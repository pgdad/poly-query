#!/usr/bin/env python3
"""PolyQuery experiment orchestrator.

Creates isolated agent workspaces, runs implementation agents inside the
sandbox, captures telemetry, validates results (public + hidden suites) in the
sandbox, and imports accepted work into the main repository.

  pq_orchestrate.py prepare  --lang go --task phase1 [--track A] [--attempt 1]
  pq_orchestrate.py run      RUN_ID [--timeout-min 300] [--budget-usd 150]
  pq_orchestrate.py validate RUN_ID
  pq_orchestrate.py import   RUN_ID [--merge]
  pq_orchestrate.py wave     --task phase1 --langs java,clojure,rust,python,go,common-lisp [--seed N]
  pq_orchestrate.py status

Run directories live under $PQ_RUN_ROOT (default /srv/polyquery/runs); the
durable record (manifest, telemetry, compressed transcript, conformance report)
is copied into experiments/runs/<run_id>/ in the repository.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import gzip
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN_ROOT = Path(os.environ.get("PQ_RUN_ROOT", "/srv/polyquery/runs"))
SANDBOX = ROOT / "tools/orchestration/sandbox.sh"
PROMPTS = ROOT / "experiments/prompts"
RECORDS = ROOT / "experiments/runs"
LANGS = ["java", "clojure", "rust", "python", "go", "common-lisp"]
ASM_LANGS = ["x86_64-asm", "arm64-asm"]
KERNEL_WORKSPACE_PATHS = [
    "spec/README.md", "spec/phases/native-kernels.md",
    "native-kernels/include", "native-kernels/reference-c", "native-kernels/tests", "native-kernels/Makefile",
    "LICENSE",
]
DEFAULT_MODEL = os.environ.get("PQ_MODEL", "claude-opus-5-5")
DEFAULT_EFFORT = os.environ.get("PQ_EFFORT", "high")

# Paths copied from the main repository into every agent workspace. Everything
# else (other implementations, hidden tests, reference tools in tools/validation,
# experiment records, results) is excluded.
WORKSPACE_PATHS = [
    "spec",
    "tests/conformance/runner.py",
    "tests/conformance/pqt.py",
    "tests/conformance/engine.py",
    "tests/conformance/FORMAT.md",
    "tests/conformance/cases",
    "tests/conformance/fixtures",
    "tests/concurrency",
    "datasets/generators",
    "datasets/manifests",
    "native-kernels/include",
    "LICENSE",
]


# The engine-integration task builds the accepted kernel library (read-only for the agent).
NATIVE_EXTRA_PATHS = ["native-kernels/Makefile", "native-kernels/reference-c", "native-kernels/x86_64",
                      "native-kernels/arm64", "native-kernels/tests"]

PHASE_TASKS = {"phase1", "phase2", "phase3", "phase4", "phase5"}

TRUSTED_PATHS = ["tests", "spec"]
TRUSTED_KERNEL_PATHS = ["spec", "native-kernels/Makefile", "native-kernels/include", "native-kernels/reference-c",
                        "native-kernels/tests"]


def load_json_file(p: Path) -> dict | None:
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def git_head() -> str | None:
    r = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() or None


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def sh(cmd: list[str], cwd: Path | None = None, check: bool = True, capture: bool = True, env: dict | None = None,
       timeout: float | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=capture, env=env, timeout=timeout)


def git(args: list[str], cwd: Path, check: bool = True) -> str:
    return sh(["git", *args], cwd=cwd, check=check).stdout.strip()


def tree_hash(paths: list[Path]) -> str:
    h = hashlib.sha256()
    for base in paths:
        files = [base] if base.is_file() else sorted(p for p in base.rglob("*") if p.is_file())
        for f in files:
            h.update(str(f.relative_to(ROOT)).encode())
            h.update(f.read_bytes())
    return h.hexdigest()


def render(template: str, values: dict) -> str:
    out = template
    for _ in range(2):  # allow placeholders inside values
        for k, v in values.items():
            out = out.replace("{{" + k + "}}", v)
    left = re.findall(r"\{\{[A-Z_]+\}\}", out)
    if left:
        raise SystemExit(f"unrendered placeholders: {left}")
    return out


def run_dir(run_id: str) -> Path:
    return RUN_ROOT / run_id


def load_manifest(run_id: str) -> dict:
    return json.loads((run_dir(run_id) / "manifest.json").read_text())


def save_manifest(run_id: str, m: dict) -> None:
    (run_dir(run_id) / "manifest.json").write_text(json.dumps(m, indent=1) + "\n")


def tool_versions() -> dict:
    vf = ROOT / "tools/environment/versions.json"
    if not vf.exists():
        sh([sys.executable, str(ROOT / "tools/environment/doctor.py"), "--quiet"], check=False)
    try:
        return json.loads(vf.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


# ------------------------------------------------------------------ prepare

def prepare(lang: str, task: str, track: str, attempt: int, base_ref: str | None, wave: str | None) -> str:
    tasks = json.loads((PROMPTS / "tasks.json").read_text())
    langs = json.loads((PROMPTS / "languages.json").read_text())
    if lang not in langs:
        raise SystemExit(f"unknown language {lang}")
    if (lang in ASM_LANGS) != (task == "kernels"):
        raise SystemExit(f"task {task} does not apply to {lang}")
    if task not in tasks:
        raise SystemExit(f"unknown task {task}")
    t, L = tasks[task], langs[lang]
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = f"{track.lower()}-{task}-{lang}-a{attempt}-{stamp}"
    rd = run_dir(run_id)
    ws = rd / "workspace"
    (rd / "config").mkdir(parents=True)
    (rd / "scratch").mkdir()
    ws.mkdir()

    ref = base_ref or git(["rev-parse", "HEAD"], ROOT)
    # Export the allowed paths at `ref` (committed state only) into the workspace.
    impl_path = L["work_dir"]
    export = (KERNEL_WORKSPACE_PATHS if task == "kernels" else WORKSPACE_PATHS) + [impl_path]
    if task not in PHASE_TASKS and task != "kernels":
        export += NATIVE_EXTRA_PATHS
    present = [p for p in export if sh(["git", "cat-file", "-e", f"{ref}:{p}"], cwd=ROOT, check=False).returncode == 0]
    archive = subprocess.run(["git", "archive", "--format=tar", ref, *present], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["tar", "-x", "-C", str(ws)], input=archive.stdout, check=True)
    (ws / impl_path).mkdir(parents=True, exist_ok=True)

    template = (PROMPTS / L["template"]).read_text()
    values = {
        "WORK_DIR": L["work_dir"], "VARIANT_PREFIX": L["variant_prefix"], "ABI": L["abi"],
        "TEST_NOTE": L["test_note"], "SIMD_NAME": L["simd_name"], "OPTIONAL_SIMD": L["optional_simd"],
        "TEST_TARGET": L["test_target"],
        "TASK_TITLE": t["title"], "TASK_GOAL": t["goal"], "PHASE_FILE": t["phase_file"],
        "RUNNER_ARGS": t["runner_args"], "DONE_CRITERIA": t["done"],
        "LANGUAGE": L["language"], "LANG_DIR": L["lang_dir"], "TOOLCHAIN": L["toolchain"],
        "STDLIB_NOTE": L["stdlib_note"],
    }
    task_md = render(template, values)
    (ws / "TASK.md").write_text(task_md)
    defect_id = None
    if task == "debug-mutant":
        # Inject the pre-generated defect (tools/orchestration/mutate.py) before the baseline commit,
        # so the workspace history contains no trace of the original line.
        cands = sorted(p for p in (ROOT / "experiments/controlled/defects" / lang).glob("*/mutation.patch"))
        want = os.environ.get("PQ_DEFECT")
        cands = [p for p in cands if not want or p.parent.name == want]
        if not cands:
            raise SystemExit(f"no defect prepared for {lang} (run tools/orchestration/mutate.py --lang {lang})")
        patch = cands[0]
        defect_id = patch.parent.name
        subprocess.run(["patch", "-p1", "-s", "-d", str(ws)], input=patch.read_bytes(), check=True)
        shutil.copy(patch.parent / "DEFECT.md", ws / "DEFECT.md")
    (ws / ".gitignore").write_text("target/\nbuild/\nout/\n.cpcache/\n__pycache__/\n*.pyc\n*.fasl\n*.o\n*.so\n/datasets/generated/\n")
    env = {**os.environ, "GIT_AUTHOR_NAME": "PolyQuery Orchestrator", "GIT_AUTHOR_EMAIL": "orchestrator@polyquery.invalid",
           "GIT_COMMITTER_NAME": "PolyQuery Orchestrator", "GIT_COMMITTER_EMAIL": "orchestrator@polyquery.invalid"}
    sh(["git", "init", "-q", "-b", "main"], cwd=ws)
    sh(["git", "add", "-A"], cwd=ws)
    sh(["git", "commit", "-q", "-m", f"baseline: {task} for {lang} (from {ref[:12]})"], cwd=ws, env=env)
    baseline = git(["rev-parse", "HEAD"], ws)

    # Isolated Claude config: credentials only (bound at run time), plus settings.
    (rd / "config/settings.json").write_text(json.dumps({
        "autoUpdates": False, "includeCoAuthoredBy": False, "cleanupPeriodDays": 3650,
    }, indent=1))

    prompt_hash = hashlib.sha256(task_md.encode()).hexdigest()
    m = {
        "schema": "polyquery-run-manifest/1",
        "run_id": run_id, "wave": wave, "language": lang, "task": task, "track": track, "attempt": attempt,
        "created": now(), "repo_ref": ref, "baseline_commit": baseline,
        "spec_hash": tree_hash([ROOT / "spec"]),
        "prompt_template": f"experiments/prompts/{L['template']}", "work_dir": L["work_dir"],
        "prompt_id": f"track-{track.lower()}-{task}", "prompt_sha256": prompt_hash,
        "model": DEFAULT_MODEL, "effort": DEFAULT_EFFORT,
        "agent_harness": None, "limits": {}, "status": "prepared",
        "host": {"hostname": os.uname().nodename, "tools": tool_versions()},
        # Capability set of the accepted engine this run starts from (refactoring must keep it).
        "defect_id": defect_id,
        "baseline_capabilities": ((load_json_file(ROOT / "results/correctness" / f"{lang}.json") or {})
                                  .get("engine") or {}).get("capability_set"),
    }
    save_manifest(run_id, m)
    print(run_id)
    return run_id


# ------------------------------------------------------------------ run

def claude_version() -> str | None:
    p = sh(["claude", "--version"], check=False)
    return p.stdout.strip() or None


MAX_TOKEN_WAIT_MIN = float(os.environ.get("PQ_MAX_TOKEN_WAIT_MIN", "160"))


def run(run_id: str, timeout_min: int, budget_usd: float, max_turns: int | None) -> dict:
    rd = run_dir(run_id)
    m = load_manifest(run_id)
    ws, cfg, scr = rd / "workspace", rd / "config", rd / "scratch"
    creds = Path.home() / ".claude/.credentials.json"
    usage_gate(run_id)
    # Fresh copy of the OAuth credential at run start (never the rest of ~/.claude).
    # The run is capped to the access token's remaining lifetime so the agent never
    # needs to refresh it (refresh-token rotation across copies could invalidate the
    # host's or other runs' credentials).
    # Wait for a token that covers the whole requested limit (up to what a fresh token
    # offers), so limits are uniform across languages instead of depending on launch time.
    need_min = max(75, min(timeout_min + 15, MAX_TOKEN_WAIT_MIN))
    while True:
        cred = json.loads(creds.read_text())
        remaining_min = ((cred.get("claudeAiOauth") or {}).get("expiresAt", 0) / 1000 - time.time()) / 60
        if remaining_min >= need_min:
            break
        print(f"[{run_id}] waiting for host credential refresh (token valid {remaining_min:.0f} more min)", flush=True)
        time.sleep(120)
    print(f"{now()} [{run_id}] agent launched (token valid {remaining_min:.0f} min)", flush=True)
    shutil.copy(creds, cfg / ".credentials.json")
    os.chmod(cfg / ".credentials.json", 0o600)
    timeout_min = int(min(timeout_min, remaining_min - 15))
    m["agent_harness"] = {"name": "claude-code", "version": claude_version(), "mode": "headless -p stream-json"}
    m["limits"] = {"timeout_min": timeout_min, "budget_usd": budget_usd, "max_turns": max_turns}
    m["status"] = "running"
    m["started"] = now()
    save_manifest(run_id, m)

    prompt = ("Read TASK.md in the current directory carefully and complete the task it describes. "
              "Work autonomously until the definition of done is met.")
    cmd = [str(SANDBOX), str(ws), str(cfg), str(scr), "--",
           "timeout", "--signal=TERM", "--kill-after=60", f"{timeout_min * 60}",
           "claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
           "--model", m["model"], "--effort", m["effort"],
           "--dangerously-skip-permissions", "--strict-mcp-config", "--setting-sources", "user",
           "--max-budget-usd", str(budget_usd)]
    if max_turns:
        cmd += ["--max-turns", str(max_turns)]
    env = dict(os.environ)
    transcript = rd / "transcript.jsonl"
    t0 = time.time()
    t_mono = time.monotonic()
    with open(transcript, "w") as out, open(rd / "agent.stderr", "w") as err:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=err, text=True, env=env)
        assert proc.stdout
        guard_reason = None
        for line in proc.stdout:
            ev = _safe_json(line)
            # Prefix each event with the orchestrator's receive time (seconds since start).
            out.write(json.dumps({"_t": round(time.monotonic() - t_mono, 3), "event": ev}) + "\n")
            out.flush()
            if guard_reason is None and (guard_reason := usage_violation(ev)):
                print(f"[{run_id}] usage guard: {guard_reason}; stopping agent", flush=True)
                proc.terminate()
        rc = proc.wait()
    m = load_manifest(run_id)
    if guard_reason:
        m["termination_reason"] = "usage_guard"
        m["usage_guard"] = guard_reason
    m["finished"] = now()
    m["wall_seconds"] = round(time.time() - t0, 1)
    m["agent_exit_code"] = rc
    if rc in (124, 137) and not guard_reason:
        m["termination_reason"] = "timeout"
    m["status"] = "ran"
    save_manifest(run_id, m)
    return m


# Subscription usage protection: never start runs near the 5-hour limit and never let
# a run continue into paid overage (thresholds overridable via environment).
MAX_5H_START = float(os.environ.get("PQ_MAX_5H_UTIL_START", "0.8"))
MAX_5H_RUN = float(os.environ.get("PQ_MAX_5H_UTIL_RUN", "0.95"))
MAX_7D_START = float(os.environ.get("PQ_MAX_7D_UTIL_START", "0.8"))


def usage_violation(ev: dict) -> str | None:
    if not isinstance(ev, dict) or ev.get("type") != "rate_limit_event":
        return None
    info = ev.get("rate_limit_info") or {}
    if info.get("isUsingOverage"):
        return "agent is using paid overage"
    if info.get("status") not in (None, "allowed"):
        return f"rate-limit status {info.get('status')}"
    five = ((info.get("unifiedWindows") or {}).get("five_hour") or {}).get("utilization")
    if five is not None and five >= MAX_5H_RUN:
        return f"five_hour utilization {five:.2f} >= {MAX_5H_RUN}"
    return None


def latest_usage() -> dict:
    """Most recent rate-limit windows observed in any run transcript (windows already reset count as 0)."""
    best: tuple[float, dict] | None = None
    for t in RUN_ROOT.glob("*/transcript.jsonl"):
        mt = t.stat().st_mtime
        if time.time() - mt > 6 * 3600 or (best and mt < best[0]):
            continue
        last = None
        with open(t, errors="replace") as fh:
            for line in fh:
                if '"rate_limit_event"' in line:
                    last = line
        if last:
            ev = (json.loads(last).get("event") or {}).get("rate_limit_info") or {}
            best = (mt, ev.get("unifiedWindows") or {})
    out = {}
    for k, w in (best[1] if best else {}).items():
        out[k] = {"utilization": 0.0 if w.get("resetsAt", 0) < time.time() else w.get("utilization", 0.0),
                  "resetsAt": w.get("resetsAt")}
    return out


def usage_gate(run_id: str) -> None:
    while True:
        u = latest_usage()
        five = (u.get("five_hour") or {}).get("utilization", 0.0)
        week = (u.get("seven_day") or {}).get("utilization", 0.0)
        if five < MAX_5H_START and week < MAX_7D_START:
            return
        print(f"[{run_id}] usage gate: five_hour={five:.2f} seven_day={week:.2f}; waiting", flush=True)
        time.sleep(300)


def _descendants(pid: int) -> list[int]:
    out, stack = [], [pid]
    while stack:
        p = stack.pop()
        out.append(p)
        try:
            for t in os.listdir(f"/proc/{p}/task"):
                stack.extend(int(c) for c in Path(f"/proc/{p}/task/{t}/children").read_text().split())
        except OSError:
            pass
    return out


def watchdog(interval: float = 30.0) -> None:
    """Applies the in-run usage guard to every running agent (also runs started by an older orchestrator)."""
    pos: dict[Path, int] = {}
    stopped: set[str] = set()
    while True:
        active = [d for d in RUN_ROOT.iterdir() if (d / "manifest.json").exists()
                  and json.loads((d / "manifest.json").read_text()).get("status") == "running"]
        for d in active:
            t = d / "transcript.jsonl"
            if not t.exists() or d.name in stopped:
                continue
            with open(t, errors="replace") as fh:
                fh.seek(pos.get(t, 0))
                chunk = fh.read()
                pos[t] = fh.tell()
            for line in chunk.splitlines():
                if '"rate_limit_event"' not in line:
                    continue
                reason = usage_violation((_safe_json(line) or {}).get("event") or {})
                if not reason:
                    continue
                m = json.loads((d / "manifest.json").read_text())
                m["usage_guard"] = reason
                m["termination_reason"] = "usage_guard"
                (d / "manifest.json").write_text(json.dumps(m, indent=1) + "\n")
                # The run's sandbox root (sudo) carries the workspace path on its command line.
                for pid in os.listdir("/proc"):
                    if not pid.isdigit():
                        continue
                    try:
                        cmd = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
                    except OSError:
                        continue
                    if cmd[:1] == [b"sudo"] and str(d / "workspace").encode() in cmd:
                        for c in _descendants(int(pid)):
                            try:
                                if Path(f"/proc/{c}/comm").read_text().strip() == "claude":
                                    os.kill(c, signal.SIGTERM)
                            except OSError:
                                pass
                print(f"{now()} [{d.name}] usage guard: {reason}; agent stopped", flush=True)
                stopped.add(d.name)
                break
        if not active:
            print(f"{now()} watchdog: no running agents; exiting", flush=True)
            return
        time.sleep(interval)


def _safe_json(line: str):
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return {"_raw": line.rstrip("\n")[:2000]}


# ------------------------------------------------------------------ telemetry

BUILD_ERR = re.compile(r"(error(\[E\d+\])?:|cannot find symbol|compilation failed|Syntax error|SyntaxError|"
                       r"undefined: |COMPILE-FILE|caught ERROR|Exception in thread \"main\"|"
                       r"Compiler exception|Unable to resolve symbol|make: \*\*\*)", re.I)
RUNNER_TOTAL = re.compile(r"TOTAL: (\d+)/(\d+) pass")


def telemetry(run_id: str) -> dict:
    rd = run_dir(run_id)
    m = load_manifest(run_id)
    events = [json.loads(l) for l in (rd / "transcript.jsonl").read_text().splitlines() if l.strip()]
    tool_calls: dict[str, int] = {}
    tool_errors = 0
    pending: dict[str, tuple[float, str, str]] = {}
    tool_time = 0.0
    build_cmds = build_failures = 0
    runner_runs = 0
    runner_results: list[tuple[int, int]] = []
    assistant_turns = 0
    results: list[dict] = []
    init = None
    result = None
    msg_usage: dict[str, dict] = {}
    thinking_est = 0
    rate_limits: list[dict] = []
    for e in events:
        ev, t = e.get("event") or {}, e.get("_t", 0.0)
        typ = ev.get("type")
        if typ == "system" and ev.get("subtype") == "init":
            init = ev
        elif typ == "system" and ev.get("subtype") == "thinking_tokens":
            thinking_est += int(ev.get("estimated_tokens_delta") or 0)
        elif typ == "rate_limit_event":
            info = ev.get("rate_limit_info") or {}
            rate_limits.append({"t": t, "status": info.get("status"),
                                "windows": {k: (w or {}).get("utilization") for k, w in (info.get("unifiedWindows") or {}).items()}})
        elif typ == "assistant":
            assistant_turns += 1
            msg = ev.get("message") or {}
            if msg.get("id") and isinstance(msg.get("usage"), dict):
                cur = msg_usage.setdefault(msg["id"], {})
                for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"):
                    v = msg["usage"].get(k)
                    if isinstance(v, int):
                        cur[k] = max(cur.get(k, 0), v)
            for block in (ev.get("message") or {}).get("content") or []:
                if block.get("type") == "tool_use":
                    name = block.get("name", "?")
                    tool_calls[name] = tool_calls.get(name, 0) + 1
                    cmd = json.dumps(block.get("input") or {})
                    pending[block.get("id")] = (t, name, cmd)
        elif typ == "user":
            for block in (ev.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    started = pending.pop(block.get("tool_use_id"), None)
                    text = block.get("content")
                    if isinstance(text, list):
                        text = " ".join(x.get("text", "") for x in text if isinstance(x, dict))
                    text = str(text or "")
                    if block.get("is_error"):
                        tool_errors += 1
                    if started:
                        tool_time += max(0.0, t - started[0])
                        name, cmd = started[1], started[2]
                        if name == "Bash":
                            if re.search(r"\bmake\b|cargo (build|test)|go (build|test|vet)|javac|mvn|clojure|sbcl|gcc|\bas\b", cmd):
                                build_cmds += 1
                                if BUILD_ERR.search(text):
                                    build_failures += 1
                            if re.search(r"runner\.py[^\n]*--engine", cmd):
                                runner_runs += 1
                                mm = RUNNER_TOTAL.findall(text)
                                if mm:
                                    runner_results.append(tuple(map(int, mm[-1])))
        elif typ == "result":
            results.append(ev)
    # A session may emit several result events (e.g. after ScheduleWakeup resumes it):
    # num_turns and usage are per segment and are summed; cost and API time are cumulative.
    result = results[-1] if results else None
    usage = {}
    for r in results:
        for k, v in (r.get("usage") or {}).items():
            if isinstance(v, int) and not isinstance(v, bool):
                usage[k] = usage.get(k, 0) + v
    usage_source = "result events" + (f" (summed over {len(results)} segments)" if len(results) > 1 else "")
    if not usage:
        # Run was killed before the final result event: sum per-message usage
        # (deduplicated by message id). Cost is not derivable without the platform's
        # pricing and is left null.
        usage_source = "summed per-message usage (no final result event; output tokens are a lower bound)"
        usage = {k: sum(u.get(k, 0) for u in msg_usage.values()) for k in
                 ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")} if msg_usage else {}
    ws = rd / "workspace"
    commits = git(["rev-list", "--count", f"{m['baseline_commit']}..HEAD"], ws, check=False)
    wd = m.get("work_dir") or f"implementations/{m['language']}"
    numstat = git(["diff", "--numstat", m["baseline_commit"], "HEAD", "--", wd], ws, check=False)
    added = removed = files = 0
    for line in numstat.splitlines():
        a, r, _ = (line.split("\t") + ["", "", ""])[:3]
        files += 1
        added += int(a) if a.isdigit() else 0
        removed += int(r) if r.isdigit() else 0
    outside = git(["diff", "--name-only", m["baseline_commit"], "HEAD", "--", ".", f":(exclude){wd}"], ws, check=False)
    dirty = git(["status", "--porcelain"], ws, check=False)
    first_fail = next((i for i, (p, n) in enumerate(runner_results) if p < n), None)
    tel = {
        "schema": "polyquery-telemetry/1",
        "run_id": run_id, "language": m["language"], "task": m["task"], "track": m["track"], "attempt": m["attempt"],
        "model": (init or {}).get("model") or m["model"], "effort": m["effort"],
        "agent_harness_version": (init or {}).get("claude_code_version") or (m.get("agent_harness") or {}).get("version"),
        "prompt_id": m["prompt_id"], "prompt_sha256": m["prompt_sha256"],
        "session_id": (result or init or {}).get("session_id"),
        "tokens": {
            "input": usage.get("input_tokens"),
            "output": usage.get("output_tokens"),
            "cache_read": usage.get("cache_read_input_tokens"),
            "cache_creation": usage.get("cache_creation_input_tokens"),
            "thinking": (usage.get("output_tokens_details") or {}).get("thinking_tokens"),
            "thinking_estimated": thinking_est,
            "source": usage_source,
            "api_messages": len(msg_usage),
        },
        "rate_limit": {"events": len(rate_limits),
                       "max_utilization": {k: max((r["windows"].get(k) or 0) for r in rate_limits)
                                           for k in {k for r in rate_limits for k in r["windows"]}},
                       "statuses": sorted({str(r["status"]) for r in rate_limits})},
        "cost_usd": max((r["total_cost_usd"] for r in results if isinstance(r.get("total_cost_usd"), (int, float))),
                        default=None),
        "cost_basis": "platform-reported list price (total_cost_usd)",
        "agent_turns": sum(r.get("num_turns") or 0 for r in results) if results else None,
        "result_segments": len(results),
        "assistant_messages": assistant_turns,
        "tool_calls": tool_calls,
        "tool_calls_total": sum(tool_calls.values()),
        "tool_failures": tool_errors,
        "build_invocations": build_cmds,
        "build_failures_heuristic": build_failures,
        "conformance_runs": runner_runs,
        "conformance_progress": runner_results,
        "repair_iterations": (runner_runs - first_fail - 1) if first_fail is not None else 0,
        "time": {
            "wall_seconds": m.get("wall_seconds"),
            "model_api_seconds": round(max((r.get("duration_api_ms") or 0) for r in results) / 1000, 1)
            if results else None,
            "tool_seconds": round(tool_time, 1),
            "waiting_seconds": None,
            "human_seconds": 0,
        },
        "human_interventions": 0,
        "git": {"commits": int(commits) if commits.isdigit() else None, "files_changed": files,
                "lines_added": added, "lines_removed": removed,
                "uncommitted_changes": bool(dirty.strip()), "paths_outside_language_dir": outside.splitlines()},
        "agent_exit_code": m.get("agent_exit_code"),
        "result_subtype": (result or {}).get("subtype"),
        "is_error": (result or {}).get("is_error"),
        "stop_reason": (result or {}).get("terminal_reason") or (result or {}).get("stop_reason"),
        "final_message": ((result or {}).get("result") or "")[:4000],
        "notes": {
            "human_seconds": "0 by construction: unattended run, no human input after launch",
            "waiting_seconds": "not exposed by the platform",
            "build_failures_heuristic": "Bash build commands whose output matched compiler-error patterns",
            "repair_iterations": "conformance runner invocations after the first one reporting failures",
        },
    }
    (rd / "telemetry.json").write_text(json.dumps(tel, indent=1) + "\n")
    return tel


# ------------------------------------------------------------------ validate

def validate(run_id: str, phases: list[int] | None = None) -> dict:
    """Clean-clone build + public & hidden conformance, executed inside the sandbox."""
    rd = run_dir(run_id)
    m = load_manifest(run_id)
    lang = m["language"]
    vd = rd / "validate"
    if vd.exists():
        shutil.rmtree(vd)
    sh(["git", "clone", "-q", str(rd / "workspace"), str(vd)])
    # Only the agent's own work directory is taken from the workspace; the harness, spec and kernel
    # test scaffolding come from the trusted repository (incl. hidden tests), so edits an agent made
    # to them cannot influence its verdict.
    for rel in TRUSTED_KERNEL_PATHS if m["task"] == "kernels" else \
            TRUSTED_PATHS + (NATIVE_EXTRA_PATHS if m["task"] not in PHASE_TASKS else []):
        dst = vd / rel
        if dst.is_dir():
            shutil.rmtree(dst)
        elif dst.exists():
            dst.unlink()
        src = ROOT / rel
        if src.is_dir():
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__", "build"))
        elif src.exists():
            shutil.copy2(src, dst)
    if m["task"] == "kernels":
        return validate_kernels(run_id, m, vd)
    task_phase = {"phase1": [1], "phase2": [1, 2], "phase3": [1, 2, 3], "phase4": [1, 2, 3], "phase5": [1, 2, 3],
                  "native": [1, 2, 3]}
    # Later experiment families (changes, refactoring, debugging, optimization) start from complete
    # Phase 5 engines and are validated like Phase 5 (change suites run when the engine claims the change).
    full = m["task"] not in task_phase or m["task"] == "phase5"
    phases = phases or task_phase.get(m["task"], [1, 2, 3])
    phase_args = " ".join(f"--phase {p}" for p in phases)
    vscr = rd / "vscratch"
    vscr.mkdir(exist_ok=True)
    script = f"""set -u
