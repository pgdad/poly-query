#!/usr/bin/env python3
"""Differential fuzzer for the Phase 5 option matrix.

Generates random typed SQL expressions, predicates, aggregations, joins and
sorts over the conformance generator fixtures and checks that every
combination of mode × join × threads × optimize returns the same result (or
the same error code) as the row-mode baseline.

usage: fuzz.py [--seed N] [--queries N]     (run from anywhere)
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE.parent / "bin" / "polyquery"
CONFORMANCE = HERE.parent.parent.parent / "tests" / "conformance"

CONFIGS = [
    {"mode": "row", "join": "hash", "threads": 1, "optimize": False},
    {"mode": "row", "join": "nested_loop", "threads": 1, "optimize": False},
    {"mode": "row", "join": "merge", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "hash", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "merge", "threads": 1, "optimize": False},
    {"mode": "vectorized", "join": "nested_loop", "threads": 4, "optimize": True},
    {},
]

TABLES = {
    "tx": ("transactions", {"int": ["tx_id", "customer_id", "merchant_id", "bucket"], "dec": ["amount", "fee"],
                            "str": ["currency", "category", "status"], "ts": ["ts"], "bool": ["is_fraud"],
                            "float": [], "date": []}),
    "nh": ("nulls_heavy", {"int": ["id", "n50", "n90"], "dec": [], "str": ["s70"], "float": ["f95"],
                           "bool": ["b60"], "date": ["d99"], "ts": []}),
}


class Gen:
    def __init__(self, rnd: random.Random, cols: dict, prefix: str = ""):
        self.r = rnd
        self.cols = cols
        self.p = prefix

    def col(self, t):
        cs = self.cols.get(t) or []
        return self.p + self.r.choice(cs) if cs else None

    def expr(self, t, d=0):
        r = self.r
        leaf = d >= 3 or r.random() < 0.3
        c = self.col(t)
        if leaf:
            if c and r.random() < 0.75:
                return c
            return self.lit(t)
        k = r.randrange(8)
        if t == "int":
            ops = [lambda: f"({self.expr('int', d+1)} {r.choice(['+', '-', '*', '/', '%'])} {self.expr('int', d+1)})",
                   lambda: f"ABS({self.expr('int', d+1)})",
                   lambda: f"CASE WHEN {self.pred(d+1)} THEN {self.expr('int', d+1)} ELSE {self.expr('int', d+1)} END",
                   lambda: f"COALESCE({self.expr('int', d+1)}, {self.expr('int', d+1)})",
                   lambda: f"NULLIF({self.expr('int', d+1)}, {r.randint(0, 5)})",
                   lambda: f"-{self.expr('int', d+1)}",
                   lambda: f"LENGTH({self.expr('str', d+1)})",
                   lambda: (f"CAST({self.expr('dec', d+1)} AS INT64)" if self.cols['dec'] else f"({self.expr('int', d+1)} + 1)")]
            return ops[k]()
        if t == "dec":
            ops = [lambda: f"({self.expr('dec', d+1)} {r.choice(['+', '-'])} {self.expr('dec', d+1)})",
                   lambda: f"({self.expr('dec', d+1)} * {r.randint(-3, 9)})",
                   lambda: f"ABS({self.expr('dec', d+1)})",
                   lambda: f"ROUND({self.expr('dec', d+1)}, 1)",
                   lambda: f"CASE WHEN {self.pred(d+1)} THEN {self.expr('dec', d+1)} END",
                   lambda: f"COALESCE({self.expr('dec', d+1)}, 0.5)",
                   lambda: f"CAST({self.expr('int', d+1)} AS DECIMAL(12,2))",
                   lambda: f"({self.expr('dec', d+1)} + {self.expr('int', d+1)})"]
            return ops[k]()
        if t == "float":
            ops = [lambda: f"({self.expr('float', d+1)} {r.choice(['+', '-', '*', '/'])} {self.expr('float', d+1)})",
                   lambda: f"CAST({self.expr('int', d+1)} AS FLOAT64)",
                   lambda: f"ABS({self.expr('float', d+1)})",
                   lambda: f"SQRT(ABS({self.expr('float', d+1)}))",
                   lambda: f"COALESCE({self.expr('float', d+1)}, 1.5)",
                   lambda: f"({self.expr('int', d+1)} / 2.5)",
                   lambda: f"CASE WHEN {self.pred(d+1)} THEN {self.expr('float', d+1)} ELSE -1.0 END",
                   lambda: f"ROUND({self.expr('float', d+1)}, 2)"]
            return ops[k]()
        if t == "str":
            ops = [lambda: f"UPPER({self.expr('str', d+1)})",
                   lambda: f"LOWER({self.expr('str', d+1)})",
                   lambda: f"SUBSTR({self.expr('str', d+1)}, {r.randint(1, 3)}, {r.randint(1, 4)})",
                   lambda: f"({self.expr('str', d+1)} || {self.expr('str', d+1)})",
                   lambda: f"COALESCE({self.expr('str', d+1)}, 'zz')",
                   lambda: f"CASE WHEN {self.pred(d+1)} THEN {self.expr('str', d+1)} ELSE 'other' END",
                   lambda: f"TRIM({self.expr('str', d+1)})",
                   lambda: f"CAST({self.expr('int', d+1)} AS STRING)"]
            return ops[k]()
        if t == "bool":
            return self.pred(d)
        return c or self.lit(t)

    def lit(self, t):
        r = self.r
        if r.random() < 0.05:
            return "NULL"
        return {"int": lambda: str(r.randint(-3, 60)),
                "dec": lambda: f"{r.randint(-50, 900)}.{r.randint(0, 99):02d}",
                "float": lambda: f"{r.uniform(-50, 50):.2f}",
                "str": lambda: "'" + r.choice(["a", "EUR", "approved", "groceries", "india", "", "x y"]) + "'",
                "bool": lambda: r.choice(["TRUE", "FALSE"]),
                "ts": lambda: "TIMESTAMP '2023-01-0%d 12:00:00'" % r.randint(1, 9),
                "date": lambda: "DATE '2023-0%d-15'" % r.randint(1, 9)}[t]()

    def types(self):
        return [t for t, cs in self.cols.items() if cs]

    def pred(self, d=0):
        r = self.r
        if d >= 3 or r.random() < 0.35:
            t = r.choice(self.types())
            k = r.randrange(6)
            x = self.expr(t, d + 1) if t in ("int", "dec", "float", "str") else (self.col(t) or self.lit(t))
            if t == "bool":
                return r.choice([x, f"{x} IS NULL", f"NOT {x}", f"({x} = TRUE)"])
            if k == 0:
                return f"{x} IS {'NOT ' if r.random() < 0.5 else ''}NULL"
            if k == 1 and t in ("int", "dec", "str", "float"):
                items = ", ".join(self.lit(t) for _ in range(r.randint(1, 4)))
                return f"{x} {'NOT ' if r.random() < 0.3 else ''}IN ({items})"
            if k == 2 and t == "str":
                return f"{x} {'NOT ' if r.random() < 0.3 else ''}LIKE '{r.choice(['%a%', 'g%', '_a%', '%', 'e_r'])}'"
            if k == 3 and t in ("int", "dec", "float", "ts", "date"):
                return f"{x} {'NOT ' if r.random() < 0.3 else ''}BETWEEN {self.lit(t)} AND {self.lit(t)}"
            y = self.expr(t, d + 1) if (t in ("int", "dec", "float", "str") and r.random() < 0.4) else self.lit(t)
            return f"{x} {r.choice(['=', '<>', '<', '<=', '>', '>='])} {y}"
        k = r.randrange(3)
        if k == 0:
            return f"({self.pred(d+1)} AND {self.pred(d+1)})"
        if k == 1:
            return f"({self.pred(d+1)} OR {self.pred(d+1)})"
        return f"NOT ({self.pred(d+1)})"


def query(rnd: random.Random) -> tuple[str, bool]:
    tname = rnd.choice(list(TABLES))
    cols = TABLES[tname][1]
    g = Gen(rnd, cols)
    pk = "tx_id" if tname == "tx" else "id"
    k = rnd.randrange(6)
    types = g.types()
    if k == 0:
        sel = ", ".join(g.expr(rnd.choice(types)) for _ in range(rnd.randint(1, 3)))
        return f"SELECT {pk}, {sel} FROM {tname} WHERE {g.pred()}", False
    if k == 1:
        key = g.expr(rnd.choice(["int", "str"] if cols["str"] else ["int"]), 2)
        aggs = [f"COUNT(*)", f"SUM({g.expr('int', 2)})", f"MIN({g.expr('str', 2)})" if cols["str"] else "MIN(1)",
                f"MAX({g.expr(rnd.choice(types), 2)})", f"COUNT(DISTINCT {g.expr('int', 2)})"]
        if cols["dec"]:
            aggs.append(f"AVG({g.expr('dec', 2)})")
        if cols["float"]:
            aggs.append(f"SUM({g.expr('float', 2)})")
        return f"SELECT {key} AS k, {', '.join(rnd.sample(aggs, 3))} FROM {tname} WHERE {g.pred()} GROUP BY {key}", False
    if k == 2:
        e1 = g.expr(rnd.choice(types))
        e2 = g.expr(rnd.choice(types))
        lim = f" LIMIT {rnd.randint(0, 50)}" if rnd.random() < 0.7 else ""
        off = f" OFFSET {rnd.randint(0, 20)}" if lim and rnd.random() < 0.3 else ""
        d1 = rnd.choice(["", " DESC", " NULLS FIRST", " DESC NULLS LAST"])
        return f"SELECT {e1} AS a, {e2} AS b, {pk} FROM {tname} WHERE {g.pred()} ORDER BY a{d1}, b, {pk}{lim}{off}", True
    if k == 3:
        return f"SELECT DISTINCT {g.expr(rnd.choice(types), 2)} FROM {tname} WHERE {g.pred()}", False
    # joins
    gt = Gen(rnd, TABLES["tx"][1], "t.")
    gn = Gen(rnd, TABLES["nh"][1], "n.")
    jt = rnd.choice(["JOIN", "LEFT JOIN"])
    on = rnd.choice(["n.id = t.bucket", "n.n50 = t.customer_id", "n.id = t.tx_id AND n.n90 IS NOT NULL",
                     "n.id = t.merchant_id % 100"])
    if rnd.random() < 0.4:
        on += f" AND {gn.pred(2)}"
    if k == 4:
        return f"SELECT t.tx_id, n.id, {gn.expr(rnd.choice(gn.types()), 2)} FROM tx t {jt} nh n ON {on} WHERE {gt.pred(1)}", False
    return (f"SELECT t.status, COUNT(*), SUM(n.n50), MAX(n.s70) FROM tx t {jt} nh n ON {on} "
            f"WHERE {gt.pred(2)} GROUP BY t.status"), False


def norm(v):
    return f"{v:.6g}" if isinstance(v, float) else json.dumps(v)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--queries", type=int, default=300)
    args = ap.parse_args()
    env = dict(os.environ, PQ_STRICT_EXECUTION="1")
    p = subprocess.Popen([str(LAUNCHER), "session", "--data-dir", str(CONFORMANCE)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True, env=env)

    def req(r):
        p.stdin.write(json.dumps(r) + "\n")
        p.stdin.flush()
        return json.loads(p.stdout.readline())

    for t, (f, _) in TABLES.items():
        schema = json.loads((CONFORMANCE / "fixtures" / "gen" / f"{f}.schema.json").read_text())
        assert req({"op": "load", "table": t, "path": f"fixtures/gen/{f}.csv", "format": "csv", "schema": schema})["ok"]
    rnd = random.Random(args.seed)
    bad = 0
    kinds = {}
    for i in range(args.queries):
        sql, ordered = query(rnd)
        results = []
        for c in CONFIGS:
            r = req({"op": "query", "sql": sql, "options": c})
            if not r.get("ok"):
                results.append("error " + r["error"]["code"])
                continue
            rows = ["|".join(norm(v) for v in row) for row in r["rows"]]
            results.append(rows if ordered else sorted(rows))
        k = results[0] if isinstance(results[0], str) else ("ok" if results[0] else "ok-empty")
        kinds[k] = kinds.get(k, 0) + 1
        if any(x != results[0] for x in results[1:]):
            bad += 1
            print(f"MISMATCH #{i}: {sql}")
            for c, x in zip(CONFIGS, results):
                print(f"   {json.dumps(c)}: {x if isinstance(x, str) else str(len(x)) + ' rows ' + str(x[:3])}")
    p.stdin.close()
    p.wait()
    print(f"{args.queries} queries, {bad} mismatches; outcomes {kinds}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
