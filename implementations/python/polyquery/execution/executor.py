"""Runs a query plan to completion and collects its result rows."""

from __future__ import annotations

from dataclasses import dataclass

from .. import errors
from ..planner.plan import QueryPlan
from ..storage.catalog import Column
from .context import ExecutionContext
from .operators import execute


@dataclass
class QueryResult:
    columns: list[Column]
    rows: list[tuple]


def run_plan(plan: QueryPlan, ctx: ExecutionContext, *, max_rows: int | None = None) -> QueryResult:
    rows: list[tuple] = []
    width = len(plan.columns)
    for batch in execute(plan.root, ctx):
        rows.extend(batch)
        if max_rows is not None and len(rows) > max_rows:
            raise errors.resource_limit(f"result exceeds max_rows ({max_rows})")
        ctx.reserve_rows(len(batch), width)
    return QueryResult(plan.columns, rows)
