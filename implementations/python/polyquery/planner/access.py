"""Access paths and estimates (indexes-and-planning.md §2-§3).

* :func:`column_predicate` recognizes conjuncts ``col <op> constant`` (also
  ``BETWEEN`` and ``IN`` lists) on a scanned column, with the constants
  evaluated at planning time and converted to the column's runtime
  representation. They drive index lookups and row-group skipping.
* :func:`choose_index` picks the most selective index lookup and keeps it
  only when its estimated selectivity is at most 10% of the table rows.
* :func:`selectivity` estimates the fraction of rows a predicate keeps,
  from table statistics (equality ≈ 1/distinct, ranges by linear
  interpolation between min and max, 1/3 otherwise).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

from .. import errors
from ..analysis import bound as b
from ..datatypes import DataType, TypeKind
from ..storage.indexes import HASH, Index, OrderedStructure
from ..storage.table import ChunkBounds, ColumnStats, RowGroup, Table
from ..values import POW10

INDEX_SELECTIVITY = 0.10
# a lookup expected to return at most this many rows always beats a scan
INDEX_MAX_TINY_ROWS = 2.0
DEFAULT_SELECTIVITY = 1.0 / 3.0

_FLIPPED = {"=": "=", "<": ">", "<=": ">=", ">": "<", ">=": "<="}
RANGE_OPS = frozenset({"<", "<=", ">", ">=", "BETWEEN"})

Evaluator = Callable[[b.Expr], Any]


@dataclass(frozen=True, eq=False)
class ColumnPredicate:
    """``column <op> values`` on a table column; ``values`` are runtime
    values of the column's type (one for comparisons, two for BETWEEN,
    any number for IN; NULL items of an IN list are dropped)."""

    column: int
    op: str  # = < <= > >= BETWEEN IN
    values: tuple[Any, ...]
    conjunct: b.Expr

    def render(self, table: Table) -> str:
        name = table.columns[self.column].name
        if self.op == "BETWEEN":
            return f"{name} BETWEEN {self.values[0]!r} AND {self.values[1]!r}"
        if self.op == "IN":
            return f"{name} IN ({', '.join(repr(v) for v in self.values)})"
        return f"{name} {self.op} {self.values[0]!r}"


def _has_side_effects(expr: b.Expr) -> bool:
    return any(isinstance(e, b.Function) and e.name == "PQ_SLEEP" for e in b.walk(expr))


def _constant(expr: b.Expr, column_type: DataType, evaluate: Evaluator) -> tuple[bool, Any]:
    """(usable, value): ``expr`` evaluated and converted to the column's
    representation; unusable if not constant, failing, or not exactly
    representable."""
    if not b.is_constant(expr) or _has_side_effects(expr):
        return False, None
    try:
        value = evaluate(expr)
    except errors.PolyQueryError:
        return False, None
    if value is None:
        return True, None
    t = expr.type
    if t == column_type:
        return True, value
    if t.kind is not column_type.kind:
        return False, None
    if t.kind is TypeKind.DECIMAL:
        diff = column_type.scale - t.scale
        if diff >= 0:
            return True, value * POW10[diff]
        if value % POW10[-diff]:
            return False, None
        return True, value // POW10[-diff]
    return True, value


def column_predicate(
    conjunct: b.Expr, rel: int, table: Table, evaluate: Evaluator
) -> ColumnPredicate | None:
    def column_of(expr: b.Expr) -> int | None:
        if isinstance(expr, b.ColumnRef) and expr.rel == rel:
            return expr.index
        return None

    if isinstance(conjunct, b.Compare) and conjunct.op in _FLIPPED:
        for col_expr, other, op in (
            (conjunct.left, conjunct.right, conjunct.op),
            (conjunct.right, conjunct.left, _FLIPPED[conjunct.op]),
        ):
            column = column_of(col_expr)
            if column is None:
                continue
            ok, value = _constant(other, table.columns[column].type, evaluate)
            if ok and value is not None:
                return ColumnPredicate(column, op, (value,), conjunct)
        return None
    if isinstance(conjunct, b.Between) and not conjunct.negated:
        column = column_of(conjunct.operand)
        if column is None:
            return None
        dtype = table.columns[column].type
        ok_low, low = _constant(conjunct.low, dtype, evaluate)
        ok_high, high = _constant(conjunct.high, dtype, evaluate)
        if ok_low and ok_high and low is not None and high is not None:
            return ColumnPredicate(column, "BETWEEN", (low, high), conjunct)
        return None
    if isinstance(conjunct, b.InList) and not conjunct.negated:
        column = column_of(conjunct.operand)
        if column is None:
            return None
        dtype = table.columns[column].type
        items = []
        for item in conjunct.items:
            ok, value = _constant(item, dtype, evaluate)
            if not ok:
                return None
            if value is not None:
                items.append(value)
        return ColumnPredicate(column, "IN", tuple(items), conjunct)
    return None


# ------------------------------------------------------------------ selectivity


def _as_number(v: Any) -> float:
    return float(v)


def predicate_selectivity(pred: ColumnPredicate, table: Table) -> float:
    stats = table.column_stats(pred.column)
    if stats.distinct_count == 0:
        return 0.0
    if pred.op == "=":
        return 1.0 / stats.distinct_count
    if pred.op == "IN":
        return min(1.0, len(set(pred.values)) / stats.distinct_count)
    low, high = range_bounds([pred])
    return range_selectivity(table.columns[pred.column].type, stats, low, high)


def range_selectivity(
    dtype: DataType, stats: ColumnStats, low: tuple[Any, bool] | None, high: tuple[Any, bool] | None
) -> float:
    """Linear interpolation between min and max for numeric/temporal types."""
    if stats.min is None:
        return 0.0
    if not (dtype.is_numeric or dtype.is_temporal):
        return DEFAULT_SELECTIVITY
    lo, hi = _as_number(stats.min), _as_number(stats.max)
    a = lo if low is None else max(lo, _as_number(low[0]))
    z = hi if high is None else min(hi, _as_number(high[0]))
    if z < a:
        return 0.0
    if hi == lo:
        return 1.0
    return min(1.0, (z - a) / (hi - lo))


def range_bounds(
    preds: list[ColumnPredicate],
) -> tuple[tuple[Any, bool] | None, tuple[Any, bool] | None]:
    """The tightest (value, inclusive) lower and upper bounds implied by
    range predicates on one column."""
    low: tuple[Any, bool] | None = None
    high: tuple[Any, bool] | None = None

    def tighten_low(value: Any, inclusive: bool) -> None:
        nonlocal low
        if low is None or value > low[0] or (value == low[0] and not inclusive):
            low = (value, inclusive)

    def tighten_high(value: Any, inclusive: bool) -> None:
        nonlocal high
        if high is None or value < high[0] or (value == high[0] and not inclusive):
            high = (value, inclusive)

    for p in preds:
        if p.op == "BETWEEN":
            tighten_low(p.values[0], True)
            tighten_high(p.values[1], True)
        elif p.op in (">", ">="):
            tighten_low(p.values[0], p.op == ">=")
        elif p.op in ("<", "<="):
            tighten_high(p.values[0], p.op == "<=")
    return low, high


ColumnResolver = Callable[[b.ColumnKey], tuple[Table, int] | None]


def selectivity(expr: b.Expr, resolve: ColumnResolver, evaluate: Evaluator) -> float:
    """Estimated fraction of rows for which ``expr`` is TRUE."""
    if isinstance(expr, b.Logical):
        left = selectivity(expr.left, resolve, evaluate)
        right = selectivity(expr.right, resolve, evaluate)
        return left * right if expr.op == "AND" else left + right - left * right
    if isinstance(expr, b.Not):
        return 1.0 - selectivity(expr.operand, resolve, evaluate)
    if isinstance(expr, b.Literal) and expr.type.kind is TypeKind.BOOLEAN:
        return 1.0 if expr.value is True else 0.0
    if isinstance(expr, b.IsNull) and isinstance(expr.operand, b.ColumnRef):
        found = resolve(expr.operand.key)
        if found is not None and found[0].row_count:
            table, column = found
            fraction = table.column_stats(column).null_count / table.row_count
            return 1.0 - fraction if expr.negated else fraction
    if isinstance(expr, b.Compare) and expr.op == "=":
        sides = [resolve(e.key) if isinstance(e, b.ColumnRef) else None for e in (expr.left, expr.right)]
        if sides[0] is not None and sides[1] is not None:
            distinct = max(t.column_stats(c).distinct_count for t, c in sides)  # type: ignore[misc]
            return 1.0 / distinct if distinct else 0.0
    column = _single_column(expr)
    if column is not None:
        found = resolve(column.key)
        if found is not None:
            table, _ = found
            pred = column_predicate(expr, column.rel, table, evaluate)
            if pred is not None:
                return predicate_selectivity(pred, table)
    return DEFAULT_SELECTIVITY


def _single_column(expr: b.Expr) -> b.ColumnRef | None:
    refs = [e for e in b.walk(expr) if isinstance(e, b.ColumnRef)]
    if refs and all(r.key == refs[0].key for r in refs):
        return refs[0]
    return None


# ------------------------------------------------------------------ index selection


@dataclass(frozen=True, eq=False)
class IndexLookup:
    """What an IndexScan looks up: a set of key values, or a key range."""

    values: tuple[Any, ...] | None = None
    low: tuple[Any, bool] | None = None
    high: tuple[Any, bool] | None = None

    def row_ids(self, index: Index) -> list[int]:
        structure = index.structure
        if self.values is not None:
            ids = structure.lookup_values(self.values)
        else:
            assert isinstance(structure, OrderedStructure)
            low = self.low or (None, True)
            high = self.high or (None, True)
            ids = structure.lookup_range(low[0], low[1], high[0], high[1])
        ids.sort()  # fetch rows in table order
        return ids


@dataclass(eq=False)
class IndexChoice:
    index: Index
    lookup: IndexLookup
    selectivity: float
    consumed: list[b.Expr] = field(default_factory=list)
    description: str = ""


def choose_index(
    table: Table, preds: list[ColumnPredicate], indexes: list[Index]
) -> IndexChoice | None:
    """The best index lookup for the predicates, if selective enough."""
    if not indexes or table.row_count == 0:
        return None
    candidates: list[IndexChoice] = []
    for index in indexes:
        on_column = [p for p in preds if p.column == index.column]
        for p in on_column:
            if p.op in ("=", "IN"):
                candidates.append(
                    IndexChoice(
                        index,
                        IndexLookup(values=p.values),
                        predicate_selectivity(p, table),
                        [p.conjunct],
                        p.render(table),
                    )
                )
        ranges = [p for p in on_column if p.op in RANGE_OPS]
        if ranges and index.structure.supports_ranges:
            low, high = range_bounds(ranges)
            stats = table.column_stats(index.column)
            sel = range_selectivity(table.columns[index.column].type, stats, low, high)
            text = " AND ".join(p.render(table) for p in ranges)
            candidates.append(
                IndexChoice(index, IndexLookup(low=low, high=high), sel, [p.conjunct for p in ranges], text)
            )
    if not candidates:
        return None
    # most selective first; for ties prefer hash lookups
    best = min(candidates, key=lambda c: (c.selectivity, c.index.kind != HASH))
    if best.selectivity <= INDEX_SELECTIVITY or best.selectivity * table.row_count <= INDEX_MAX_TINY_ROWS:
        return best
    return None


# ------------------------------------------------------------------ row-group skipping


def group_may_match(group: RowGroup, preds: list[ColumnPredicate]) -> bool:
    """False if the group's chunk statistics prove that some predicate is
    never TRUE in it."""
    bounds = group.bounds
    if bounds is None:
        return True
    for p in preds:
        if not _chunk_may_match(bounds[p.column], group.row_count, p):
            return False
    return True


def _chunk_may_match(bounds: ChunkBounds, rows: int, p: ColumnPredicate) -> bool:
    if bounds.null_count >= rows:
        return False  # only NULLs: no comparison is TRUE
    lo, hi = bounds.min, bounds.max
    op, values = p.op, p.values
    if op == "=":
        v = values[0]
        return not ((lo is not None and v < lo) or (hi is not None and v > hi))
    if op == "IN":
        return any(
            not ((lo is not None and v < lo) or (hi is not None and v > hi)) for v in values
        )
    if op == "BETWEEN":
        a, z = values
        return not ((hi is not None and hi < a) or (lo is not None and lo > z))
    v = values[0]
    if op == "<":
        return lo is None or lo < v
    if op == "<=":
        return lo is None or lo <= v
    if op == ">":
        return hi is None or hi > v
    return hi is None or hi >= v  # >=
