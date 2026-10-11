"""Execution paths that use the native kernels (``native: true`` with
``--native-kernels`` loaded; native-kernels.md).

Every path here computes exactly what the engine's own code computes, and
each one is only taken when it applies; otherwise the caller runs its usual
code. The kernels work on the column storage directly (no decoding into
Python objects), which is where they save time in CPython:

* **Scan filtering** (:class:`NativeFilter`): the conjuncts of a Filter
  directly above a TableScan of a column table that compare a column with
  constants (``=``, ``<>``, ``<``, ``<=``, ``>``, ``>=``, ``BETWEEN``,
  ``IN``) on INT64 / DECIMAL / DATE / TIMESTAMP columns, and on
  dictionary-encoded STRING columns (the constants are mapped to code
  ranges), become ``pqk_filter_i64_bitmap`` calls over windows of the
  stored arrays. Their bitmaps are combined with ``pqk_bitmap_and`` /
  ``pqk_bitmap_or`` / ``pqk_bitmap_andnot`` and counted with
  ``pqk_bitmap_popcount``; the selected positions come from
  ``pqk_filter_i64`` and the selected values of fixed-width columns are
  gathered with ``pqk_gather_i64``. Only the selected rows are ever turned
  into Python values. Remaining conjuncts are evaluated by the engine on
  the selected rows.
* **Scan aggregation** (:class:`NativeScanAggregate`): an aggregation
  without GROUP BY directly over such a (filtered) scan, whose aggregates
  are ``COUNT(*)``, ``COUNT(col)``, ``SUM``/``AVG`` of INT64 / DECIMAL
  columns and ``MIN``/``MAX`` of INT64 / DECIMAL / DATE / TIMESTAMP /
  FLOAT64 columns, is computed by ``pqk_sum_i64`` / ``pqk_minmax_i64`` /
  ``pqk_minmax_f64`` / popcounts with the selection bitmap as validity.
* **Grouped sums** (:class:`NativeGroupSums`): ``SUM`` / ``AVG`` / ``COUNT``
  states of the vectorized hash aggregation buffer (group id, value) pairs
  and fold them with ``pqk_group_sum_i64``.

Exactness: ``pqk_sum_i64`` reports results outside int64 and
``pqk_group_sum_i64`` reports possible wrap-around; in both cases the sum
is recomputed with Python integers, so overflow errors (and sums whose
partial results overflow but whose total does not) are unchanged. Float
sums stay with ``math.fsum`` (the kernel's reassociated sum could differ in
the last bits); float MIN/MAX results equal to zero are recomputed in
Python, since ``0.0`` and ``-0.0`` compare equal and the engine returns the
first one seen.
"""

from __future__ import annotations

import array
import bisect
import collections
import itertools
import operator
from dataclasses import dataclass
from typing import Any, Callable, Iterable, Iterator, Sequence

from .. import errors
from ..analysis import bound as b
from ..datatypes import TypeKind
from ..native import kernels as nk
from ..native.kernels import NativeKernels, address, new_bitmap
from ..planner import physical as pp
from ..planner.access import column_predicate, group_may_match
from ..storage.table import ColumnTable, RowGroup
from ..storage.vectors import ColumnVector, DictVector, PlainVector, bits_to_flags, flags_to_bits
from . import parallel
from .common import scan_range
from .compiler import evaluate_constant
from .context import ExecutionContext
from .group_states import CountStarState, CountState, GroupState, MinMaxState, SumState, make_state

# rows per kernel window (a multiple of 8, so windows start on bitmap bytes)
WINDOW_ROWS = 65536
# a term on a dictionary column is computed natively when the matching
# codes form at most this many ranges (else in Python from the codes)
MAX_CODE_RANGES = 32
MAX_IN_ITEMS = 64
# GROUP BY over a scan: at most this many groups (dictionary entries)
MAX_GROUP_CODES = 64

INT64_MIN, INT64_MAX = nk.INT64_MIN, nk.INT64_MAX
_INT_KINDS = frozenset({TypeKind.INT64, TypeKind.DECIMAL, TypeKind.DATE, TypeKind.TIMESTAMP})
_TERM_KINDS = _INT_KINDS | {TypeKind.STRING}
_FLIPPED = {"=": "=", "<>": "<>", "<": ">", "<=": ">=", ">": "<", ">=": "<="}

class NativeFallback(Exception):
    """A native path cannot finish exactly (a kernel reported a possible
    int64 wrap-around); the caller reruns the operator with its own code."""


# an all-zero int64 buffer: pqk_filter_i64 over it with an always-true
# predicate and a selection bitmap as validity lists the set bits. It is
# replaced when a larger one is needed; callers hold the buffer they got
# while a kernel reads it (other threads may replace it meanwhile).
_zeros = array.array("q")


def _zero_buffer(n: int) -> array.array:
    global _zeros
    zeros = _zeros
    if len(zeros) < n:
        zeros = _zeros = array.array("q", bytes(8 * max(n, WINDOW_ROWS)))
    return zeros


# ------------------------------------------------------------------ terms


Interval = tuple[int, int]  # inclusive bounds within the int64 range


@dataclass(frozen=True, eq=False)
class Term:
    """A conjunct ``column op constants`` on a table column. ``values`` are
    runtime values of the column's type (two for BETWEEN, any number for IN).
    With ``other`` set the conjunct is ``column op other`` between two
    columns of the same integer-represented type (``pqk_compare_i64``)."""

    column: int
    kind: TypeKind
    op: str  # = <> < <= > >= BETWEEN IN
    values: tuple[Any, ...]
    other: int | None = None

    def matches(self, v: Any) -> bool:
        """The predicate on one non-NULL value (Python reference semantics)."""
        op, values = self.op, self.values
        if op == "IN":
            return v in values
        if op == "BETWEEN":
            return values[0] <= v <= values[1]
        return _COMPARE[op](v, values[0])


_KERNEL_OPS = {"=": nk.EQ, "<>": nk.NE, "<": nk.LT, "<=": nk.LE, ">": nk.GT, ">=": nk.GE}
_COMPARE: dict[str, Callable[[Any, Any], bool]] = {
    "=": operator.eq,
    "<>": operator.ne,
    "<": operator.lt,
    "<=": operator.le,
    ">": operator.gt,
    ">=": operator.ge,
}


