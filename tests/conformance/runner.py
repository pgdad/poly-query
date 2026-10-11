#!/usr/bin/env python3
"""PolyQuery conformance runner.

Runs .pqt suites against any engine through its public protocol and produces a
machine-readable JSON report (plus a short text summary).

Examples:
  runner.py --engine implementations/go/bin/polyquery
  runner.py --engine ... --phase 1 --phase 2 --report results/correctness/go.json
  runner.py --engine ... --transport http          # Phase 4: same cases over HTTP
  runner.py --engine ... --modes                   # Phase 5: option matrix
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import json
import os
import shutil
import struct
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from engine import EngineError, HttpEngine, SessionEngine, engine_info  # noqa: E402
from pqt import PqtFile, PqtSyntaxError, Step, parse_file, rows_match, subset_match, walk_plan  # noqa: E402

HERE = Path(__file__).resolve().parent
PUBLIC_CASES = HERE / "cases"
HIDDEN_CASES = HERE / "hidden" / "cases"
FIXTURES = HERE / "fixtures"

MODE_MATRIX = [
    {"mode": "row", "join": "nested_loop", "threads": 1, "optimize": False},
    {"mode": "row", "join": "hash", "threads": 1, "optimize": True},
    {"mode": "row", "join": "merge", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "hash", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "merge", "threads": 1, "optimize": False},
    {"mode": "vectorized", "join": "nested_loop", "threads": 4, "optimize": True},
]
MODE_CAPS = {"exec.row", "exec.vectorized", "exec.parallel", "join.hash", "join.merge", "join.nested_loop"}


def discover(dirs: list[Path], phases: set[int] | None, name_filter: str | None) -> list[tuple[Path, PqtFile | Exception]]:
    out = []
    for d in dirs:
        if not d.exists():
            continue
        for p in sorted(d.rglob("*.pqt")):
            if name_filter and name_filter not in str(p.relative_to(d)):
                continue
            try:
                f = parse_file(p)
            except PqtSyntaxError as e:
                out.append((p, e))
                continue
            if phases and f.phase not in phases:
                continue
            out.append((p, f))
    return out


def check_step(step: Step, resp: dict) -> tuple[str, str]:
    """Returns (status, message) for a case step given the engine response."""
    ok = resp.get("ok") is True
    err = resp.get("error") if isinstance(resp.get("error"), dict) else {}
    code = err.get("code")
    if not ok and code == "INTERNAL_ERROR":
        return "fail", f"INTERNAL_ERROR: {err.get('message', '')[:300]}"

    if step.kind in ("load", "data", "error", "open", "save") or (step.kind == "statement" and step.expect_error):
        if step.expect_error:
            if ok:
                return "fail", f"expected error {step.expect_error}, got success"
            if code != step.expect_error:
                return "fail", f"expected error {step.expect_error}, got {code}: {err.get('message', '')[:200]}"
            return "pass", ""
    if step.kind in ("load", "data", "statement", "open", "save"):
        return ("pass", "") if ok else ("fail", f"unexpected error {code}: {err.get('message', '')[:300]}")

    if step.kind == "corrupt":
        if ok:
            return "fail", f"corrupt file was opened and fully read without {step.expect_error}"
        if code != step.expect_error:
            return "fail", f"expected {step.expect_error}, got {code}: {err.get('message', '')[:200]}"
        return "pass", ""

    if step.kind == "query":
        if not ok:
            return "fail", f"unexpected error {code}: {err.get('message', '')[:300]}"
        cols = resp.get("columns")
        rows = resp.get("rows")
        if step.rowcount is not None:
            rc = resp.get("row_count")
            return ("pass", "") if rc == step.rowcount else ("fail", f"row_count {rc} != {step.rowcount}")
        if not isinstance(cols, list) or not isinstance(rows, list):
            return "fail", "response lacks columns/rows arrays"
        try:
            got = [(c["name"], c["type"]) for c in cols]
        except (KeyError, TypeError):
            return "fail", "malformed columns metadata"
        exp = step.columns or []
        if [t for _, t in got] != [t for _, t in exp] or [n for n, _ in got] != [n for n, _ in exp]:
            return "fail", f"columns: expected {exp}, got {got}"
        if resp.get("row_count") != len(rows):
            return "fail", f"row_count {resp.get('row_count')} disagrees with {len(rows)} rows"
        if any(not isinstance(r, list) or len(r) != len(exp) for r in rows):
            return "fail", "row arity mismatch"
        good, msg = rows_match(step.rows or [], rows, [t for _, t in exp], step.ordered)
        return ("pass", "") if good else ("fail", msg)

    if step.kind == "request":
        for kind, arg in step.expectations:
            if kind == "ok" and not ok:
                return "fail", f"unexpected error {code}: {err.get('message', '')[:300]}"
            if kind == "error":
                if ok:
                    return "fail", f"expected error {arg}, got success"
                if code != arg:
                    return "fail", f"expected error {arg}, got {code}"
            if kind == "match":
                good, msg = subset_match(arg, resp)
                if not good:
                    return "fail", msg
        return "pass", ""

    if step.kind == "explain":
        if not ok:
            return "fail", f"unexpected error {code}: {err.get('message', '')[:300]}"
        nodes = list(walk_plan(resp.get("plan")))
        if not nodes:
            return "fail", "missing plan tree"
        for kind, args in step.expectations:
            if kind == "index-scan":
                if not any(n.get("op") == "IndexScan" and str(n.get("index", "")).lower() == args[0].lower() for n in nodes):
                    return "fail", f"no IndexScan using {args[0]}"
            elif kind == "no-index-scan":
                if any(n.get("op") == "IndexScan" for n in nodes):
                    return "fail", "unexpected IndexScan"
            elif kind == "scan-columns":
                table, want = args[0].lower(), {c.lower() for c in args[1].split(",") if c}
                scans = [n for n in nodes if n.get("op") in ("TableScan", "IndexScan") and str(n.get("table", "")).lower() == table]
                if not scans:
                    return "fail", f"no scan of {table}"
                for s in scans:
                    have = {str(c).lower() for c in s.get("columns") or []}
                    if have != want:
                        return "fail", f"scan of {table} reads {sorted(have)}, expected {sorted(want)}"
            elif kind == "node":
                if not any(n.get("op") == args[0] for n in nodes):
                    return "fail", f"no {args[0]} node"
            elif kind == "no-node":
                if any(n.get("op") == args[0] for n in nodes):
                    return "fail", f"unexpected {args[0]} node"
            else:
                return "error", f"unknown explain expectation {kind}"
        return "pass", ""
    return "error", f"unknown step kind {step.kind}"


def check_pqcf_version(path: Path, expected: int) -> tuple[str, str]:
    """Checks the header and metadata format_version of a file the engine saved (not a full validation)."""
    try:
        data = path.read_bytes()
    except OSError as e:
        return "fail", f"cannot read {path.name}: {e}"
    if len(data) < 20 or data[:4] != b"PQCF" or data[-4:] != b"PQCF":
        return "fail", f"{path.name}: not a PQCF file"
    header = struct.unpack_from("<H", data, 4)[0]
    mlen = struct.unpack_from("<I", data, len(data) - 12)[0]
    try:
        meta = json.loads(data[len(data) - 12 - mlen:len(data) - 12])
    except ValueError:
        return "fail", f"{path.name}: metadata is not JSON"
    got = (header, meta.get("format_version") if isinstance(meta, dict) else None)
    if got != (expected, expected):
        return "fail", f"{path.name}: header/metadata format_version {got}, expected {expected}"
    return "pass", ""


def step_request(step: Step, overlay: dict | None) -> dict:
    if step.kind in ("load", "data", "request", "open", "save", "corrupt"):
        return dict(step.request or {})
    opts = dict(step.options or {})
    if overlay and step.kind in ("query", "error", "explain"):
        merged = dict(overlay)
        merged.update(opts)   # test-specific options win
        opts = merged
    req: dict = {"op": "explain" if step.kind == "explain" else "query", "sql": step.sql}
    if opts:
        req["options"] = opts
    return req


def run_file(f: PqtFile, launcher: str, caps: set[str], args: argparse.Namespace,
             overlay: dict | None, label: str) -> dict:
    try:
        rel = str(f.path.relative_to(HERE))
    except ValueError:
        rel = str(f.path)
    missing = [c for c in f.requires if c not in caps]
    cases = [s for s in f.steps if s.is_case]
    result: dict = {"file": rel, "phase": f.phase, "requires": f.requires, "variant": label,
                    "cases": [], "missing_capabilities": missing}
    if missing:
        result["status"] = "not_implemented"
        result["cases"] = [{"line": s.line, "kind": s.kind, "status": "not_implemented",
                            "message": "missing capabilities: " + " ".join(missing)} for s in cases]
        return result

    tmp = Path(tempfile.mkdtemp(prefix="pqconf-"))
    (tmp / "fixtures").symlink_to(FIXTURES)
    (tmp / "out").mkdir()
    stderr_path = Path(args.logs) / (rel.replace("/", "__") + f".{label}.stderr") if args.logs else None
    engine = None
    t_file = time.monotonic()
    try:
        cls = HttpEngine if args.transport == "http" else SessionEngine
        try:
            eargs = list(f.engine_args) + (["--native-kernels", str(Path(args.native).resolve())] if args.native else [])
            engine = cls(launcher, tmp, eargs, timeout=args.timeout, stderr_path=stderr_path)
        except EngineError as e:
            result["status"] = "error"
            result["cases"] = [{"line": s.line, "kind": s.kind, "status": "error", "message": f"engine start: {e}"} for s in cases]
            return result
        broken: str | None = None
        for k, step in enumerate(f.steps):
            entry = {"line": step.line, "kind": step.kind}
            if broken:
                if step.is_case:
                    result["cases"].append({**entry, "status": "error", "message": broken})
                continue
            if step.kind == "pqcf":
                status, msg = check_pqcf_version(tmp / step.request["path"], step.request["format_version"])
                result["cases"].append({**entry, "status": status, **({"message": msg} if msg else {})})
                continue
            req = step_request(step, overlay)
            # A request step may test id echoing with its own id (any JSON value); keep it.
            if not (step.kind == "request" and step.request and "id" in step.request):
                req["id"] = k
            expect_id = req["id"]
            t0 = time.monotonic()
            try:
                resp = engine.request(req)
            except EngineError as e:
                broken = f"engine failure at line {step.line}: {e}"
                if step.is_case:
                    result["cases"].append({**entry, "status": "error", "message": str(e),
                                            "elapsed_ms": round((time.monotonic() - t0) * 1000, 2)})
                continue
            if step.kind == "corrupt" and resp.get("ok") is True and resp.get("id") == expect_id:
                try:
                    resp = engine.request({"op": "query", "id": expect_id,
                                           "sql": f'SELECT * FROM "{step.request["table"]}"'})
                except EngineError as e:
                    broken = f"engine failure at line {step.line}: {e}"
                    result["cases"].append({**entry, "status": "error", "message": str(e)})
                    continue
            elapsed = round((time.monotonic() - t0) * 1000, 2)
            if resp.get("id") != expect_id:
                status, msg = "fail", f"response id {resp.get('id')!r} != request id {expect_id!r}"
            else:
                status, msg = check_step(step, resp)
            if step.setup:
                if status != "pass":
                    broken = f"setup failed at line {step.line}: {msg}"
                continue
            entry.update({"status": status, "elapsed_ms": elapsed})
            if msg:
                entry["message"] = msg
            if status != "pass" and args.verbose:
                entry["sql"] = step.sql or json.dumps(step.request)[:500]
            result["cases"].append(entry)
        result["status"] = "ran"
    finally:
        if engine:
            engine.close()
        shutil.rmtree(tmp, ignore_errors=True)
    result["seconds"] = round(time.monotonic() - t_file, 3)
    return result


def summarize(files: list[dict]) -> dict:
    by_phase: dict = {}
    for fr in files:
        ph = by_phase.setdefault(str(fr["phase"]), {"total": 0, "pass": 0, "fail": 0, "error": 0, "not_implemented": 0})
        for c in fr["cases"]:
            ph["total"] += 1
            ph[c["status"]] = ph.get(c["status"], 0) + 1
    total = {k: sum(p[k] for p in by_phase.values()) for k in ("total", "pass", "fail", "error", "not_implemented")}
    return {"by_phase": by_phase, "total": total}


OPTIONAL_CAPS = {"sql.correlated_subquery"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engine", required=True, help="path to bin/polyquery launcher")
    ap.add_argument("--phase", type=int, action="append", help="restrict to phase(s)")
    ap.add_argument("--filter", help="substring filter on case file path")
    ap.add_argument("--include-hidden", action="store_true", help="also run hidden acceptance cases")
    ap.add_argument("--hidden-only", action="store_true")
    ap.add_argument("--transport", choices=["session", "http"], default="session")
    ap.add_argument("--modes", action="store_true", help="run Phase 1-3 cases under the Phase 5 option matrix")
    ap.add_argument("--jobs", type=int, default=max(1, min(8, (os.cpu_count() or 2) // 2)))
    ap.add_argument("--timeout", type=float, default=30.0, help="per-request timeout seconds")
    ap.add_argument("--report", help="write JSON report here")
    ap.add_argument("--logs", help="directory for engine stderr logs")
    ap.add_argument("--native", metavar="LIBPQKERNELS",
                    help="pass --native-kernels LIB to the engine and run every query with native: true "
                         "(requires capability native.kernels; combinable with --modes)")
    ap.add_argument("--claimed", action="store_true",
                    help="restrict to the phases the engine claims (capability phaseN); not_implemented is "
                         "tolerated only in files that need an optional capability the engine does not claim")
    ap.add_argument("--ci", action="store_true",
                    help="exit status ignores not_implemented cases (still reported); fails on fail/error")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--quiet", "-q", action="store_true")
    args = ap.parse_args()

    launcher = str(Path(args.engine).resolve())
    if not os.access(launcher, os.X_OK):
        print(f"engine launcher not executable: {launcher}", file=sys.stderr)
        return 2
    if args.logs:
        Path(args.logs).mkdir(parents=True, exist_ok=True)

    info = engine_info(launcher)
    caps = set(info["capability_set"])
    dirs = [] if args.hidden_only else [PUBLIC_CASES]
    if args.include_hidden or args.hidden_only:
        dirs.append(HIDDEN_CASES)
    phases = set(args.phase) if args.phase else None
    if args.claimed:
        claimed = {n for n in range(1, 6) if f"phase{n}" in caps}
        phases = claimed & phases if phases else claimed
    found = discover(dirs, phases, args.filter)

    syntax_errors = [{"file": str(p), "error": str(e)} for p, e in found if isinstance(e, Exception)]
    files = [f for _, f in found if not isinstance(f, Exception)]
    # Requirement-change suites (spec/changes/) apply only to engines that adopted the change.
    files = [f for f in files if all(c in caps for c in f.requires if c.startswith("change."))]

    jobs: list[tuple[PqtFile, dict | None, str]] = []
    if args.modes:
        mode_missing = sorted(MODE_CAPS - caps)
        for f in files:
            if f.phase > 3:
                continue
            for k, ov in enumerate(MODE_MATRIX):
                jobs.append((f, {**ov, "native": True} if args.native else ov, f"modes{k}" + ("-native" if args.native else "")))
    else:
        mode_missing = []
        jobs = [(f, {"native": True} if args.native else None, args.transport + ("-native" if args.native else ""))
                for f in files]
    if args.native and "native.kernels" not in caps:
        mode_missing = sorted(set(mode_missing) | {"native.kernels"})

    started = dt.datetime.now(dt.timezone.utc).isoformat()
    results: list[dict] = []
    t0 = time.monotonic()
    if mode_missing:
        for f, ov, label in jobs:
            results.append({"file": str(f.path.name), "phase": f.phase, "variant": label, "status": "not_implemented",
                            "cases": [{"line": s.line, "kind": s.kind, "status": "not_implemented",
                                       "message": "missing capabilities: " + " ".join(mode_missing)}
                                      for s in f.steps if s.is_case]})
    else:
        with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            futs = [ex.submit(run_file, f, launcher, caps, args, ov, label) for f, ov, label in jobs]
            for fut in cf.as_completed(futs):
                r = fut.result()
                results.append(r)
                if not args.quiet:
                    n = len(r["cases"])
                    p = sum(1 for c in r["cases"] if c["status"] == "pass")
                    print(f"  {r['file']} [{r['variant']}]: {p}/{n} {r['status']}", flush=True)
    results.sort(key=lambda r: (r["phase"], r["file"], r["variant"]))
    summary = summarize(results)

    phase_passed = {}
    for ph, s in summary["by_phase"].items():
        phase_passed[ph] = s["total"] > 0 and s["pass"] == s["total"]
    report = {
        "schema": "polyquery-conformance-report/1",
        "started": started,
        "seconds": round(time.monotonic() - t0, 2),
        "engine": info,
        "transport": args.transport,
        "modes": args.modes,
        "include_hidden": bool(args.include_hidden or args.hidden_only),
        "syntax_errors": syntax_errors,
        "summary": summary,
        "phase_passed": phase_passed,
        "files": results,
    }
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps(report, indent=1) + "\n")

    t = summary["total"]
    print(f"engine: {(info.get('version') or {}).get('engine', '?')} caps={len(caps)}")
    for ph, s in sorted(summary["by_phase"].items()):
        print(f"  phase {ph}: {s['pass']}/{s['total']} pass, {s['fail']} fail, {s['error']} error, {s['not_implemented']} not implemented")
    print(f"  TOTAL: {t['pass']}/{t['total']} pass")
    if syntax_errors:
        print(f"  {len(syntax_errors)} test files have syntax errors:", file=sys.stderr)
        for s in syntax_errors:
            print(f"    {s['error']}", file=sys.stderr)
    if args.verbose:
        for r in results:
            for c in r["cases"]:
                if c["status"] in ("fail", "error"):
                    print(f"  FAIL {r['file']}:{c['line']} [{r['variant']}] {c.get('message', '')}")
                    if c.get("sql"):
                        print("       " + c["sql"].replace("\n", "\n       "))
    if args.ci:
        return 0 if t["fail"] == 0 and t["error"] == 0 and not syntax_errors else 1
    if args.claimed:
        bad = [c for r in results for c in r["cases"] if c["status"] in ("fail", "error") or
               (c["status"] == "not_implemented" and not (set(r["requires"]) & OPTIONAL_CAPS - caps))]
        return 0 if t["total"] > 0 and not bad and not syntax_errors else 1
    return 0 if t["total"] > 0 and t["pass"] == t["total"] and not syntax_errors else 1


if __name__ == "__main__":
    sys.exit(main())
