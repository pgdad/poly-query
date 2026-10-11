#!/usr/bin/env python3
"""Time the benchmark workload (benchmarks/workloads/analytics.json) through
`bin/polyquery session`.

Loads every workload table from a generated dataset directory (CSV with its
`.schema.json`), creates the workload's indexes, then runs each workload
query with its default options (plus `result: count` where the workload asks
for it). Reports the median and minimum client-side wall time per query
(request written -> response line read, including JSON serialization).

The rows of every query are written to --rows so that two engine builds can
be compared for identical results (--compare OTHER_ROWS_FILE).

Usage:
  workload.py --engine bin/polyquery --data datasets/generated/1m
              [--workload benchmarks/workloads/analytics.json]
              [--repeat 7] [--warmup 1] [--queries q01,q02]
              [--engine-arg=--threads=4] [--json out.json]
              [--rows rows.json] [--compare rows.json]
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time

FLOAT_REL_TOL = 1e-9


class Session:
    def __init__(self, engine: str, data_dir: str, extra_args=()):
        self.proc = subprocess.Popen([engine, "session", "--data-dir", data_dir, *extra_args],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def request(self, req: dict) -> dict:
        self.proc.stdin.write((json.dumps(req) + "\n").encode())
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait()


def values_equal(x, y) -> bool:
    if isinstance(x, float) or isinstance(y, float):
        if not (isinstance(x, (int, float)) and isinstance(y, (int, float))):
            return False
        return abs(x - y) <= FLOAT_REL_TOL * max(1.0, abs(x), abs(y))
    return x == y


def results_equal(a, b) -> bool:
    """Ordered comparison (every workload query is ordered or a single row)."""
    if a.get("error") or b.get("error"):
        return a.get("error") == b.get("error")
    if a["row_count"] != b["row_count"] or a.get("columns") != b.get("columns"):
        return False
    ra, rb = a.get("rows"), b.get("rows")
    if ra is None or rb is None:
        return ra is None and rb is None
    return len(ra) == len(rb) and all(
        len(x) == len(y) and all(values_equal(u, v) for u, v in zip(x, y)) for x, y in zip(ra, rb))


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True, help="directory with the generated CSV files")
    ap.add_argument("--workload", default=os.path.join(here, "../../../benchmarks/workloads/analytics.json"))
    ap.add_argument("--repeat", type=int, default=7)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--queries", default=None, help="comma-separated name prefixes")
    ap.add_argument("--engine-arg", action="append", default=[], help="extra engine CLI argument")
    ap.add_argument("--options", default=None,
                    help="JSON object merged into every query's options (e.g. {\"result\":\"rows\"})")
    ap.add_argument("--json", default=None, help="write timings to this file")
    ap.add_argument("--rows", default=None, help="write query results to this file")
    ap.add_argument("--compare", default=None, help="compare results with a --rows file")
    args = ap.parse_args()

    wl = json.load(open(args.workload))
    extra_opts = json.loads(args.options) if args.options else {}
    queries = wl["queries"]
    if args.queries:
        prefixes = args.queries.split(",")
        queries = [q for q in queries if any(q["name"].startswith(p) for p in prefixes)]

    s = Session(args.engine, args.data, args.engine_arg)
    t0 = time.monotonic()
    for table, base in wl["tables"].items():
        schema = json.load(open(f"{args.data}/{base}.schema.json"))
        r = s.request({"op": "load", "table": table, "format": "csv", "path": f"{base}.csv", "schema": schema})
        if not r.get("ok"):
            print("load failed", table, r, file=sys.stderr)
            return 1
    for ix in wl.get("indexes", []):
        r = s.request({"op": "query", "sql": ix["sql"]})
        if not r.get("ok"):
            print("index failed", ix["sql"], r, file=sys.stderr)
            return 1
    print(f"loaded {len(wl['tables'])} tables in {time.monotonic() - t0:.1f}s", flush=True)

    timings, outputs = {}, {}
    print("%-28s %10s %10s %8s" % ("query", "median ms", "min ms", "rows"))
    for q in queries:
        req = {"op": "query", "sql": q["sql"]}
        options = {"result": q["result"]} if q.get("result") else {}
        options.update(extra_opts)
        if options:
            req["options"] = options
        samples = []
        r = None
        for i in range(args.warmup + args.repeat):
            t = time.monotonic()
            r = s.request(req)
            dt = time.monotonic() - t
            if i >= args.warmup:
                samples.append(dt * 1000.0)
            if not r.get("ok"):
                break
        if r.get("ok"):
            outputs[q["name"]] = {"columns": r.get("columns"), "rows": r.get("rows"), "row_count": r["row_count"]}
        else:
            outputs[q["name"]] = {"error": r["error"]["code"]}
        timings[q["name"]] = {"median_ms": statistics.median(samples), "min_ms": min(samples),
                              "samples_ms": samples}
        print("%-28s %10.2f %10.2f %8s" % (q["name"], timings[q["name"]]["median_ms"],
                                            timings[q["name"]]["min_ms"],
                                            r.get("row_count", r.get("error", {}).get("code"))), flush=True)
    s.close()

    if args.json:
        json.dump(timings, open(args.json, "w"), indent=1)
    if args.rows:
        json.dump(outputs, open(args.rows, "w"))
    if args.compare:
        ref = json.load(open(args.compare))
        bad = [n for n in outputs if n in ref and not results_equal(outputs[n], ref[n])]
        for n in bad:
            print(f"MISMATCH {n}", file=sys.stderr)
        print(f"compared {len(outputs)} queries: {len(bad)} mismatches")
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