def _int_intervals(term: Term) -> list[Interval] | None:
    """The values of an integer term as a union of int64 intervals (empty
    list: no value matches); None for ``<>`` (handled by PQK_NE)."""
    op, values = term.op, term.values
    if op == "<>":
        return None
    if op == "IN":
        points = sorted(set(values))
        return [(v, v) for v in points if INT64_MIN <= v <= INT64_MAX]
    if op == "=":
        lo = hi = values[0]
    elif op == "BETWEEN":
        lo, hi = values
    elif op == "<":
        lo, hi = INT64_MIN, values[0] - 1
    elif op == "<=":
        lo, hi = INT64_MIN, values[0]
    elif op == ">":
        lo, hi = values[0] + 1, INT64_MAX
    else:  # >=
        lo, hi = values[0], INT64_MAX
    lo, hi = max(lo, INT64_MIN), min(hi, INT64_MAX)
    return [(lo, hi)] if lo <= hi else []


def _code_ranges(codes: list[int]) -> list[Interval]:
    """Sorted codes as maximal runs of consecutive codes."""
    out: list[Interval] = []
    for code in codes:
        if out and out[-1][1] == code - 1:
            out[-1] = (out[-1][0], code)
        else:
            out.append((code, code))
    return out


def _interval_kernel_args(lo: int, hi: int) -> tuple[int, int, int] | None:
    """(op, a, b) of a kernel predicate selecting ``lo <= x <= hi``; None if
    every value qualifies."""
    if lo == INT64_MIN and hi == INT64_MAX:
        return None
    if lo == hi:
        return nk.EQ, lo, 0
    if lo == INT64_MIN:
        return nk.LE, hi, 0
    if hi == INT64_MAX:
        return nk.GE, lo, 0
    return nk.BETWEEN, lo, hi


# ------------------------------------------------------------------ windows


class Window:
    """Rows ``base`` .. ``base + n - 1`` of a row group (``base`` a multiple
    of 8) of which rows before ``first`` (relative) belong to another scan
    range and must be excluded."""

    __slots__ = ("group", "base", "n", "first", "nbytes")

    def __init__(self, group: RowGroup, base: int, n: int, first: int):
        self.group = group
        self.base = base
        self.n = n
        self.first = first
        self.nbytes = (n + 7) >> 3

    def validity(self, vector: ColumnVector) -> int | None:
        """Address of the window's part of the vector's validity bitmap."""
        validity = vector.validity
        return None if validity is None else address(validity, self.base >> 3)

    def all_rows(self) -> array.array:
        """Bitmap of the window's rows in the scan range."""
        bits = array.array("B", b"\xff" * self.nbytes)
        tail = self.n & 7
        if tail:
            bits[-1] = (1 << tail) - 1
        self.clear_head(bits)
        return bits

    def clear_head(self, bits: array.array) -> None:
        first = self.first
        if first:
            bits[0] &= 0xFF ^ ((1 << first) - 1)


def windows(
    table: ColumnTable,
    keep: Callable[[RowGroup], bool] | None,
    start: int,
    stop: int | None,
    columns: Sequence[int],
) -> Iterator[Window]:
    """Windows of the row groups read by a scan. Like the engine's own scan,
    every scanned column of a row group is loaded (and, when memory-mapped,
    verified) before any of its rows is used, so a corrupt chunk fails the
    query whether or not the kernels select rows from that group."""
    for group, lo, hi in table.row_ranges(keep, start, stop):
        for column in columns:
            group.vector(column)
        base = lo & ~7
        first = lo - base
        while base < hi:
            end = min(base + WINDOW_ROWS, hi)
            yield Window(group, base, end - base, first)
            base, first = end, 0


# ------------------------------------------------------------------ filter


@dataclass(eq=False)
class NativeFilter:
    """The native part of a Filter over a TableScan. ``keep_null``: a term
    whose value is NULL keeps the row (it is not FALSE) — used when the
    residual predicate (then the whole original predicate) may raise
    errors, so that it is evaluated on exactly the rows the engine's own
    left-to-right AND evaluation would evaluate it on."""

    scan: pp.TableScan
    terms: list[Term]
    residual: b.Expr | None
    keep_null: bool

    def select(self, kernels: NativeKernels, window: Window) -> tuple[array.array, int]:
        """(bitmap of the window's rows passing every term, their count)."""
        bits: array.array | None = None
        group = window.group
        for term in self.terms:
            term_bits = self._term_bits(kernels, window, term, group.vector(term.column))
            if bits is None:
                bits = term_bits
            else:
                kernels.bitmap_and(bits, term_bits.buffer_info()[0], window.nbytes)
        assert bits is not None
        window.clear_head(bits)
        return bits, kernels.popcount(bits.buffer_info()[0], window.n)

    def _term_bits(self, kernels: NativeKernels, window: Window, term: Term, vector: ColumnVector) -> array.array:
        if term.other is not None:
            return self._columns_bits(kernels, window, term, vector, window.group.vector(term.other))
        n = window.n
        validity = window.validity(vector)
        data = vector.int64_view()
        if data is None:
            bits = _python_term_bits(window, term, vector)
        else:
            if isinstance(vector, DictVector):
                ranges, negate = _dictionary_ranges(vector, term)
                bits = _union_bits(kernels, address(data, window.base), validity, n, ranges, window.nbytes)
                if negate:  # the term holds for the valid rows outside the ranges
                    rest = _valid_bits(kernels, window, vector)
                    kernels.bitmap_andnot(rest, bits.buffer_info()[0], window.nbytes)
                    bits = rest
            else:
                bits = _int_term_bits(kernels, window, term, address(data, window.base), validity)
        if self.keep_null and validity is not None:
            nulls = window.all_rows()
            kernels.bitmap_andnot(nulls, validity, window.nbytes)
            kernels.bitmap_or(bits, nulls, window.nbytes)
        return bits


    def _columns_bits(
        self, kernels: NativeKernels, window: Window, term: Term, left: ColumnVector, right: ColumnVector
    ) -> array.array:
        """``left op right`` on the rows where both are non-NULL (and, with
        ``keep_null``, every row where one of them is NULL)."""
        a, c = left.int64_view(), right.int64_view()
        assert a is not None and c is not None
        bits = new_bitmap(window.n)
        kernels.compare(address(a, window.base), address(c, window.base), window.n, _KERNEL_OPS[term.op], bits)
        valid = _valid_bits(kernels, window, left)  # the kernel ignores validity
        if right.validity is not None:
            kernels.bitmap_and(valid, window.validity(right), window.nbytes)
        kernels.bitmap_and(bits, valid.buffer_info()[0], window.nbytes)
        if self.keep_null and (left.validity is not None or right.validity is not None):
            nulls = window.all_rows()
            kernels.bitmap_andnot(nulls, valid.buffer_info()[0], window.nbytes)
            kernels.bitmap_or(bits, nulls, window.nbytes)
        return bits


