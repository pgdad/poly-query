"""Reference implementation of PolyQuery *ingestion* rules (spec/data-types/ingestion.md)
and value serialization (types.md §9), used only by validation tooling (oracle
cross-check, golden PQCF files). It is not a query engine and is never shown to
implementation agents as a solution.
"""
from __future__ import annotations

import datetime as dt
import json
import re
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

INT64_MIN, INT64_MAX = -(2**63), 2**63 - 1

RE_INT = re.compile(r"^[+-]?[0-9]+$")
RE_FLOAT = re.compile(r"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$")
RE_DATE = re.compile(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})$")
RE_TS = re.compile(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?$")
RE_DEC = re.compile(r"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$")
RE_DECTYPE = re.compile(r"^(?:DECIMAL|NUMERIC)(?:\((\d+)(?:,(\d+))?\))?$")
EPOCH = dt.date(1970, 1, 1)


class IngestError(Exception):
    def __init__(self, code: str, msg: str):
        super().__init__(msg)
        self.code = code


def canonical_type(t: str) -> str:
    u = t.strip().upper().replace(" ", "")
    alias = {"BOOL": "BOOLEAN", "BOOLEAN": "BOOLEAN", "INT": "INT64", "INTEGER": "INT64", "BIGINT": "INT64",
             "INT64": "INT64", "DOUBLE": "FLOAT64", "FLOAT": "FLOAT64", "REAL": "FLOAT64", "FLOAT64": "FLOAT64",
             "VARCHAR": "STRING", "TEXT": "STRING", "STRING": "STRING", "DATE": "DATE", "TIMESTAMP": "TIMESTAMP"}
    if u in alias:
        return alias[u]
    m = RE_DECTYPE.match(u)
    if m:
        p = int(m.group(1) or 18)
        s = int(m.group(2) or 0)
        if not (1 <= p <= 18 and 0 <= s <= p):
            raise IngestError("INVALID_REQUEST", f"bad decimal type {t}")
        return f"DECIMAL({p},{s})"
    raise IngestError("INVALID_REQUEST", f"unknown type {t}")


def dec_params(t: str) -> tuple[int, int]:
    m = re.match(r"DECIMAL\((\d+),(\d+)\)", t)
    assert m
    return int(m.group(1)), int(m.group(2))


# ------------------------------------------------------------------ parsing values

def parse_date(s: str) -> dt.date | None:
    m = RE_DATE.match(s)
    if not m:
        return None
    try:
        return dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def parse_ts(s: str) -> dt.datetime | None:
    m = RE_TS.match(s)
    if not m:
        d = parse_date(s)
        return dt.datetime(d.year, d.month, d.day) if d else None
    frac = m.group(7)
    us = int((frac[1:] + "000000")[:6]) if frac else 0
    try:
        return dt.datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)),
                           int(m.group(5)), int(m.group(6)), us)
    except ValueError:
        return None


def is_ts_text(s: str) -> bool:
    return RE_TS.match(s) is not None and parse_ts(s) is not None


def parse_float(s: str) -> float | None:
    if not RE_FLOAT.match(s):
        return None
    v = float(s)
    return v if v == v and v not in (float("inf"), float("-inf")) else None


def parse_int(s: str) -> int | None:
    if not RE_INT.match(s):
        return None
    v = int(s)
    return v if INT64_MIN <= v <= INT64_MAX else None


def parse_decimal_exact(s: str, p: int, sc: int) -> Decimal | None:
    if not RE_DEC.match(s):
        return None
    d = Decimal(s)
    frac = s.split(".", 1)[1] if "." in s else ""
    if len(frac) > sc:
        return None
    unscaled = int(d.scaleb(sc))
    if abs(unscaled) >= 10**p:
        return None
    return d


def convert_text(text: str, typ: str) -> Any:
    """Converts a non-null CSV field text to a Python value of PolyQuery type typ."""
    if typ == "STRING":
        return text
    t = text.strip(" \t")
    if typ == "BOOLEAN":
        if t.lower() in ("true", "false"):
            return t.lower() == "true"
    elif typ == "INT64":
        v = parse_int(t)
        if v is not None:
            return v
    elif typ == "FLOAT64":
        v = parse_float(t)
        if v is not None:
            return v
    elif typ == "DATE":
        v = parse_date(t)
        if v is not None:
            return v
    elif typ == "TIMESTAMP":
        v = parse_ts(t)
        if v is not None:
            return v
    elif typ.startswith("DECIMAL"):
        p, sc = dec_params(typ)
        v = parse_decimal_exact(t, p, sc)
        if v is not None:
            return v.quantize(Decimal(1).scaleb(-sc))
    raise IngestError("CONVERSION_ERROR", f"cannot convert {text!r} to {typ}")


