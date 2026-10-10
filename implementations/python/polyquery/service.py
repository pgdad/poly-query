"""The engine facade used by every protocol front end (session, exec, HTTP):
owns the catalog and runs loads and SQL statements."""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Any

from . import errors
from .analysis.binder import Binder
from .execution.context import ExecutionContext
from .execution.executor import QueryResult, run_plan
from .ingest.limits import DEFAULT_MAX_INGEST_BYTES, DEFAULT_MAX_TABLE_ROWS, IngestLimits
from .ingest.loader import load_table
from .planner.planner import plan_query
from .sql import ast
from .sql.parser import parse
from .storage.catalog import Catalog, Column, Table


@dataclass
class EngineConfig:
    data_dir: str = "."
    test_functions: bool = False
    max_query_memory_mb: int = 4096
    max_ingest_bytes: int = DEFAULT_MAX_INGEST_BYTES
    max_table_rows: int = DEFAULT_MAX_TABLE_ROWS
    max_join_rows: int = 100_000_000
    threads: int = 1
    log_level: str = "info"


@dataclass
class QueryOptions:
    max_rows: int | None = None
    timeout_ms: int = 0
    cancel_event: threading.Event | None = None
    extra: dict[str, Any] = field(default_factory=dict)


class Engine:
    def __init__(self, config: EngineConfig):
        self.config = config
        self.catalog = Catalog()
        self.ingest_limits = IngestLimits(config.max_ingest_bytes, config.max_table_rows)

    # ------------------------------------------------------------ catalog

    def load(
        self,
        name: str,
        fmt: str,
        text: str,
        schema: list[Column] | None,
        options: dict[str, Any],
        replace: bool,
    ) -> Table:
        if not replace and self.catalog.exists(name):
            raise errors.already_exists(f"table '{name}' already exists", table=name)
        table = load_table(name, fmt, text, schema, options, self.ingest_limits)
        self.catalog.put(table, replace=replace)
        return table

    # ------------------------------------------------------------ SQL

    def query(self, sql: str, options: QueryOptions) -> QueryResult:
        statement = parse(sql)
        if isinstance(statement, ast.Explain):
            raise errors.unsupported("EXPLAIN is not supported")
        if isinstance(statement, (ast.CreateIndex, ast.DropIndex)):
            raise errors.unsupported("indexes are not supported")
        assert isinstance(statement, ast.QueryStatement)
        binder = Binder(self.catalog, test_functions=self.config.test_functions)
        bound = binder.bind_query(statement.query)
        plan = plan_query(bound)
        ctx = ExecutionContext.create(
            timeout_ms=options.timeout_ms,
            max_memory_mb=self.config.max_query_memory_mb,
            test_functions=self.config.test_functions,
            cancel_event=options.cancel_event,
        )
        return run_plan(plan, ctx, max_rows=options.max_rows)
