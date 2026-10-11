"""The engine facade used by every protocol front end (session, exec, HTTP):
owns the catalog and runs loads and SQL statements."""

from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

from . import errors
from .analysis.binder import Binder
from .datatypes import STRING
from .execution.compiler import evaluate_constant
from .execution.context import DEFAULT_PARALLEL_MIN_ROWS, ExecutionContext
from .execution.executor import QueryResult, run_plan, stream_plan
from .execution.native_ops import kernel_plan
from .execution.worker_pool import WorkerPool
from .ingest.limits import DEFAULT_MAX_INGEST_BYTES, DEFAULT_MAX_TABLE_ROWS, IngestLimits
from .ingest.loader import load_table
from .native import NativeKernels, load_kernels
from .planner.physical import PhysicalPlan, PlanOptions
from .planner.pipeline import plan_statement
from .sql import ast
from .sql.parser import parse
from .storage import pqcf
from .storage.catalog import Catalog, Column, Table
from .storage.indexes import Index, build_index
from .storage.table import COLUMN


@dataclass
class StorageOptions:
    """In-memory representation options of ``load`` / ``open``."""

    layout: str = COLUMN
    dictionary: bool | None = None  # None: automatic for STRING columns
    mmap: bool = False


@dataclass
class EngineConfig:
    data_dir: str = "."
    test_functions: bool = False
    max_query_memory_mb: int = 4096
    max_ingest_bytes: int = DEFAULT_MAX_INGEST_BYTES
    max_table_rows: int = DEFAULT_MAX_TABLE_ROWS
    max_join_rows: int = 100_000_000
    threads: int = 1  # default parallelism of queries without a ``threads`` option
    # parallel pipelines over fewer rows run their partitions in-process
    parallel_min_rows: int = DEFAULT_PARALLEL_MIN_ROWS
    log_level: str = "info"
    native_kernels: str | None = None  # path of libpqkernels (--native-kernels)


@dataclass
class QueryOptions:
    max_rows: int | None = None
    timeout_ms: int = 0
    # absolute time.monotonic() deadline; overrides timeout_ms (the server
    # starts the clock when the query arrives, so queueing time counts)
    deadline: float | None = None
    cancel_event: threading.Event | None = None
    optimize: bool = True
    join: str = "auto"
    use_indexes: bool = True
    mode: str = "auto"  # auto (= vectorized), row, vectorized
    threads: int | None = None  # None: the engine's --threads
    native: bool = False  # use the native kernels (when loaded)
    extra: dict[str, Any] = field(default_factory=dict)


@dataclass
class QueryCursor:
    """A started statement whose result rows are produced on demand."""

    columns: list[Column]
    batches: Iterator[list[tuple]]


