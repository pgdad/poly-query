"""Runs a physical plan: either to completion, collecting its result rows,
or incrementally as a stream of row batches. The execution model is chosen
per statement by ``ExecutionContext.mode``: the row-at-a-time iterator
engine (``row``) or the vectorized engine (``vectorized``)."""

from __future__ import annotations

import itertools
from collections.abc import Iterator
from dataclasses import dataclass

from .. import errors
from ..planner.physical import ROW, PhysicalNode, PhysicalPlan
from ..storage.catalog import Column
from . import row_engine, vector_engine
from .common import OUTPUT_BATCH_ROWS
from .context import ExecutionContext


@dataclass
class QueryResult:
    columns: list[Column]
    rows: list[tuple]


def subplan_rows(node: PhysicalNode, ctx: ExecutionContext) -> Iterator[tuple]:
    """The output rows of a (sub)plan in the statement's execution mode."""
    if ctx.mode == ROW:
        return row_engine.execute(node, ctx)
    return vector_engine.rows(node, ctx)


def _row_batches(node: PhysicalNode, ctx: ExecutionContext) -> Iterator[list[tuple]]:
    if ctx.mode == ROW:
        rows = row_engine.execute(node, ctx)
        while True:
            batch = list(itertools.islice(rows, OUTPUT_BATCH_ROWS))
            if not batch:
                return
            yield batch
    else:
        for batch in vector_engine.execute(node, ctx):
            if batch[1]:
                yield vector_engine.to_rows(batch)


def stream_plan(
    plan: PhysicalPlan, ctx: ExecutionContext, *, max_rows: int | None = None
) -> Iterator[list[tuple]]:
    """Yields the result in batches; execution advances only as batches are
    consumed (the consumer provides backpressure)."""
    ctx.subplans = plan.subplans
    produced = 0
    for batch in _row_batches(plan.root, ctx):
        produced += len(batch)
        if max_rows is not None and produced > max_rows:
            raise errors.resource_limit(f"result exceeds max_rows ({max_rows})")
        yield batch


def count_plan(plan: PhysicalPlan, ctx: ExecutionContext, *, max_rows: int | None = None) -> int:
    """Runs a plan to completion and returns its row count, without building
    the result rows (``result: "count"``). Limits and the memory budget
    apply exactly as in :func:`run_plan`."""
    ctx.subplans = plan.subplans
    produced = 0
    width = len(plan.columns)
    for n in _batch_sizes(plan.root, ctx):
        produced += n
        if max_rows is not None and produced > max_rows:
            raise errors.resource_limit(f"result exceeds max_rows ({max_rows})")
        ctx.reserve_rows(n, width)
    return produced


def _batch_sizes(node: PhysicalNode, ctx: ExecutionContext) -> Iterator[int]:
    if ctx.mode == ROW:
        rows = row_engine.execute(node, ctx)
        while True:
            n = sum(1 for _ in itertools.islice(rows, OUTPUT_BATCH_ROWS))
            if not n:
                return
            yield n
    else:
        for _, n in vector_engine.execute(node, ctx):
            if n:
                yield n


def run_plan(plan: PhysicalPlan, ctx: ExecutionContext, *, max_rows: int | None = None) -> QueryResult:
    rows: list[tuple] = []
    width = len(plan.columns)
    for batch in stream_plan(plan, ctx, max_rows=max_rows):
        rows.extend(batch)
        ctx.reserve_rows(len(batch), width)
    return QueryResult(plan.columns, rows)
