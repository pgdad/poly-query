"""Text -> value conversion and type inference shared by CSV and JSON ingestion
(spec/data-types/ingestion.md §1.1, §1.2)."""

from __future__ import annotations

from typing import Any, Callable

from .. import errors, values
from ..datatypes import BOOLEAN, DATE, FLOAT64, INT64, STRING, TIMESTAMP, DataType, TypeKind

# A converter maps trimmed field text to a value, or raises _Invalid.
Converter = Callable[[str], Any]

TRIM_CHARS = " \t"


class InvalidText(Exception):
    """The text is not acceptable for the target type."""


def _convert_bool(text: str) -> bool:
    v = values.parse_bool(text)
    if v is None:
        raise InvalidText
    return v


def _convert_int(text: str) -> int:
    v = values.parse_int64(text)
    if v is None or not (values.INT64_MIN <= v <= values.INT64_MAX):
        raise InvalidText
    return v


def _convert_float(text: str) -> float:
    v = values.parse_float(text)
    if v is None or v != v or v in (float("inf"), float("-inf")):
        raise InvalidText
    return v


def _convert_date(text: str) -> int:
    v = values.parse_date(text)
    if v is None:
        raise InvalidText
    return v


def _convert_timestamp(text: str) -> int:
    v = values.parse_timestamp(text, allow_date=True)
    if v is None:
        raise InvalidText
    return v


def _decimal_converter(dtype: DataType) -> Converter:
    precision, scale = dtype.precision, dtype.scale

    def convert(text: str) -> int:
        try:
            v = values.parse_decimal_text(text, scale, exact=True)
        except errors.PolyQueryError:
            raise InvalidText from None
        if v is None or not values.decimal_fits(v, precision):
            raise InvalidText
        return v

    return convert


_CONVERTERS: dict[TypeKind, Converter] = {
    TypeKind.BOOLEAN: _convert_bool,
    TypeKind.INT64: _convert_int,
    TypeKind.FLOAT64: _convert_float,
    TypeKind.DATE: _convert_date,
    TypeKind.TIMESTAMP: _convert_timestamp,
    TypeKind.STRING: lambda text: text,
}


def converter_for(dtype: DataType) -> Converter:
    """Converter for trimmed text of a non-STRING column (STRING is identity)."""
    if dtype.kind is TypeKind.DECIMAL:
        return _decimal_converter(dtype)
    return _CONVERTERS[dtype.kind]


def _matches(texts: set[str], convert: Converter) -> bool:
    try:
        for t in texts:
            convert(t)
    except InvalidText:
        return False
    return True


def infer_text_type(texts: set[str]) -> DataType:
    """Infers a CSV column type from its distinct, trimmed, non-empty texts (§1.1)."""
    if not texts:
        return STRING
    for dtype in (BOOLEAN, INT64, FLOAT64, DATE):
        if _matches(texts, _CONVERTERS[dtype.kind]):
            return dtype
    if _matches(texts, _convert_timestamp):
        return TIMESTAMP
    return STRING


def is_date_or_timestamp_text(text: str) -> bool:
    return values.parse_timestamp(text, allow_date=True) is not None
