"""JSON array and JSON Lines ingestion (spec/data-types/ingestion.md §2)."""

from __future__ import annotations

import json
import re
from typing import Any

from .. import errors, values
from ..storage.catalog import Column
from ..datatypes import BOOLEAN, DATE, FLOAT64, INT64, STRING, TIMESTAMP, DataType, TypeKind
from .convert import TRIM_CHARS, InvalidText, converter_for
from .limits import MAX_FIELD_CHARS, IngestLimits, check_column_names

_SURROGATE_RE = re.compile("[\ud800-\udfff]")


class JsonNumber:
    """A JSON number that keeps its literal text (needed for INT64 vs FLOAT64
    inference and exact DECIMAL conversion)."""

    __slots__ = ("text", "is_integral")

    def __init__(self, text: str, is_integral: bool):
        self.text = text
        self.is_integral = is_integral


class JsonObject(list):
    """Key/value pairs of one JSON object, in document order."""


def _object_hook(pairs: list[tuple[str, Any]]) -> JsonObject:
    return JsonObject(pairs)


def _reject_constant(name: str) -> Any:
    raise ValueError(f"invalid JSON constant {name}")


_DECODER = json.JSONDecoder(
    object_pairs_hook=_object_hook,
    parse_int=lambda s: JsonNumber(s, True),
    parse_float=lambda s: JsonNumber(s, False),
    parse_constant=_reject_constant,
    strict=True,
)


def _parse(text: str, where: str) -> Any:
    try:
        return _DECODER.decode(text)
    except (ValueError, RecursionError) as e:
        raise errors.ingest_error(f"invalid JSON {where}: {e}") from None


def _records(text: str, fmt: str) -> list[JsonObject]:
    if text.startswith("﻿"):
        text = text[1:]
    if fmt == "json":
        doc = _parse(text, "document")
        if not isinstance(doc, list) or isinstance(doc, JsonObject):
            raise errors.ingest_error("JSON input must be an array of objects")
        for n, rec in enumerate(doc, 1):
            if not isinstance(rec, JsonObject):
                raise errors.ingest_error(f"JSON array element {n} is not an object", record=n)
        return doc
    records = []
    for line_no, line in enumerate(text.split("\n"), 1):
        line = line.strip()
        if not line:
            continue
        rec = _parse(line, f"on line {line_no}")
        if not isinstance(rec, JsonObject):
            raise errors.ingest_error(f"line {line_no} is not a JSON object", record=line_no)
        records.append(rec)
    return records


def _check_string(s: str, record: int) -> None:
    if len(s) > MAX_FIELD_CHARS:
        raise errors.ingest_error(f"field longer than 16 MiB in record {record}", record=record)
    if _SURROGATE_RE.search(s):
        raise errors.ingest_error(f"invalid Unicode (lone surrogate) in record {record}", record=record)


def _validate_value(v: Any, record: int) -> None:
    if isinstance(v, list):  # JsonObject is a list, too
        raise errors.ingest_error(f"nested object or array in record {record}", record=record)
    if isinstance(v, str):
        _check_string(v, record)


def _infer_json_type(column: list[Any], name: str) -> DataType:
    kinds = {type(v) for v in column if v is not None}
    if not kinds:
        return STRING
    if len(kinds) > 1:
        raise errors.ingest_error(f"inconsistent JSON value types in column '{name}'", column_name=name)
    kind = kinds.pop()
    if kind is bool:
        return BOOLEAN
    if kind is JsonNumber:
        if all(
            v.is_integral and values.INT64_MIN <= int(v.text) <= values.INT64_MAX
            for v in column
            if v is not None
        ):
            return INT64
        return FLOAT64
    texts = [v for v in column if v is not None]
    if all(values.is_date_text(t) for t in texts):
        return DATE
    if all(values.parse_timestamp(t, allow_date=True) is not None for t in texts):
        return TIMESTAMP
    return STRING


