#!/usr/bin/env python3
"""Randomized differential testing: engine vs. SQLite oracle.

Generates random queries from a grammar restricted to constructs whose
semantics coincide between PolyQuery and SQLite (integer arithmetic without
overflow or division by zero, comparisons, three-valued logic, NULL handling,
LIKE (case-sensitive pragma), string functions, grouping/aggregation, joins,
DISTINCT, ORDER BY over all output columns). Every query's result must match.

  differential.py --engine implementations/go/bin/polyquery [--cases 500] [--seed 1] [--options '{"mode":"vectorized"}']
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/conformance"))
sys.path.insert(0, str(ROOT / "tools/validation"))

import oracle_check as oc  # noqa: E402
from engine import EngineError, SessionEngine, engine_info  # noqa: E402
from pqt import rows_match  # noqa: E402

FIX = ROOT / "tests/conformance/fixtures"

TABLES = {
    "people": ("fixtures/people.csv", None, {"id": "i", "name": "s", "age": "i", "city": "s", "active": "b"}),
    "customers": ("fixtures/customers.csv", None, {"customer_id": "i", "name": "s", "country": "s", "tier": "s"}),
    "tx": ("fixtures/gen/transactions.csv", "fixtures/gen/transactions.schema.json",
           {"tx_id": "i", "customer_id": "i", "merchant_id": "i", "currency": "s", "category": "s",
            "status": "s", "is_fraud": "b", "bucket": "i"}),
}


class Gen:
    def __init__(self, rng: random.Random):
        self.r = rng

    def int_expr(self, cols: dict, depth: int = 0) -> str:
        r = self.r
        ints = [c for c, t in cols.items() if t == "i"]
        choice = r.random()
        if depth > 2 or choice < 0.35:
            return r.choice(ints) if ints and r.random() < 0.7 else str(r.randint(-20, 50))
        if choice < 0.75:
            op = r.choice(["+", "-", "*"])
            return f"({self.int_expr(cols, depth + 1)} {op} {self.int_expr(cols, depth + 1)})"
        if choice < 0.85:
            return f"({self.int_expr(cols, depth + 1)} {r.choice(['/', '%'])} {r.randint(1, 9)})"
        if choice < 0.93:
            strs = [c for c, t in cols.items() if t == "s"]
            if strs:
                return f"LENGTH({r.choice(strs)})"
        return f"COALESCE({self.int_expr(cols, depth + 1)}, {r.randint(0, 9)})"

    def str_expr(self, cols: dict) -> str:
        r = self.r
        strs = [c for c, t in cols.items() if t == "s"]
        c = r.choice(strs) if strs else "'x'"
        k = r.random()
        if k < 0.4:
            return c
        if k < 0.55:
            return f"UPPER({c})"
        if k < 0.7:
            return f"LOWER({c})"
        if k < 0.85:
            return f"SUBSTR({c}, {r.randint(1, 3)}, {r.randint(0, 4)})"
        return f"COALESCE({c}, 'none')"

    def pred(self, cols: dict, depth: int = 0) -> str:
        r = self.r
        k = r.random()
        if depth < 2 and k < 0.25:
            return f"({self.pred(cols, depth + 1)} {r.choice(['AND', 'OR'])} {self.pred(cols, depth + 1)})"
        if depth < 2 and k < 0.32:
            return f"NOT ({self.pred(cols, depth + 1)})"
        if k < 0.6:
            return f"{self.int_expr(cols)} {r.choice(['=', '<>', '<', '<=', '>', '>='])} {self.int_expr(cols)}"
        if k < 0.7:
            return f"{self.str_expr(cols)} {r.choice(['=', '<>', '<', '>='])} '{r.choice(['A', 'Helsinki', 'gold', 'EUR', 'm', ''])}'"
        if k < 0.78:
            return f"{r.choice(list(cols))} IS {r.choice(['', 'NOT '])}NULL"
        if k < 0.85:
            lo = r.randint(-5, 30)
            return f"{self.int_expr(cols)} {r.choice(['', 'NOT '])}BETWEEN {lo} AND {lo + r.randint(0, 40)}"
        if k < 0.92:
            return f"{self.int_expr(cols)} {r.choice(['', 'NOT '])}IN ({', '.join(str(r.randint(0, 40)) for _ in range(r.randint(1, 4)))})"
        strs = [c for c, t in cols.items() if t == "s"]
        if strs:
            pat = r.choice(["%a%", "A%", "_o%", "%e", "%", "__", "%i%e%"])
            return f"{r.choice(strs)} {r.choice(['', 'NOT '])}LIKE '{pat}'"
        bools = [c for c, t in cols.items() if t == "b"]
        return r.choice(bools) if bools else "TRUE"

    def query(self) -> str:
        r = self.r
        if r.random() < 0.3:
            return self.join_query()
        t = r.choice(list(TABLES))
        cols = TABLES[t][2]
        where = f" WHERE {self.pred(cols)}" if r.random() < 0.8 else ""
        if r.random() < 0.45:
            keys = [r.choice([c for c, ty in cols.items() if ty in "s"] or list(cols))]
            if r.random() < 0.4:
                keys.append(f"{self.int_expr(cols)} % 3")
            aggs = []
            ints = [c for c, ty in cols.items() if ty == "i"]
            for _ in range(r.randint(1, 3)):
                f = r.choice(["COUNT(*)", "COUNT({c})", "SUM({i})", "MIN({c})", "MAX({c})", "COUNT(DISTINCT {c})"])
                aggs.append(f.format(c=r.choice(list(cols)), i=r.choice(ints)))
            sel = [f"{k} AS k{n}" for n, k in enumerate(keys)] + [f"{a} AS a{n}" for n, a in enumerate(aggs)]
            having = f" HAVING COUNT(*) > {r.randint(0, 3)}" if r.random() < 0.3 else ""
            gb = ", ".join(keys)
            order = ", ".join(str(i + 1) for i in range(len(sel)))
            return f"SELECT {', '.join(sel)} FROM {t}{where} GROUP BY {gb}{having} ORDER BY {order}"
        items = []
        for n in range(r.randint(1, 4)):
            k = r.random()
            items.append(f"{self.int_expr(cols) if k < 0.5 else self.str_expr(cols) if k < 0.8 else r.choice(list(cols))} AS c{n}")
        distinct = "DISTINCT " if r.random() < 0.25 else ""
        order = ", ".join(str(i + 1) for i in range(len(items)))
        limit = f" LIMIT {r.randint(0, 30)}" if r.random() < 0.3 else ""
        if limit and r.random() < 0.5:
            limit += f" OFFSET {r.randint(0, 10)}"
        return f"SELECT {distinct}{', '.join(items)} FROM {t}{where} ORDER BY {order}{limit}"

    def join_query(self) -> str:
        r = self.r
        kind = r.choice(["JOIN", "LEFT JOIN"])
        cond = "c.customer_id = p.id" if r.random() < 0.7 else "c.customer_id <= p.id"
        extra = f" AND {self.pred({'p.age': 'i', 'c.customer_id': 'i'})}" if r.random() < 0.3 else ""
        where = f" WHERE {self.pred({'p.age': 'i', 'p.id': 'i', 'p.city': 's', 'c.tier': 's'})}" if r.random() < 0.5 else ""
        if r.random() < 0.5:
            return (f"SELECT p.city AS k, COUNT(c.customer_id) AS n, MAX(c.name) AS m FROM people p {kind} customers c "
                    f"ON {cond}{extra}{where} GROUP BY p.city ORDER BY 1, 2, 3")
        return (f"SELECT p.id AS a, p.name AS b, c.customer_id AS c1, c.tier AS d FROM people p {kind} customers c "
                f"ON {cond}{extra}{where} ORDER BY 1, 2, 3, 4")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--cases", type=int, default=500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--options", help="JSON query options applied to every query")
    ap.add_argument("--report")
    a = ap.parse_args()
    launcher = str(Path(a.engine).resolve())
    caps = set(engine_info(launcher)["capability_set"])
    need = {"sql.groupby", "sql.join", "sql.functions"}
    if not need <= caps:
        print(f"differential: engine lacks {sorted(need - caps)}; skipped (not_implemented)")
        return 0
    data = Path(tempfile.mkdtemp(prefix="pqdiff-"))
    (data / "fixtures").symlink_to(FIX)
    eng = SessionEngine(launcher, data, timeout=60)
    con = oc.connect()
    for t, (path, schema, _) in TABLES.items():
        req = {"op": "load", "table": t, "format": "csv", "path": path}
        if schema:
            req["schema"] = json.loads((ROOT / "tests/conformance" / schema).read_text())
        resp = eng.request(req)
        if not resp.get("ok"):
            print("load failed", resp)
            return 2
        oc.load_into(con, req, ROOT / "tests/conformance")
    gen = Gen(random.Random(a.seed))
    opts = json.loads(a.options) if a.options else None
    failures, passed, skipped = [], 0, 0
    for i in range(a.cases):
        sql = gen.query()
        try:
            exp_raw = con.execute(oc.translate(sql)).fetchall()
        except Exception as e:  # noqa: BLE001 - generator produced something sqlite rejects
            skipped += 1
            continue
        req = {"op": "query", "sql": sql}
        if opts:
            req["options"] = opts
        try:
            resp = eng.request(req)
        except EngineError as e:
            failures.append({"sql": sql, "error": f"engine failure: {e}"})
            eng = SessionEngine(launcher, data, timeout=60)
            for t, (path, schema, _) in TABLES.items():
                rq = {"op": "load", "table": t, "format": "csv", "path": path}
                if schema:
                    rq["schema"] = json.loads((ROOT / "tests/conformance" / schema).read_text())
                eng.request(rq)
            continue
        if not resp.get("ok"):
            failures.append({"sql": sql, "error": resp.get("error")})
            continue
        types = [c["type"] for c in resp["columns"]]
        try:
            exp = [[oc.from_sqlite(v, t) for v, t in zip(row, types)] for row in exp_raw]
        except ValueError as e:
            failures.append({"sql": sql, "error": f"type mismatch vs oracle: {e} (engine types {types})"})
            continue
        ok, msg = rows_match(exp, resp["rows"], types, True)
        if ok:
            passed += 1
        else:
            failures.append({"sql": sql, "error": msg})
    eng.close()
    print(f"differential: {passed} passed, {len(failures)} failed, {skipped} skipped (oracle rejected)")
    for f in failures[:15]:
        print(f"  FAIL {f['sql']}\n       {f['error']}")
    if a.report:
        Path(a.report).write_text(json.dumps({"passed": passed, "failed": len(failures), "skipped": skipped,
                                              "seed": a.seed, "failures": failures}, indent=1) + "\n")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