cd {vd}
: > validate-status
"""
    if m["task"] not in PHASE_TASKS:
        # The library is built from the trusted kernel sources inside the sandbox.
        script += """( make -C native-kernels all ) > validate-native-lib.log 2>&1; echo "native_lib_exit=$?" >> validate-status
"""
    script += f"""( make -C implementations/{lang} build ) > validate-build.log 2>&1; echo "build_exit=$?" >> validate-status
python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery {phase_args} --include-hidden \
   --report conformance.json --logs engine-logs -q > validate-conformance.log 2>&1; echo "conformance_exit=$?" >> validate-status
"""
    extra = []
    if m["task"] == "phase4" or full:
        script += f"""python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery {phase_args} --include-hidden \
   --transport http --report conformance-http.json -q > validate-http.log 2>&1; echo "http_exit=$?" >> validate-status
python3 tests/concurrency/http_suite.py --engine implementations/{lang}/bin/polyquery --report http-suite.json > validate-http-suite.log 2>&1; echo "http_suite_exit=$?" >> validate-status
"""
        extra = ["conformance-http.json", "http-suite.json"]
    if m["task"] == "native":
        # Trusted kernel sources replace the workspace copy; the library is built inside the sandbox.
        lib = "native-kernels/build/x86_64/libpqkernels.so"
        script += f"""python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery {phase_args} --include-hidden \
   --native {lib} --report conformance-native.json -q > validate-native.log 2>&1; echo "native_exit=$?" >> validate-status
