"""Differential tester for the native kernel paths (``native: true``).

Loads tables large enough to span several kernel windows (in the column
layout from CSV, and reopened from PQCF files with small, odd row groups
and forced PLAIN / DICT / RLE encodings), generates random queries whose
filters and aggregates the kernels can (partly) compute, and checks that
every query returns exactly the same rows, in the same order, or the same
error code with ``native: true`` as without, in row and vectorized mode,
serially and with partitions (in-process and in forked workers).

    python3 tools/native_difftest.py --lib ../../native-kernels/build/x86_64/libpqkernels.so \\
        [--seed N] [--queries N] [--rows N] [--variant avx2] [--verbose]
"""

from __future__ import annotations

import argparse
import random
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from polyquery import errors  # noqa: E402
from polyquery.datatypes import parse_type  # noqa: E402
from polyquery.service import Engine, EngineConfig, QueryOptions, StorageOptions  # noqa: E402
from polyquery.storage import pqcf  # noqa: E402
from polyquery.storage.catalog import Column  # noqa: E402

SCHEMA = [
    ("id", "INT64"),
    ("a", "INT64"),
    ("big", "INT64"),
    ("dec", "DECIMAL(12,2)"),
    ("d", "DATE"),
    ("ts", "TIMESTAMP"),
    ("f", "FLOAT64"),
    ("s", "STRING"),
    ("u", "STRING"),
    ("bo", "BOOLEAN"),
]
WORDS = ["", "a", "ab", "abc", "b", "ba", "zeta", "Zulu", "é", "x y"]
OPTIONS = [
    {"mode": "vectorized"},
    {"mode": "row"},
    {"mode": "vectorized", "threads": 3},
    {"mode": "row", "threads": 4},
]


def make_csv(rng: random.Random, n: int) -> str:
    def maybe(v: str, p: float = 0.12) -> str:
        return "" if rng.random() < p else v

    lines = [",".join(name for name, _ in SCHEMA)]
    for i in range(n):
        big = rng.choice([4 * 10**18, -4 * 10**18, rng.randint(-10, 10), 9 * 10**18, -9 * 10**18])
        f = rng.choice([0.0, -0.0, rng.uniform(-100, 100), rng.uniform(-1, 1), 1e300, -1e300])
        s = rng.choice(WORDS[:6]) if i < n // 2 else rng.choice(WORDS)
        lines.append(",".join([
            str(i),
            maybe(str(rng.randint(-50, 50))),
            maybe(str(big), 0.05),
            maybe(f"{rng.randint(-99999, 99999) / 100:.2f}"),
            maybe(f"2024-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}"),
            maybe(f"2024-03-{rng.randint(1, 28):02d}T{rng.randint(0, 23):02d}:00:00"),
            maybe(repr(f)),
            maybe(s, 0.1),
            maybe(f"u{rng.randint(0, n)}", 0.05),
            maybe(rng.choice(["true", "false"])),
        ]))
    return "\n".join(lines) + "\n"


