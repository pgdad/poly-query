"""Predicate simplification: the identities of three-valued logic that hold
for every operand value. ``TRUE AND x`` → ``x``, ``FALSE OR x`` → ``x``,
``FALSE AND x`` → ``FALSE``, ``TRUE OR x`` → ``TRUE`` (also with the literal
on the right when ``x`` cannot raise an error), ``NOT NOT x`` → ``x``,
comparisons with a NULL literal → NULL, and CASE branches with constant
conditions. (Dropping ``TRUE`` and duplicate conjuncts, and filters that
became ``TRUE``, is done by the :class:`~.base.RewriteExpressions` pass.)"""

from __future__ import annotations

from ...analysis import bound as b
from ...datatypes import BOOLEAN
from .base import ExpressionRule


class PredicateSimplification(ExpressionRule):
    name = "predicate_simplification"

    def rewrite(self, expr: b.Expr) -> b.Expr:
        if isinstance(expr, b.Logical):
            return self._logical(expr)
        if isinstance(expr, b.Not) and isinstance(expr.operand, b.Not):
            return expr.operand.operand
        if isinstance(expr, b.Compare) and (_is_null(expr.left) or _is_null(expr.right)):
            if not b.may_fail(expr):
                return b.Literal(expr.type, None)
        if isinstance(expr, b.Case):
            return self._case(expr)
        return expr

    def _logical(self, e: b.Logical) -> b.Expr:
        # identity / absorbing element of the operator
        identity, absorbing = (True, False) if e.op == "AND" else (False, True)
        for this, other, on_left in ((e.left, e.right, True), (e.right, e.left, False)):
            if not (isinstance(this, b.Literal) and this.type.kind is BOOLEAN.kind):
                continue
            if this.value is identity:
                return other
            if this.value is absorbing and (on_left or not b.may_fail(other)):
                return this
        return e

    def _case(self, e: b.Case) -> b.Expr:
        whens: list[tuple[b.Expr, b.Expr]] = []
        for cond, result in e.whens:
            if isinstance(cond, b.Literal):
                if cond.value is True:
                    if not whens and result.type == e.type:
                        return result  # the first branch always applies
                    whens.append((cond, result))
                    break
                continue  # FALSE / NULL: never taken
            whens.append((cond, result))
        if not whens:
            if e.else_ is None:
                return b.Literal(e.type, None)
            if e.else_.type == e.type:
                return e.else_
            return e
        if len(whens) == len(e.whens):
            return e
        return b.Case(e.type, tuple(whens), e.else_)


def _is_null(e: b.Expr) -> bool:
    return isinstance(e, b.Literal) and e.value is None