def _valid_bits(kernels: NativeKernels, window: Window, vector: ColumnVector) -> array.array:
    """Bitmap of the window's non-NULL rows."""
    bits = window.all_rows()
    if vector.validity is not None:
        kernels.bitmap_and(bits, window.validity(vector), window.nbytes)
    return bits


def _int_term_bits(kernels: NativeKernels, window: Window, term: Term, data: int, validity: int | None) -> array.array:
    intervals = _int_intervals(term)
    if intervals is None:  # <>
        bits = new_bitmap(window.n)
        value = term.values[0]
        if INT64_MIN <= value <= INT64_MAX:
            kernels.filter_bitmap(data, validity, window.n, nk.NE, value, 0, bits)
            return bits
        intervals = [(INT64_MIN, INT64_MAX)]
    return _union_bits(kernels, data, validity, window.n, intervals, window.nbytes)


def _union_bits(
    kernels: NativeKernels, data: int, validity: int | None, n: int, intervals: list[Interval], nbytes: int
) -> array.array:
    """Bitmap of the valid rows whose value lies in one of the intervals."""
    bits = new_bitmap(n)
    if not intervals:
        return bits
    part = new_bitmap(n) if len(intervals) > 1 else bits
    for k, (lo, hi) in enumerate(intervals):
        target = bits if k == 0 else part
        args = _interval_kernel_args(lo, hi)
        if args is None:  # every valid row
            kernels.filter_bitmap(data, validity, n, nk.GE, INT64_MIN, 0, target)
        else:
            kernels.filter_bitmap(data, validity, n, args[0], args[1], args[2], target)
        if k:
            kernels.bitmap_or(bits, part, nbytes)
    return bits


def _dictionary_ranges(vector: DictVector, term: Term) -> tuple[list[Interval], bool]:
    """Code ranges of the dictionary entries satisfying the term, or (when
    fewer) of those not satisfying it with ``negate`` set."""
    matches = term.matches
    flags = [matches(v) for v in vector.dictionary]
    hit = [c for c, f in enumerate(flags) if f]
    if len(hit) * 2 <= len(flags):
        return _code_ranges(hit), False
    return _code_ranges([c for c, f in enumerate(flags) if not f]), True


def _python_term_bits(window: Window, term: Term, vector: ColumnVector) -> array.array:
    """A term over a representation without int64 view (plain strings)."""
    values = vector.to_list(window.base, window.base + window.n)
    matches = term.matches
    flags = bytes([v is not None and matches(v) for v in values])
    return array.array("B", flags_to_bits(flags))


def compile_filter(node: pp.Filter, ctx: ExecutionContext) -> NativeFilter | None:
    """The native plan of a Filter, if its input is a TableScan of a column
    table and some conjunct can be computed by the kernels."""
    scan = node.input
    if not isinstance(scan, pp.TableScan) or not isinstance(scan.table, ColumnTable):
        return None
    conjuncts = b.conjuncts(node.predicate)
    failing = [i for i, c in enumerate(conjuncts) if b.may_fail(c)]
    # with a conjunct that may raise, only conjuncts before it may be
    # evaluated first (and they then keep their NULL rows, see keep_null)
    limit = failing[0] if failing else len(conjuncts)
    terms: list[Term] = []
    rest: list[b.Expr] = []
    for i, conjunct in enumerate(conjuncts):
        term = _term(conjunct, scan, keep_null=bool(failing)) if i < limit else None
        if term is None:
            rest.append(conjunct)
        else:
            terms.append(term)
    if not terms:
        return None
    residual = node.predicate if failing else b.conjunction(rest)
    return NativeFilter(scan, terms, residual, bool(failing))


def _term(conjunct: b.Expr, scan: pp.TableScan, keep_null: bool) -> Term | None:
    table = scan.table
    if isinstance(conjunct, b.Compare) and conjunct.op in _KERNEL_OPS:
        left, right = conjunct.left, conjunct.right
        if isinstance(left, b.ColumnRef) and isinstance(right, b.ColumnRef):
            same = left.rel == right.rel == scan.rel and left.type == right.type
            if same and left.type.kind in _INT_KINDS:
                return Term(left.index, left.type.kind, conjunct.op, (), right.index)
            return None
    negated = isinstance(conjunct, b.Compare) and conjunct.op == "<>"
    probe = conjunct
    if negated:
        assert isinstance(conjunct, b.Compare)
        probe = b.Compare(conjunct.type, "=", conjunct.left, conjunct.right)
    if isinstance(probe, b.InList) and keep_null and any(
        isinstance(i, b.Literal) and i.value is None for i in probe.items
    ):
        return None  # x IN (…, NULL) is NULL, not FALSE, for non-matching x
    try:
        pred = column_predicate(probe, scan.rel, table, evaluate_constant)
    except errors.PolyQueryError:
        return None
    if pred is None:
        return None
    column = pred.column
    if column not in scan.columns:
        return None
    kind = table.columns[column].type.kind
    if kind not in _TERM_KINDS:
        return None
    op = "<>" if negated else pred.op
    if op == "IN" and len(pred.values) > MAX_IN_ITEMS:
        return None
    if op == "IN" and len(pred.values) != len(probe.items) and keep_null:  # type: ignore[union-attr]
        return None
    return Term(column, kind, op, pred.values)


