#!/usr/bin/env python3
"""Randomized differential test of the PolyQuery Go engine's execution options.

Generates random queries over the conformance fixtures and checks that every
execution option combination returns the same result as the row-at-a-time
baseline (or fails with the same error code).

Usage:
  python3 implementations/go/scripts/difftest.py [--seed N] [--queries N] [--morsel-rows N] [-v]

Errors may legitimately depend on evaluation order (e.g. a filter that is
pushed below a join is evaluated for more rows), so error codes are compared
only between configurations sharing the join algorithm and the optimize flag;
successful results are compared across all configurations.
"""
import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "bin" / "polyquery"
FIXTURES = HERE.parents[2] / "tests" / "conformance" / "fixtures"

TABLES = {
    "tx": ("gen/transactions.csv", "gen/transactions.schema.json"),
    "c": ("gen/customers.csv", "gen/customers.schema.json"),
    "o": ("gen/orders.csv", "gen/orders.schema.json"),
    "i": ("gen/order_items.csv", "gen/order_items.schema.json"),
    "p": ("gen/products.csv", "gen/products.schema.json"),
    "nh": ("gen/nulls_heavy.csv", "gen/nulls_heavy.schema.json"),
}

JOINS = [  # (left, right, left key, right key)
    ("tx", "c", "customer_id", "customer_id"),
    ("o", "c", "customer_id", "customer_id"),
    ("i", "o", "order_id", "order_id"),
    ("i", "p", "product_id", "product_id"),
    ("nh", "tx", "n50", "merchant_id"),
    ("nh", "c", "n90", "birth_year"),
]

BASE = {"mode": "row", "threads": 1}
VARIANTS = [
    {"mode": "vectorized", "threads": 1},
    {"mode": "vectorized", "threads": 4},
    {"mode": "row", "threads": 3},
    {"mode": "auto"},
]
JOIN_OPT = [("hash", True), ("merge", True), ("nested_loop", True), ("hash", False), ("merge", False)]


def kind(t):
    t = t.upper()
    if t.startswith("DECIMAL"):
        return "DEC"
    return {"INT64": "INT", "FLOAT64": "FLOAT", "STRING": "STR", "BOOLEAN": "BOOL",
            "DATE": "DATE", "TIMESTAMP": "TS"}[t]


