#!/usr/bin/env python3
"""Times the analytics workload through `bin/polyquery session`.

Usage:
  python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
  python3 implementations/go/scripts/workload.py --data /tmp/pqdata/1m [--repeat 7] [--engine BIN] [--save out.json]
  python3 implementations/go/scripts/workload.py --compare before.json after.json

Loads every table of the workload from CSV (default options), runs each
query once to warm up and then `--repeat` times, and reports the median
client-side wall time in milliseconds (request written → response line
parsed, i.e. including result serialization). Queries use the default
options and return full results; `--save` also records a digest of every
result so that two runs (e.g. two engine builds) can be checked for
identical answers with `--compare`.
"""
import argparse
import hashlib
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "bin" / "polyquery"
WORKLOAD = HERE.parent / "benchmarks" / "analytics.json"


class Session:
    def __init__(self, data, engine):
        self.p = subprocess.Popen([str(engine), "session", "--data-dir", str(data)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
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


def digest(resp):
    if not resp.get("ok"):
        return "error:" + resp["error"]["code"]
    rows = resp["rows"]
    # FLOAT64 aggregates may differ in the last bits between summation orders.
    norm = [[float(f"{v:.9g}") if isinstance(v, float) else v for v in r] for r in rows]
    return hashlib.sha256(json.dumps([resp["columns"], norm]).encode()).hexdigest()[:16]


def run(args):
    workload = json.loads(Path(args.workload).read_text())
    s = Session(args.data, args.engine)
    for t in workload["tables"]:
        schema = json.loads((Path(args.data) / f"{t}.schema.json").read_text())
        t0 = time.monotonic()
        r = s.req({"op": "load", "table": t, "path": f"{t}.csv", "format": "csv", "schema": schema})
        if not r.get("ok"):
            sys.exit(f"load {t}: {r}")
        print(f"# loaded {t}: {r['row_count']} rows in {time.monotonic() - t0:.2f}s", file=sys.stderr)
    names = args.queries.split(",") if args.queries else None
    out = {}
    print("| query | rows | median ms | min ms |")
    print("|---|---:|---:|---:|")
    for q in workload["queries"]:
        if names and q["name"] not in names:
            continue
        req = {"op": "query", "sql": q["sql"]}
        r = s.req(dict(req))  # warm-up
        times = []
        for _ in range(args.repeat):
            t0 = time.monotonic()
            r = s.req(dict(req))
            times.append((time.monotonic() - t0) * 1000)
        rows = r["row_count"] if r.get("ok") else r["error"]["code"]
        med = statistics.median(times)
        out[q["name"]] = {"median_ms": med, "min_ms": min(times), "rows": rows, "digest": digest(r)}
        print(f"| {q['name']} | {rows} | {med:.1f} | {min(times):.1f} |", flush=True)
    s.close()
    total = sum(v["median_ms"] for v in out.values())
    print(f"| **total** | | {total:.1f} | |")
    if args.save:
        Path(args.save).write_text(json.dumps(out, indent=1))


def compare(before_path, after_path):
    before = json.loads(Path(before_path).read_text())
    after = json.loads(Path(after_path).read_text())
    print("| query | before ms | after ms | speedup |")
    print("|---|---:|---:|---:|")
    tb = ta = 0.0
    bad = []
    for name, b in before.items():
        a = after.get(name)
        if a is None:
            continue
        if a["digest"] != b["digest"]:
            bad.append(name)
        tb += b["median_ms"]
        ta += a["median_ms"]
        print(f"| {name} | {b['median_ms']:.1f} | {a['median_ms']:.1f} | {b['median_ms'] / max(a['median_ms'], 0.01):.2f}× |")
    print(f"| **total** | {tb:.1f} | {ta:.1f} | {tb / max(ta, 0.01):.2f}× |")
    if bad:
        sys.exit("results differ: " + ", ".join(bad))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data")
    ap.add_argument("--workload", default=str(WORKLOAD))
    ap.add_argument("--engine", default=str(ENGINE))
    ap.add_argument("--repeat", type=int, default=7)
    ap.add_argument("--queries", help="comma-separated query names (default: all)")
    ap.add_argument("--save", help="write timings and result digests to this JSON file")
    ap.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    args = ap.parse_args()
    if args.compare:
        compare(*args.compare)
    elif args.data:
        run(args)
    else:
        ap.error("--data or --compare required")


if __name__ == "__main__":
    main()