class QueryGen:
    INT_COLS = ["id", "a", "big", "dec", "d", "ts"]

    def __init__(self, rng: random.Random, n: int):
        self.rng = rng
        self.n = n

    def pick(self, seq):  # noqa: ANN001
        return self.rng.choice(seq)

    def literal(self, col: str) -> str:
        r = self.rng
        if col == "id":
            return str(r.randint(-5, self.n + 5))
        if col == "a":
            return self.pick([str(r.randint(-55, 55)), "1.5", "-0.0", "NULL", "9223372036854775807"])
        if col == "big":
            return self.pick(["0", "-4000000000000000000", "4000000000000000000", "9000000000000000000", "-1"])
        if col == "dec":
            return self.pick([f"{r.randint(-99999, 99999) / 100:.2f}", "1.005", "12", "-3.5", "99999999999.99"])
        if col == "d":
            return f"DATE '2024-{r.randint(1, 12):02d}-{r.randint(1, 28):02d}'"
        if col == "ts":
            return f"TIMESTAMP '2024-03-{r.randint(1, 28):02d}T{r.randint(0, 23):02d}:00:00'"
        if col in ("s", "u"):
            return "'" + (self.pick(WORDS) if col == "s" else f"u{r.randint(0, self.n)}") + "'"
        if col == "f":
            return self.pick(["0", "0.5", "-1.5", "1e300"])
        return self.pick(["TRUE", "FALSE"])

    def term(self) -> str:
        r = self.rng.random()
        col = self.pick(self.INT_COLS + ["s", "s", "u", "f", "bo"])
        if r < 0.5:
            op = self.pick(["=", "<>", "<", "<=", ">", ">="])
            lhs, rhs = col, self.literal(col)
            if self.rng.random() < 0.2:
                lhs, rhs = rhs, lhs
            return f"{lhs} {op} {rhs}"
        if r < 0.65:
            lo, hi = sorted([self.literal(col), self.literal(col)]) if col not in ("d", "ts") else (
                self.literal(col), self.literal(col))
            return f"{col} {self.pick(['BETWEEN', 'BETWEEN', 'NOT BETWEEN'])} {lo} AND {hi}"
        if r < 0.8:
            items = ", ".join(self.literal(col) for _ in range(self.rng.randint(1, 5)))
            if self.rng.random() < 0.2:
                items += ", NULL"
            return f"{col} {self.pick(['IN', 'IN', 'NOT IN'])} ({items})"
        if r < 0.85:
            return f"{col} IS {self.pick(['', 'NOT '])}NULL"
        if r < 0.9:  # may fail: keeps NULL rows of earlier terms in play
            return self.pick(["100 / (a - a) = 1", "a / (id - 7) >= 0", "big * 3 > 0", "CAST(u AS INT64) > 0"])
        if r < 0.95:
            return f"({self.term()} OR {self.term()})"
        return self.pick(["a + 1 > 3", "LENGTH(s) > 1", "f * 2 < 10", "bo", "NOT bo", "s LIKE 'a%'"])

    def where(self) -> str:
        return " AND ".join(self.term() for _ in range(self.rng.randint(1, 4)))

    def query(self, table: str) -> str:
        r = self.rng.random()
        if r < 0.4:
            cols = ", ".join(self.rng.sample([c for c, _ in SCHEMA], self.rng.randint(1, 4)))
            order = " ORDER BY id" if self.rng.random() < 0.3 else ""
            return f"SELECT {cols} FROM {table} WHERE {self.where()}{order}"
        aggs = []
        for _ in range(self.rng.randint(1, 5)):
            fn = self.pick(["COUNT", "SUM", "AVG", "MIN", "MAX", "COUNT(*)"])
            if fn == "COUNT(*)":
                aggs.append(fn)
                continue
            col = self.pick(["a", "big", "dec", "id"] if fn in ("SUM", "AVG") else [c for c, _ in SCHEMA])
            aggs.append(f"{fn}({self.pick(['', '', '', 'DISTINCT '])}{col})")
        where = f" WHERE {self.where()}" if self.rng.random() < 0.75 else ""
        if r < 0.6:
            return f"SELECT {', '.join(aggs)} FROM {table}{where}"
        key = self.pick(["s", "a", "bo", "d", "s, bo", "a % 3", "u", "id", "big", "dec, s", "ts"])
        if self.rng.random() < 0.5:  # only COUNT / SUM / AVG (the kernels' group sums)
            aggs = [self.pick(["COUNT(*)", "COUNT({c})", "SUM({n})", "AVG({n})"]).format(
                c=self.pick([c for c, _ in SCHEMA]), n=self.pick(["a", "big", "dec", "id"]))
                for _ in range(self.rng.randint(1, 4))]
        return f"SELECT {key}, {', '.join(aggs)} FROM {table}{where} GROUP BY {key}"


def run(engine: Engine, sql: str, options: dict) -> tuple[str, object]:
    try:
        result = engine.query(sql, QueryOptions(**options))
    except errors.PolyQueryError as e:
        return "error", e.code
    return "ok", [tuple(repr(v) for v in row) for row in result.rows]  # repr: -0.0 differs from 0.0


def load_tables(engine: Engine, text: str, tmp: Path) -> list[str]:
    columns = [Column(n, parse_type(t)) for n, t in SCHEMA]
    engine.load("t", "csv", text, columns, {}, False)
    engine.load("tr", "csv", text, columns, {}, False, StorageOptions(layout="row"))
    names = ["t", "tr"]
    for k, (encoding, size, mmap) in enumerate([("auto", 1003, False), ("plain", 4099, True), ("dict", 777, False),
                                                ("rle", 65536, True)]):
        path = tmp / f"t{k}.pqcf"
        engine.save("t", str(path), pqcf.SaveOptions(encoding=encoding, row_group_size=size))
        engine.open(f"p{k}", str(path), StorageOptions(mmap=mmap), False)
        names.append(f"p{k}")
    return names


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True, help="path of libpqkernels")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--queries", type=int, default=300)
    ap.add_argument("--rows", type=int, default=150_003)
    ap.add_argument("--variant", help="force a kernel variant (reference, x86_scalar, x86_avx2, …)")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    engines = [Engine(EngineConfig(native_kernels=args.lib)),
               Engine(EngineConfig(native_kernels=args.lib, parallel_min_rows=1))]  # 2nd: forked workers
    if engines[0].native is None:
        print("native kernels could not be loaded", file=sys.stderr)
        return 2
    if args.variant:
        for engine in engines:
            assert engine.native is not None
            if not engine.native.set_variant(args.variant):
                print(f"variant {args.variant} unavailable", file=sys.stderr)
                return 2
    print(f"kernel variant: {engines[0].native.variant}")
    text = make_csv(random.Random(args.seed), args.rows)
    with tempfile.TemporaryDirectory() as tmp:
        tables = []
        for engine in engines:
            tables = load_tables(engine, text, Path(tmp))
        gen = QueryGen(rng, args.rows)
        failures = 0
        for qi in range(args.queries):
            sql = gen.query(gen.pick(tables))
            checks = [(engines[0], o) for o in OPTIONS] + [(engines[1], {"mode": "vectorized", "threads": 2})]
            for engine, options in checks:
                base = run(engine, sql, options)
                got = run(engine, sql, {**options, "native": True})
                if args.verbose and options is OPTIONS[0]:
                    print(f"[{qi}] {base[0]} {sql}")
                if got != base:
                    failures += 1
                    print(f"MISMATCH {options}\n  {sql}\n  base={str(base)[:300]}\n  got ={str(got)[:300]}")
                    break
    print(f"{args.queries} queries, {failures} mismatches")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
