#!/usr/bin/env python3
"""PolyQuery Clojure engine — Phase 5 micro-benchmark.

Loads the generated datasets (datasets/generators/pqgen.py generate --scale 1m)
into one `bin/polyquery session` and runs a fixed set of queries under several
option combinations, printing median wall-clock times (client side, results
requested with result=count so serialization of large results is excluded).

usage: bench.py DATA_DIR [--runs N] [--only Q1,Q2] [--configs baseline,vec1,...]
       bench.py DATA_DIR --verify     # compare full results across configurations
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
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE.parent / "bin" / "polyquery"

TABLES = {
    "tx": "transactions",
    "cust": "customers",
    "orders": "orders",
    "items": "order_items",
    "products": "products",
    "sensor": "sensor_readings",
    "sk": "sort_keys",
}

QUERIES = {
    "Q1 filter+count": "SELECT COUNT(*) FROM tx WHERE amount > 500 AND status = 'approved'",
    "Q2 group by (low card.)": "SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(ts), MAX(ts) FROM tx GROUP BY category",
    "Q3 group by (100K groups)": "SELECT customer_id, SUM(amount), COUNT(*) FROM tx GROUP BY customer_id",
    "Q4 project+filter": "SELECT tx_id, amount * 2 + fee, bucket % 7 FROM tx WHERE bucket < 200 AND NOT is_fraud",
    "Q5 join+group": "SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment",
    "Q6 join 1M x 250K": "SELECT o.status, SUM(i.quantity), COUNT(*) FROM items i JOIN orders o ON o.order_id = i.order_id GROUP BY o.status",
    "Q7 top-N": "SELECT tx_id, amount FROM tx ORDER BY amount DESC, tx_id LIMIT 10",
    "Q8 full sort": "SELECT id, uniq_key FROM sk ORDER BY uniq_key",
    "Q9 sensor agg": "SELECT sensor_id, AVG(temperature), MAX(humidity), COUNT(*) FROM sensor WHERE status = 'ok' GROUP BY sensor_id",
    "Q10 3-way join (comma)": "SELECT COUNT(*), SUM(i.quantity) FROM items i, products p, orders o WHERE o.order_id = i.order_id AND p.product_id = i.product_id AND p.category = 'books'",
    "Q11 CASE/strings": "SELECT currency, SUM(CASE WHEN status = 'approved' THEN amount ELSE 0 END), COUNT(*) FROM tx WHERE category LIKE 'g%' OR category IN ('travel', 'utilities') GROUP BY currency",
}

CONFIGS = {
    "default": {},
    "baseline": {"mode": "row", "threads": 1, "optimize": False},
    "row": {"mode": "row", "threads": 1},
    "vec1": {"mode": "vectorized", "threads": 1},
    "vec8": {"mode": "vectorized", "threads": 8},
    "merge8": {"mode": "vectorized", "threads": 8, "join": "merge"},
}


class Session:
    def __init__(self, data_dir: str, java_opts: str, launcher: str):
        env = dict(os.environ, POLYQUERY_JAVA_OPTS=java_opts)
        self.proc = subprocess.Popen([launcher, "session", "--data-dir", data_dir],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.n = 0

    def request(self, req: dict) -> dict:
        self.n += 1
        req = dict(req, id=self.n)
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("engine exited")
        return json.loads(line)

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait(timeout=30)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--only")
    ap.add_argument("--configs", default="baseline,row,vec1,vec8")
    ap.add_argument("--java-opts", default="-Xmx24g")
    ap.add_argument("--engine", default=str(LAUNCHER), help="launcher to benchmark (default: this engine)")
    ap.add_argument("--verify", action="store_true", help="compare result digests instead of timing")
    args = ap.parse_args()

    s = Session(args.data_dir, args.java_opts, args.engine)
    for t, f in TABLES.items():
        schema = json.loads((Path(args.data_dir) / f"{f}.schema.json").read_text())
        t0 = time.monotonic()
        r = s.request({"op": "load", "table": t, "path": f"{f}.csv", "format": "csv", "schema": schema})
        if not r.get("ok"):
            print(f"load {t} failed: {r}", file=sys.stderr)
            return 1
        print(f"loaded {t}: {r['row_count']} rows in {time.monotonic() - t0:.1f}s", file=sys.stderr)

    configs = args.configs.split(",")
    only = set(args.only.split(",")) if args.only else None
    if args.verify:
        bad = 0
        for name, sql in QUERIES.items():
            if only and name.split()[0] not in only:
                continue
            digests = {}
            for c in CONFIGS:
                r = s.request({"op": "query", "sql": sql, "options": CONFIGS[c]})
                if not r.get("ok"):
                    digests[c] = "error " + r["error"]["code"]
                    continue
                norm = lambda v: f"{v:.6g}" if isinstance(v, float) else json.dumps(v)
                rows = sorted("|".join(norm(v) for v in row) for row in r["rows"])
                if "ORDER BY" in sql:
                    rows = ["|".join(norm(v) for v in row) for row in r["rows"]]
                digests[c] = hashlib.sha256("\n".join(rows).encode()).hexdigest()[:12] + f" ({len(rows)} rows)"
            ok = len({d for c, d in digests.items() if not (c == "baseline" and d.startswith("error"))}) == 1
            bad += not ok
            print(("ok   " if ok else "DIFF ") + name + "  " + json.dumps(digests), flush=True)
        s.close()
        return 1 if bad else 0
    print("| query | " + " | ".join(configs) + " |")
    print("|---|" + "---:|" * len(configs))
    for name, sql in QUERIES.items():
        if only and name.split()[0] not in only:
            continue
        cells = []
        counts = set()
        for c in configs:
            opts = dict(CONFIGS[c], result="count")
            times = []
            for i in range(args.warmup + args.runs):
                t0 = time.monotonic()
                r = s.request({"op": "query", "sql": sql, "options": opts})
                dt = time.monotonic() - t0
                if not r.get("ok"):
                    print(f"{name} [{c}] failed: {r}", file=sys.stderr)
                    break
                counts.add(r["row_count"])
                if i >= args.warmup:
                    times.append(dt)
            cells.append(f"{statistics.median(times) * 1000:.0f} ms" if times else "error")
        flag = "" if len(counts) <= 1 else " (ROW COUNTS DIFFER)"
        print(f"| {name}{flag} | " + " | ".join(cells) + " |", flush=True)
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
