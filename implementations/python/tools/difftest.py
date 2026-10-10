"""Differential tester for the Phase 5 option matrix.

Generates random queries over small random tables and checks that every
combination of ``mode`` × ``join`` × ``threads`` × ``optimize`` (plus
parallel pipelines forced into worker processes) returns the same result
(as a multiset; floats compared to 9 significant digits) or the same error
code as the baseline (``mode: row``, ``optimize: false``).

    python3 tools/difftest.py [--seed N] [--queries N] [--verbose]
"""

from __future__ import annotations

import argparse
import itertools
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from polyquery import errors  # noqa: E402
from polyquery.datatypes import parse_type  # noqa: E402
from polyquery.service import Engine, EngineConfig, QueryOptions, StorageOptions  # noqa: E402
from polyquery.storage.catalog import Column  # noqa: E402

COMBOS = [
    {"mode": mode, "join": join, "threads": threads, "optimize": optimize}
    for mode, join, threads, optimize in itertools.product(
        ("row", "vectorized"), ("auto", "hash", "merge", "nested_loop"), (1, 4), (True, False)
    )
]


def _csv_value(v: object) -> str:
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    return str(v)


def make_tables(rng: random.Random) -> dict[str, tuple[list[tuple[str, str]], list[list[object]]]]:
    def maybe(v: object, p: float = 0.15) -> object:
        return None if rng.random() < p else v

    t1 = []
    for i in range(1, 61):
        t1.append([
            i,
            maybe(rng.randint(-5, 9)),
            maybe(f"{rng.randint(-9999, 9999) / 100:.2f}"),
            maybe(round(rng.uniform(-50, 50), 3)),
            maybe(rng.choice(["ab", "abc", "b", "xyz", "", "Ab"])),
            maybe(f"2024-0{rng.randint(1, 9)}-1{rng.randint(0, 9)}"),
            maybe(rng.choice([True, False])),
        ])
    t2 = []
    for i in range(1, 81):
        t2.append([i, maybe(rng.randint(1, 70)), rng.randint(0, 4), maybe(rng.choice(["ab", "b", "q"]))])
    t3 = [[k, rng.choice(["one", "two", "three"])] for k in range(-2, 9)]
    return {
        "t1": ([("id", "INT64"), ("a", "INT64"), ("b", "DECIMAL(10,2)"), ("c", "FLOAT64"),
                ("s", "STRING"), ("d", "DATE"), ("f", "BOOLEAN")], t1),
        "t2": ([("id", "INT64"), ("t1_id", "INT64"), ("x", "INT64"), ("s", "STRING")], t2),
        "t3": ([("k", "INT64"), ("v", "STRING")], t3),
    }


