#!/usr/bin/env python3
"""Times the queries of a benchmark workload (benchmarks/workloads/*.json) through
`bin/polyquery session` (development tool).

  python3 datasets/generators/pqgen.py generate --scale 1m --jobs 1
  python3 tools/workload_bench.py --engine bin/polyquery \
      --workload ../../benchmarks/workloads/analytics.json --data ../../datasets/generated --scale 1m \
      [--reps 7] [--warmup 3] [--save results.json] [--compare before.json]

Loads the workload's tables (CSV + schema) into one session, creates its indexes, then runs
every query with the engine's default options (`warmup` unmeasured runs, then `reps` timed
runs) and reports the median and minimum client-side wall time in milliseconds. Queries
marked `"result": "count"` in the workload are run with `result: count`; all others return
their rows, so serialization is included. A digest of every result is recorded; with
`--compare FILE` (a file written by `--save`), the digests must match and a before/after
Markdown table is printed.
"""
import argparse
import hashlib
import json
import os
import statistics
import subprocess
import time


class Session:
    def __init__(self, launcher, data, jvm):
        env = dict(os.environ)
        if jvm:
            env["POLYQUERY_JAVA_OPTS"] = jvm
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, env=env)
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


def rounded(v):
    """FLOAT64 results (AVG, float sums) may differ in the last bits with the summation order."""
    if isinstance(v, float):
        return float(f"{v:.9g}")
    if isinstance(v, list):
        return [rounded(x) for x in v]
    return v


def digest(resp):
    body = {"columns": resp.get("columns"), "row_count": resp.get("row_count"),
            "rows": rounded(resp.get("rows"))}
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--scale", default="1m")
    ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--jvm", default="")
    ap.add_argument("--only", help="comma-separated query name prefixes")
    ap.add_argument("--save", help="write the results (times + digests) to this JSON file")
    ap.add_argument("--compare", help="earlier --save file: check digests, print a before/after table")
    args = ap.parse_args()

    workload = json.load(open(args.workload))
    data = os.path.abspath(args.data)
    s = Session(os.path.abspath(args.engine), data, args.jvm)
    for name, base in workload["tables"].items():
        schema = json.load(open(f"{data}/{args.scale}/{base}.schema.json"))
        t0 = time.time()
        r = s.req({"op": "load", "table": name, "path": f"{args.scale}/{base}.csv", "format": "csv",
                   "schema": schema})
        assert r.get("ok"), r
        print(f"loaded {name}: {r['row_count']} rows in {time.time() - t0:.1f}s", flush=True)
    for idx in workload.get("indexes", []):
        r = s.req({"op": "query", "sql": idx["sql"]})
        assert r.get("ok"), r

    only = args.only.split(",") if args.only else None
    results = {}
    for q in workload["queries"]:
        if only and not any(q["name"].startswith(p) for p in only):
            continue
        opts = {"result": "count"} if q.get("result") == "count" else {}
        times, dig = [], None
        for rep in range(args.warmup + args.reps):
            t0 = time.perf_counter()
            r = s.req({"op": "query", "sql": q["sql"], "options": dict(opts)})
            dt = (time.perf_counter() - t0) * 1000
            assert r.get("ok"), (q["name"], r)
            d = digest(r)
            assert dig is None or dig == d, f"{q['name']}: result differs between runs"
            dig = d
            if rep >= args.warmup:
                times.append(dt)
        results[q["name"]] = {"median_ms": round(statistics.median(times), 2), "min_ms": round(min(times), 2),
                              "row_count": r["row_count"], "digest": dig}
        print(f"{q['name']:28s} median {statistics.median(times):8.2f} ms  min {min(times):8.2f} ms  "
              f"rows {r['row_count']}  {dig}", flush=True)
    s.close()

    if args.save:
        with open(args.save, "w") as f:
            json.dump(results, f, indent=1)
    if args.compare:
        before = json.load(open(args.compare))
        mismatches = []
        print("\n| query | before (ms) | after (ms) | speed-up |\n|---|---:|---:|---:|")
        tb = ta = 0.0
        for name, a in results.items():
            b = before.get(name)
            if b is None:
                continue
            if b["digest"] != a["digest"]:
                mismatches.append(name)
            tb += b["median_ms"]
            ta += a["median_ms"]
            print(f"| {name} | {b['median_ms']:.1f} | {a['median_ms']:.1f} | "
                  f"{b['median_ms'] / max(a['median_ms'], 0.01):.1f}× |")
        print(f"| **total** | {tb:.1f} | {ta:.1f} | {tb / max(ta, 0.01):.1f}× |")
        if mismatches:
            raise SystemExit(f"RESULT MISMATCH: {', '.join(mismatches)}")


if __name__ == "__main__":
    main()
