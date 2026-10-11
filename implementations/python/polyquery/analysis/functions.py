"""Function catalog: signatures, argument checking and result types
(spec/sql/functions.md). Runtime kernels live in ``execution.functions``."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from .. import errors
from ..datatypes import (
    FLOAT64,
    INT64,
    NULL,
    STRING,
    TIMESTAMP,
    DataType,
    TypeKind,
    comparable,
    comparison_type,
    decimal_result,
)
from . import bound as b
from .typing_rules import unify

AGGREGATE_FUNCTIONS = frozenset({"COUNT", "SUM", "MIN", "MAX", "AVG"})

DATE_TRUNC_UNITS = ("year", "month", "day", "hour", "minute")
DATE_DIFF_UNITS = ("day",)

# Evaluates a constant bound expression (provided by the execution layer).
ConstEvaluator = Callable[[b.Expr], Any]


@dataclass(frozen=True)
class ScalarFunction:
    name: str
    min_args: int
    max_args: int | None  # None = unbounded
    # Validates the arguments; returns the result type and the (possibly
    # promoted) arguments.
    resolve: Callable[[list[b.Expr], ConstEvaluator], tuple[DataType, list[b.Expr]]]
    test_only: bool = False


_NUMERIC = (TypeKind.INT64, TypeKind.DECIMAL, TypeKind.FLOAT64)
_TEMPORAL = (TypeKind.DATE, TypeKind.TIMESTAMP)


def _expect(arg: b.Expr, kinds: tuple[TypeKind, ...], fname: str) -> None:
    if arg.type.kind is not TypeKind.NULL and arg.type.kind not in kinds:
        raise errors.type_error(f"invalid argument type {arg.type.name} for {fname}")


def _constant(arg: b.Expr, fname: str, evaluate: ConstEvaluator) -> Any:
    if not b.is_constant(arg):
        raise errors.semantic_error(f"argument of {fname} must be a constant expression")
    return evaluate(arg)


def _numeric_type(arg: b.Expr) -> DataType:
    # "same type" as the argument: an untyped NULL stays the null type
    return arg.type


def _same_numeric(fname: str) -> Callable:
    def resolve(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
        _expect(args[0], _NUMERIC, fname)
        return _numeric_type(args[0]), args

    return resolve


def _round(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
    _expect(args[0], _NUMERIC, "ROUND")
    t = _numeric_type(args[0])
    n = 0
    if len(args) == 2:
        _expect(args[1], (TypeKind.INT64,), "ROUND")
        value = _constant(args[1], "ROUND", evaluate)
        n = t.scale if value is None else value
    if t.kind is TypeKind.DECIMAL:
        return decimal_result(max(0, min(n, t.scale)), t), args
    return t, args


def _floor_ceil(fname: str) -> Callable:
    def resolve(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
        _expect(args[0], _NUMERIC, fname)
        t = _numeric_type(args[0])
        if t.kind is TypeKind.DECIMAL:
            return decimal_result(0, t), args
        return t, args

    return resolve


def _fixed(arg_kinds: tuple[tuple[TypeKind, ...], ...], result: DataType, fname: str) -> Callable:
    def resolve(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
        for arg, kinds in zip(args, arg_kinds):
            _expect(arg, kinds, fname)
        return result, args

    return resolve


def _concat(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
    for arg in args:
        if arg.type.kind is TypeKind.FLOAT64:
            raise errors.type_error("CONCAT does not accept FLOAT64 arguments")
    return STRING, args


def _coalesce(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
    return unify(args, "COALESCE")


def _nullif(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
    a, c = args
    if not comparable(a.type, c.type):
        raise errors.type_error(f"NULLIF arguments {a.type.name} and {c.type.name} are not comparable")
    return a.type, args


def _unit(arg: b.Expr, fname: str, units: tuple[str, ...], evaluate: ConstEvaluator) -> None:
    _expect(arg, (TypeKind.STRING,), fname)
    unit = _constant(arg, fname, evaluate)
    if unit is not None and unit.lower() not in units:
        raise errors.invalid_argument(f"unsupported {fname} unit '{unit}'")


def _date_trunc(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
    _unit(args[0], "DATE_TRUNC", DATE_TRUNC_UNITS, evaluate)
    _expect(args[1], _TEMPORAL, "DATE_TRUNC")
    return TIMESTAMP, args


def _date_diff(args: list[b.Expr], evaluate: ConstEvaluator) -> tuple[DataType, list[b.Expr]]:
    _unit(args[0], "DATE_DIFF", DATE_DIFF_UNITS, evaluate)
    _expect(args[1], _TEMPORAL, "DATE_DIFF")
    _expect(args[2], _TEMPORAL, "DATE_DIFF")
    return INT64, args


_S, _I = (TypeKind.STRING,), (TypeKind.INT64,)

SCALAR_FUNCTIONS: dict[str, ScalarFunction] = {
    f.name: f
    for f in [
        ScalarFunction("ABS", 1, 1, _same_numeric("ABS")),
        ScalarFunction("ROUND", 1, 2, _round),
        ScalarFunction("FLOOR", 1, 1, _floor_ceil("FLOOR")),
        ScalarFunction("CEIL", 1, 1, _floor_ceil("CEIL")),
        ScalarFunction("CEILING", 1, 1, _floor_ceil("CEILING")),
        ScalarFunction("SQRT", 1, 1, _fixed((_NUMERIC,), FLOAT64, "SQRT")),
        ScalarFunction("POWER", 2, 2, _fixed((_NUMERIC, _NUMERIC), FLOAT64, "POWER")),
        ScalarFunction("MOD", 2, 2, _fixed((_I, _I), INT64, "MOD")),
        ScalarFunction("LENGTH", 1, 1, _fixed((_S,), INT64, "LENGTH")),
        ScalarFunction("UPPER", 1, 1, _fixed((_S,), STRING, "UPPER")),
        ScalarFunction("LOWER", 1, 1, _fixed((_S,), STRING, "LOWER")),
        ScalarFunction("SUBSTR", 2, 3, _fixed((_S, _I, _I), STRING, "SUBSTR")),
        ScalarFunction("SUBSTRING", 2, 3, _fixed((_S, _I, _I), STRING, "SUBSTRING")),
        ScalarFunction("TRIM", 1, 1, _fixed((_S,), STRING, "TRIM")),
        ScalarFunction("LTRIM", 1, 1, _fixed((_S,), STRING, "LTRIM")),
        ScalarFunction("RTRIM", 1, 1, _fixed((_S,), STRING, "RTRIM")),
        ScalarFunction("REPLACE", 3, 3, _fixed((_S, _S, _S), STRING, "REPLACE")),
        ScalarFunction("CONCAT", 1, None, _concat),
        ScalarFunction("COALESCE", 1, None, _coalesce),
        ScalarFunction("NULLIF", 2, 2, _nullif),
        ScalarFunction("YEAR", 1, 1, _fixed((_TEMPORAL,), INT64, "YEAR")),
        ScalarFunction("MONTH", 1, 1, _fixed((_TEMPORAL,), INT64, "MONTH")),
        ScalarFunction("DAY", 1, 1, _fixed((_TEMPORAL,), INT64, "DAY")),
        ScalarFunction("HOUR", 1, 1, _fixed(((TypeKind.TIMESTAMP,),), INT64, "HOUR")),
        ScalarFunction("MINUTE", 1, 1, _fixed(((TypeKind.TIMESTAMP,),), INT64, "MINUTE")),
        ScalarFunction("SECOND", 1, 1, _fixed(((TypeKind.TIMESTAMP,),), INT64, "SECOND")),
        ScalarFunction("DATE_TRUNC", 2, 2, _date_trunc),
        ScalarFunction("DATE_DIFF", 3, 3, _date_diff),
        ScalarFunction("PQ_SLEEP", 1, 1, _fixed((_I,), INT64, "PQ_SLEEP"), test_only=True),
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
        return decimal_result(t.scale, t)
    return t


def nullif_compare_type(a: DataType, c: DataType) -> DataType:
    """Type in which NULLIF compares its arguments."""
    return comparison_type([a, c]) or NULL
