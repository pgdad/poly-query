"""Logical rewrites: expression simplification (``rewrite``), predicate
pushdown (indexes-and-planning.md §3) and column pruning.

``WHERE`` / ``ON`` conjuncts are moved as close to the scans as the join
semantics allow; conjuncts referencing both sides of an inner join become join
conditions (from which the physical planner extracts hash-join keys).
Column references to relations outside the subtree (correlation parameters)
are treated as constants.
"""

from __future__ import annotations

from ..analysis import bound as b
from . import logical as lp
from .rewrite import Evaluator, simplify_plan


conjuncts = b.conjuncts
conjunction = b.conjunction


def _rels(expr: b.Expr, within: set[int]) -> set[int]:
    return {key[0] for key in b.column_keys(expr)} & within


def _wrap(node: lp.LogicalNode, predicates: list[b.Expr]) -> lp.LogicalNode:
    predicate = conjunction(predicates)
    return node if predicate is None else lp.Filter(node, predicate)


def optimize(node: lp.LogicalNode, evaluate: Evaluator | None = None) -> lp.LogicalNode:
    """Expression simplification (constant folding needs ``evaluate``), then
    predicate pushdown."""
    return _push(simplify_plan(node, evaluate), [])


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


# ------------------------------------------------------------------ column pruning


def prune_columns(node: lp.LogicalNode) -> lp.LogicalNode:
    """Restricts every scan to the columns the plan above it needs
    (indexes-and-planning.md §3.2). Output columns of a derived table / CTE
    that the enclosing query never reads are replaced by NULL when they are
    plain column references or literals (which can neither fail nor have
    side effects), so their source columns are not read either."""
    _prune(node, set(node.layout))
    return node


def _keys(exprs: list[b.Expr]) -> set[b.ColumnKey]:
    out: set[b.ColumnKey] = set()
    for e in exprs:
        out |= b.column_keys(e)
    return out


def _prune(node: lp.LogicalNode, required: set[b.ColumnKey]) -> None:
    if isinstance(node, lp.Scan):
        node.columns = [i for i in node.columns if (node.rel, i) in required]
    elif isinstance(node, lp.SubqueryScan):
        layout = node.input.layout
        _prune(node.input, {layout[i] for i in range(node.width) if (node.rel, i) in required})
    elif isinstance(node, lp.Project):
        node.exprs = [
            b.Literal(e.type, None)
            if (node.rel, i) not in required and isinstance(e, (b.ColumnRef, b.Literal))
            else e
            for i, e in enumerate(node.exprs)
        ]
        _prune(node.input, _keys(node.exprs))
    elif isinstance(node, lp.Filter):
        _prune(node.input, required | b.column_keys(node.predicate))
    elif isinstance(node, lp.Join):
        need = required if node.condition is None else required | b.column_keys(node.condition)
        _prune(node.left, need)
        _prune(node.right, need)
    elif isinstance(node, lp.Aggregate):
        _prune(node.input, _keys(node.keys + [a.arg for a in node.aggregates if a.arg is not None]))
    elif isinstance(node, lp.Distinct):
        _prune(node.input, set(node.input.layout))
    elif isinstance(node, lp.Sort):
        layout = node.input.layout
        _prune(node.input, required | {layout[k.position] for k in node.keys})
    elif isinstance(node, lp.Limit):
        _prune(node.input, required)
