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
    r = render_expr
    if isinstance(e, b.Literal):
        return _literal(e)
    if isinstance(e, b.ColumnRef):
        return e.name
    if isinstance(e, b.Unary):
        return ("-" if e.op == "neg" else "+") + r(e.operand)
    if isinstance(e, (b.Arith, b.Compare)):
        return f"({r(e.left)} {e.op} {r(e.right)})"
    if isinstance(e, b.Logical):
        return f"({r(e.left)} {e.op} {r(e.right)})"
    if isinstance(e, b.Concat):
        return f"({r(e.left)} || {r(e.right)})"
    if isinstance(e, b.Not):
        return f"(NOT {r(e.operand)})"
    if isinstance(e, b.IsNull):
        return f"({r(e.operand)} IS {'NOT ' if e.negated else ''}NULL)"
    if isinstance(e, b.Cast):
        return r(e.operand) if e.implicit else f"CAST({r(e.operand)} AS {e.type.name})"
    if isinstance(e, b.Like):
        return f"({r(e.operand)} {'NOT ' if e.negated else ''}LIKE {r(e.pattern)})"
    if isinstance(e, b.Between):
        neg = "NOT " if e.negated else ""
        return f"({r(e.operand)} {neg}BETWEEN {r(e.low)} AND {r(e.high)})"
    if isinstance(e, b.InList):
        neg = "NOT " if e.negated else ""
        return f"({r(e.operand)} {neg}IN ({', '.join(r(i) for i in e.items)}))"
    if isinstance(e, b.Case):
        parts = ["CASE"]
        for cond, result in e.whens:
            parts.append(f"WHEN {r(cond)} THEN {r(result)}")
        if e.else_ is not None:
            parts.append(f"ELSE {r(e.else_)}")
        parts.append("END")
        return " ".join(parts)
    if isinstance(e, b.Function):
        return f"{e.name}({', '.join(r(a) for a in e.args)})"
    if isinstance(e, b.AggCall):
        if e.arg is None:
            return f"{e.name}(*)"
        return f"{e.name}({'DISTINCT ' if e.distinct else ''}{r(e.arg)})"
    if isinstance(e, b.ScalarSubquery):
        return f"(subquery #{e.subquery.id})"
    if isinstance(e, b.Exists):
        return f"EXISTS(subquery #{e.subquery.id})"
    if isinstance(e, b.InSubquery):
        neg = "NOT " if e.negated else ""
        return f"({r(e.operand)} {neg}IN (subquery #{e.subquery.id}))"
    return type(e).__name__
