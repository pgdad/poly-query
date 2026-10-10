"""Columnar aggregation state for vectorized grouping.

Instead of one accumulator object per group and aggregate (the row engine's
model), each aggregate keeps its state for *all* groups in flat lists
indexed by a dense group id: totals, counts, current minima, … This avoids
an object (and a method call per row) per group, keeps the state of one
aggregate contiguous, and makes partial results of parallel workers cheap
to pickle and merge (plain lists of numbers).

Updates come in two shapes:

* ``update_runs(runs, values)``: ``values`` is sorted by group and
  ``runs`` lists ``(group id, start, end)`` slices — few groups per batch,
  so every group's slice is reduced by one C-level call (``sum``, ``min``…);
* ``update_rows(ids, values)``: per-row group ids — many groups per batch.

Results are identical to the row engine's accumulators (same exact integer
sums, fsum-based float sums, first-seen minima/maxima).
"""

from __future__ import annotations

import math
import operator
from collections import Counter
from functools import partial
from itertools import compress
from typing import Any, Sequence

from .. import errors, values
from ..analysis import bound as b
from ..datatypes import TypeKind
from .aggregates import make_accumulator, non_null

Runs = list[tuple[int, int, int]]
_is_not_none = partial(operator.is_not, None)
_FLOAT_COMPACT = 4096


def _non_null_rows(ids: Sequence[int], vals: Sequence[Any]) -> tuple[Sequence[int], Sequence[Any]]:
    if None not in vals:
        return ids, vals
    mask = list(map(_is_not_none, vals))
    return list(compress(ids, mask)), list(compress(vals, mask))


class GroupState:
    """State of one aggregate for every group."""

    def grow(self, n: int) -> None:
        """Adds ``n`` new (empty) groups."""
        raise NotImplementedError

    def update_runs(self, runs: Runs, vals: Sequence[Any] | None) -> None:
        raise NotImplementedError

    def update_rows(self, ids: Sequence[int], vals: Sequence[Any] | None) -> None:
        raise NotImplementedError

    def merge(self, other: GroupState, mapping: Sequence[int]) -> None:
        """Absorbs ``other``; its group ``g`` is this state's group ``mapping[g]``."""
        raise NotImplementedError

    def results(self) -> list[Any]:
        raise NotImplementedError


class CountStarState(GroupState):
    def __init__(self) -> None:
        self.counts: list[int] = []

    def grow(self, n: int) -> None:
        self.counts.extend([0] * n)

    def update_runs(self, runs: Runs, vals: Sequence[Any] | None) -> None:
        counts = self.counts
        for g, s, e in runs:
            counts[g] += e - s

    def update_rows(self, ids: Sequence[int], vals: Sequence[Any] | None) -> None:
        counts = self.counts
        for g, c in Counter(ids).items():
            counts[g] += c

    def merge(self, other: GroupState, mapping: Sequence[int]) -> None:
        assert isinstance(other, CountStarState)
        counts = self.counts
        for g, c in zip(mapping, other.counts):
            counts[g] += c

    def results(self) -> list[Any]:
        return self.counts


class CountState(CountStarState):
    def update_runs(self, runs: Runs, vals: Sequence[Any] | None) -> None:
        assert vals is not None
        counts = self.counts
        if None not in vals:
            for g, s, e in runs:
                counts[g] += e - s
            return
        for g, s, e in runs:
            part = vals[s:e]
            counts[g] += len(part) - part.count(None)

    def update_rows(self, ids: Sequence[int], vals: Sequence[Any] | None) -> None:
        assert vals is not None
        ids, _ = _non_null_rows(ids, vals)
        super().update_rows(ids, None)


class SumState(GroupState):
    """Exact SUM / AVG over INT64 and DECIMAL (unscaled) values."""

    def __init__(self, kind: str, scale: int = 0) -> None:
        self.kind = kind  # "int", "decimal" or "avg"
        self.divisor = values.POW10[scale]
        self.totals: list[int] = []
        self.counts: list[int] = []

    def grow(self, n: int) -> None:
        self.totals.extend([0] * n)
        self.counts.extend([0] * n)

    def update_runs(self, runs: Runs, vals: Sequence[Any] | None) -> None:
        assert vals is not None
        totals, counts = self.totals, self.counts
        nulls = None in vals
        for g, s, e in runs:
            part = vals[s:e]
            if nulls:
                part = non_null(part)  # type: ignore[arg-type]
            totals[g] += sum(part)
            counts[g] += len(part)

    def update_rows(self, ids: Sequence[int], vals: Sequence[Any] | None) -> None:
        assert vals is not None
        ids, vals = _non_null_rows(ids, vals)
        totals, counts = self.totals, self.counts
        for g, v in zip(ids, vals):
            totals[g] += v
        for g, c in Counter(ids).items():
            counts[g] += c

    def merge(self, other: GroupState, mapping: Sequence[int]) -> None:
        assert isinstance(other, SumState)
        totals, counts = self.totals, self.counts
        for g, t, c in zip(mapping, other.totals, other.counts):
            totals[g] += t
            counts[g] += c

    def results(self) -> list[Any]:
        out: list[Any] = []
        for total, count in zip(self.totals, self.counts):
            if not count:
                out.append(None)
            elif self.kind == "int":
                out.append(values.check_int64(total))
            elif self.kind == "decimal":
                out.append(values.check_decimal(total))
            else:
                out.append(total / (count * self.divisor))
        return out


