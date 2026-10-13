"""The rule-based logical optimizer: applies a sequence of named rules
(``rules/``) to every tree of a logical plan. It never looks at physical
properties (indexes, algorithms, execution modes); with ``optimize: false``
no rule is applied.

The default rule sequence:

1. :class:`ConstantFolding` and 2. :class:`PredicateSimplification`
   (expression rules, run together in one bottom-up pass);
3. :class:`PredicatePushdown`;
4. :class:`ColumnPruning`.
"""

from __future__ import annotations

from collections.abc import Sequence

from ..limits import Check, no_check
from . import logical as lp
from .rules import (
    ColumnPruning,
    ConstantFolding,
    ExpressionRule,
    PredicatePushdown,
    PredicateSimplification,
    RewriteExpressions,
    Rule,
)
from .rules.constant_folding import Evaluator


def default_rules(evaluate: Evaluator | None) -> list[Rule]:
    """The rules of ``optimize: true`` (constants are folded with ``evaluate``)."""
    folding: list[Rule] = [] if evaluate is None else [ConstantFolding(evaluate)]
    return folding + [PredicateSimplification(), PredicatePushdown(), ColumnPruning()]


class Optimizer:
    def __init__(self, rules: Sequence[Rule], check: Check = no_check):
        self.rules = list(rules)
        self.check = check  # the statement's deadline check

    @classmethod
    def for_options(cls, optimize: bool, evaluate: Evaluator | None, check: Check = no_check) -> Optimizer:
        return cls(default_rules(evaluate) if optimize else [], check)

    def optimize(self, plan: lp.LogicalPlan) -> lp.LogicalPlan:
        """``plan`` with every rule applied to each of its trees (the trees
        are modified)."""
        passes = _fuse_expression_rules(self.rules, self.check)
        root = plan.root
        for rule in passes:
            self.check()
            root = rule.apply(root)
        subqueries = dict(plan.subqueries)
        for id_ in subqueries:
            for rule in passes:
                self.check()
                subqueries[id_] = rule.apply(subqueries[id_])
        return lp.LogicalPlan(root, plan.columns, subqueries)


def _fuse_expression_rules(rules: list[Rule], check: Check = no_check) -> list[Rule]:
    """Consecutive expression rules become one RewriteExpressions pass
    (checking the deadline at every expression node)."""
    out: list[Rule] = []
    pending: list[ExpressionRule] = []
    for rule in rules:
        if isinstance(rule, ExpressionRule):
            pending.append(rule)
            continue
        if pending:
            out.append(RewriteExpressions(pending, check))
            pending = []
        out.append(rule)
    if pending:
        out.append(RewriteExpressions(pending, check))
    return out
