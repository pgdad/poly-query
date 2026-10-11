#!/usr/bin/env python3
"""Randomized differential test of the execution options (development aid).

Generates random queries over the conformance fixture tables and runs each
under several option combinations (row / vectorized / parallel, join
algorithms, optimize on/off). Results must be identical (multisets, FLOAT64
with the conformance tolerance) and errors must have the same code.
Tables are also saved as multi-row-group PQCF files and reopened, and loaded
in the row layout, so every storage path is exercised.

  POLYQUERY_MORSEL_ROWS=37 bench/fuzz.py --engine bin/polyquery --count 2000 --seed 1

With --native LIB the engine loads the native kernel library and every
vectorized configuration also runs with `native: true`; with threads: 1
those results must be *exactly* equal (same rows in the same order, same
floats) to the results of the same configuration without native kernels.
(Parallel runs sum floats in an order that varies from run to run, so
there the rows must be in the same order with floats equal up to the
tolerance.)
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parent.parent.parent / "tests" / "conformance" / "fixtures"

CONFIGS = [
    {"mode": "row", "threads": 1, "join": "hash"},
    {"mode": "vectorized", "threads": 1},
    {"mode": "vectorized", "threads": 4},
    {"mode": "vectorized", "threads": 3, "join": "merge"},
    {"mode": "vectorized", "threads": 2, "join": "nested_loop", "optimize": False},
    {"mode": "row", "threads": 1, "join": "merge", "optimize": False},
    {"mode": "row", "threads": 1, "join": "nested_loop"},
]

TABLES = {
    "tx": "transactions", "cust": "customers", "orders": "orders", "items": "order_items",
    "products": "products", "nh": "nulls_heavy", "sens": "sensor_readings",
}


class Session:
    def __init__(self, engine: str, data_dir: str, extra_args=()):
        self.proc = subprocess.Popen([engine, "session", "--data-dir", data_dir, *extra_args],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=data_dir)

    def request(self, req: dict) -> dict:
        self.proc.stdin.write((json.dumps(req) + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("engine died")
        return json.loads(line)


def float_close(a, b):
    return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))


def same_rows(a, b):
    if len(a) != len(b):
        return False
    key = lambda r: [("%.6e" % x) if isinstance(x, float) else json.dumps(x) for x in r]
    for ra, rb in zip(sorted(a, key=key), sorted(b, key=key)):
        for x, y in zip(ra, rb):
            if isinstance(x, float) or isinstance(y, float):
                if not (isinstance(x, (int, float)) and isinstance(y, (int, float)) and float_close(x, y)):
                    return False
            elif x != y:
                return False
    return True


class Gen:
    def __init__(self, rng: random.Random, schemas: dict):
        self.r = rng
        self.schemas = schemas

    def cols(self, alias, table, kind):
        return [f"{alias}.{c}" for c, t in self.schemas[table] if self.kind(t) == kind]

    @staticmethod
    def kind(t):
        if t.startswith("DECIMAL"):
            return "DECIMAL"
        return t

    def lit(self, kind):
        r = self.r
        if kind == "INT64":
            return str(r.choice([0, 1, 2, 3, 5, 7, 10, 100, -3, 1000, 123456]))
        if kind == "DECIMAL":
            return r.choice(["0.5", "1.25", "10.00", "-2.5", "100.75", "0.01"])
        if kind == "FLOAT64":
            return r.choice(["1.5e0", "0.25e0", "-3.75e0", "100.0e0", "2e0"])
        if kind == "STRING":
            return r.choice(["'a'", "'approved'", "'ok'", "'enterprise'", "'x%'", "''", "'US'"])
        if kind == "BOOLEAN":
            return r.choice(["TRUE", "FALSE"])
        if kind == "DATE":
            return r.choice(["DATE '2023-06-01'", "DATE '2024-01-15'", "DATE '2022-12-31'"])
        if kind == "TIMESTAMP":
            return r.choice(["TIMESTAMP '2023-06-01 12:00:00'", "TIMESTAMP '2024-03-01 00:00:00'"])
        raise ValueError(kind)

    def expr(self, kind, scope, depth=0):
        """Random expression of KIND over SCOPE [(alias, table)]."""
        r = self.r
        cols = [c for a, t in scope for c in self.cols(a, t, kind)]
        if depth >= 3 or r.random() < 0.3:
            if cols and r.random() < 0.75:
                return r.choice(cols)
            if r.random() < 0.05:
                return "NULL"
            return self.lit(kind)
        d = depth + 1
        e = lambda k=kind: self.expr(k, scope, d)
        choice = r.random()
        if kind == "INT64":
            opts = [lambda: f"({e()} + {e()})", lambda: f"({e()} - {e()})", lambda: f"({e()} * {self.lit('INT64')})",
                    lambda: f"({e()} / {r.choice(['2', '3', '7', e()])})", lambda: f"({e()} % {r.choice(['2', '5', e()])})",
                    lambda: f"ABS({e()})", lambda: f"LENGTH({e('STRING')})", lambda: f"-{e()}",
                    lambda: f"CASE WHEN {e('BOOLEAN')} THEN {e()} ELSE {e()} END",
                    lambda: f"COALESCE({e()}, {e()})", lambda: f"NULLIF({e()}, {e()})",
                    lambda: f"CAST({e('DECIMAL')} AS INT64)", lambda: f"YEAR({e('DATE')})",
                    lambda: f"MONTH({e('TIMESTAMP')})", lambda: f"MOD({e()}, 4)", lambda: f"FLOOR({e()})",
                    lambda: f"HOUR({e('TIMESTAMP')})", lambda: f"SECOND({e('TIMESTAMP')})",
                    lambda: f"DATE_DIFF('day', {e('DATE')}, {e('TIMESTAMP')})",
                    lambda: f"CAST({e('STRING')} AS INT64)", lambda: f"CEIL({e('DECIMAL')})",
                    lambda: f"ROUND({e('FLOAT64')})" if False else f"LENGTH(CAST({e()} AS STRING))"]
        elif kind == "DECIMAL":
            opts = [lambda: f"({e()} + {e()})", lambda: f"({e()} - {e()})", lambda: f"({e()} * 2)",
                    lambda: f"ROUND({e()}, 1)", lambda: f"ABS({e()})", lambda: f"-{e()}",
                    lambda: f"CASE WHEN {e('BOOLEAN')} THEN {e()} ELSE {e()} END",
                    lambda: f"COALESCE({e()}, {self.lit('DECIMAL')})", lambda: f"({e()} + {e('INT64')})",
                    lambda: f"CAST({e('FLOAT64')} AS DECIMAL(12,2))", lambda: f"CEIL({e()})",
                    lambda: f"NULLIF({e()}, {self.lit('DECIMAL')})", lambda: f"({e()} * {e()})"]
        elif kind == "FLOAT64":
            opts = [lambda: f"({e()} + {e()})", lambda: f"({e()} * {e()})", lambda: f"({e()} / {r.choice(['2.0e0', e()])})",
                    lambda: f"SQRT(ABS({e()}))", lambda: f"CAST({e('INT64')} AS FLOAT64)", lambda: f"-{e()}",
                    lambda: f"CAST({e('DECIMAL')} AS FLOAT64)", lambda: f"({e()} - {e('INT64')})",
                    lambda: f"CASE WHEN {e('BOOLEAN')} THEN {e()} END",
                    lambda: f"POWER({e()}, 2)", lambda: f"ROUND({e()}, 2)", lambda: f"FLOOR({e()})",
                    lambda: f"COALESCE({e()}, {e('INT64')})"]
        elif kind == "STRING":
            opts = [lambda: f"UPPER({e()})", lambda: f"LOWER({e()})", lambda: f"SUBSTR({e()}, 2, 3)",
                    lambda: f"TRIM({e()})", lambda: f"({e()} || {e()})", lambda: f"CONCAT({e()}, '-', {e('INT64')})",
                    lambda: f"REPLACE({e()}, 'a', 'b')", lambda: f"CAST({e('INT64')} AS STRING)",
                    lambda: f"CASE {e()} WHEN {self.lit('STRING')} THEN 'one' WHEN {e()} THEN 'two' ELSE {e()} END",
                    lambda: f"COALESCE({e()}, 'none')", lambda: f"LTRIM({e()})", lambda: f"RTRIM({e()})",
                    lambda: f"NULLIF({e()}, 'ok')", lambda: f"CAST({e('DATE')} AS STRING)",
                    lambda: f"CAST({e('DECIMAL')} AS STRING)", lambda: f"SUBSTR({e()}, {e('INT64')})"]
        elif kind == "BOOLEAN":
            k = r.choice(["INT64", "INT64", "DECIMAL", "FLOAT64", "STRING", "DATE", "TIMESTAMP"])
            op = r.choice(["=", "<>", "<", "<=", ">", ">="])
            mixed = {"INT64": "DECIMAL", "DECIMAL": "INT64", "FLOAT64": "INT64", "DATE": "TIMESTAMP"}.get(k, k)
            opts = [lambda: f"({e(k)} {op} {e(k)})", lambda: f"({e(k)} {op} {self.lit(k)})",
                    lambda: f"({e(k)} {op} {e(mixed)})",
                    lambda: f"({e()} AND {e()})", lambda: f"({e()} OR {e()})", lambda: f"NOT {e()}",
                    lambda: f"{e(k)} IS NULL", lambda: f"{e(k)} IS NOT NULL",
                    lambda: f"{e(k)} BETWEEN {self.lit(k)} AND {e(k)}",
                    lambda: f"{e(k)} IN ({self.lit(k)}, {self.lit(k)}, {e(k)})",
                    lambda: f"{e(k)} IN ({self.lit(k)}, {self.lit(k)})",
                    lambda: f"{e('STRING')} LIKE {r.choice(['%a%', 'a%', '_x%', '%'])!r}".replace('"', "'")]
        elif kind == "DATE":
            opts = [lambda: f"CAST({e('TIMESTAMP')} AS DATE)", lambda: f"COALESCE({e()}, DATE '2020-01-01')"]
        elif kind == "TIMESTAMP":
            opts = [lambda: f"DATE_TRUNC('month', {e()})", lambda: f"CAST({e('DATE')} AS TIMESTAMP)",
                    lambda: f"DATE_TRUNC('day', {e('DATE')})"]
        else:
            raise ValueError(kind)
        return r.choice(opts)()

    def scope_for(self):
        r = self.r
        shape = r.random()
        if shape < 0.5:
            t = r.choice(list(self.schemas) + ["ext", "ext", "empty"])
            return [("a", t)], f"{t} a"
        if shape < 0.62:
            # Three inputs (join reordering): explicit joins or a comma list.
            scope = [("a", "items"), ("b", "orders"), ("c", "products")]
            extra = f" AND {self.expr('BOOLEAN', scope, 2)}" if r.random() < 0.4 else ""
            if r.random() < 0.5:
                return scope, ("products c, items a, orders b WHERE a.order_id = b.order_id "
                               f"AND a.product_id = c.product_id{extra}")
            kind = r.choice(["JOIN", "LEFT JOIN"])
            return scope, (f"orders b JOIN items a ON a.order_id = b.order_id {kind} products c "
                           f"ON c.product_id = a.product_id{extra}")
        if shape < 0.8:
            pairs = [("tx", "cust", "customer_id", "customer_id"), ("orders", "cust", "customer_id", "customer_id"),
                     ("items", "orders", "order_id", "order_id"), ("items", "products", "product_id", "product_id"),
                     ("txp", "cust", "customer_id", "customer_id"), ("txr", "custr", "customer_id", "customer_id")]
            lt, rt, lk, rk = r.choice([p for p in pairs if p[0] in self.schemas and p[1] in self.schemas])
            kind = r.choice(["JOIN", "JOIN", "LEFT JOIN"])
            cond = f"a.{lk} = b.{rk}"
            if r.random() < 0.3:
                cond += f" AND {self.expr('BOOLEAN', [('a', lt), ('b', rt)], 2)}"
            return [("a", lt), ("b", rt)], f"{lt} a {kind} {rt} b ON {cond}"
        lt, rt = r.choice([("orders", "products"), ("products", "cust"), ("cust", "products")])
        return [("a", lt), ("b", rt)], f"{lt} a, {rt} b"

    def subquery_predicate(self, scope):
        """A predicate with an (uncorrelated or correlated) subquery."""
        r = self.r
        alias, table = scope[0]
        keyed = {"tx": "customer_id", "orders": "customer_id", "cust": "customer_id", "txp": "customer_id",
                 "txr": "customer_id", "custr": "customer_id", "items": "order_id"}
        if table in keyed and r.random() < 0.6:
            k = keyed[table]
            other = {"customer_id": r.choice(["cust", "orders", "tx"]), "order_id": "items"}[k]
            inner = self.expr("BOOLEAN", [("s", other)], 2)
            if r.random() < 0.5:
                return f"{alias}.{k} IN (SELECT s.{k} FROM {other} s WHERE {inner})"
            neg = "NOT " if r.random() < 0.3 else ""
            return f"{neg}EXISTS (SELECT 1 FROM {other} s WHERE s.{k} = {alias}.{k} AND {inner})"
        k = r.choice(["INT64", "DECIMAL"])
        cols = self.cols(alias, table, k)
        if not cols:
            return self.expr("BOOLEAN", scope)
        return f"{r.choice(cols)} > (SELECT AVG({r.choice(cols).split('.')[1]}) FROM {table})"

    def query(self):
        r = self.r
        shape = r.random()
        if shape < 0.08:
            # Derived table / CTE.
            t = r.choice(["tx", "orders", "items", "cust"])
            inner_scope = [("x", t)]
            e1 = self.expr(r.choice(["INT64", "STRING", "BOOLEAN"]), inner_scope, 1)
            e2 = self.expr(r.choice(["INT64", "DECIMAL"]), inner_scope, 1)
            where = f" WHERE {self.expr('BOOLEAN', inner_scope)}" if r.random() < 0.5 else ""
            body = f"SELECT {e1} AS k, {e2} AS v FROM {t} x{where}"
            if r.random() < 0.5:
                return f"WITH d AS ({body}) SELECT k, COUNT(*) AS n, SUM(v) AS s, MIN(v) AS lo FROM d GROUP BY k"
            return f"SELECT d.k, MAX(d.v) AS m FROM ({body}) d GROUP BY d.k HAVING COUNT(*) >= 1"
        if shape < 0.16:
            scope, from_ = self.scope_for()
            pred = self.subquery_predicate(scope)
            items = ", ".join(f"{self.expr(r.choice(['INT64', 'STRING', 'DECIMAL']), scope, 1)} AS c{i}"
                              for i in range(r.randint(1, 3)))
            return f"SELECT {items} FROM {from_} {'AND' if ' WHERE ' in from_ else 'WHERE'} {pred}"
        if shape < 0.24:
            scope, from_ = self.scope_for()
            items = [f"{self.expr(r.choice(['INT64', 'STRING', 'DECIMAL', 'DATE']), scope, 1)} AS c{i}"
                     for i in range(r.randint(1, 3))]
            where = f" {'AND' if ' WHERE ' in from_ else 'WHERE'} {self.expr('BOOLEAN', scope)}" if r.random() < 0.6 else ""
            order = ", ".join(f"{i + 1} {r.choice(['ASC', 'DESC'])} NULLS {r.choice(['FIRST', 'LAST'])}"
                              for i in range(len(items)))
            limit = f" LIMIT {r.randint(0, 40)} OFFSET {r.randint(0, 5)}" if r.random() < 0.5 else ""
            return ("ORDERED", f"SELECT {', '.join(items)} FROM {from_}{where} ORDER BY {order}{limit}")
        scope, from_ = self.scope_for()
        where = f" {'AND' if ' WHERE ' in from_ else 'WHERE'} {self.expr('BOOLEAN', scope)}" if r.random() < 0.7 else ""
        kinds = ["INT64", "DECIMAL", "FLOAT64", "STRING", "BOOLEAN", "DATE", "TIMESTAMP"]
        shape = r.random()
        if shape < 0.4:
            items = ", ".join(f"{self.expr(r.choice(kinds), scope)} AS c{i}" for i in range(r.randint(1, 4)))
            distinct = "DISTINCT " if r.random() < 0.15 else ""
            tail = ""
            if r.random() < 0.2:
                tail = f" ORDER BY 1 LIMIT {r.randint(0, 30)}"
                return None  # order of ties is implementation-defined: skip
            return f"SELECT {distinct}{items} FROM {from_}{where}{tail}"
        aggs = []
        for i in range(r.randint(1, 4)):
            k = r.choice(["INT64", "DECIMAL", "FLOAT64", "STRING", "DATE"])
            fn = r.choice(["COUNT", "SUM", "AVG", "MIN", "MAX", "COUNT_STAR", "COUNT_DISTINCT", "SUM_DISTINCT"])
            if fn in ("SUM", "AVG", "SUM_DISTINCT") and k in ("STRING", "DATE"):
                k = "INT64"
            arg = self.expr(k, scope, 1)
            aggs.append({"COUNT_STAR": "COUNT(*)", "COUNT_DISTINCT": f"COUNT(DISTINCT {arg})",
                         "SUM_DISTINCT": f"SUM(DISTINCT {arg})"}.get(fn, f"{fn}({arg})") + f" AS g{i}")
        if shape < 0.6:
            return f"SELECT {', '.join(aggs)} FROM {from_}{where}"
        keys = [self.expr(r.choice(["INT64", "STRING", "BOOLEAN", "DATE", "DECIMAL"]), scope, 2)
                for _ in range(r.randint(1, 2))]
        having = f" HAVING COUNT(*) > {r.randint(0, 3)}" if r.random() < 0.3 else ""
        sel = ", ".join([f"{k} AS k{i}" for i, k in enumerate(keys)] + aggs)
        return f"SELECT {sel} FROM {from_}{where} GROUP BY {', '.join(keys)}{having}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--count", type=int, default=500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--native", metavar="LIBPQKERNELS", help="also run vectorized configurations with native: true")
    args = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="pqfuzz-")
    os.symlink(FIXTURES, f"{tmp}/fixtures")
    configs = list(CONFIGS)
    twins = {}                       # index of a native config -> index of its non-native twin
    if args.native:
        for k, cfg in enumerate(CONFIGS):
            if cfg["mode"] == "vectorized":
                twins[len(configs)] = k
                configs.append({**cfg, "native": True})
    s = Session(os.path.abspath(args.engine), tmp,
                ["--native-kernels", os.path.abspath(args.native)] if args.native else [])
    schemas = {}
    for name, base in TABLES.items():
        schema = json.load(open(FIXTURES / "gen" / f"{base}.schema.json"))
        r = s.request({"op": "load", "table": name, "format": "csv", "path": f"fixtures/gen/{base}.csv",
                       "schema": schema})
        assert r["ok"], r
        schemas[name] = [(c["name"], c["type"]) for c in schema]
    # Multi-segment PQCF copy and row-layout copies.
    assert s.request({"op": "save", "table": "tx", "path": "tx.pqcf", "row_group_size": 300})["ok"]
    assert s.request({"op": "open", "table": "txp", "path": "tx.pqcf", "mmap": True})["ok"]
    schemas["txp"] = schemas["tx"]
    for name, base in (("txr", "transactions"), ("custr", "customers")):
        schema = json.load(open(FIXTURES / "gen" / f"{base}.schema.json"))
        assert s.request({"op": "load", "table": name, "format": "csv", "path": f"fixtures/gen/{base}.csv",
                          "schema": schema, "layout": "row"})["ok"]
        schemas[name] = [(c["name"], c["type"]) for c in schema]

    # Indexes, so that index scans (row operators behind batch adapters) run.
    for stmt in ("CREATE INDEX fz_tx_cust ON tx (customer_id) USING HASH",
                 "CREATE INDEX fz_tx_amount ON tx (amount)",
                 "CREATE INDEX fz_orders_id ON orders (order_id)",
                 "CREATE INDEX fz_items_product ON items (product_id) USING HASH",
                 "CREATE INDEX fz_cust_seg ON cust (segment)"):
        assert s.request({"op": "query", "sql": stmt})["ok"]
    # Edge values and an empty table.
    ext_schema = [("i", "INT64"), ("d", "DECIMAL(18,4)"), ("f", "FLOAT64"), ("s", "STRING"),
                  ("b", "BOOLEAN"), ("dt", "DATE"), ("ts", "TIMESTAMP")]
    rng = random.Random(args.seed * 7919)
    ints = ["9223372036854775807", "-9223372036854775808", "0", "1", "-1", "", "4611686018427387904", "42"]
    decs = ["99999999999999.9999", "-0.0001", "0", "", "12345.6789", "-99999999999999.9999", "1"]
    floats = ["1e300", "-0.0", "0.0", "1.5", "", "-2.25", "3e-300", "123456.789"]
    strs = ["", "Ünïcödé", "a%b", "_x_", "", "  pad  ", "ok", "approved", "zzz", "A"]
    lines = ["i,d,f,s,b,dt,ts"]
    for k in range(60):
        lines.append(",".join([rng.choice(ints), rng.choice(decs), rng.choice(floats),
                               '"%s"' % rng.choice(strs) if rng.random() < 0.9 else "",
                               rng.choice(["true", "false", ""]),
                               rng.choice(["2024-02-29", "0001-01-01", "9999-12-31", "1970-01-01", ""]),
                               rng.choice(["2024-02-29 23:59:59.999999", "1970-01-01 00:00:00", ""])]))
    for name, data in (("ext", "\n".join(lines) + "\n"), ("empty", "i,d,f,s,b,dt,ts\n")):
        r = s.request({"op": "load", "table": name, "format": "csv", "data": data,
                       "schema": [{"name": c, "type": t} for c, t in ext_schema]})
        assert r["ok"], r
        schemas[name] = ext_schema

    gen = Gen(random.Random(args.seed), schemas)
    bad = 0
    ran = 0
    errors = 0
    while ran < args.count:
        sql = gen.query()
        if sql is None:
            continue
        ordered = isinstance(sql, tuple)
        if ordered:
            sql = sql[1]
        ran += 1
        outs = []
        for cfg in configs:
            r = s.request({"op": "query", "sql": sql, "options": cfg})
            outs.append(("ok", r["rows"]) if r["ok"] else ("error", r["error"]["code"]))
        ref = outs[0]
        if ref[0] == "error":
            errors += 1
            if ref[1] == "INTERNAL_ERROR":
                print("INTERNAL_ERROR (row):", sql)
        for k, twin in twins.items():
            a, b = outs[k], outs[twin]
            if configs[k]["threads"] == 1:
                same = a == b
            else:
                same = a[0] == b[0] and (a[1] == b[1] if a[0] == "error" else
                                         len(a[1]) == len(b[1]) and
                                         all(same_rows([x], [y]) for x, y in zip(a[1], b[1])))
            if not same:
                bad += 1
                print(f"NATIVE MISMATCH {configs[k]}: {sql}")
                print("   plain: ", str(outs[twin])[:300])
                print("   native:", str(outs[k])[:300])
        for cfg, o in zip(configs[1:], outs[1:]):
            ok = (o[0] == ref[0] and (o[1] == ref[1] if o[0] == "error" else same_rows(o[1], ref[1])))
            if ok and ordered and o[0] == "ok":
                ok = all(same_rows([x], [y]) for x, y in zip(o[1], ref[1]))
            if not ok:
                bad += 1
                print(f"MISMATCH {cfg}: {sql}")
                print("   ref:", str(ref)[:300])
                print("   got:", str(o)[:300])
                break
        if args.verbose:
            print(ref[0], sql)
    print(f"{ran} queries, {errors} errors (in all modes), {bad} mismatches")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
