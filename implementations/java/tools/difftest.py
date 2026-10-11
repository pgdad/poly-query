#!/usr/bin/env python3
"""Randomized differential test of the execution options (development tool).

Generates random queries over the conformance fixtures and runs each one under every
combination of mode x join x threads x optimize, in engines started with different batch and
morsel sizes; all results must equal the row-mode baseline (multiset comparison unless the
query orders all output columns; FLOAT64 with relative tolerance; errors by code).

  python3 tools/difftest.py --engine bin/polyquery --data ../../tests/conformance --queries 300 --seed 1

With --native-kernels LIB the engines load the native kernel library and every vectorized
combination also runs with `native: true`.

Since CR-2 a generated table `wd` (written to the data directory) holds wide DECIMALs
(precision 19-38) next to INT64 and narrow DECIMAL columns; it is also saved as PQCF v2 with
small row groups (`wd_p`, memory-mapped, with an index) and queried with wide arithmetic,
exact mixed comparisons, wide join/group/sort keys and aggregates.
"""
import argparse
import itertools
import json
import random
import subprocess
import sys

TABLES = {
    "tx": ("fixtures/gen/transactions.csv", "fixtures/gen/transactions.schema.json"),
    "cust": ("fixtures/gen/customers.csv", "fixtures/gen/customers.schema.json"),
    "orders": ("fixtures/gen/orders.csv", "fixtures/gen/orders.schema.json"),
    "items": ("fixtures/gen/order_items.csv", "fixtures/gen/order_items.schema.json"),
    "products": ("fixtures/gen/products.csv", "fixtures/gen/products.schema.json"),
    "nh": ("fixtures/gen/nulls_heavy.csv", "fixtures/gen/nulls_heavy.schema.json"),
    "sk": ("fixtures/gen/sort_keys.csv", "fixtures/gen/sort_keys.schema.json"),
}


class Engine:
    def __init__(self, launcher, data, jvm_opts, native=None):
        env = dict(__import__("os").environ)
        env["POLYQUERY_JAVA_OPTS"] = jvm_opts
        extra = ["--native-kernels", native] if native else []
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data] + extra, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, env=env, text=True)
        self.n = 0

    def req(self, obj):
        self.n += 1
        obj["id"] = self.n
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("engine died")
        return json.loads(line)

    def close(self):
        self.p.stdin.close()
        self.p.wait()


WIDE_SCHEMA = [("id", "INT64"), ("g", "STRING"), ("i", "INT64"), ("n1", "DECIMAL(10,2)"),
               ("w1", "DECIMAL(38,10)"), ("w2", "DECIMAL(25,2)"), ("w3", "DECIMAL(30,0)")]


def write_wide(data, rows=600, seed=7):
    """wd.csv: wide DECIMAL columns with NULLs, duplicates, extreme and small values."""
    rnd = random.Random(seed)

    def dec(int_digits, scale):
        r = rnd.random()
        if r < 0.1:
            return ""
        if r < 0.25:  # small values, also equal to narrow / integer values
            v = rnd.choice(["0", "1", "-1", "10", "100", "250"] + (["2.5", "-3.75", "1000.5"] if scale else []))
        elif r < 0.35:  # extremes
            v = ("-" if rnd.random() < 0.5 else "") + "9" * int_digits + ("." + "9" * scale if scale else "")
        else:
            n = rnd.randint(1, int_digits)
            v = ("-" if rnd.random() < 0.3 else "") + str(rnd.randint(10 ** (n - 1), 10 ** n - 1))
            if scale:
                v += "." + str(rnd.randint(0, 10 ** scale - 1)).zfill(scale)
        return v

    with open(f"{data}/wd.csv", "w") as f:
        f.write(",".join(n for n, _ in WIDE_SCHEMA) + "\n")
        for k in range(rows):
            i = rnd.choice(["", str(rnd.randint(-5, 300)), str(rnd.choice([9223372036854775807, -9223372036854775807,
                                                                            10 ** 18, 123456789012345678]))])
            n1 = "" if rnd.random() < 0.1 else rnd.choice(["0.00", "1.00", "2.50", "-3.75", "10.00", "100.00",
                                                           str(rnd.randint(-99999999, 99999999)) + ".99"])
            f.write(",".join([str(k), rnd.choice(["a", "b", "c", "d"]), i, n1, dec(28, 10), dec(23, 2),
                              dec(30, 0)]) + "\n")


