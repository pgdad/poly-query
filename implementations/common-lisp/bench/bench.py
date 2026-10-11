#!/usr/bin/env python3
"""Benchmark and differential check for the PolyQuery Common Lisp engine.

Loads a generated dataset (datasets/generators/pqgen.py) into one engine
session and runs a fixed query set under several execution-option
configurations. For every query the results of all configurations are
compared (as multisets, FLOAT64 with the conformance tolerance) and the
median wall time of each configuration is reported.

Usage:
  bench.py --engine bin/polyquery --data /tmp/pqdata/1m [--repeat 3]
           [--configs row,vec1,vec4] [--queries q1,q2] [--json out.json]
           [--native native-kernels/build/x86_64/libpqkernels.so]

--native loads the native kernel library (`--native-kernels`), for the
configurations with `native: true` (vec1n, vec4n, vec8n).
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import subprocess
import sys
import time

TABLES = {
    "tx": "transactions", "cust": "customers", "sensors": "sensor_readings",
    "products": "products", "orders": "orders", "items": "order_items",
    "nh": "nulls_heavy", "sk": "sort_keys",
}

QUERIES = {
    "q1_filter_count": "SELECT COUNT(*) FROM tx WHERE amount > 1000 AND status = 'approved'",
    "q2_group_low": "SELECT category, COUNT(*) AS n, SUM(amount) AS s, AVG(fee) AS f, MIN(ts) AS t0, "
                    "MAX(ts) AS t1 FROM tx GROUP BY category",
    "q3_group_high": "SELECT customer_id, COUNT(*) AS n, SUM(amount) AS s FROM tx GROUP BY customer_id",
    "q4_join_agg": "SELECT c.segment, COUNT(*) AS n, SUM(t.amount) AS s FROM tx t "
                   "JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment",
    "q5_topn": "SELECT tx_id, amount FROM tx WHERE status = 'approved' ORDER BY amount DESC, tx_id LIMIT 10",
    "q6_float_agg": "SELECT sensor_id % 100 AS s, MIN(temperature) AS lo, MAX(temperature) AS hi, "
                    "AVG(humidity) AS h, SUM(pressure) AS p FROM sensors GROUP BY sensor_id % 100",
    "q7_join3": "SELECT p.category, COUNT(*) AS lines, SUM(i.quantity * i.unit_price) AS revenue "
                "FROM items i JOIN orders o ON o.order_id = i.order_id "
                "JOIN products p ON p.product_id = i.product_id "
                "WHERE o.status = 'delivered' GROUP BY p.category",
    "q8_count_distinct": "SELECT COUNT(DISTINCT customer_id) AS c, COUNT(DISTINCT merchant_id) AS m FROM tx",
    "q9_project": "SELECT tx_id, amount * 2 AS a2, fee + amount AS t FROM tx WHERE bucket < 50",
    "q10_nulls": "SELECT b60, COUNT(*) AS n, COUNT(n50) AS c50, SUM(n90) AS s90, AVG(f95) AS a95, "
                 "MAX(s70) AS m FROM nh GROUP BY b60",
    "q11_case_expr": "SELECT CASE WHEN amount > 500 THEN 'big' WHEN amount > 50 THEN 'mid' ELSE 'small' END AS k, "
                     "COUNT(*) AS n, SUM(CASE WHEN is_fraud THEN 1 ELSE 0 END) AS f FROM tx GROUP BY 1",
    "q12_sort": "SELECT id, dup_key, str_key FROM sk ORDER BY dup_key, str_key, id LIMIT 20 OFFSET 1000",
    "q13_left_join": "SELECT o.status, COUNT(i.order_id) AS lines FROM orders o "
                     "LEFT JOIN items i ON i.order_id = o.order_id AND i.quantity > 8 GROUP BY o.status",
    "q14_distinct": "SELECT DISTINCT currency, category, status FROM tx",
    "q15_comma_join": "SELECT COUNT(*) FROM orders o, cust c WHERE o.customer_id = c.customer_id "
                      "AND c.segment = 'enterprise'",
    # count: only the row count is returned (no result serialization)
    "q16_full_sort": "count:SELECT id, dup_key, float_key FROM sk ORDER BY dup_key, float_key DESC, id",
    "q17_scan_filter": "count:SELECT tx_id, amount, category FROM tx WHERE category LIKE '%e%' AND fee < 5",
}

CONFIGS = {
    "row": {"mode": "row", "threads": 1},
    "row_noopt": {"mode": "row", "threads": 1, "optimize": False},
    "vec1": {"mode": "vectorized", "threads": 1},
    "vec4": {"mode": "vectorized", "threads": 4},
    "vec8": {"mode": "vectorized", "threads": 8},
    "vec1n": {"mode": "vectorized", "threads": 1, "native": True},
    "vec4n": {"mode": "vectorized", "threads": 4, "native": True},
    "vec8n": {"mode": "vectorized", "threads": 8, "native": True},
    "vec4_merge": {"mode": "vectorized", "threads": 4, "join": "merge"},
    "vec1_merge": {"mode": "vectorized", "threads": 1, "join": "merge"},
    "vec1_noopt": {"mode": "vectorized", "threads": 1, "optimize": False},
    "row_merge": {"mode": "row", "threads": 1, "join": "merge"},
    "baseline": {},          # an engine without Phase 5 options (use --engine of that build)
}

FLOAT_REL_TOL = 1e-9


class Session:
    def __init__(self, engine: str, data_dir: str, extra_args=()):
        self.proc = subprocess.Popen([engine, "session", "--data-dir", data_dir, *extra_args],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def request(self, req: dict) -> dict:
        self.proc.stdin.write((json.dumps(req) + "\n").encode())
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait()


def norm_value(v):
    if isinstance(v, float):
        return ("f", v)
    return ("v", json.dumps(v))


def rows_equal(a: list, b: list) -> bool:
    if len(a) != len(b):
        return False
    key = lambda r: [json.dumps(x) if not isinstance(x, float) else "%.6e" % x for x in r]
    for ra, rb in zip(sorted(a, key=key), sorted(b, key=key)):
        for x, y in zip(ra, rb):
            if isinstance(x, float) or isinstance(y, float):
                if not (isinstance(x, (int, float)) and isinstance(y, (int, float))):
                    return False
                if abs(x - y) > FLOAT_REL_TOL * max(1.0, abs(x), abs(y)):
                    return False
            elif x != y:
                return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True, help="directory with the generated CSV files")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--configs", default="row,vec1,vec4")
    ap.add_argument("--queries", default=None)
    ap.add_argument("--json", default=None)
    ap.add_argument("--native", default=None, help="path of libpqkernels (for the native configs)")
    args = ap.parse_args()

    configs = args.configs.split(",")
    queries = args.queries.split(",") if args.queries else list(QUERIES)
    s = Session(args.engine, args.data,
                ["--native-kernels", args.native] if args.native else [])
    t0 = time.monotonic()
    for name, base in TABLES.items():
        schema = json.load(open(f"{args.data}/{base}.schema.json"))
        r = s.request({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        if not r.get("ok"):
            print("load failed", name, r, file=sys.stderr)
            return 1
    print(f"loaded {len(TABLES)} tables in {time.monotonic() - t0:.1f}s", flush=True)

    results = {}
    failures = 0
    print("%-20s" % "query" + "".join("%12s" % c for c in configs) + "   rows  same")
    for q in queries:
        sql = QUERIES[q]
        times = {}
        outputs = {}
        for c in configs:
            samples = []
            for _ in range(args.repeat):
                count_only = sql.startswith("count:")
                req = {"op": "query", "sql": sql[6:] if count_only else sql}
                options = dict(CONFIGS[c])
                if count_only:
                    options["result"] = "count"
                if options:
                    req["options"] = options
                t = time.monotonic()
                r = s.request(req)
                samples.append(time.monotonic() - t)
                if not r.get("ok"):
                    outputs[c] = ("error", r["error"]["code"])
                    break
                outputs[c] = ("ok", r["rows"] if "rows" in r else [[r["row_count"]]])
            times[c] = statistics.median(samples)
        ref = outputs[configs[0]]
        same = all(o[0] == ref[0] and (o[1] == ref[1] if o[0] == "error" else rows_equal(o[1], ref[1]))
                   for o in outputs.values())
        failures += not same
        nrows = len(ref[1]) if ref[0] == "ok" else ref[1]
        print("%-20s" % q + "".join("%11.3fs" % times[c] for c in configs) + "  %6s  %s" % (nrows, "yes" if same else "NO"),
              flush=True)
        results[q] = {"sql": sql, "seconds": times, "rows": nrows, "consistent": same}
    s.close()
    if args.json:
        json.dump({"configs": {c: CONFIGS[c] for c in configs}, "results": results}, open(args.json, "w"), indent=1)
    if failures:
        print(f"{failures} queries produced different results", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
