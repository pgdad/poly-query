#!/usr/bin/env python3
"""Large-data probe: the benchmark workload at 10m rows, and memory pressure without a crash.

  large_data_probe.py --engine implementations/<lang>/bin/polyquery [--scale 10m] [--copies 6]
                      [--guard-gib 120] [--report out.json] [--require-pass]

Black-box, through the session protocol. The spec requirements tested:
  * an engine MUST NOT crash, hang or exit on any request (errors.md); out-of-memory conditions
    are reported as RESOURCE_LIMIT, not by dying;
  * default ingestion limits allow at least 2 GiB of input and 200,000,000 rows
    (data-types/ingestion.md §3), so the 10m benchmark tables (at most 0.9 GB each) must load;
  * --max-query-memory-mb and --max-ingest-bytes are enforced with RESOURCE_LIMIT
    (sql/semantics.md §15, protocol.md).

Checks (each starts a fresh engine process):
  workload     load the 9 workload tables at --scale, run the 20 workload queries: all must be ok.
  query_budget same tables with --max-query-memory-mb 64: every query is ok or RESOURCE_LIMIT, at
               least one is RESOURCE_LIMIT, and the engine still answers afterwards.
  ingest_limit --max-ingest-bytes 100000000 and the transactions file: RESOURCE_LIMIT, engine alive.
  exhaustion   load the transactions file into --copies tables: each load is ok or RESOURCE_LIMIT,
               the engine never exits, and afterwards it still answers a query on the first copy.

The data is generated with datasets/generators/pqgen.py when missing. A memory guard kills the
engine (and fails the check) if its process tree exceeds --guard-gib, to protect the host.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/conformance"))
from engine import EngineError, SessionEngine  # noqa: E402

WORKLOAD = ROOT / "benchmarks/workloads/analytics.json"
LOAD_TIMEOUT = 1800
QUERY_TIMEOUT = 600


def tree_rss_gib(root: int) -> float:
    kids: dict[int, list[int]] = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                ppid = int(Path(f"/proc/{d}/stat").read_text().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            kids.setdefault(ppid, []).append(int(d))
    total, todo = 0, [root]
    while todo:
        p = todo.pop()
        todo += kids.get(p, [])
        try:
            for line in Path(f"/proc/{p}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1])
        except OSError:
            pass
    return total / 2**20


class Guarded:
    """A session engine whose process tree is killed if it grows beyond the guard."""

    def __init__(self, launcher: str, data_dir: Path, extra: list[str], guard_gib: float, log: Path):
        self.eng = SessionEngine(launcher, data_dir, extra, timeout=QUERY_TIMEOUT, stderr_path=log)
        self.guard_gib, self.peak_gib, self.tripped = guard_gib, 0.0, False
        self._stop = threading.Event()
        threading.Thread(target=self._watch, daemon=True).start()

    def _watch(self) -> None:
        while not self._stop.wait(0.5):
            rss = tree_rss_gib(self.eng.proc.pid)
            self.peak_gib = max(self.peak_gib, rss)
            if rss > self.guard_gib:
                self.tripped = True
                self.eng.kill()
                return

    def request(self, req: dict, timeout: float) -> dict:
        return self.eng.request(req, timeout=timeout)

    def alive(self) -> bool:
        return self.eng.proc.poll() is None and not self.eng.dead

    def close(self) -> None:
        self._stop.set()
        self.eng.close()


def ensure_data(scale: str) -> Path:
    d = ROOT / "datasets/generated" / scale
    if not (d / "transactions.csv").exists() or not (d / "manifest.json").exists():
        subprocess.run([sys.executable, str(ROOT / "datasets/generators/pqgen.py"), "generate", "--scale", scale,
                        "--jobs", "8"], check=True)
    return d


def load(eng: Guarded, d: Path, table: str, stem: str) -> dict:
    schema = json.loads((d / f"{stem}.schema.json").read_text())
    t0 = time.monotonic()
    r = eng.request({"op": "load", "table": table, "format": "csv", "path": f"{stem}.csv", "schema": schema},
                    timeout=LOAD_TIMEOUT)
    return {"table": table, "ok": r.get("ok"), "code": (r.get("error") or {}).get("code"),
            "rows": r.get("row_count"), "seconds": round(time.monotonic() - t0, 1)}


def code_of(r: dict) -> str | None:
    return None if r.get("ok") else (r.get("error") or {}).get("code")


def run_check(name: str, fn, args, d: Path, workload: dict) -> dict:
    log = Path(args.logs) / f"{name}.stderr"
    eng = Guarded(args.engine, d, CHECK_ARGS.get(name, []), args.guard_gib, log)
    res: dict = {"check": name, "args": CHECK_ARGS.get(name, []), "steps": []}
    try:
        fn(eng, d, workload, args, res)
    except EngineError as e:
        res["error"] = str(e)
        res.setdefault("failures", []).append("engine died or hung: " + str(e))
    finally:
        res["engine_alive_at_end"] = eng.alive()
        res["peak_rss_gib"] = round(eng.peak_gib, 1)
        res["memory_guard_tripped"] = eng.tripped
        eng.close()
    if eng.tripped:
        res.setdefault("failures", []).append(f"process tree exceeded the {args.guard_gib} GiB memory guard")
    if not res["engine_alive_at_end"] and "error" not in res:
        res.setdefault("failures", []).append("engine process exited")
    try:
        tail = log.read_bytes()[-1500:].decode("utf-8", "replace")
    except OSError:
        tail = ""
    if res.get("failures") and tail:
        res["stderr_tail"] = tail
    res["verdict"] = "fail" if res.get("failures") else "pass"
    print(f"[{name}] {res['verdict']} peak={res['peak_rss_gib']} GiB {'; '.join(res.get('failures', []))}", flush=True)
    return res


def chk_workload(eng, d, workload, args, res) -> None:
    for t, stem in workload["tables"].items():
        s = load(eng, d, t, stem)
        res["steps"].append(s)
        if not s["ok"]:
            res.setdefault("failures", []).append(f"load {t}: {s['code']}")
            return
    for q in workload["queries"]:
        t0 = time.monotonic()
        r = eng.request({"op": "query", "sql": q["sql"], "options": {}}, timeout=QUERY_TIMEOUT)
        res["steps"].append({"query": q["name"], "ok": r.get("ok"), "code": code_of(r),
                             "seconds": round(time.monotonic() - t0, 3)})
        if not r.get("ok"):
            res.setdefault("failures", []).append(f"{q['name']}: {code_of(r)}")


def chk_query_budget(eng, d, workload, args, res) -> None:
    for t, stem in workload["tables"].items():
        s = load(eng, d, t, stem)
        res["steps"].append(s)
        if not s["ok"]:
            res.setdefault("failures", []).append(f"load {t}: {s['code']}")
            return
    limited = 0
    for q in workload["queries"]:
        r = eng.request({"op": "query", "sql": q["sql"], "options": {}}, timeout=QUERY_TIMEOUT)
        c = code_of(r)
        res["steps"].append({"query": q["name"], "ok": r.get("ok"), "code": c})
        if c == "RESOURCE_LIMIT":
            limited += 1
        elif not r.get("ok"):
            res.setdefault("failures", []).append(f"{q['name']}: {c} (expected ok or RESOURCE_LIMIT)")
    if not limited:
        res.setdefault("failures", []).append("no query hit the 64 MiB budget (RESOURCE_LIMIT never reported)")
    r = eng.request({"op": "query", "sql": "SELECT COUNT(*) FROM customers", "options": {}}, timeout=QUERY_TIMEOUT)
    if not r.get("ok"):
        res.setdefault("failures", []).append(f"engine does not answer after the budget errors: {code_of(r)}")


def chk_ingest_limit(eng, d, workload, args, res) -> None:
    s = load(eng, d, "t", "transactions")
    res["steps"].append(s)
    if s["code"] != "RESOURCE_LIMIT":
        res.setdefault("failures", []).append(f"load above --max-ingest-bytes: {s['code'] or 'ok'} "
                                              "(expected RESOURCE_LIMIT)")
    r = eng.request({"op": "query", "sql": "SELECT 1", "options": {}}, timeout=QUERY_TIMEOUT)
    if not r.get("ok"):
        res.setdefault("failures", []).append(f"engine does not answer afterwards: {code_of(r)}")


def chk_exhaustion(eng, d, workload, args, res) -> None:
    for i in range(1, args.copies + 1):
        s = load(eng, d, f"t{i}", "transactions")
        res["steps"].append(s)
        if not s["ok"] and s["code"] != "RESOURCE_LIMIT":
            res.setdefault("failures", []).append(f"load t{i}: {s['code']} (expected ok or RESOURCE_LIMIT)")
    if not res["steps"][0]["ok"]:
        res.setdefault("failures", []).append("the first copy did not load (one 10m table must fit)")
        return
    r = eng.request({"op": "query", "sql": "SELECT COUNT(*) FROM t1", "options": {}}, timeout=QUERY_TIMEOUT)
    res["steps"].append({"query": "SELECT COUNT(*) FROM t1", "ok": r.get("ok"), "code": code_of(r),
                         "rows": r.get("rows")})
    if not r.get("ok"):
        res.setdefault("failures", []).append(f"engine does not answer after the loads: {code_of(r)}")


CHECKS = {"workload": chk_workload, "query_budget": chk_query_budget, "ingest_limit": chk_ingest_limit,
          "exhaustion": chk_exhaustion}
CHECK_ARGS = {"query_budget": ["--max-query-memory-mb", "64"], "ingest_limit": ["--max-ingest-bytes", "100000000"]}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engine", required=True)
    ap.add_argument("--scale", default="10m")
    ap.add_argument("--copies", type=int, default=6)
    ap.add_argument("--guard-gib", type=float, default=120.0)
    ap.add_argument("--only", default="", help="comma-separated check names")
    ap.add_argument("--logs", default="large-data-logs")
    ap.add_argument("--report")
    ap.add_argument("--require-pass", action="store_true")
    args = ap.parse_args()
    args.engine = str(Path(args.engine).resolve())
    Path(args.logs).mkdir(parents=True, exist_ok=True)
    d = ensure_data(args.scale)
    workload = json.loads(WORKLOAD.read_text())
    names = [n for n in CHECKS if not args.only or n in args.only.split(",")]
    results = [run_check(n, CHECKS[n], args, d, workload) for n in names]
    ok = all(r["verdict"] == "pass" for r in results)
    out = {"schema": "polyquery-large-data-probe/1", "engine": args.engine, "scale": args.scale,
           "copies": args.copies, "guard_gib": args.guard_gib, "verdict": "pass" if ok else "fail",
           "checks": results}
    if args.report:
        Path(args.report).write_text(json.dumps(out, indent=1) + "\n")
    print("large-data probe:", out["verdict"])
    return 0 if ok or not args.require_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