def setup(engine, data):
    schemas = {}
    write_wide(data)
    r = engine.req({"op": "load", "table": "wd", "path": "wd.csv", "format": "csv",
                    "schema": [{"name": n, "type": t} for n, t in WIDE_SCHEMA]})
    assert r["ok"], r
    schemas["wd"] = list(WIDE_SCHEMA)
    r = engine.req({"op": "save", "table": "wd", "path": "dt_wd.pqcf", "options": {"row_group_size": 64}})
    assert r["ok"], r
    r = engine.req({"op": "open", "table": "wd_p", "path": "dt_wd.pqcf", "options": {"mmap": True}})
    assert r["ok"], r
    r = engine.req({"op": "query", "sql": "CREATE INDEX wd_p_w1 ON wd_p (w1)"})
    assert r["ok"], r
    r = engine.req({"op": "query", "sql": "CREATE INDEX wd_p_w3 ON wd_p (w3) USING HASH"})
    assert r["ok"], r
    schemas["wd_p"] = list(WIDE_SCHEMA)
    for name, (path, schemafile) in TABLES.items():
        schema = json.load(open(f"{data}/{schemafile}"))
        r = engine.req({"op": "load", "table": name, "path": path, "format": "csv", "schema": schema})
        assert r["ok"], r
        schemas[name] = [(c["name"], c["type"]) for c in schema]
    # PQCF copies with small row groups (several groups, per-group dictionaries), memory-mapped
    for name in ("tx", "nh"):
        r = engine.req({"op": "save", "table": name, "path": f"dt_{name}.pqcf",
                        "options": {"row_group_size": 300}})
        assert r["ok"], r
        r = engine.req({"op": "open", "table": f"{name}_p", "path": f"dt_{name}.pqcf", "options": {"mmap": True}})
        assert r["ok"], r
        schemas[f"{name}_p"] = schemas[name]
    r = engine.req({"op": "load", "table": "items_r", "path": TABLES["items"][0], "format": "csv",
                    "schema": json.load(open(f"{data}/{TABLES['items'][1]}")), "options": {"layout": "row"}})
    assert r["ok"], r
    schemas["items_r"] = schemas["items"]
    return schemas


