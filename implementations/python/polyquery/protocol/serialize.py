"""Canonical JSON serialization of result values (types.md §9)."""

from __future__ import annotations

import json
from typing import Any, Callable

from .. import values
from ..datatypes import DataType, TypeKind
from ..storage.catalog import Column


def _float(v: float) -> float:
    return v + 0.0  # normalizes -0.0 to 0.0


def value_serializer(dtype: DataType) -> Callable[[Any], Any] | None:
    """Returns a converter for non-NULL values, or None when values are
    already JSON-ready."""
    kind = dtype.kind
    if kind is TypeKind.FLOAT64:
        return _float
    if kind is TypeKind.DECIMAL:
        scale = dtype.scale
        return lambda v: values.format_decimal(v, scale)
    if kind is TypeKind.DATE:
        return values.format_date
    if kind is TypeKind.TIMESTAMP:
        return values.format_timestamp
    return None


def serialize_value(v: Any, dtype: DataType) -> Any:
    if v is None:
        return None
    convert = value_serializer(dtype)
    return v if convert is None else convert(v)


def row_serializer(columns: list[Column]) -> Callable[[list[tuple]], list[Any]]:
    """Returns a function serializing batches of rows of the given columns.
    Values are converted column by column (one C-level ``map`` per column)
    and the rows are rebuilt as lists."""
    converters = [value_serializer(c.type) for c in columns]
    if all(c is None for c in converters):
        return lambda rows: rows

    def column(values: tuple, convert: Callable[[Any], Any] | None) -> Any:
        if convert is None:
            return values
        if None in values:
            return [None if v is None else convert(v) for v in values]
        return map(convert, values)

    def serialize(rows: list[tuple]) -> list[Any]:
        if not rows:
            return rows
        return list(map(list, zip(*map(column, zip(*rows), converters))))

    return serialize


def serialize_rows(columns: list[Column], rows: list[tuple]) -> list[Any]:
    return row_serializer(columns)(rows)


def dumps(obj: Any) -> str:
    """One-line JSON text; non-ASCII is escaped so output is always valid UTF-8."""
    return json.dumps(obj, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
