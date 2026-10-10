"""Turns a bound query into a logical plan."""

from __future__ import annotations

from ..analysis import bound as b
from ..storage.catalog import Column
from . import plan as p


def plan_query(query: b.BoundQuery) -> p.QueryPlan:
    node: p.PlanNode
    if query.table is None:
        node = p.SingleRow()
    else:
        node = p.TableScan(query.table, list(query.scan_columns))
    if query.where is not None:
        node = p.Filter(node, query.where)
    if query.aggregated:
        node = p.Aggregate(node, list(query.aggregates))

    exprs = [o.expr for o in query.outputs] + list(query.hidden)
    node = p.Project(node, exprs)
    if query.distinct:
        node = p.Distinct(node)
    if query.order:
        node = p.Sort(node, list(query.order))
    if query.limit is not None or query.offset is not None:
        node = p.Limit(node, query.limit, query.offset)
    if query.hidden:
        width = len(query.outputs)
        node = p.Project(
            node, [b.ColumnSlot(o.expr.type, i, o.name) for i, o in enumerate(query.outputs[:width])]
        )
    columns = [Column(o.name, o.expr.type) for o in query.outputs]
    return p.QueryPlan(node, columns)
