#!/usr/bin/env python3
"""Latency benchmark: run a workload file through `bin/polyquery session`.

Loads the workload's tables (CSV + schema files from the generated dataset
directory), then runs every query `--warmup` times untimed and `--runs` times
timed. Timing is client-side wall clock of one request/response round trip
with default query options and full result rows (what a client sees),
so parsing, planning, execution and JSON serialization are all included.

  workload.py --engine bin/polyquery --data /tmp/pqdata/1m \
      --workload bench/workloads/analytics.json [--runs 5] [--warmup 1] \
      [--save results.json] [--compare before.json] [--only A01,A07]

`--save` writes timings and result rows; `--compare` checks this run's
results against a saved run (exact, FLOAT64 within 1e-9 relative, unordered
queries as multisets) and prints a before/after Markdown table.
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time


class Session:
    def __init__(self, engine: str, data: str, extra=()):
        self.p = subprocess.Popen([engine, "session", "--data-dir", data, *extra], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1 << 20)
        self.n = 0

    def call(self, req: dict) -> dict:
        self.n += 1
        req["id"] = self.n
        assert self.p.stdin and self.p.stdout
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def close(self) -> None:
        if self.p.stdin:
            self.p.stdin.close()
        self.p.wait()


def values_equal(a, b, typ: str) -> bool:
    if a is None or b is None:
        return a is b
    if typ == "FLOAT64":
        return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
    return a == b


def rows_equal(cols: list, ra: list, rb: list, ordered: bool) -> bool:
    if len(ra) != len(rb):
        return False
    types = [c["type"] for c in cols]
    if not ordered:
        key = lambda r: json.dumps([None if t == "FLOAT64" else v for v, t in zip(r, types)])
        ra, rb = sorted(ra, key=key), sorted(rb, key=key)
    return all(all(values_equal(x, y, t) for x, y, t in zip(a, b, types)) for a, b in zip(ra, rb))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--only", default="")
    ap.add_argument("--save")
    ap.add_argument("--compare")
    ap.add_argument("--options", default="{}", help="extra query options (JSON object)")
    args = ap.parse_args()
    wl = json.load(open(args.workload))
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    extra_opts = json.loads(args.options)

    s = Session(args.engine, args.data)
    t0 = time.monotonic()
    for t in wl["tables"]:
        schema = json.load(open(f"{args.data}/{t['schema']}"))
        r = s.call({"op": "load", "table": t["table"], "format": "csv", "path": t["file"], "schema": schema})
        if not r.get("ok"):
            print(f"load {t['table']} failed: {r}", file=sys.stderr)
            return 1
    load_s = time.monotonic() - t0
    print(f"# loaded {len(wl['tables'])} tables in {load_s:.1f}s", file=sys.stderr, flush=True)

    results = {"load_s": load_s, "queries": {}}
    for q in wl["queries"]:
        if only and q["id"] not in only:
            continue
        times = []
        resp = None
        for i in range(args.warmup + args.runs):
            t = time.monotonic()
            r = s.call({"op": "query", "sql": q["sql"], "options": dict(extra_opts)})
            dt = (time.monotonic() - t) * 1000
            if not r.get("ok"):
                print(f"{q['id']} failed: {r.get('error')}", file=sys.stderr)
                return 1
            if i >= args.warmup:
                times.append(dt)
            resp = r
        results["queries"][q["id"]] = {
            "median_ms": statistics.median(times), "min_ms": min(times), "times_ms": times,
            "columns": resp["columns"], "rows": resp["rows"], "row_count": resp["row_count"],
        }
        print(f"{q['id']} {q['name']}: median {statistics.median(times):.1f} ms, min {min(times):.1f} ms, "
              f"{resp['row_count']} rows", file=sys.stderr, flush=True)
    s.close()

    if args.save:
        with open(args.save, "w") as f:
            json.dump(results, f)

    if args.compare:
        before = json.load(open(args.compare))
        print("| query | description | before median (ms) | after median (ms) | speedup | result |")
        print("|---|---|---:|---:|---:|---|")
        tb = ta = 0.0
        bad = 0
        for q in wl["queries"]:
            a = results["queries"].get(q["id"])
            b = before["queries"].get(q["id"])
            if not a or not b:
                continue
            same = a["columns"] == b["columns"] and rows_equal(a["columns"], a["rows"], b["rows"], q["ordered"])
            bad += not same
            tb += b["median_ms"]
            ta += a["median_ms"]
            print(f"| {q['id']} | {q['name']} | {b['median_ms']:.1f} | {a['median_ms']:.1f} | "
                  f"{b['median_ms'] / a['median_ms']:.2f}x | {'identical' if same else 'DIFFERENT'} |")
        print(f"| **total** | | **{tb:.1f}** | **{ta:.1f}** | **{tb / ta:.2f}x** | |")
        if bad:
            print(f"{bad} queries returned different results", file=sys.stderr)
            return 1
    else:
        print("| query | description | median (ms) | min (ms) | rows |")
        print("|---|---|---:|---:|---:|")
        for q in wl["queries"]:
            a = results["queries"].get(q["id"])
            if a:
                print(f"| {q['id']} | {q['name']} | {a['median_ms']:.1f} | {a['min_ms']:.1f} | {a['row_count']} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