# ------------------------------------------------------------------ selected rows


def selected_positions(kernels: NativeKernels, bits: array.array, n: int, count: int) -> array.array:
    """Window-relative positions of the set bits (ascending)."""
    idx = array.array("I", bytes(4 * n))  # the kernel's output capacity must be n
    zeros = _zero_buffer(n)
    found = kernels.filter_indices(address(zeros), bits.buffer_info()[0], n, nk.GE, INT64_MIN, 0, idx)
    if found != count:
        raise nk.NativeKernelError(f"pqk_filter_i64 selected {found} rows, popcount {count}")
    del idx[count:]
    return idx


def gather_column(
    kernels: NativeKernels, window: Window, vector: ColumnVector, bits: array.array, idx: array.array
) -> list[Any]:
    """The runtime values of one column at the selected rows (``idx``: the
    positions of the bits set in ``bits``)."""
    base, k = window.base, len(idx)
    if isinstance(vector, DictVector) or (
        isinstance(vector, PlainVector) and isinstance(vector.data, array.array) and vector.data.itemsize >= 4
    ):
        if isinstance(vector, PlainVector) and vector.data.typecode == "d":
            data, out = vector.data, array.array("d", bytes(8 * k))
        else:
            data, out = vector.int64_view(), array.array("q", bytes(8 * k))
        kernels.gather(address(data, base), idx, k, out)
        values: list[Any] = out.tolist()
        if isinstance(vector, DictVector):
            values = list(map(vector.dictionary.__getitem__, values))
    else:
        assert isinstance(vector, PlainVector)
        positions = idx.tolist()
        chunk = vector.data[base : base + window.n]
        values = [chunk[i] for i in positions] if len(positions) < 2 else list(operator.itemgetter(*positions)(chunk))
        if vector.dtype.kind is TypeKind.BOOLEAN:
            values = list(map(bool, values))
    if vector.validity is not None:
        _apply_nulls(kernels, window, vector, bits, idx, values)
    return values


def _apply_nulls(
    kernels: NativeKernels, window: Window, vector: ColumnVector, bits: array.array, idx: array.array, values: list[Any]
) -> None:
    """Sets the gathered values of the selected NULL rows to None."""
    validity = window.validity(vector)
    nulls_bits = array.array("B", bits)
    kernels.bitmap_andnot(nulls_bits, validity, window.nbytes)  # selected and NULL
    nulls = kernels.popcount(nulls_bits.buffer_info()[0], window.n)
    if not nulls:
        return
    if nulls * 16 < len(idx):  # few: find their output positions by bisection
        rows = selected_positions(kernels, nulls_bits, window.n, nulls)
        positions: Iterable[int] = map(bisect.bisect_left, itertools.repeat(idx), rows)
    else:
        assert vector.validity is not None
        start = window.base >> 3
        flags = bits_to_flags(vector.validity[start : start + window.nbytes], window.n)
        positions = itertools.compress(range(len(idx)), map(operator.not_, map(flags.__getitem__, idx)))
    collections.deque(map(values.__setitem__, positions, itertools.repeat(None)), maxlen=0)


def filtered_batches(
    native: NativeFilter, ctx: ExecutionContext, batch_rows: int
) -> Iterator[tuple[list[list[Any]], int]]:
    """Batches (columns of the scan's layout) of the scanned rows that pass
    the native terms; the residual predicate is left to the caller."""
    kernels = ctx.native
    assert kernels is not None
    scan = native.scan
    table = scan.table
    assert isinstance(table, ColumnTable)
    skip = scan.skip
    keep = (lambda group: group_may_match(group, skip)) if skip else None
    start, stop = scan_range(scan, ctx, table.row_count)
    ctx.check()
    for window in windows(table, keep, start, stop, scan.columns):
        bits, count = native.select(kernels, window)
        if count:
            group = window.group
            if count == window.n:  # every row: plain decoding is cheaper
                lo, hi = window.base, window.base + window.n
                cols = [group.vector(i).to_list(lo, hi) for i in scan.columns]
            else:
                idx = selected_positions(kernels, bits, window.n, count)
                cols = [gather_column(kernels, window, group.vector(i), bits, idx) for i in scan.columns]
            if count <= batch_rows:
                yield cols, count
            else:
                for lo in range(0, count, batch_rows):
                    yield [c[lo : lo + batch_rows] for c in cols], min(batch_rows, count - lo)
        ctx.check()


def python_rows(gather: pp.Gather, ctx: ExecutionContext) -> float:
    """Estimated number of rows a parallel pipeline turns into Python values
    (which is what worker processes can speed up): the rows of its driving
    scan, or only those selected by the kernels if the scan is filtered
    natively."""
    rows = gather.driver.estimated_rows
    path = pp.pipeline_path(gather.input)
    if ctx.native is not None and path and len(path) >= 2:
        parent = path[-2]
        if isinstance(parent, pp.Filter) and native_filter(parent, ctx) is not None:
            rows = parent.estimated_rows
    return rows


def native_filter(node: pp.Filter, ctx: ExecutionContext) -> NativeFilter | None:
    """The cached native plan of a Filter for this statement (None if the
    kernels are not in use or do not apply)."""
    if ctx.native is None:
        return None
    plan = ctx.cached(node, "native:filter", lambda: compile_filter(node, ctx) or False)
    return plan or None


# ------------------------------------------------------------------ scan aggregation


@dataclass(frozen=True, eq=False)
class _AggSpec:
    call: b.AggCall
    column: int | None  # table column of the argument (None for COUNT(*))


