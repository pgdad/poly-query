"""SQL data types (spec/data-types/types.md §1-§2).

Runtime value representation (used by storage, execution and serialization):

=============  ==========================================================
Type           Python value
=============  ==========================================================
BOOLEAN        ``bool``
INT64          ``int`` (always within the signed 64-bit range)
FLOAT64        ``float`` (always finite)
DECIMAL(p,s)   ``int`` holding the *unscaled* value (value = int / 10**s)
STRING         ``str``
DATE           ``int`` days since 1970-01-01
TIMESTAMP      ``int`` microseconds since 1970-01-01 00:00:00
NULL           ``None`` (for every type)
=============  ==========================================================
"""

from __future__ import annotations

import enum
import re
from dataclasses import dataclass


class TypeKind(enum.Enum):
    NULL = "NULL"
    BOOLEAN = "BOOLEAN"
    INT64 = "INT64"
    FLOAT64 = "FLOAT64"
    DECIMAL = "DECIMAL"
    STRING = "STRING"
    DATE = "DATE"
    TIMESTAMP = "TIMESTAMP"


MAX_DECIMAL_PRECISION = 18


@dataclass(frozen=True, slots=True)
class DataType:
    kind: TypeKind
    precision: int = 0
    scale: int = 0

    def __str__(self) -> str:
        return self.name

    @property
    def name(self) -> str:
        """Canonical type name as reported in result metadata."""
        if self.kind is TypeKind.DECIMAL:
            return f"DECIMAL({self.precision},{self.scale})"
        if self.kind is TypeKind.NULL:
            # An expression whose type stays the null type is reported as STRING.
            return "STRING"
        return self.kind.value

    @property
    def is_null(self) -> bool:
        return self.kind is TypeKind.NULL

    @property
    def is_numeric(self) -> bool:
        return self.kind in _NUMERIC_KINDS

    @property
    def is_temporal(self) -> bool:
        return self.kind is TypeKind.DATE or self.kind is TypeKind.TIMESTAMP


_NUMERIC_KINDS = frozenset({TypeKind.INT64, TypeKind.DECIMAL, TypeKind.FLOAT64})

NULL = DataType(TypeKind.NULL)
BOOLEAN = DataType(TypeKind.BOOLEAN)
INT64 = DataType(TypeKind.INT64)
FLOAT64 = DataType(TypeKind.FLOAT64)
STRING = DataType(TypeKind.STRING)
DATE = DataType(TypeKind.DATE)
TIMESTAMP = DataType(TypeKind.TIMESTAMP)


class InvalidTypeError(ValueError):
    """Raised for unknown type names or invalid DECIMAL parameters."""


def decimal(precision: int, scale: int) -> DataType:
    if not (1 <= precision <= MAX_DECIMAL_PRECISION) or not (0 <= scale <= precision):
        raise InvalidTypeError(f"invalid DECIMAL parameters ({precision},{scale})")
    return DataType(TypeKind.DECIMAL, precision, scale)


_SIMPLE_TYPES = {
    "BOOLEAN": BOOLEAN,
    "BOOL": BOOLEAN,
    "INT64": INT64,
    "INT": INT64,
    "INTEGER": INT64,
    "BIGINT": INT64,
    "FLOAT64": FLOAT64,
    "DOUBLE": FLOAT64,
    "FLOAT": FLOAT64,
    "REAL": FLOAT64,
    "STRING": STRING,
    "VARCHAR": STRING,
    "TEXT": STRING,
    "DATE": DATE,
    "TIMESTAMP": TIMESTAMP,
}
_DECIMAL_NAMES = frozenset({"DECIMAL", "NUMERIC"})


def resolve_type(name: str, params: list[int] | None = None) -> DataType:
    """Resolves a type name (aliases allowed, case-insensitive) with optional parameters."""
    upper = name.upper()
    params = params or []
    if upper in _DECIMAL_NAMES:
        if len(params) > 2:
            raise InvalidTypeError(f"too many parameters for {name}")
        if not params:
            return decimal(MAX_DECIMAL_PRECISION, 0)
        precision = params[0]
        scale = params[1] if len(params) > 1 else 0
        return decimal(precision, scale)
    simple = _SIMPLE_TYPES.get(upper)
    if simple is None:
        raise InvalidTypeError(f"unknown type '{name}'")
    if params:
        raise InvalidTypeError(f"type {upper} takes no parameters")
    return simple


_TYPE_TEXT_RE = re.compile(
    r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*([0-9]+)\s*(?:,\s*([0-9]+)\s*)?\))?\s*"
)


def parse_type(text: str) -> DataType:
    """Parses a type string such as ``"DECIMAL(10, 2)"`` or ``"bigint"``."""
    m = _TYPE_TEXT_RE.fullmatch(text)
    if not m:
        raise InvalidTypeError(f"invalid type '{text}'")
    params = [int(g) for g in m.group(2, 3) if g is not None]
    return resolve_type(m.group(1), params)


def common_numeric_type(a: DataType, b: DataType) -> DataType:
    """Common type of two numeric types under the promotion lattice (types.md §2)."""
    if a.kind is TypeKind.FLOAT64 or b.kind is TypeKind.FLOAT64:
        return FLOAT64
    if a.kind is TypeKind.DECIMAL or b.kind is TypeKind.DECIMAL:
        return DataType(TypeKind.DECIMAL, MAX_DECIMAL_PRECISION, max(a.scale, b.scale))
    return INT64


def comparable(a: DataType, b: DataType) -> bool:
    """Whether values of the two types may be compared (types.md §2, §5)."""
    if a.is_null or b.is_null:
        return True
    if a.is_numeric and b.is_numeric:
        return True
    if a.is_temporal and b.is_temporal:
        return True
    return a.kind is b.kind


def common_type(types: list[DataType]) -> DataType | None:
    """Common super type for CASE/COALESCE-like constructs (semantics.md §13).

    Returns None if the types have no common type.
    """
    result = NULL
    for t in types:
        if t.is_null:
            continue
        if result.is_null or result == t:
            result = t
        elif result.is_numeric and t.is_numeric:
            result = common_numeric_type(result, t)
        elif result.is_temporal and t.is_temporal:
            result = TIMESTAMP if TIMESTAMP in (result, t) else DATE
        elif result.kind is t.kind:
            continue
        else:
            return None
    return result