python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery --modes --include-hidden \
   --native {lib} --report conformance-native-modes.json -q > validate-native-modes.log 2>&1; echo "native_modes_exit=$?" >> validate-status
python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery --modes --include-hidden \
   --report conformance-modes.json -q > validate-modes.log 2>&1; echo "modes_exit=$?" >> validate-status
python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery {phase_args} --include-hidden \
   --transport http --report conformance-http.json -q > validate-http.log 2>&1; echo "http_exit=$?" >> validate-status
python3 tests/concurrency/http_suite.py --engine implementations/{lang}/bin/polyquery --report http-suite.json > validate-http-suite.log 2>&1; echo "http_suite_exit=$?" >> validate-status
"""
        extra = ["conformance-native.json", "conformance-native-modes.json", "conformance-modes.json",
                 "conformance-http.json", "http-suite.json"]
    if full and m["task"] != "phase5":
        lib = "native-kernels/build/x86_64/libpqkernels.so"
        script += f"""if implementations/{lang}/bin/polyquery capabilities | grep -q native.kernels; then
python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery {phase_args} --include-hidden \
   --native {lib} --report conformance-native.json -q > validate-native.log 2>&1; echo "native_exit=$?" >> validate-status
fi
"""
        extra.append("conformance-native.json")
    if full:
        script += f"""python3 tests/conformance/runner.py --engine implementations/{lang}/bin/polyquery --modes --include-hidden \
   --report conformance-modes.json -q > validate-modes.log 2>&1; echo "modes_exit=$?" >> validate-status