class Engine:
    def __init__(self, config: EngineConfig):
        self.config = config
        self.catalog = Catalog()
        self.ingest_limits = IngestLimits(config.max_ingest_bytes, config.max_table_rows)
        self.native: NativeKernels | None = load_kernels(config.native_kernels)
        # worker processes of parallel pipelines, forked on first use
        self.pool = WorkerPool(self.catalog.objects)

    def close(self) -> None:
        """Stops the worker processes (they also exit with this process)."""
        self.pool.close()

    # ------------------------------------------------------------ catalog

    def load(
        self,
        name: str,
        fmt: str,
        text: str,
        schema: list[Column] | None,
        options: dict[str, Any],
        replace: bool,
        storage: StorageOptions | None = None,
    ) -> Table:
        storage = storage or StorageOptions()
        if not replace and self.catalog.exists(name):
            raise errors.already_exists(f"table '{name}' already exists", table=name)
        table = load_table(
            name,
            fmt,
            text,
            schema,
            options,
            self.ingest_limits,
            layout=storage.layout,
            dictionary=storage.dictionary,
        )
        self.catalog.put(table, replace=replace)
        return table

    # ------------------------------------------------------------ storage

    def save(self, name: str, path: str, options: pqcf.SaveOptions) -> tuple[Table, int]:
        """Writes table ``name`` (with its index definitions) to a PQCF file;
        returns the table and the file size."""
        table = self.catalog.require(name)
        indexes = [index.to_json() for index in self.catalog.indexes_of(table)]
        return table, pqcf.save_table(path, table, indexes, options)

    def open(self, name: str, path: str, storage: StorageOptions, replace: bool) -> Table:
        """Opens a PQCF file as table ``name`` and recreates its indexes."""
        if not replace and self.catalog.exists(name):
            raise errors.already_exists(f"table '{name}' already exists", table=name)
        file = pqcf.read_file(path, use_mmap=storage.mmap)
        if file.row_count > self.ingest_limits.max_rows:
            raise errors.resource_limit(
                f"table has more than {self.ingest_limits.max_rows} rows (--max-table-rows)"
            )
        table = pqcf.table_from_file(
            file, name, lazy=storage.mmap, layout=storage.layout, dictionary=storage.dictionary
        )
        self._check_index_names(name, [n for n, _, _ in file.indexes], replace)
        indexes = [build_index(n, table, column, kind) for n, column, kind in file.indexes]
        self.catalog.put(table, replace=replace, indexes=indexes)
        return table

    def _check_index_names(self, table_name: str, names: list[str], replace: bool) -> None:
        """Fails early (before building indexes) if an index name is taken by
        an index that would survive; Catalog.put re-checks atomically."""
        current = self.catalog.get(table_name) if replace else None
        for name in names:
            existing = self.catalog.get_index(name)
            if existing is not None and existing.table is not current:
                raise errors.already_exists(f"index '{name}' already exists", index=name)

    def indexes_of(self, table: Table) -> list[Index]:
        return self.catalog.indexes_of(table)

    # ------------------------------------------------------------ SQL

    def query(self, sql: str, options: QueryOptions) -> QueryResult:
        """Runs a statement to completion."""
        statement = parse(sql)
        if not isinstance(statement, ast.QueryStatement):
            return self._run_statement(statement, options)
        plan, ctx = self._prepare(statement.query, options)
        return run_plan(plan, ctx, max_rows=options.max_rows)

    def open_cursor(self, sql: str, options: QueryOptions) -> QueryCursor:
        """Parses, binds and plans a statement (raising errors found up to
        that point) and returns a cursor that executes it incrementally."""
        statement = parse(sql)
        if not isinstance(statement, ast.QueryStatement):
            result = self._run_statement(statement, options)
            return QueryCursor(result.columns, iter([result.rows] if result.rows else []))
        plan, ctx = self._prepare(statement.query, options)
        return QueryCursor(plan.columns, stream_plan(plan, ctx, max_rows=options.max_rows))

    def _run_statement(self, statement: ast.Statement, options: QueryOptions) -> QueryResult:
        """EXPLAIN, CREATE INDEX and DROP INDEX."""
        if isinstance(statement, ast.Explain):
            plan = self._plan(statement.query, options)
            text = json.dumps(plan.to_json(), ensure_ascii=False)
            return QueryResult([Column("plan", STRING)], [(text,)])
        if isinstance(statement, ast.CreateIndex):
            self.create_index(statement)
            return QueryResult([], [])
        assert isinstance(statement, ast.DropIndex)
        self.drop_index(statement)
        return QueryResult([], [])

    def _prepare(self, query: ast.Query, options: QueryOptions) -> tuple[PhysicalPlan, ExecutionContext]:
        plan = self._plan(query, options)
        ctx = ExecutionContext.create(
            timeout_ms=options.timeout_ms,
            deadline=options.deadline,
            max_memory_mb=self.config.max_query_memory_mb,
            test_functions=self.config.test_functions,
            cancel_event=options.cancel_event,
            max_join_rows=self.config.max_join_rows,
            mode=plan.mode,
            threads=self._threads(options),
            parallel_min_rows=self.config.parallel_min_rows,
            native=plan.native,
            pool=self.pool,
        )
        return plan, ctx

    def _threads(self, options: QueryOptions) -> int:
        return options.threads if options.threads is not None else self.config.threads

    def create_index(self, statement: ast.CreateIndex) -> None:
        table = self.catalog.get(statement.table)
        if table is None:
            raise errors.semantic_error(
                f"table '{statement.table}' does not exist", **_position(statement)
            )
        column = table.column_index(statement.column)
        if column is None:
            raise errors.semantic_error(
                f"column '{statement.column}' does not exist in table '{table.name}'",
                **_position(statement),
            )
        if self.catalog.get_index(statement.name) is not None:
            if statement.if_not_exists:
                return
            raise errors.already_exists(f"index '{statement.name}' already exists", index=statement.name)
        index = build_index(statement.name, table, column, statement.kind)
        try:
            self.catalog.add_index(index)
        except errors.PolyQueryError as e:
            if e.code == errors.ALREADY_EXISTS and statement.if_not_exists:
                return
            raise

    def drop_index(self, statement: ast.DropIndex) -> None:
        if not self.catalog.drop_index(statement.name) and not statement.if_exists:
            raise errors.not_found(f"index '{statement.name}' does not exist", index=statement.name)

    def explain(self, sql: str, options: QueryOptions) -> dict[str, Any]:
        """The plan of a query (or of the query of an EXPLAIN statement) as JSON."""
        statement = parse(sql)
        if isinstance(statement, (ast.CreateIndex, ast.DropIndex)):
            raise errors.unsupported("only queries can be explained", **_position(statement))
        assert isinstance(statement, (ast.QueryStatement, ast.Explain))
        return self._plan(statement.query, options).to_json()

    def _plan(self, query: ast.Query, options: QueryOptions) -> PhysicalPlan:
        """Semantic analysis, logical and physical planning of a query
        against a snapshot of the catalog."""
        snapshot = self.catalog.snapshot()
        binder = Binder(snapshot, evaluate_constant, test_functions=self.config.test_functions)
        bound = binder.bind_statement(query)
        plan_options = PlanOptions(
            optimize=options.optimize,
            join=options.join,
            use_indexes=options.use_indexes,
            threads=self._threads(options),
            mode=options.mode,
            indexes_of=snapshot.indexes_of,
            evaluate=evaluate_constant,
            kernels=self.native if options.native else None,
            kernel_plan=kernel_plan,
        )
        return plan_statement(bound, plan_options)


def _position(node: ast.Node) -> dict[str, int]:
    return {"line": node.pos[0], "column": node.pos[1]}
