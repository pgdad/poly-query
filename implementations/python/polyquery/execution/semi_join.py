"""Correlated ``EXISTS`` as a hash semi-join.

The physical planner turns ``inner_col = <outer expression>`` in a correlated
subquery into a ``LookupScan``, and the expression compilers run the
subquery's plan once per distinct outer value. For the common shape

    EXISTS (SELECT … FROM t WHERE t.k = <outer> AND <inner-only conditions>)

that per-row execution is not needed: the subquery has a row for an outer
row exactly when the outer key is one of the inner keys whose conditions
are TRUE. :func:`exists_semi_join` describes that key set; it is computed
on first use, once per statement, with vectorized evaluation over the inner
table, and EXISTS becomes a set membership test.

It applies only when skipping the per-row execution cannot change the
outcome: the plan is ``Project`` / ``Distinct`` nodes over ``Filter`` nodes
over the ``LookupScan``, and no projected expression, filter or residual
condition can raise an error (``bound.may_fail``) or reads a correlation
parameter (so the conditions can be evaluated for every inner row up front).
A NULL key never matches (``=`` is never TRUE for NULL), as in the lookup.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from itertools import compress
from typing import Any

from ..analysis import bound as b
from ..planner import physical as pp
from .common import VECTOR_BATCH_ROWS
from .context import ExecutionContext
from .vcompiler import compile_vector


@dataclass(eq=False)
class SemiJoin:
    """``EXISTS`` ≡ ``key`` (an expression over the subquery's correlation
    parameters) is in ``keys()``: the key column values of the rows of
    ``scan`` satisfying all ``conditions``."""

    key: b.Expr
    scan: pp.LookupScan
    conditions: list[b.Expr]
    ctx: ExecutionContext
    _keys: frozenset | None = field(default=None, init=False)

    def keys(self) -> frozenset:
        if self._keys is None:
            self._keys = frozenset(_matching_keys(self.scan, self.conditions, self.ctx))
        return self._keys


def exists_semi_join(e: b.Exists, ctx: ExecutionContext) -> SemiJoin | None:
    """The semi-join form of ``e`` (one per statement and subquery), or None
    if the subquery does not have the required shape."""
    plan = ctx.subplans[e.subquery.id]
    found = ctx.cached(plan, "semi_join", lambda: (_semi_join(plan, ctx),))
    return found[0]


def _semi_join(plan: pp.PhysicalNode, ctx: ExecutionContext) -> SemiJoin | None:
    node = plan
    while isinstance(node, (pp.Project, pp.Distinct)):
        if any(b.may_fail(expr) for expr in node.expressions()):
            return None
        node = node.input
    conditions: list[b.Expr] = []
    while isinstance(node, pp.Filter):
        conditions.append(node.predicate)
        node = node.input
    if not isinstance(node, pp.LookupScan):
        return None
    if node.residual is not None:
        conditions.append(node.residual)
    layout = {key: i for i, key in enumerate(node.layout)}
    for condition in conditions:
        if b.may_fail(condition) or not b.column_keys(condition) <= layout.keys():
            return None
    return SemiJoin(node.key, node, conditions, ctx)


def _matching_keys(node: pp.LookupScan, conditions: list[b.Expr], ctx: ExecutionContext) -> set[Any]:
    """The non-NULL key column values of the inner rows satisfying every condition."""
    layout = {key: i for i, key in enumerate(node.layout)}
    predicates = [compile_vector(c, ctx, layout) for c in conditions]
    slot = node.columns.index(node.key_column)
    keys: set[Any] = set()
    for cols, n in node.table.scan_columns(node.columns, VECTOR_BATCH_ROWS, None, 0, None):
        values = cols[slot]
        for predicate in predicates:
            mask = predicate(cols, n)
            if mask.count(True) != n:
                cols = [list(compress(c, mask)) for c in cols]
                values = cols[slot]
                n = len(values)
        keys.update(values)
        ctx.check()
    keys.discard(None)
    ctx.reserve_rows(len(keys), 1)
    return keys
