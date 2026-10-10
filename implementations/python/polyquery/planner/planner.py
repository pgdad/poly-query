"""Turns a bound query into a logical plan (semantics.md §4 clause order)."""

from __future__ import annotations

from ..analysis import bound as b
from . import logical as lp


class LogicalPlanner:
    def __init__(self, ids: b.IdGenerator):
        self.ids = ids

    def plan_query(self, query: b.BoundQuery) -> lp.LogicalNode:
        node: lp.LogicalNode
        node = self.plan_relation(query.from_) if query.from_ is not None else lp.Values()
        if query.where is not None:
            node = lp.Filter(node, query.where)
        if query.aggregation is not None:
            agg = query.aggregation
            node = lp.Aggregate(node, agg.rel, list(agg.keys), list(agg.aggregates))
        if query.having is not None:
            node = lp.Filter(node, query.having)

        projected = self.ids.next()
        exprs = [o.expr for o in query.outputs] + list(query.hidden)
        node = lp.Project(node, projected, exprs)
        if query.distinct:
            node = lp.Distinct(node)
        if query.order:
            node = lp.Sort(node, list(query.order))
        if query.limit is not None or query.offset is not None:
            node = lp.Limit(node, query.limit, query.offset)
        if query.hidden:
            # drop the ORDER BY keys that are not output columns
            node = lp.Project(
                node,
                self.ids.next(),
                [b.ColumnRef(o.expr.type, projected, i, o.name) for i, o in enumerate(query.outputs)],
            )
        return node

    def plan_relation(self, relation: b.Relation) -> lp.LogicalNode:
        if isinstance(relation, b.TableRelation):
            return lp.Scan(relation.table, relation.rel, sorted(relation.used), relation.name)
        if isinstance(relation, b.DerivedRelation):
            return lp.SubqueryScan(
                self.plan_query(relation.query),
                relation.rel,
                len(relation.query.outputs),
                relation.name,
            )
        assert isinstance(relation, b.JoinRelation)
        return lp.Join(
            relation.kind,
            self.plan_relation(relation.left),
            self.plan_relation(relation.right),
            relation.condition,
        )
