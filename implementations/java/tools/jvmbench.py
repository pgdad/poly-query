#!/usr/bin/env python3
"""Start-up, first-query and warm latency of `benchmarks/workloads/analytics.json` (JVM tuning tool).

  python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
  python3 tools/jvmbench.py startup --engine bin/polyquery [--runs 30]
  python3 tools/jvmbench.py workload --engine bin/polyquery --data /tmp/pqdata \
      --workload ../../benchmarks/workloads/analytics.json [--rounds 5] [--save after.json] [--compare before.json]

Everything goes through `bin/polyquery session` (JVM flags under test can be added with
POLYQUERY_JAVA_OPTS, or a different launcher passed with --engine).

startup: spawns the engine `runs` times and measures, client side, the time from spawning the
process to reading the response to its first request (`{"op":"version"}`), and the RSS of the
JVM at that moment. Reports median and 10th/90th percentiles.

workload: every round starts a fresh engine process, loads the workload's tables (the pqgen CSV
files with their schema files) and indexes, then runs each query once cold (its first execution
in the process: class loading, interpretation and JIT compilation included), `warmup` unmeasured
and `reps` measured times, with default options (`result: count` where the workload asks for
it). Per query it reports the median over the rounds of the cold time and of the per-round warm
median (ms), plus the process's peak RSS (VmHWM) and RSS after loading.

With several --engine options the engines' rounds alternate, so a changing machine load hits
them alike. --save (one per engine) writes the timings and every query's result; --compare reads
such a file (default with several engines: the first engine's), prints a before/after table and
fails if any result differs (rows compared as multisets unless the query
has ORDER BY; FLOAT64 values within 1e-9 relative).
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time


def rss_kb(pid, field="VmRSS"):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith(field + ":"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


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
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError(f"engine exited (code {self.p.wait()}) on {obj}")
        return json.loads(line)

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def timed(s, obj):
    t0 = time.perf_counter()
    r = s.req(obj)
    return (time.perf_counter() - t0) * 1000, r


def pct(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def startup(args):
    times, rss = [], []
    with tempfile.TemporaryDirectory() as d:
        for _ in range(args.warm_disk):  # page cache / file system warm-up, not measured
            s = Session(args.engine, d)
            s.req({"op": "version"})
            s.close()
        for _ in range(args.runs):
            t0 = time.perf_counter()
            s = Session(args.engine, d)
            r = s.req({"op": "version"})
            times.append((time.perf_counter() - t0) * 1000)
            assert r.get("ok"), r
            rss.append(rss_kb(s.p.pid) / 1024)
            s.close()
    out = {"startup_ms": statistics.median(times), "p10": pct(times, 0.1), "p90": pct(times, 0.9),
           "rss_mb": statistics.median(rss)}
    print(json.dumps(out))
    if args.save:
        json.dump({**out, "all": times}, open(args.save, "w"))


def same(a, b):
    if isinstance(a, float) and isinstance(b, (int, float)) and not isinstance(b, bool):
        return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def canonical(sql, result):
    rows = result.get("rows")
    if rows is not None and "ORDER BY" not in sql.upper():
        rows = sorted(rows, key=json.dumps)
    return {"columns": result["columns"], "rows": rows, "row_count": result["row_count"]}


def run_round(engine, wl, queries, data, args, acc):
    """One fresh engine process: start-up, loading, each query cold then warm; accumulates into acc."""
    t0 = time.perf_counter()
    s = Session(engine, data)
    r = s.req({"op": "version"})
    acc["first"].append((time.perf_counter() - t0) * 1000)
    t1 = time.perf_counter()
    for name, dataset in wl["tables"].items():
        schema = json.load(open(os.path.join(data, args.scale, dataset + ".schema.json")))
        r = s.req({"op": "load", "table": name, "path": f"{args.scale}/{dataset}.csv", "format": "csv",
                   "schema": schema})
        assert r.get("ok"), r
    for ix in wl.get("indexes", []):
        r = s.req({"op": "query", "sql": ix["sql"]})
        assert r.get("ok"), r
    acc["load"].append((time.perf_counter() - t1) * 1000)
    acc["rss_loaded"].append(rss_kb(s.p.pid) / 1024)
    for q in queries:
        name, sql = q["name"], q["sql"]
        req = {"op": "query", "sql": sql}
        if q.get("result") == "count":
            req["options"] = {"result": "count"}
        times = []
        for rep in range(1 + args.warmup + args.reps):
            dt, r = timed(s, dict(req))
            assert r.get("ok"), (name, r)
            if rep == 0:
                acc["cold"].setdefault(name, []).append(dt)
                acc["results"].setdefault(name, canonical(sql, r))
            elif rep > args.warmup:
                times.append(dt)
        acc["warm"].setdefault(name, []).append(statistics.median(times))
    acc["hwm"].append(rss_kb(s.p.pid, "VmHWM") / 1024)
    s.close()
    print(f"{engine} round {len(acc['first'])}: start-up {acc['first'][-1]:.0f} ms, load {acc['load'][-1] / 1000:.1f} s, "
          f"cold total {sum(acc['cold'][q['name']][-1] for q in queries):.0f} ms, "
          f"warm total {sum(acc['warm'][q['name']][-1] for q in queries):.1f} ms, peak RSS {acc['hwm'][-1]:.0f} MB",
          file=sys.stderr, flush=True)


def summarize(acc):
    summary = {
        "startup_ms": statistics.median(acc["first"]), "load_ms": statistics.median(acc["load"]),
        "rss_loaded_mb": statistics.median(acc["rss_loaded"]), "peak_rss_mb": statistics.median(acc["hwm"]),
        "cold": {k: statistics.median(v) for k, v in acc["cold"].items()},
        "warm": {k: statistics.median(v) for k, v in acc["warm"].items()},
    }
    summary["cold_total"] = sum(summary["cold"].values())
    summary["warm_total"] = sum(summary["warm"].values())
    return summary


def workload(args):
    wl = json.load(open(args.workload))
    data = os.path.abspath(args.data)
    queries = wl["queries"]
    if args.only:
        wanted = set(args.only.split(","))
        queries = [q for q in queries if q["name"] in wanted]
    accs = [{"first": [], "load": [], "rss_loaded": [], "hwm": [], "cold": {}, "warm": {}, "results": {}}
            for _ in args.engine]
    for _ in range(args.rounds):  # engines alternate round by round, so load changes hit them alike
        for engine, acc in zip(args.engine, accs):
            run_round(engine, wl, queries, data, args, acc)
    failed = False
    for k, (engine, acc) in enumerate(zip(args.engine, accs)):
        summary = summarize(acc)
        results = acc["results"]
        save = args.save[k] if args.save and k < len(args.save) else None
        if save:
            json.dump({**summary, "cold_all": acc["cold"], "warm_all": acc["warm"], "results": results}, open(save, "w"))
        print(f"## {engine}")
        print(json.dumps({x: summary[x] for x in ("startup_ms", "load_ms", "rss_loaded_mb", "peak_rss_mb",
                                                   "cold_total", "warm_total")}))
        compare = args.compare or (args.save[0] if k > 0 and args.save else None)
        if compare:
            before = json.load(open(compare))
            bad = [q["name"] for q in queries if not same(before["results"][q["name"]], results[q["name"]])]
            print(f"| query | before cold | after cold | before warm | after warm |  ({compare})")
            print("|---|---:|---:|---:|---:|")
            for q in queries:
                n = q["name"]
                print(f"| {n} | {before['cold'][n]:.1f} | {summary['cold'][n]:.1f} | {before['warm'][n]:.2f} "
                      f"| {summary['warm'][n]:.2f} |")
            print(f"| **total** | {before['cold_total']:.1f} | {summary['cold_total']:.1f} | "
                  f"{before['warm_total']:.2f} | {summary['warm_total']:.2f} |")
            if bad:
                print("RESULTS DIFFER: " + ", ".join(bad), file=sys.stderr)
                failed = True
        else:
            print("| query | cold | warm |")
            print("|---|---:|---:|")
            for q in queries:
                print(f"| {q['name']} | {summary['cold'][q['name']]:.1f} | {summary['warm'][q['name']]:.2f} |")
    if failed:
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("startup")
    a.add_argument("--engine", required=True)
    a.add_argument("--runs", type=int, default=30)
    a.add_argument("--warm-disk", type=int, default=3)
    a.add_argument("--save")
    b = sub.add_parser("workload")
    b.add_argument("--engine", required=True, action="append",
                   help="launcher; repeat to compare engines (their rounds are interleaved)")
    b.add_argument("--data", required=True, help="pqgen output directory containing <scale>/")
    b.add_argument("--workload", required=True)
    b.add_argument("--scale", default="1m")
    b.add_argument("--reps", type=int, default=9)
    b.add_argument("--warmup", type=int, default=3)
    b.add_argument("--rounds", type=int, default=5)
    b.add_argument("--only", help="comma-separated query names")
    b.add_argument("--save", action="append", help="output file per --engine, in order")
    b.add_argument("--compare", help="earlier --save file to compare with (default with several engines: "
                                       "the first engine's)")
    args = ap.parse_args()
    startup(args) if args.cmd == "startup" else workload(args)


if __name__ == "__main__":
    main()
