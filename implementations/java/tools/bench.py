#!/usr/bin/env python3
"""Benchmarks the execution options on generated datasets (development tool).

  python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
  python3 tools/bench.py --engine bin/polyquery --data /tmp/pqdata --scale 1m [--reps 5]
  python3 tools/bench.py ... --native-kernels ../../native-kernels/build/x86_64/libpqkernels.so \
      --native-pairs --verify          # each vectorized configuration without / with `native: true`

Loads the tables once into one session, then runs every query under every configuration
(warm-up runs first) and prints the median wall time per query in milliseconds as a
Markdown table. Results are only counted (`result: count`), so serialization is excluded.
With --verify, every configuration's full result must be identical to the first
configuration's result with the same options except `native` (or, for the first, to itself).
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
    ("Q14 conjunctive filter", "SELECT COUNT(*) FROM tx WHERE bucket < 500 AND merchant_id > 10 AND customer_id <> 7"),
    ("Q15 reductions", "SELECT SUM(tx_id), MIN(bucket), MAX(merchant_id), COUNT(*) FROM tx"),
    ("Q16 left join", "SELECT o.status, COUNT(i.order_id), SUM(i.quantity) FROM orders o LEFT JOIN items i "
                      "ON i.order_id = o.order_id GROUP BY o.status"),
    ("Q17 range filter", "SELECT COUNT(*), SUM(merchant_id) FROM tx WHERE tx_id BETWEEN 100000 AND 900000 "
                         "AND bucket >= 100 AND customer_id <> merchant_id"),
    ("Q18 int group sums", "SELECT merchant_id, SUM(tx_id), SUM(bucket), COUNT(*) FROM tx GROUP BY merchant_id"),
    ("Q19 null aggregates", "SELECT COUNT(n50), COUNT(n90), MIN(n50), MAX(n90), SUM(n50), MIN(d99) FROM nh"),
    ("Q20 filter on nulls", "SELECT COUNT(*), SUM(id) FROM nh WHERE n50 > 100 AND n90 IS NOT NULL"),
    ("Q13 join order", "SELECT COUNT(*), SUM(i.quantity) FROM items i JOIN orders o ON o.order_id = i.order_id "
                       "JOIN products p ON p.product_id = i.product_id JOIN cust c ON c.customer_id = o.customer_id "
                       "WHERE c.country = 'FI' AND p.category = 'books'"),
]

CONFIGS = [
    ("row, unoptimized (baseline)", {"mode": "row", "threads": 1, "optimize": False, "join": "auto"}),
    ("row, optimized", {"mode": "row", "threads": 1, "optimize": True, "join": "auto"}),
    ("vectorized, 1 thread", {"mode": "vectorized", "threads": 1, "optimize": True, "join": "auto"}),
    ("vectorized, 4 threads", {"mode": "vectorized", "threads": 4, "optimize": True, "join": "auto"}),
    ("vectorized, 16 threads", {"mode": "vectorized", "threads": 16, "optimize": True, "join": "auto"}),
]


def same(a, b, tolerant):
    """Equal results; with `tolerant`, FLOAT64 values may differ by rounding (parallel float sums
    depend on how morsels were distributed over the workers, with or without native kernels)."""
    if tolerant and isinstance(a, float) and isinstance(b, (int, float)):
        return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y, tolerant) for x, y in zip(a, b))
    return a == b


class Session:
    def __init__(self, launcher, data, jvm, native=None):
        import os
        env = dict(os.environ)
        if jvm:
            env["POLYQUERY_JAVA_OPTS"] = jvm
        extra = ["--native-kernels", native] if native else []
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data] + extra, stdin=subprocess.PIPE,
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
    ap.add_argument("--config", action="append", metavar="NAME=JSON",
                    help="replace the configurations, e.g. 'default={}' (repeatable)")
    ap.add_argument("--native-kernels", metavar="LIB", help="start the engine with --native-kernels LIB")
    ap.add_argument("--native-pairs", action="store_true",
                    help="run every vectorized configuration also with native: true (next to it)")
    ap.add_argument("--verify", action="store_true",
                    help="check that native and non-native results are identical (full rows)")
    args = ap.parse_args()
    configs = CONFIGS
    if args.config:
        configs = []
        for c in args.config:
            name, _, opts = c.partition("=")
            configs.append((name, json.loads(opts)))
    if args.native_pairs:
        paired = []
        for name, opts in configs:
            paired.append((name, opts))
            if opts.get("mode") != "row" and not opts.get("native"):
                paired.append((name + " +native", {**opts, "native": True}))
        configs = paired
    s = Session(args.engine, args.data, args.jvm, args.native_kernels)
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
    header = "| query | " + " | ".join(c[0] for c in configs) + " |"
    lines = [header, "|" + "---|" * (len(configs) + 1)]
    for qname, sql in queries:
        cells = []
        counts = set()
        for cname, opts in configs:
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
            cells.append(f"{statistics.median(times):.1f}")
        assert len(counts) == 1, (qname, counts)
        if args.verify:
            reference = {}
            for cname, opts in configs:
                key = json.dumps({k: v for k, v in opts.items() if k != "native"}, sort_keys=True)
                r = s.req({"op": "query", "sql": sql, "options": dict(opts)})
                assert r.get("ok"), (qname, cname, r)
                rows = r["rows"]
                if "ORDER BY" not in sql:
                    rows = sorted(rows, key=json.dumps)
                if key in reference:
                    exact = opts.get("threads", 1) == 1
                    assert same(reference[key], rows, not exact), f"{qname}: {cname} differs from its non-native run"
                else:
                    reference[key] = rows
        lines.append(f"| {qname} | " + " | ".join(cells) + " |")
        print(lines[-1], flush=True)
    print()
    print("\n".join(lines))


if __name__ == "__main__":
    main()
