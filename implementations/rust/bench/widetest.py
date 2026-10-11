#!/usr/bin/env python3
"""Wide-decimal (CR-2, DECIMAL(38)) oracle test across every execution option.

Generates tables with wide (p > 18) and narrow DECIMAL columns, loads them in
several physical representations (column table, row layout, PQCF PLAIN and
RLE files, plain and mmap), computes the expected result of each query with
Python's `decimal` module and checks the engine's result under every
execution variant (mode x join x threads x optimize, optionally native
kernels), with default and tiny morsels. Expected NUMERIC_OVERFLOW errors
are predicted by the oracle as well.

Usage: widetest.py --engine bin/polyquery [--rows 5000] [--seed 7] [--native LIB] [-v]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import tempfile
from decimal import ROUND_FLOOR, ROUND_CEILING, ROUND_HALF_UP, Decimal, getcontext
from pathlib import Path

getcontext().prec = 200

VARIANTS = [
    {"mode": "row", "join": "hash", "threads": 1, "optimize": True},
    {"mode": "row", "join": "nested_loop", "threads": 1, "optimize": False},
    {"mode": "row", "join": "merge", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "hash", "threads": 4, "optimize": True},
    {"mode": "vectorized", "join": "merge", "threads": 1, "optimize": False},
    {"mode": "vectorized", "join": "nested_loop", "threads": 3, "optimize": True},
    {},
]


class Engine:
    def __init__(self, launcher, data, env, extra=()):
        self.p = subprocess.Popen([launcher, "session", "--data-dir", data, *extra],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, env=env)
        self.n = 0

    def call(self, req):
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


def fmt(d: Decimal, scale: int) -> str:
    q = d.quantize(Decimal(1).scaleb(-scale))
    s = format(q, "f")
    return s.lstrip("-") if q == 0 else s


def fits(d: Decimal, scale: int, p: int) -> bool:
    return abs(d.scaleb(scale)) < Decimal(10) ** p


class Overflow(Exception):
    pass


def rand_dec(rng, int_digits, scale, null_rate=0.05):
    if rng.random() < null_rate:
        return None
    kind = rng.random()
    if kind < 0.3:
        digits = rng.randint(0, 2)
    elif kind < 0.5:
        digits = int_digits
    else:
        digits = rng.randint(0, int_digits)
    ip = rng.randint(0, 10 ** digits - 1) if digits else 0
    fp = rng.randint(0, 10 ** scale - 1) if scale else 0
    v = Decimal(ip) + Decimal(fp).scaleb(-scale)
    return -v if rng.random() < 0.4 else v


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--rows", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--native", metavar="LIB")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    launcher = str(Path(args.engine).resolve())
    extra = ["--native-kernels", str(Path(args.native).resolve())] if args.native else []
    variants = VARIANTS + ([dict(v, native=True) for v in VARIANTS] if args.native else [])

    # ---- data: w(id, g, a DECIMAL(38,10), b DECIMAL(30,0), c DECIMAL(20,2), n DECIMAL(10,2), k INT64)
    groups = ["p", "q", "r", "s", "t"]
    W = []
    for i in range(1, args.rows + 1):
        a = rand_dec(rng, 23, 10)
        b = rand_dec(rng, 21, 0)
        if b is not None and rng.random() < 0.2:
            b = Decimal(rng.randint(-50, 50))  # small values: join with k
        c = rand_dec(rng, 18, 2)
        n = rand_dec(rng, 8, 2)
        if a is not None and rng.random() < 0.05 and n is not None:
            a = n  # wide = narrow equalities
        k = None if rng.random() < 0.05 else rng.randint(-60, 60)
        W.append(dict(id=i, g=rng.choice(groups), a=a, b=b, c=c, n=n, k=k))
    # dimension: d(key DECIMAL(25,0), nkey DECIMAL(12,1), label STRING)
    D = []
    for j in range(200):
        key = Decimal(rng.randint(-60, 60)) if j % 2 else rng.choice([r["b"] for r in W if r["b"] is not None])
        nkey = Decimal(rng.randint(-300, 300)).scaleb(-1)
        D.append(dict(key=key, nkey=nkey, label=f"L{j}"))

    def csv_val(v):
        return "" if v is None else str(v)

    w_csv = "id,g,a,b,c,n,k\n" + "".join(
        ",".join(csv_val(r[c]) for c in ["id", "g", "a", "b", "c", "n", "k"]) + "\n" for r in W)
    w_schema = [{"name": "id", "type": "INT64"}, {"name": "g", "type": "STRING"},
                {"name": "a", "type": "DECIMAL(38,10)"}, {"name": "b", "type": "DECIMAL(30,0)"},
                {"name": "c", "type": "DECIMAL(20,2)"}, {"name": "n", "type": "DECIMAL(10,2)"},
                {"name": "k", "type": "INT64"}]
    d_csv = "key,nkey,label\n" + "".join(f"{r['key']},{r['nkey']},{r['label']}\n" for r in D)
    d_schema = [{"name": "key", "type": "DECIMAL(25,0)"}, {"name": "nkey", "type": "DECIMAL(12,1)"},
                {"name": "label", "type": "STRING"}]

    tmp = Path(tempfile.mkdtemp(prefix="pqwide-"))
    (tmp / "out").mkdir()
    engines = [Engine(launcher, str(tmp), dict(os.environ), extra),
               Engine(launcher, str(tmp), dict(os.environ, POLYQUERY_MORSEL_ROWS="37"), extra)]
    copies = ["w", "w_row", "w_pq", "w_rle"]
    for i, e in enumerate(engines):
        assert e.call({"op": "load", "table": "w", "format": "csv", "data": w_csv, "schema": w_schema}).get("ok")
        assert e.call({"op": "load", "table": "w_row", "format": "csv", "data": w_csv, "schema": w_schema,
                       "options": {"layout": "row"}}).get("ok")
        assert e.call({"op": "load", "table": "d", "format": "csv", "data": d_csv, "schema": d_schema}).get("ok")
        for name, enc in [("w_pq", "plain"), ("w_rle", "rle")]:
            path = f"out/{name}{i}.pqcf"
            r = e.call({"op": "save", "table": "w", "path": path,
                        "options": {"row_group_size": 700, "encoding": enc}})
            assert r.get("ok"), r
            assert (tmp / path).read_bytes()[4] == 2
            r = e.call({"op": "open", "table": name, "path": path, "options": {"mmap": name == "w_rle"}})
            assert r.get("ok"), r
        for t in copies:
            for col, kind in [("a", "BTREE"), ("b", "HASH"), ("c", "BTREE")]:
                r = e.call({"op": "query", "sql": f"CREATE INDEX {t}_{col} ON {t} ({col}) USING {kind}"})
                assert r.get("ok"), r

    # ---- oracle queries: (sql template with {T}, expected rows or "ERROR:CODE", ordered)
    nn = lambda v: v is not None
    cases = []

    def add(sql, fn, ordered=True):
        try:
            exp = fn()
        except Overflow:
            exp = "ERROR:NUMERIC_OVERFLOW"
        cases.append((sql, exp, ordered))

    def gsum(rows, col):
        vals = [r[col] for r in rows if nn(r[col])]
        return sum(vals, Decimal(0)) if vals else None

    def grouped():
        out = []
        for g in groups:
            rs = [r for r in W if r["g"] == g]
            sa, sb, sc = gsum(rs, "a"), gsum(rs, "b"), gsum(rs, "c")
            for v, s, p in [(sa, 10, 38), (sb, 0, 38), (sc, 2, 38)]:
                if v is not None and not fits(v, s, p):
                    raise Overflow
            av = [r["a"] for r in rs if nn(r["a"])]
            out.append([g, len(av), fmt(sa, 10), fmt(min(av), 10), fmt(max(av), 10), fmt(sb, 0),
                        fmt(min(r["c"] for r in rs if nn(r["c"])), 2), fmt(sc, 2)])
        return out
    add("SELECT g, COUNT(a), SUM(a), MIN(a), MAX(a), SUM(b), MIN(c), SUM(c) FROM {T} GROUP BY g ORDER BY g",
        grouped)

    def narrow_sum():
        s = gsum(W, "n")
        if not fits(s, 2, 18):
            raise Overflow
        return [[fmt(s, 2), fmt(s, 2)]]
    add("SELECT SUM(n), SUM(CAST(n AS DECIMAL(38,2))) FROM {T}", narrow_sum)

    lit = Decimal("1234567.0000000001")
    add("SELECT COUNT(*), SUM(id) FROM {T} WHERE a > 1234567.0000000001",
        lambda: [[sum(1 for r in W if nn(r["a"]) and r["a"] > lit),
                  sum(r["id"] for r in W if nn(r["a"]) and r["a"] > lit) or None]])
    add("SELECT COUNT(*) FROM {T} WHERE a = n", lambda: [[sum(1 for r in W if nn(r["a"]) and nn(r["n"]) and r["a"] == r["n"])]])
    add("SELECT COUNT(*) FROM {T} WHERE b = k", lambda: [[sum(1 for r in W if nn(r["b"]) and nn(r["k"]) and r["b"] == r["k"])]])
    add("SELECT COUNT(*) FROM {T} WHERE b < k OR c > 100000000000000000.5",
        lambda: [[sum(1 for r in W if (nn(r["b"]) and nn(r["k"]) and r["b"] < r["k"]) or (nn(r["c"]) and r["c"] > Decimal("100000000000000000.5")))]])
    lo, hi = Decimal("-5000000000000000000000"), Decimal("12.5")
    add("SELECT COUNT(*), MIN(id), MAX(id) FROM {T} WHERE b BETWEEN -5000000000000000000000.0 AND 12.5",
        lambda: (lambda ids: [[len(ids), min(ids) if ids else None, max(ids) if ids else None]])(
            [r["id"] for r in W if nn(r["b"]) and lo <= r["b"] <= hi]))
    big = Decimal(9223372036854775807)
    add("SELECT COUNT(*) FROM {T} WHERE b > 9223372036854775807 AND b <> 1.5",
        lambda: [[sum(1 for r in W if nn(r["b"]) and r["b"] > big)]])
    add("SELECT COUNT(*) FROM {T} WHERE b IN (1, -2, 3.0, 12345678901234567890123.0)",
        lambda: [[sum(1 for r in W if nn(r["b"]) and r["b"] in (1, -2, 3, Decimal("12345678901234567890123")))]])
    pick = next(r["a"] for r in W if nn(r["a"]) and abs(r["a"]) > 10 ** 20)
    add(f"SELECT id FROM {{T}} WHERE a = {pick} ORDER BY id", lambda: [[r["id"]] for r in W if r["a"] == pick])
    add(f"SELECT id FROM {{T}} WHERE a >= {pick} AND a < {pick + 1} ORDER BY id",
        lambda: [[r["id"]] for r in W if nn(r["a"]) and pick <= r["a"] < pick + 1])

    def arith():
        out = []
        for r in W[:300]:
            if r["id"] % 3:
                continue
            s = None if not (nn(r["b"]) and nn(r["c"])) else r["b"] + r["c"]
            m = None if not (nn(r["b"]) and nn(r["n"])) else r["b"] * r["n"]
            d = None if not (nn(r["c"]) and nn(r["n"])) else r["c"] - r["n"]
            for v, sc in [(s, 2), (m, 2), (d, 2)]:
                if v is not None and not fits(v, sc, 38):
                    raise Overflow
            out.append([r["id"], None if s is None else fmt(s, 2), None if m is None else fmt(m, 2),
                        None if d is None else fmt(d, 2)])
        return out
    add("SELECT id, b + c, b * n, c - n FROM {T} WHERE id <= 300 AND id % 3 = 0 ORDER BY id", arith)

    def overflow_mul():
        for r in W:
            if nn(r["a"]) and nn(r["c"]) and not fits(r["a"] * r["c"], 12, 38):
                raise Overflow
        return [[sum(1 for r in W if nn(r["a"]) and nn(r["c"]))]]
    add("SELECT COUNT(a * c) FROM {T}", overflow_mul)

    add("SELECT id, a FROM {T} ORDER BY a DESC, id LIMIT 15",
        lambda: [[r["id"], None if r["a"] is None else fmt(r["a"], 10)] for r in
                 sorted(W, key=lambda r: (0 if r["a"] is None else 1, r["a"] or 0, -r["id"]), reverse=True)][:15])
    add("SELECT id, b FROM {T} WHERE b IS NOT NULL ORDER BY b, id LIMIT 15",
        lambda: [[r["id"], fmt(r["b"], 0)] for r in sorted((r for r in W if nn(r["b"])), key=lambda r: (r["b"], r["id"]))][:15])
    add("SELECT COUNT(DISTINCT b), COUNT(DISTINCT a) FROM {T}",
        lambda: [[len({r["b"] for r in W if nn(r["b"])}), len({r["a"] for r in W if nn(r["a"])})]])

    def distinct_groups():
        cnt = {}
        for r in W:
            if nn(r["b"]) and abs(r["b"]) <= 50:
                cnt[r["b"]] = cnt.get(r["b"], 0) + 1
        return [[fmt(k, 0), v] for k, v in sorted(cnt.items())]
    add("SELECT b, COUNT(*) FROM {T} WHERE b BETWEEN -50 AND 50 GROUP BY b ORDER BY b", distinct_groups)

    def join_wide():
        out = []
        for r in W:
            for d in D:
                if nn(r["b"]) and r["b"] == d["key"]:
                    out.append((r["id"], d["label"]))
        return [[i, l] for i, l in sorted(out)]
    add("SELECT t.id, d.label FROM {T} t JOIN d ON t.b = d.key ORDER BY t.id, d.label", join_wide)

    def join_int():
        out = sum(1 for r in W for d in D if nn(r["k"]) and r["k"] == d["key"])
        return [[out]]
    add("SELECT COUNT(*) FROM {T} t JOIN d ON t.k = d.key", join_int)

    def join_narrow():
        out = sum(1 for r in W for d in D if nn(r["n"]) and r["n"] == d["nkey"])
        sm = sum((d["key"] for r in W for d in D if nn(r["n"]) and r["n"] == d["nkey"]), Decimal(0))
        return [[out, fmt(sm, 0) if out else None]]
    add("SELECT COUNT(*), SUM(d.key) FROM {T} t JOIN d ON t.n = d.nkey", join_narrow)

    def left_join():
        keys = {}
        for d in D:
            keys.setdefault(d["key"], 0)
            keys[d["key"]] += 1
        return [[sum(keys.get(r["b"], 1) if nn(r["b"]) else 1 for r in W)]]
    add("SELECT COUNT(*) FROM {T} t LEFT JOIN d ON t.b = d.key", left_join)

    def casts():
        out = []
        for r in W[:200]:
            a = r["a"]
            if a is None:
                out.append([r["id"], None, None, None, None, None])
                continue
            i = int(a)  # truncates toward zero
            if not -2 ** 63 <= i < 2 ** 63:
                raise Overflow
            out.append([r["id"], i, float(a), fmt(a.quantize(Decimal("0.01"), ROUND_HALF_UP), 2),
                        fmt(a.to_integral_value(ROUND_FLOOR), 0), fmt(a.to_integral_value(ROUND_CEILING), 0)])
        return out
    add("SELECT id, CAST(a AS INT64), CAST(a AS FLOAT64), ROUND(a, 2), FLOOR(a), CEIL(a) FROM {T} WHERE id <= 200 ORDER BY id",
        casts)

    def casts_small():
        out = []
        for r in W[:200]:
            a = r["a"]
            if a is None or abs(a) >= 10 ** 15:
                continue
            out.append([r["id"], int(a), fmt(a.quantize(Decimal("0.01"), ROUND_HALF_UP), 2), str(fmt(a, 10))])
        return out
    add("SELECT id, CAST(a AS INT64), CAST(a AS DECIMAL(20,2)), CAST(a AS STRING) FROM {T} "
        "WHERE id <= 200 AND a > -1000000000000000 AND a < 1000000000000000 ORDER BY id", casts_small)

    def coalesce():
        out = []
        for r in W[:100]:
            v = r["a"] if nn(r["a"]) else (r["n"] if nn(r["n"]) else Decimal(0))
            out.append([r["id"], fmt(v, 10)])
        return out
    add("SELECT id, COALESCE(a, n, 0) FROM {T} WHERE id <= 100 ORDER BY id", coalesce)

    def case_expr():
        out = []
        for r in W[:100]:
            v = r["c"] if nn(r["k"]) and r["k"] > 0 else r["n"]
            out.append([r["id"], None if v is None else fmt(v, 2)])
        return out
    add("SELECT id, CASE WHEN k > 0 THEN c ELSE n END FROM {T} WHERE id <= 100 ORDER BY id", case_expr)

    def union_all():
        vals = [r["b"] for r in W if r["id"] <= 30] + [r["n"] for r in W if r["id"] <= 30]
        vals = [v for v in vals if nn(v)]
        return [[fmt(v, 2)] for v in sorted(vals)]
    add("SELECT v FROM (SELECT b AS v FROM {T} WHERE id <= 30 UNION ALL SELECT n FROM {T} WHERE id <= 30) x "
        "WHERE v IS NOT NULL ORDER BY v", union_all)

    def avg():
        out = []
        for g in groups:
            vs = [r["b"] for r in W if r["g"] == g and nn(r["b"])]
            out.append([g, float(sum(vs, Decimal(0)) / len(vs))])
        return out
    add("SELECT g, AVG(b) FROM {T} GROUP BY g ORDER BY g", avg)

    def having():
        out = []
        for g in groups:
            vs = [r["c"] for r in W if r["g"] == g and nn(r["c"])]
            s = sum(vs, Decimal(0))
            if s > 0:
                out.append([g, fmt(max(vs), 2)])
        return out
    add("SELECT g, MAX(c) FROM {T} GROUP BY g HAVING SUM(c) > 0 ORDER BY g", having)

    def neg_abs():
        out = []
        for r in W[:50]:
            out.append([r["id"], None if r["b"] is None else fmt(-r["b"], 0),
                        None if r["a"] is None else fmt(abs(r["a"]), 10)])
        return out
    add("SELECT id, -b, ABS(a) FROM {T} WHERE id <= 50 ORDER BY id", neg_abs)

    def scalar_sub():
        mx = max(r["a"] for r in W if nn(r["a"]))
        return [[r["id"]] for r in W if r["a"] == mx]
    add("SELECT id FROM {T} WHERE a = (SELECT MAX(a) FROM {T}) ORDER BY id", scalar_sub)

    def in_sub():
        keys = {d["key"] for d in D}
        return [[sum(1 for r in W if nn(r["b"]) and r["b"] in keys)]]
    add("SELECT COUNT(*) FROM {T} WHERE b IN (SELECT key FROM d)", in_sub)

    # ---- run
    def norm(rows):
        return [[round(x, 6) if isinstance(x, float) else x for x in r] for r in rows]

    def close_rows(got, exp, ordered):
        if not ordered:
            got, exp = sorted(map(json.dumps, got)), sorted(map(json.dumps, exp))
            return got == exp
        if len(got) != len(exp):
            return False
        for g, e in zip(got, exp):
            if len(g) != len(e):
                return False
            for x, y in zip(g, e):
                if isinstance(y, float) and isinstance(x, (int, float)):
                    if abs(x - y) > 1e-9 * max(1.0, abs(y)):
                        return False
                elif x != y:
                    return False
        return True

    fails = 0
    total = 0
    reported = set()
    for sql_t, exp, ordered in cases:
        for t in copies:
            sql = sql_t.replace("{T}", t)
            for ei, e in enumerate(engines):
                for v in variants:
                    total += 1
                    r = e.call({"op": "query", "sql": sql, "options": dict(v)})
                    if isinstance(exp, str):
                        ok = not r.get("ok") and r["error"]["code"] == exp[6:]
                        got = r.get("error", {}).get("code") if not r.get("ok") else r["rows"][:3]
                    else:
                        ok = r.get("ok") and close_rows(r["rows"], exp, ordered)
                        got = r.get("rows", r.get("error"))
                    if not ok:
                        fails += 1
                        if sql_t not in reported:
                            reported.add(sql_t)
                            if isinstance(got, list) and isinstance(exp, list):
                                diff = [(g, x) for g, x in zip(got, exp) if g != x][:3]
                                print(f"FAIL engine{ei} {v}\n  {sql}\n  rows got/exp: {len(got)}/{len(exp)}"
                                      f" first diffs: {json.dumps(diff)[:600]}")
                            else:
                                print(f"FAIL engine{ei} {v}\n  {sql}\n  got: {json.dumps(got)[:400]}\n"
                                      f"  exp: {json.dumps(exp)[:400]}")
        if args.verbose:
            print("ok" if not fails else "..", sql_t[:100])
    for e in engines:
        e.close()
    print(f"widetest: {total - fails}/{total} passed ({len(cases)} queries x {len(copies)} tables x "
          f"{len(engines)} engines x {len(variants)} variants)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
