#!/usr/bin/env python3
"""SQLite oracle cross-check for .pqt conformance tests.

For every `query ... oracle` block, loads the file's tables into an in-memory
SQLite database (using the spec-reference ingestion in pqref.py), translates the
SQL where PolyQuery syntax differs, executes it and compares the result with the
expected rows using the acceptance comparison rules.

  oracle_check.py [paths...]          # check (default: all public + hidden cases)
  oracle_check.py --fill FILE...      # replace '?' placeholders with oracle results

The oracle is independent of every PolyQuery engine (ADR-0009).
"""
from __future__ import annotations

import argparse
import datetime as dt
import math
import re
import sqlite3
import sys
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/conformance"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pqref  # noqa: E402
from pqt import parse_file, rows_match  # noqa: E402

FIXTURE_ROOT = ROOT / "tests/conformance"

SQLITE_TYPE = {"BOOLEAN": "INTEGER", "INT64": "INTEGER", "FLOAT64": "REAL", "STRING": "TEXT",
               "DATE": "TEXT", "TIMESTAMP": "TEXT"}


def to_sqlite(v, typ: str):
    if v is None:
        return None
    if typ == "BOOLEAN":
        return 1 if v else 0
    if typ.startswith("DECIMAL"):
        return float(v)
    if typ == "DATE":
        return pqref.fmt_date(v)
    if typ == "TIMESTAMP":
        return v.strftime("%Y-%m-%d %H:%M:%S.") + f"{v.microsecond:06d}"
    return v


def from_sqlite(v, typ: str):
    if v is None:
        return None
    if typ == "BOOLEAN":
        return bool(v)
    if typ == "INT64":
        if isinstance(v, float):
            if v != int(v):
                raise ValueError(f"non-integral value {v} for INT64")
            return int(v)
        return int(v)
    if typ == "FLOAT64":
        return float(v)
    if typ.startswith("DECIMAL"):
        return pqref.fmt_decimal(Decimal(repr(v)) if isinstance(v, float) else Decimal(v), pqref.dec_params(typ)[1])
    if typ == "TIMESTAMP":
        t = pqref.parse_ts(str(v))
        if t is None:
            raise ValueError(f"bad timestamp {v!r}")
        return pqref.fmt_ts(t)
    if typ == "DATE":
        return str(v)[:10]
    return v if isinstance(v, str) else str(v)


# --- PolyQuery-semantics UDFs registered in SQLite (only functions SQLite lacks)

def _ts(x):
    return pqref.parse_ts(x) if isinstance(x, str) else None


def _udf_field(name):
    def f(x):
        t = _ts(x)
        if t is None:
            return None
        return getattr(t, name)
    return f


def _date_trunc(unit, x):
    t = _ts(x)
    if t is None:
        return None
    if unit == "year":
        t = t.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0)
    elif unit == "month":
        t = t.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    elif unit == "day":
        t = t.replace(hour=0, minute=0, second=0, microsecond=0)
    elif unit == "hour":
        t = t.replace(minute=0, second=0, microsecond=0)
    elif unit == "minute":
        t = t.replace(second=0, microsecond=0)
    return t.strftime("%Y-%m-%d %H:%M:%S.") + f"{t.microsecond:06d}"


def _date_diff(unit, a, b):
    ta, tb = _ts(a), _ts(b)
    if ta is None or tb is None:
        return None
    return (tb.date() - ta.date()).days


def _sqrt(x):
    return None if x is None else math.sqrt(x)


def _power(x, y):
    return None if x is None or y is None else float(x) ** float(y)


def connect() -> sqlite3.Connection:
    con = sqlite3.connect(":memory:")
    con.execute("PRAGMA case_sensitive_like = ON")
    for nm in ("year", "month", "day", "hour", "minute", "second"):
        con.create_function(nm.upper(), 1, _udf_field(nm), deterministic=True)
    con.create_function("DATE_TRUNC", 2, _date_trunc, deterministic=True)
    con.create_function("DATE_DIFF", 3, _date_diff, deterministic=True)
    con.create_function("SQRT", 1, _sqrt, deterministic=True)
    con.create_function("POWER", 2, _power, deterministic=True)
    return con


_LIT_TS = re.compile(r"\bTIMESTAMP\s+'([^']*)'", re.I)
_LIT_DATE = re.compile(r"\bDATE\s+'([^']*)'", re.I)
_CAST = re.compile(r"\bAS\s+(INT64|FLOAT64|STRING|BOOLEAN)\b", re.I)


def translate(sql: str) -> str:
    def ts(m):
        t = pqref.parse_ts(m.group(1))
        return "'" + (t.strftime("%Y-%m-%d %H:%M:%S.") + f"{t.microsecond:06d}") + "'" if t else m.group(0)
    sql = _LIT_TS.sub(ts, sql)
    sql = _LIT_DATE.sub(lambda m: f"'{m.group(1)}'", sql)
    sql = _CAST.sub(lambda m: "AS " + {"INT64": "INTEGER", "FLOAT64": "REAL", "STRING": "TEXT", "BOOLEAN": "INTEGER"}[m.group(1).upper()], sql)
    return sql


