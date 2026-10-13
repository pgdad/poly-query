"""The interfaces of logical optimizer rules.

A :class:`Rule` rewrites a logical tree (in place where convenient) and
returns its new root. An :class:`ExpressionRule` rewrites single expression
nodes; :class:`RewriteExpressions` applies expression rules to every
expression of a plan in one bottom-up pass.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import ClassVar

from ...analysis import bound as b
from ...datatypes import BOOLEAN
from .. import logical as lp


class Rule(ABC):
    name: ClassVar[str]

    @abstractmethod
    def apply(self, node: lp.LogicalNode) -> lp.LogicalNode:
        """The rewritten tree (``node`` may be modified)."""


class ExpressionRule(Rule):
    """A rewrite of one expression node whose children have already been
    rewritten. Applied on its own, it runs as a :class:`RewriteExpressions`
    pass; the optimizer fuses consecutive expression rules into one pass, so
    that an expression one rule produces is seen by the others at its parent
    (``NOT (FALSE AND x)``: simplification yields ``NOT FALSE``, which is
    then folded)."""

    @abstractmethod
    def rewrite(self, expr: b.Expr) -> b.Expr:
        """``expr`` rewritten, or ``expr`` itself."""

    def apply(self, node: lp.LogicalNode) -> lp.LogicalNode:
        return RewriteExpressions([self]).apply(node)


class RewriteExpressions(Rule):
    """Applies expression rules bottom-up to every expression of the plan,
    and normalises filter and join predicates afterwards: ``TRUE`` and
    duplicate conjuncts are dropped, a filter whose predicate became ``TRUE``
    disappears, an inner join whose condition became ``TRUE`` is a cross
    join."""

    name = "rewrite_expressions"

    def __init__(self, rules: list[ExpressionRule]):
        self.rules = rules

    def rewrite(self, expr: b.Expr) -> b.Expr:
        expr = b.map_children(expr, self.rewrite)
        for rule in self.rules:
            expr = rule.rewrite(expr)
        return expr

    def predicate(self, expr: b.Expr) -> b.Expr | None:
        """A rewritten filter / join predicate (None: always TRUE)."""
        parts: list[b.Expr] = []
        seen: set[b.Expr] = set()  # (hashing: long AND chains have many conjuncts)
        for p in b.conjuncts(self.rewrite(expr)):
            if isinstance(p, b.Literal) and p.value is True:
                continue
            if p not in seen:
                seen.add(p)
                parts.append(p)
        return b.conjunction(parts)

    def apply(self, node: lp.LogicalNode) -> lp.LogicalNode:
        if isinstance(node, lp.Filter):
            child = self.apply(node.input)
            predicate = self.predicate(node.predicate)
            if predicate is None:
                return child
            node.input, node.predicate = child, predicate
            return node
        if isinstance(node, lp.Join):
            node.left = self.apply(node.left)
            node.right = self.apply(node.right)
            if node.condition is not None:
                node.condition = self.predicate(node.condition)
                if node.condition is None and node.kind == "INNER":
                    node.kind = "CROSS"
                elif node.condition is None:  # LEFT JOIN ... ON TRUE
                    node.condition = b.Literal(BOOLEAN, True)
            return node
        if isinstance(node, lp.Aggregate):
            node.input = self.apply(node.input)
            node.keys = [self.rewrite(k) for k in node.keys]
            node.aggregates = [
                call if call.arg is None else b.AggCall(call.type, call.name, self.rewrite(call.arg), call.distinct)
                for call in node.aggregates
            ]
            return node
        if isinstance(node, lp.Project):
            node.input = self.apply(node.input)
            node.exprs = [self.rewrite(e) for e in node.exprs]
            return node
        if isinstance(node, (lp.Distinct, lp.Sort, lp.Limit, lp.SubqueryScan)):
            node.input = self.apply(node.input)
        elif isinstance(node, lp.UnionAll):
            node.branches = [self.apply(branch) for branch in node.branches]
        return node
