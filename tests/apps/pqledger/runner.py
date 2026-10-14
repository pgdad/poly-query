#!/usr/bin/env python3
"""Black-box test runner for pqledger (spec/apps/pqledger.md) and pq-embed-demo
(spec/apps/embedding.md §5).

  runner.py --app implementations/<lang>/bin/pqledger [--embed-demo implementations/<lang>/bin/pq-embed-demo]
            [--cases DIR ...] [--filter TEXT] [--trace] [--report out.json] [-v]

Each case (cases/*.json) runs in a fresh temporary directory: its files are written, an optional
ledger is seeded (PQCF files written by this runner, so a ledger from "another implementation"
is read), then each step runs `pqledger ARGS` with that directory as the working directory
and HOME. A step compares the exit status, stdout (exactly, when given), and for failures that
stdout is empty and stderr starts with `pqledger: error: `. A `ledger` step compares the PQCF
files of the ledger with the expected rows; a `write` step (re)writes files between commands.

--trace runs every pqledger step under strace and fails a step that connects a network or
UNIX socket, or executes a program named polyquery or with argument `session`/`serve` (the
application must use the engine in-process, spec/apps/pqledger.md §1).
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pqcf_mini  # noqa: E402

HERE = Path(__file__).resolve().parent
TABLES = {
    "transactions": [("id", "INT64"), ("account", "STRING"), ("date", "DATE"), ("description", "STRING"),
                     ("merchant", "STRING"), ("amount", "DECIMAL(18,2)"), ("batch", "INT64")],
    "batches": [("batch", "INT64"), ("account", "STRING"), ("file", "STRING"), ("imported", "INT64"),
                ("duplicates", "INT64")],
    "overrides": [("id", "INT64"), ("category", "STRING")],
}
STEP_TIMEOUT = 120


def typed(v, typ: str):
    if v is None:
        return None
    if typ == "DATE":
        return dt.date.fromisoformat(v)
    if typ.startswith("DECIMAL"):
        return Decimal(v)
    return v


def jsonable(v):
    if isinstance(v, dt.date):
        return v.isoformat()
    if isinstance(v, Decimal):
        return f"{v:f}"
    return v


def write_files(root: Path, case: dict) -> None:
    for rel, text in (case.get("files") or {}).items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode("utf-8"))
    for rel, b64 in (case.get("files_b64") or {}).items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(base64.b64decode(b64))
    for g in case.get("generate") or []:
        # Large inputs come from the deterministic generator instead of being stored in the case.
        gen = HERE.parents[2] / "datasets/generators/bankgen.py"
        subprocess.run([sys.executable, str(gen), "--style", g["style"], "--from", g["from"], "--to", g["to"],
                        "--seed", str(g.get("seed", 1)), "--per-month", str(g["per_month"]),
                        "--out", str(root / g["path"])], check=True)
    seed = case.get("seed_ledger")
    if seed:
        d = root / seed["dir"]
        d.mkdir(parents=True, exist_ok=True)
        for t, cols in TABLES.items():
            rows = [[typed(v, ty) for v, (_, ty) in zip(r, cols)] for r in seed.get(t, [])]
            pqcf_mini.write(d / f"{t}.pqcf", t, cols, rows, encoding=seed.get("encoding", "plain"))


def traced(cmd: list[str], log: Path) -> list[str]:
    return ["strace", "-f", "-qq", "-e", "trace=execve,connect", "-e", "signal=none", "-o", str(log), *cmd]


def trace_violations(log: Path) -> list[str]:
    bad = []
    for line in log.read_text(errors="replace").splitlines():
        if " connect(" in line:
            # Name-service lookups may try local daemons (nscd, systemd-userdb); everything else counts,
            # including failed attempts.
            local = "AF_UNIX" in line and any(x in line for x in ("/nscd/", "/systemd/userdb/"))
            if ("AF_INET" in line or "AF_UNIX" in line) and not local:
                bad.append("socket connect: " + line.split(" ", 1)[-1][:160])
        m = re.search(r'execve\("([^"]+)", \[(.*?)\]', line)
        if m and "= -1" not in line:
            prog, argv = m.group(1), re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2))
            if Path(prog).name == "polyquery" or (len(argv) > 1 and argv[1] in ("session", "serve")):
                bad.append("engine process started: " + " ".join(argv)[:160])
    return bad


def run_case(app: str, case: dict, trace: bool, keep: bool) -> dict:
    tmp = Path(tempfile.mkdtemp(prefix="pqledger-"))
    res = {"case": case["name"], "steps": [], "verdict": "pass"}
    try:
        write_files(tmp, case)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(tmp), "LANG": "C.UTF-8",
               "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
        for k in ("JAVA_HOME", "SBCL_HOME", "GOCACHE", "GOPATH", "CARGO_HOME", "RUSTUP_HOME"):
            if k in os.environ:
                env[k] = os.environ[k]
        env.update(case.get("env") or {})
        for n, step in enumerate(case["steps"], 1):
            fails = []
            if "write" in step:
                write_files(tmp, {"files": step["write"]})
                continue
            if "ledger" in step:
                exp = step["ledger"]
                d = tmp / exp["dir"]
                for t, cols in TABLES.items():
                    if t not in exp:
                        continue
                    try:
                        got_cols, rows = pqcf_mini.read(d / f"{t}.pqcf")
                    except (OSError, pqcf_mini.PqcfError, ValueError, KeyError) as e:
                        fails.append(f"{t}.pqcf: {e}")
                        continue
                    if [(a, b) for a, b in got_cols] != cols:
                        fails.append(f"{t}.pqcf columns {got_cols} != {cols}")
                        continue
                    want = [[typed(v, ty) for v, (_, ty) in zip(r, cols)] for r in exp[t]]
                    key = (lambda r: r[0])
                    if sorted(rows, key=key) != sorted(want, key=key):
                        fails.append(f"{t}.pqcf rows differ: got {json.dumps([[jsonable(v) for v in r] for r in rows][:20])}")
                res["steps"].append({"step": n, "ledger": True, "ok": not fails, "failures": fails})
                if fails:
                    res["verdict"] = "fail"
                continue
            cmd = [app, *step["args"]]
            log = tmp / f".strace-{n}.log"
            t0 = time.monotonic()
            try:
                p = subprocess.run(traced(cmd, log) if trace else cmd, cwd=tmp / step.get("cwd", "."), env=env,
                                   capture_output=True, timeout=step.get("timeout", STEP_TIMEOUT),
                                   input=step.get("stdin", "").encode())
                rc, out, err = p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
            except subprocess.TimeoutExpired:
                rc, out, err = None, "", ""
                fails.append(f"timeout after {step.get('timeout', STEP_TIMEOUT)} s")
            secs = round(time.monotonic() - t0, 2)
            if rc is not None:
                if rc != step["exit"]:
                    fails.append(f"exit {rc}, expected {step['exit']}")
                if "stdout" in step and out != step["stdout"]:
                    fails.append("stdout differs")
                if step["exit"] not in (0, 3):
                    if out:
                        fails.append("stdout not empty on failure")
                    if not err.startswith("pqledger: error: "):
                        fails.append("stderr does not start with 'pqledger: error: '")
                for s in step.get("stderr_contains", []):
                    if s not in err:
                        fails.append(f"stderr lacks {s!r}")
                if trace and log.exists():
                    fails += trace_violations(log)
            r = {"step": n, "args": step["args"], "ok": not fails, "seconds": secs, "failures": fails}
            if fails:
                r.update({"exit": rc, "stdout": out[-4000:], "stderr": err[-2000:],
                          "expected_stdout": step.get("stdout")})
                res["verdict"] = "fail"
            res["steps"].append(r)
    finally:
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)
    return res


def run_embed(demo: str, case: dict) -> dict:
    tmp = Path(tempfile.mkdtemp(prefix="pqembed-"))
    try:
        write_files(tmp, case)
        p = subprocess.run([demo, str(tmp), *case["args"]], capture_output=True, timeout=STEP_TIMEOUT)
        out, err = p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
        fails = []
        if p.returncode != case["exit"]:
            fails.append(f"exit {p.returncode}, expected {case['exit']}")
        if "stdout" in case and out != case["stdout"]:
            fails.append("stdout differs")
        for s in case.get("stderr_contains", []):
            if s not in err:
                fails.append(f"stderr lacks {s!r}")
        r = {"case": case["name"], "verdict": "fail" if fails else "pass", "failures": fails}
        if fails:
            r.update({"stdout": out[-4000:], "stderr": err[-2000:], "expected_stdout": case.get("stdout")})
        return r
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def load_cases(dirs: list[Path], filt: str) -> list[dict]:
    out = []
    for d in dirs:
        for f in sorted(d.glob("*.json")):
            c = json.loads(f.read_text())
            c.setdefault("name", f.stem)
            if not filt or filt in c["name"]:
                out.append(c)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", required=True)
    ap.add_argument("--embed-demo")
    ap.add_argument("--cases", action="append", type=Path)
    ap.add_argument("--filter", default="")
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the temporary directories")
    ap.add_argument("--report")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    app = str(Path(a.app).resolve())
    if a.trace and not shutil.which("strace"):
        print("--trace needs strace", file=sys.stderr)
        return 2
    dirs = a.cases or [HERE / "cases"]
    results = [run_case(app, c, a.trace, a.keep) for c in load_cases(dirs, a.filter)]
    embed = []
    if a.embed_demo:
        edirs = [d.parent / "embed" if d.name == "cases" else d / "embed" for d in dirs]
        embed = [run_embed(str(Path(a.embed_demo).resolve()), c) for c in load_cases([d for d in edirs if d.is_dir()], a.filter)]
    for r in results + embed:
        if r["verdict"] != "pass" or a.verbose:
            print(f"{r['verdict'].upper():4} {r['case']}")
            for s in r.get("steps", []):
                if not s["ok"]:
                    print(f"     step {s['step']} {' '.join(s.get('args', ['ledger']))}: {'; '.join(s['failures'])}")
                    if a.verbose and "stdout" in s:
                        print("     --- got ---\n" + s["stdout"] + "     --- expected ---\n" + str(s["expected_stdout"]))
            for f in r.get("failures", []) if "steps" not in r else []:
                print(f"     {f}")
    def summ(rs):
        return {"total": len(rs), "pass": sum(r["verdict"] == "pass" for r in rs)}
    out = {"schema": "polyquery-app-tests/1", "app": app, "embed_demo": a.embed_demo, "trace": a.trace,
           "summary": {"cases": summ(results), "embed": summ(embed)}, "results": results, "embed": embed}
    s = out["summary"]
    print(f"pqledger cases: {s['cases']['pass']}/{s['cases']['total']} pass; "
          f"embed-demo cases: {s['embed']['pass']}/{s['embed']['total']} pass")
    if a.report:
        Path(a.report).write_text(json.dumps(out, indent=1) + "\n")
    ok = s["cases"]["pass"] == s["cases"]["total"] and s["embed"]["pass"] == s["embed"]["total"]
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
