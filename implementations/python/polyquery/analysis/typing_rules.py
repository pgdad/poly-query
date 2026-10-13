"""Static typing rules: operator result types, implicit promotion and CAST
legality (types.md §2, §4, §5, §8)."""

from __future__ import annotations

from .. import errors
from ..datatypes import (
    BOOLEAN,
    FLOAT64,
    INT64,
    COMPARISON_PRECISION,
    NULL,
    STRING,
    TIMESTAMP,
    DataType,
    TypeKind,
    common_numeric_type,
    common_type,
    comparable,
    comparison_type,
    decimal_result,
    result_precision,
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

def check_cast(source: DataType, target: DataType) -> None:
    if target.kind not in CAST_TARGETS[source.kind]:
        raise errors.type_error(f"cannot cast {source.name} to {target.name}")


def promote(expr: b.Expr, target: DataType) -> b.Expr:
    """Wraps ``expr`` in an implicit promotion to ``target`` if needed."""
    if expr.type == target or expr.type.is_null:
        return expr
    return b.Cast(target, expr, implicit=True)


def promote_compared(expr: b.Expr, target: DataType) -> b.Expr:
    """Promotes an operand to the comparison type ``target``. DECIMAL
    operands that already have the target scale are left alone: their
    unscaled values compare directly (which keeps column references
    visible to index and native-kernel planning)."""
    t = expr.type
    if t.kind is TypeKind.DECIMAL and target.kind is TypeKind.DECIMAL and t.scale == target.scale:
        return expr
    return promote(expr, target)


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
        # W = 38 as soon as one DECIMAL operand is wide (decimal38.md §2); an
        # INT64 operand is promoted to DECIMAL(W, 0)
        width = result_precision(lt, rt)
        int_decimal = DataType(TypeKind.DECIMAL, width, 0)
        left = promote(left, int_decimal) if lt.kind is TypeKind.INT64 else left
        right = promote(right, int_decimal) if rt.kind is TypeKind.INT64 else right
        s1 = lt.scale if lt.kind is TypeKind.DECIMAL else 0
        s2 = rt.scale if rt.kind is TypeKind.DECIMAL else 0
        if op in ("+", "-"):
            result = decimal_result(max(s1, s2), lt, rt)
        elif op == "*":
            if s1 + s2 > width:
                raise errors.type_error(f"DECIMAL product scale {s1 + s2} exceeds {width}")
            result = decimal_result(s1 + s2, lt, rt)
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
            # INT64 and DECIMAL values compare exactly (decimal38.md §4): an
            # INT64 operand is promoted to the overflow-free comparison
            # precision at the other side's scale; two DECIMALs are compared
            # exactly by value whatever their scales
            exact = DataType(TypeKind.DECIMAL, COMPARISON_PRECISION, common.scale)
            if lt.kind is TypeKind.INT64:
                left = promote(left, exact)
            if rt.kind is TypeKind.INT64:
                right = promote(right, exact)
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


def union_type(types: list[DataType]) -> DataType | None:
    """Common type of a UNION ALL output column (the CASE rule, semantics.md
    §13): numeric promotion, otherwise one type; untyped NULL columns adopt
    the others' type (all NULL ⇒ the NULL type). None if there is none."""
    result = NULL
    for t in types:
        if t.is_null or t == result:
            continue
        if result.is_null:
            result = t
        elif result.is_numeric and t.is_numeric:
            result = common_numeric_type(result, t)
        else:
            return None
    return result


def _common_comparison_type(exprs: list[b.Expr], what: str) -> DataType:
    types = [e.type for e in exprs]
    # pairwise over the distinct types (an IN list may have many items)
    distinct = list(dict.fromkeys(types))
    for i, t in enumerate(distinct):
        for u in distinct[i + 1 :]:
            if not comparable(t, u):
                raise errors.type_error(f"cannot compare {t.name} with {u.name} in {what}")
    result = comparison_type(types)
    assert result is not None
    return result


def between(operand: b.Expr, low: b.Expr, high: b.Expr, negated: bool) -> b.Expr:
    t = _common_comparison_type([operand, low, high], "BETWEEN")
    return b.Between(
        BOOLEAN,
        promote_compared(operand, t),
        promote_compared(low, t),
        promote_compared(high, t),
        negated,
    )


def in_list(operand: b.Expr, items: list[b.Expr], negated: bool) -> b.Expr:
    t = _common_comparison_type([operand, *items], "IN")
    return b.InList(
        BOOLEAN, promote_compared(operand, t), tuple(promote_compared(i, t) for i in items), negated
    )


def in_subquery_type(operand: b.Expr, column_type: DataType) -> DataType:
    """Common type in which ``operand IN (subquery)`` compares values."""
    return _common_comparison_type([operand, b.Literal(column_type, None)], "IN")


def like(operand: b.Expr, pattern: b.Expr, negated: bool) -> b.Expr:
    for e in (operand, pattern):
        if e.type.kind not in (TypeKind.STRING, TypeKind.NULL):
            raise errors.type_error(f"LIKE requires STRING operands, got {e.type.name}")
    return b.Like(BOOLEAN, operand, pattern, negated)


def case(whens: list[tuple[b.Expr, b.Expr]], else_: b.Expr | None) -> b.Expr:
    for cond, _ in whens:
        require_boolean(cond, "CASE WHEN condition")
    results = [r for _, r in whens] + ([else_] if else_ is not None else [])
    result_type, promoted = unify(results, "CASE")
    new_whens = tuple((cond, promoted[i]) for i, (cond, _) in enumerate(whens))
    new_else = promoted[-1] if else_ is not None else None
    return b.Case(result_type, new_whens, new_else)
