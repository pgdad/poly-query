#!/usr/bin/env python3
"""Times the queries of a benchmark workload (benchmarks/workloads/*.json) through
`bin/polyquery session` (development tool).

  python3 datasets/generators/pqgen.py generate --scale 1m --jobs 1
  python3 tools/workload_bench.py --engine bin/polyquery \
      --workload ../../benchmarks/workloads/analytics.json --data ../../datasets/generated --scale 1m \
      [--rounds 3] [--reps 10] [--warmup 5] [--save results.json] [--compare before.json]
  python3 tools/workload_bench.py --engine bin/polyquery --baseline-engine OTHER/bin/polyquery ...

Every round starts a fresh session, loads the workload's tables (CSV + schema), creates its
indexes, then runs each query with the engine's default options: the first execution is
recorded as the *cold* time (JIT compilation included), then `warmup` unmeasured runs and
`reps` timed runs give the round's *warm* median. Reported per query: the median over rounds
of the warm medians and of the cold times (client-side wall time in milliseconds). Queries
marked `"result": "count"` in the workload are run with `result: count`; all others return
their rows, so serialization is included. A digest of every result is recorded (FLOAT64
values rounded to 9 significant digits); with `--compare FILE` (a file written by `--save`),
the digests must match and a before/after Markdown table is printed. With
`--baseline-engine`, every round runs the baseline engine and then this one (alternating, so
that both see the same machine load) and the table compares the two.
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
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data, "--log-level", "off"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
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


def run_round(args, engine, workload, data, only):
    s = Session(os.path.abspath(engine), data, args.jvm)
    for name, base in workload["tables"].items():
        schema = json.load(open(f"{data}/{args.scale}/{base}.schema.json"))
        r = s.req({"op": "load", "table": name, "path": f"{args.scale}/{base}.csv", "format": "csv",
                   "schema": schema})
        assert r.get("ok"), r
    for idx in workload.get("indexes", []):
        r = s.req({"op": "query", "sql": idx["sql"]})
        assert r.get("ok"), r
    out = {}
    for q in workload["queries"]:
        if only and not any(q["name"].startswith(p) for p in only):
            continue
        opts = {"result": "count"} if q.get("result") == "count" else {}
        times, dig, cold = [], None, None
        for rep in range(1 + args.warmup + args.reps):
            t0 = time.perf_counter()
            r = s.req({"op": "query", "sql": q["sql"], "options": dict(opts)})
            dt = (time.perf_counter() - t0) * 1000
            assert r.get("ok"), (q["name"], r)
            d = digest(r)
            assert dig is None or dig == d, f"{q['name']}: result differs between runs"
            dig = d
            if rep == 0:
                cold = dt
            elif rep > args.warmup:
                times.append(dt)
        out[q["name"]] = {"warm": statistics.median(times), "cold": cold, "rows": r["row_count"], "digest": dig}
    s.close()
    return out


def summarize(rounds):
    """Per query: medians over rounds of the warm medians and of the cold times."""
    results = {}
    for name in rounds[0]:
        digests = {r[name]["digest"] for r in rounds}
        assert len(digests) == 1, f"{name}: result differs between rounds"
        results[name] = {"warm_ms": round(statistics.median(r[name]["warm"] for r in rounds), 2),
                         "cold_ms": round(statistics.median(r[name]["cold"] for r in rounds), 2),
                         "rows": rounds[0][name]["rows"], "digest": digests.pop()}
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--scale", default="1m")
    ap.add_argument("--rounds", type=int, default=3, help="fresh sessions; per-query medians over rounds")
    ap.add_argument("--reps", type=int, default=10)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--jvm", default="", help="extra JVM options (POLYQUERY_JAVA_OPTS)")
    ap.add_argument("--only", help="comma-separated query name prefixes")
    ap.add_argument("--save", help="write the results to this JSON file")
    ap.add_argument("--compare", help="earlier --save file: check digests, print a before/after table")
    ap.add_argument("--baseline-engine", help="also measure this engine, alternating rounds, and compare")
    args = ap.parse_args()

    workload = json.load(open(args.workload))
    data = os.path.abspath(args.data)
    only = args.only.split(",") if args.only else None
    rounds, base_rounds = [], []
    for i in range(args.rounds):
        if args.baseline_engine:
            base_rounds.append(run_round(args, args.baseline_engine, workload, data, only))
        rounds.append(run_round(args, args.engine, workload, data, only))
        print(f"round {i + 1}/{args.rounds} done", flush=True)
    results = summarize(rounds)
    for name, r in results.items():
        print(f"{name:28s} warm {r['warm_ms']:8.2f} ms  cold {r['cold_ms']:8.2f} ms  rows {r['rows']}  {r['digest']}",
              flush=True)
    if args.save:
        with open(args.save, "w") as f:
            json.dump(results, f, indent=1)
    before = None
    if args.baseline_engine:
        before = summarize(base_rounds)
        if args.save:
            with open(args.save.replace(".json", "") + ".baseline.json", "w") as f:
                json.dump(before, f, indent=1)
    elif args.compare:
        before = json.load(open(args.compare))
    if before is not None:
        mismatches = []
        print("\n| query | warm before (ms) | warm after (ms) | speed-up | cold before (ms) | cold after (ms) | speed-up |")
        print("|---|---:|---:|---:|---:|---:|---:|")
        sums = [0.0, 0.0, 0.0, 0.0]
        for name, a in results.items():
            b = before.get(name)
            if b is None:
                continue
            if b["digest"] != a["digest"]:
                mismatches.append(name)
            vals = [b["warm_ms"], a["warm_ms"], b["cold_ms"], a["cold_ms"]]
            sums = [x + y for x, y in zip(sums, vals)]
            print(f"| {name} | {vals[0]:.1f} | {vals[1]:.1f} | {vals[0] / max(vals[1], 0.01):.1f}× "
                  f"| {vals[2]:.1f} | {vals[3]:.1f} | {vals[2] / max(vals[3], 0.01):.1f}× |")
        print(f"| **total** | {sums[0]:.1f} | {sums[1]:.1f} | {sums[0] / max(sums[1], 0.01):.1f}× "
              f"| {sums[2]:.1f} | {sums[3]:.1f} | {sums[2] / max(sums[3], 0.01):.1f}× |")
        if mismatches:
            raise SystemExit(f"RESULT MISMATCH: {', '.join(mismatches)}")


if __name__ == "__main__":
    main()
