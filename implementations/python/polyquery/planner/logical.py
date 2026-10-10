"""Logical query plan: relational operators without algorithm choices.

Every node describes its output rows by a *layout*: the list of column keys
``(rel, index)`` of the row slots, in order (see ``analysis.bound``).
"""

from __future__ import annotations

from dataclasses import dataclass

from ..analysis import bound as b
from ..storage.catalog import Table


@dataclass(eq=False)
class LogicalNode:
    def inputs(self) -> list[LogicalNode]:
        return []

    @property
    def layout(self) -> list[b.ColumnKey]:
        raise NotImplementedError

    def rels(self) -> set[int]:
        return {key[0] for key in self.layout}


@dataclass(eq=False)
class Scan(LogicalNode):
    table: Table
    rel: int
    columns: list[int]  # table column indexes that are read
    name: str  # range variable name

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in self.columns]


@dataclass(eq=False)
class Values(LogicalNode):
    """A single row without columns (SELECT without FROM)."""

    @property
    def layout(self) -> list[b.ColumnKey]:
        return []


@dataclass(eq=False)
class SubqueryScan(LogicalNode):
    """Exposes the output of a derived table / CTE query as relation ``rel``."""

    input: LogicalNode
    rel: int
    width: int
    name: str

    def inputs(self) -> list[LogicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(self.width)]


@dataclass(eq=False)
class Filter(LogicalNode):
    input: LogicalNode
    predicate: b.Expr

    def inputs(self) -> list[LogicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout


@dataclass(eq=False)
class Join(LogicalNode):
    kind: str  # INNER, LEFT, CROSS
    left: LogicalNode
    right: LogicalNode
    condition: b.Expr | None

    def inputs(self) -> list[LogicalNode]:
        return [self.left, self.right]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.left.layout + self.right.layout


@dataclass(eq=False)
class Aggregate(LogicalNode):
    """Groups by ``keys``; outputs the key values followed by the aggregates."""

    input: LogicalNode
    rel: int
    keys: list[b.Expr]
    aggregates: list[b.AggCall]

    def inputs(self) -> list[LogicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(len(self.keys) + len(self.aggregates))]


@dataclass(eq=False)
class Project(LogicalNode):
    input: LogicalNode
    rel: int
    exprs: list[b.Expr]

    def inputs(self) -> list[LogicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(len(self.exprs))]


@dataclass(eq=False)
class Distinct(LogicalNode):
    input: LogicalNode

    def inputs(self) -> list[LogicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout


@dataclass(eq=False)
class Sort(LogicalNode):
    input: LogicalNode
    keys: list[b.SortKey]  # positions in the input row

    def inputs(self) -> list[LogicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout


@dataclass(eq=False)
class Limit(LogicalNode):
    input: LogicalNode
    limit: b.Expr | None
    offset: b.Expr | None

    def inputs(self) -> list[LogicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout
