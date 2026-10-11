"""Expression rewrites of the logical optimizer: constant folding and
predicate simplification (applied only with ``optimize: true``).

* **Constant folding** evaluates every constant subexpression (no columns,
  aggregates, subqueries or ``PQ_SLEEP``) once at planning time and replaces
  it by a literal of the same type. An expression whose evaluation fails
  (``1/0``) is left alone, so the error is still raised exactly when (and
  only if) a row evaluates it.
* **Predicate simplification** applies the identities of three-valued logic
  that hold for every operand value: ``TRUE AND x`` → ``x``,
  ``FALSE OR x`` → ``x``, ``FALSE AND x`` → ``FALSE``, ``TRUE OR x`` → ``TRUE``
  (also with the literal on the right when ``x`` cannot raise an error),
  ``NOT NOT x`` → ``x``, comparisons with a NULL literal → NULL, CASE
  branches with constant conditions, and duplicate conjuncts. Filters whose
  predicate became ``TRUE`` disappear.
"""

from __future__ import annotations

from typing import Any, Callable

from .. import errors
from ..analysis import bound as b
from ..datatypes import BOOLEAN
from . import logical as lp

Evaluator = Callable[[b.Expr], Any]


class ExprSimplifier:
    def __init__(self, evaluate: Evaluator | None):
        self.evaluate = evaluate

    def simplify(self, expr: b.Expr) -> b.Expr:
        expr = b.map_children(expr, self.simplify)
        folded = self._fold(expr)
        if folded is not None:
            return folded
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

    def _fold(self, expr: b.Expr) -> b.Expr | None:
        if self.evaluate is None or isinstance(expr, b.Literal):
            return None
        if not b.is_constant(expr) or b.has_side_effects(expr):
            return None
        try:
            return b.Literal(expr.type, self.evaluate(expr))
        except errors.PolyQueryError:
            return None  # raised at run time, if a row evaluates it

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

    def predicate(self, expr: b.Expr) -> b.Expr | None:
        """A simplified filter / join predicate (None: always TRUE)."""
        parts: list[b.Expr] = []
        for p in b.conjuncts(self.simplify(expr)):
            if isinstance(p, b.Literal) and p.value is True:
                continue
            if p not in parts:
                parts.append(p)
        return b.conjunction(parts)


def _is_null(e: b.Expr) -> bool:
    return isinstance(e, b.Literal) and e.value is None


def simplify_plan(node: lp.LogicalNode, evaluate: Evaluator | None) -> lp.LogicalNode:
    """Simplifies every expression of a logical plan (in place)."""
    return _simplify(node, ExprSimplifier(evaluate))


def _simplify(node: lp.LogicalNode, s: ExprSimplifier) -> lp.LogicalNode:
    if isinstance(node, lp.Filter):
        child = _simplify(node.input, s)
        predicate = s.predicate(node.predicate)
        if predicate is None:
            return child
        node.input, node.predicate = child, predicate
        return node
    if isinstance(node, lp.Join):
        node.left = _simplify(node.left, s)
        node.right = _simplify(node.right, s)
        if node.condition is not None:
            node.condition = s.predicate(node.condition)
            if node.condition is None and node.kind == "INNER":
                node.kind = "CROSS"
            elif node.condition is None:  # LEFT JOIN ... ON TRUE
                node.condition = b.Literal(BOOLEAN, True)
        return node
    if isinstance(node, lp.Aggregate):
        node.input = _simplify(node.input, s)
        node.keys = [s.simplify(k) for k in node.keys]
        node.aggregates = [
            call if call.arg is None else b.AggCall(call.type, call.name, s.simplify(call.arg), call.distinct)
            for call in node.aggregates
        ]
        return node
    if isinstance(node, lp.Project):
        node.input = _simplify(node.input, s)
        node.exprs = [s.simplify(e) for e in node.exprs]
        return node
    if isinstance(node, (lp.Distinct, lp.Sort, lp.Limit, lp.SubqueryScan)):
        node.input = _simplify(node.input, s)
    elif isinstance(node, lp.UnionAll):
        node.branches = [_simplify(branch, s) for branch in node.branches]
    return node
