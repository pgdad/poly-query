#!/usr/bin/env python3
"""Randomized differential test of the execution options (development tool).

Generates random queries over the conformance fixtures and runs each one under every
combination of mode x join x threads x optimize, in engines started with different batch and
morsel sizes; all results must equal the row-mode baseline (multiset comparison unless the
query orders all output columns; FLOAT64 with relative tolerance; errors by code).

  python3 tools/difftest.py --engine bin/polyquery --data ../../tests/conformance --queries 300 --seed 1

With --native-kernels LIB the engines load the native kernel library and every vectorized
combination also runs with `native: true`.
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


def setup(engine, data):
    schemas = {}
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
            k = "DEC" if t.startswith("DECIMAL") else t
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
        kind = r.choice(["INT64", "DEC", "FLOAT64", "STRING", "DATE", "TIMESTAMP", "BOOLEAN"])
        if choice <= 3:
            a = self.expr(scope, kind, depth + 1)
            b = self.expr(scope, kind, depth + 1) if r.random() < 0.4 else self.literal(kind)
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
            k = r.choice(["INT64", "STRING", "DEC"])
            items = ", ".join(self.literal(k) for _ in range(r.randint(1, 4)))
            if r.random() < 0.2:
                items += ", NULL"
            return f"{self.expr(scope, k, depth + 1)} {r.choice(['', 'NOT '])}IN ({items})"
        if choice == 9:
            k = r.choice(["INT64", "DEC", "DATE"])
            return (f"{self.expr(scope, k, depth + 1)} {r.choice(['', 'NOT '])}BETWEEN {self.literal(k)} "
                    f"AND {self.literal(k)}")
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
        c = r.randint(0, 14)
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

    def query(self):
        r = self.r
        frm, scope, join, required = self.from_clause()
        where = f" WHERE {self.pred(scope)}" if r.random() < 0.7 else ""
        if required:
            where = f" WHERE {required}" + (f" AND {self.pred(scope)}" if where else "")
        shape = r.randint(0, 9)
        if shape <= 3:
            n = r.randint(1, 3)
            items = [f"{self.expr(scope, r.choice(['INT64', 'DEC', 'STRING', 'FLOAT64', 'DATE']))} AS c{i}"
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
            keys = [self.expr(scope, r.choice(["INT64", "STRING", "DATE", "DEC", "BOOLEAN"]), 2)
                    for _ in range(r.randint(0, 2))]
            aggs = r.sample([f"COUNT(*)", f"SUM({self.expr(scope, 'INT64', 2)})",
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
            p = r.choice([f"{col} IN ({sub})", f"{col} NOT IN ({sub})",
                          f"EXISTS (SELECT 1 FROM {sub_t} x WHERE x.{sub_col} = {col})",
                          f"{col} > (SELECT AVG(x.{sub_col}) FROM {sub_t} x)"])
            return f"SELECT {col} AS v, {self.expr(scope, 'STRING')} AS s FROM {frm} WHERE {p}", False, False, join
        # derived table + aggregation on top
        inner = f"SELECT {self.expr(scope, 'INT64')} AS x, {self.expr(scope, 'STRING')} AS y FROM {frm}{where}"
        return f"SELECT y, COUNT(*), SUM(x), MAX(x) FROM ({inner}) d GROUP BY y", False, False, join


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
