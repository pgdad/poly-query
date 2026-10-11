"""Times the queries of a benchmark workload (benchmarks/workloads/*.json)
through ``bin/polyquery session``.

    python3 tools/workload_bench.py --data /tmp/pqdata/1m [--repeat 5] [--only q01,q06]
        [--options '{"threads":4}'] [--engine bin/polyquery] [--json out.json]
        [--save-results results.json | --check-results results.json]

Tables are loaded from ``<table>.csv`` with ``<table>.schema.json`` and the
workload's indexes are created. Every query is run once as a warm-up, then
``--repeat`` times; the median and minimum wall time of the request (sent →
response parsed) are reported in ms. Queries use the workload's ``result``
mode (``rows`` unless the workload says ``count``), so result serialization
is included exactly as a harness would see it.

``--save-results`` writes every query's result rows; ``--check-results``
compares against such a file (rows as a multiset unless the query has an
ORDER BY) and fails on any difference.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE.parent / "bin" / "polyquery"
WORKLOAD = HERE.parents[2] / "benchmarks" / "workloads" / "analytics.json"


class Session:
    def __init__(self, data_dir: str, launcher: str, extra_args: list[str]):
        self.proc = subprocess.Popen(
            [launcher, "session", "--data-dir", data_dir, *extra_args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        self.next_id = 0

    def request(self, req: dict) -> dict:
        self.next_id += 1
        req = {**req, "id": self.next_id}
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        resp = json.loads(self.proc.stdout.readline())
        if not resp.get("ok"):
            raise RuntimeError(f"{req}: {resp.get('error')}")
        return resp

    def close(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.close()
        self.proc.wait()


def result_key(query: dict, rows: list) -> list:
    if "ORDER BY" in query["sql"].upper():
        return rows
    return sorted(json.dumps(r) for r in rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--workload", default=str(WORKLOAD))
    ap.add_argument("--repeat", type=int, default=5)
    ap.add_argument("--only", help="comma-separated query name prefixes")
    ap.add_argument("--options", default="{}", help="JSON query options added to every query")
    ap.add_argument("--engine", default=str(LAUNCHER))
    ap.add_argument("--engine-arg", action="append", default=[], help="extra engine CLI argument")
    ap.add_argument("--json", help="write timings as JSON to this file")
    ap.add_argument("--save-results")
    ap.add_argument("--check-results")
    args = ap.parse_args()

    workload = json.loads(Path(args.workload).read_text())
    data = Path(args.data)
    options = json.loads(args.options)
    session = Session(str(data), args.engine, args.engine_arg)
    for name, base in workload["tables"].items():
        schema = json.loads((data / f"{base}.schema.json").read_text())
        t0 = time.monotonic()
        session.request({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        print(f"load {name}: {time.monotonic() - t0:.1f}s", file=sys.stderr)
    for index in workload.get("indexes", []):
        session.request({"op": "query", "sql": index["sql"]})

    prefixes = args.only.split(",") if args.only else None
    queries = [q for q in workload["queries"] if not prefixes or any(q["name"].startswith(p) for p in prefixes)]
    expected = json.loads(Path(args.check_results).read_text()) if args.check_results else None
    results: dict[str, list] = {}
    timings: dict[str, dict] = {}
    failed = False
    print("query | median ms | min ms | rows")
    for query in queries:
        req = {"op": "query", "sql": query["sql"], "options": {**options, "result": query.get("result", "rows")}}
        first = session.request(req)
        if args.save_results or expected is not None:
            rows = session.request({**req, "options": {**req["options"], "result": "rows"}})["rows"]
            results[query["name"]] = result_key(query, rows)
            if expected is not None and expected.get(query["name"]) != results[query["name"]]:
                print(f"MISMATCH {query['name']}", file=sys.stderr)
                failed = True
        times = []
        for _ in range(args.repeat):
            t0 = time.perf_counter()
            session.request(req)
            times.append((time.perf_counter() - t0) * 1000)
        timings[query["name"]] = {"median_ms": statistics.median(times), "min_ms": min(times)}
        print(f"{query['name']} | {statistics.median(times):.0f} | {min(times):.0f} | {first['row_count']}", flush=True)
    session.close()
    if args.json:
        Path(args.json).write_text(json.dumps(timings, indent=1))
    if args.save_results:
        Path(args.save_results).write_text(json.dumps(results))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