def infer_csv_type(texts: list[str]) -> str:
    vals = [t.strip(" \t") for t in texts]
    if not vals:
        return "STRING"
    if all(v.lower() in ("true", "false") for v in vals):
        return "BOOLEAN"
    if all(parse_int(v) is not None for v in vals):
        return "INT64"
    if all(parse_float(v) is not None for v in vals):
        return "FLOAT64"
    if all(parse_date(v) is not None for v in vals):
        return "DATE"
    if all(parse_date(v) is not None or is_ts_text(v) for v in vals):
        return "TIMESTAMP"
    return "STRING"


# ------------------------------------------------------------------ CSV

def parse_csv(text: str, delimiter: str = ",") -> list[list[tuple[str, bool]]]:
    """Returns records as lists of (field_text, was_quoted)."""
    if text.startswith("﻿"):
        text = text[1:]
    records: list[list[tuple[str, bool]]] = []
    i, n = 0, len(text)
    while i < n:
        # completely empty line
        if text[i] == "\n":
            i += 1
            continue
        if text.startswith("\r\n", i):
            i += 2
            continue
        rec: list[tuple[str, bool]] = []
        while True:
            if i < n and text[i] == '"':
                i += 1
                buf = []
                while True:
                    if i >= n:
                        raise IngestError("INGEST_ERROR", "unterminated quoted field")
                    c = text[i]
                    if c == '"':
                        if i + 1 < n and text[i + 1] == '"':
                            buf.append('"'); i += 2; continue
                        i += 1
                        break
                    buf.append(c); i += 1
                # after closing quote: delimiter, newline or EOF
                if i < n and text[i] not in (delimiter, "\n", "\r"):
                    raise IngestError("INGEST_ERROR", "garbage after closing quote")
                rec.append(("".join(buf), True))
            else:
                j = i
                while j < n and text[j] not in (delimiter, "\n") and not text.startswith("\r\n", j):
                    if text[j] == '"':
                        raise IngestError("INGEST_ERROR", "quote inside unquoted field")
                    j += 1
                rec.append((text[i:j], False))
                i = j
            if i < n and text[i] == delimiter:
                i += 1
                if i >= n:
                    rec.append(("", False))
                    break
                continue
            if text.startswith("\r\n", i):
                i += 2
            elif i < n and text[i] == "\n":
                i += 1
            elif i < n and text[i] == "\r":
                i += 1
            break
        records.append(rec)
    return records


def load_csv(text: str, schema: list[dict] | None = None, header: bool = True, delimiter: str = ","):
    recs = parse_csv(text, delimiter)
    if header:
        if not recs:
            raise IngestError("INGEST_ERROR", "missing header")
        names = [f for f, _ in recs[0]]
        body = recs[1:]
    else:
        if schema is None:
            raise IngestError("INVALID_REQUEST", "header=false requires schema")
        names = [c["name"] for c in schema]
        body = recs
    if any(not nm for nm in names):
        raise IngestError("INGEST_ERROR", "empty column name")
    if len({nm.lower() for nm in names}) != len(names):
        raise IngestError("INGEST_ERROR", "duplicate column")
    for k, r in enumerate(body):
        if len(r) != len(names):
            raise IngestError("INGEST_ERROR", f"record {k + 1} has {len(r)} fields, expected {len(names)}")
    if schema is not None:
        if header and [s["name"].lower() for s in schema] != [nm.lower() for nm in names]:
            raise IngestError("INGEST_ERROR", "header does not match schema")
        types = [canonical_type(s["type"]) for s in schema]
        names = [s["name"] for s in schema] if not header else names
    else:
        types = []
        for c in range(len(names)):
            texts = [r[c][0] for r in body if not (r[c][0] == "" and not r[c][1]) and not (r[c][0] == "" and r[c][1])]
            types.append(infer_csv_type(texts))
    rows = []
    for r in body:
        row = []
        for (txt, quoted), typ in zip(r, types):
            if txt == "" and (not quoted or typ != "STRING"):
                row.append(None)
            else:
                row.append(convert_text(txt, typ))
        rows.append(row)
    return names, types, rows


# ------------------------------------------------------------------ JSON

def _json_objects(text: str, fmt: str) -> list[list[tuple[str, Any, str]]]:
    """Returns objects as ordered (key, value, raw_number_text) triples."""
    def hook(pairs):
        keys = [k for k, _ in pairs]
        if len(set(keys)) != len(keys):
            raise IngestError("INGEST_ERROR", "duplicate key")
        return ("__obj__", pairs)

    def parse_doc(s: str):
        return json.loads(s, object_pairs_hook=hook, parse_float=lambda x: ("__num__", x),
                          parse_int=lambda x: ("__num__", x),
                          parse_constant=lambda x: (_ for _ in ()).throw(IngestError("INGEST_ERROR", "NaN")))
    try:
        if fmt == "json":
            doc = parse_doc(text)
            if not isinstance(doc, list):
                raise IngestError("INGEST_ERROR", "JSON document must be an array")
            items = doc
        else:
            items = [parse_doc(line) for line in text.split("\n") if line.strip()]
    except json.JSONDecodeError as e:
        raise IngestError("INGEST_ERROR", str(e)) from e
    out = []
    for it in items:
        if not (isinstance(it, tuple) and it[0] == "__obj__"):
            raise IngestError("INGEST_ERROR", "element is not an object")
        out.append(it[1])
    return out