@dataclass(eq=False)
class NativeScanAggregate:
    """An aggregation directly over a (natively filtered) TableScan, without
    GROUP BY or grouped by one low-cardinality STRING column. Each window's
    groups are bitmaps (the selection, ANDed for a key with the rows of each
    dictionary code), and every aggregate of a group is one kernel call
    over the column storage with that bitmap as validity."""

    scan: pp.TableScan
    filter: NativeFilter | None
    specs: list[_AggSpec]
    key: int | None  # table column of the GROUP BY key
    width: int  # output width (memory accounting of new groups)

    def partition(self, ctx: ExecutionContext) -> tuple[list[Any], list[GroupState]]:
        """The partial aggregation of the scan range of the current partition,
        in the vectorized engine's form: group keys in first-seen order and
        the columnar state of every aggregate."""
        kernels = ctx.native
        assert kernels is not None
        scan = self.scan
        table = scan.table
        assert isinstance(table, ColumnTable)
        states = [make_state(spec.call) for spec in self.specs]
        index: dict[Any, int] = {}  # group key -> dense group id
        if self.key is None:
            index[()] = 0
            for state in states:
                state.grow(1)
        skip = scan.skip
        keep = (lambda group: group_may_match(group, skip)) if skip else None
        start, stop = scan_range(scan, ctx, table.row_count)
        ctx.check()
        counter = self._counter()
        for window in windows(table, keep, start, stop, scan.columns):
            if counter is not None and not window.first:  # only COUNT(*) WHERE <one comparison>
                count = counter(kernels, window)
                if count:
                    states[0].counts[0] += count  # type: ignore[attr-defined]
                ctx.check()
                continue
            if self.filter is not None:
                sel, count = self.filter.select(kernels, window)
            else:
                sel = window.all_rows()
                count = kernels.popcount(sel.buffer_info()[0], window.n)
            if count:
                if self.key is None:
                    groups = [(0, sel, count)]
                else:
                    groups = self._groups(kernels, window, sel, count, index, states, ctx)
                for gid, bits, n in groups:
                    for spec, state in zip(self.specs, states):
                        _accumulate(kernels, window, bits, n, spec, state, gid)
            ctx.check()
        return list(index), states

    def _counter(self) -> Callable[[NativeKernels, Window], int] | None:
        """``SELECT COUNT(*) … WHERE col op constant`` on a plain integer
        column: one ``pqk_count_i64`` call per window."""
        native = self.filter
        if self.key is not None or len(self.specs) != 1 or self.specs[0].column is not None:
            return None
        if native is None or native.keep_null or len(native.terms) != 1:
            return None
        term = native.terms[0]
        if term.other is not None or term.kind is TypeKind.STRING:
            return None
        intervals = _int_intervals(term)
        if intervals is None:
            if not INT64_MIN <= term.values[0] <= INT64_MAX:
                return None
            args: tuple[int, int, int] | None = (nk.NE, term.values[0], 0)
        elif len(intervals) == 1:
            args = _interval_kernel_args(*intervals[0])
        else:
            return None
        op, a, c = args if args is not None else (nk.GE, INT64_MIN, 0)

        def count(kernels: NativeKernels, window: Window) -> int:
            vector = window.group.vector(term.column)
            data = vector.int64_view()
            if data is None or isinstance(vector, DictVector):
                raise NativeFallback()
            return kernels.count(address(data, window.base), window.validity(vector), window.n, op, a, c)

        return count

    def _groups(
        self,
        kernels: NativeKernels,
        window: Window,
        sel: array.array,
        count: int,
        index: dict[Any, int],
        states: list[GroupState],
        ctx: ExecutionContext,
    ) -> list[tuple[int, array.array, int]]:
        """(group id, row bitmap, row count) of the window's groups, new
        groups registered in the order of their first row."""
        assert self.key is not None
        vector = window.group.vector(self.key)
        if not isinstance(vector, DictVector) or len(vector.dictionary) > MAX_GROUP_CODES:
            self._update_rows(kernels, window, sel, count, vector, index, states, ctx)
            return []
        codes = address(vector.int64_view(), window.base)
        validity = window.validity(vector)
        sel_addr = sel.buffer_info()[0]
        found: list[tuple[int, Any, array.array, int]] = []
        for code, value in enumerate(vector.dictionary):
            bits = new_bitmap(window.n)
            if kernels.filter_bitmap(codes, validity, window.n, nk.EQ, code, 0, bits):
                kernels.bitmap_and(bits, sel_addr, window.nbytes)
                n = kernels.popcount(bits.buffer_info()[0], window.n)
                if n:
                    found.append((_first_bit(bits), value, bits, n))
        if validity is not None:  # NULL keys form one group
            bits = array.array("B", sel)
            kernels.bitmap_andnot(bits, validity, window.nbytes)
            n = kernels.popcount(bits.buffer_info()[0], window.n)
            if n:
                found.append((_first_bit(bits), None, bits, n))
        found.sort(key=operator.itemgetter(0))
        out = []
        for _, value, bits, n in found:
            out.append((_group_id(value, index, states, ctx, self.width), bits, n))
        return out

    def _update_rows(
        self,
        kernels: NativeKernels,
        window: Window,
        sel: array.array,
        count: int,
        key_vector: ColumnVector,
        index: dict[Any, int],
        states: list[GroupState],
        ctx: ExecutionContext,
    ) -> None:
        """A window whose key is not a small dictionary: the selected rows are
        gathered and fed to the states row by row."""
        idx = selected_positions(kernels, sel, window.n, count)
        keys = gather_column(kernels, window, key_vector, sel, idx)
        for key in dict.fromkeys(keys):
            if key not in index:
                _group_id(key, index, states, ctx, self.width)
        ids = list(map(index.__getitem__, keys))
        group = window.group
        for spec, state in zip(self.specs, states):
            if spec.column is None:
                state.update_rows(ids, None)
            else:
                state.update_rows(ids, gather_column(kernels, window, group.vector(spec.column), sel, idx))


def _group_id(key: Any, index: dict[Any, int], states: list[GroupState], ctx: ExecutionContext, width: int) -> int:
    gid = index.get(key)
    if gid is None:
        gid = index[key] = len(index)
        for state in states:
            state.grow(1)
        ctx.reserve_rows(1, width)
    return gid


def _first_bit(bits: array.array) -> int:
    raw = bits.tobytes()
    byte = len(raw) - len(raw.lstrip(b"\x00"))
    value = raw[byte]
    return byte * 8 + (value & -value).bit_length() - 1


