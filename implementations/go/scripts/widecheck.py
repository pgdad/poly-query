#!/usr/bin/env python3
"""Oracle test of wide DECIMAL support (change request CR-2).

Generates random data (wide, narrow and INT64 columns with values at the
38-digit and int64 limits, NULLs, duplicates), loads it as CSV (column and
row layout) and as PQCF v2 (eager and mmap), and checks arithmetic, casts,
rounding, comparisons, IN/BETWEEN, aggregates, grouping, sorting, joins on
mixed key types and index lookups against Python's decimal module
(100-digit context) under several execution option sets.

Usage:
  SEED=7 ROWS=3000 python3 implementations/go/scripts/widecheck.py [ENGINE [LIBPQKERNELS]]
"""
import atexit, json, random, shutil, subprocess, sys, os, itertools, tempfile
from decimal import Decimal, getcontext, ROUND_HALF_UP, ROUND_FLOOR, ROUND_CEILING, ROUND_DOWN
from pathlib import Path

getcontext().prec = 100
ENGINE = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parent.parent / "bin" / "polyquery")
NATIVE = sys.argv[2] if len(sys.argv) > 2 else None
DATA = tempfile.mkdtemp(prefix="widecheck-")
atexit.register(shutil.rmtree, DATA, True)
rnd = random.Random(int(os.environ.get("SEED", "7")))
N = int(os.environ.get("ROWS", "3000"))

COLS = [("id", "INT64"), ("g", "STRING"), ("w1", "DECIMAL(38,10)"), ("w2", "DECIMAL(30,0)"),
        ("w3", "DECIMAL(20,5)"), ("n1", "DECIMAL(10,2)"), ("i1", "INT64"), ("n0", "DECIMAL(18,0)")]

def rdec(p, s, big=0.3):
    if rnd.random() < 0.1:
        return None
    if rnd.random() < big:
        digits = rnd.randint(1, p)
    else:
        digits = rnd.randint(1, min(p, s + 4))
    u = rnd.randint(0, 10 ** digits - 1)
    if rnd.random() < 0.4:
        u = -u
    return Decimal(u).scaleb(-s)

def rint():
    if rnd.random() < 0.1:
        return None
    r = rnd.random()
    if r < 0.1:
        return rnd.choice([2**63 - 1, -2**63, 2**63 - 2, 10**18, -10**18])
    if r < 0.3:
        return rnd.randint(-2**63, 2**63 - 1)
    return rnd.randint(-1000, 1000)

pool = {c: [] for c, _ in COLS}
rows = []
for k in range(1, N + 1):
    def pick(col, gen):
        if pool[col] and rnd.random() < 0.15:
            return rnd.choice(pool[col])
        v = gen()
        pool[col].append(v)
        return v
    row = {"id": k, "g": rnd.choice("abcde"),
           "w1": pick("w1", lambda: rdec(38, 10)), "w2": pick("w2", lambda: rdec(30, 0)),
           "w3": pick("w3", lambda: rdec(20, 5)), "n1": pick("n1", lambda: rdec(10, 2, 0.5)),
           "i1": pick("i1", rint), "n0": pick("n0", lambda: rdec(18, 0, 0.5))}
    # Make some cross-column equalities exist.
    if rnd.random() < 0.05 and row["w3"] is not None:
        row["w1"] = row["w3"]
    if rnd.random() < 0.05 and row["i1"] is not None:
        row["w2"] = Decimal(row["i1"])
    rows.append(row)

def fmt(v):
    return "" if v is None else str(v)

with open(os.path.join(DATA, "t.csv"), "w") as f:
    f.write(",".join(c for c, _ in COLS) + "\n")
    for r in rows:
        f.write(",".join(fmt(r[c]) if not isinstance(r[c], Decimal) else format(r[c], "f") for c, _ in COLS) + "\n")

def ptype(t):
    if t.startswith("DECIMAL"):
        p, s = t[8:-1].split(",")
        return ("D", int(p), int(s))
    return (t,)

TYPES = {c: ptype(t) for c, t in COLS}

class Overflow(Exception):
    pass

def fits(v, p, s):
    return abs(v.scaleb(s)) < Decimal(10) ** p

def dstr(v, s):
    q = v.quantize(Decimal(1).scaleb(-s))
    if q == 0:
        q = abs(q)
    return format(q, "f")

