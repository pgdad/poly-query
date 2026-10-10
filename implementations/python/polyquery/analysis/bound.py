"""Bound (resolved and typed) expressions and queries.

Bound expressions are immutable value objects: structural equality (``==``)
compares resolved column slots, literal values, operators and function names,
which is what ORDER BY / GROUP BY matching needs (semantics.md §5, §6).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..datatypes import DataType
from ..storage.catalog import Table


@dataclass(frozen=True)
class Expr:
    type: DataType

    def children(self) -> tuple[Expr, ...]:
        return ()


@dataclass(frozen=True)
class Literal(Expr):
    value: Any


@dataclass(frozen=True)
class ColumnSlot(Expr):
    """Position ``slot`` in the operator's input row."""

    slot: int
    name: str = field(compare=False)


@dataclass(frozen=True)
class Unary(Expr):
    op: str  # 'neg', 'pos'
    operand: Expr

    def children(self) -> tuple[Expr, ...]:
        return (self.operand,)


@dataclass(frozen=True)
class Arith(Expr):
    op: str  # + - * / %
    left: Expr
    right: Expr

    def children(self) -> tuple[Expr, ...]:
        return (self.left, self.right)


@dataclass(frozen=True)
class Compare(Expr):
    op: str  # = <> < <= > >=
    left: Expr
    right: Expr

    def children(self) -> tuple[Expr, ...]:
        return (self.left, self.right)


@dataclass(frozen=True)
class Logical(Expr):
    op: str  # AND, OR
    left: Expr
    right: Expr

    def children(self) -> tuple[Expr, ...]:
        return (self.left, self.right)


@dataclass(frozen=True)
class Not(Expr):
    operand: Expr

    def children(self) -> tuple[Expr, ...]:
        return (self.operand,)


@dataclass(frozen=True)
class IsNull(Expr):
    operand: Expr
    negated: bool

    def children(self) -> tuple[Expr, ...]:
        return (self.operand,)


@dataclass(frozen=True)
class Concat(Expr):
    left: Expr
    right: Expr

    def children(self) -> tuple[Expr, ...]:
        return (self.left, self.right)


@dataclass(frozen=True)
class Cast(Expr):
    """Explicit CAST, or an implicit numeric/temporal promotion."""

    operand: Expr
    implicit: bool = False

    def children(self) -> tuple[Expr, ...]:
        return (self.operand,)


@dataclass(frozen=True)
class Like(Expr):
    operand: Expr
    pattern: Expr
    negated: bool

    def children(self) -> tuple[Expr, ...]:
        return (self.operand, self.pattern)


@dataclass(frozen=True)
class InList(Expr):
    operand: Expr
    items: tuple[Expr, ...]
    negated: bool

    def children(self) -> tuple[Expr, ...]:
        return (self.operand, *self.items)


@dataclass(frozen=True)
class Case(Expr):
    """Searched CASE (simple CASE is rewritten to the searched form)."""

    whens: tuple[tuple[Expr, Expr], ...]
    else_: Expr | None

    def children(self) -> tuple[Expr, ...]:
        out: list[Expr] = []
        for cond, result in self.whens:
            out += (cond, result)
        if self.else_ is not None:
            out.append(self.else_)
        return tuple(out)


@dataclass(frozen=True)
class Function(Expr):
    """Scalar function call; ``name`` is the canonical upper-case name."""

    name: str
    args: tuple[Expr, ...]

    def children(self) -> tuple[Expr, ...]:
        return self.args


@dataclass(frozen=True)
class AggCall(Expr):
    """An aggregate function over the input rows. ``arg`` is None for COUNT(*)."""

    name: str  # COUNT, SUM, MIN, MAX, AVG
    arg: Expr | None
    distinct: bool

    def children(self) -> tuple[Expr, ...]:
        return () if self.arg is None else (self.arg,)


@dataclass(frozen=True)
class AggRef(Expr):
    """Reference to the ``index``-th output of an Aggregate operator."""

    index: int


def walk(expr: Expr):
    yield expr
    for child in expr.children():
        yield from walk(child)


def is_constant(expr: Expr) -> bool:
    return not any(isinstance(e, (ColumnSlot, AggRef, AggCall)) for e in walk(expr))


# ------------------------------------------------------------------ queries


@dataclass
class OutputColumn:
    name: str
    expr: Expr


@dataclass
class SortKey:
    position: int  # index into the projected row (outputs + hidden keys)
    descending: bool
    nulls_first: bool


@dataclass
class BoundQuery:
    """A single-table SELECT after name resolution and type checking."""

    table: Table | None
    scan_columns: list[int]  # table column indexes, in input-slot order
    where: Expr | None
    aggregated: bool
    aggregates: list[AggCall]
    outputs: list[OutputColumn]
    hidden: list[Expr]  # ORDER BY keys that are not output columns
    order: list[SortKey]
    distinct: bool
    limit: int | None
    offset: int