def _inferred_values(column: list[Any], dtype: DataType, name: str) -> list[Any]:
    if dtype.kind is TypeKind.INT64:
        return [None if v is None else int(v.text) for v in column]
    if dtype.kind is TypeKind.FLOAT64:
        out = []
        for v in column:
            if v is None:
                out.append(None)
                continue
            f = float(v.text)
            if f in (float("inf"), float("-inf")):
                raise errors.ingest_error(f"number {v.text[:50]} out of FLOAT64 range in column '{name}'")
            out.append(f)
        return out
    if dtype.kind is TypeKind.DATE:
        return [None if v is None else values.parse_date(v) for v in column]
    if dtype.kind is TypeKind.TIMESTAMP:
        return [None if v is None else values.parse_timestamp(v, allow_date=True) for v in column]
    return list(column)


_NUMBER_TARGETS = frozenset({TypeKind.INT64, TypeKind.FLOAT64, TypeKind.DECIMAL})


def _schema_values(column: list[Any], dtype: DataType, name: str) -> list[Any]:
    convert = converter_for(dtype)
    out: list[Any] = []
    for n, v in enumerate(column, 1):
        if v is None:
            out.append(None)
            continue
        try:
            if isinstance(v, bool):
                if dtype.kind is not TypeKind.BOOLEAN:
                    raise InvalidText
                out.append(v)
            elif isinstance(v, JsonNumber):
                if dtype.kind not in _NUMBER_TARGETS:
                    raise InvalidText
                out.append(convert(v.text))
            else:
                if dtype.kind is TypeKind.BOOLEAN:
                    raise InvalidText
                if dtype.kind is TypeKind.STRING:
                    out.append(v)
                else:
                    text = v.strip(TRIM_CHARS)
                    out.append(convert(text))
        except InvalidText:
            shown = v.text if isinstance(v, JsonNumber) else json.dumps(v)
            raise errors.conversion_error(
                f"cannot convert {shown[:100]} to {dtype.name} (record {n}, column '{name}')",
                record=n,
                column_name=name,
            ) from None
    return out


def ingest_json(
    text: str,
    fmt: str,
    schema: list[Column] | None,
    limits: IngestLimits,
) -> tuple[list[Column], list[list[Any]], int]:
    """Parses JSON / JSONL text into (columns, column data, row count)."""
    records = _records(text, fmt)
    limits.check_rows(len(records))

    if schema is not None:
        names = [c.name for c in schema]
        positions = {c.name.lower(): i for i, c in enumerate(schema)}
    else:
        names = []
        positions = {}

    rows: list[dict[int, Any]] = []
    width = len(names)
    for n, rec in enumerate(records, 1):
        row: dict[int, Any] = {}
        for key, value in rec:
            _check_string(key, n)
            _validate_value(value, n)
            pos = positions.get(key.lower())
            if pos is None:
                if schema is not None:
                    raise errors.ingest_error(f"key '{key}' (record {n}) is not in the schema", record=n)
                if key == "":
                    raise errors.ingest_error("empty column name", record=n)
                pos = len(names)
                positions[key.lower()] = pos
                names.append(key)
            elif pos in row or (schema is None and names[pos] != key):
                # duplicate key in one object, or a key that collides
                # case-insensitively with another column name
                raise errors.ingest_error(f"duplicate key '{key}' in record {n}", record=n)
            row[pos] = value
        rows.append(row)
        width = len(names)

    check_column_names(names)
    columns_raw: list[list[Any]] = [[r.get(i) for r in rows] for i in range(width)]

    if schema is not None:
        columns = schema
        data = [_schema_values(col, c.type, c.name) for col, c in zip(columns_raw, columns)]
    else:
        columns = []
        data = []
        for name, col in zip(names, columns_raw):
            dtype = _infer_json_type(col, name)
            columns.append(Column(name, dtype))
            data.append(_inferred_values(col, dtype, name))
    return columns, data, len(records)
