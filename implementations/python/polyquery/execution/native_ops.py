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
import collections
import itertools
import operator
from dataclasses import dataclass
from typing import Any, Callable, Iterator, Sequence

from .. import errors
from ..analysis import bound as b
from ..datatypes import TypeKind
from ..native import kernels as nk
from ..native.kernels import NativeKernels, address, new_bitmap
from ..planner import physical as pp
from ..planner.access import column_predicate, group_may_match
from ..storage.table import ColumnTable, RowGroup
from ..storage.vectors import ColumnVector, DictVector, PlainVector, bits_to_flags, flags_to_bits
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

INT64_MIN, INT64_MAX = nk.INT64_MIN, nk.INT64_MAX
_INT_KINDS = frozenset({TypeKind.INT64, TypeKind.DECIMAL, TypeKind.DATE, TypeKind.TIMESTAMP})
_TERM_KINDS = _INT_KINDS | {TypeKind.STRING}
_FLIPPED = {"=": "=", "<>": "<>", "<": ">", "<=": ">=", ">": "<", ">=": "<="}

# an all-zero int64 buffer: pqk_filter_i64 over it with an always-true
# predicate and a selection bitmap as validity lists the set bits
_zeros = array.array("q")


def _zero_data(n: int) -> int:
    global _zeros
    zeros = _zeros
    if len(zeros) < n:
        zeros = _zeros = array.array("q", bytes(8 * max(n, WINDOW_ROWS)))
    return zeros.buffer_info()[0]


# ------------------------------------------------------------------ terms


Interval = tuple[int, int]  # inclusive bounds within the int64 range


@dataclass(frozen=True, eq=False)
class Term:
    """A conjunct ``column op constants`` on a table column. ``values`` are
    runtime values of the column's type (two for BETWEEN, any number for IN)."""

    column: int
    kind: TypeKind
    op: str  # = <> < <= > >= BETWEEN IN
    values: tuple[Any, ...]

    def matches(self, v: Any) -> bool:
        """The predicate on one non-NULL value (Python reference semantics)."""
        op, values = self.op, self.values
        if op == "IN":
            return v in values
        if op == "BETWEEN":
            return values[0] <= v <= values[1]
        return _COMPARE[op](v, values[0])


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


def windows(table: ColumnTable, keep: Callable[[RowGroup], bool] | None, start: int, stop: int | None) -> Iterator[Window]:
    for group, lo, hi in table.row_ranges(keep, start, stop):
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
    found = kernels.filter_indices(_zero_data(n), bits.buffer_info()[0], n, nk.GE, INT64_MIN, 0, idx)
    if found != count:
        raise nk.NativeKernelError(f"pqk_filter_i64 selected {found} rows, popcount {count}")
    del idx[count:]
    return idx


def gather_column(
    kernels: NativeKernels, window: Window, vector: ColumnVector, idx: array.array, positions: list[int] | None
) -> list[Any]:
    """The runtime values of the selected rows of one column."""
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
        if positions is None:
            positions = idx.tolist()
        chunk = vector.data[base : base + window.n]
        values = [chunk[i] for i in positions] if len(positions) < 2 else list(operator.itemgetter(*positions)(chunk))
        if vector.dtype.kind is TypeKind.BOOLEAN:
            values = list(map(bool, values))
    if vector.validity is not None:
        _apply_nulls(window, vector, idx, values)
    return values


def _apply_nulls(window: Window, vector: ColumnVector, idx: array.array, values: list[Any]) -> None:
    assert vector.validity is not None
    start = window.base >> 3
    flags = bits_to_flags(vector.validity[start : start + window.nbytes], window.n)
    valid = list(map(flags.__getitem__, idx))
    if 0 in valid:
        nulls = itertools.compress(range(len(valid)), map(operator.not_, valid))
        collections.deque(map(values.__setitem__, nulls, itertools.repeat(None)), maxlen=0)


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
    for window in windows(table, keep, start, stop):
        bits, count = native.select(kernels, window)
        if count:
            group = window.group
            if count == window.n:  # every row: plain decoding is cheaper
                lo, hi = window.base, window.base + window.n
                cols = [group.vector(i).to_list(lo, hi) for i in scan.columns]
            else:
                idx = selected_positions(kernels, bits, window.n, count)
                positions = idx.tolist()
                cols = [gather_column(kernels, window, group.vector(i), idx, positions) for i in scan.columns]
            if count <= batch_rows:
                yield cols, count
            else:
                for lo in range(0, count, batch_rows):
                    yield [c[lo : lo + batch_rows] for c in cols], min(batch_rows, count - lo)
        ctx.check()


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
    scan: pp.TableScan
    filter: NativeFilter | None
    specs: list[_AggSpec]

    def partition(self, ctx: ExecutionContext) -> tuple[list[Any], list[GroupState]]:
        """The partial aggregation state of the scan range of the current
        partition (same form as the vectorized engine's partials)."""
        kernels = ctx.native
        assert kernels is not None
        scan = self.scan
        table = scan.table
        assert isinstance(table, ColumnTable)
        states = [make_state(spec.call) for spec in self.specs]
        for state in states:
            state.grow(1)
        skip = scan.skip
        keep = (lambda group: group_may_match(group, skip)) if skip else None
        start, stop = scan_range(scan, ctx, table.row_count)
        ctx.check()
        for window in windows(table, keep, start, stop):
            if self.filter is not None:
                sel, count = self.filter.select(kernels, window)
            else:
                sel = window.all_rows()
                count = kernels.popcount(sel.buffer_info()[0], window.n)
            if count:
                for spec, state in zip(self.specs, states):
                    _accumulate(kernels, window, sel, count, spec, state)
            ctx.check()
        return [()], states