class QueryGen:
    """Random queries over t1 (alias r: row layout copy), t2 and t3."""

    NUM = {"t1": ["id", "a", "b", "c"], "t2": ["id", "t1_id", "x"], "t3": ["k"]}
    STR = {"t1": ["s"], "t2": ["s"], "t3": ["v"]}

    def __init__(self, rng: random.Random):
        self.rng = rng

    def pick(self, seq):  # noqa: ANN001
        return self.rng.choice(seq)

    def num_expr(self, aliases: dict[str, str], depth: int = 0) -> str:
        alias = self.pick(list(aliases))
        col = f"{alias}.{self.pick(self.NUM[aliases[alias]])}"
        r = self.rng.random()
        if depth > 1 or r < 0.45:
            return col
        if r < 0.65:
            return f"({col} {self.pick(['+', '-', '*'])} {self.rng.randint(-3, 3)})"
        if r < 0.75:
            return f"({col} / {self.pick(['2', '3', '(' + col + ' - ' + col + ' + 1)'])})"
        if r < 0.85:
            return f"ABS({self.num_expr(aliases, depth + 1)})"
        if r < 0.92:
            return f"COALESCE({col}, {self.rng.randint(0, 5)})"
        if r < 0.93:  # errors: every option combination must report the same code
            return self.pick([f"({col} / ({col} - {col}))", f"({col} * 4611686018427387904)"])
        if r < 0.95:
            return self.pick([f"ROUND({col}, 1)", f"CAST({col} AS INT64)", f"NULLIF({col}, 1)", f"({col} % 3)"])
        if r < 0.97 and aliases[alias] == "t1":
            return f"(SELECT COUNT(*) FROM t2 z WHERE z.t1_id = {alias}.id)"
        if r < 0.98:
            return "(SELECT MAX(k) FROM t3)"
        return f"CASE WHEN {self.predicate(aliases, depth + 1)} THEN {col} ELSE {self.rng.randint(0, 9)} END"

    def str_expr(self, aliases: dict[str, str]) -> str:
        alias = self.pick(list(aliases))
        col = f"{alias}.{self.pick(self.STR[aliases[alias]])}"
        r = self.rng.random()
        if r < 0.6:
            return col
        if r < 0.75:
            return f"UPPER({col})"
        if r < 0.85:
            return f"({col} || 'z')"
        return f"SUBSTR({col}, 1, 2)"

    def predicate(self, aliases: dict[str, str], depth: int = 0) -> str:
        r = self.rng.random()
        if depth < 2 and r < 0.2:
            op = self.pick(["AND", "OR"])
            return f"({self.predicate(aliases, depth + 1)} {op} {self.predicate(aliases, depth + 1)})"
        if depth < 2 and r < 0.27:
            return f"NOT ({self.predicate(aliases, depth + 1)})"
        if r < 0.55:
            op = self.pick(["=", "<>", "<", "<=", ">", ">="])
            rhs = self.pick([str(self.rng.randint(-3, 9)), self.num_expr(aliases, 2), "1.5", "NULL"])
            return f"{self.num_expr(aliases, depth + 1)} {op} {rhs}"
        if r < 0.65:
            return f"{self.str_expr(aliases)} {self.pick(['LIKE', 'NOT LIKE'])} '{self.pick(['a%', '%b', '%b%', '_b%', 'ab'])}'"
        if r < 0.72:
            return f"{self.num_expr(aliases, 2)} IS {self.pick(['', 'NOT '])}NULL"
        if r < 0.8:
            return f"{self.num_expr(aliases, 2)} BETWEEN {self.rng.randint(-5, 2)} AND {self.rng.randint(2, 9)}"
        if r < 0.86:
            items = ", ".join(str(self.rng.randint(-2, 6)) for _ in range(3))
            return f"{self.num_expr(aliases, 2)} {self.pick(['IN', 'NOT IN'])} ({items}{self.pick(['', ', NULL'])})"
        if r < 0.88:
            return self.pick(["TRUE", "FALSE", "1 = 1", "NULL IS NULL", "1 = 0 AND 2 = 2", "1 + 1 = 2"])
        if r < 0.9 and "t1" in aliases.values():
            a = [k for k, v in aliases.items() if v == "t1"][0]
            return self.pick([f"{a}.d >= DATE '2024-05-01'", f"{a}.f", f"NOT {a}.f", f"{a}.f IS NULL",
                              f"LENGTH({a}.s) > 1", f"LOWER({a}.s) = 'ab'"])
        if r < 0.95 and "t2" not in aliases.values():
            return f"{self.num_expr(aliases, 2)} IN (SELECT x FROM t2 WHERE x > {self.rng.randint(0, 3)})"
        alias = self.pick(list(aliases))
        if aliases[alias] == "t1":
            return f"EXISTS (SELECT 1 FROM t2 z WHERE z.t1_id = {alias}.id AND z.x > {self.rng.randint(0, 3)})"
        return f"{self.str_expr(aliases)} = {self.pick(['ab', 'b', 'q', 'one'])!r}".replace('"', "'")

    def from_clause(self) -> tuple[str, dict[str, str]]:
        r = self.rng.random()
        t1 = self.pick(["t1", "r"])
        if r < 0.3:
            return f"{t1} p", {"p": "t1"}
        kind = self.pick(["JOIN", "LEFT JOIN", "JOIN", "LEFT JOIN", "CROSS JOIN"])
        cond = self.pick([
            "q.t1_id = p.id",
            "q.t1_id = p.id AND q.x > 1",
            "q.t1_id = p.a",
            "q.x = p.a AND q.s = p.s",
            "q.t1_id > p.id + 60",
            "q.s = p.s",
        ])
        two = f"{t1} p {kind} t2 q" + ("" if kind == "CROSS JOIN" else f" ON {cond}")
        aliases = {"p": "t1", "q": "t2"}
        if r < 0.75:
            return two, aliases
        kind3 = self.pick(["JOIN", "LEFT JOIN"])
        cond3 = self.pick(["w.k = q.x", "w.k = p.a", "w.k = q.x AND w.v <> 'two'"])
        aliases["w"] = "t3"
        if self.rng.random() < 0.5:
            return f"{two} {kind3} t3 w ON {cond3}", aliases
        # comma joins with the conditions in WHERE (join reordering)
        return f"{t1} p, t2 q, t3 w WHERE {cond.split(' AND ')[0]} AND {cond3.split(' AND ')[0]}", aliases

    def query(self) -> str:
        frm, aliases = self.from_clause()
        has_where = " WHERE " in frm
        where = ""
        if self.rng.random() < 0.6:
            where = (" AND " if has_where else " WHERE ") + self.predicate(aliases)
        r = self.rng.random()
        if r < 0.4:
            keys = [self.pick([self.str_expr(aliases), self.num_expr(aliases, 2)]) for _ in range(self.rng.randint(1, 2))]
            arg = self.num_expr(aliases, 1)
            aggs = [
                "COUNT(*)",
                f"SUM({arg})",
                f"MIN({self.str_expr(aliases)})",
                f"MAX({arg})",
                f"AVG({arg})",
                f"COUNT(DISTINCT {arg})",
                f"COUNT({arg})",
            ]
            items = keys + self.rng.sample(aggs, self.rng.randint(1, 4))
            having = ""
            if self.rng.random() < 0.3:
                having = f" HAVING COUNT(*) > {self.rng.randint(0, 2)}"
            sql = f"SELECT {', '.join(items)} FROM {frm}{where} GROUP BY {', '.join(keys)}{having}"
        elif r < 0.5:
            items = self.rng.sample(["COUNT(*)", f"SUM({self.num_expr(aliases, 1)})", f"MAX({self.str_expr(aliases)})"], 2)
            sql = f"SELECT {', '.join(items)} FROM {frm}{where}"
        else:
            items = [self.pick([self.num_expr(aliases), self.str_expr(aliases)]) for _ in range(self.rng.randint(1, 3))]
            distinct = "DISTINCT " if self.rng.random() < 0.15 else ""
            sql = f"SELECT {distinct}{', '.join(items)} FROM {frm}{where}"
            if self.rng.random() < 0.4:
                order = ", ".join(f"{i + 1} {self.pick(['ASC', 'DESC'])}{self.pick(['', ' NULLS FIRST', ' NULLS LAST'])}"
                                  for i in range(len(items)))
                sql += f" ORDER BY {order}"
                if self.rng.random() < 0.6:
                    sql += f" LIMIT {self.rng.randint(0, 12)}"
                    if self.rng.random() < 0.3:
                        sql += f" OFFSET {self.rng.randint(0, 5)}"
        if self.rng.random() < 0.1:
            sql = f"WITH cte AS ({sql}) SELECT * FROM cte"
        return sql


