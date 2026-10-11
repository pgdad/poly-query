#!/usr/bin/env python3
"""A/B latency comparison of two engine builds on the same queries.

Starts one session per engine, loads the given tables (generated CSV +
schema), then runs every query alternately on A and B (`--repeat` rounds,
after a warm-up) and reports the median and minimum engine-side elapsed
time (`stats.elapsed_us`) per engine. Alternating keeps drifting machine
load from favouring one side.

Usage:
  ab.py --a OLD/bin/polyquery --b NEW/bin/polyquery --data /tmp/pqdata/1m
        --tables transactions,customers [--repeat 21] [--options '{}']
        "SELECT ..." ["SELECT ..." ...]
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys


class Session:
    def __init__(self, engine: str, data: str):
        self.p = subprocess.Popen([engine, "session", "--data-dir", data], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def call(self, req: dict) -> dict:
        assert self.p.stdin and self.p.stdout
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def close(self) -> None:
        if self.p.stdin:
            self.p.stdin.close()
        self.p.wait()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--tables", required=True)
    ap.add_argument("--repeat", type=int, default=21)
    ap.add_argument("--options", default="{}")
    ap.add_argument("queries", nargs="+")
    args = ap.parse_args()
    opts = json.loads(args.options)
    opts.setdefault("result", "count")
    sessions = [Session(args.a, args.data), Session(args.b, args.data)]
    for s in sessions:
        for t in args.tables.split(","):
            schema = json.load(open(f"{args.data}/{t}.schema.json"))
            r = s.call({"op": "load", "table": t, "format": "csv", "path": f"{t}.csv", "schema": schema})
            assert r.get("ok"), r
    for q in args.queries:
        times: list[list[float]] = [[], []]
        for i, s in enumerate(sessions):
            for _ in range(2):
                r = s.call({"op": "query", "sql": q, "options": opts})
                if not r.get("ok"):
                    print(f"{'AB'[i]} failed: {r}", file=sys.stderr)
                    return 1
        for _ in range(args.repeat):
            for i, s in enumerate(sessions):
                r = s.call({"op": "query", "sql": q, "options": opts})
                times[i].append(r["stats"]["elapsed_us"] / 1000)
        a, b = times
        print(f"A {statistics.median(a):8.2f} (min {min(a):7.2f})  B {statistics.median(b):8.2f} "
              f"(min {min(b):7.2f})  ms  {q[:90]}", flush=True)
    for s in sessions:
        s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
