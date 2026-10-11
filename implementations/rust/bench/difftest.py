#!/usr/bin/env python3
"""Differential tester: random SQL, every execution option vs the row baseline.

Generates random (typed) queries over the conformance fixture datasets and
runs each one under the row-at-a-time baseline and under every combination
of mode x join x threads x optimize, in one engine process with default
morsels and one with tiny morsels (POLYQUERY_MORSEL_ROWS) so that the
parallel operators are exercised on small tables. Results (or error codes)
must agree; rows are compared as multisets with a float tolerance.

Usage: difftest.py --engine bin/polyquery [--queries 500] [--seed 1] [-v]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parents[2] / "tests" / "conformance" / "fixtures"

TABLES = {
    "tx": "transactions",
    "cust": "customers",
    "orders": "orders",
    "items": "order_items",
    "products": "products",
    "sensor": "sensor_readings",
    "nulls": "nulls_heavy",
    "sortk": "sort_keys",
}
# Copies with other physical representations.
COPIES = {"tx_pq": ("tx", "pqcf"), "tx_row": ("tx", "row"), "items_pq": ("items", "pqcf")}

JOINS = [
    ("tx", "customer_id", "cust", "customer_id"),
    ("orders", "customer_id", "cust", "customer_id"),
    ("items", "order_id", "orders", "order_id"),
    ("items", "product_id", "products", "product_id"),
    ("tx_pq", "customer_id", "cust", "customer_id"),
    ("tx_row", "customer_id", "cust", "customer_id"),
    ("items_pq", "order_id", "orders", "order_id"),
    ("tx", "bucket", "sortk", "dup_key"),
]

VARIANTS = [
    {"mode": "row", "join": "nested_loop", "threads": 1, "optimize": False},
    {"mode": "row", "join": "merge", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "hash", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "merge", "threads": 1, "optimize": False},
    {"mode": "vectorized", "join": "nested_loop", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "hash", "threads": 3, "optimize": False},
    {},
]
BASELINE = {"mode": "row", "join": "hash", "threads": 1, "optimize": True}


class Engine:
    def __init__(self, launcher: str, data: str, env: dict):
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
        self.n = 0

    def call(self, req: dict) -> dict:
        self.n += 1
        req["id"] = self.n
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("engine died")
        return json.loads(line)

    def close(self):
        self.p.stdin.close()
        self.p.wait()


# ------------------------------------------------------------ query generator

class Gen:
    def __init__(self, rng: random.Random, schemas: dict):
        self.r = rng
        self.schemas = schemas  # table -> [(col, type)]

    def cols(self, scope, kind):
        out = []
        for alias, table in scope:
            for c, t in self.schemas[table]:
                if kind is None or kind_of(t) == kind:
                    out.append((f"{alias}.{c}", t))
        return out

    def lit(self, kind):
        r = self.r
        if kind == "int":
            return str(r.choice([0, 1, 2, 3, 5, 7, 10, 100, 1000, -1, -3]))
        if kind == "dec":
            return r.choice(["1.5", "0.25", "100.00", "-2.5", "3.125"])
        if kind == "float":
            return r.choice(["1.5e0", "0.5e0", "2.0e0", "-1.25e0"])
        if kind == "str":
            return r.choice(["'a'", "'approved'", "'declined'", "'consumer'", "'x%'", "''", "'EUR'", "'ok'"])
        if kind == "bool":
            return r.choice(["TRUE", "FALSE"])
        if kind == "date":
            return r.choice(["DATE '2023-06-01'", "DATE '2024-01-01'", "DATE '2020-02-29'"])
        if kind == "ts":
            return r.choice(["TIMESTAMP '2023-06-01 12:00:00'", "TIMESTAMP '2024-01-01 00:00:00'"])
        return "NULL"

    def expr(self, scope, kind, depth=0):
        r = self.r
        cols = self.cols(scope, kind)
        if depth > 2 or r.random() < 0.35:
            if cols and r.random() < 0.8:
                return r.choice(cols)[0]
            if r.random() < 0.05:
                return "NULL"
            return self.lit(kind)
        d = depth + 1
        if kind == "int":
            c = r.randrange(9)
            if c == 0:
                return f"({self.expr(scope, 'int', d)} {r.choice(['+', '-', '*'])} {self.expr(scope, 'int', d)})"
            if c == 1:
                return f"({self.expr(scope, 'int', d)} {r.choice(['/', '%'])} {r.choice(['2', '3', '7', '10'])})"
            if c == 2:
                return f"ABS({self.expr(scope, 'int', d)})"
            if c == 3:
                return f"LENGTH({self.expr(scope, 'str', d)})"
            if c == 4:
                return f"{r.choice(['YEAR', 'MONTH', 'DAY'])}({self.expr(scope, r.choice(['date', 'ts']), d)})"
            if c == 5:
                return f"CASE WHEN {self.pred(scope, d)} THEN {self.expr(scope, 'int', d)} ELSE {self.expr(scope, 'int', d)} END"
            if c == 6:
                return f"COALESCE({self.expr(scope, 'int', d)}, {self.lit('int')})"
            if c == 7:
                return f"CAST({self.expr(scope, r.choice(['dec', 'float']), d)} AS INT64)"
            return f"(-{self.expr(scope, 'int', d)})"
        if kind == "dec":
            c = r.randrange(6)
            if c == 0:
                return f"({self.expr(scope, 'dec', d)} {r.choice(['+', '-'])} {self.expr(scope, r.choice(['dec', 'int']), d)})"
            if c == 1:
                return f"({self.expr(scope, 'dec', d)} * {self.lit(r.choice(['int', 'dec']))})"
            if c == 2:
                return f"ROUND({self.expr(scope, 'dec', d)}, {r.choice([0, 1, 2])})"
            if c == 3:
                return f"ABS({self.expr(scope, 'dec', d)})"
            if c == 4:
                return f"CASE WHEN {self.pred(scope, d)} THEN {self.expr(scope, 'dec', d)} END"
            return f"CAST({self.expr(scope, 'int', d)} AS DECIMAL(12,2))"
        if kind == "float":
            c = r.randrange(5)
            if c == 0:
                return f"({self.expr(scope, 'float', d)} {r.choice(['+', '-', '*'])} {self.expr(scope, r.choice(['float', 'int', 'dec']), d)})"
            if c == 1:
                return f"SQRT(ABS({self.expr(scope, 'float', d)}))"
            if c == 2:
                return f"CAST({self.expr(scope, r.choice(['int', 'dec']), d)} AS DOUBLE)"
            if c == 3:
                return f"({self.expr(scope, 'float', d)} / {r.choice(['2.0e0', '4', '0.5'])})"
            return f"ROUND({self.expr(scope, 'float', d)}, 2)"
        if kind == "str":
            c = r.randrange(7)
            if c == 0:
                return f"UPPER({self.expr(scope, 'str', d)})"
            if c == 1:
                return f"SUBSTR({self.expr(scope, 'str', d)}, {r.choice([1, 2, 3])}, {r.choice([1, 2, 5])})"
            if c == 2:
                return f"({self.expr(scope, 'str', d)} || {self.expr(scope, 'str', d)})"
            if c == 3:
                return f"COALESCE({self.expr(scope, 'str', d)}, 'none')"
            if c == 4:
                return f"CAST({self.expr(scope, r.choice(['int', 'date']), d)} AS STRING)"
            if c == 5:
                return f"CASE {self.expr(scope, 'int', d)} WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE {self.expr(scope, 'str', d)} END"
            return f"TRIM({self.expr(scope, 'str', d)})"
        if kind == "bool":
            return self.pred(scope, d)
        if kind == "date":
            return f"CAST({self.expr(scope, 'ts', d)} AS DATE)" if self.cols(scope, "ts") else self.lit("date")
        if kind == "ts":
            if r.random() < 0.5:
                return f"DATE_TRUNC('{r.choice(['day', 'month', 'hour'])}', {self.expr(scope, 'ts', d)})"
            return self.lit("ts")
        return "NULL"

    def pred(self, scope, depth=0):
        r = self.r
        d = depth + 1
        c = r.randrange(10) if depth < 3 else r.randrange(3, 10)
        if c == 0:
            return f"({self.pred(scope, d)} AND {self.pred(scope, d)})"
        if c == 1:
            return f"({self.pred(scope, d)} OR {self.pred(scope, d)})"
        if c == 2:
            return f"(NOT {self.pred(scope, d)})"
        kinds = [k for k in ["int", "dec", "float", "str", "date", "ts", "bool"] if self.cols(scope, k)] or ["int"]
        k = r.choice(kinds)
        if c == 3:
            return f"{self.expr(scope, k, d)} IS {r.choice(['', 'NOT '])}NULL"
        if c == 4 and k in ("int", "dec", "float", "date", "ts"):
            lo, hi = self.lit(k), self.lit(k)
            return f"{self.expr(scope, k, d)} {r.choice(['', 'NOT '])}BETWEEN {lo} AND {hi}"
        if c == 5 and k in ("int", "str"):
            items = ", ".join(self.lit(k) for _ in range(r.randrange(1, 4)))
            if r.random() < 0.15:
                items += ", NULL"
            return f"{self.expr(scope, k, d)} {r.choice(['', 'NOT '])}IN ({items})"
        if c == 6 and k == "str":
            return f"{self.expr(scope, 'str', d)} {r.choice(['', 'NOT '])}LIKE {r.choice(['%a%', 'c%', '%d', '_o%', '%'])!r}".replace('"', "'")
        if k == "bool":
            return self.expr(scope, "bool", 3) if self.cols(scope, "bool") else "TRUE"
        op = r.choice(["=", "<>", "<", "<=", ">", ">="])
        other = k
        if k in ("int", "dec", "float") and r.random() < 0.3:
            other = r.choice(["int", "dec", "float"])
        if k in ("date", "ts") and r.random() < 0.3:
            other = r.choice(["date", "ts"])
        return f"{self.expr(scope, k, d)} {op} {self.expr(scope, other, d)}"

    def agg(self, scope):
        r = self.r
        k = r.choice(["int", "dec", "float", "str", "date", "ts"])
        e = self.expr(scope, k, 2)
        f = r.choice(["COUNT", "SUM", "AVG", "MIN", "MAX", "COUNT(*)", "COUNTD"])
        if f == "COUNT(*)":
            return "COUNT(*)"
        if f == "COUNTD":
            return f"COUNT(DISTINCT {e})"
        if f in ("SUM", "AVG") and k not in ("int", "dec", "float"):
            f = "COUNT"
        if f == "SUM" and r.random() < 0.2:
            return f"SUM(DISTINCT {e})"
        return f"{f}({e})"

    def from_clause(self):
        r = self.r
        c = r.random()
        if c < 0.45:
            t = r.choice(list(self.schemas))
            return f"{t} a", [("a", t)]
        if c < 0.85:
            lt, lk, rt, rk = r.choice(JOINS)
            if r.random() < 0.5:
                lt, lk, rt, rk = rt, rk, lt, lk
            jt = r.choice(["JOIN", "JOIN", "LEFT JOIN", "INNER JOIN"])
            scope = [("a", lt), ("b", rt)]
            on = f"a.{lk} = b.{rk}"
            if r.random() < 0.3:
                on += f" AND {self.pred(scope, 2)}"
            if r.random() < 0.05:
                on = self.pred(scope, 1)
            return f"{lt} a {jt} {rt} b ON {on}", scope
        # three-way chain
        chains = [
            ("items", "orders", "cust", "a.order_id = b.order_id", "b.customer_id = c.customer_id"),
            ("items", "orders", "products", "a.order_id = b.order_id", "a.product_id = c.product_id"),
            ("tx", "cust", "orders", "a.customer_id = b.customer_id", "c.customer_id = b.customer_id"),
        ]
        t1, t2, t3, on1, on2 = r.choice(chains)
        j2 = r.choice(["JOIN", "JOIN", "LEFT JOIN"])
        return (f"{t1} a JOIN {t2} b ON {on1} {j2} {t3} c ON {on2}",
                [("a", t1), ("b", t2), ("c", t3)])

    def query(self):
        r = self.r
        frm, scope = self.from_clause()
        where = f" WHERE {self.pred(scope)}" if r.random() < 0.7 else ""
        shape = r.random()
        if shape < 0.4:
            n = r.randrange(1, 4)
            items = [self.expr(scope, r.choice(["int", "dec", "float", "str", "date", "ts", "bool"])) for _ in range(n)]
            distinct = "DISTINCT " if r.random() < 0.15 else ""
            sql = f"SELECT {distinct}{', '.join(items)} FROM {frm}{where}"
            ordered = False
            if r.random() < 0.4:
                keys = ", ".join(f"{i + 1} {r.choice(['ASC', 'DESC'])}" for i in range(n))
                sql += f" ORDER BY {keys}"
                ordered = True
                if r.random() < 0.6:
                    sql += f" LIMIT {r.choice([1, 3, 10, 50])}"
                    ordered = "limit"
            return sql, ordered
        if shape < 0.85:
            nk = r.randrange(0, 3)
            keys = [self.expr(scope, r.choice(["int", "str", "date", "bool", "dec"]), 2) for _ in range(nk)]
            aggs = [self.agg(scope) for _ in range(r.randrange(1, 4))]
            sel = ", ".join(keys + aggs)
            sql = f"SELECT {sel} FROM {frm}{where}"
            if keys:
                sql += " GROUP BY " + ", ".join(str(i + 1) for i in range(nk))
                if r.random() < 0.3:
                    sql += f" HAVING COUNT(*) > {r.choice([1, 2, 5])}"
            return sql, False
        # subqueries
        alias, table = scope[0]
        k = r.choice(["int", "str"])
        cols = self.cols([(alias, table)], k)
        if not cols:
            return f"SELECT COUNT(*) FROM {frm}{where}", False
        col, _ = r.choice(cols)
        other = r.choice(list(self.schemas))
        ocols = self.cols([("s", other)], k)
        if not ocols:
            return f"SELECT COUNT(*) FROM {frm}{where}", False
        ocol, _ = r.choice(ocols)
        c = r.randrange(3)
        if c == 0:
            sub = f"{col} {r.choice(['', 'NOT '])}IN (SELECT {ocol} FROM {other} s WHERE {self.pred([('s', other)], 2)})"
        elif c == 1:
            sub = f"{r.choice(['', 'NOT '])}EXISTS (SELECT 1 FROM {other} s WHERE {ocol} = {col})"
        else:
            sub = f"{col} {r.choice(['=', '<', '>='])} (SELECT {r.choice(['MIN', 'MAX'])}({ocol}) FROM {other} s)"
        w = f" WHERE {sub}" + (f" AND {self.pred(scope, 2)}" if r.random() < 0.5 else "")
        return f"SELECT COUNT(*), {self.agg(scope)} FROM {frm}{w}", False


def kind_of(t: str) -> str:
    t = t.upper()
    if t == "INT64":
        return "int"
    if t.startswith("DECIMAL"):
        return "dec"
    if t == "FLOAT64":
        return "float"
    if t == "STRING":
        return "str"
    if t == "BOOLEAN":
        return "bool"
    if t == "DATE":
        return "date"
    if t == "TIMESTAMP":
        return "ts"
    return "other"


# ------------------------------------------------------------ comparison

def norm(v):
    if isinstance(v, float):
        return ("f", v)
    if v is None:
        return ("n", 0)
    return ("v", json.dumps(v))


def close(a, b):
    if isinstance(a, float) or isinstance(b, float):
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
            return False
        return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-9)
    return a == b


def rows_equal(x, y, ordered):
    if len(x) != len(y):
        return False
    if not ordered:
        key = lambda row: [norm(v) if not isinstance(v, float) else ("f", round(v, 6)) for v in row]
        try:
            x = sorted(x, key=key)
            y = sorted(y, key=key)
        except TypeError:
            return False
    return all(len(a) == len(b) and all(close(p, q) for p, q in zip(a, b)) for a, b in zip(x, y))


def outcome(resp):
    if not resp.get("ok"):
        return ("error", resp["error"]["code"])
    return ("ok", resp.get("columns"), resp.get("rows"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--queries", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    launcher = str(Path(args.engine).resolve())

    tmp = Path(tempfile.mkdtemp(prefix="pqdiff-"))
    (tmp / "fixtures").symlink_to(FIXTURES)
    (tmp / "out").mkdir()
    engines = [
        Engine(launcher, str(tmp), dict(os.environ)),
        Engine(launcher, str(tmp), dict(os.environ, POLYQUERY_MORSEL_ROWS="37")),
    ]
    schemas = {}
    for name, base in TABLES.items():
        schema = json.loads((FIXTURES / "gen" / f"{base}.schema.json").read_text())
        schemas[name] = [(c["name"], c["type"]) for c in schema]
        for e in engines:
            r = e.call({"op": "load", "table": name, "format": "csv", "path": f"fixtures/gen/{base}.csv",
                        "schema": schema})
            assert r.get("ok"), r
    for name, (src, kind) in COPIES.items():
        schemas[name] = schemas[src]
        for i, e in enumerate(engines):
            if kind == "pqcf":
                path = f"out/{name}{i}.pqcf"
                assert e.call({"op": "save", "table": src, "path": path,
                               "options": {"row_group_size": 173}}).get("ok")
                r = e.call({"op": "open", "table": name, "path": path, "options": {"mmap": i == 0}})
            else:
                schema = json.loads((FIXTURES / "gen" / f"{TABLES[src]}.schema.json").read_text())
                r = e.call({"op": "load", "table": name, "format": "csv",
                            "path": f"fixtures/gen/{TABLES[src]}.csv", "schema": schema,
                            "options": {"layout": "row"}})
            assert r.get("ok"), r

    gen = Gen(random.Random(args.seed), schemas)
    failures = 0
    errors = 0
    for qi in range(args.queries):
        sql, ordered = gen.query()
        base = engines[0].call({"op": "query", "sql": sql, "options": dict(BASELINE)})
        bo = outcome(base)
        if bo[0] == "error":
            errors += 1
        for e in engines:
            for v in VARIANTS:
                got = outcome(e.call({"op": "query", "sql": sql, "options": dict(v)}))
                same = got[0] == bo[0]
                if same and bo[0] == "error":
                    same = got[1] == bo[1]
                elif same:
                    same = got[1] == bo[1] and (
                        len(got[2]) == len(bo[2]) if ordered == "limit" and not sql.count("ORDER BY")
                        else rows_equal(bo[2], got[2], ordered is True)
                        if ordered != "limit" else rows_equal(bo[2], got[2], True))
                if not same:
                    failures += 1
                    print(f"MISMATCH q{qi} variant={v} morsels={'tiny' if e is engines[1] else 'default'}\n  {sql}")
                    print(f"  baseline: {str(bo)[:400]}\n  got:      {str(got)[:400]}", flush=True)
                    break
        if args.verbose and qi % 50 == 0:
            print(f"{qi} queries, {failures} mismatches, {errors} baseline errors", flush=True)
    for e in engines:
        e.close()
    print(f"{args.queries} queries, {failures} mismatches ({errors} queries ended in errors)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