def _accumulate(
    kernels: NativeKernels,
    window: Window,
    bits: array.array,
    count: int,
    spec: _AggSpec,
    state: GroupState,
    gid: int,
) -> None:
    """Adds the rows set in ``bits`` to group ``gid`` of one aggregate."""
    if spec.column is None:
        assert isinstance(state, CountStarState)
        state.counts[gid] += count
        return
    vector = window.group.vector(spec.column)
    validity = window.validity(vector)
    rows = bits
    if validity is not None:  # selected and non-NULL
        rows = array.array("B", bits)
        kernels.bitmap_and(rows, validity, window.nbytes)
        count = kernels.popcount(rows.buffer_info()[0], window.n)
        if not count:
            return
    kind = type(state)
    if kind is CountState:
        state.counts[gid] += count  # type: ignore[attr-defined]
        return
    rows_addr = rows.buffer_info()[0]
    data = None if isinstance(vector, DictVector) else vector.int64_view()
    if kind is SumState and data is not None:
        assert isinstance(state, SumState)
        total = kernels.sum_i64(address(data, window.base), rows_addr, window.n)
        if total is None:  # outside int64: recompute exactly
            total = sum(_selected_values(kernels, window, vector, rows, count))
        state.totals[gid] += total
        state.counts[gid] += count
        return
    if kind is MinMaxState:
        assert isinstance(state, MinMaxState)
        if isinstance(vector, PlainVector) and vector.dtype.kind is TypeKind.FLOAT64:
            _, lo, hi = kernels.minmax_f64(address(vector.data, window.base), rows_addr, window.n)
            value = lo if state.is_min else hi
            if value != 0.0:  # (0.0 vs -0.0: the first one seen wins, see below)
                state._offer(gid, value)
                return
        elif data is not None:
            _, lo, hi = kernels.minmax_i64(address(data, window.base), rows_addr, window.n)
            state._offer(gid, lo if state.is_min else hi)
            return
    # any other aggregate: the state's own update over the selected values
    values = _selected_values(kernels, window, vector, rows, count)
    state.update_runs([(gid, 0, len(values))], values)


def _selected_values(
    kernels: NativeKernels, window: Window, vector: ColumnVector, rows: array.array, count: int
) -> list[Any]:
    """The values of the rows set in ``rows``."""
    idx = selected_positions(kernels, rows, window.n, count)
    return gather_column(kernels, window, vector, rows, idx)


_SUM_KINDS = frozenset({TypeKind.INT64, TypeKind.DECIMAL})


def compile_scan_aggregate(
    node: pp.HashAggregate, ctx: ExecutionContext
) -> NativeScanAggregate | NativeHashScanAggregate | None:
    """The native plan of an aggregation whose input is a (natively
    filtered, possibly partitioned) TableScan of a column table and whose
    keys and arguments are columns of that scan."""
    source = node.input.input if isinstance(node.input, pp.Gather) else node.input
    native: NativeFilter | None = None
    if isinstance(source, pp.Filter):
        native = native_filter(source, ctx)
        if native is None or native.residual is not None:
            return None
        scan: pp.PhysicalNode = native.scan
    else:
        scan = source
    if not isinstance(scan, pp.TableScan) or not isinstance(scan.table, ColumnTable):
        return None

    def column_of(expr: b.Expr) -> int | None:
        if isinstance(expr, b.ColumnRef) and expr.rel == scan.rel:  # type: ignore[union-attr]
            return expr.index
        return None

    keys = [column_of(k) for k in node.keys]
    specs: list[_AggSpec] = []
    for call in node.aggregates:
        column = None if call.arg is None else column_of(call.arg)
        if call.arg is not None and column is None:
            return None
        specs.append(_AggSpec(call, column))
    if None in keys:
        return None
    columns = scan.table.columns
    if not keys:
        return NativeScanAggregate(scan, native, specs, None, len(node.layout))
    if len(keys) == 1 and columns[keys[0]].type.kind is TypeKind.STRING and node.estimated_rows <= MAX_GROUP_CODES:
        return NativeScanAggregate(scan, native, specs, keys[0], len(node.layout))
    for spec in specs:
        call = spec.call
        if call.distinct or call.name not in ("COUNT", "SUM", "AVG"):
            return None
        if call.name != "COUNT" and columns[spec.column].type.kind not in _SUM_KINDS:  # type: ignore[index]
            return None
    return NativeHashScanAggregate(scan, native, specs, keys, len(node.layout))  # type: ignore[arg-type]


