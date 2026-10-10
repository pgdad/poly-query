"""Logical rewrites: predicate pushdown (indexes-and-planning.md §3).

``WHERE`` / ``ON`` conjuncts are moved as close to the scans as the join
semantics allow; conjuncts referencing both sides of an inner join become join
conditions (from which the physical planner extracts hash-join keys).
Column references to relations outside the subtree (correlation parameters)
are treated as constants.
"""

from __future__ import annotations

from ..analysis import bound as b
from ..datatypes import BOOLEAN
from . import logical as lp


def conjuncts(expr: b.Expr | None) -> list[b.Expr]:
    if expr is None:
        return []
    if isinstance(expr, b.Logical) and expr.op == "AND":
        return conjuncts(expr.left) + conjuncts(expr.right)
    return [expr]


def conjunction(exprs: list[b.Expr]) -> b.Expr | None:
    result: b.Expr | None = None
    for e in exprs:
        result = e if result is None else b.Logical(BOOLEAN, "AND", result, e)
    return result


def _rels(expr: b.Expr, within: set[int]) -> set[int]:
    return {key[0] for key in b.column_keys(expr)} & within


def _wrap(node: lp.LogicalNode, predicates: list[b.Expr]) -> lp.LogicalNode:
    predicate = conjunction(predicates)
    return node if predicate is None else lp.Filter(node, predicate)


def optimize(node: lp.LogicalNode) -> lp.LogicalNode:
    return _push(node, [])


def _push(node: lp.LogicalNode, predicates: list[b.Expr]) -> lp.LogicalNode:
    if isinstance(node, lp.Filter):
        return _push(node.input, predicates + conjuncts(node.predicate))
    if isinstance(node, lp.Join):
        return _push_join(node, predicates)
    # stop here: optimize the subtree independently
    if isinstance(node, (lp.Aggregate, lp.Project, lp.Distinct, lp.Sort, lp.Limit, lp.SubqueryScan)):
        node.input = _push(node.input, [])
    return _wrap(node, predicates)


def _push_join(node: lp.Join, predicates: list[b.Expr]) -> lp.LogicalNode:
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
            kind, _push(node.left, to_left), _push(node.right, to_right), conjunction(in_join)
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
        node.kind, _push(node.left, to_left), _push(node.right, to_right), conjunction(in_join)
    )
    return _wrap(join, above)