class Gen:
    def __init__(self, rnd, schemas):
        self.r = rnd
        self.s = schemas

    def cols(self, alias, table, kind):
        out = []
        for name, t in self.s[table]:
            k = t
            if t.startswith("DECIMAL"):
                k = "WIDE" if int(t[8:t.index(",")]) > 18 else "DEC"
            if k == kind:
                out.append(f"{alias}.{name}")
        return out

    def expr(self, scope, kind, depth=0):
        r = self.r
        cands = [c for a, t in scope for c in self.cols(a, t, kind)]
        if depth > 2 or (cands and r.random() < 0.45):
            if cands and r.random() < 0.85:
                return r.choice(cands)
            return self.literal(kind)
        if kind == "INT64":
            a = self.expr(scope, "INT64", depth + 1)
            b = self.expr(scope, "INT64", depth + 1)
            return r.choice([f"({a} + {b})", f"({a} - {b})", f"({a} * {r.randint(-3, 3)})",
                             f"({a} / {r.choice([1, 2, 3, 7, -2])})", f"({a} % {r.choice([2, 5, 10])})",
                             f"ABS({a})", f"COALESCE({a}, {b})", f"NULLIF({a}, {r.randint(0, 5)})",
                             f"CASE WHEN {self.pred(scope, depth + 1)} THEN {a} ELSE {b} END",
                             f"LENGTH({self.expr(scope, 'STRING', depth + 1)})",
                             f"CAST({self.expr(scope, 'DEC', depth + 1)} AS INT64)",
                             f"({a} / ({b} - {r.randint(0, 3)}))"])
        if kind == "DEC":
            a = self.expr(scope, "DEC", depth + 1)
            b = self.expr(scope, "DEC", depth + 1)
            return r.choice([f"({a} + {b})", f"({a} - {b})", f"({a} * 2)", f"ROUND({a}, 1)", f"-{a}",
                             f"CASE WHEN {self.pred(scope, depth + 1)} THEN {a} END", f"({a} + 1)"])
        if kind == "WIDE":
            a = self.expr(scope, "WIDE", depth + 1)
            b = self.expr(scope, r.choice(["WIDE", "DEC", "INT64"]), depth + 1)
            return r.choice([f"({a} + {b})", f"({a} - {b})", f"({a} * {r.choice(['2', '0.5', '-3', '1.25'])})",
                             f"({a} * {b})", f"-({a})", f"ABS({a})", f"ROUND({a}, {r.randint(-2, 3)})",
                             f"FLOOR({a})", f"CEIL({a})", f"COALESCE({a}, {b})", f"NULLIF({a}, {self.literal('WIDE')})",
                             f"CASE WHEN {self.pred(scope, depth + 1)} THEN {a} ELSE {b} END",
                             f"CAST({self.expr(scope, 'DEC', depth + 1)} AS DECIMAL(38,4))",
                             f"CAST({self.expr(scope, 'INT64', depth + 1)} AS DECIMAL(30,2))",
                             f"CAST({a} AS DECIMAL(38,1))", f"CAST(CAST({a} AS STRING) AS DECIMAL(38,10))"])
        if kind == "FLOAT64":
            a = self.expr(scope, "FLOAT64", depth + 1)
            return r.choice([f"({a} * 1.5e0)", f"({a} + {self.expr(scope, 'INT64', depth + 1)})",
                             f"CAST({self.expr(scope, 'DEC', depth + 1)} AS FLOAT64)", f"({a} / 3.0e0)"])
        if kind == "STRING":
            a = self.expr(scope, "STRING", depth + 1)
            return r.choice([f"UPPER({a})", f"SUBSTR({a}, 1, 3)", f"({a} || 'x')", f"LOWER({a})",
                             f"CASE WHEN {self.pred(scope, depth + 1)} THEN {a} ELSE 'zz' END",
                             f"CAST({self.expr(scope, 'INT64', depth + 1)} AS STRING)"])
        if kind == "BOOLEAN":
            return self.pred(scope, depth + 1)
        return self.literal(kind)

    def literal(self, kind):
        r = self.r
        if kind == "INT64":
            return str(r.choice([0, 1, 2, 5, 10, 100, 1000, -1, 250, 1500]))
        if kind == "DEC":
            return r.choice(["0.50", "10.25", "100.00", "1000.5", "-3.75"])
        if kind == "WIDE":
            return r.choice(["12345678901234567890.5", "-99999999999999999999.99", "0.0000000000000000001",
                             "CAST(1 AS DECIMAL(20,0))", "CAST('-2.5' AS DECIMAL(30,10))", "100000000000000000000.",
                             "CAST('99999999999999999999999999999999999999' AS DECIMAL(38,0))"])
        if kind == "FLOAT64":
            return r.choice(["0.5e0", "100.0e0", "-1.25e0"])
        if kind == "STRING":
            return r.choice(["'consumer'", "'approved'", "'books'", "'US'", "'india'", "'a'", "''"])
        if kind == "BOOLEAN":
            return r.choice(["TRUE", "FALSE", "NULL"])
        if kind == "DATE":
            return r.choice(["DATE '2023-06-01'", "DATE '2022-01-15'"])
        if kind == "TIMESTAMP":
            return r.choice(["TIMESTAMP '2023-06-01 00:00:00'", "TIMESTAMP '2024-01-01 12:00:00'"])
        return "NULL"

    def pred(self, scope, depth=0):
        r = self.r
        if depth > 2:
            kind = r.choice(["INT64", "DEC", "STRING"])
            return f"{self.expr(scope, kind, 3)} {r.choice(['=', '<', '>=', '<>'])} {self.literal(kind)}"
        choice = r.randint(0, 11)
        wide = any(t.startswith("wd") for _, t in scope)
        kind = r.choice(["INT64", "DEC", "FLOAT64", "STRING", "DATE", "TIMESTAMP", "BOOLEAN"]
                        + (["WIDE", "WIDE", "WIDE"] if wide else []))
        if choice <= 3:
            a = self.expr(scope, kind, depth + 1)
            other = kind
            if kind in ("WIDE", "DEC", "INT64") and wide:
                other = r.choice(["WIDE", "DEC", "INT64", "FLOAT64"])  # exact comparisons across types
            b = self.expr(scope, other, depth + 1) if r.random() < 0.4 else self.literal(other)
            if kind == "BOOLEAN":
                return f"({a} = {b})"
            return f"{a} {r.choice(['=', '<', '<=', '>', '>=', '<>'])} {b}"
        if choice == 4:
            return f"({self.pred(scope, depth + 1)} AND {self.pred(scope, depth + 1)})"
        if choice == 5:
            return f"({self.pred(scope, depth + 1)} OR {self.pred(scope, depth + 1)})"
        if choice == 6:
            return f"NOT ({self.pred(scope, depth + 1)})"
        if choice == 7:
            return f"{self.expr(scope, kind, depth + 1)} IS {r.choice(['', 'NOT '])}NULL"
        if choice == 8:
            k = r.choice(["INT64", "STRING", "DEC"] + (["WIDE"] if wide else []))
            items = ", ".join(self.literal(k) for _ in range(r.randint(1, 4)))
            if r.random() < 0.2:
                items += ", NULL"
            return f"{self.expr(scope, k, depth + 1)} {r.choice(['', 'NOT '])}IN ({items})"
        if choice == 9:
            k = r.choice(["INT64", "DEC", "DATE"] + (["WIDE"] if wide else []))
            lo, hi = (r.choice(["DEC", "INT64", "WIDE"]) for _ in range(2)) if k == "WIDE" else (k, k)
            return (f"{self.expr(scope, k, depth + 1)} {r.choice(['', 'NOT '])}BETWEEN {self.literal(lo)} "
                    f"AND {self.literal(hi)}")
        if choice == 10:
            s = self.expr(scope, "STRING", depth + 1)
            return f"{s} {r.choice(['', 'NOT '])}LIKE '{r.choice(['%a%', 'c%', '_o%', '%', '%s'])}'"
        a = self.expr(scope, "INT64", depth + 1)
        return f"({a} / ({self.expr(scope, 'INT64', depth + 1)} - 2)) > 0"

    def failing(self, scope):
        """A predicate that raises an error on some rows (division by zero, overflow)."""
        r = self.r
        a = r.choice([c for al, t in scope for c in self.cols(al, t, "INT64")])
        b = r.choice([c for al, t in scope for c in self.cols(al, t, "INT64")])
        return r.choice([f"({a} / ({b} - {r.randint(0, 3)})) >= 0",
                         f"({a} * 4611686018427387) > 0",
                         f"{a} % ({b} - {r.randint(1, 2)}) = 0"])

    def from_clause(self):
        r = self.r
        c = r.randint(0, 20)
        if c >= 15:
            return self.wide_from()
        if c == 12:
            extra = self.failing([("i", "items")])
            return (f"orders o JOIN items i ON o.order_id = i.order_id AND {extra}",
                    [("o", "orders"), ("i", "items")], True, None)
        if c == 13:
            preds = [self.pred([("c", "cust"), ("o", "orders")], 2), "c.customer_id = o.customer_id",
                     self.failing([("c", "cust"), ("o", "orders")])]
            r.shuffle(preds)
            return ("cust c, orders o", [("c", "cust"), ("o", "orders")], True, " AND ".join(preds))
        if c == 14:
            preds = ["p.product_id = i.product_id", self.pred([("p", "products")], 2),
                     self.failing([("p", "products"), ("i", "items")])]
            r.shuffle(preds)
            return ("products p, items i", [("p", "products"), ("i", "items")], True, " AND ".join(preds))
        if c == 10:
            return ("items i JOIN products p ON p.product_id = i.product_id JOIN orders o ON i.order_id = o.order_id",
                    [("i", "items"), ("p", "products"), ("o", "orders")], True, None)
        if c == 11:
            return ("tx t JOIN cust c ON t.customer_id = c.customer_id JOIN orders o ON o.customer_id = c.customer_id"
                    " AND o.order_id < 60", [("t", "tx"), ("c", "cust"), ("o", "orders")], True, None)
        if c <= 3:
            t = r.choice(["tx", "cust", "nh", "sk", "tx_p", "nh_p", "items_r", "products"])
            return f"{t} a", [("a", t)], False, None
        if c <= 6:
            kind = r.choice(["JOIN", "LEFT JOIN"])
            extra = f" AND {self.pred([('i', 'items')], 2)}" if r.random() < 0.4 else ""
            return (f"orders o {kind} items i ON o.order_id = i.order_id{extra}", [("o", "orders"), ("i", "items")],
                    True, None)
        if c == 7:
            return ("orders o JOIN items i ON i.order_id = o.order_id JOIN products p ON p.product_id = i.product_id",
                    [("o", "orders"), ("i", "items"), ("p", "products")], True, None)
        if c == 8:
            kind = r.choice(["JOIN", "LEFT JOIN"])
            return (f"tx t {kind} cust c ON c.customer_id = t.customer_id", [("t", "tx"), ("c", "cust")], True, None)
        return ("tx_p t JOIN cust c ON t.customer_id = c.customer_id AND c.segment <> 'enterprise'",
                [("t", "tx_p"), ("c", "cust")], True, None)

    def wide_from(self):
        """FROM clauses over the wide table: scans (PQCF v2 / indexed) and joins on wide or mixed keys."""
        r = self.r
        c = r.randint(0, 6)
        if c <= 2:
            t = r.choice(["wd", "wd_p"])
            return f"{t} a", [("a", t)], False, None
        on = r.choice(["a.w2 = b.n1", "a.w3 = b.i", "a.w1 = b.w1", "a.w1 = b.w2", "a.i = b.n1", "a.w3 = b.w2",
                       "a.w1 = b.w1 AND a.g = b.g", "a.n1 = b.w1"])
        if c <= 4:
            kind = r.choice(["JOIN", "LEFT JOIN"])
            return (f"wd a {kind} wd_p b ON {on}", [("a", "wd"), ("b", "wd_p")], True, None)
        if c == 5:
            return ("wd a JOIN items i ON a.i = i.order_id", [("a", "wd"), ("i", "items")], True, None)
        return ("wd_p a JOIN products p ON a.n1 = p.price OR a.w2 = p.price",
                [("a", "wd_p"), ("p", "products")], True, None)

    def query(self):
        r = self.r
        frm, scope, join, required = self.from_clause()
        where = f" WHERE {self.pred(scope)}" if r.random() < 0.7 else ""
        if required:
            where = f" WHERE {required}" + (f" AND {self.pred(scope)}" if where else "")
        shape = r.randint(0, 11)
        if self.shape is not None:
            shape = self.shape
        if shape >= 10:
            return self.union_all(frm, scope, join, where)
        if shape <= 3:
            n = r.randint(1, 3)
            wide = ["WIDE", "WIDE"] if any(t.startswith("wd") for _, t in scope) else []
            items = [f"{self.expr(scope, r.choice(['INT64', 'DEC', 'STRING', 'FLOAT64', 'DATE'] + wide))} AS c{i}"
                     for i in range(n)]
            distinct = "DISTINCT " if r.random() < 0.2 else ""
            order = ""
            ordered = False
            limit = ""
            if r.random() < 0.5:
                order = " ORDER BY " + ", ".join(f"{i + 1}{r.choice(['', ' DESC'])}" for i in range(n))
                ordered = True
                if r.random() < 0.6:
                    limit = f" LIMIT {r.randint(0, 20)}" + (f" OFFSET {r.randint(0, 5)}" if r.random() < 0.3 else "")
            elif r.random() < 0.3:
                limit = f" LIMIT {r.randint(0, 20)}"
            q = f"SELECT {distinct}{', '.join(items)} FROM {frm}{where}{order}{limit}"
            return q, ordered, bool(limit) and not order, join
        if shape <= 7:
            wide = any(t.startswith("wd") for _, t in scope)
            keys = [self.expr(scope, r.choice(["INT64", "STRING", "DATE", "DEC", "BOOLEAN"] + (["WIDE"] * 3 if wide else [])), 2)
                    for _ in range(r.randint(0, 2))]
            wide_aggs = [f"SUM({self.expr(scope, 'WIDE', 2)})", f"AVG({self.expr(scope, 'WIDE', 2)})",
                         f"MIN({self.expr(scope, 'WIDE', 2)})", f"MAX({self.expr(scope, 'WIDE', 1)})",
                         f"COUNT(DISTINCT {self.expr(scope, 'WIDE', 2)})", f"SUM(DISTINCT {self.expr(scope, 'WIDE', 1)})",
                         f"SUM(CAST({self.expr(scope, 'DEC', 2)} AS DECIMAL(38,2)))"] if wide else []
            aggs = r.sample(wide_aggs + [f"COUNT(*)", f"SUM({self.expr(scope, 'INT64', 2)})",
                             f"SUM({self.expr(scope, 'DEC', 2)})", f"MIN({self.expr(scope, 'STRING', 2)})",
                             f"MAX({self.expr(scope, 'DATE', 1)})", f"AVG({self.expr(scope, 'DEC', 2)})",
                             f"COUNT({self.expr(scope, 'INT64', 2)})", f"COUNT(DISTINCT {self.expr(scope, 'STRING', 2)})",
                             f"SUM({self.expr(scope, 'FLOAT64', 2)})", f"MIN({self.expr(scope, 'FLOAT64', 2)})"],
                            r.randint(1, 4))
            sel = ", ".join([f"{k} AS k{i}" for i, k in enumerate(keys)] + [f"{a} AS a{i}" for i, a in enumerate(aggs)])
            group = (" GROUP BY " + ", ".join(str(i + 1) for i in range(len(keys)))) if keys else ""
            having = f" HAVING COUNT(*) > {r.randint(0, 5)}" if keys and r.random() < 0.3 else ""
            return f"SELECT {sel} FROM {frm}{where}{group}{having}", False, False, join
        if shape == 8:
            a, t = scope[0]
            sub_t = r.choice(["items", "orders", "tx"])
            sub_col = {"items": "order_id", "orders": "customer_id", "tx": "customer_id"}[sub_t]
            col = self.r.choice(self.cols(a, t, "INT64"))
            sub = f"SELECT x.{sub_col} FROM {sub_t} x WHERE {self.pred([('x', sub_t)], 2)}"
            strs = self.cols(a, t, "STRING")
            # uncorrelated subqueries (evaluated once per query, also by parallel workers), some failing
            p = r.choice([f"{col} IN ({sub})", f"{col} NOT IN ({sub})",
                          f"EXISTS (SELECT 1 FROM {sub_t} x WHERE x.{sub_col} = {col})",
                          f"{col} > (SELECT AVG(x.{sub_col}) FROM {sub_t} x)",
                          f"{col} IN (SELECT x.{sub_col} FROM {sub_t} x WHERE {self.failing([('x', sub_t)])})",
                          f"{col} NOT IN (SELECT x.{sub_col} / (x.{sub_col} - {r.randint(0, 3)}) FROM {sub_t} x)",
                          f"{col} < (SELECT MAX(x.{sub_col}) / {r.randint(0, 1)} FROM {sub_t} x)",
                          f"({self.pred(scope, 2)}) AND {col} IN ({sub})",
                          f"({self.pred(scope, 2)}) OR {col} NOT IN ({sub})",
                          f"{col} IN (SELECT CAST(x.{sub_col} AS DECIMAL(10,2)) / 2 FROM {sub_t} x)",
                          f"NOT EXISTS (SELECT 1 FROM {sub_t} x WHERE {self.pred([('x', sub_t)], 2)})",
                          (f"{strs[0]} IN (SELECT x.status FROM orders x WHERE {self.pred([('x', 'orders')], 2)})"
                           if strs else f"{col} IN ({sub})")])
            if r.random() < 0.3:
                extra = r.choice([f"(SELECT COUNT(*) FROM {sub_t} x WHERE {self.pred([('x', sub_t)], 2)})",
                                  f"{col} IN ({sub})", f"{col} + (SELECT MIN(x.{sub_col}) FROM {sub_t} x)"])
                return (f"SELECT {col} AS v, {extra} AS e FROM {frm}" + (f" WHERE {p}" if r.random() < 0.5 else ""),
                        False, False, join)
            return f"SELECT {col} AS v, {self.expr(scope, 'STRING')} AS s FROM {frm} WHERE {p}", False, False, join
        # derived table + aggregation on top
        inner = f"SELECT {self.expr(scope, 'INT64')} AS x, {self.expr(scope, 'STRING')} AS y FROM {frm}{where}"
        return f"SELECT y, COUNT(*), SUM(x), MAX(x) FROM ({inner}) d GROUP BY y", False, False, join


    def union_all(self, frm, scope, join, where):
        """UNION ALL (CR-1) of 2-3 branches with mixed numeric types, optionally ordered/limited or aggregated."""
        r = self.r
        kinds = [r.choice([("INT64", "DEC"), ("DEC", "FLOAT64"), ("INT64", "INT64"), ("STRING", "STRING"),
                           ("DATE", "DATE")]) for _ in range(r.randint(1, 2))]
        branches = [f"SELECT {', '.join(f'{self.expr(scope, k[0])} AS c{i}' for i, k in enumerate(kinds))} "
                    f"FROM {frm}{where}"]
        for _ in range(r.randint(1, 2)):
            frm2, scope2, join2, required2 = self.from_clause()
            join = join or join2
            where2 = f" WHERE {required2}" if required2 else (f" WHERE {self.pred(scope2)}" if r.random() < 0.6 else "")
            items = ["NULL" if r.random() < 0.1 else self.expr(scope2, k[1]) for k in kinds]
            distinct = "DISTINCT " if r.random() < 0.15 else ""
            branches.append(f"SELECT {distinct}{', '.join(items)} FROM {frm2}{where2}")
        q = " UNION ALL ".join(branches)
        if r.random() < 0.3:
            return f"SELECT c0, COUNT(*) FROM ({q}) u GROUP BY c0", False, False, join
        if r.random() < 0.5:
            order = " ORDER BY " + ", ".join(f"{i + 1}{r.choice(['', ' DESC'])}" for i in range(len(kinds)))
            limit = f" LIMIT {r.randint(0, 20)}" if r.random() < 0.5 else ""
            # every output column is a sort key: the order (and a LIMITed prefix) is deterministic
            return q + order + limit, True, False, join
        return q, False, False, join

