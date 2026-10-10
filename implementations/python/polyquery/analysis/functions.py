"""Function catalog: signatures and result types (spec/sql/functions.md)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from .. import errors
from ..datatypes import FLOAT64, INT64, DataType, TypeKind
from . import bound as b

AGGREGATE_FUNCTIONS = frozenset({"COUNT", "SUM", "MIN", "MAX", "AVG"})

# Scalar functions of the full v1 function set that this engine does not
# implement yet; calls to them are reported as UNSUPPORTED.
UNIMPLEMENTED_FUNCTIONS = frozenset(
    """ABS ROUND FLOOR CEIL CEILING SQRT POWER MOD LENGTH UPPER LOWER SUBSTR SUBSTRING
    TRIM LTRIM RTRIM REPLACE CONCAT COALESCE NULLIF YEAR MONTH DAY HOUR MINUTE SECOND
    DATE_TRUNC DATE_DIFF""".split()
)


@dataclass(frozen=True)
class ScalarFunction:
    name: str
    min_args: int
    max_args: int
    # Validates argument types; returns the result type.
    resolve: Callable[[list[b.Expr]], DataType]
    test_only: bool = False


def _expect(arg: b.Expr, kinds: tuple[TypeKind, ...], fname: str) -> None:
    if arg.type.kind is not TypeKind.NULL and arg.type.kind not in kinds:
        raise errors.type_error(f"invalid argument type {arg.type.name} for {fname}")


def _resolve_pq_sleep(args: list[b.Expr]) -> DataType:
    _expect(args[0], (TypeKind.INT64,), "PQ_SLEEP")
    return INT64


SCALAR_FUNCTIONS: dict[str, ScalarFunction] = {
    f.name: f
    for f in [
        ScalarFunction("PQ_SLEEP", 1, 1, _resolve_pq_sleep, test_only=True),
    ]
}


def aggregate_result_type(name: str, arg: b.Expr | None) -> DataType:
    """Result type of an aggregate call (functions.md §2)."""
    if name == "COUNT":
        return INT64
    assert arg is not None
    t = arg.type
    if name in ("MIN", "MAX"):
        return t
    if t.is_null:
        return INT64 if name == "SUM" else FLOAT64
    if not t.is_numeric:
        raise errors.type_error(f"{name} requires a numeric argument, got {t.name}")
    if name == "AVG":
        return FLOAT64
    if t.kind is TypeKind.DECIMAL:
        return DataType(TypeKind.DECIMAL, 18, t.scale)
    return t
