#!/usr/bin/env python3
"""Micro-benchmark for the PolyQuery Rust engine (Phase 5 measurements).

Loads the generated datasets (pqgen.py generate --scale 1m --out DIR) through
the session protocol and times a fixed set of queries under several option
combinations. Each query runs `--repeat` times; the best wall-clock time is
reported (milliseconds, `result: "count"` so serialization is excluded).

Queries N1-N10 exercise the native kernels (`native: true`, which needs
`--native LIB` so that the engine loads libpqkernels).

Usage:
  bench.py --engine bin/polyquery --data /tmp/pqdata/1m [--repeat 3]
           [--variant '{"mode":"row","threads":1}' ...] [--only Q1,Q4]
           [--native native-kernels/build/x86_64/libpqkernels.so]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time

TABLES = [
    ("tx", "transactions"),
    ("cust", "customers"),
    ("orders", "orders"),
    ("items", "order_items"),
    ("products", "products"),
    ("sensor", "sensor_readings"),
    ("sortk", "sort_keys"),
]

QUERIES = [
    ("Q1 filter+count", "SELECT COUNT(*) FROM tx WHERE amount > 500 AND status = 'approved'"),
    ("Q2 group low-card", "SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(ts), MAX(amount) "
                          "FROM tx GROUP BY category"),
    ("Q3 group high-card", "SELECT customer_id, COUNT(*), SUM(amount) FROM tx GROUP BY customer_id"),
    ("Q4 join+group", "SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c "
                      "ON c.customer_id = t.customer_id GROUP BY c.segment"),
    ("Q5 1M x 250k join", "SELECT o.status, SUM(i.quantity * i.unit_price) FROM orders o JOIN items i "
                          "ON i.order_id = o.order_id GROUP BY o.status"),
    ("Q6 top-N", "SELECT tx_id, amount FROM tx WHERE status = 'approved' ORDER BY amount DESC, tx_id LIMIT 10"),
    ("Q7 full sort", "SELECT id, uniq_key FROM sortk ORDER BY uniq_key"),
    ("Q8 arithmetic", "SELECT SUM(temperature * 1.8 + 32), AVG(humidity) FROM sensor WHERE pressure > 1000"),
    ("Q9 3-way join", "SELECT p.category, SUM(i.quantity) FROM items i JOIN orders o ON o.order_id = i.order_id "
                      "JOIN products p ON p.product_id = i.product_id WHERE o.status = 'delivered' "
                      "GROUP BY p.category"),
    ("Q10 distinct", "SELECT DISTINCT merchant_id FROM tx"),
    ("Q11 join order", "SELECT COUNT(*), SUM(i.quantity) FROM items i JOIN products p ON p.product_id = i.product_id "
                       "JOIN orders o ON o.order_id = i.order_id JOIN cust c ON c.customer_id = o.customer_id "
                       "WHERE c.segment = 'public_sector' AND o.status = 'returned'"),
    ("Q12 high-card group", "SELECT tx_id % 500000, COUNT(*), MAX(ts), MIN(category) FROM tx GROUP BY 1"),
    # Native kernel shapes.
    ("N1 selective range, wide rows", "SELECT tx_id, customer_id, merchant_id, amount, currency, category, ts, "
                                      "status FROM tx WHERE customer_id BETWEEN 1000 AND 1999"),
    ("N2 int+decimal filter+count", "SELECT COUNT(*) FROM tx WHERE merchant_id < 2500 AND amount >= 100.5"),
    ("N3 filter+global aggs", "SELECT COUNT(*), SUM(quantity), MIN(unit_price), MAX(unit_price) FROM items "
                              "WHERE quantity >= 5 AND discount IS NOT NULL"),
    ("N4 global aggs", "SELECT SUM(amount), SUM(fee), MIN(ts), MAX(ts), COUNT(fee), SUM(bucket) FROM tx"),
    ("N5 date filter", "SELECT COUNT(*) FROM orders WHERE order_date >= DATE '2024-01-01' AND item_count > 3"),
    ("N6 column compare", "SELECT COUNT(*) FROM sortk WHERE dup_key < uniq_key AND id > 100"),
    ("N7 group by int key", "SELECT merchant_id, SUM(amount), COUNT(*) FROM tx GROUP BY merchant_id"),
    ("N8 int join", "SELECT COUNT(*), SUM(i.quantity) FROM items i JOIN orders o ON o.order_id = i.order_id "
                    "WHERE o.item_count > 2"),
    ("N9 float min/max", "SELECT MIN(temperature), MAX(pressure), MIN(humidity) FROM sensor"),
    ("N10 filter + residual", "SELECT COUNT(*) FROM tx WHERE customer_id < 20000 AND amount * 2 > fee"),
]


class Session:
    def __init__(self, engine: str, data: str, extra=()):
        self.p = subprocess.Popen([engine, "session", "--data-dir", data, *extra], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        self.n = 0

    def call(self, req: dict) -> dict:
        self.n += 1
        req["id"] = self.n
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
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--variant", action="append", default=[])
    ap.add_argument("--only", default="")
    ap.add_argument("--native", metavar="LIB", help="pass --native-kernels LIB to the engine")
    args = ap.parse_args()
    variants = [json.loads(v) for v in args.variant] or [{}]
    only = {s.strip() for s in args.only.split(",") if s.strip()}

    s = Session(args.engine, args.data, ["--native-kernels", args.native] if args.native else [])
    t0 = time.monotonic()
    for name, base in TABLES:
        schema = json.load(open(f"{args.data}/{base}.schema.json"))
        r = s.call({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        if not r.get("ok"):
            print(f"load {name} failed: {r}", file=sys.stderr)
            return 1
    print(f"# loaded {len(TABLES)} tables in {time.monotonic() - t0:.1f}s", flush=True)

    header = "| query | " + " | ".join(json.dumps(v) if v else "default" for v in variants) + " |"
    print(header)
    print("|" + "---|" * (len(variants) + 1))
    for label, sql in QUERIES:
        if only and label.split()[0] not in only:
            continue
        counts = set()
        best: list = [None] * len(variants)
        failed: list = [None] * len(variants)
        # Round-robin over the variants, so drifting machine load affects
        # all of them alike.
        for _ in range(args.repeat):
            for i, v in enumerate(variants):
                if failed[i]:
                    continue
                opts = dict(v)
                opts["result"] = "count"
                t = time.monotonic()
                r = s.call({"op": "query", "sql": sql, "options": opts})
                dt = (time.monotonic() - t) * 1000
                if not r.get("ok"):
                    failed[i] = "error " + r.get("error", {}).get("code", "?")
                    continue
                counts.add(r.get("row_count"))
                best[i] = dt if best[i] is None else min(best[i], dt)
        cells = [failed[i] or f"{best[i]:.1f}" for i in range(len(variants))]
        note = "" if len(counts) <= 1 else f" (row counts differ: {sorted(counts)})"
        print(f"| {label} | " + " | ".join(cells) + f" |{note}", flush=True)
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