def canon(resp, ordered):
    if not resp.get("ok"):
        return ("error", resp["error"]["code"])
    rows = [tuple(row) for row in resp["rows"]]
    if not ordered:
        rows.sort(key=lambda r: [("%.5g" % v) if isinstance(v, float) else json.dumps(v) for v in r]
                  + [json.dumps(v) for v in r])
    return ("ok", [c["type"] for c in resp["columns"]], rows)


def close(a, b):
    """Results equal with FLOAT64 tolerance |a-b| <= 1e-9 * max(1, |a|, |b|)."""
    if a[0] != b[0] or a[0] == "error":
        return a == b
    if a[1] != b[1] or len(a[2]) != len(b[2]):
        return False
    for ra, rb in zip(a[2], b[2]):
        for x, y in zip(ra, rb):
            if isinstance(x, float) and isinstance(y, float):
                if abs(x - y) > 1e-9 * max(1.0, abs(x), abs(y)):
                    return False
            elif x != y:
                return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--queries", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--quick", action="store_true", help="only the runner's mode matrix")
    ap.add_argument("--shape", type=int, help="generate only query shape N (e.g. 8: subqueries)")
    ap.add_argument("--native-kernels", metavar="LIB", help="also run vectorized combinations with native: true")
    args = ap.parse_args()
    variants = ["", "-Dpolyquery.batchSize=7 -Dpolyquery.morselRows=40 -Dpolyquery.parallelBuildRows=16"]
    engines = [Engine(args.engine, args.data, v, args.native_kernels) for v in variants]
    schemas = None
    for e in engines:
        schemas = setup(e, args.data)
    combos = [dict(mode=m, join=j, threads=t, optimize=o) for m, j, t, o in
              itertools.product(["row", "vectorized"], ["hash", "merge", "nested_loop", "auto"], [1, 4], [True, False])]
    if args.quick:
        combos = combos[::5]
    if args.native_kernels:
        combos += [dict(c, native=True) for c in combos if c["mode"] == "vectorized"]
    gen = Gen(random.Random(args.seed), schemas)
    gen.shape = args.shape
    failures = 0
    outcomes = {}
    for qi in range(args.queries):
        sql, ordered, count_only, join = gen.query()
        base = canon(engines[0].req({"op": "query", "sql": sql, "options": dict(mode="row", join="hash", threads=1,
                                                                                 optimize=False)}), ordered)
        key = base[1] if base[0] == "error" else ("rows" if base[2] else "empty")
        outcomes[key] = outcomes.get(key, 0) + 1
        for ei, e in enumerate(engines):
            for c in combos:
                got = canon(e.req({"op": "query", "sql": sql, "options": c}), ordered)
                same = close(got, base)
                if not same and count_only and got[0] == base[0] == "ok":
                    same = len(got[2]) == len(base[2])
                if not same and join and got[0] == base[0] == "error":
                    # several failing rows: which fails first depends on the join output order
                    # (left-major for nested loops, right-major for a hash join built on the left)
                    same = True
                if not same and count_only and join and "error" in (got[0], base[0]):
                    # LIMIT without ORDER BY over a join: which rows (and so which errors) are
                    # reached first depends on the join algorithm's output order
                    same = True
                if not same:
                    failures += 1
                    print(f"MISMATCH q{qi} engine{ei} {c}\n  {sql}\n  base={str(base)[:300]}\n  got ={str(got)[:300]}")
                    break
            else:
                continue
            break
    for e in engines:
        e.close()
    print(f"{args.queries} queries, {failures} mismatches; baseline outcomes: {outcomes}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