def normalize(rows: list[tuple]) -> list[tuple]:
    def norm(v: object) -> object:
        if isinstance(v, float):
            return float(f"{v:.9g}")
        return v

    return sorted((tuple(norm(v) for v in row) for row in rows), key=repr)


def run(engine: Engine, sql: str, options: dict) -> tuple[str, object]:
    try:
        result = engine.query(sql, QueryOptions(**options))
    except errors.PolyQueryError as e:
        return "error", e.code
    return "ok", normalize(result.rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--queries", type=int, default=300)
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    engines = [Engine(EngineConfig()), Engine(EngineConfig(parallel_min_rows=1))]  # 2nd: forked workers
    for engine in engines:
        for name, (schema, rows) in make_tables(random.Random(args.seed)).items():
            text = ",".join(n for n, _ in schema) + "\n" + "".join(",".join(map(_csv_value, r)) + "\n" for r in rows)
            columns = [Column(n, parse_type(t)) for n, t in schema]
            engine.load(name, "csv", text, columns, {}, False)
            if name == "t1":
                engine.load("r", "csv", text, columns, {}, False, StorageOptions(layout="row"))

    gen = QueryGen(rng)
    failures = 0
    for qi in range(args.queries):
        sql = gen.query()
        base = run(engines[0], sql, {"mode": "row", "optimize": False})
        if args.verbose:
            print(f"[{qi}] {base[0]} {sql}")
        checks = [(engines[0], c) for c in COMBOS] + [
            (engines[1], {"mode": m, "threads": 4}) for m in ("row", "vectorized")
        ]
        for engine, options in checks:
            got = run(engine, sql, options)
            if got != base:
                failures += 1
                fork = " (forked workers)" if engine is engines[1] else ""
                print(f"MISMATCH{fork} {options}\n  {sql}\n  base={str(base)[:300]}\n  got ={str(got)[:300]}")
                break
    print(f"{args.queries} queries, {failures} mismatches")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
