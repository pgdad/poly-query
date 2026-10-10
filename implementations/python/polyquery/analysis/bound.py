"""Bound (resolved and typed) expressions and queries.

Bound expressions are immutable value objects: structural equality (``==``)
compares resolved column bindings, literal values, operators and function
names, which is what GROUP BY / ORDER BY matching needs (semantics.md §5, §6).

A column is identified by a *column key* ``(rel, index)``: ``rel`` is a
statement-wide unique id of a relation (a range variable of a FROM clause,
the output of an aggregation or of a projection) and ``index`` the column's
position in it. Plan operators describe their output rows as a list of
column keys, which is how expressions are mapped to row slots at execution.
"""

from __future__ import annotations

import dataclasses
import itertools
from dataclasses import dataclass, field
from typing import Any, Callable, Iterator

from ..datatypes import DataType
from ..storage.catalog import Table

ColumnKey = tuple[int, int]


class IdGenerator:
    """Statement-wide source of unique relation / subquery ids."""

    def __init__(self) -> None:
        self._counter = itertools.count(1)

    def next(self) -> int:
        return next(self._counter)


@dataclass(frozen=True)
class Expr:
    type: DataType

    def children(self) -> tuple[Expr, ...]:
        return ()


@dataclass(frozen=True)
class Literal(Expr):
    value: Any


@dataclass(frozen=True)
class ColumnRef(Expr):
    rel: int
    index: int
    name: str = field(compare=False)

    @property
    def key(self) -> ColumnKey:
        return (self.rel, self.index)


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
class Between(Expr):
    """``operand BETWEEN low AND high``; all three promoted to a common type."""

    operand: Expr
    low: Expr
    high: Expr
    negated: bool

    def children(self) -> tuple[Expr, ...]:
        return (self.operand, self.low, self.high)


@dataclass(frozen=True)
class InList(Expr):
    """``operand IN (items)``; operand and items promoted to a common type."""

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


# ------------------------------------------------------------------ subqueries


@dataclass(eq=False)
class Subquery:
    """A bound subquery used inside an expression.

    ``outer_keys`` are the column keys of enclosing queries the subquery reads
    (empty for an uncorrelated subquery). Compared by identity.
    """

    id: int
    query: BoundQuery
    outer_keys: tuple[ColumnKey, ...]

    @property
    def correlated(self) -> bool:
        return bool(self.outer_keys)


@dataclass(frozen=True)
class SubqueryExpr(Expr):
    """Base of subquery expressions. ``args`` evaluate the subquery's outer
    column keys in the context of the enclosing query (initially plain column
    references; GROUP BY substitution may rewrite them)."""

    subquery: Subquery
    args: tuple[Expr, ...]


@dataclass(frozen=True)
class ScalarSubquery(SubqueryExpr):
    def children(self) -> tuple[Expr, ...]:
        return self.args


@dataclass(frozen=True)
class Exists(SubqueryExpr):
    def children(self) -> tuple[Expr, ...]:
        return self.args


@dataclass(frozen=True)
class InSubquery(SubqueryExpr):
    """``operand IN (subquery)``; the subquery's values are converted to
    ``operand.type`` (the common comparison type) when they differ."""

    operand: Expr = field(kw_only=True)
    negated: bool = field(kw_only=True)

    def children(self) -> tuple[Expr, ...]:
        return (self.operand, *self.args)


# ------------------------------------------------------------------ helpers


def walk(expr: Expr) -> Iterator[Expr]:
    yield expr
    for child in expr.children():
        yield from walk(child)


def map_children(expr: Expr, fn: Callable[[Expr], Expr]) -> Expr:
    """Returns ``expr`` with ``fn`` applied to each direct child expression."""
    changes: dict[str, Any] = {}
    for f in dataclasses.fields(expr):
        if f.name == "type":
            continue
        value = getattr(expr, f.name)
        if isinstance(value, Expr):
            new: Any = fn(value)
        elif isinstance(value, tuple) and value and isinstance(value[0], Expr):
            new = tuple(fn(v) for v in value)
        elif isinstance(value, tuple) and value and isinstance(value[0], tuple):
            new = tuple(tuple(fn(v) for v in pair) for pair in value)
        else:
            continue
        if new != value:
            changes[f.name] = new
    return dataclasses.replace(expr, **changes) if changes else expr


def column_keys(expr: Expr) -> set[ColumnKey]:
    """All column keys referenced by an expression (including subquery args)."""
    return {e.key for e in walk(expr) if isinstance(e, ColumnRef)}


def is_constant(expr: Expr) -> bool:
    return not any(isinstance(e, (ColumnRef, AggCall, SubqueryExpr)) for e in walk(expr))


def contains_subquery(expr: Expr) -> bool:
    return any(isinstance(e, SubqueryExpr) for e in walk(expr))


def subqueries(expr: Expr) -> Iterator[Subquery]:
    for e in walk(expr):
        if isinstance(e, SubqueryExpr):
            yield e.subquery


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


@dataclass(eq=False)
class Relation:
    """A FROM clause item after binding."""


@dataclass(eq=False)
class TableRelation(Relation):
    rel: int
    table: Table
    name: str  # range variable name
    used: set[int] = field(default_factory=set)  # referenced column indexes


@dataclass(eq=False)
class DerivedRelation(Relation):
    """A derived table or CTE reference: the output of ``query`` as relation ``rel``."""

    rel: int
    query: BoundQuery
    name: str
    cte: str | None = None


@dataclass(eq=False)
class JoinRelation(Relation):
    kind: str  # INNER, LEFT, CROSS
    left: Relation
    right: Relation
    condition: Expr | None


@dataclass
class Aggregation:
    """Grouping keys and aggregate calls; outputs ``keys + aggregates`` as ``rel``."""

    rel: int
    keys: list[Expr]
    aggregates: list[AggCall]


@dataclass(eq=False)
class BoundQuery:
    """A SELECT after name resolution and type checking."""

    from_: Relation | None
    where: Expr | None
    aggregation: Aggregation | None
    having: Expr | None
    outputs: list[OutputColumn]
    hidden: list[Expr]  # ORDER BY keys that are not output columns
    order: list[SortKey]
    distinct: bool
    limit: Expr | None
    offset: Expr | None

    @property
    def column_types(self) -> list[DataType]:
        return [o.expr.type for o in self.outputs]


@dataclass(eq=False)
class BoundStatement:
    query: BoundQuery
    ids: IdGenerator
