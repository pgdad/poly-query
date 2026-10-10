"""Runtime CAST implementations (types.md §8). Each function converts a
non-NULL value of the source type to the target type."""

from __future__ import annotations

import math
from typing import Any, Callable

from .. import errors, values
from ..datatypes import DataType, TypeKind

CastFn = Callable[[Any], Any]

_STRIP = " \t\r\n\f\v"


def identity(v: Any) -> Any:
    return v


def _int_to_decimal(target: DataType) -> CastFn:
    factor = values.POW10[target.scale]
    precision = target.precision

    def cast(v: int) -> int:
        return values.check_decimal(v * factor, precision)

    return cast


def _decimal_to_decimal(source: DataType, target: DataType) -> CastFn:
    s1, s2, precision = source.scale, target.scale, target.precision

    def cast(v: int) -> int:
        return values.check_decimal(values.rescale(v, s1, s2), precision)

    return cast


def _decimal_to_int(source: DataType) -> CastFn:
    divisor = values.POW10[source.scale]

    def cast(v: int) -> int:
        q = abs(v) // divisor
        return q if v >= 0 else -q

    return cast


def _decimal_to_float(source: DataType) -> CastFn:
    divisor = values.POW10[source.scale]
    return lambda v: v / divisor


def _decimal_to_string(source: DataType) -> CastFn:
    scale = source.scale
    return lambda v: values.format_decimal(v, scale)


def _float_to_int(v: float) -> int:
    r = math.trunc(v)
    if not values.INT64_MIN <= r <= values.INT64_MAX:
        raise errors.numeric_overflow(f"value {v!r} is out of INT64 range")
    return r


def _float_to_decimal(target: DataType) -> CastFn:
    scale, precision = target.scale, target.precision

    def cast(v: float) -> int:
        return values.check_decimal(values.float_to_decimal(v, scale), precision)

    return cast


def _string_to_bool(v: str) -> bool:
    r = values.parse_bool(v.strip(_STRIP))
    if r is None:
        raise errors.conversion_error(f"cannot convert '{v[:100]}' to BOOLEAN")
    return r


def _string_to_int(v: str) -> int:
    r = values.parse_int64(v.strip(_STRIP))
    if r is None:
        raise errors.conversion_error(f"cannot convert '{v[:100]}' to INT64")
    return values.check_int64(r)


def _string_to_float(v: str) -> float:
    r = values.parse_float(v.strip(_STRIP))
    if r is None:
        raise errors.conversion_error(f"cannot convert '{v[:100]}' to FLOAT64")
    return values.check_float(r)


def _string_to_decimal(target: DataType) -> CastFn:
    scale, precision = target.scale, target.precision

    def cast(v: str) -> int:
        r = values.parse_decimal_text(v.strip(_STRIP), scale, exact=False)
        if r is None:
            raise errors.conversion_error(f"cannot convert '{v[:100]}' to {target.name}")
        return values.check_decimal(r, precision)

    return cast


def _string_to_date(v: str) -> int:
    r = values.parse_date(v)
    if r is None:
        raise errors.conversion_error(f"cannot convert '{v[:100]}' to DATE")
    return r


def _string_to_timestamp(v: str) -> int:
    r = values.parse_timestamp(v, allow_date=False)
    if r is None:
        raise errors.conversion_error(f"cannot convert '{v[:100]}' to TIMESTAMP")
    return r


def cast_function(source: DataType, target: DataType) -> CastFn:
    """Returns the conversion for non-NULL values (legality checked at bind time)."""
    s, t = source.kind, target.kind
    K = TypeKind
    if s is t and s is not K.DECIMAL:
        return identity
    if s is K.BOOLEAN:
        if t is K.INT64:
            return int
        if t is K.STRING:
            return lambda v: "true" if v else "false"
    elif s is K.INT64:
        if t is K.BOOLEAN:
            return lambda v: v != 0
        if t is K.DECIMAL:
            return _int_to_decimal(target)
        if t is K.FLOAT64:
            return float
        if t is K.STRING:
            return str
    elif s is K.DECIMAL:
        if t is K.DECIMAL:
            if source.scale == target.scale and source.precision <= target.precision:
                return identity
            return _decimal_to_decimal(source, target)
        if t is K.INT64:
            return _decimal_to_int(source)
        if t is K.FLOAT64:
            return _decimal_to_float(source)
        if t is K.STRING:
            return _decimal_to_string(source)
    elif s is K.FLOAT64:
        if t is K.INT64:
            return _float_to_int
        if t is K.DECIMAL:
            return _float_to_decimal(target)
        if t is K.STRING:
            return values.format_float
    elif s is K.STRING:
        return {
            K.BOOLEAN: _string_to_bool,
            K.INT64: _string_to_int,
            K.FLOAT64: _string_to_float,
            K.DATE: _string_to_date,
            K.TIMESTAMP: _string_to_timestamp,
        }.get(t) or _string_to_decimal(target)
    elif s is K.DATE:
        if t is K.STRING:
            return values.format_date
        if t is K.TIMESTAMP:
            return values.date_to_timestamp
    elif s is K.TIMESTAMP:
        if t is K.STRING:
            return values.format_timestamp
        if t is K.DATE:
            return values.timestamp_to_date
    raise errors.type_error(f"cannot cast {source.name} to {target.name}")
