#!/usr/bin/env python3
"""Times a workload file's queries through `bin/polyquery session` (development tool).

  python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
  python3 tools/workload.py --engine bin/polyquery --data /tmp/pqdata --workload bench/analytics.json \
      [--reps 9] [--warmup 3] [--rounds 2] [--save results.json] [--compare before.json]

Every round starts a fresh engine process, loads the workload's tables and runs each query once
cold (first execution in the process), then `warmup` unmeasured and `reps` measured times, with
default query options (full `rows` results, so serialization is included). Wall time is measured
client side, from writing the request line to reading the response line. Reports per query the
cold time and the median of the measured runs (best median over the rounds) in milliseconds.

--save writes the timings and every query's full result; --compare reads such a file, prints a
before/after table and fails if any result differs (rows compared as multisets unless the query
has ORDER BY; FLOAT64 values within 1e-9 relative).
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time


class Session:
    def __init__(self, launcher, data):
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True)
        self.n = 0

    def req(self, obj):
        self.n += 1
        obj["id"] = self.n
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def timed(s, obj):
    t0 = time.perf_counter()
    r = s.req(obj)
    return (time.perf_counter() - t0) * 1000, r


def same(a, b):
    if isinstance(a, float) and isinstance(b, (int, float)) and not isinstance(b, bool):
        return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def canonical(sql, result):
    rows = result["rows"]
    if "ORDER BY" not in sql.upper():
        rows = sorted(rows, key=json.dumps)
    return {"columns": result["columns"], "rows": rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True, help="directory containing <scale>/<table files>")
    ap.add_argument("--workload", required=True)
    ap.add_argument("--scale")
    ap.add_argument("--reps", type=int, default=9)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--only", help="comma-separated query ids")
    ap.add_argument("--save")
    ap.add_argument("--compare")
    args = ap.parse_args()

    workload = json.load(open(args.workload))
    scale = args.scale or workload["scale"]
    queries = workload["queries"]
    if args.only:
        wanted = set(args.only.split(","))
        queries = [q for q in queries if q["id"] in wanted]
    cold, warm, results = {}, {}, {}
    for rnd in range(args.rounds):
        s = Session(args.engine, os.path.abspath(args.data))
        for t in workload["tables"]:
            schema = json.load(open(os.path.join(args.data, scale, t["schema"])))
            dt, r = timed(s, {"op": "load", "table": t["name"], "path": f"{scale}/{t['file']}", "format": "csv",
                              "schema": schema})
            assert r.get("ok"), r
            print(f"round {rnd + 1}: loaded {t['name']} ({r['row_count']} rows) in {dt / 1000:.1f}s",
                  file=sys.stderr, flush=True)
        for q in queries:
            qid, sql = q["id"], q["sql"]
            times = []
            for rep in range(1 + args.warmup + args.reps):
                dt, r = timed(s, {"op": "query", "sql": sql})
                assert r.get("ok"), (qid, r)
                if rep == 0:
                    cold[qid] = min(dt, cold.get(qid, dt))
                    results.setdefault(qid, canonical(sql, r))
                elif rep > args.warmup:
                    times.append(dt)
            med = statistics.median(times)
            warm[qid] = min(med, warm.get(qid, med))
            print(f"round {rnd + 1} {qid}: cold {cold[qid]:.1f} ms, median {warm[qid]:.1f} ms",
                  file=sys.stderr, flush=True)
        s.close()

    if args.save:
        json.dump({"cold": cold, "warm": warm, "results": results}, open(args.save, "w"))
    if args.compare:
        before = json.load(open(args.compare))
        bad = [q["id"] for q in queries
               if before["results"][q["id"]]["columns"] != results[q["id"]]["columns"]
               or not same(before["results"][q["id"]]["rows"], results[q["id"]]["rows"])]
        print("| query | before cold | after cold | before median | after median | speed-up |")
        print("|---|---:|---:|---:|---:|---:|")
        for q in queries:
            qid = q["id"]
            b, a = before["warm"][qid], warm[qid]
            print(f"| {qid} {q['name']} | {before['cold'][qid]:.1f} | {cold[qid]:.1f} | {b:.1f} | {a:.1f} "
                  f"| {b / a:.2f}× |")
        tb, ta = sum(before["warm"][q["id"]] for q in queries), sum(warm[q["id"]] for q in queries)
        print(f"| **total** | {sum(before['cold'][q['id']] for q in queries):.1f} | "
              f"{sum(cold[q['id']] for q in queries):.1f} | {tb:.1f} | {ta:.1f} | {tb / ta:.2f}× |")
        if bad:
            print("RESULTS DIFFER: " + ", ".join(bad), file=sys.stderr)
            sys.exit(1)
    else:
        print("| query | cold | median |")
        print("|---|---:|---:|")
        for q in queries:
            print(f"| {q['id']} {q['name']} | {cold[q['id']]:.1f} | {warm[q['id']]:.1f} |")


if __name__ == "__main__":
    main()
