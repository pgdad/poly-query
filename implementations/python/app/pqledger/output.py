"""The output formats table, csv and json (pqledger.md §7)."""

from __future__ import annotations

import datetime as dt
import json
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, TextIO

_NUMERIC = ("INT64", "FLOAT64", "DECIMAL")


@dataclass
class Table:
    """A result to print: column names, canonical type names and rows of
    native values (as returned by ``polyquery.Result``)."""

    columns: Sequence[str]
    types: Sequence[str]
    rows: Sequence[Sequence[Any]]


def kind(type_name: str) -> str:
    """``DECIMAL(18,2)`` → ``DECIMAL``."""
    return type_name.split("(", 1)[0]


def value_text(value: Any) -> str:
    """The value text of §7 (NULL: empty)."""
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, Decimal):
        return f"{value:f}"
    if isinstance(value, float):
        text = f"{value:.6f}"
        return "0.000000" if text == "-0.000000" else text
    if isinstance(value, dt.datetime):
        return value.isoformat(sep=" ")
    if isinstance(value, dt.date):
        return value.isoformat()
    return str(value)


def write_table(table: Table, out: TextIO) -> None:
    texts = [[value_text(v) for v in row] for row in table.rows]
    widths = [len(name) for name in table.columns]
    for row in texts:
        for i, text in enumerate(row):
            if len(text) > widths[i]:
                widths[i] = len(text)
    right = [kind(t) in _NUMERIC for t in table.types]

    def line(cells: Sequence[str]) -> str:
        parts = [c.rjust(w) if r else c.ljust(w) for c, w, r in zip(cells, widths, right)]
        return "  ".join(parts).rstrip(" ") + "\n"

    out.write(line(table.columns))
    out.write(line(["-" * w for w in widths]))
    for row in texts:
        out.write(line(row))
    n = len(texts)
    out.write("(1 row)\n" if n == 1 else f"({n} rows)\n")


def csv_field(value: Any) -> str:
    if value is None:
        return ""
    text = value_text(value)
    if (
        (text == "" and isinstance(value, str))
        or "," in text
        or '"' in text
        or "\r" in text
        or "\n" in text
        or text.startswith(" ")
        or text.endswith(" ")
    ):
        return '"' + text.replace('"', '""') + '"'
    return text


def write_csv(table: Table, out: TextIO) -> None:
    out.write(",".join(csv_field(name) for name in table.columns) + "\n")
    for row in table.rows:
        out.write(",".join(csv_field(v) for v in row) + "\n")


def json_string(text: str) -> str:
    """A JSON string: ``"`` ``\\`` and control characters escaped (short forms
    where JSON has them, else lowercase ``\\u00xx``), the rest raw UTF-8."""
    return json.dumps(text, ensure_ascii=False)


def _json_value(type_kind: str) -> Callable[[Any], str]:
    if type_kind in ("INT64", "FLOAT64"):
        return value_text
    if type_kind == "BOOLEAN":
        return lambda v: "true" if v else "false"
    return lambda v: json_string(value_text(v))


def write_json(table: Table, out: TextIO) -> None:
    keys = [json_string(name) + ":" for name in table.columns]
    encoders = [_json_value(kind(t)) for t in table.types]
    for row in table.rows:
        members = [k + ("null" if v is None else enc(v)) for k, enc, v in zip(keys, encoders, row)]
        out.write("{" + ",".join(members) + "}\n")


WRITERS: dict[str, Callable[[Table, TextIO], None]] = {"table": write_table, "csv": write_csv, "json": write_json}


def write(table: Table, fmt: str, out: TextIO) -> None:
    WRITERS[fmt](table, out)