def load_into(con: sqlite3.Connection, req: dict, base: Path) -> None:
    fmt = req["format"]
    text = req.get("data")
    if text is None:
        text = (base / req["path"]).read_text(encoding="utf-8")
    schema = req.get("schema")
    opts = req.get("options") or {}
    if fmt == "csv":
        names, types, rows = pqref.load_csv(text, schema, opts.get("header", True), opts.get("delimiter", ","))
    else:
        names, types, rows = pqref.load_json(text, fmt, schema)
    table = req["table"]
    if not names:
        return
    if req.get("replace"):
        con.execute(f'DROP TABLE IF EXISTS "{table}"')
    cols = ", ".join(f'"{n}" {SQLITE_TYPE.get(t, "REAL")}' for n, t in zip(names, types))
    con.execute(f'CREATE TABLE "{table}" ({cols})')
    ph = ", ".join("?" for _ in names)
    con.executemany(f'INSERT INTO "{table}" VALUES ({ph})', [[to_sqlite(v, t) for v, t in zip(r, types)] for r in rows])


def open_pqcf(con: sqlite3.Connection, table: str, file: Path, replace: bool) -> None:
    import pqcf
    meta, rows = pqcf.read(file.read_bytes())
    names = [c["name"] for c in meta["columns"]]
    types = [pqref.canonical_type(c["type"]) for c in meta["columns"]]
    if replace:
        con.execute(f'DROP TABLE IF EXISTS "{table}"')
    if not names:
        return
    cols = ", ".join(f'"{n}" {SQLITE_TYPE.get(t, "REAL")}' for n, t in zip(names, types))
    con.execute(f'CREATE TABLE "{table}" ({cols})')
    ph = ", ".join("?" for _ in names)
    con.executemany(f'INSERT INTO "{table}" VALUES ({ph})', [[to_sqlite(v, t) for v, t in zip(r, types)] for r in rows])


def process(path: Path, fill: bool) -> tuple[int, int, list[str]]:
    f = parse_file(path)
    con = connect()
    saved: dict[str, str] = {}   # path -> source table (oracle models save/open as a copy)
    checked, failed, msgs = 0, 0, []
    lines = path.read_text(encoding="utf-8").split("\n")
    replacements: list[tuple[int, int, list[str]]] = []
    for st in f.steps:
        if st.kind in ("load", "data") and not st.expect_error:
            try:
                load_into(con, st.request, FIXTURE_ROOT)
            except pqref.IngestError as e:
                msgs.append(f"{path}:{st.line}: reference ingestion failed: {e.code} {e}")
                failed += 1
            continue
        if st.kind == "save" and not st.expect_error:
            snap = f"__saved_{len(saved)}"
            con.execute(f'CREATE TABLE "{snap}" AS SELECT * FROM "{st.request["table"]}"')
            saved[st.request["path"]] = snap
            continue
        if st.kind == "open" and not st.expect_error:
            p, t = st.request["path"], st.request["table"]
            if st.request.get("replace"):
                con.execute(f'DROP TABLE IF EXISTS "{t}"')
            if p in saved:
                con.execute(f'CREATE TABLE "{t}" AS SELECT * FROM "{saved[p]}"')
            else:
                open_pqcf(con, t, FIXTURE_ROOT / p, False)
            continue
        if st.kind == "request" and (st.request or {}).get("op") == "load" and \
                not any(k == "error" for k, _ in st.expectations):
            try:
                load_into(con, st.request, FIXTURE_ROOT)
            except pqref.IngestError as e:
                msgs.append(f"{path}:{st.line}: reference ingestion failed: {e.code} {e}")
                failed += 1
            continue
        if st.kind == "request" and (st.request or {}).get("op") == "drop":
            con.execute(f'DROP TABLE IF EXISTS "{st.request["table"]}"')
            continue
        if st.kind != "query" or not st.oracle:
            continue
        types = [t for _, t in st.columns or []]
        try:
            cur = con.execute(translate(st.sql))
            got = [[from_sqlite(v, t) for v, t in zip(r, types)] for r in cur.fetchall()]
            if cur.description and len(cur.description) != len(types):
                raise ValueError(f"oracle returned {len(cur.description)} columns, header has {len(types)}")
        except (sqlite3.Error, ValueError) as e:
            msgs.append(f"{path}:{st.line}: oracle error: {e}")
            failed += 1
            continue
        checked += 1
        if st.rows is None:
            if fill:
                hdr, end = st.result_span
                replacements.append((hdr + 1, end, [json_row(r) for r in got]))
            else:
                msgs.append(f"{path}:{st.line}: placeholder rows (run --fill)")
                failed += 1
            continue
        ok, msg = rows_match(st.rows, got, types, st.ordered)
        if not ok:
            failed += 1
            msgs.append(f"{path}:{st.line}: MISMATCH vs SQLite: {msg}")
    if fill and replacements:
        for start, end, new in sorted(replacements, reverse=True):
            lines[start:end] = new
        path.write_text("\n".join(lines), encoding="utf-8")
    return checked, failed, msgs


def json_row(r: list) -> str:
    import json
    out = []
    for v in r:
        if isinstance(v, float) and v.is_integer() and abs(v) < 1e15:
            out.append(repr(v))
        else:
            out.append(json.dumps(v, ensure_ascii=False))
    return "[" + ", ".join(out) + "]"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--fill", action="store_true")
    args = ap.parse_args()
    paths = [Path(p) for p in args.paths] or sorted((ROOT / "tests/conformance/cases").rglob("*.pqt")) + \
        sorted((ROOT / "tests/conformance/hidden/cases").rglob("*.pqt"))
    total_checked = total_failed = 0
    for p in paths:
        c, fl, msgs = process(p, args.fill)
        total_checked += c
        total_failed += fl
        for m in msgs:
            print(m)
    print(f"oracle: {total_checked} oracle-eligible queries checked, {total_failed} problems")
    return 1 if total_failed else 0


if __name__ == "__main__":
    _ = dt
    sys.exit(main())
