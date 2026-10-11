#!/usr/bin/env python3
"""Combines `workload.py --save` result files into a before/after table.

Timed runs of all BEFORE files are pooled per query (likewise AFTER), so
alternating before/after sessions (B, A, B, A) spread machine-load drift
over both sides. Results of every file are checked against the first
BEFORE file (same comparison rules as workload.py --compare).

  combine.py --workload bench/workloads/analytics.json \
      --before b1.json,b2.json --after a1.json,a2.json
"""
import argparse
import json
import statistics
import sys

from workload import rows_equal


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workload", required=True)
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    args = ap.parse_args()
    wl = json.load(open(args.workload))
    before = [json.load(open(f)) for f in args.before.split(",")]
    after = [json.load(open(f)) for f in args.after.split(",")]
    print("| query | description | before median (ms) | after median (ms) | speedup | result |")
    print("|---|---|---:|---:|---:|---|")
    tb = ta = 0.0
    bad = 0
    for q in wl["queries"]:
        ref = before[0]["queries"][q["id"]]
        tbq = statistics.median(t for r in before for t in r["queries"][q["id"]]["times_ms"])
        taq = statistics.median(t for r in after for t in r["queries"][q["id"]]["times_ms"])
        same = all(
            r["queries"][q["id"]]["columns"] == ref["columns"]
            and rows_equal(ref["columns"], r["queries"][q["id"]]["rows"], ref["rows"], q["ordered"])
            for r in before + after
        )
        bad += not same
        tb += tbq
        ta += taq
        print(f"| {q['id']} | {q['name']} | {tbq:.1f} | {taq:.1f} | {tbq / taq:.2f}x | "
              f"{'identical' if same else 'DIFFERENT'} |")
    print(f"| **sum** | | **{tb:.1f}** | **{ta:.1f}** | **{tb / ta:.2f}x** | |")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