def load_json(text: str, fmt: str, schema: list[dict] | None = None):
    objs = _json_objects(text, fmt)
    names: list[str] = []
    lower: dict[str, int] = {}
    for o in objs:
        for k, _ in o:
            if k.lower() not in lower:
                lower[k.lower()] = len(names)
                names.append(k)
    if schema is not None:
        snames = [s["name"] for s in schema]
        sl = {s.lower(): i for i, s in enumerate(snames)}
        for k in lower:
            if k not in sl:
                raise IngestError("INGEST_ERROR", f"key {k} not in schema")
        names, lower = snames, sl
    cols: list[list[Any]] = [[] for _ in names]
    for o in objs:
        d = {k.lower(): v for k, v in o}
        for nm, idx in lower.items():
            cols[idx].append(d.get(nm))
    types: list[str] = []
    for c, vals in enumerate(cols):
        nn = [v for v in vals if v is not None]
        for v in nn:
            if isinstance(v, (list, tuple)) and v and v[0] == "__obj__" or isinstance(v, list):
                raise IngestError("INGEST_ERROR", "nested value")
        if schema is not None:
            types.append(canonical_type(schema[c]["type"]))
            continue
        if not nn:
            types.append("STRING")
        elif all(isinstance(v, bool) for v in nn):
            types.append("BOOLEAN")
        elif all(isinstance(v, tuple) and v[0] == "__num__" for v in nn):
            texts = [v[1] for v in nn]
            if all(RE_INT.match(t) and parse_int(t) is not None for t in texts):
                types.append("INT64")
            else:
                types.append("FLOAT64")
        elif all(isinstance(v, str) for v in nn):
            if all(parse_date(v) for v in nn):
                types.append("DATE")
            elif all(parse_date(v) or is_ts_text(v) for v in nn):
                types.append("TIMESTAMP")
            else:
                types.append("STRING")
        else:
            raise IngestError("INGEST_ERROR", "inconsistent JSON types")
    rows = []
    for r in range(len(objs)):
        row = []
        for c, typ in enumerate(types):
            v = cols[c][r]
            if v is None:
                row.append(None)
            elif isinstance(v, bool):
                if typ != "BOOLEAN":
                    raise IngestError("CONVERSION_ERROR", "bool")
                row.append(v)
            elif isinstance(v, tuple) and v[0] == "__num__":
                if typ in ("INT64", "FLOAT64") or typ.startswith("DECIMAL"):
                    row.append(convert_text(v[1], typ))
                else:
                    raise IngestError("CONVERSION_ERROR", "number")
            elif isinstance(v, str):
                if typ == "BOOLEAN":
                    raise IngestError("CONVERSION_ERROR", "string to bool")
                row.append(convert_text(v, typ))
            else:
                raise IngestError("INGEST_ERROR", "nested value")
        rows.append(row)
    return names, types, rows


# ------------------------------------------------------------------ serialization

def fmt_ts(v: dt.datetime) -> str:
    base = f"{v.year:04d}-{v.month:02d}-{v.day:02d} {v.hour:02d}:{v.minute:02d}:{v.second:02d}"
    return base + (f".{v.microsecond:06d}" if v.microsecond else "")


def fmt_date(v: dt.date) -> str:
    return f"{v.year:04d}-{v.month:02d}-{v.day:02d}"


def fmt_decimal(v: Decimal, scale: int) -> str:
    q = v.quantize(Decimal(1).scaleb(-scale), rounding=ROUND_HALF_UP)
    s = format(q, "f")
    if s.startswith("-") and Decimal(s) == 0:
        s = s[1:]
    return s


def serialize(v: Any, typ: str) -> Any:
    if v is None:
        return None
    if typ.startswith("DECIMAL"):
        return fmt_decimal(Decimal(str(v)) if not isinstance(v, Decimal) else v, dec_params(typ)[1])
    if typ == "DATE":
        return fmt_date(v) if isinstance(v, dt.date) else str(v)
    if typ == "TIMESTAMP":
        return fmt_ts(v) if isinstance(v, dt.datetime) else str(v)
    if typ == "FLOAT64":
        f = float(v)
        return 0.0 if f == 0 else f
    if typ == "INT64":
        return int(v)
    if typ == "BOOLEAN":
        return bool(v)
    return v


def days(d: dt.date) -> int:
    return (d - EPOCH).days


def micros(t: dt.datetime) -> int:
    delta = t - dt.datetime(1970, 1, 1)
    return delta.days * 86_400_000_000 + delta.seconds * 1_000_000 + delta.microseconds