"""
        extra.append("conformance-modes.json")
    (vscr / "validate.sh").write_text(script)
    cfg = rd / "config"
    t0 = time.time()
    sh([str(SANDBOX), str(vd), str(cfg), str(vscr), "--", "bash", str(vscr / "validate.sh")], check=False, capture=True,
       timeout=6 * 3600)
    status = dict(l.split("=", 1) for l in (vd / "validate-status").read_text().split() if "=" in l) \
        if (vd / "validate-status").exists() else {}
    report = json.loads((vd / "conformance.json").read_text()) if (vd / "conformance.json").exists() else None
    out = {"seconds": round(time.time() - t0, 1), "status": status, "phases": phases,
           "summary": (report or {}).get("summary"), "phase_passed": (report or {}).get("phase_passed"),
           "capabilities": ((report or {}).get("engine") or {}).get("capability_set"),
           "extra": {}}
    for x in extra:
        p = vd / x
        if p.exists():
            d = json.loads(p.read_text())
            out["extra"][x] = d.get("summary") or d
    for f in ["conformance.json", *extra, "validate-build.log", "validate-conformance.log"]:
        if (vd / f).exists():
            shutil.copy(vd / f, rd / f)
    out["outcome"] = classify(m, out)
    out["validated_at"] = now()
    out["harness_commit"] = git_head()
    archive_validation(rd)
    (rd / "validation.json").write_text(json.dumps(out, indent=1) + "\n")
    m = load_manifest(run_id)
    m["outcome"] = out["outcome"]
    m["status"] = "validated"
    save_manifest(run_id, m)
    return out


def archive_validation(rd: Path) -> None:
    """Re-validation (e.g. after a harness fix) keeps every earlier verdict."""
    prev = rd / "validation.json"
    if prev.exists():
        hist = rd / "validation-history"
        hist.mkdir(exist_ok=True)
        shutil.copy(prev, hist / f"validation-{len(list(hist.glob('*.json'))) + 1}.json")


def validate_kernels(run_id: str, m: dict, vd: Path) -> dict:
    rd = run_dir(run_id)
    L = json.loads((PROMPTS / "languages.json").read_text())[m["language"]]
    vscr = rd / "vscratch"
    vscr.mkdir(exist_ok=True)
    target = L["test_target"]
    script = f"""set -u
