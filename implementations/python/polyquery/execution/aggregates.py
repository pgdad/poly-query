"""Aggregate accumulators (functions.md §2).

Accumulators consume argument values (``None`` = NULL) one at a time
(``add``, row-at-a-time execution) or a batch at a time (``add_batch``,
vectorized execution), can absorb the state of another accumulator of the
same aggregate (``merge``, parallel partial aggregation) and produce the
final aggregate value in the runtime representation.

All states merge exactly: integer and DECIMAL sums are unbounded Python
integers checked only at the end, and FLOAT64 sums keep ``math.fsum``
partials (fsum is correctly rounded, so the result does not depend on how
the input was partitioned).
"""

from __future__ import annotations

import math
import operator
from functools import partial
from typing import Any

from .. import errors, values
from ..analysis import bound as b
from ..datatypes import DataType, TypeKind

_not_null = partial(operator.is_not, None)


def non_null(batch: list[Any]) -> list[Any]:
    """The non-NULL values of a batch (the batch itself when it has none)."""
    return list(filter(_not_null, batch)) if None in batch else batch


class Accumulator:
    __slots__ = ()

    def add(self, value: Any) -> None:
        raise NotImplementedError

    def add_batch(self, batch: list[Any]) -> None:
        raise NotImplementedError

    def merge(self, other: Accumulator) -> None:
        raise NotImplementedError

    def result(self) -> Any:
        raise NotImplementedError


class CountStar(Accumulator):
    __slots__ = ("n",)

    def __init__(self) -> None:
        self.n = 0

    def add(self, value: Any) -> None:
        self.n += 1

    def add_rows(self, n: int) -> None:
        self.n += n

    def add_batch(self, batch: list[Any]) -> None:
        self.n += len(batch)

    def merge(self, other: Accumulator) -> None:
        assert isinstance(other, CountStar)
        self.n += other.n

    def result(self) -> Any:
        return self.n


class Count(Accumulator):
    __slots__ = ("n",)

    def __init__(self) -> None:
        self.n = 0

    def add(self, value: Any) -> None:
        if value is not None:
            self.n += 1

    def add_batch(self, batch: list[Any]) -> None:
        self.n += len(batch) - batch.count(None)

    def merge(self, other: Accumulator) -> None:
        assert isinstance(other, Count)
        self.n += other.n

    def result(self) -> Any:
        return self.n


class _ExactSum(Accumulator):
    """SUM over INT64 / DECIMAL (unscaled) values with an unbounded accumulator."""

    __slots__ = ("total", "count")

    def __init__(self) -> None:
        self.total = 0
        self.count = 0

    def add(self, value: Any) -> None:
        if value is not None:
            self.total += value
            self.count += 1

    def add_batch(self, batch: list[Any]) -> None:
        vals = non_null(batch)
        self.count += len(vals)
        self.total += sum(vals)

    def merge(self, other: Accumulator) -> None:
        assert isinstance(other, _ExactSum)
        self.total += other.total
        self.count += other.count


class SumInt(_ExactSum):
    __slots__ = ()

    def result(self) -> Any:
        if not self.count:
            return None
        return values.check_int64(self.total)


class SumDecimal(_ExactSum):
    __slots__ = ()

    def result(self) -> Any:
        if not self.count:
            return None
        return values.check_decimal(self.total)


class _FloatSum(Accumulator):
    __slots__ = ("partials", "count")

    def __init__(self) -> None:
        self.partials: list[float] = []
        self.count = 0

    def add(self, value: Any) -> None:
        if value is not None:
            self.count += 1
            self.partials.append(value)
            if len(self.partials) > 4096:
                self.partials = [self._sum()]

    def add_batch(self, batch: list[Any]) -> None:
        vals = non_null(batch)
        if vals:
            self.count += len(vals)
            self.partials.extend(vals)
            if len(self.partials) > 4096:
                self.partials = [self._sum()]

    def merge(self, other: Accumulator) -> None:
        assert isinstance(other, _FloatSum)
        self.count += other.count
        self.partials.extend(other.partials)

    def _sum(self) -> float:
        try:
            return values.check_float(math.fsum(self.partials))
        except OverflowError:
            raise errors.numeric_overflow("FLOAT64 sum overflow") from None


class SumFloat(_FloatSum):
    __slots__ = ()

    def result(self) -> Any:
        return self._sum() if self.count else None


class AvgFloat(_FloatSum):
    __slots__ = ()

    def result(self) -> Any:
        return self._sum() / self.count if self.count else None


class AvgExact(_ExactSum):
    __slots__ = ("divisor",)

    def __init__(self, scale: int) -> None:
        super().__init__()
        self.divisor = values.POW10[scale]

    def result(self) -> Any:
        if not self.count:
            return None
        return self.total / (self.count * self.divisor)


class MinMax(Accumulator):
    __slots__ = ("is_min", "value")

    def __init__(self, is_min: bool) -> None:
        self.is_min = is_min
        self.value: Any = None

    def add(self, value: Any) -> None:
        if value is None:
            return
        current = self.value
        if current is None or (value < current if self.is_min else value > current):
            self.value = value

    def add_batch(self, batch: list[Any]) -> None:
        vals = non_null(batch)
        if vals:
            self.add(min(vals) if self.is_min else max(vals))

    def merge(self, other: Accumulator) -> None:
        assert isinstance(other, MinMax)
        self.add(other.value)

    def result(self) -> Any:
        return self.value


class Distinct(Accumulator):
    """Feeds the distinct non-NULL values to an inner accumulator at the end."""

    __slots__ = ("inner", "seen")

    def __init__(self, inner: Accumulator) -> None:
        self.inner = inner
        self.seen: set[Any] = set()

    def add(self, value: Any) -> None:
        self.seen.add(value)

    def add_batch(self, batch: list[Any]) -> None:
        self.seen.update(batch)

    def merge(self, other: Accumulator) -> None:
        assert isinstance(other, Distinct)
        self.seen |= other.seen

    def result(self) -> Any:
        self.seen.discard(None)
        self.inner.add_batch(list(self.seen))
        return self.inner.result()


def make_accumulator(call: b.AggCall) -> Accumulator:
    if call.arg is None:
        return CountStar()
    arg_type: DataType = call.arg.type
    acc: Accumulator
    name = call.name
    if name == "COUNT":
        acc = Count()
    elif name in ("MIN", "MAX"):
        acc = MinMax(name == "MIN")
    elif name == "SUM":
        if arg_type.kind is TypeKind.FLOAT64:
            acc = SumFloat()
        elif arg_type.kind is TypeKind.DECIMAL:
            acc = SumDecimal()
        else:
            acc = SumInt()
    else:  # AVG
        if arg_type.kind is TypeKind.FLOAT64:
            acc = AvgFloat()
        else:
            acc = AvgExact(arg_type.scale if arg_type.kind is TypeKind.DECIMAL else 0)
    return Distinct(acc) if call.distinct else acc


def accumulator_factory(calls: list[b.AggCall]):
    """A function creating a fresh list of accumulators for ``calls``."""
    return lambda: [make_accumulator(call) for call in calls]
