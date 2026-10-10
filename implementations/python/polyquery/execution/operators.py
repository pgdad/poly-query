"""Physical execution of plan nodes.

Every operator is a generator of *batches* (lists of row tuples). Batching
amortizes per-row interpreter overhead and is the unit at which timeouts,
cancellation and memory accounting are checked.
"""

from __future__ import annotations

import itertools
import operator
from typing import Any, Callable, Iterator

from .. import errors
from ..analysis import bound as b
from ..planner import plan as p
from .aggregates import CountStar, make_accumulator
from .compiler import compile_expr, compile_row
from .context import ExecutionContext

BATCH_SIZE = 2048

Batch = list[tuple]


def execute(node: p.PlanNode, ctx: ExecutionContext) -> Iterator[Batch]:
    handler: Callable[[Any, ExecutionContext], Iterator[Batch]] = _HANDLERS[type(node)]
    return handler(node, ctx)


def _table_scan(node: p.TableScan, ctx: ExecutionContext) -> Iterator[Batch]:
    rows = node.table.scan(node.columns)
    while True:
        ctx.check()
        batch = list(itertools.islice(rows, BATCH_SIZE))
        if not batch:
            return
        yield batch


def _single_row(node: p.SingleRow, ctx: ExecutionContext) -> Iterator[Batch]:
    yield [()]


def _filter(node: p.Filter, ctx: ExecutionContext) -> Iterator[Batch]:
    predicate = compile_expr(node.predicate, ctx)
    for batch in execute(node.input, ctx):
        out = [row for row in batch if predicate(row) is True]
        if out:
            yield out
        ctx.check()


def _aggregate(node: p.Aggregate, ctx: ExecutionContext) -> Iterator[Batch]:
    accumulators = [make_accumulator(call) for call in node.aggregates]
    getters: list[Callable[[tuple], Any] | None] = []
    for call in node.aggregates:
        if call.arg is None:
            getters.append(None)
        else:
            getters.append(compile_expr(call.arg, ctx))
    for batch in execute(node.input, ctx):
        for acc, getter in zip(accumulators, getters):
            if getter is None:
                assert isinstance(acc, CountStar)
                acc.add_rows(len(batch))
            elif isinstance(getter, operator.itemgetter):
                acc.add_batch(list(map(getter, batch)))
            else:
                acc.add_batch([getter(row) for row in batch])
        ctx.check()
    yield [tuple(acc.result() for acc in accumulators)]


def _project(node: p.Project, ctx: ExecutionContext) -> Iterator[Batch]:
    make_row = compile_row(node.exprs, ctx)
    for batch in execute(node.input, ctx):
        yield list(map(make_row, batch))
        ctx.check()


def _distinct(node: p.Distinct, ctx: ExecutionContext) -> Iterator[Batch]:
    seen: set[tuple] = set()
    for batch in execute(node.input, ctx):
        out = []
        for row in batch:
            if row not in seen:
                seen.add(row)
                out.append(row)
        if out:
            ctx.reserve_rows(len(out), len(out[0]))
            yield out


def _sort_rows(rows: list[tuple], keys: list[b.SortKey]) -> None:
    """Sorts in place: one stable pass per key, least significant key first."""
    for key in reversed(keys):
        pos = key.position
        has_null = any(row[pos] is None for row in rows)
        if not has_null:
            rows.sort(key=operator.itemgetter(pos), reverse=key.descending)
            continue
        # NULL placement: rank 0 sorts before non-NULLs (rank 1), rank 2 after;
        # ``reverse`` flips the ranks as well, hence the XOR.
        null_key = (0,) if key.nulls_first != key.descending else (2,)

        def sort_key(row: tuple, pos: int = pos, null_key: tuple = null_key) -> tuple:
            v = row[pos]
            return null_key if v is None else (1, v)

        rows.sort(key=sort_key, reverse=key.descending)


def _sort(node: p.Sort, ctx: ExecutionContext) -> Iterator[Batch]:
    rows: list[tuple] = []
    for batch in execute(node.input, ctx):
        if batch:
            ctx.reserve_rows(len(batch), len(batch[0]))
        rows.extend(batch)
    ctx.check()
    _sort_rows(rows, node.keys)
    ctx.check()
    for i in range(0, len(rows), BATCH_SIZE):
        yield rows[i : i + BATCH_SIZE]


def evaluate_count(expr: b.Expr | None, ctx: ExecutionContext, clause: str) -> int | None:
    """Evaluates a constant LIMIT/OFFSET expression."""
    if expr is None:
        return None
    value = compile_expr(expr, ctx)(())
    if value is not None and value < 0:
        raise errors.invalid_argument(f"{clause} must not be negative")
    return value


def _limit(node: p.Limit, ctx: ExecutionContext) -> Iterator[Batch]:
    limit = evaluate_count(node.limit, ctx, "LIMIT")
    offset = evaluate_count(node.offset, ctx, "OFFSET") or 0
    if limit == 0:
        return
    skipped = 0
    produced = 0
    for batch in execute(node.input, ctx):
        if skipped < offset:
            take = min(offset - skipped, len(batch))
            skipped += take
            batch = batch[take:]
        if not batch:
            continue
        if limit is not None and produced + len(batch) >= limit:
            yield batch[: limit - produced]
            return
        produced += len(batch)
        yield batch


_HANDLERS: dict[type, Callable[[Any, ExecutionContext], Iterator[Batch]]] = {
    p.TableScan: _table_scan,
    p.SingleRow: _single_row,
    p.Filter: _filter,
    p.Aggregate: _aggregate,
    p.Project: _project,
    p.Distinct: _distinct,
    p.Sort: _sort,
    p.Limit: _limit,
}
