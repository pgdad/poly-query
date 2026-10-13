"""Predicate pushdown (indexes-and-planning.md §3.1).

``WHERE`` / ``ON`` conjuncts are moved as close to the scans as the join
semantics allow; conjuncts referencing both sides of an inner join become join
conditions (from which the physical planner extracts hash-join keys).
Column references to relations outside the subtree (correlation parameters)
are treated as constants.

Conjuncts on a derived table / CTE move below its projection (rewritten in
terms of the projection's input) when that cannot change which errors are
raised: the conjunct and every projected expression cannot fail (no
arithmetic, casts, function calls or subqueries), so evaluating the
conjunct earlier, on the same rows, only removes rows sooner.
"""

from __future__ import annotations

from ...analysis import bound as b
from ...limits import Check
from .. import logical as lp
from .base import Rule

conjuncts = b.conjuncts
conjunction = b.conjunction


class PredicatePushdown(Rule):
    name = "predicate_pushdown"

    def apply(self, node: lp.LogicalNode) -> lp.LogicalNode:
        return _push(node, [], self.check)


def _rels(expr: b.Expr, within: set[int]) -> set[int]:
    return {key[0] for key in b.column_keys(expr)} & within


def _wrap(node: lp.LogicalNode, predicates: list[b.Expr]) -> lp.LogicalNode:
    predicate = conjunction(predicates)
    return node if predicate is None else lp.Filter(node, predicate)


def _push(node: lp.LogicalNode, predicates: list[b.Expr], check: Check) -> lp.LogicalNode:
    """``node`` with ``predicates`` (conjuncts that held above it) applied
    as low as possible in its subtree. (Each join level examines every
    conjunct passing it: quadratic for long join chains, hence ``check``,
    the statement's deadline check, at every node.)"""
    check()
    if isinstance(node, lp.Filter):
        # the node's own conjuncts first: they guarded the ones from above
        return _push(node.input, conjuncts(node.predicate) + predicates, check)
    if isinstance(node, lp.Join):
        return _push_join(node, predicates, check)
    if isinstance(node, lp.SubqueryScan) and isinstance(node.input, lp.Project):
        return _push_projection(node, node.input, predicates, check)
    # stop here: optimize the subtree independently
    if isinstance(node, (lp.Aggregate, lp.Project, lp.Distinct, lp.Sort, lp.Limit, lp.SubqueryScan)):
        node.input = _push(node.input, [], check)
    elif isinstance(node, lp.UnionAll):
        node.branches = [_push(branch, [], check) for branch in node.branches]
    return _wrap(node, predicates)


def _push_join(node: lp.Join, predicates: list[b.Expr], check: Check) -> lp.LogicalNode:
    left_rels, right_rels = node.left.rels(), node.right.rels()
    both = left_rels | right_rels
    if node.kind in ("INNER", "CROSS"):
        to_left: list[b.Expr] = []
        to_right: list[b.Expr] = []
        in_join: list[b.Expr] = []
        for p in predicates + conjuncts(node.condition):
            rels = _rels(p, both)
            if rels <= left_rels:
                to_left.append(p)
            elif rels <= right_rels:
                to_right.append(p)
            else:
                in_join.append(p)
        kind = "INNER" if in_join else node.kind
        return lp.Join(
            kind, _push(node.left, to_left, check), _push(node.right, to_right, check), conjunction(in_join)
        )
    # LEFT JOIN: WHERE conjuncts on the preserved side go down the left input;
    # ON conjuncts on the right side only go down the right input.
    to_left, above = [], []
    for p in predicates:
        (to_left if _rels(p, both) <= left_rels else above).append(p)
    to_right, in_join = [], []
    for p in conjuncts(node.condition):
        rels = _rels(p, both)
        (to_right if rels and rels <= right_rels else in_join).append(p)
    join = lp.Join(
        node.kind, _push(node.left, to_left, check), _push(node.right, to_right, check), conjunction(in_join)
    )
    return _wrap(join, above)


def _push_projection(
    scan: lp.SubqueryScan, project: lp.Project, predicates: list[b.Expr], check: Check
) -> lp.LogicalNode:
    """Moves the conjuncts on a derived table below its projection where
    that is valid (see the module documentation); the others stay above."""
    below: list[b.Expr] = []
    above: list[b.Expr] = []
    if any(b.may_fail(e) for e in project.exprs):
        above = predicates
    else:
        outputs = {(scan.rel, i): e for i, e in enumerate(project.exprs)}
        for p in predicates:
            (above if b.may_fail(p) else below).append(p)
        below = [_substitute(p, outputs) for p in below]
    project.input = _push(project.input, below, check)
    return _wrap(scan, above)


def _substitute(expr: b.Expr, exprs: dict[b.ColumnKey, b.Expr]) -> b.Expr:
    """``expr`` with the column references in ``exprs`` replaced."""
    if isinstance(expr, b.ColumnRef):
        return exprs.get(expr.key, expr)
    return b.map_children(expr, lambda e: _substitute(e, exprs))
