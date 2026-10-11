"""Turns a bound query into a logical plan (semantics.md §4 clause order)."""

from __future__ import annotations

from ..analysis import bound as b
from ..analysis import typing_rules as tr
from ..datatypes import DataType
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
        if isinstance(relation, b.UnionRelation):
            branches = [self._converted(q, relation.types) for q in relation.branches]
            return lp.UnionAll(branches, relation.rel, len(relation.types))
        assert isinstance(relation, b.JoinRelation)
        return lp.Join(
            relation.kind,
            self.plan_relation(relation.left),
            self.plan_relation(relation.right),
            relation.condition,
        )

    def _converted(self, query: b.BoundQuery, types: list[DataType]) -> lp.LogicalNode:
        """The plan of a UNION ALL branch with its columns promoted to the
        output types (an INT64 that does not fit the DECIMAL fails with
        NUMERIC_OVERFLOW)."""
        node = self.plan_query(query)
        columns = [
            b.ColumnRef(o.expr.type, *key, o.name) for o, key in zip(query.outputs, node.layout)
        ]
        promoted = [tr.promote(c, t) for c, t in zip(columns, types)]
        if all(p is c for p, c in zip(promoted, columns)):
            return node
        return lp.Project(node, self.ids.next(), promoted)
