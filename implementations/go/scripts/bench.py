#!/usr/bin/env python3
"""Micro-benchmark for the PolyQuery Go engine (Phase 5 measurements).

Usage:
  python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
  python3 implementations/go/scripts/bench.py --data /tmp/pqdata/1m [--configs row1,vec1,vec8] [--repeat 3]

Starts `bin/polyquery session --data-dir DATA`, loads the generated tables and
runs every query under every configuration, printing the median wall time
(client side, ms) of `--repeat` runs. Queries use `result: "count"` so
response serialization does not dominate.
"""
import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "bin" / "polyquery"

TABLES = {
    "tx": "transactions", "cust": "customers", "orders": "orders",
    "items": "order_items", "products": "products", "sensors": "sensor_readings",
    "sk": "sort_keys",
}

QUERIES = {
    "filter_count": "SELECT COUNT(*) FROM tx WHERE amount > 500 AND status = 'approved'",
    "agg_lowcard": "SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(ts), MAX(merchant_id) FROM tx GROUP BY category",
    "agg_highcard": "SELECT customer_id, COUNT(*), SUM(amount) FROM tx GROUP BY customer_id",
    "agg_expr": "SELECT bucket % 10 AS b, COUNT(*), SUM(fee * 2), MAX(ts) FROM tx WHERE is_fraud = FALSE GROUP BY bucket % 10",
    "sensor_agg": "SELECT sensor_id, AVG(temperature), MAX(humidity), MIN(pressure) FROM sensors WHERE status = 'ok' GROUP BY sensor_id",
    "items_sum": "SELECT SUM(quantity * unit_price), COUNT(discount) FROM items WHERE quantity >= 3",
    "join_agg": "SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment",
    "join_big": "SELECT o.status, SUM(i.quantity), COUNT(*) FROM items i JOIN orders o ON o.order_id = i.order_id GROUP BY o.status",
    "join_filter": "SELECT COUNT(*) FROM orders o JOIN cust c ON o.customer_id = c.customer_id WHERE c.segment = 'enterprise' AND o.status = 'paid'",
    "topn": "SELECT tx_id, amount FROM tx ORDER BY amount DESC, tx_id LIMIT 10",
    "sort_full": "SELECT id, str_key FROM sk ORDER BY str_key, id",
    "distinct": "SELECT DISTINCT merchant_id FROM tx",
    "const_fold": "SELECT COUNT(*) FROM tx WHERE amount > 100 * 5 + 0 AND 1 = 1 AND fee >= CAST('0.50' AS DECIMAL(10,2))",
}

CONFIGS = {
    "row1": {"mode": "row", "threads": 1},
    "row1_noopt": {"mode": "row", "threads": 1, "optimize": False},
    "vec1": {"mode": "vectorized", "threads": 1},
    "vec4": {"mode": "vectorized", "threads": 4},
    "vec8": {"mode": "vectorized", "threads": 8},
    "row8": {"mode": "row", "threads": 8},
    "vec8_hash": {"mode": "vectorized", "threads": 8, "join": "hash"},
    "vec8_merge": {"mode": "vectorized", "threads": 8, "join": "merge"},
    "row1_merge": {"mode": "row", "threads": 1, "join": "merge"},
}


class Session:
    def __init__(self, data):
        self.p = subprocess.Popen([str(ENGINE), "session", "--data-dir", str(data)],
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--configs", default="row1,vec1,vec8")
    ap.add_argument("--queries", default=",".join(QUERIES))
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--layout", default="column")
    args = ap.parse_args()
    s = Session(args.data)
    for t, f in TABLES.items():
        schema = json.loads((Path(args.data) / f"{f}.schema.json").read_text())
        t0 = time.monotonic()
        r = s.req({"op": "load", "table": t, "path": f"{f}.csv", "format": "csv", "schema": schema,
                   "options": {"layout": args.layout}})
        if not r.get("ok"):
            sys.exit(f"load {t}: {r}")
        print(f"# loaded {t}: {r['row_count']} rows in {time.monotonic() - t0:.2f}s", file=sys.stderr)
    configs = args.configs.split(",")
    print("| query | " + " | ".join(configs) + " |")
    print("|---|" + "---:|" * len(configs))
    for q in args.queries.split(","):
        cells = []
        for c in configs:
            times = []
            rc = None
            for _ in range(args.repeat):
                t0 = time.monotonic()
                r = s.req({"op": "query", "sql": QUERIES[q], "options": {**CONFIGS[c], "result": "count", "timeout_ms": 120000}})
                times.append((time.monotonic() - t0) * 1000)
                if not r.get("ok"):
                    rc = r["error"]["code"]
                    break
                rc = r["row_count"]
            cells.append(f"{statistics.median(times):.0f}" if isinstance(rc, int) else str(rc))
        print(f"| {q} | " + " | ".join(cells) + " |", flush=True)
    s.close()


if __name__ == "__main__":
    main()
