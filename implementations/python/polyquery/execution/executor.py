"""Runs a physical plan: either to completion, collecting its result rows,
or incrementally as a stream of row batches."""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass

from .. import errors
from ..planner.physical import PhysicalPlan
from ..storage.catalog import Column
from .context import ExecutionContext
from .operators import execute


@dataclass
class QueryResult:
    columns: list[Column]
    rows: list[tuple]


def stream_plan(
    plan: PhysicalPlan, ctx: ExecutionContext, *, max_rows: int | None = None
) -> Iterator[list[tuple]]:
    """Yields the result in batches; execution advances only as batches are
    consumed (the consumer provides backpressure)."""
    ctx.subplans = plan.subplans
    produced = 0
    for batch in execute(plan.root, ctx):
        if not batch:
            continue
        produced += len(batch)
        if max_rows is not None and produced > max_rows:
            raise errors.resource_limit(f"result exceeds max_rows ({max_rows})")
        yield batch


def run_plan(plan: PhysicalPlan, ctx: ExecutionContext, *, max_rows: int | None = None) -> QueryResult:
    rows: list[tuple] = []
    width = len(plan.columns)
    for batch in stream_plan(plan, ctx, max_rows=max_rows):
        rows.extend(batch)
        ctx.reserve_rows(len(batch), width)
    return QueryResult(plan.columns, rows)
