#!/usr/bin/env python3
"""Time a benchmark workload through `bin/polyquery session`.

Loads the workload's tables (CSV + schema from a pqgen output directory) into
one session, then runs every query `--warmup` + `--repeat` times with the
engine's default execution options (no `options` object, as a client would
send) and reports the median and minimum wall time seen by the client
(request written -> response line read: parse, plan, execute, serialize).

Results are canonicalised (rows sorted unless the query has ORDER BY, floats
rounded to 9 significant digits) and hashed, so two runs (e.g. before/after an
optimization) can be checked for identical answers with --compare.

Usage:
  workload.py --engine bin/polyquery --data /tmp/pqdata/1m
              [--workload bench/workloads/analytics.json] [--repeat 7]
              [--warmup 1] [--queries q01,q02] [--json out.json]
              [--compare before.json] [--engine-arg=--threads=8 ...]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def canon_value(v):
    if isinstance(v, float):
        return "%.9g" % v
    return json.dumps(v)


def result_digest(sql: str, resp: dict) -> str:
    if not resp.get("ok"):
        return "error:" + resp["error"]["code"]
    if "rows" not in resp:
        return "count:%d" % resp["row_count"]
    rows = [[canon_value(v) for v in r] for r in resp["rows"]]
    if "ORDER BY" not in sql.upper():
        rows.sort()
    return hashlib.sha256(json.dumps([resp.get("columns"), rows]).encode()).hexdigest()[:16]


class Session:
    def __init__(self, engine: str, data_dir: str, extra_args):
        self.proc = subprocess.Popen([engine, "session", "--data-dir", data_dir, *extra_args],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def request(self, req: dict) -> dict:
        self.proc.stdin.write((json.dumps(req) + "\n").encode())
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True, help="pqgen output directory (CSV + schema files)")
    ap.add_argument("--workload", default=os.path.join(HERE, "workloads", "analytics.json"))
    ap.add_argument("--repeat", type=int, default=7)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--queries", default=None)
    ap.add_argument("--json", default=None)
    ap.add_argument("--compare", default=None, help="earlier --json output to compare answers/times with")
    ap.add_argument("--engine-arg", action="append", default=[])
    args = ap.parse_args()

    wl = json.load(open(args.workload))
    queries = wl["queries"]
    if args.queries:
        wanted = args.queries.split(",")
        queries = [q for q in queries if any(q["name"].startswith(w) for w in wanted)]
    before = json.load(open(args.compare))["results"] if args.compare else {}

    s = Session(args.engine, args.data, args.engine_arg)
    t0 = time.monotonic()
    for table in wl["tables"]:
        schema = json.load(open(os.path.join(args.data, f"{table}.schema.json")))
        r = s.request({"op": "load", "table": table, "format": "csv", "path": f"{table}.csv", "schema": schema})
        if not r.get("ok"):
            print("load failed", table, r, file=sys.stderr)
            return 1
    print(f"loaded {len(wl['tables'])} tables in {time.monotonic() - t0:.1f}s", flush=True)

    results = {}
    mismatches = 0
    hdr = "%-22s %10s %10s %8s  %s" % ("query", "median_ms", "min_ms", "rows", "digest")
    if before:
        hdr += "   before_ms  speedup same"
    print(hdr)
    for q in queries:
        req = {"op": "query", "sql": q["sql"]}
        if q.get("result"):
            req["options"] = {"result": q["result"]}
        samples = []
        digest = None
        rows = None
        for i in range(args.warmup + args.repeat):
            t = time.monotonic()
            r = s.request(req)
            dt = time.monotonic() - t
            if i >= args.warmup:
                samples.append(dt * 1000.0)
            d = result_digest(q["sql"], r)
            if digest is not None and d != digest:
                print(f"  {q['name']}: nondeterministic result", file=sys.stderr)
                mismatches += 1
            digest = d
            rows = r.get("row_count") if r.get("ok") else r["error"]["code"]
        med, lo = statistics.median(samples), min(samples)
        line = "%-22s %10.1f %10.1f %8s  %s" % (q["name"], med, lo, rows, digest)
        if q["name"] in before:
            b = before[q["name"]]
            same = b["digest"] == digest
            mismatches += not same
            line += "   %9.1f  %6.2fx %s" % (b["median_ms"], b["median_ms"] / med, "yes" if same else "NO")
        print(line, flush=True)
        results[q["name"]] = {"sql": q["sql"], "median_ms": med, "min_ms": lo, "rows": rows,
                              "digest": digest, "samples_ms": samples}
    s.close()
    total = sum(r["median_ms"] for r in results.values())
    print(f"total of medians: {total:.1f} ms")
    if before:
        btotal = sum(before[n]["median_ms"] for n in results if n in before)
        print(f"total before: {btotal:.1f} ms  ({btotal / total:.2f}x)")
    if args.json:
        json.dump({"engine_args": args.engine_arg, "results": results}, open(args.json, "w"), indent=1)
    if mismatches:
        print(f"{mismatches} result mismatches", file=sys.stderr)
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
