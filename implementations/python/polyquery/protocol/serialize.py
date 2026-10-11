"""Canonical JSON serialization of result values (types.md §9)."""

from __future__ import annotations

import json
import operator
from itertools import repeat
from typing import Any, Callable, Iterable, Sequence

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


def column_serializer(dtype: DataType) -> Callable[[Sequence[Any]], Iterable[Any]] | None:
    """Returns a converter for a whole column of non-NULL values whose
    per-value work runs in C (``map`` over builtins and bound ``str.format``),
    or None when values are already JSON-ready."""
    convert = value_serializer(dtype)
    if convert is None:
        return None
    kind = dtype.kind
    if kind is TypeKind.FLOAT64:
        return lambda vals: map(operator.add, vals, repeat(0.0))  # -0.0 -> 0.0
    if kind is TypeKind.DECIMAL:
        if dtype.scale == 0:
            return lambda vals: map(str, vals)
        divisor = values.POW10[dtype.scale]
        text = ("{}.{:0" + str(dtype.scale) + "d}").format

        def decimals(vals: Sequence[Any]) -> Iterable[Any]:
            if min(vals) < 0:
                return map(convert, vals)
            return map(text, map(operator.floordiv, vals, repeat(divisor)), map(operator.mod, vals, repeat(divisor)))

        return decimals
    return lambda vals: map(convert, vals)


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
    column_converters = [column_serializer(c.type) for c in columns]

    def column(values: tuple, convert: Callable[[Any], Any] | None, convert_all: Any) -> Any:
        if convert is None:
            return values
        if None in values:
            return [None if v is None else convert(v) for v in values]
        return convert_all(values)

    def serialize(rows: list[tuple]) -> list[Any]:
        if not rows:
            return rows
        return list(map(list, zip(*map(column, zip(*rows), converters, column_converters))))

    return serialize


def serialize_rows(columns: list[Column], rows: list[tuple]) -> list[Any]:
    return row_serializer(columns)(rows)


def dumps(obj: Any) -> str:
    """One-line JSON text; non-ASCII is escaped so output is always valid UTF-8."""
    return json.dumps(obj, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
