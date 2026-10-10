"""Aggregate accumulators (functions.md §2).

Accumulators consume batches of argument values (``None`` = NULL) and
produce the final aggregate value in the runtime representation.
"""

from __future__ import annotations

import math
from typing import Any

from .. import errors, values
from ..analysis import bound as b
from ..datatypes import DataType, TypeKind


class Accumulator:
    def add_batch(self, batch: list[Any]) -> None:
        raise NotImplementedError

    def result(self) -> Any:
        raise NotImplementedError


class CountStar(Accumulator):
    def __init__(self) -> None:
        self.n = 0

    def add_rows(self, n: int) -> None:
        self.n += n

    def add_batch(self, batch: list[Any]) -> None:
        self.n += len(batch)

    def result(self) -> Any:
        return self.n


class Count(Accumulator):
    def __init__(self) -> None:
        self.n = 0

    def add_batch(self, batch: list[Any]) -> None:
        self.n += len(batch) - batch.count(None)

    def result(self) -> Any:
        return self.n


class _ExactSum(Accumulator):
    """SUM over INT64 / DECIMAL (unscaled) values with an unbounded accumulator."""

    def __init__(self) -> None:
        self.total = 0
        self.count = 0

    def add_batch(self, batch: list[Any]) -> None:
        vals = [v for v in batch if v is not None]
        self.count += len(vals)
        self.total += sum(vals)


class SumInt(_ExactSum):
    def result(self) -> Any:
        if not self.count:
            return None
        return values.check_int64(self.total)


class SumDecimal(_ExactSum):
    def result(self) -> Any:
        if not self.count:
            return None
        return values.check_decimal(self.total)


class _FloatSum(Accumulator):
    def __init__(self) -> None:
        self.partials: list[float] = []
        self.count = 0

    def add_batch(self, batch: list[Any]) -> None:
        vals = [v for v in batch if v is not None]
        if vals:
            self.count += len(vals)
            self.partials.extend(vals)
            if len(self.partials) > 4096:
                self.partials = [self._sum()]

    def _sum(self) -> float:
        try:
            return values.check_float(math.fsum(self.partials))
        except OverflowError:
            raise errors.numeric_overflow("FLOAT64 sum overflow") from None


class SumFloat(_FloatSum):
    def result(self) -> Any:
        return self._sum() if self.count else None


class AvgFloat(_FloatSum):
    def result(self) -> Any:
        return self._sum() / self.count if self.count else None


class AvgExact(_ExactSum):
    def __init__(self, scale: int) -> None:
        super().__init__()
        self.divisor = values.POW10[scale]

    def result(self) -> Any:
        if not self.count:
            return None
        return self.total / (self.count * self.divisor)


class MinMax(Accumulator):
    def __init__(self, is_min: bool) -> None:
        self.pick = min if is_min else max
        self.value: Any = None

    def add_batch(self, batch: list[Any]) -> None:
        vals = [v for v in batch if v is not None]
        if not vals:
            return
        m = self.pick(vals)
        self.value = m if self.value is None else self.pick(self.value, m)

    def result(self) -> Any:
        return self.value


class Distinct(Accumulator):
    """Feeds the distinct non-NULL values to an inner accumulator at the end."""

    def __init__(self, inner: Accumulator) -> None:
        self.inner = inner
        self.seen: set[Any] = set()

    def add_batch(self, batch: list[Any]) -> None:
        self.seen.update(batch)

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