cd {vd}
make -C native-kernels clean >/dev/null 2>&1
( make -C native-kernels {target} ) > validate-kernels.log 2>&1; echo "test_exit=$?" > validate-status
if [ "{target}" = "test" ]; then ( make -C native-kernels bench ) > validate-bench.log 2>&1; echo "bench_exit=$?" >> validate-status; fi
"""
    if L["variant_prefix"] == "a64_":
        # SVE code must be vector-length agnostic: sweep 128..2048-bit vectors under qemu.
        script += """for vl in 16 32 64 128 256; do echo "VL=$vl"; \
  qemu-aarch64-static -cpu max,sve-default-vector-length=$vl -L /usr/aarch64-linux-gnu \
  native-kernels/build/aarch64-cross/kernel_test 800 2>&1 | grep -E 'kernels +(PASS|FAIL)'; done > validate-sve.log 2>&1
"""
    (vscr / "validate.sh").write_text(script)
    t0 = time.time()
    sh([str(SANDBOX), str(vd), str(rd / "config"), str(vscr), "--", "bash", str(vscr / "validate.sh")], check=False,
       timeout=3 * 3600)
    status = dict(l.split("=", 1) for l in (vd / "validate-status").read_text().split() if "=" in l) \
        if (vd / "validate-status").exists() else {}
    log = (vd / "validate-kernels.log").read_text(errors="replace") if (vd / "validate-kernels.log").exists() else ""
    variants = {mm.group(1): {"kernels": int(mm.group(2)), "status": mm.group(3)}
                for mm in re.finditer(r"^\s+(\w+)\s+(\d+)/16 kernels\s+(PASS|FAIL)", log, re.M)}
    prefix = L["variant_prefix"]
    simd = "x86_avx2" if prefix == "x86_" else "a64_neon"
    required = [f"{prefix}scalar", simd]
    ok = status.get("test_exit") == "0" and all(variants.get(v, {}).get("kernels") == 16 and
                                                 variants.get(v, {}).get("status") == "PASS" for v in required)
    bench = []
    bf = vd / "native-kernels/build/x86_64/bench.jsonl"
    if bf.exists():
        bench = [json.loads(l) for l in bf.read_text().splitlines() if l.strip().startswith("{")]
    sve_vl: dict[str, bool] = {}
    if (vd / "validate-sve.log").exists():
        vl = None
        for line in (vd / "validate-sve.log").read_text().splitlines():
            if line.startswith("VL="):
                vl = str(int(line[3:]) * 8)
            elif vl and "a64_sve" in line:
                sve_vl[vl] = "PASS" in line
    native_arm = None
    if prefix == "a64_":
        native_arm = run_native_arm(vd / "native-kernels", rd / "native-arm")
        if native_arm.get("available"):
            ok = ok and native_arm["ok"]
            if native_arm["bench"]:
                bench = native_arm["bench"]
    for f in ["validate-kernels.log", "validate-bench.log", "validate-sve.log"]:
        if (vd / f).exists():
            shutil.copy(vd / f, rd / f)
    out = {"seconds": round(time.time() - t0, 1), "status": status, "variants": variants, "required": required,
           "emulated": prefix == "a64_" and not (native_arm or {}).get("available"),
           "bench": bench, "sve_vector_lengths_bits": sve_vl or None,
           "native_arm": {k: v for k, v in (native_arm or {}).items() if k != "bench"} or None}
    out["outcome"] = "success" if ok else ("build_failed" if not variants else "tests_failed")
    tel_path = rd / "telemetry.json"
    if tel_path.exists() and (json.loads(tel_path.read_text()).get("git") or {}).get("paths_outside_language_dir"):
        out["outcome"] = "isolation_violation"
    (rd / "validation.json").write_text(json.dumps(out, indent=1) + "\n")
    if bench:
        (rd / "kernel-bench.json").write_text(json.dumps(bench, indent=1) + "\n")
    mm_ = load_manifest(run_id)
    mm_["outcome"] = out["outcome"]
    mm_["status"] = "validated"
    save_manifest(run_id, mm_)
    return out


ARM_NATIVE = ROOT / "tools/remote/arm_native.sh"


def run_native_arm(kernels_dir: Path, out_dir: Path) -> dict:
    """Native AArch64 tests (+ASan/UBSan) and a pinned benchmark on the remote ARM host (PQ_ARM_HOST)."""
    host = os.environ.get("PQ_ARM_HOST", "spark")
    if os.environ.get("PQ_ARM_HOST") == "":
        return {"available": False, "reason": "disabled (PQ_ARM_HOST empty)"}
    if out_dir.exists():
        shutil.rmtree(out_dir)
    r = subprocess.run([str(ARM_NATIVE), str(kernels_dir), str(out_dir), "--bench", "--asan"],
                       capture_output=True, text=True, timeout=3 * 3600)
    st_file = out_dir / "arm-status"
    if not st_file.exists():
        return {"available": False, "host": host, "reason": (r.stderr or r.stdout)[-500:]}
    st = dict(l.split("=", 1) for l in st_file.read_text().split() if "=" in l)
    variants: dict[str, dict] = {}
    for log, key in (("arm-test.log", "native"), ("arm-asan.log", "asan")):
        p = out_dir / log
        if p.exists():
            for mm in re.finditer(r"^\s+(\w+)\s+(\d+)/16 kernels\s+(PASS|FAIL)", p.read_text(errors="replace"), re.M):
                variants.setdefault(mm.group(1), {})[key] = f"{mm.group(2)}/16 {mm.group(3)}"
    bf = out_dir / "bench.jsonl"
    bench = [json.loads(l) for l in bf.read_text().splitlines() if l.strip().startswith("{")] if bf.exists() else []
    host_info = json.loads((out_dir / "arm-host.json").read_text()) if (out_dir / "arm-host.json").exists() else {}
    ok = st.get("test_exit") == "0" and st.get("asan_exit") == "0" and \
        all(v.get("native", "").startswith("16/16 PASS") and v.get("asan", "").startswith("16/16 PASS")
            for v in variants.values()) and bool(variants)
    return {"available": True, "host": host, "status": st, "variants": variants, "ok": ok, "bench": bench,
            "bench_cpu": os.environ.get("PQ_ARM_BENCH_CPU", "9"),
            "host_info": {k: host_info.get(k) for k in ("hostname", "kernel", "os", "gcc",
                                                         "sve_default_vector_length_bytes", "governor")}}


CAPS_UNCHANGED_TASKS = {"refactor-plan-separation", "debug-mutant", "optimize-latency"}
TASK_REQUIRED_CAPS = {"change-union-all": "change.union_all", "change-decimal38": "change.decimal38",
                      "native": "native.kernels"}


def classify(m: dict, v: dict) -> str:
    tel_path = run_dir(m["run_id"]) / "telemetry.json"
    tel = json.loads(tel_path.read_text()) if tel_path.exists() else {}
    if (tel.get("git") or {}).get("paths_outside_language_dir"):
        return "isolation_violation"
    if v["status"].get("build_exit") != "0":
        return "build_failed"
    # A requirement-change task is only done if the engine claims the change (its suites are skipped otherwise).
    need = TASK_REQUIRED_CAPS.get(m["task"])
    if need and need not in (v.get("capabilities") or []):
        return "tests_failed"
    if m["task"] in CAPS_UNCHANGED_TASKS and m.get("baseline_capabilities") is not None and \
            sorted(v.get("capabilities") or []) != sorted(m["baseline_capabilities"]):
        return "tests_failed"
    summ = (v.get("summary") or {}).get("by_phase") or {}
    ok = True
    for ph in v["phases"]:
        s = summ.get(str(ph))
        if not s:
            ok = False
            continue
        nonpass = s["total"] - s["pass"]
        # The optional correlated-subquery file may be not_implemented in phase 2.
        allowed = 0
        if ph == 2:
            allowed = _optional_not_impl(m["run_id"])
        if nonpass > allowed:
            ok = False
    for name, s in (v.get("extra") or {}).items():
        t = (s or {}).get("total") if isinstance(s, dict) else None
        if isinstance(t, dict) and t.get("pass") != t.get("total"):
            ok = False
        elif isinstance(s, dict) and "failed" in s and s["failed"]:
            ok = False
    rc = m.get("agent_exit_code")
    # A killed agent did not finish its task, even if what it had committed passes.
    if rc in (124, 137):
        return "timeout"
    if ok:
        return "success"
    subtype = tel.get("result_subtype")
    if (m.get("wall_seconds") or 0) >= (m.get("limits") or {}).get("timeout_min", 1e9) * 60:
        return "timeout"
    if subtype and "budget" in str(subtype):
        return "budget_exhausted"
    if tel.get("is_error") or subtype not in (None, "success"):
        return "agent_failure"
    return "tests_failed"


def _optional_not_impl(run_id: str) -> int:
    p = run_dir(run_id) / "conformance.json"
    if not p.exists():
        return 0
    rep = json.loads(p.read_text())
    n = 0
    for f in rep.get("files", []):
        if f.get("file", "").endswith("correlated.pqt"):
            n += sum(1 for c in f["cases"] if c["status"] == "not_implemented")
    return n


# ------------------------------------------------------------------ record & import

def record(run_id: str) -> Path:
    """Copies the durable run record into experiments/runs/<run_id>/."""
    rd = run_dir(run_id)
    dest = RECORDS / run_id
    dest.mkdir(parents=True, exist_ok=True)
    for f in ["manifest.json", "telemetry.json", "validation.json", "conformance.json", "conformance-http.json",
              "conformance-modes.json", "http-suite.json", "kernel-bench.json"]:
        if (rd / f).exists():
            shutil.copy(rd / f, dest / f)
    if (rd / "native-arm").is_dir():
        shutil.copytree(rd / "native-arm", dest / "native-arm", dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("arm-remote.log"))
    if (rd / "validation-history").is_dir():
        shutil.copytree(rd / "validation-history", dest / "validation-history", dirs_exist_ok=True)
    if (rd / "transcript.jsonl").exists():
        with open(rd / "transcript.jsonl", "rb") as src, gzip.open(dest / "transcript.jsonl.gz", "wb") as dst:
            shutil.copyfileobj(src, dst)
    if (rd / "workspace/TASK.md").exists():
        shutil.copy(rd / "workspace/TASK.md", dest / "TASK.md")
    return dest


def import_run(run_id: str, merge: bool) -> str:
    """Applies the agent's commits (language dir only) onto a branch in the main repo."""
    rd = run_dir(run_id)
    m = load_manifest(run_id)
    lang = m["language"]
    ws = rd / "workspace"
    patches = rd / "patches"
    if patches.exists():
        shutil.rmtree(patches)
    patches.mkdir()
    wd = m.get("work_dir") or f"implementations/{lang}"
    sh(["git", "format-patch", "-q", "-o", str(patches), f"{m['baseline_commit']}..HEAD", "--", wd], cwd=ws)
    branch = f"track-{m['track'].lower()}/{lang}/{m['task']}/a{m['attempt']}"
    current = git(["rev-parse", "--abbrev-ref", "HEAD"], ROOT)
    if git(["status", "--porcelain"], ROOT):
        raise SystemExit("main repository has uncommitted changes; commit first")
    git(["branch", "-f", branch, m["repo_ref"]], ROOT)
    git(["checkout", "-q", branch], ROOT)
    try:
        files = sorted(patches.glob("*.patch"))
        if files:
            sh(["git", "am", "-q", "--committer-date-is-author-date", *map(str, files)], cwd=ROOT)
        # Squash-safe check: the branch must differ from repo_ref only inside the language dir.
        changed = git(["diff", "--name-only", m["repo_ref"], "HEAD"], ROOT).splitlines()
        bad = [c for c in changed if not c.startswith(wd + "/")]
        if bad:
            raise SystemExit(f"isolation violation: {bad[:5]}")
    except BaseException:
        sh(["git", "am", "--abort"], cwd=ROOT, check=False)
        git(["checkout", "-q", current], ROOT)
        raise
    git(["checkout", "-q", current], ROOT)
    m["import_branch"] = branch
    if merge:
        sh(["git", "merge", "--no-ff", "-q", "-m", f"merge: {m['track']}/{lang}/{m['task']} attempt {m['attempt']} ({m.get('outcome')})", branch], cwd=ROOT)
        m["merged_into"] = current
    save_manifest(run_id, m)
    return branch