class FloatSumState(GroupState):
    """SUM / AVG over FLOAT64: per group the values (compacted with fsum)."""

    def __init__(self, average: bool) -> None:
        self.average = average
        self.parts: list[list[float]] = []
        self.counts: list[int] = []

    def grow(self, n: int) -> None:
        self.parts.extend([] for _ in range(n))
        self.counts.extend([0] * n)

    def _compact(self, g: int) -> None:
        if len(self.parts[g]) > _FLOAT_COMPACT:
            self.parts[g] = [_fsum(self.parts[g])]

    def update_runs(self, runs: Runs, vals: Sequence[Any] | None) -> None:
        assert vals is not None
        nulls = None in vals
        for g, s, e in runs:
            part = vals[s:e]
            if nulls:
                part = non_null(part)  # type: ignore[arg-type]
            if part:
                self.parts[g].extend(part)
                self.counts[g] += len(part)
                self._compact(g)

    def update_rows(self, ids: Sequence[int], vals: Sequence[Any] | None) -> None:
        assert vals is not None
        ids, vals = _non_null_rows(ids, vals)
        parts = self.parts
        for g, v in zip(ids, vals):
            parts[g].append(v)
        for g, c in Counter(ids).items():
            self.counts[g] += c
            self._compact(g)

    def merge(self, other: GroupState, mapping: Sequence[int]) -> None:
        assert isinstance(other, FloatSumState)
        for g, p, c in zip(mapping, other.parts, other.counts):
            self.parts[g].extend(p)
            self.counts[g] += c

    def results(self) -> list[Any]:
        out: list[Any] = []
        for part, count in zip(self.parts, self.counts):
            if not count:
                out.append(None)
            else:
                total = _fsum(part)
                out.append(total / count if self.average else total)
        return out


def _fsum(parts: list[float]) -> float:
    try:
        return values.check_float(math.fsum(parts))
    except OverflowError:
        raise errors.numeric_overflow("FLOAT64 sum overflow") from None


class MinMaxState(GroupState):
    def __init__(self, is_min: bool) -> None:
        self.is_min = is_min
        self.values: list[Any] = []

    def grow(self, n: int) -> None:
        self.values.extend([None] * n)

    def _offer(self, g: int, v: Any) -> None:
        cur = self.values[g]
        if cur is None or (v < cur if self.is_min else v > cur):
            self.values[g] = v

    def update_runs(self, runs: Runs, vals: Sequence[Any] | None) -> None:
        assert vals is not None
        pick = min if self.is_min else max
        nulls = None in vals
        for g, s, e in runs:
            part = vals[s:e]
            if nulls:
                part = non_null(part)  # type: ignore[arg-type]
            if part:
                self._offer(g, pick(part))

    def update_rows(self, ids: Sequence[int], vals: Sequence[Any] | None) -> None:
        assert vals is not None
        ids, vals = _non_null_rows(ids, vals)
        current = self.values
        if self.is_min:
            for g, v in zip(ids, vals):
                cur = current[g]
                if cur is None or v < cur:
                    current[g] = v
        else:
            for g, v in zip(ids, vals):
                cur = current[g]
                if cur is None or v > cur:
                    current[g] = v

    def merge(self, other: GroupState, mapping: Sequence[int]) -> None:
        assert isinstance(other, MinMaxState)
        for g, v in zip(mapping, other.values):
            if v is not None:
                self._offer(g, v)

    def results(self) -> list[Any]:
        return self.values


class DistinctState(GroupState):
    """Aggregates over DISTINCT values: per group the set of values."""

    def __init__(self, call: b.AggCall) -> None:
        self.call = call
        self.sets: list[set[Any]] = []

    def grow(self, n: int) -> None:
        self.sets.extend(set() for _ in range(n))

    def update_runs(self, runs: Runs, vals: Sequence[Any] | None) -> None:
        assert vals is not None
        for g, s, e in runs:
            self.sets[g].update(vals[s:e])

    def update_rows(self, ids: Sequence[int], vals: Sequence[Any] | None) -> None:
        assert vals is not None
        sets = self.sets
        for g, v in zip(ids, vals):
            sets[g].add(v)

    def merge(self, other: GroupState, mapping: Sequence[int]) -> None:
        assert isinstance(other, DistinctState)
        for g, s in zip(mapping, other.sets):
            self.sets[g] |= s

    def results(self) -> list[Any]:
        out = []
        for seen in self.sets:
            acc = make_accumulator(self.call)
            acc.add_batch(list(seen))  # the Distinct accumulator drops NULL
            out.append(acc.result())
        return out


def make_state(call: b.AggCall) -> GroupState:
    if call.arg is None:
        return CountStarState()
    if call.distinct:
        return DistinctState(call)
    name, arg_type = call.name, call.arg.type
    if name == "COUNT":
        return CountState()
    if name in ("MIN", "MAX"):
        return MinMaxState(name == "MIN")
    is_float = arg_type.kind is TypeKind.FLOAT64
    if name == "SUM":
        if is_float:
            return FloatSumState(average=False)
        return SumState("decimal" if arg_type.kind is TypeKind.DECIMAL else "int")
    if is_float:
        return FloatSumState(average=True)
    return SumState("avg", arg_type.scale if arg_type.kind is TypeKind.DECIMAL else 0)
