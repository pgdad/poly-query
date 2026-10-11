"""Constant folding: every constant subexpression (no columns, aggregates,
subqueries or ``PQ_SLEEP``) is evaluated once at planning time and replaced
by a literal of the same type. An expression whose evaluation fails
(``1/0``) is left alone, so the error is still raised exactly when (and only
if) a row evaluates it."""

from __future__ import annotations

from typing import Any, Callable

from ... import errors
from ...analysis import bound as b
from .base import ExpressionRule

Evaluator = Callable[[b.Expr], Any]


class ConstantFolding(ExpressionRule):
    name = "constant_folding"

    def __init__(self, evaluate: Evaluator):
        self.evaluate = evaluate

    def rewrite(self, expr: b.Expr) -> b.Expr:
        if isinstance(expr, b.Literal) or not b.is_constant(expr) or b.has_side_effects(expr):
            return expr
        try:
            return b.Literal(expr.type, self.evaluate(expr))
        except errors.PolyQueryError:
            return expr  # raised at run time, if a row evaluates it
