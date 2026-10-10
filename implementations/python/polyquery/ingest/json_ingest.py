"""JSON array and JSON Lines ingestion (spec/data-types/ingestion.md §2)."""

from __future__ import annotations

import json
import re
from typing import Any

from .. import errors, values
from ..datatypes import BOOLEAN, DATE, FLOAT64, INT64, STRING, TIMESTAMP, DataType, TypeKind
from ..names import fold
from ..storage.catalog import Column
from .convert import TRIM_CHARS, InvalidText, converter_for
from .limits import MAX_FIELD_CHARS, IngestLimits, check_column_names

_SURROGATE_RE = re.compile("[\ud800-\udfff]")
_INF = float("inf")


class JsonFloatText(str):
    """Literal text of a JSON number written with a fraction or exponent.

    Integral numbers are decoded to ``int``; keeping the text of the others
    allows exact DECIMAL conversion (ingestion.md §2.2).
    """


def _object_hook(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    obj = dict(pairs)
    if len(obj) != len(pairs):
        raise errors.ingest_error("duplicate key in JSON object")
    return obj


def _reject_constant(name: str) -> Any:
    raise ValueError(f"invalid JSON constant {name}")


_DECODER = json.JSONDecoder(
    object_pairs_hook=_object_hook,
    parse_float=JsonFloatText,
    parse_constant=_reject_constant,
    strict=True,
)


def _parse(text: str, where: str) -> Any:
    try:
        return _DECODER.decode(text)
    except (ValueError, RecursionError) as e:
        raise errors.ingest_error(f"invalid JSON {where}: {e}") from None
    except errors.PolyQueryError as e:
        raise errors.ingest_error(f"{e.message} {where}") from None


def _records(text: str, fmt: str) -> list[dict[str, Any]]:
    if text.startswith("﻿"):
        text = text[1:]
    if fmt == "json":
        doc = _parse(text, "in document")
        if not isinstance(doc, list):
            raise errors.ingest_error("JSON input must be an array of objects")
        for n, rec in enumerate(doc, 1):
            if not isinstance(rec, dict):
                raise errors.ingest_error(f"JSON array element {n} is not an object", record=n)
        return doc
    records = []
    for line_no, line in enumerate(text.split("\n"), 1):
        line = line.strip()
        if not line:
            continue
        rec = _parse(line, f"on line {line_no}")
        if not isinstance(rec, dict):
            raise errors.ingest_error(f"line {line_no} is not a JSON object", record=line_no)
        records.append(rec)
    return records


class _ColumnSet:
    """Maps the keys of JSON objects to columns (with or without a schema).

    Validation happens once per distinct key sequence, which is cheap because
    records of one input usually share their keys.
    """

    def __init__(self, schema: list[Column] | None):
        self.schema = schema
        self.names: list[str] = [c.name for c in schema] if schema else []
        self.by_folded: dict[str, int] = {fold(n): i for i, n in enumerate(self.names)}
        self.spellings: list[set[str]] = [set() for _ in self.names]
        self._seen: set[tuple[str, ...]] = set()

    def register(self, keys: tuple[str, ...], record: int) -> None:
        if keys in self._seen:
            return
        folded_in_record: set[str] = set()
        for key in keys:
            _check_string(key, record)
            folded = fold(key)
            if folded in folded_in_record:
                raise errors.ingest_error(f"duplicate key '{key}' in record {record}", record=record)
            folded_in_record.add(folded)
            pos = self.by_folded.get(folded)
            if pos is None:
                if self.schema is not None:
                    raise errors.ingest_error(
                        f"key '{key}' (record {record}) is not in the schema", record=record
                    )
                if key == "":
                    raise errors.ingest_error("empty column name", record=record)
                pos = len(self.names)
                self.by_folded[folded] = pos
                self.names.append(key)
                self.spellings.append(set())
            elif self.schema is None and self.names[pos] != key:
                raise errors.ingest_error(
                    f"keys '{self.names[pos]}' and '{key}' name the same column", record=record
                )
            self.spellings[pos].add(key)
        self._seen.add(keys)

    def extract(self, records: list[dict[str, Any]]) -> list[list[Any]]:
        columns = []
        for spellings in self.spellings:
            if not spellings:
                columns.append([None] * len(records))
            elif len(spellings) == 1:
                key = next(iter(spellings))
                columns.append([rec.get(key) for rec in records])
            else:
                columns.append([_first_present(rec, spellings) for rec in records])
        return columns


def _first_present(rec: dict[str, Any], keys: set[str]) -> Any:
    for k in keys:
        if k in rec:
            return rec[k]
    return None


def _check_string(s: str, record: int) -> None:
    if len(s) > MAX_FIELD_CHARS:
        raise errors.ingest_error(f"field longer than 16 MiB in record {record}", record=record)
    if _SURROGATE_RE.search(s):
        raise errors.ingest_error(f"invalid Unicode (lone surrogate) in record {record}", record=record)


def _validate_column(column: list[Any], name: str) -> set[type]:
    """Rejects nested values and invalid strings; returns the value types."""
    kinds = set(map(type, column))
    kinds.discard(type(None))
    if dict in kinds or list in kinds:
        raise errors.ingest_error(f"nested object or array in column '{name}'", column_name=name)
    if str in kinds:
        strings = [v for v in column if type(v) is str]
        if max(map(len, strings)) > MAX_FIELD_CHARS:
            raise errors.ingest_error(f"field longer than 16 MiB in column '{name}'", column_name=name)
        if _SURROGATE_RE.search("".join(strings)):
            raise errors.ingest_error(
                f"invalid Unicode (lone surrogate) in column '{name}'", column_name=name
            )
    return kinds


def _infer_json_type(column: list[Any], kinds: set[type], name: str) -> DataType:
    """Column type inference over the non-NULL values (§2.1)."""
    if not kinds:
        return STRING
    if kinds == {bool}:
        return BOOLEAN
    if kinds == {int}:
        ints = [v for v in column if v is not None]
        if values.INT64_MIN <= min(ints) and max(ints) <= values.INT64_MAX:
            return INT64
        return FLOAT64
    if kinds <= {int, JsonFloatText}:
        return FLOAT64
    if kinds == {str}:
        texts = {v for v in column if v is not None}
        if all(values.parse_date(t) is not None for t in texts):
            return DATE
        if all(values.parse_timestamp(t, allow_date=True) is not None for t in texts):
            return TIMESTAMP
        return STRING
    raise errors.ingest_error(f"inconsistent JSON value types in column '{name}'", column_name=name)


def _inferred_values(column: list[Any], dtype: DataType, name: str) -> list[Any]:
    kind = dtype.kind
    if kind is TypeKind.FLOAT64:
        try:
            out = [None if v is None else float(v) for v in column]
        except OverflowError:  # integer literal beyond the float range
            out = [_INF]
        if _INF in out or -_INF in out:
            raise errors.ingest_error(f"number out of FLOAT64 range in column '{name}'", column_name=name)
        return out
    if kind is TypeKind.DATE:
        return [None if v is None else values.parse_date(v) for v in column]
    if kind is TypeKind.TIMESTAMP:
        return [None if v is None else values.parse_timestamp(v, allow_date=True) for v in column]
    return column


_NUMBER_TARGETS = frozenset({TypeKind.INT64, TypeKind.FLOAT64, TypeKind.DECIMAL})


def _schema_value(v: Any, dtype: DataType, convert: Any) -> Any:
    """Converts one non-NULL JSON value to ``dtype`` (§2.2)."""
    kind = dtype.kind
    if type(v) is bool:
        if kind is not TypeKind.BOOLEAN:
            raise InvalidText
        return v
    if type(v) is int or type(v) is JsonFloatText:
        if kind not in _NUMBER_TARGETS:
            raise InvalidText
        # the number's literal text, converted with the CSV rules
        return convert(str(v))
    if kind is TypeKind.BOOLEAN:
        raise InvalidText
    if kind is TypeKind.STRING:
        return v
    return convert(v.strip(TRIM_CHARS))


def _schema_values(column: list[Any], dtype: DataType, name: str) -> list[Any]:
    convert = converter_for(dtype)
    out: list[Any] = []
    for n, v in enumerate(column, 1):
        if v is None:
            out.append(None)
            continue
        try:
            out.append(_schema_value(v, dtype, convert))
        except InvalidText:
            shown = str(v) if type(v) in (int, JsonFloatText) else json.dumps(v)
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

    column_set = _ColumnSet(schema)
    for n, rec in enumerate(records, 1):
        column_set.register(tuple(rec), n)
    check_column_names(column_set.names)
    raw_columns = column_set.extract(records)

    columns: list[Column] = []
    data: list[list[Any]] = []
    for i, (name, raw) in enumerate(zip(column_set.names, raw_columns)):
        kinds = _validate_column(raw, name)
        if schema is not None:
            columns.append(schema[i])
            data.append(_schema_values(raw, schema[i].type, schema[i].name))
        else:
            dtype = _infer_json_type(raw, kinds, name)
            columns.append(Column(name, dtype))
            data.append(_inferred_values(raw, dtype, name))
    return columns, data, len(records)