# ------------------------------------------------------------------ wave

def full_cycle(run_id: str, timeout_min: int, budget: float, max_turns: int | None, log) -> dict:
    log(f"[{run_id}] agent queued (usage gate, then launch)")
    run(run_id, timeout_min, budget, max_turns)
    log(f"[{run_id}] agent finished; collecting telemetry")
    tel = telemetry(run_id)
    log(f"[{run_id}] validating (clean clone, sandboxed)")
    v = validate(run_id)
    record(run_id)
    log(f"[{run_id}] outcome={v['outcome']} cost=${tel.get('cost_usd')} turns={tel.get('agent_turns')} wall={tel['time']['wall_seconds']}s")
    return {"run_id": run_id, "outcome": v["outcome"], "telemetry": tel, "validation": v}


def wave(task: str, langs: list[str], track: str, attempt: int, seed: int, timeout_min: int, budget: float,
         max_turns: int | None, parallel: int) -> dict:
    rng = random.Random(seed)
    order = list(langs)
    rng.shuffle(order)
    wave_id = f"wave-{track.lower()}-{task}-a{attempt}-{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    lock = threading.Lock()
    logf = RECORDS / f"{wave_id}.log"
    RECORDS.mkdir(parents=True, exist_ok=True)

    def log(msg: str) -> None:
        with lock:
            line = f"{now()} {msg}"
            print(line, flush=True)
            with open(logf, "a") as fh:
                fh.write(line + "\n")

    run_ids = []
    for lang in order:
        run_ids.append(prepare(lang, task, track, attempt, None, wave_id))
        time.sleep(1.1)  # distinct timestamps
    wm = {"wave_id": wave_id, "task": task, "track": track, "attempt": attempt, "seed": seed, "order": order,
          "run_ids": run_ids, "started": now(), "parallel": parallel,
          "limits": {"timeout_min": timeout_min, "budget_usd": budget, "max_turns": max_turns},
          "loadavg_start": os.getloadavg()}
    (RECORDS / f"{wave_id}.json").write_text(json.dumps(wm, indent=1) + "\n")
    log(f"wave {wave_id}: order={order}")
    results = []
    with cf.ThreadPoolExecutor(max_workers=parallel) as ex:
        futs = {}
        for rid in run_ids:
            futs[ex.submit(full_cycle, rid, timeout_min, budget, max_turns, log)] = rid
            time.sleep(5)  # stagger starts
        for fut in cf.as_completed(futs):
            try:
                results.append(fut.result())
            except Exception as e:  # noqa: BLE001
                log(f"[{futs[fut]}] orchestration error: {e!r}")
                results.append({"run_id": futs[fut], "outcome": "orchestration_error", "error": repr(e)})
    wm["finished"] = now()
    wm["loadavg_end"] = os.getloadavg()
    wm["results"] = [{"run_id": r["run_id"], "outcome": r["outcome"]} for r in results]
    (RECORDS / f"{wave_id}.json").write_text(json.dumps(wm, indent=1) + "\n")
    log(f"wave {wave_id} finished: " + ", ".join(f"{r['run_id'].split('-')[2]}={r['outcome']}" for r in results))
    return wm