class Gen:
    def __init__(self, rnd, schemas):
        self.r = rnd
        self.schemas = schemas  # table -> [(col, kind)]

    def cols(self, aliases, k):
        out = []
        for a, t in aliases:
            out += [f"{a}.{c}" for c, ck in self.schemas[t] if ck == k]
        return out

    def lit(self, k):
        r = self.r
        if k == "INT":
            return str(r.choice([0, 1, 2, 3, 5, 7, 10, 100, 1000, -1, -3, 2024, 4611686018427387904 // 2 ** r.randint(0, 40)]))
        if k == "DEC":
            return r.choice(["1.50", "0.25", "100.00", "-2.5", "12345.678", "0.01"])
        if k == "FLOAT":
            return r.choice(["1.5e0", "0.25e0", "-3.75e0", "1e3", "CAST(2 AS FLOAT64)"])
        if k == "STR":
            return r.choice(["'a'", "'consumer'", "'approved'", "'paid'", "'x%'", "''", "'germany'", "'india'"])
        if k == "BOOL":
            return r.choice(["TRUE", "FALSE"])
        if k == "DATE":
            return r.choice(["DATE '2023-06-01'", "DATE '2024-01-15'", "DATE '2022-12-31'"])
        if k == "TS":
            return r.choice(["TIMESTAMP '2023-06-01 12:00:00'", "TIMESTAMP '2024-01-01 00:00:00'"])
        return "NULL"

    def expr(self, aliases, k, depth=0):
        r = self.r
        cols = self.cols(aliases, k)
        if depth >= 3 or r.random() < 0.3:
            if cols and r.random() < 0.8:
                return r.choice(cols)
            if r.random() < 0.05:
                return "NULL"
            return self.lit(k)
        d = depth + 1
        e = lambda kk: self.expr(aliases, kk, d)  # noqa: E731
        if k == "INT":
            return r.choice([
                lambda: f"({e('INT')} {r.choice(['+', '-', '*', '/', '%'])} {e('INT')})",
                lambda: f"ABS({e('INT')})",
                lambda: f"LENGTH({e('STR')})",
                lambda: f"YEAR({e(r.choice(['DATE', 'TS']))})",
                lambda: f"CASE WHEN {e('BOOL')} THEN {e('INT')} ELSE {e('INT')} END",
                lambda: f"COALESCE({e('INT')}, {e('INT')})",
                lambda: f"CAST({e('DEC')} AS INT64)",
                lambda: f"NULLIF({e('INT')}, {e('INT')})",
                lambda: f"MOD({e('INT')}, {e('INT')})",
                lambda: f"(-{e('INT')})",
            ])()
        if k == "DEC":
            return r.choice([
                lambda: f"({e('DEC')} {r.choice(['+', '-'])} {e(r.choice(['DEC', 'INT']))})",
                lambda: f"({e('DEC')} * {r.choice(['2', '3', 'CAST(1.5 AS DECIMAL(4,1))'])})",
                lambda: f"CAST({e('INT')} AS DECIMAL(12,2))",
                lambda: f"ROUND({e('DEC')}, 1)",
                lambda: f"ABS({e('DEC')})",
            ])()
        if k == "FLOAT":
            return r.choice([
                lambda: f"({e('FLOAT')} {r.choice(['+', '-', '*', '/'])} {e(r.choice(['FLOAT', 'INT', 'DEC']))})",
                lambda: f"CAST({e('DEC')} AS FLOAT64)",
                lambda: f"SQRT(ABS({e('FLOAT')}))",
                lambda: f"({e('DEC')} / {e('INT')})",
            ])()
        if k == "STR":
            return r.choice([
                lambda: f"UPPER({e('STR')})",
                lambda: f"LOWER({e('STR')})",
                lambda: f"SUBSTR({e('STR')}, {r.randint(0, 3)}, {r.randint(0, 4)})",
                lambda: f"({e('STR')} || {e('STR')})",
                lambda: f"CONCAT({e('STR')}, {e('INT')})",
                lambda: f"TRIM({e('STR')})",
                lambda: f"CASE WHEN {e('BOOL')} THEN {e('STR')} END",
                lambda: f"CAST({e('INT')} AS STRING)",
                lambda: f"REPLACE({e('STR')}, 'a', 'b')",
            ])()
        if k == "BOOL":
            cmp = r.choice(["=", "<>", "<", "<=", ">", ">="])
            return r.choice([
                lambda: f"({e('INT')} {cmp} {e(r.choice(['INT', 'DEC', 'FLOAT']))})",
                lambda: f"({e('DEC')} {cmp} {e(r.choice(['DEC', 'INT']))})",
                lambda: f"({e('STR')} {cmp} {e('STR')})",
                lambda: f"({e('DATE')} {cmp} {e(r.choice(['DATE', 'TS']))})",
                lambda: f"({e('FLOAT')} {cmp} {e('FLOAT')})",
                lambda: f"({e('BOOL')} {r.choice(['AND', 'OR'])} {e('BOOL')})",
                lambda: f"(NOT {e('BOOL')})",
                lambda: f"({e(r.choice(['INT', 'STR', 'DEC', 'FLOAT']))} IS {r.choice(['', 'NOT '])}NULL)",
                lambda: f"({e('INT')} BETWEEN {e('INT')} AND {e('INT')})",
                lambda: f"({e('STR')} {r.choice(['', 'NOT '])}IN ('consumer', 'paid', 'india', 'approved', NULL))",
                lambda: f"({e('INT')} IN (1, 2, 3, 5, 8, 13, 21, 34, 55))",
                lambda: f"({e('STR')} LIKE '{r.choice(['%a%', 'c%', '_n%', '%'])}')",
            ])()
        if k == "DATE":
            return r.choice(cols or [self.lit("DATE")])
        if k == "TS":
            return r.choice([lambda: f"DATE_TRUNC('month', {e(r.choice(['TS', 'DATE']))})"] +
                            [lambda: c for c in cols])()
        return self.lit(k)

    def anyexpr(self, aliases):
        k = self.r.choice(["INT", "INT", "DEC", "FLOAT", "STR", "STR", "BOOL", "DATE", "TS"])
        return self.expr(aliases, k), k

    def agg(self, aliases):
        r = self.r
        f = r.choice(["COUNT(*)", "COUNT", "SUM", "AVG", "MIN", "MAX", "COUNT_DISTINCT", "SUM_DISTINCT"])
        if f == "COUNT(*)":
            return "COUNT(*)"
        if f in ("SUM", "AVG", "SUM_DISTINCT"):
            x = self.expr(aliases, r.choice(["INT", "DEC", "FLOAT"]), 1)
            if f == "SUM_DISTINCT":
                return f"SUM(DISTINCT {x})"
            return f"{f}({x})"
        x, _ = self.anyexpr(aliases)
        if f == "COUNT_DISTINCT":
            return f"COUNT(DISTINCT {x})"
        if f == "COUNT":
            return f"COUNT({x})"
        return f"{f}({x})"

    def source(self):
        r = self.r
        if r.random() < 0.45:
            t = r.choice(list(TABLES))
            return f"{t} t0", [("t0", t)]
        if r.random() < 0.25:
            # three-way inner joins in varying FROM orders (join reordering)
            src, aliases = r.choice([
                ("i a JOIN o b ON a.order_id = b.order_id JOIN c d ON b.customer_id = d.customer_id",
                 [("a", "i"), ("b", "o"), ("d", "c")]),
                ("c d JOIN o b ON b.customer_id = d.customer_id JOIN i a ON a.order_id = b.order_id",
                 [("a", "i"), ("b", "o"), ("d", "c")]),
                ("p d JOIN i a ON a.product_id = d.product_id JOIN o b ON b.order_id = a.order_id",
                 [("a", "i"), ("b", "o"), ("d", "p")]),
                ("c d JOIN tx a ON a.customer_id = d.customer_id AND a.tx_id < 300 JOIN o b ON b.customer_id = d.customer_id",
                 [("a", "tx"), ("b", "o"), ("d", "c")]),
            ])
            return src, aliases
        lt, rt, lk, rk = r.choice(JOINS)
        jt = r.choice(["JOIN", "JOIN", "LEFT JOIN"])
        aliases = [("a", lt), ("b", rt)]
        on = f"a.{lk} = b.{rk}"
        if r.random() < 0.3:
            on += f" AND {self.expr(aliases, 'BOOL', 2)}"
        if r.random() < 0.1:
            on = self.expr(aliases, "BOOL", 1)  # non-equi
        return f"{lt} a {jt} {rt} b ON {on}", aliases

    def query(self):
        r = self.r
        src, aliases = self.source()
        where = ""
        if r.random() < 0.7:
            where = f" {'AND' if ' WHERE ' in src else 'WHERE'} {self.expr(aliases, 'BOOL')}"
        shape = r.random()
        if shape < 0.4:
            items = [self.anyexpr(aliases)[0] for _ in range(r.randint(1, 4))]
            sel = ", ".join(f"{x} AS c{i}" for i, x in enumerate(items))
            distinct = "DISTINCT " if r.random() < 0.2 else ""
            q = f"SELECT {distinct}{sel} FROM {src}{where}"
            if r.random() < 0.4:
                order = ", ".join(f"c{i}" for i in range(len(items)))
                q += f" ORDER BY {order} LIMIT {r.randint(0, 30)}"
            return q
        if shape < 0.85:
            keys = [self.anyexpr(aliases)[0] for _ in range(r.randint(0, 2))]
            aggs = [self.agg(aliases) for _ in range(r.randint(1, 4))]
            items = [f"{k} AS k{i}" for i, k in enumerate(keys)] + [f"{a} AS a{i}" for i, a in enumerate(aggs)]
            q = f"SELECT {', '.join(items)} FROM {src}{where}"
            if keys:
                q += " GROUP BY " + ", ".join(keys)
                if r.random() < 0.3:
                    q += f" HAVING COUNT(*) > {r.randint(0, 3)}"
            return q
        # subqueries
        t = r.choice(list(TABLES))
        inner = r.choice([
            "SELECT customer_id FROM c WHERE segment = 'consumer'",
            "SELECT order_id FROM o WHERE status = 'paid'",
            "SELECT n50 FROM nh",
        ])
        outer_col = {"tx": "customer_id", "c": "customer_id", "o": "order_id", "i": "order_id",
                     "p": "product_id", "nh": "n90"}[t]
        return (f"SELECT COUNT(*), MIN({outer_col}) FROM {t} WHERE {outer_col} "
                f"{r.choice(['IN', 'NOT IN'])} ({inner})")


class Session:
    def __init__(self, morsel):
        env = dict(os.environ, POLYQUERY_MORSEL_ROWS=str(morsel), GOTRACEBACK="all")
        self.dir = tempfile.mkdtemp(prefix="pq-difftest-")
        os.symlink(FIXTURES, os.path.join(self.dir, "fixtures"))
        self.p = subprocess.Popen([str(ENGINE), "session", "--data-dir", self.dir],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(os.path.join(self.dir, "stderr"), "w"),
                                  text=True, env=env)

    def req(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("engine died")
        return json.loads(line)


def norm(v):
    if isinstance(v, float):
        return float(f"{v:.9g}")
    return v


def canon(resp):
    if not resp.get("ok"):
        return ("error", resp["error"]["code"])
    rows = sorted((json.dumps([norm(x) for x in row]) for row in resp["rows"]))
    return ("ok", json.dumps(resp["columns"]), rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--queries", type=int, default=300)
    ap.add_argument("--morsel-rows", type=int, default=37)
    ap.add_argument("-v", action="store_true")
    args = ap.parse_args()
    s = Session(args.morsel_rows)
    schemas = {}
    for t, (csv, sch) in TABLES.items():
        schema = json.loads((FIXTURES / sch).read_text())
        schemas[t] = [(c["name"], kind(c["type"])) for c in schema]
        r = s.req({"op": "load", "table": t, "path": f"fixtures/{csv}", "format": "csv", "schema": schema})
        assert r.get("ok"), r
    # Layout variants: small row groups through PQCF, row layout, forced dictionaries.
    rnd = random.Random(args.seed)
    for t in TABLES:
        choice = rnd.choice(["pqcf", "row", "dict", "plain"])
        if choice == "pqcf":
            r = s.req({"op": "save", "table": t, "path": f"{t}.pqcf",
                       "options": {"row_group_size": rnd.choice([50, 128, 333])}})
            if r.get("ok"):
                s.req({"op": "open", "table": t, "path": f"{t}.pqcf",
                       "replace": True, "options": {"mmap": rnd.random() < 0.5}})
        elif choice in ("row", "dict"):
            csv, sch = TABLES[t]
            opts = {"layout": "row"} if choice == "row" else {"dictionary": True}
            s.req({"op": "load", "table": t, "path": f"fixtures/{csv}", "format": "csv",
                   "schema": json.loads((FIXTURES / sch).read_text()), "replace": True, "options": opts})
        print(f"# {t}: {choice}", file=sys.stderr)
    g = Gen(rnd, schemas)
    failures = 0
    errors = 0
    for n in range(args.queries):
        q = g.query()
        if args.v:
            print(f"{n}: {q}", flush=True)
        results = {}
        for join, opt in JOIN_OPT:
            base = s.req({"op": "query", "sql": q, "options": {**BASE, "join": join, "optimize": opt}})
            cb = canon(base)
            results[(join, opt)] = cb
            if cb[0] == "error":
                errors += 1
            for v in VARIANTS:
                opts = {**v, "join": join, "optimize": opt}
                cv = canon(s.req({"op": "query", "sql": q, "options": opts}))
                if cv != cb:
                    failures += 1
                    print(f"MISMATCH [{json.dumps(opts)}] {q}\n  base: {str(cb)[:400]}\n  got:  {str(cv)[:400]}")
        oks = {k: v for k, v in results.items() if v[0] == "ok"}
        if len(set(map(str, oks.values()))) > 1:
            failures += 1
            print(f"MISMATCH across join/optimize: {q}")
            for k, v in oks.items():
                print(f"  {k}: {str(v)[:300]}")
    s.p.stdin.close()
    s.p.wait()
    shutil.rmtree(s.dir, ignore_errors=True)
    print(f"{args.queries} queries, {failures} mismatches, {errors} baseline errors")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
