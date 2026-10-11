#!/usr/bin/env python3
"""PolyQuery Clojure engine — latency of the benchmark workload.

Runs the queries of benchmarks/workloads/analytics.json (default options)
through one `bin/polyquery session` over the generated datasets
(datasets/generators/pqgen.py generate --scale 1m) and prints, per query,
the first (cold) run and the median of the warm runs, wall clock measured
by the client including the protocol round trip.

usage: workload.py DATA_DIR [--runs N] [--warmup N] [--only q01,q02]
       workload.py DATA_DIR --digest FILE   # write result digests (no timing)
       workload.py DATA_DIR --check FILE    # compare result digests with FILE
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
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE.parent / "bin" / "polyquery"
WORKLOAD = HERE.parents[2] / "benchmarks" / "workloads" / "analytics.json"


class Session:
    def __init__(self, data_dir: str, launcher: str, java_opts: str | None):
        env = dict(os.environ)
        if java_opts is not None:
            env["POLYQUERY_JAVA_OPTS"] = java_opts
        self.proc = subprocess.Popen([launcher, "session", "--data-dir", data_dir],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.n = 0

    def request(self, req: dict) -> dict:
        self.n += 1
        self.proc.stdin.write(json.dumps(dict(req, id=self.n)) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("engine exited")
        return json.loads(line)

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait(timeout=60)


def digest(sql: str, rows: list) -> str:
    norm = lambda v: f"{v:.9g}" if isinstance(v, float) else json.dumps(v)
    lines = ["|".join(norm(v) for v in row) for row in rows]
    if "ORDER BY" not in sql:
        lines.sort()
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16] + f" ({len(lines)} rows)"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir")
    ap.add_argument("--runs", type=int, default=9)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--only")
    ap.add_argument("--java-opts", default=None, help="POLYQUERY_JAVA_OPTS (default: inherit)")
    ap.add_argument("--engine", default=str(LAUNCHER))
    ap.add_argument("--workload", default=str(WORKLOAD))
    ap.add_argument("--digest", metavar="FILE", help="write result digests to FILE")
    ap.add_argument("--check", metavar="FILE", help="compare result digests with FILE")
    args = ap.parse_args()

    wl = json.loads(Path(args.workload).read_text())
    s = Session(args.data_dir, args.engine, args.java_opts)
    for t, f in wl["tables"].items():
        schema = json.loads((Path(args.data_dir) / f"{f}.schema.json").read_text())
        t0 = time.monotonic()
        r = s.request({"op": "load", "table": t, "path": f"{f}.csv", "format": "csv", "schema": schema})
        if not r.get("ok"):
            print(f"load {t} failed: {r}", file=sys.stderr)
            return 1
        print(f"loaded {t}: {r['row_count']} rows in {time.monotonic() - t0:.1f}s", file=sys.stderr)
    for ix in wl.get("indexes", []):
        r = s.request({"op": "query", "sql": ix["sql"]})
        if not r.get("ok"):
            print(f"index failed: {r}", file=sys.stderr)
            return 1

    only = set(args.only.split(",")) if args.only else None
    queries = [q for q in wl["queries"] if not only or q["name"].split("_")[0] in only]

    if args.digest or args.check:
        got = {}
        for q in queries:
            r = s.request({"op": "query", "sql": q["sql"]})
            got[q["name"]] = digest(q["sql"], r["rows"]) if r.get("ok") else "error " + r["error"]["code"]
            print(f"{q['name']}: {got[q['name']]}", flush=True)
        s.close()
        if args.digest:
            Path(args.digest).write_text(json.dumps(got, indent=1) + "\n")
            return 0
        want = json.loads(Path(args.check).read_text())
        bad = [n for n in got if want.get(n) != got[n]]
        for n in bad:
            print(f"MISMATCH {n}: expected {want.get(n)}, got {got[n]}")
        print("all results match" if not bad else f"{len(bad)} mismatches")
        return 1 if bad else 0

    print("| query | first run | warm median | warm min |")
    print("|---|---:|---:|---:|")
    for q in queries:
        opts = {"result": "count"} if q.get("result") == "count" else {}
        times = []
        for i in range(1 + args.warmup + args.runs):
            t0 = time.monotonic()
            r = s.request({"op": "query", "sql": q["sql"], "options": opts})
            times.append(time.monotonic() - t0)
            if not r.get("ok"):
                print(f"{q['name']} failed: {r}", file=sys.stderr)
                break
        warm = times[1 + args.warmup:]
        ms = lambda x: f"{x * 1000:.1f} ms"
        print(f"| {q['name']} | {ms(times[0])} | {ms(statistics.median(warm)) if warm else 'error'} | "
              f"{ms(min(warm)) if warm else 'error'} |", flush=True)
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