@dataclass(eq=False)
class NativeHashScanAggregate:
    """GROUP BY columns of a (natively filtered) TableScan with COUNT and
    integer SUM / AVG aggregates of its columns, for any number of groups.
    The engine maps each window's keys to dense group ids (dict lookups);
    ``pqk_group_sum_i64`` then adds the value columns into int64 sums and
    counts, reading them directly from the column storage when the whole
    window is selected (else from natively gathered values). If the kernel
    reports a possible wrap-around, :class:`NativeFallback` is raised and
    the aggregation runs again in the engine's exact Python arithmetic.

    With parallel workers and a single integer key the groups are *hash
    partitioned* (:meth:`hash_partition`): every worker scans the whole
    table but keeps only the rows whose key hashes (``pqk_hash_i64``) into
    its share of the hash range, so the workers' groups are disjoint and
    merging their results is a concatenation instead of a lookup per group."""

    scan: pp.TableScan
    filter: NativeFilter | None
    specs: list[_AggSpec]
    keys: list[int]  # table columns of the GROUP BY keys
    width: int

    def partition(self, ctx: ExecutionContext) -> tuple[list[Any], list[GroupState]]:
        """Serial aggregation of the scan range (raises NativeFallback)."""
        start, stop = scan_range(self.scan, ctx, self.scan.table.row_count)
        index, sums, counts, _ = self._aggregate(ctx, start, stop, None)
        return list(index), self._states(sums, counts)

    def hash_partitionable(self) -> bool:
        return len(self.keys) == 1 and self.scan.table.columns[self.keys[0]].type.kind in _INT_KINDS

    def hash_partition(self, ctx: ExecutionContext) -> tuple[list[Any], list[array.array], list[array.array], list[int]] | None:
        """The groups of hash partition ``ctx.partitions[scan]`` over the whole
        scan: (keys, sums, counts, first row of each group); None if the
        kernels reported a possible overflow."""
        part = ctx.partitions[id(self.scan)]
        try:
            index, sums, counts, firsts = self._aggregate(ctx, 0, None, part)
        except NativeFallback:
            return None
        return list(index), sums, counts, firsts

    def merge_hash_partitions(
        self, parts: list[tuple[list[Any], list[array.array], list[array.array], list[int]]]
    ) -> tuple[list[Any], list[GroupState]]:
        """Concatenates the disjoint groups of the hash partitions and orders
        them by their first row, i.e. as a serial scan would have found them."""
        keys: list[Any] = []
        firsts: list[int] = []
        sums: list[list[int]] = [[] for _ in self.specs]
        counts: list[list[int]] = [[] for _ in self.specs]
        for part_keys, part_sums, part_counts, part_firsts in parts:
            keys += part_keys
            firsts += part_firsts
            for k in range(len(self.specs)):
                sums[k] += part_sums[k].tolist()
                counts[k] += part_counts[k].tolist()
        order = sorted(range(len(keys)), key=firsts.__getitem__)
        states = self._states([take_list(s, order) for s in sums], [take_list(c, order) for c in counts])
        return take_list(keys, order), states

    def _states(self, sums: Sequence[Sequence[int]], counts: Sequence[Sequence[int]]) -> list[GroupState]:
        states = [make_state(spec.call) for spec in self.specs]
        for state, total, count in zip(states, sums, counts):
            state.counts = list(count)  # type: ignore[attr-defined]
            if isinstance(state, SumState):
                state.totals = list(total)
        return states

    def _aggregate(
        self, ctx: ExecutionContext, start: int, stop: int | None, part: tuple[int, int] | None
    ) -> tuple[dict[Any, int], list[array.array], list[array.array], list[int]]:
        kernels = ctx.native
        assert kernels is not None
        scan = self.scan
        table = scan.table
        assert isinstance(table, ColumnTable)
        index: dict[Any, int] = {}
        sums = [array.array("q") for _ in self.specs]
        counts = [array.array("q") for _ in self.specs]
        firsts: list[int] = []  # (hash partitions) global first row of each group
        reserved = ctx.memory_used
        skip = scan.skip
        keep = (lambda group: group_may_match(group, skip)) if skip else None
        ctx.check()
        try:
            for window in windows(table, keep, start, stop, scan.columns):
                if self.filter is not None:
                    sel, count = self.filter.select(kernels, window)
                else:
                    sel = window.all_rows()
                    count = window.n - window.first
                if count and part is not None:
                    count = _hash_select(kernels, window, window.group.vector(self.keys[0]), part, sel)
                if count:
                    self._window(kernels, window, sel, count, index, sums, counts, ctx, firsts if part else None)
                ctx.check()
        except NativeFallback:
            ctx.memory_used = reserved  # the engine's own path accounts again
            raise
        return index, sums, counts, firsts

    def _window(
        self,
        kernels: NativeKernels,
        window: Window,
        sel: array.array,
        count: int,
        index: dict[Any, int],
        sums: list[array.array],
        counts: list[array.array],
        ctx: ExecutionContext,
        firsts: list[int] | None,
    ) -> None:
        group = window.group
        whole = count == window.n  # every row of the window: no gathering
        idx = None if whole else selected_positions(kernels, sel, window.n, count)
        lo, hi = window.base, window.base + window.n
        key_cols = [
            group.vector(k).to_list(lo, hi) if idx is None else gather_column(kernels, window, group.vector(k), sel, idx)
            for k in self.keys
        ]
        keys = key_cols[0] if len(key_cols) == 1 else list(zip(*key_cols))
        missing = list(itertools.filterfalse(index.__contains__, dict.fromkeys(keys)))
        if missing:
            first = len(index)
            index.update(zip(missing, range(first, first + len(missing))))
            zeros = bytes(8 * len(missing))
            for arr in itertools.chain(sums, counts):
                arr.frombytes(zeros)
            ctx.reserve_rows(len(missing), self.width)
            if firsts is not None:
                # position of each new key's first row (reversed: the earliest wins)
                at = dict(zip(reversed(keys), range(len(keys) - 1, -1, -1)))
                offset = group.start + window.base
                rows = [at[k] for k in missing]
                firsts.extend(offset + (r if idx is None else idx[r]) for r in rows)
        ids = array.array("I", map(index.__getitem__, keys))
        ngroups = len(index)
        zeros = _zero_buffer(count)
        for spec, total, count_ in zip(self.specs, sums, counts):
            values: int = address(zeros)  # type: ignore[assignment]
            validity: int | None = None
            gathered = valid_bits = None  # (kept alive until the kernel call)
            if spec.column is not None:
                vector = group.vector(spec.column)
                data = None if spec.call.name == "COUNT" else vector.int64_view()
                if idx is None:
                    validity = window.validity(vector)
                    if data is not None:
                        values = address(data, window.base)  # type: ignore[assignment]
                else:
                    if vector.validity is not None:
                        valid_bits = _gathered_validity(window, vector, idx)
                        validity = valid_bits.buffer_info()[0]
                    if data is not None:
                        gathered = array.array("q", bytes(8 * count))
                        kernels.gather(address(data, window.base), idx, count, gathered)
                        values = gathered.buffer_info()[0]
            if not kernels.group_sum_i64(ids, values, validity, count, total, count_, ngroups):
                raise NativeFallback()


# hash partitioning: partitions own contiguous ranges of the low HASH_BITS bits
HASH_BITS = 16
HASH_SEED = 0x9E3779B97F4A7C15
_hash_masks = array.array("q")


def _hash_mask_buffer(n: int) -> array.array:
    """At least n int64 masks selecting the low HASH_BITS bits (held by the
    caller during the kernel call, like :func:`_zero_buffer`)."""
    global _hash_masks
    masks = _hash_masks
    if len(masks) < n:
        masks = _hash_masks = array.array("q", [(1 << HASH_BITS) - 1]) * max(n, WINDOW_ROWS)
    return masks


