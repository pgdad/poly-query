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

from ..datatypes import BOOLEAN, DataType
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
    (empty for an uncorrelated subquery). Two subqueries are equal if they
    were bound from structurally identical SQL (``fingerprint``) with the same
    correlation, so that e.g. a GROUP BY expression containing a subquery
    matches the identical SELECT expression.
    """

    id: int
    query: BoundQuery
    outer_keys: tuple[ColumnKey, ...]
    fingerprint: object = None

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Subquery):
            return NotImplemented
        if self.fingerprint is None or other.fingerprint is None:
            return self is other
        return self.fingerprint == other.fingerprint and self.outer_keys == other.outer_keys

    def __hash__(self) -> int:
        return hash((self.fingerprint, self.outer_keys))

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
    """``expr`` and all its descendants in pre-order (iteratively: a
    recursive generator would cost time proportional to the depth per node,
    and long operator chains are deep trees)."""
    stack = [expr]
    pop, extend = stack.pop, stack.extend
    while stack:
        e = pop()
        yield e
        children = e.children()
        if children:
            extend(reversed(children))


def map_children(expr: Expr, fn: Callable[[Expr], Expr]) -> Expr:
    """Returns ``expr`` with ``fn`` applied to each direct child expression."""
    changes: dict[str, Any] = {}
    for f in dataclasses.fields(expr):
        if f.name == "type":
            continue
        value = getattr(expr, f.name)
        if isinstance(value, Expr):
            new: Any = fn(value)
            changed = new is not value
        elif isinstance(value, tuple) and value and isinstance(value[0], Expr):
            new = tuple([fn(v) for v in value])
            changed = _replaced(new, value)
        elif isinstance(value, tuple) and value and isinstance(value[0], tuple):
            new = tuple([tuple([fn(v) for v in pair]) for pair in value])
            changed = any(_replaced(n, v) for n, v in zip(new, value))
        else:
            continue
        # identity, not equality: comparing rebuilt subtrees at every level
        # of a deep tree would take quadratic time
        if changed:
            changes[f.name] = new
    return dataclasses.replace(expr, **changes) if changes else expr


def _replaced(new: tuple, old: tuple) -> bool:
    return any(n is not o for n, o in zip(new, old))


def _bottom_up(expr: Expr, attr: str, combine: Callable[[Expr, list[Any]], Any]) -> Any:
    """A property of ``expr`` computed from its node and the properties of
    its children, cached on every node of the subtree under ``attr``
    (computed iteratively in post-order). Planning and compilation ask for
    such properties at every node of deep trees; walking each subtree again
    would take quadratic time."""
    cached = expr.__dict__.get(attr)
    if cached is not None:
        return cached
    stack = [expr]
    while stack:
        e = stack[-1]
        if attr in e.__dict__:
            stack.pop()
            continue
        children = e.children()
        pending = [c for c in children if attr not in c.__dict__]
        if pending:
            stack += pending
            continue
        stack.pop()
        value = combine(e, [c.__dict__[attr] for c in children])
        object.__setattr__(e, attr, value)  # a cache, not a field
    return expr.__dict__[attr]


_NO_KEYS: frozenset[ColumnKey] = frozenset()


def _combine_keys(e: Expr, children: list[frozenset[ColumnKey]]) -> frozenset[ColumnKey]:
    # reuses a child's set where possible (a chain over one column shares it)
    out = _NO_KEYS
    for keys in children:
        if keys and not keys <= out:
            out = keys if out <= keys else out | keys
    if isinstance(e, ColumnRef) and e.key not in out:
        out = out | {e.key}
    return out


def column_keys(expr: Expr) -> frozenset[ColumnKey]:
    """All column keys referenced by an expression (including subquery args)."""
    return _bottom_up(expr, "_column_keys", _combine_keys)


# what a subtree contains (``summary``)
_HAS_COLUMN = 1
_HAS_AGGREGATE = 2
_HAS_SUBQUERY = 4
_HAS_SLEEP = 8
_MAY_FAIL = 16


def _own_flags(e: Expr) -> int:
    if isinstance(e, ColumnRef):
        return _HAS_COLUMN
    if isinstance(e, AggCall):
        return _HAS_AGGREGATE
    if isinstance(e, SubqueryExpr):
        return _HAS_SUBQUERY | _MAY_FAIL
    if isinstance(e, Function):
        return _MAY_FAIL | (_HAS_SLEEP if e.name == "PQ_SLEEP" else 0)
    if isinstance(e, (Arith, Unary, Cast)):
        return _MAY_FAIL
    return 0


def _combine_flags(e: Expr, children: list[int]) -> int:
    flags = _own_flags(e)
    for f in children:
        flags |= f
    return flags


def summary(expr: Expr) -> int:
    """The ``_HAS_*`` / ``_MAY_FAIL`` flags of a subtree."""
    return _bottom_up(expr, "_summary", _combine_flags)


def is_constant(expr: Expr) -> bool:
    return not summary(expr) & (_HAS_COLUMN | _HAS_AGGREGATE | _HAS_SUBQUERY)


def conjuncts(expr: Expr | None) -> list[Expr]:
    """The operands of a chain of ANDs (``[]`` for None)."""
    out: list[Expr] = []
    stack = [] if expr is None else [expr]
    while stack:
        e = stack.pop()
        if isinstance(e, Logical) and e.op == "AND":
            stack += (e.right, e.left)
        else:
            out.append(e)
    return out


def conjunction(exprs: list[Expr]) -> Expr | None:
    """``e1 AND e2 AND …`` (None for no expressions)."""
    result: Expr | None = None
    for e in exprs:
        result = e if result is None else Logical(BOOLEAN, "AND", result, e)
    return result


def has_side_effects(expr: Expr) -> bool:
    """``PQ_SLEEP`` must run once per evaluation (never folded or skipped)."""
    return bool(summary(expr) & _HAS_SLEEP)


def may_fail(expr: Expr) -> bool:
    """Conservatively: can evaluating ``expr`` raise an error (overflow,
    division by zero, conversion, subquery cardinality, …) or have a side
    effect? Column references, literals, comparisons and boolean logic cannot."""
    return bool(summary(expr) & _MAY_FAIL)


def contains_subquery(expr: Expr) -> bool:
    return bool(summary(expr) & _HAS_SUBQUERY)


def subqueries(expr: Expr) -> Iterator[Subquery]:
    for e in walk(expr):
        if isinstance(e, SubqueryExpr):
            yield e.subquery


# ------------------------------------------------------------------ hashing

# per expression class: its compared fields that are not child expressions
_SCALAR_FIELDS: dict[type, tuple[str, ...]] = {}


def _scalar_fields(cls: type) -> tuple[str, ...]:
    names = _SCALAR_FIELDS.get(cls)
    if names is None:
        names = _SCALAR_FIELDS[cls] = tuple(
            f.name for f in dataclasses.fields(cls) if f.compare and f.name not in _CHILD_FIELDS
        )
    return names


# fields holding child expressions (``children()``), hashed through them
_CHILD_FIELDS = frozenset({"operand", "left", "right", "pattern", "low", "high", "items", "whens", "else_", "args", "arg"})


def _combine_hash(e: Expr, children: list[int]) -> int:
    return hash((type(e), *[getattr(e, name) for name in _scalar_fields(type(e))], *children))


def _expr_hash(self: Expr) -> int:
    """The hash of an expression, consistent with its structural ``==`` and
    computed once per node from its children's hashes (the generated
    dataclass hash would rehash the whole subtree on every call, quadratic
    when the nodes of a deep tree are looked up in dicts)."""
    return _bottom_up(self, "_hash", _combine_hash)


# per expression class: its fields holding child expressions
_CHILD_FIELD_NAMES: dict[type, tuple[str, ...]] = {}


def _child_values(e: Expr) -> list[Any]:
    names = _CHILD_FIELD_NAMES.get(type(e))
    if names is None:
        names = _CHILD_FIELD_NAMES[type(e)] = tuple(
            f.name for f in dataclasses.fields(e) if f.name in _CHILD_FIELDS
        )
    return [getattr(e, name) for name in names]


def _expr_eq(self: Expr, other: object) -> Any:
    """Structural equality of the generated dataclass ``__eq__`` (same class,
    equal compared fields), computed iteratively with an explicit stack: the
    generated method recurses in C once per level (long chains are deep),
    and compares cached hashes first."""
    if self is other:
        return True
    if other.__class__ is not self.__class__:
        return NotImplemented
    stack: list[tuple[Any, Any]] = [(self, other)]
    while stack:
        a, c = stack.pop()
        if a is c:
            continue
        if isinstance(a, Expr):
            if c.__class__ is not a.__class__ or hash(a) != hash(c):
                return False
            for name in _scalar_fields(type(a)):
                if getattr(a, name) != getattr(c, name):
                    return False
            stack.extend(zip(_child_values(a), _child_values(c)))
        elif isinstance(a, tuple):  # tuples of children or of CASE branches
            if not isinstance(c, tuple) or len(a) != len(c):
                return False
            stack.extend(zip(a, c))
        elif a != c:  # None (no ELSE / argument)
            return False
    return True


def _install(cls: type) -> None:
    cls.__hash__ = _expr_hash  # type: ignore[method-assign]
    cls.__eq__ = _expr_eq  # type: ignore[method-assign]
    for sub in cls.__subclasses__():
        _install(sub)


_install(Expr)


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
class UnionRelation(Relation):
    """The rows of all ``branches`` (UNION ALL) as relation ``rel``. Column
    ``i`` has type ``types[i]``, to which each branch's column ``i`` is
    converted (spec/changes/union-all.md §2)."""

    rel: int
    branches: list[BoundQuery]
    types: list[DataType]


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