def status() -> None:
    rows = []
    for d in sorted(RECORDS.glob("*/manifest.json")):
        m = json.loads(d.read_text())
        tel = json.loads((d.parent / "telemetry.json").read_text()) if (d.parent / "telemetry.json").exists() else {}
        rows.append((m["run_id"], m.get("outcome") or m.get("status"), tel.get("cost_usd"), tel.get("agent_turns"),
                     (tel.get("time") or {}).get("wall_seconds")))
    live = sorted(p.name for p in RUN_ROOT.glob("*") if p.is_dir() and not (RECORDS / p.name).exists()) if RUN_ROOT.exists() else []
    print(f"{'run_id':60} {'outcome':20} {'cost':>8} {'turns':>6} {'wall_s':>8}")
    for r in rows:
        print(f"{r[0]:60} {str(r[1]):20} {str(r[2]):>8} {str(r[3]):>6} {str(r[4]):>8}")
    for l in live:
        print(f"{l:60} {'(in progress / unrecorded)':20}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--lang", required=True)
    p.add_argument("--task", required=True)
    p.add_argument("--track", default="A")
    p.add_argument("--attempt", type=int, default=1)
    p.add_argument("--base-ref")
    for name in ("run", "validate", "telemetry", "record", "cycle"):
        q = sub.add_parser(name)
        q.add_argument("run_id")
        q.add_argument("--timeout-min", type=int, default=300)
        q.add_argument("--budget-usd", type=float, default=150.0)
        q.add_argument("--max-turns", type=int)
    q = sub.add_parser("import")
    q.add_argument("run_id")
    q.add_argument("--merge", action="store_true")
    w = sub.add_parser("wave")
    w.add_argument("--task", required=True)
    w.add_argument("--langs", default=",".join(LANGS))
    w.add_argument("--track", default="A")
    w.add_argument("--attempt", type=int, default=1)
    w.add_argument("--seed", type=int, default=int(time.time()))
    w.add_argument("--timeout-min", type=int, default=300)
    w.add_argument("--budget-usd", type=float, default=150.0)
    w.add_argument("--max-turns", type=int)
    w.add_argument("--parallel", type=int, default=6)
    sub.add_parser("status")
    sub.add_parser("watchdog", help="stop running agents that approach the usage limit or use overage")
    a = ap.parse_args()
    if a.cmd == "prepare":
        prepare(a.lang, a.task, a.track, a.attempt, a.base_ref, None)
    elif a.cmd == "run":
        print(json.dumps(run(a.run_id, a.timeout_min, a.budget_usd, a.max_turns), indent=1))
    elif a.cmd == "telemetry":
        print(json.dumps(telemetry(a.run_id), indent=1))
    elif a.cmd == "validate":
        print(json.dumps(validate(a.run_id), indent=1))
    elif a.cmd == "record":
        print(record(a.run_id))
    elif a.cmd == "cycle":
        print(json.dumps(full_cycle(a.run_id, a.timeout_min, a.budget_usd, a.max_turns, print)["outcome"]))
    elif a.cmd == "import":
        print(import_run(a.run_id, a.merge))
    elif a.cmd == "wave":
        wave(a.task, a.langs.split(","), a.track, a.attempt, a.seed, a.timeout_min, a.budget_usd, a.max_turns, a.parallel)
    elif a.cmd == "status":
        status()
    elif a.cmd == "watchdog":
        watchdog()
    return 0


if __name__ == "__main__":
    sys.exit(main())
