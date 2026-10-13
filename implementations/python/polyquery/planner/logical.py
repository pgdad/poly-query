"""Logical query plan: relational operators without algorithm choices.

Every node describes its output rows by a *layout*: the list of column keys
``(rel, index)`` of the row slots, in order (see ``analysis.bound``).

A logical plan says *what* a statement computes. How it is computed (access
paths, join algorithms, execution mode, parallelism, native kernels) is
decided by the physical planner (``physical.py``); the optimizer
(``optimizer.py``, ``rules/``) only rewrites logical plans.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass

from ..analysis import bound as b
from ..storage.catalog import Column, Table
from .explain import render_expr


@dataclass(eq=False)
class LogicalNode:
    def inputs(self) -> list[LogicalNode]:
        return []

    @property
    def layout(self) -> list[b.ColumnKey]:
        raise NotImplementedError

    def rels(self) -> set[int]:
        return {key[0] for key in self.layout}

    def expressions(self) -> list[b.Expr]:
        """All expressions evaluated by this operator."""
        return []

    def describe(self) -> str:
        """The operator's arguments, for :func:`format_plan`."""
        return ""


@dataclass(eq=False)
class Scan(LogicalNode):
    table: Table
    rel: int
    columns: list[int]  # table column indexes that are read
    name: str  # range variable name

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in self.columns]

    def describe(self) -> str:
        columns = ", ".join(self.table.columns[i].name for i in self.columns)
        alias = f" AS {self.name}" if self.name != self.table.name else ""
        return f"{self.table.name}{alias} [{columns}]"


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

    def describe(self) -> str:
        return self.name


@dataclass(eq=False)
class UnionAll(LogicalNode):
    """The rows of every branch, in branch order, as relation ``rel``; the
    branches have equal widths and already produce the output types."""

    branches: list[LogicalNode]
    rel: int
    width: int

    def inputs(self) -> list[LogicalNode]:
        return list(self.branches)

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

    def expressions(self) -> list[b.Expr]:
        return [self.predicate]

    def describe(self) -> str:
        return render_expr(self.predicate)


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

    def expressions(self) -> list[b.Expr]:
        return [] if self.condition is None else [self.condition]

    def describe(self) -> str:
        return self.kind if self.condition is None else f"{self.kind} ON {render_expr(self.condition)}"


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

    def expressions(self) -> list[b.Expr]:
        return self.keys + [a.arg for a in self.aggregates if a.arg is not None]

    def describe(self) -> str:
        keys = ", ".join(render_expr(k) for k in self.keys)
        return f"keys [{keys}] aggregates [{', '.join(render_expr(a) for a in self.aggregates)}]"


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

    def expressions(self) -> list[b.Expr]:
        return self.exprs

    def describe(self) -> str:
        return ", ".join(render_expr(e) for e in self.exprs)


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

    def describe(self) -> str:
        return ", ".join(f"#{k.position + 1}{' DESC' if k.descending else ''}" for k in self.keys)


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

    def expressions(self) -> list[b.Expr]:
        return [e for e in (self.limit, self.offset) if e is not None]

    def describe(self) -> str:
        parts = [] if self.limit is None else [f"limit {render_expr(self.limit)}"]
        if self.offset is not None:
            parts.append(f"offset {render_expr(self.offset)}")
        return " ".join(parts)


@dataclass(eq=False)
class LogicalPlan:
    """The logical plan of a statement: the tree of the query and the trees
    of the subqueries evaluated by its expressions (scalar / IN / EXISTS
    subqueries at any nesting depth, by ``Subquery.id``). Derived tables and
    CTE references are part of the trees (``SubqueryScan``)."""

    root: LogicalNode
    columns: list[Column]  # names and types of the result columns
    subqueries: dict[int, LogicalNode]

    def trees(self) -> list[LogicalNode]:
        return [self.root, *self.subqueries.values()]

    def __str__(self) -> str:
        parts = [format_plan(self.root)]
        for id_, tree in self.subqueries.items():
            parts.append(f"subquery {id_}:\n" + format_plan(tree, indent=1))
        return "\n".join(parts)


def walk(node: LogicalNode) -> Iterator[LogicalNode]:
    """The nodes of a tree, parents before their inputs (iteratively: the
    plans of nested derived tables are deep)."""
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        stack += reversed(n.inputs())


def format_plan(node: LogicalNode, indent: int = 0) -> str:
    """An indented, human-readable rendering of a logical tree (debugging
    and tests; not part of the protocol)."""
    detail = node.describe()
    lines = ["  " * indent + type(node).__name__ + (f" {detail}" if detail else "")]
    lines.extend(format_plan(child, indent + 1) for child in node.inputs())
    return "\n".join(lines)
