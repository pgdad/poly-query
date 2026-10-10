"""Micro-benchmark driver: loads generated datasets (datasets/generators/pqgen.py)
into one engine session and times a fixed set of queries under several
option sets.

    python3 tools/bench.py --data /tmp/pqdata/1m [--repeat 3] [--only Q2,Q4]
        [--variant row] [--variant '{"mode":"vectorized","threads":4}']

Each query is run ``--repeat`` times per variant (``result: count``, so
serialization does not dominate); the median wall time is reported in ms.
"""

from __future__ import annotations

import argparse
import json
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
    "sk": "sort_keys",
}

QUERIES = {
    "Q1": "SELECT COUNT(*) FROM tx WHERE amount > 1000 AND status = 'approved'",
    "Q2": "SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(ts), MAX(ts) FROM tx GROUP BY category",
    "Q3": "SELECT customer_id, SUM(amount) AS s FROM tx GROUP BY customer_id",
    "Q4": "SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c "
    "ON c.customer_id = t.customer_id GROUP BY c.segment",
    "Q5": "SELECT tx_id, amount FROM tx WHERE status = 'approved' ORDER BY amount DESC, tx_id LIMIT 10",
    "Q6": "SELECT p.category, SUM(i.quantity * i.unit_price) FROM items i "
    "JOIN orders o ON o.order_id = i.order_id JOIN products p ON p.product_id = i.product_id "
    "WHERE o.status = 'delivered' GROUP BY p.category",
    "Q7": "SELECT SUM(amount * 2 + fee), COUNT(*) FROM tx WHERE bucket < 500",
    "Q8": "SELECT id, float_key FROM sk ORDER BY float_key, id",
    "Q9": "SELECT tx_id, amount, fee FROM tx WHERE amount > 10",
    "Q10": "SELECT tx_id, amount FROM tx WHERE status = 'approved' AND amount > 5000",
}

PRESETS = {
    "row": {"mode": "row"},
    "vectorized": {"mode": "vectorized"},
    "auto": {},
    "vec4": {"mode": "vectorized", "threads": 4},
    "row4": {"mode": "row", "threads": 4},
    "noopt": {"optimize": False},
}


class Session:
    def __init__(self, data_dir: str):
        self.proc = subprocess.Popen(
            [str(LAUNCHER), "session", "--data-dir", data_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        self.next_id = 0

    def request(self, req: dict) -> dict:
        self.next_id += 1
        req = {**req, "id": self.next_id}
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        resp = json.loads(self.proc.stdout.readline())
        if not resp.get("ok"):
            raise RuntimeError(f"{req}: {resp.get('error')}")
        return resp

    def close(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.close()
        self.proc.wait()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--only")
    ap.add_argument("--variant", action="append")
    ap.add_argument("--tables", help="comma-separated subset of tables to load")
    args = ap.parse_args()

    data = Path(args.data)
    session = Session(str(data))
    wanted = set(args.tables.split(",")) if args.tables else set(TABLES)
    for name, base in TABLES.items():
        if name not in wanted:
            continue
        schema = json.loads((data / f"{base}.schema.json").read_text())
        t0 = time.monotonic()
        session.request({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        print(f"load {name}: {time.monotonic() - t0:.1f}s", file=sys.stderr)

    variants = args.variant or ["row", "vectorized", "vec4"]
    queries = {k: v for k, v in QUERIES.items() if not args.only or k in args.only.split(",")}
    print("query | " + " | ".join(variants))
    for qname, sql in queries.items():
        cells = []
        for variant in variants:
            options = PRESETS[variant] if variant in PRESETS else json.loads(variant)
            times = []
            for _ in range(args.repeat):
                t0 = time.monotonic()
                session.request({"op": "query", "sql": sql, "options": {**options, "result": "count"}})
                times.append((time.monotonic() - t0) * 1000)
            cells.append(f"{statistics.median(times):.0f}")
        print(f"{qname} | " + " | ".join(cells), flush=True)
    session.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
