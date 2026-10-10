"""Logical query plan nodes.

A plan is a tree of operators; each operator produces rows (tuples) whose
layout is described by the bound expressions of its parent.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..analysis import bound as b
from ..storage.catalog import Column, Table


@dataclass(eq=False)
class PlanNode:
    def children(self) -> list[PlanNode]:
        return []

    @property
    def op(self) -> str:
        return type(self).__name__

    def describe(self) -> dict[str, Any]:
        """Operator-specific details for EXPLAIN output."""
        return {}

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"op": self.op, **self.describe()}
        kids = self.children()
        if kids:
            out["children"] = [k.to_json() for k in kids]
        return out


@dataclass(eq=False)
class TableScan(PlanNode):
    table: Table
    columns: list[int]  # table column indexes, in output order

    def describe(self) -> dict[str, Any]:
        return {
            "table": self.table.name,
            "columns": [self.table.columns[i].name for i in self.columns],
        }


@dataclass(eq=False)
class SingleRow(PlanNode):
    """Produces one empty row (SELECT without FROM)."""


@dataclass(eq=False)
class Filter(PlanNode):
    input: PlanNode
    predicate: b.Expr

    def children(self) -> list[PlanNode]:
        return [self.input]


@dataclass(eq=False)
class Aggregate(PlanNode):
    """Whole-input aggregation: outputs one row of aggregate values."""

    input: PlanNode
    aggregates: list[b.AggCall]

    def children(self) -> list[PlanNode]:
        return [self.input]

    def describe(self) -> dict[str, Any]:
        return {"aggregates": [a.name for a in self.aggregates]}


@dataclass(eq=False)
class Project(PlanNode):
    input: PlanNode
    exprs: list[b.Expr]

    def children(self) -> list[PlanNode]:
        return [self.input]


@dataclass(eq=False)
class Distinct(PlanNode):
    input: PlanNode

    def children(self) -> list[PlanNode]:
        return [self.input]


@dataclass(eq=False)
class Sort(PlanNode):
    input: PlanNode
    keys: list[b.SortKey]

    def children(self) -> list[PlanNode]:
        return [self.input]


@dataclass(eq=False)
class Limit(PlanNode):
    input: PlanNode
    limit: b.Expr | None
    offset: b.Expr | None

    def children(self) -> list[PlanNode]:
        return [self.input]


@dataclass(eq=False)
class QueryPlan:
    root: PlanNode
    columns: list[Column] = field(default_factory=list)
