"""Static typing rules: operator result types, implicit promotion and CAST
legality (types.md §2, §4, §5, §8)."""

from __future__ import annotations

from .. import errors
from ..datatypes import (
    BOOLEAN,
    FLOAT64,
    INT64,
    MAX_DECIMAL_PRECISION,
    STRING,
    TIMESTAMP,
    DataType,
    TypeKind,
    common_numeric_type,
    common_type,
    comparable,
)
from . import bound as b

_ALL_KINDS = frozenset(TypeKind) - {TypeKind.NULL}

CAST_TARGETS: dict[TypeKind, frozenset[TypeKind]] = {
    TypeKind.NULL: _ALL_KINDS,
    TypeKind.BOOLEAN: frozenset({TypeKind.BOOLEAN, TypeKind.INT64, TypeKind.STRING}),
    TypeKind.INT64: frozenset(
        {TypeKind.BOOLEAN, TypeKind.INT64, TypeKind.DECIMAL, TypeKind.FLOAT64, TypeKind.STRING}
    ),
    TypeKind.DECIMAL: frozenset(
        {TypeKind.INT64, TypeKind.DECIMAL, TypeKind.FLOAT64, TypeKind.STRING}
    ),
    TypeKind.FLOAT64: frozenset(
        {TypeKind.INT64, TypeKind.DECIMAL, TypeKind.FLOAT64, TypeKind.STRING}
    ),
    TypeKind.STRING: _ALL_KINDS,
    TypeKind.DATE: frozenset({TypeKind.STRING, TypeKind.DATE, TypeKind.TIMESTAMP}),
    TypeKind.TIMESTAMP: frozenset({TypeKind.STRING, TypeKind.DATE, TypeKind.TIMESTAMP}),
}

DECIMAL_18_0 = DataType(TypeKind.DECIMAL, MAX_DECIMAL_PRECISION, 0)


def check_cast(source: DataType, target: DataType) -> None:
    if target.kind not in CAST_TARGETS[source.kind]:
        raise errors.type_error(f"cannot cast {source.name} to {target.name}")


def promote(expr: b.Expr, target: DataType) -> b.Expr:
    """Wraps ``expr`` in an implicit promotion to ``target`` if needed."""
    if expr.type == target or expr.type.is_null:
        return expr
    return b.Cast(target, expr, implicit=True)


def _numeric_operand(expr: b.Expr, op: str, other: DataType | None = None) -> DataType:
    """Type of an arithmetic operand. The untyped NULL literal takes the type of
    the other operand (INT64 if that is NULL, too)."""
    t = expr.type
    if t.is_null:
        return other if other is not None and other.is_numeric else INT64
    if not t.is_numeric:
        raise errors.type_error(f"operator {op} requires numeric operands, got {t.name}")
    return t


def arithmetic(op: str, left: b.Expr, right: b.Expr) -> b.Expr:
    lt = _numeric_operand(left, op, right.type)
    rt = _numeric_operand(right, op, left.type)
    if TypeKind.FLOAT64 in (lt.kind, rt.kind):
        if op == "%":
            raise errors.type_error("operator % requires INT64 operands")
        return b.Arith(FLOAT64, op, promote(left, FLOAT64), promote(right, FLOAT64))
    if TypeKind.DECIMAL in (lt.kind, rt.kind):
        if op == "%":
            raise errors.type_error("operator % requires INT64 operands")
        left = promote(left, DECIMAL_18_0) if lt.kind is TypeKind.INT64 else left
        right = promote(right, DECIMAL_18_0) if rt.kind is TypeKind.INT64 else right
        s1 = lt.scale if lt.kind is TypeKind.DECIMAL else 0
        s2 = rt.scale if rt.kind is TypeKind.DECIMAL else 0
        if op in ("+", "-"):
            result = DataType(TypeKind.DECIMAL, MAX_DECIMAL_PRECISION, max(s1, s2))
        elif op == "*":
            if s1 + s2 > MAX_DECIMAL_PRECISION:
                raise errors.type_error(
                    f"DECIMAL product scale {s1 + s2} exceeds {MAX_DECIMAL_PRECISION}"
                )
            result = DataType(TypeKind.DECIMAL, MAX_DECIMAL_PRECISION, s1 + s2)
        else:  # '/'
            result = FLOAT64
        return b.Arith(result, op, left, right)
    return b.Arith(INT64, op, left, right)


def negate(op: str, operand: b.Expr) -> b.Expr:
    """Unary minus/plus; preserves the operand's type (also the null type)."""
    t = operand.type if operand.type.is_null else _numeric_operand(operand, op)
    return b.Unary(t, "neg" if op == "-" else "pos", operand)


def comparison(op: str, left: b.Expr, right: b.Expr) -> b.Expr:
    lt, rt = left.type, right.type
    if not comparable(lt, rt):
        raise errors.type_error(f"cannot compare {lt.name} with {rt.name}")
    if lt.is_numeric and rt.is_numeric and lt != rt:
        common = common_numeric_type(lt, rt)
        if common.kind is TypeKind.FLOAT64:
            left, right = promote(left, FLOAT64), promote(right, FLOAT64)
        elif common.kind is TypeKind.DECIMAL:
            # an INT64 operand is promoted to DECIMAL(18, s) of the other side and
            # overflows if it then needs more than 18 digits (types.md §2);
            # two DECIMALs are compared exactly by value
            if lt.kind is TypeKind.INT64:
                left = promote(left, common)
            if rt.kind is TypeKind.INT64:
                right = promote(right, common)
    elif lt.is_temporal and rt.is_temporal and lt.kind is not rt.kind:
        left, right = promote(left, TIMESTAMP), promote(right, TIMESTAMP)
    return b.Compare(BOOLEAN, op, left, right)


def require_boolean(expr: b.Expr, what: str) -> b.Expr:
    if expr.type.kind not in (TypeKind.BOOLEAN, TypeKind.NULL):
        raise errors.type_error(f"{what} must be BOOLEAN, got {expr.type.name}")
    return expr


def logical(op: str, left: b.Expr, right: b.Expr) -> b.Expr:
    require_boolean(left, f"operand of {op}")
    require_boolean(right, f"operand of {op}")
    return b.Logical(BOOLEAN, op, left, right)


def concat(left: b.Expr, right: b.Expr) -> b.Expr:
    for e in (left, right):
        if e.type.kind not in (TypeKind.STRING, TypeKind.NULL):
            raise errors.type_error(f"operator || requires STRING operands, got {e.type.name}")
    return b.Concat(STRING, left, right)


def unify(exprs: list[b.Expr], what: str) -> tuple[DataType, list[b.Expr]]:
    """Common type of several expressions (CASE/COALESCE); promotes them to it."""
    result = common_type([e.type for e in exprs])
    if result is None:
        raise errors.type_error(f"incompatible types in {what}")
    return result, [promote(e, result) for e in exprs]
