"""Projection / column pruning (indexes-and-planning.md §3.2).

Restricts every scan to the columns the plan above it needs. Output columns
of a derived table / CTE that the enclosing query never reads are replaced
by NULL when they are plain column references or literals (which can
neither fail nor have side effects), so their source columns are not read
either.
"""

from __future__ import annotations

from ...analysis import bound as b
from .. import logical as lp
from .base import Rule


class ColumnPruning(Rule):
    name = "column_pruning"

    def apply(self, node: lp.LogicalNode) -> lp.LogicalNode:
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
    elif isinstance(node, lp.UnionAll):
        for branch in node.branches:
            layout = branch.layout
            _prune(branch, {layout[i] for i in range(node.width) if (node.rel, i) in required})
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
