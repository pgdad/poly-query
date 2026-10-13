"""Human-readable rendering of bound expressions for EXPLAIN output."""

from __future__ import annotations

import json

from .. import values
from ..analysis import bound as b
from ..datatypes import TypeKind


def _literal(e: b.Literal) -> str:
    v, kind = e.value, e.type.kind
    if v is None:
        return "NULL"
    if kind is TypeKind.BOOLEAN:
        return "TRUE" if v else "FALSE"
    if kind is TypeKind.STRING:
        return "'" + v.replace("'", "''") + "'"
    if kind is TypeKind.DECIMAL:
        return values.format_decimal(v, e.type.scale)
    if kind is TypeKind.DATE:
        return f"DATE '{values.format_date(v)}'"
    if kind is TypeKind.TIMESTAMP:
        return f"TIMESTAMP '{values.format_timestamp(v)}'"
    if kind is TypeKind.FLOAT64:
        return json.dumps(v)
    return str(v)


def render_expr(e: b.Expr) -> str:
    """``e`` as SQL-like text. The pieces are collected in one list and
    joined once: nesting f-strings would copy the text of every subtree at
    each level, quadratic for long operator chains."""
    out: list[str] = []
    _render(e, out)
    return "".join(out)


def _render(e: b.Expr, out: list[str]) -> None:
    r, emit = _render, out.append
    if isinstance(e, b.Literal):
        emit(_literal(e))
    elif isinstance(e, b.ColumnRef):
        emit(e.name)
    elif isinstance(e, b.Unary):
        emit("-" if e.op == "neg" else "+")
        r(e.operand, out)
    elif isinstance(e, (b.Arith, b.Compare, b.Logical, b.Concat)):
        emit("(")
        r(e.left, out)
        emit(" || " if isinstance(e, b.Concat) else f" {e.op} ")
        r(e.right, out)
        emit(")")
    elif isinstance(e, b.Not):
        emit("(NOT ")
        r(e.operand, out)
        emit(")")
    elif isinstance(e, b.IsNull):
        emit("(")
        r(e.operand, out)
        emit(f" IS {'NOT ' if e.negated else ''}NULL)")
    elif isinstance(e, b.Cast):
        if e.implicit:
            r(e.operand, out)
        else:
            emit("CAST(")
            r(e.operand, out)
            emit(f" AS {e.type.name})")
    elif isinstance(e, b.Like):
        emit("(")
        r(e.operand, out)
        emit(f" {'NOT ' if e.negated else ''}LIKE ")
        r(e.pattern, out)
        emit(")")
    elif isinstance(e, b.Between):
        emit("(")
        r(e.operand, out)
        emit(f" {'NOT ' if e.negated else ''}BETWEEN ")
        r(e.low, out)
        emit(" AND ")
        r(e.high, out)
        emit(")")
    elif isinstance(e, b.InList):
        emit("(")
        r(e.operand, out)
        emit(f" {'NOT ' if e.negated else ''}IN (")
        _render_list(e.items, out)
        emit("))")
    elif isinstance(e, b.Case):
        emit("CASE")
        for cond, result in e.whens:
            emit(" WHEN ")
            r(cond, out)
            emit(" THEN ")
            r(result, out)
        if e.else_ is not None:
            emit(" ELSE ")
            r(e.else_, out)
        emit(" END")
    elif isinstance(e, b.Function):
        emit(f"{e.name}(")
        _render_list(e.args, out)
        emit(")")
    elif isinstance(e, b.AggCall):
        if e.arg is None:
            emit(f"{e.name}(*)")
        else:
            emit(f"{e.name}({'DISTINCT ' if e.distinct else ''}")
            r(e.arg, out)
            emit(")")
    elif isinstance(e, b.ScalarSubquery):
        emit(f"(subquery #{e.subquery.id})")
    elif isinstance(e, b.Exists):
        emit(f"EXISTS(subquery #{e.subquery.id})")
    elif isinstance(e, b.InSubquery):
        emit("(")
        r(e.operand, out)
        emit(f" {'NOT ' if e.negated else ''}IN (subquery #{e.subquery.id}))")
    else:
        emit(type(e).__name__)


def _render_list(items: tuple[b.Expr, ...], out: list[str]) -> None:
    for i, item in enumerate(items):
        if i:
            out.append(", ")
        _render(item, out)
