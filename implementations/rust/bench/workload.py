#!/usr/bin/env python3
"""Times the benchmark workload (benchmarks/workloads/analytics.json).

Loads the workload's tables (generated CSV + schema, `pqgen.py generate
--scale 1m --out DIR`) into one `bin/polyquery session`, creates the
workload's indexes, then runs every workload query with the default options
(plus `result: "count"` where the workload asks for it). Each query runs
`--warmup` times untimed and `--repeat` times timed; the client-side
wall-clock median and minimum (milliseconds) are reported.

`--save FILE` writes a digest of every query's response (rows or row count)
and `--check FILE` compares against such a file, so result changes between
engine versions are detected.

Usage:
  workload.py --engine bin/polyquery --data /tmp/pqdata/1m
              [--workload benchmarks/workloads/analytics.json]
              [--repeat 15] [--warmup 2] [--only q01,q06]
              [--options '{"threads":8}'] [--save F] [--check F]
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
DEFAULT_WORKLOAD = os.path.join(HERE, "..", "..", "..", "benchmarks", "workloads", "analytics.json")


class Session:
    def __init__(self, engine: str, data: str):
        self.p = subprocess.Popen([engine, "session", "--data-dir", data], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        self.n = 0

    def call_raw(self, req: dict) -> str:
        self.n += 1
        req["id"] = self.n
        assert self.p.stdin and self.p.stdout
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        return self.p.stdout.readline()

    def call(self, req: dict) -> dict:
        return json.loads(self.call_raw(req))

    def close(self) -> None:
        if self.p.stdin:
            self.p.stdin.close()
        self.p.wait()


def digest(resp: dict) -> str:
    if not resp.get("ok"):
        return "error:" + resp.get("error", {}).get("code", "?")
    body = {"columns": resp.get("columns"), "row_count": resp.get("row_count"), "rows": resp.get("rows")}
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--workload", default=DEFAULT_WORKLOAD)
    ap.add_argument("--repeat", type=int, default=15)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--only", default="")
    ap.add_argument("--options", default="{}", help="extra query options (JSON object)")
    ap.add_argument("--save")
    ap.add_argument("--check")
    args = ap.parse_args()
    wl = json.load(open(args.workload))
    only = [s.strip() for s in args.only.split(",") if s.strip()]
    extra = json.loads(args.options)

    s = Session(args.engine, args.data)
    t0 = time.monotonic()
    for name, base in wl["tables"].items():
        schema = json.load(open(f"{args.data}/{base}.schema.json"))
        r = s.call({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        if not r.get("ok"):
            print(f"load {name} failed: {r}", file=sys.stderr)
            return 1
    for ix in wl.get("indexes", []):
        r = s.call({"op": "query", "sql": ix["sql"]})
        if not r.get("ok"):
            print(f"index failed: {r}", file=sys.stderr)
            return 1
    print(f"# loaded {len(wl['tables'])} tables in {time.monotonic() - t0:.1f}s", flush=True)

    digests = {}
    expected = json.load(open(args.check)) if args.check else {}
    mismatches = 0
    print("| query | median ms | min ms |")
    print("|---|---:|---:|")
    for q in wl["queries"]:
        if only and not any(q["name"].startswith(o) for o in only):
            continue
        opts = dict(extra)
        if q.get("result"):
            opts["result"] = q["result"]
        req = {"op": "query", "sql": q["sql"], "options": opts}
        first = s.call(dict(req))
        digests[q["name"]] = digest(first)
        for _ in range(max(0, args.warmup - 1)):
            s.call_raw(dict(req))
        times = []
        for _ in range(args.repeat):
            t = time.perf_counter()
            s.call_raw(dict(req))
            times.append((time.perf_counter() - t) * 1000)
        note = ""
        if not first.get("ok"):
            note = f" ERROR {first.get('error')}"
        if expected and expected.get(q["name"]) not in (None, digests[q["name"]]):
            note += " RESULT MISMATCH"
            mismatches += 1
        print(f"| {q['name']} | {statistics.median(times):.2f} | {min(times):.2f} |{note}", flush=True)
    s.close()
    if args.save:
        with open(args.save, "w") as f:
            json.dump(digests, f, indent=1)
    if mismatches:
        print(f"# {mismatches} result mismatches", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