def _accumulate(
    kernels: NativeKernels, window: Window, sel: array.array, count: int, spec: _AggSpec, state: GroupState
) -> None:
    if spec.column is None:
        assert isinstance(state, CountStarState)
        state.counts[0] += count
        return
    vector = window.group.vector(spec.column)
    validity = window.validity(vector)
    rows = sel
    if validity is not None:  # selected and non-NULL
        rows = array.array("B", sel)
        kernels.bitmap_and(rows, validity, window.nbytes)
        count = kernels.popcount(rows.buffer_info()[0], window.n)
        if not count:
            return
    if isinstance(state, CountState):
        state.counts[0] += count
        return
    rows_addr = rows.buffer_info()[0]
    if isinstance(state, SumState):
        data = vector.int64_view()
        assert data is not None
        total = kernels.sum_i64(address(data, window.base), rows_addr, window.n)
        if total is None:  # outside int64: recompute exactly
            total = sum(_selected_values(kernels, window, vector, rows, count))
        state.totals[0] += total
        state.counts[0] += count
        return
    assert isinstance(state, MinMaxState)
    if vector.dtype.kind is TypeKind.FLOAT64:
        assert isinstance(vector, PlainVector)
        _, lo, hi = kernels.minmax_f64(address(vector.data, window.base), rows_addr, window.n)
        value = lo if state.is_min else hi
        if value == 0.0:  # 0.0 vs -0.0: the first one seen wins
            values = _selected_values(kernels, window, vector, rows, count)
            value = min(values) if state.is_min else max(values)
    else:
        data = vector.int64_view()
        assert data is not None
        _, lo, hi = kernels.minmax_i64(address(data, window.base), rows_addr, window.n)
        value = lo if state.is_min else hi
    state._offer(0, value)


def _selected_values(
    kernels: NativeKernels, window: Window, vector: ColumnVector, rows: array.array, count: int
) -> list[Any]:
    """The values of the (non-NULL) rows set in ``rows``."""
    idx = selected_positions(kernels, rows, window.n, count)
    return gather_column(kernels, window, vector, idx, None)


_SUM_KINDS = frozenset({TypeKind.INT64, TypeKind.DECIMAL})
_MINMAX_KINDS = _INT_KINDS | {TypeKind.FLOAT64}


def compile_scan_aggregate(node: pp.HashAggregate, ctx: ExecutionContext) -> NativeScanAggregate | None:
    if node.keys:
        return None
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
    specs: list[_AggSpec] = []
    for call in node.aggregates:
        if call.arg is None:
            specs.append(_AggSpec(call, None))
            continue
        arg = call.arg
        if call.distinct or not isinstance(arg, b.ColumnRef) or arg.rel != scan.rel:
            return None
        kind = scan.table.columns[arg.index].type.kind
        if call.name in ("SUM", "AVG") and kind not in _SUM_KINDS:
            return None
        if call.name in ("MIN", "MAX") and kind not in _MINMAX_KINDS:
            return None
        specs.append(_AggSpec(call, arg.index))
    return NativeScanAggregate(scan, native, specs)


def native_scan_aggregate(node: pp.HashAggregate, ctx: ExecutionContext) -> NativeScanAggregate | None:
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
                self.kernels.group_sum_i64(ids, _zero_values(n), None, n, sums, counts, ngroups)
            else:
                sums = array.array("q", bytes(8 * ngroups))
                if not self.kernels.group_sum_i64(ids, values, None, n, sums, counts, ngroups):
                    sums = _exact_group_sums(ids, values, ngroups)  # possible wrap-around
            state.counts[:] = map(operator.add, state.counts, counts)  # type: ignore[attr-defined]
            if isinstance(state, SumState):
                state.totals[:] = map(operator.add, state.totals, sums)
            del ids[:]
            if values is not None:
                del values[:]
        self.pending = 0


def _zero_values(n: int) -> array.array:
    return array.array("q", bytes(8 * n))


def _exact_group_sums(ids: array.array, values: array.array, ngroups: int) -> list[int]:
    sums = [0] * ngroups
    for g, v in zip(ids, values):
        sums[g] += v
    return sums