# ---------------------------------------------------------------- engine session
class Session:
    def __init__(self):
        args = [ENGINE, "session", "--data-dir", DATA, "--log-level", "warn"]
        if NATIVE:
            args += ["--native-kernels", NATIVE]
        env = dict(os.environ, POLYQUERY_MORSEL_ROWS="300")
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    def req(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n"); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

S = Session()
r = S.req({"op": "load", "table": "t", "format": "csv", "path": "t.csv",
           "schema": [{"name": c, "type": t} for c, t in COLS]})
assert r["ok"], r
S.req({"op": "save", "table": "t", "path": "t.pqcf", "encoding": "auto", "row_group_size": 700})
r = S.req({"op": "open", "table": "tp", "path": "t.pqcf"})
assert r["ok"], r
r = S.req({"op": "open", "table": "tm", "path": "t.pqcf", "options": {"mmap": True}})
assert r["ok"], r
r = S.req({"op": "load", "table": "tr", "format": "csv", "path": "t.csv",
           "schema": [{"name": c, "type": t} for c, t in COLS], "options": {"layout": "row"}})
assert r["ok"], r

OPTS = [{"mode": "row", "threads": 1}, {"mode": "vectorized", "threads": 1}, {"mode": "vectorized", "threads": 4},
        {"mode": "row", "threads": 4}, {"mode": "vectorized", "join": "merge"}, {"mode": "row", "join": "nested_loop"},
        {"mode": "vectorized", "optimize": False}, {"mode": "vectorized", "use_indexes": False}]
if NATIVE:
    OPTS += [{"mode": "vectorized", "native": True, "threads": 4}, {"mode": "row", "native": True}]

fails = 0
checked = 0

def run(sql, expect, ordered=True, tables=("t", "tp", "tm", "tr")):
    """expect: ("rows", [types], [rows]) or ("error", code)."""
    global fails, checked
    for tb in tables:
        q = sql.replace("{t}", tb)
        for o in OPTS:
            checked += 1
            r = S.req({"op": "query", "sql": q, "options": o})
            if expect[0] == "error":
                if r["ok"] or r["error"]["code"] != expect[1]:
                    fails += 1
                    print("FAIL", q, o, "want error", expect[1], "got", json.dumps(r)[:300])
                continue
            if not r["ok"]:
                fails += 1
                print("FAIL", q, o, "error", r["error"])
                continue
            got_types = [c["type"] for c in r["columns"]]
            want_rows = expect[2]
            got_rows = r["rows"]
            if not ordered:
                got_rows = sorted(got_rows, key=json.dumps); want_rows = sorted(want_rows, key=json.dumps)
            if got_types != expect[1] or not rows_equal(got_rows, want_rows):
                fails += 1
                print("FAIL", q, o)
                print("   types", got_types, expect[1])
                for a, b in zip(got_rows, want_rows):
                    if not rows_equal([a], [b]):
                        print("   got ", a, "\n   want", b)
                        break
                if len(got_rows) != len(want_rows):
                    print("   rowcount", len(got_rows), len(want_rows))
                if fails > 60:
                    sys.exit(1)

def rows_equal(a, b):
    if len(a) != len(b):
        return False
    for x, y in zip(a, b):
        if len(x) != len(y):
            return False
        for u, v in zip(x, y):
            if isinstance(u, float) or isinstance(v, float):
                if u is None or v is None or abs(u - v) > 1e-9 * max(1, abs(u), abs(v)):
                    return False
            elif u != v:
                return False
    return True

def dec_or_int(c, r):
    v = r[c]
    if v is None:
        return None
    return Decimal(v)

def scale(c):
    t = TYPES[c]
    return t[2] if t[0] == "D" else 0

def wide(c):
    t = TYPES[c]
    return t[0] == "D" and t[1] > 18

# ---------------------------------------------------------------- per-row arithmetic
def arith(a, op, b):
    W = 38 if wide(a) or wide(b) else 18
    if TYPES[a][0] == "INT64" and TYPES[b][0] == "INT64":
        return None
    sa, sb = scale(a), scale(b)
    s = max(sa, sb) if op in "+-" else sa + sb
    if s > W:
        return ("error", "TYPE_ERROR")
    out = []
    for r in rows:
        x, y = dec_or_int(a, r), dec_or_int(b, r)
        if x is None or y is None:
            out.append([r["id"], None]); continue
        if TYPES[a][0] == "INT64" and not fits(x, W, 0):
            return ("error", "NUMERIC_OVERFLOW")
        if TYPES[b][0] == "INT64" and not fits(y, W, 0):
            return ("error", "NUMERIC_OVERFLOW")
        v = x + y if op == "+" else x - y if op == "-" else x * y
        if not fits(v, W, s):
            return ("error", "NUMERIC_OVERFLOW")
        out.append([r["id"], dstr(v, s)])
    return ("rows", ["INT64", f"DECIMAL({W},{s})"], out)

numcols = ["w1", "w2", "w3", "n1", "i1", "n0"]
for a in numcols:
    for b in numcols:
        for op in "+-*":
            e = arith(a, op, b)
            if e is None:
                continue
            run(f"SELECT id, {a} {op} {b} AS v FROM {{t}} ORDER BY id", e)

# Restricted to rows where products fit, to exercise success paths.
for a, b in [("w1", "n1"), ("w2", "n1"), ("w3", "w3"), ("w2", "i1"), ("w1", "w3")]:
    sa, sb = scale(a), scale(b)
    s = sa + sb
    W = 38
    keep = []
    for r in rows:
        x, y = dec_or_int(a, r), dec_or_int(b, r)
        if x is None or y is None or (TYPES[b][0] == "INT64" and not fits(y, W, 0)):
            continue
        if fits(x * y, W, s) and abs(x) < 10**12:
            keep.append([r["id"], dstr(x * y, s)])
    ids = ",".join(str(k[0]) for k in keep[:300])
    if ids and s <= 38:
        run(f"SELECT id, {a} * {b} AS v FROM {{t}} WHERE id IN ({ids}) ORDER BY id", ("rows", ["INT64", f"DECIMAL(38,{s})"], keep[:300]))

# unary minus, ABS, ROUND, FLOOR, CEIL, CASTs
def unary_rows(c, f, typ):
    out = []
    for r in rows:
        x = dec_or_int(c, r)
        try:
            out.append([r["id"], None if x is None else f(x)])
        except Overflow:
            return ("error", "NUMERIC_OVERFLOW")
    return ("rows", ["INT64", typ], out)

for c in ["w1", "w2", "w3"]:
    t = COLS[[x for x, _ in COLS].index(c)][1]
    s = scale(c)
    run(f"SELECT id, -{c} AS v FROM {{t}} ORDER BY id", unary_rows(c, lambda x: dstr(-x, s), t))
    run(f"SELECT id, ABS({c}) AS v FROM {{t}} ORDER BY id", unary_rows(c, lambda x: dstr(abs(x), s), t))
    for n in [-3, 0, 2, 7, 40, -40]:
        rs = max(0, min(n, s))
        def rnd_(x, n=n, rs=rs):
            q = x.quantize(Decimal(1).scaleb(-n), rounding=ROUND_HALF_UP) if n >= -60 else Decimal(0)
            if not fits(q, 38, rs):
                raise Overflow
            return dstr(q, rs)
        run(f"SELECT id, ROUND({c}, {n}) AS v FROM {{t}} ORDER BY id", unary_rows(c, rnd_, f"DECIMAL(38,{rs})"))
    run(f"SELECT id, FLOOR({c}) AS v FROM {{t}} ORDER BY id", unary_rows(c, lambda x: dstr(x.to_integral_value(ROUND_FLOOR), 0), "DECIMAL(38,0)"))
    run(f"SELECT id, CEIL({c}) AS v FROM {{t}} ORDER BY id", unary_rows(c, lambda x: dstr(x.to_integral_value(ROUND_CEILING), 0), "DECIMAL(38,0)"))
    run(f"SELECT id, CAST({c} AS STRING) AS v FROM {{t}} ORDER BY id", unary_rows(c, lambda x: dstr(x, s), "STRING"))
    run(f"SELECT id, CAST({c} AS FLOAT64) AS v FROM {{t}} ORDER BY id", unary_rows(c, lambda x: float(x), "FLOAT64"))
    def toint(x):
        v = x.to_integral_value(ROUND_DOWN)
        if not (-2**63 <= v < 2**63):
            raise Overflow
        return int(v)
    run(f"SELECT id, CAST({c} AS INT64) AS v FROM {{t}} ORDER BY id", unary_rows(c, toint, "INT64"))
    for p2, s2 in [(38, 2), (25, 12), (18, 4), (38, 30), (12, 0)]:
        def cst(x, p2=p2, s2=s2):
            q = x.quantize(Decimal(1).scaleb(-s2), rounding=ROUND_HALF_UP)
            if not fits(q, p2, s2):
                raise Overflow
            return dstr(q, s2)
        run(f"SELECT id, CAST({c} AS DECIMAL({p2},{s2})) AS v FROM {{t}} ORDER BY id", unary_rows(c, cst, f"DECIMAL({p2},{s2})"))

# CAST INT64 -> wide, narrow -> wide
run("SELECT id, CAST(i1 AS DECIMAL(25,4)) AS v FROM {t} ORDER BY id",
    unary_rows("i1", lambda x: (_ for _ in ()).throw(Overflow) if not fits(x, 25, 4) else dstr(x, 4), "DECIMAL(25,4)"))
run("SELECT id, CAST(i1 AS DECIMAL(38,4)) AS v FROM {t} ORDER BY id", unary_rows("i1", lambda x: dstr(x, 4), "DECIMAL(38,4)"))
run("SELECT id, CAST(n1 AS DECIMAL(38,20)) AS v FROM {t} ORDER BY id", unary_rows("n1", lambda x: dstr(x, 20), "DECIMAL(38,20)"))

# ---------------------------------------------------------------- comparisons
def lit(v):
    t = format(Decimal(v), "f")
    if "." not in t and not (-2**63 <= int(t) < 2**63):
        t += "."
    return t

consts = ["0", "1.5", "-0.0000000001", "12345678901234567890.123456789", "9223372036854775807", "-9223372036854775808",
          "99999999999999999999999999.99", "1e10", "0.12345678901234567890123456789", "1000000000000000000000."]
def cval(c):
    if "e" in c:
        return ("F", Decimal(float(c)))
    return ("X", Decimal(c))
ops = {"=": lambda a, b: a == b, "<>": lambda a, b: a != b, "<": lambda a, b: a < b, "<=": lambda a, b: a <= b,
       ">": lambda a, b: a > b, ">=": lambda a, b: a >= b}
def as_cmp(x, kind):
    return Decimal(float(x)) if kind == "F" else x

for c in numcols:
    for k in consts:
        kind, kv = cval(k)
        for op in ["=", "<", ">=", "<>"]:
            want = [[r["id"]] for r in rows if r[c] is not None and ops[op](as_cmp(Decimal(r[c]), kind), kv)]
            run(f"SELECT id FROM {{t}} WHERE {c} {op} {k} ORDER BY id", ("rows", ["INT64"], want))
            want2 = [[r["id"]] for r in rows if r[c] is not None and ops[op](kv, as_cmp(Decimal(r[c]), kind))]
            run(f"SELECT id FROM {{t}} WHERE {k} {op} {c} ORDER BY id", ("rows", ["INT64"], want2))
for a, b in itertools.permutations(numcols, 2):
    for op in ["=", "<", ">="]:
        want = [[r["id"]] for r in rows if r[a] is not None and r[b] is not None and ops[op](Decimal(r[a]), Decimal(r[b]))]
        run(f"SELECT id FROM {{t}} WHERE {a} {op} {b} ORDER BY id", ("rows", ["INT64"], want))
# BETWEEN / IN
for c in numcols:
    lo, hi = Decimal("-123456789012.5"), Decimal("99999999999999999999.99")
    want = [[r["id"]] for r in rows if r[c] is not None and lo <= Decimal(r[c]) <= hi]
    run(f"SELECT id FROM {{t}} WHERE {c} BETWEEN -123456789012.5 AND 99999999999999999999.99 ORDER BY id", ("rows", ["INT64"], want))
    vals = [v for v in pool[c] if v is not None][:12]
    lits = [lit(v) for v in vals] + ["0.5", "7"]
    sv = set(Decimal(x) for x in lits)
    want = [[r["id"]] for r in rows if r[c] is not None and Decimal(r[c]) in sv]
    run(f"SELECT id FROM {{t}} WHERE {c} IN ({', '.join(lits)}) ORDER BY id", ("rows", ["INT64"], want))
    run(f"SELECT id FROM {{t}} WHERE {c} IN ({', '.join(lits[:3])}) ORDER BY id",
        ("rows", ["INT64"], [[r["id"]] for r in rows if r[c] is not None and Decimal(r[c]) in set(Decimal(x) for x in lits[:3])]))
    want = [[r["id"]] for r in rows if r[c] is not None and Decimal(r[c]) not in sv]
    run(f"SELECT id FROM {{t}} WHERE {c} NOT IN ({', '.join(lits)}) ORDER BY id", ("rows", ["INT64"], want))

# ---------------------------------------------------------------- aggregates
def agg_expect(c, groups=True):
    W = 38 if wide(c) else 18
    s = scale(c)
    t = COLS[[x for x, _ in COLS].index(c)][1]
    by = {}
    for r in rows:
        by.setdefault(r["g"] if groups else "", []).append(r[c])
    out = []
    for g in sorted(by):
        vals = [Decimal(v) for v in by[g] if v is not None]
        tot = sum(vals, Decimal(0))
        if TYPES[c][0] == "INT64":
            if not (-2**63 <= tot < 2**63):
                return ("error", "NUMERIC_OVERFLOW")
            sv = int(tot)
        else:
            if not fits(tot, W, s):
                return ("error", "NUMERIC_OVERFLOW")
            sv = dstr(tot, s)
        mn = min(vals) if vals else None
        mx = max(vals) if vals else None
        conv = (lambda v: None if v is None else int(v)) if TYPES[c][0] == "INT64" else (lambda v: None if v is None else dstr(v, s))
        avg = float(tot / len(vals)) if vals else None
        row = ([g] if groups else []) + [len(vals), sv if vals else None, conv(mn), conv(mx), avg, len(set(vals))]
        out.append(row)
    st = "INT64" if TYPES[c][0] == "INT64" else f"DECIMAL({W},{s})"
    types = (["STRING"] if groups else []) + ["INT64", st, t, t, "FLOAT64", "INT64"]
    return ("rows", types, out)

for c in numcols:
    run(f"SELECT g, COUNT({c}) AS n, SUM({c}) AS s, MIN({c}) AS lo, MAX({c}) AS hi, AVG({c}) AS a, COUNT(DISTINCT {c}) AS d FROM {{t}} GROUP BY g ORDER BY g", agg_expect(c))
    run(f"SELECT COUNT({c}) AS n, SUM({c}) AS s, MIN({c}) AS lo, MAX({c}) AS hi, AVG({c}) AS a, COUNT(DISTINCT {c}) AS d FROM {{t}}", agg_expect(c, False))

# SUM of small wide values (succeeds)
for c in ["w1", "w3"]:
    s = scale(c)
    sel = [r for r in rows if r[c] is not None and abs(Decimal(r[c])) < 10**15]
    ids = set(r["id"] for r in sel)
    tot = sum((Decimal(r[c]) for r in sel), Decimal(0))
    run(f"SELECT SUM({c}) AS s, MIN({c}) AS lo FROM {{t}} WHERE {c} > -1000000000000000 AND {c} < 1000000000000000",
        ("rows", [f"DECIMAL(38,{s})", COLS[[x for x, _ in COLS].index(c)][1]], [[dstr(tot, s), dstr(min(Decimal(r[c]) for r in sel), s)]]))
    # GROUP BY the wide value
    cnt = {}
    for r in rows:
        k = None if r[c] is None else Decimal(r[c])
        cnt[k] = cnt.get(k, 0) + 1
    keys = sorted([k for k in cnt if k is not None])
    want = ([[None, cnt[None]]] if None in cnt else []) + [[dstr(k, s), cnt[k]] for k in keys]
    run(f"SELECT {c}, COUNT(*) AS n FROM {{t}} GROUP BY {c} ORDER BY {c}", ("rows", [COLS[[x for x, _ in COLS].index(c)][1], "INT64"], want))
    want = [[dstr(k, s)] for k in sorted(set(Decimal(r[c]) for r in rows if r[c] is not None), reverse=True)] + ([[None]] if None in cnt else [])
    run(f"SELECT DISTINCT {c} FROM {{t}} ORDER BY {c} DESC", ("rows", [COLS[[x for x, _ in COLS].index(c)][1]], want))
    want = [[r["id"]] for r in sorted([r for r in rows], key=lambda r: (r[c] is None, -(Decimal(r[c]) if r[c] is not None else 0), r["id"]))][:25]
    run(f"SELECT id FROM {{t}} ORDER BY {c} DESC NULLS LAST, id LIMIT 25", ("rows", ["INT64"], want))
    want = [[r["id"]] for r in sorted([r for r in rows], key=lambda r: (r[c] is not None, Decimal(r[c]) if r[c] is not None else 0, r["id"]))]
    run(f"SELECT id FROM {{t}} ORDER BY {c}, id", ("rows", ["INT64"], want))

# ---------------------------------------------------------------- joins
def join_expect(a, b):
    idx = {}
    for r in rows:
        if r[b] is not None:
            idx.setdefault(Decimal(r[b]), []).append(r["id"])
    out = []
    for r in rows:
        if r[a] is not None:
            for j in idx.get(Decimal(r[a]), []):
                out.append([r["id"], j])
    return ("rows", ["INT64", "INT64"], sorted(out))

for a, b in [("w1", "w3"), ("w2", "i1"), ("i1", "w2"), ("w2", "n0"), ("w1", "n1"), ("n1", "w1"), ("w1", "w1")]:
    run(f"SELECT x.id AS a, y.id AS b FROM {{t}} x JOIN {{t}} y ON x.{a} = y.{b} ORDER BY a, b", join_expect(a, b), tables=("t", "tp"))
    run(f"SELECT x.id AS a, y.id AS b FROM {{t}} x JOIN t y ON x.{a} = y.{b} ORDER BY a, b", join_expect(a, b), tables=("tr",))
    sub = [[r["id"]] for r in rows if r[a] is not None and any(q[b] is not None and Decimal(q[b]) == Decimal(r[a]) for q in rows[:200])]
    run(f"SELECT id FROM {{t}} WHERE {a} IN (SELECT {b} FROM {{t}} WHERE id <= 200) ORDER BY id", ("rows", ["INT64"], sub))

# ---------------------------------------------------------------- CASE / COALESCE / NULLIF / UNION ALL
run("SELECT id, COALESCE(w1, n1, 0) AS v FROM {t} ORDER BY id",
    ("rows", ["INT64", "DECIMAL(38,10)"], [[r["id"], dstr(Decimal(r["w1"] if r["w1"] is not None else r["n1"] if r["n1"] is not None else 0), 10)] for r in rows]))
run("SELECT id, NULLIF(w2, i1) AS v FROM {t} ORDER BY id",
    ("rows", ["INT64", "DECIMAL(30,0)"], [[r["id"], None if r["w2"] is None or (r["i1"] is not None and Decimal(r["w2"]) == r["i1"]) else dstr(Decimal(r["w2"]), 0)] for r in rows]))
run("SELECT id, CASE w3 WHEN n1 THEN 'eq' WHEN 0 THEN 'zero' ELSE 'no' END AS v FROM {t} ORDER BY id",
    ("rows", ["INT64", "STRING"], [[r["id"], "eq" if r["w3"] is not None and r["n1"] is not None and Decimal(r["w3"]) == Decimal(r["n1"]) else "zero" if r["w3"] is not None and Decimal(r["w3"]) == 0 else "no"] for r in rows]))
u = [[dstr(Decimal(r["n1"]), 10)] for r in rows if r["n1"] is not None and r["id"] <= 50] + [[dstr(Decimal(r["w1"]), 10)] for r in rows if r["w1"] is not None and r["id"] <= 50]
run("SELECT v FROM (SELECT n1 AS v FROM {t} WHERE id <= 50 UNION ALL SELECT w1 FROM {t} WHERE id <= 50) q WHERE v IS NOT NULL", ("rows", ["DECIMAL(38,10)"], u), ordered=False)

# ---------------------------------------------------------------- indexes
for kind in ["BTREE", "HASH"]:
    S.req({"op": "query", "sql": "DROP INDEX IF EXISTS ixw"})
    r = S.req({"op": "query", "sql": f"CREATE INDEX ixw ON tp (w1) USING {kind}"})
    assert r["ok"], r
    for k in ["0", "1.5", "12345678901234567890.123456789"] + [lit(v) for v in pool["w1"][:5] if v is not None]:
        kv = Decimal(k)
        want = [[r["id"]] for r in rows if r["w1"] is not None and Decimal(r["w1"]) == kv]
        run(f"SELECT id FROM {{t}} WHERE w1 = {k} ORDER BY id", ("rows", ["INT64"], want), tables=("tp",))
        want = [[r["id"]] for r in rows if r["w1"] is not None and Decimal(r["w1"]) > kv]
        run(f"SELECT id FROM {{t}} WHERE w1 > {k} ORDER BY id", ("rows", ["INT64"], want), tables=("tp",))
    S.req({"op": "query", "sql": "DROP INDEX IF EXISTS ixw"})

run("SELECT id FROM {t} WHERE w2 = 1000000000000000000000", ("error", "NUMERIC_OVERFLOW"))
print(f"checked {checked}, failures {fails}")
sys.exit(1 if fails else 0)