def _hash_select(
    kernels: NativeKernels, window: Window, key: ColumnVector, part: tuple[int, int], sel: array.array
) -> int:
    """Restricts ``sel`` to the rows whose key hashes into partition
    ``part = (index, count)``; returns the remaining row count. NULL keys
    (stored as 0) all hash alike, so the NULL group stays in one partition."""
    data = key.int64_view()
    if data is None:
        raise NativeFallback()
    n = window.n
    hashes = array.array("q", bytes(8 * n))
    kernels.hash_i64(address(data, window.base), n, HASH_SEED, hashes)
    pa = hashes.buffer_info()[0]
    masks = _hash_mask_buffer(n)
    kernels.bitmap_and_raw(pa, address(masks), pa, 8 * n)  # low HASH_BITS bits
    index, count = part
    space = 1 << HASH_BITS
    lo, hi = space * index // count, space * (index + 1) // count - 1
    mine = new_bitmap(n)
    kernels.filter_bitmap(pa, None, n, nk.BETWEEN, lo, hi, mine)
    kernels.bitmap_and(sel, mine.buffer_info()[0], window.nbytes)
    return kernels.popcount(sel.buffer_info()[0], n)


def take_list(values: Sequence[Any], order: Sequence[int]) -> list[Any]:
    return [values[i] for i in order] if len(order) < 2 else list(operator.itemgetter(*order)(values))


def run_scan_aggregate(
    native: NativeScanAggregate | NativeHashScanAggregate, node: pp.HashAggregate, ctx: ExecutionContext
) -> tuple[list[Any], list[GroupState]] | None:
    """Runs a native scan aggregation: hash partitioned in worker processes
    when the plan has a parallel pipeline below and the input is large,
    else serially (the kernels leave too little work per row to pay for
    worker processes). None if the engine must aggregate itself."""
    gather = node.input if isinstance(node.input, pp.Gather) else None
    if (
        isinstance(native, NativeHashScanAggregate)
        and gather is not None
        and native.hash_partitionable()
        and parallel.use_processes(gather, ctx)
    ):
        parts = parallel.run_partitions(gather, ctx, lambda: native.hash_partition(ctx))
        if any(part is None for part in parts):
            return None
        return native.merge_hash_partitions(parts)  # type: ignore[arg-type]
    try:
        return native.partition(ctx)
    except NativeFallback:
        return None


def _gathered_validity(window: Window, vector: ColumnVector, idx: array.array) -> array.array:
    """The validity bitmap of the gathered rows ``idx``."""
    assert vector.validity is not None
    start = window.base >> 3
    flags = bits_to_flags(vector.validity[start : start + window.nbytes], window.n)
    return array.array("B", flags_to_bits(bytes(map(flags.__getitem__, idx))))


def native_scan_aggregate(
    node: pp.HashAggregate, ctx: ExecutionContext
) -> NativeScanAggregate | NativeHashScanAggregate | None:
    if ctx.native is None:
        return None
    plan = ctx.cached(node, "native:aggregate", lambda: compile_scan_aggregate(node, ctx) or False)
    return plan or None


# ------------------------------------------------------------------ grouped sums


class NativeGroupSums:
    """Buffers the (group id, value) pairs of SUM / AVG / COUNT states of a
    vectorized hash aggregation and folds them into the states with
    ``pqk_group_sum_i64`` (one call per ~1M rows instead of a Python loop
    per row). Values are INT64 or unscaled DECIMAL, so they fit in int64."""

    FLUSH_ROWS = 1 << 20

    def __init__(self, kernels: NativeKernels, states: Sequence[GroupState]):
        self.kernels = kernels
        # per handled state: [ids, values]; COUNT(*) needs only ids
        self.buffers: dict[int, tuple[GroupState, array.array, array.array | None]] = {}
        for k, state in enumerate(states):
            if type(state) in (CountStarState, CountState, SumState):
                values = array.array("q") if isinstance(state, SumState) else None
                self.buffers[k] = (state, array.array("I"), values)
        self.pending = 0

    def handles(self, k: int) -> bool:
        return k in self.buffers

    def add(self, k: int, ids: array.array, vals: Sequence[Any] | None) -> None:
        """Rows of one batch for state ``k`` (``ids``: group id per row)."""
        state, buf_ids, buf_values = self.buffers[k]
        if vals is not None and None in vals:  # NULLs do not count
            keep = list(map(operator.is_not, vals, itertools.repeat(None)))
            buf_ids.extend(itertools.compress(ids, keep))
            if buf_values is not None:
                buf_values.extend(itertools.compress(vals, keep))
        else:
            buf_ids.extend(ids)
            if buf_values is not None:
                assert vals is not None
                buf_values.extend(vals)
        self.pending = max(self.pending, len(buf_ids))

    def flush_if_full(self) -> None:
        if self.pending >= self.FLUSH_ROWS:
            self.flush()

    def flush(self) -> None:
        for state, ids, values in self.buffers.values():
            n = len(ids)
            if not n:
                continue
            ngroups = len(state.counts)  # type: ignore[attr-defined]
            counts = array.array("q", bytes(8 * ngroups))
            if values is None:
                sums = array.array("q", bytes(8 * ngroups))
                zeros = _zero_buffer(n)
                self.kernels.group_sum_i64(ids, address(zeros), None, n, sums, counts, ngroups)
            else:
                sums = array.array("q", bytes(8 * ngroups))
                if not self.kernels.group_sum_i64(ids, values.buffer_info()[0], None, n, sums, counts, ngroups):
                    sums = _exact_group_sums(ids, values, ngroups)  # possible wrap-around
            state.counts[:] = map(operator.add, state.counts, counts)  # type: ignore[attr-defined]
            if isinstance(state, SumState):
                state.totals[:] = map(operator.add, state.totals, sums)
            del ids[:]
            if values is not None:
                del values[:]
        self.pending = 0


def _exact_group_sums(ids: array.array, values: array.array, ngroups: int) -> list[int]:
    sums = [0] * ngroups
    for g, v in zip(ids, values):
        sums[g] += v
    return sums
