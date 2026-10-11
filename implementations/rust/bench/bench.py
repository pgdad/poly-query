#!/usr/bin/env python3
"""Micro-benchmark for the PolyQuery Rust engine (Phase 5 measurements).

Loads the generated datasets (pqgen.py generate --scale 1m --out DIR) through
the session protocol and times a fixed set of queries under several option
combinations. Each query runs `--repeat` times; the best wall-clock time is
reported (milliseconds, `result: "count"` so serialization is excluded).

Usage:
  bench.py --engine bin/polyquery --data /tmp/pqdata/1m [--repeat 3]
           [--variant '{"mode":"row","threads":1}' ...] [--only Q1,Q4]
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
]


class Session:
    def __init__(self, engine: str, data: str):
        self.p = subprocess.Popen([engine, "session", "--data-dir", data], stdin=subprocess.PIPE,
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
    args = ap.parse_args()
    variants = [json.loads(v) for v in args.variant] or [{}]
    only = {s.strip() for s in args.only.split(",") if s.strip()}

    s = Session(args.engine, args.data)
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
        cells = []
        counts = set()
        for v in variants:
            best = None
            for _ in range(args.repeat):
                opts = dict(v)
                opts["result"] = "count"
                t = time.monotonic()
                r = s.call({"op": "query", "sql": sql, "options": opts})
                dt = (time.monotonic() - t) * 1000
                if not r.get("ok"):
                    cells.append("error " + r.get("error", {}).get("code", "?"))
                    break
                counts.add(r.get("row_count"))
                best = dt if best is None else min(best, dt)
            else:
                cells.append(f"{best:.0f}")
        note = "" if len(counts) <= 1 else f" (row counts differ: {sorted(counts)})"
        print(f"| {label} | " + " | ".join(cells) + f" |{note}", flush=True)
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
