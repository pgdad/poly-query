#!/usr/bin/env python3
"""Benchmarks the execution options on generated datasets (development tool).

  python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
  python3 tools/bench.py --engine bin/polyquery --data /tmp/pqdata --scale 1m [--reps 5]

Loads the tables once into one session, then runs every query under every configuration
(warm-up runs first) and prints the median wall time per query in milliseconds as a
Markdown table. Results are only counted (`result: count`), so serialization is excluded.
"""
import argparse
import json
import statistics
import subprocess
import time

TABLES = {
    "tx": "transactions", "cust": "customers", "orders": "orders", "items": "order_items",
    "products": "products", "sensor": "sensor_readings", "nh": "nulls_heavy", "sk": "sort_keys",
}

QUERIES = [
    ("Q1 filter+agg", "SELECT COUNT(*), SUM(amount), AVG(fee) FROM tx WHERE status = 'approved' AND amount > 100"),
    ("Q2 group by (low card.)",
     "SELECT category, COUNT(*), SUM(amount), MIN(ts), MAX(amount) FROM tx GROUP BY category"),
    ("Q3 group by (high card.)", "SELECT customer_id, COUNT(*), SUM(amount) FROM tx GROUP BY customer_id"),
    ("Q4 join+group", "SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c "
                      "ON c.customer_id = t.customer_id GROUP BY c.segment"),
    ("Q5 3-way join", "SELECT p.category, SUM(i.quantity * i.unit_price) FROM orders o JOIN items i "
                      "ON i.order_id = o.order_id JOIN products p ON p.product_id = i.product_id "
                      "WHERE o.status = 'delivered' GROUP BY p.category"),
    ("Q6 top-N", "SELECT tx_id, amount FROM tx WHERE status = 'approved' ORDER BY amount DESC, tx_id LIMIT 10"),
    ("Q7 sort", "SELECT id, float_key FROM sk ORDER BY float_key"),
    ("Q8 sensor avg", "SELECT sensor_id, AVG(temperature), MAX(humidity) FROM sensor GROUP BY sensor_id"),
    ("Q9 distinct", "SELECT DISTINCT merchant_id, category FROM tx"),
    ("Q10 string filter", "SELECT COUNT(*) FROM cust WHERE email LIKE '%1@example.com' AND country IN ('US', 'GB')"),
    ("Q11 projection", "SELECT tx_id, amount * 2 + fee, UPPER(currency) FROM tx WHERE bucket < 500"),
    ("Q12 nulls", "SELECT n50 % 10, COUNT(*), SUM(n90), COUNT(f95) FROM nh GROUP BY 1"),
]

CONFIGS = [
    ("row, unoptimized (baseline)", {"mode": "row", "threads": 1, "optimize": False, "join": "auto"}),
    ("row, optimized", {"mode": "row", "threads": 1, "optimize": True, "join": "auto"}),
    ("vectorized, 1 thread", {"mode": "vectorized", "threads": 1, "optimize": True, "join": "auto"}),
    ("vectorized, 4 threads", {"mode": "vectorized", "threads": 4, "optimize": True, "join": "auto"}),
    ("vectorized, 16 threads", {"mode": "vectorized", "threads": 16, "optimize": True, "join": "auto"}),
]


class Session:
    def __init__(self, launcher, data, jvm):
        import os
        env = dict(os.environ)
        if jvm:
            env["POLYQUERY_JAVA_OPTS"] = jvm
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, env=env)
        self.n = 0

    def req(self, obj):
        self.n += 1
        obj["id"] = self.n
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--scale", default="1m")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--jvm", default="")
    ap.add_argument("--only", help="comma-separated query name prefixes")
    args = ap.parse_args()
    s = Session(args.engine, args.data, args.jvm)
    for name, base in TABLES.items():
        schema = json.load(open(f"{args.data}/{args.scale}/{base}.schema.json"))
        t0 = time.time()
        r = s.req({"op": "load", "table": name, "path": f"{args.scale}/{base}.csv", "format": "csv",
                   "schema": schema})
        assert r.get("ok"), r
        print(f"loaded {name}: {r['row_count']} rows in {time.time() - t0:.1f}s", flush=True)
    queries = QUERIES
    if args.only:
        prefixes = args.only.split(",")
        queries = [q for q in QUERIES if any(q[0].startswith(p + " ") for p in prefixes)]
    header = "| query | " + " | ".join(c[0] for c in CONFIGS) + " |"
    lines = [header, "|" + "---|" * (len(CONFIGS) + 1)]
    for qname, sql in queries:
        cells = []
        counts = set()
        for cname, opts in CONFIGS:
            o = dict(opts)
            o["result"] = "count"
            times = []
            for rep in range(args.reps + 2):
                t0 = time.perf_counter()
                r = s.req({"op": "query", "sql": sql, "options": o})
                dt = (time.perf_counter() - t0) * 1000
                assert r.get("ok"), (qname, cname, r)
                counts.add(r["row_count"])
                if rep >= 2:
                    times.append(dt)
            cells.append(f"{statistics.median(times):.0f}")
        assert len(counts) == 1, (qname, counts)
        lines.append(f"| {qname} | " + " | ".join(cells) + " |")
        print(lines[-1], flush=True)
    print()
    print("\n".join(lines))


if __name__ == "__main__":
    main()
