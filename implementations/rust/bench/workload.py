#!/usr/bin/env python3
"""Times the benchmark workload (benchmarks/workloads/analytics.json).

Loads the workload's tables (generated CSV + schema, `pqgen.py generate
--scale 1m --out DIR`) into one `bin/polyquery session` per engine, creates
the workload's indexes, then runs every workload query with the default
options (plus `result: "count"` where the workload asks for it). Each query
runs `--warmup` times untimed and `--repeat` times timed per engine; with
several engines the timed runs alternate between them, so drifting machine
load affects all alike. Reported: client-side wall-clock median and
minimum (milliseconds) per engine, and the median speedup of the last
engine over the first.

`--save FILE` writes a digest of every query's response (rows or row
count; FLOAT64 rounded to 9 significant digits) of the last engine, and
`--check FILE` compares every engine against such a file.

Usage:
  workload.py --engine bin/polyquery [--engine OTHER/bin/polyquery ...]
              --data /tmp/pqdata/1m
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
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
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
    """Digest of a response; FLOAT64 values are rounded to 9 significant
    digits (their summation order, hence last bits, may vary with threads)."""
    if not resp.get("ok"):
        return "error:" + resp.get("error", {}).get("code", "?")
    rows = resp.get("rows")
    if rows is not None:
        rows = [[f"{v:.9g}" if isinstance(v, float) else v for v in row] for row in rows]
    body = {"columns": resp.get("columns"), "row_count": resp.get("row_count"), "rows": rows}
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]


def load(s: Session, wl: dict, data: str) -> None:
    for name, base in wl["tables"].items():
        schema = json.load(open(f"{data}/{base}.schema.json"))
        r = s.call({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        if not r.get("ok"):
            raise SystemExit(f"load {name} failed: {r}")
    for ix in wl.get("indexes", []):
        r = s.call({"op": "query", "sql": ix["sql"]})
        if not r.get("ok"):
            raise SystemExit(f"index failed: {r}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", action="append", required=True)
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

    sessions = []
    for e in args.engine:
        t0 = time.monotonic()
        s = Session(e, args.data)
        load(s, wl, args.data)
        print(f"# {e}: loaded {len(wl['tables'])} tables in {time.monotonic() - t0:.1f}s", flush=True)
        sessions.append(s)

    digests = {}
    expected = json.load(open(args.check)) if args.check else {}
    mismatches = 0
    names = [f"engine {i + 1}" for i in range(len(sessions))]
    head = "| query | " + " | ".join(f"{n} median ms | {n} min ms" for n in names)
    if len(sessions) > 1:
        head += " | speedup (median)"
    print(head + " |")
    print("|---|" + "---:|" * (2 * len(sessions) + (len(sessions) > 1)))
    totals = [0.0] * len(sessions)
    for q in wl["queries"]:
        if only and not any(q["name"].startswith(o) for o in only):
            continue
        opts = dict(extra)
        if q.get("result"):
            opts["result"] = q["result"]
        req = {"op": "query", "sql": q["sql"], "options": opts}
        note = ""
        for i, s in enumerate(sessions):
            first = s.call(dict(req))
            d = digest(first)
            if not first.get("ok"):
                note += f" ERROR({names[i]}) {first.get('error')}"
            if expected and expected.get(q["name"]) not in (None, d):
                note += f" RESULT MISMATCH ({names[i]})"
                mismatches += 1
            digests[q["name"]] = d
            for _ in range(max(0, args.warmup - 1)):
                s.call_raw(dict(req))
        times: list[list[float]] = [[] for _ in sessions]
        for _ in range(args.repeat):
            for i, s in enumerate(sessions):
                t = time.perf_counter()
                s.call_raw(dict(req))
                times[i].append((time.perf_counter() - t) * 1000)
        meds = [statistics.median(t) for t in times]
        for i, m in enumerate(meds):
            totals[i] += m
        cells = " | ".join(f"{statistics.median(t):.2f} | {min(t):.2f}" for t in times)
        if len(sessions) > 1:
            cells += f" | {meds[0] / meds[-1]:.1f}x"
        print(f"| {q['name']} | {cells} |{note}", flush=True)
    total = " | ".join(f"{t:.1f} | " for t in totals)
    if len(sessions) > 1:
        total += f" | {totals[0] / totals[-1]:.1f}x"
    print(f"| **sum of medians** | {total} |")
    for s in sessions:
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
