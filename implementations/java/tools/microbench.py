#!/usr/bin/env python3
"""Server-side latency of single queries in several engines, interleaved (JVM tuning tool).

  python3 tools/microbench.py --data /tmp/pqdata --tables sort_keys,customers \\
      --engine before/bin/polyquery --engine bin/polyquery [--reps 30] [--options '{"threads":1}'] \\
      "SELECT ..." ["SELECT ..." ...]

Each engine runs in one session process that loads the pqgen tables (<data>/1m/<table>.csv with
their schema files); then every query runs `reps` times, the engines taking turns per query.
Reported per query and engine: the median of the engine's own `stats.elapsed_us` over the last
two thirds of the runs (so JIT warm-up is excluded) and the ratio to the first engine; differing
results are flagged. Compare an engine with itself (A/A) to see the noise level.
"""
import argparse
import json
import statistics
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", action="append", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--scale", default="1m")
    ap.add_argument("--tables", required=True, help="comma-separated pqgen table names")
    ap.add_argument("--reps", type=int, default=30)
    ap.add_argument("--options", default="{}", help="query options (JSON object)")
    ap.add_argument("sql", nargs="+")
    args = ap.parse_args()
    opts = json.loads(args.options)

    procs = [subprocess.Popen([e, "session", "--data-dir", args.data], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True) for e in args.engine]

    def req(p, obj):
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()
        return json.loads(p.stdout.readline())

    for p in procs:
        for t in args.tables.split(","):
            schema = json.load(open(f"{args.data}/{args.scale}/{t}.schema.json"))
            r = req(p, {"op": "load", "table": t, "path": f"{args.scale}/{t}.csv", "format": "csv", "schema": schema})
            assert r.get("ok"), r
    times, rows = {}, {}
    for rep in range(args.reps):
        for sql in args.sql:
            for e, p in zip(args.engine, procs):
                r = req(p, {"op": "query", "sql": sql, "options": opts})
                assert r.get("ok"), r
                rows[(sql, e)] = r.get("rows", r.get("row_count"))
                if rep >= args.reps // 3:
                    times.setdefault((sql, e), []).append(r["stats"]["elapsed_us"] / 1000)
    for sql in args.sql:
        print(sql)
        base = None
        for e in args.engine:
            m = statistics.median(times[(sql, e)])
            base = base or m
            flag = "" if rows[(sql, e)] == rows[(sql, args.engine[0])] else "  RESULTS DIFFER"
            print(f"  {m:9.2f} ms  {m / base:5.2f}x  {e}{flag}")
    for p in procs:
        p.stdin.close()
        p.wait()


if __name__ == "__main__":
    main()
