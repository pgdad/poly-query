"""The embedding API (spec/apps/embedding.md): the engine as an in-process
library.

    import polyquery

    with polyquery.Database("/path/to/data") as db:
        db.load("t", path="t.csv")
        result = db.query("SELECT a, SUM(b) AS total FROM t GROUP BY a")
        for a, total in result:
            ...

A :class:`Database` owns one engine instance (catalog, worker pool). Every
operation runs in the calling thread, without starting processes (unless
``worker_processes=True``) or opening network connections. Errors are raised
as :class:`Error` carrying the specification's error code; an error leaves
the instance usable.

Result values are native Python values (see :data:`VALUE_TYPES` and
EMBEDDING.md): INT64 ``int``, DECIMAL ``decimal.Decimal`` (exact, exponent
``-scale``), FLOAT64 ``float``, STRING ``str``, BOOLEAN ``bool``, DATE
``datetime.date``, TIMESTAMP ``datetime.datetime`` (naive, UTC), NULL ``None``.
"""

from __future__ import annotations

import datetime as _dt
import decimal as _decimal
import math
import os
import threading
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass
from typing import Any, Callable, overload

from . import errors
from .datatypes import DataType, InvalidTypeError, TypeKind, parse_type
from .execution.context import gc_paused
from .ingest.limits import DEFAULT_MAX_INGEST_BYTES, DEFAULT_MAX_TABLE_ROWS
from .limits import configure_interpreter
from .paths import decode_utf8, read_input_file, resolve_data_path
from .service import Engine, EngineConfig, QueryOptions, StorageOptions
from .storage import pqcf
from .storage.catalog import Column

__all__ = [
    "ColumnInfo",
    "Database",
    "Error",
    "Result",
    "TableInfo",
    "VALUE_TYPES",
    "configure_interpreter",
]

#: The exception raised by every operation: ``code`` (e.g. ``"PARSE_ERROR"``),
#: ``message`` and ``details`` (a dict or None), as in spec/errors/errors.md.
Error = errors.PolyQueryError

#: Python type of the non-NULL values of each type kind.
VALUE_TYPES: dict[str, type] = {
    "BOOLEAN": bool,
    "INT64": int,
    "FLOAT64": float,
    "DECIMAL": _decimal.Decimal,
    "STRING": str,
    "DATE": _dt.date,
    "TIMESTAMP": _dt.datetime,
}

_EPOCH_ORDINAL = _dt.date(1970, 1, 1).toordinal()
_EPOCH = _dt.datetime(1970, 1, 1)
_INT64_MIN, _INT64_MAX = -(2**63), 2**63 - 1
# exact arithmetic for DECIMAL(38, s) conversions
_EXACT = _decimal.Context(prec=80, traps=[_decimal.InvalidOperation])


@dataclass(frozen=True, slots=True)
class ColumnInfo:
    """A column: its name and canonical type name (e.g. ``DECIMAL(18,2)``)."""

    name: str
    type: str


@dataclass(frozen=True, slots=True)
class TableInfo:
    """A table of the catalog: name, row count and columns."""

    name: str
    row_count: int
    columns: tuple[ColumnInfo, ...]


class Result:
    """The result of :meth:`Database.query`: column names and types and the
    rows as tuples of native values. Iterating yields the rows; ``len()``
    is the row count."""

    __slots__ = ("columns", "types", "rows")

    def __init__(self, columns: tuple[str, ...], types: tuple[str, ...], rows: list[tuple]):
        self.columns = columns
        self.types = types
        self.rows = rows

    @property
    def row_count(self) -> int:
        return len(self.rows)

    @property
    def schema(self) -> tuple[ColumnInfo, ...]:
        return tuple(ColumnInfo(n, t) for n, t in zip(self.columns, self.types))

    def __len__(self) -> int:
        return len(self.rows)

    def __iter__(self) -> Iterator[tuple]:
        return iter(self.rows)

    @overload
    def __getitem__(self, index: int) -> tuple: ...
    @overload
    def __getitem__(self, index: slice) -> list[tuple]: ...
    def __getitem__(self, index):
        return self.rows[index]

    def column(self, name: str) -> list[Any]:
        """The values of the column ``name`` (exact spelling)."""
        try:
            i = self.columns.index(name)
        except ValueError:
            raise KeyError(name) from None
        return [row[i] for row in self.rows]

    def scalar(self) -> Any:
        """The single value of a one-row, one-column result."""
        if len(self.rows) != 1 or len(self.columns) != 1:
            raise ValueError(f"expected 1 row and 1 column, got {len(self.rows)} rows, {len(self.columns)} columns")
        return self.rows[0][0]

    def to_dicts(self) -> list[dict[str, Any]]:
        return [dict(zip(self.columns, row)) for row in self.rows]

    def __repr__(self) -> str:
        cols = ", ".join(f"{n} {t}" for n, t in zip(self.columns, self.types))
        return f"<Result ({cols}): {len(self.rows)} rows>"


SchemaSpec = Sequence["ColumnInfo | tuple[str, str]"]


class Database:
    """One in-process engine instance.

    ``data_dir`` is the directory that relative paths of :meth:`load`,
    :meth:`save` and :meth:`open` are resolved in (as ``--data-dir``: paths
    must be relative and must not contain ``..``). The keyword arguments are
    the CLI's limits and defaults:

    * ``max_query_memory_mb`` — per-query memory budget (``--max-query-memory-mb``);
    * ``threads`` — default parallelism of queries (``--threads``; None: automatic);
    * ``max_ingest_bytes``, ``max_table_rows``, ``max_join_rows`` — as the CLI flags;
    * ``worker_processes`` — allow parallel pipelines to fork worker processes
      (the CLI's behaviour). Default False: everything runs in the calling
      thread and no process is ever started;
    * ``native_kernels`` — path of the optional native kernel library.

    Use it as a context manager or call :meth:`close`. Operations may be
    called from several threads at once (see EMBEDDING.md, *Thread safety*).
    """

    def __init__(
        self,
        data_dir: str | os.PathLike[str] = ".",
        *,
        max_query_memory_mb: int = 4096,
        threads: int | None = None,
        max_ingest_bytes: int = DEFAULT_MAX_INGEST_BYTES,
        max_table_rows: int = DEFAULT_MAX_TABLE_ROWS,
        max_join_rows: int = 100_000_000,
        worker_processes: bool = False,
        native_kernels: str | None = None,
    ):
        for name, value in (
            ("max_query_memory_mb", max_query_memory_mb),
            ("max_ingest_bytes", max_ingest_bytes),
            ("max_table_rows", max_table_rows),
            ("max_join_rows", max_join_rows),
        ):
            _check_int(name, value, 0)
        if threads is not None:
            _check_int("threads", threads, 1)
        path = os.path.abspath(os.fspath(data_dir))
        if not os.path.isdir(path):
            raise errors.not_found(f"data directory does not exist: {os.fspath(data_dir)}")
        self._config = EngineConfig(
            data_dir=path,
            max_query_memory_mb=max_query_memory_mb,
            max_ingest_bytes=max_ingest_bytes,
            max_table_rows=max_table_rows,
            max_join_rows=max_join_rows,
            threads=threads,
            native_kernels=native_kernels,
            worker_processes=worker_processes,
        )
        self._engine: Engine | None = _call(lambda: Engine(self._config))
        self._lock = threading.Lock()

    # ------------------------------------------------------------ lifecycle

    @property
    def data_dir(self) -> str:
        return self._config.data_dir

    @property
    def closed(self) -> bool:
        return self._engine is None

    def close(self) -> None:
        """Releases the instance (tables, worker processes). Idempotent;
        later operations raise ``Error`` with code ``INVALID_REQUEST``."""
        with self._lock:
            engine, self._engine = self._engine, None
        if engine is not None:
            engine.catalog.reset()
            engine.close()

    def __enter__(self) -> Database:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def __del__(self) -> None:
        engine = getattr(self, "_engine", None)
        if engine is not None:
            engine.close()

    def _live(self) -> Engine:
        engine = self._engine
        if engine is None:
            raise errors.invalid_request("the database is closed")
        return engine

    # ------------------------------------------------------------ loading

    def load(
        self,
        table: str,
        *,
        path: str | None = None,
        text: str | None = None,
        schema: SchemaSpec | None = None,
        header: bool = True,
        delimiter: str = ",",
        replace: bool = False,
    ) -> TableInfo:
        """Loads CSV into ``table``, from a file (``path``, relative to the
        data directory) or from in-memory ``text`` (exactly one of them).
        ``schema`` is a sequence of ``(name, type)`` pairs (or ColumnInfo);
        without it the types are inferred (ingestion.md §1.1); ``header=False``
        requires a schema."""
        engine = self._live()
        _check_name(table)
        if (path is None) == (text is None):
            raise errors.invalid_argument("exactly one of 'path' or 'text' is required")
        if not isinstance(delimiter, str) or len(delimiter) != 1 or not delimiter.isascii() or delimiter in '"\r\n':
            raise errors.invalid_argument("delimiter must be a single ASCII character")
        columns = _columns(schema) if schema is not None else None
        if not header and columns is None:
            raise errors.invalid_argument("header=False requires an explicit schema")

        def run() -> TableInfo:
            if path is not None:
                full = resolve_data_path(engine.config.data_dir, os.fspath(path))
                source = decode_utf8(read_input_file(full, engine.ingest_limits.max_bytes))
            else:
                if not isinstance(text, str):
                    raise errors.invalid_argument("text must be a string")
                engine.ingest_limits.check_bytes(len(text.encode("utf-8", "surrogatepass")))
                source = text
            options = {"header": bool(header), "delimiter": delimiter}
            return _info(engine.load(table, "csv", source, columns, options, replace))

        return _call(run)

    def create_table(
        self, table: str, schema: SchemaSpec, rows: Iterable[Sequence[Any]], *, replace: bool = False
    ) -> TableInfo:
        """Creates ``table`` from native values: ``rows`` are sequences with
        one value per column of ``schema`` (the value types of VALUE_TYPES,
        or None). DECIMAL values must be exact at the column's scale."""
        engine = self._live()
        _check_name(table)
        columns = _columns(schema)
        converters = [_to_internal(c.type) for c in columns]
        data: list[list[Any]] = [[] for _ in columns]
        count = 0
        for count, row in enumerate(rows, 1):
            if not isinstance(row, Sequence) or len(row) != len(columns):
                raise errors.invalid_argument(f"row {count} does not have one value per column ({len(columns)})")
            for i, value in enumerate(row):
                if value is None:
                    data[i].append(None)
                    continue
                try:
                    data[i].append(converters[i](value))
                except (TypeError, ValueError, ArithmeticError) as e:
                    raise errors.conversion_error(
                        f"row {count}, column '{columns[i].name}': {e}", row=count, column_name=columns[i].name
                    ) from None
        return _call(lambda: _info(engine.create_table(table, columns, data, count, replace)))

    def create_table_as(
        self,
        table: str,
        sql: str,
        *,
        replace: bool = False,
        threads: int | None = None,
        timeout_ms: int | None = None,
    ) -> TableInfo:
        """Runs the query ``sql`` and stores its result as ``table`` (the
        query may read the table it replaces)."""
        engine = self._live()
        _check_name(table)
        options = _query_options(sql, threads, timeout_ms, None, {})
        return _call(lambda: _info(engine.materialize(table, sql, options, replace)))

    # ------------------------------------------------------------ queries

    def query(
        self,
        sql: str,
        *,
        threads: int | None = None,
        timeout_ms: int | None = None,
        max_rows: int | None = None,
        mode: str = "auto",
        join: str = "auto",
        optimize: bool = True,
        use_indexes: bool = True,
    ) -> Result:
        """Executes one SQL statement and returns its complete result.

        ``threads`` — parallelism (default: the instance's ``threads``);
        ``timeout_ms`` — fail with ``TIMEOUT`` after this time (None/0: none);
        ``max_rows`` — fail with ``RESOURCE_LIMIT`` if the result is larger;
        ``mode`` (auto/row/vectorized), ``join`` (auto/hash/merge/nested_loop),
        ``optimize`` and ``use_indexes`` are the protocol's query options."""
        engine = self._live()
        extra = {"mode": mode, "join": join, "optimize": optimize, "use_indexes": use_indexes}
        options = _query_options(sql, threads, timeout_ms, max_rows, extra)

        def run() -> Result:
            result = engine.query(sql, options)
            return _result(result.columns, result.rows)

        return _call(run)

    # ------------------------------------------------------------ storage

    def save(self, table: str, path: str) -> int:
        """Writes ``table`` (with its index definitions) atomically to the
        PQCF file ``path`` (relative to the data directory); returns its size
        in bytes."""
        engine = self._live()
        _check_name(table)

        def run() -> int:
            full = resolve_data_path(engine.config.data_dir, os.fspath(path))
            return engine.save(table, full, pqcf.SaveOptions())[1]

        return _call(run)

    def open(self, table: str, path: str, *, replace: bool = False, mmap: bool = False) -> TableInfo:
        """Opens the PQCF file ``path`` (relative to the data directory) as
        ``table``; ``mmap`` maps the file instead of reading it."""
        engine = self._live()
        _check_name(table)

        def run() -> TableInfo:
            full = resolve_data_path(engine.config.data_dir, os.fspath(path))
            return _info(engine.open(table, full, StorageOptions(mmap=mmap), replace))

        return _call(run)

    # ------------------------------------------------------------ catalog

    def drop(self, table: str) -> None:
        """Removes ``table`` (``NOT_FOUND`` if it does not exist)."""
        engine = self._live()
        _check_name(table)
        _call(lambda: engine.catalog.drop(table))

    def tables(self) -> list[TableInfo]:
        """The tables of the catalog, ordered by name."""
        engine = self._live()
        return _call(lambda: [_info(t) for t in engine.catalog.tables()])

    def schema(self, table: str) -> TableInfo:
        """Name, row count and columns of ``table`` (``NOT_FOUND`` if absent)."""
        engine = self._live()
        _check_name(table)
        return _call(lambda: _info(engine.catalog.require(table)))

    def exists(self, table: str) -> bool:
        engine = self._live()
        _check_name(table)
        return engine.catalog.exists(table)

    def __repr__(self) -> str:
        state = "closed" if self.closed else "open"
        return f"<polyquery.Database {self._config.data_dir!r} ({state})>"


# ------------------------------------------------------------ helpers


def _call(fn: Callable[[], Any]) -> Any:
    """Runs an engine operation, mapping every failure to an Error."""
    try:
        with gc_paused():
            return fn()
    except errors.PolyQueryError:
        raise
    except RecursionError:
        raise errors.resource_limit("statement is too deeply nested") from None
    except MemoryError:
        raise errors.resource_limit("out of memory") from None
    except Exception as e:  # noqa: BLE001 - an engine bug: reported, not logged
        raise errors.PolyQueryError(errors.INTERNAL_ERROR, f"internal error: {e!r}") from e


def _check_int(name: str, value: Any, minimum: int) -> None:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise errors.invalid_argument(f"{name} must be an integer >= {minimum}")


def _check_name(table: Any) -> None:
    if not isinstance(table, str) or table == "":
        raise errors.invalid_argument("a table name must be a non-empty string")


def _query_options(
    sql: Any, threads: int | None, timeout_ms: int | None, max_rows: int | None, extra: dict[str, Any]
) -> QueryOptions:
    if not isinstance(sql, str):
        raise errors.invalid_argument("sql must be a string")
    if threads is not None:
        _check_int("threads", threads, 1)
    if timeout_ms is not None:
        _check_int("timeout_ms", timeout_ms, 0)
    if max_rows is not None:
        _check_int("max_rows", max_rows, 0)
    options = QueryOptions(max_rows=max_rows, timeout_ms=timeout_ms or 0, threads=threads)
    if extra:
        if extra["mode"] not in ("auto", "row", "vectorized"):
            raise errors.unsupported(f"execution mode '{extra['mode']}' is not supported")
        if extra["join"] not in ("auto", "hash", "merge", "nested_loop"):
            raise errors.unsupported(f"join algorithm '{extra['join']}' is not supported")
        options.mode = extra["mode"]
        options.join = extra["join"]
        options.optimize = bool(extra["optimize"])
        options.use_indexes = bool(extra["use_indexes"])
    return options


def _columns(schema: Any) -> list[Column]:
    columns = []
    try:
        entries = list(schema)
    except TypeError:
        raise errors.invalid_argument("schema must be a sequence of (name, type) pairs") from None
    for entry in entries:
        if isinstance(entry, ColumnInfo):
            name, type_text = entry.name, entry.type
        else:
            try:
                name, type_text = entry
            except (TypeError, ValueError):
                raise errors.invalid_argument("schema entries must be (name, type) pairs") from None
        if not isinstance(name, str) or not isinstance(type_text, str):
            raise errors.invalid_argument("schema names and types must be strings")
        try:
            columns.append(Column(name, parse_type(type_text)))
        except InvalidTypeError as e:
            raise errors.invalid_argument(f"invalid schema type: {e}") from None
    if not columns:
        raise errors.invalid_argument("a schema needs at least one column")
    return columns


def _info(table: Any) -> TableInfo:
    return TableInfo(
        table.name, table.row_count, tuple(ColumnInfo(c.name, c.type.name) for c in table.columns)
    )


# ------------------------------------------------------------ value mapping


def _decimal_from(scale: int) -> Callable[[int], _decimal.Decimal]:
    exponent = -scale
    scaleb, make = _EXACT.scaleb, _decimal.Decimal
    return lambda unscaled: scaleb(make(unscaled), exponent)


def _date_from(days: int) -> _dt.date:
    return _dt.date.fromordinal(days + _EPOCH_ORDINAL)


def _timestamp_from(micros: int) -> _dt.datetime:
    return _EPOCH + _dt.timedelta(microseconds=micros)


def _to_native(dtype: DataType) -> Callable[[Any], Any] | None:
    """Converter of internal values of ``dtype`` to native values (None:
    the internal value is already native)."""
    kind = dtype.kind
    if kind is TypeKind.DECIMAL:
        return _decimal_from(dtype.scale)
    if kind is TypeKind.DATE:
        return _date_from
    if kind is TypeKind.TIMESTAMP:
        return _timestamp_from
    return None


def _result(columns: list[Column], rows: list[tuple]) -> Result:
    converters = [(i, c) for i, c in enumerate(_to_native(col.type) for col in columns) if c is not None]
    if converters and rows:
        out = []
        for row in rows:
            values = list(row)
            for i, convert in converters:
                v = values[i]
                if v is not None:
                    values[i] = convert(v)
            out.append(tuple(values))
        rows = out
    elif rows and not isinstance(rows[0], tuple):
        rows = [tuple(r) for r in rows]
    return Result(tuple(c.name for c in columns), tuple(c.type.name for c in columns), list(rows))


def _to_internal(dtype: DataType) -> Callable[[Any], Any]:
    """Converter of native values to the engine's runtime representation
    (datatypes.py); raises TypeError / ValueError for unfit values."""
    kind = dtype.kind
    if kind is TypeKind.BOOLEAN:
        def boolean(v: Any) -> bool:
            if not isinstance(v, bool):
                raise TypeError(f"expected bool, got {type(v).__name__}")
            return v
        return boolean
    if kind is TypeKind.INT64:
        def int64(v: Any) -> int:
            if not isinstance(v, int) or isinstance(v, bool):
                raise TypeError(f"expected int, got {type(v).__name__}")
            if not _INT64_MIN <= v <= _INT64_MAX:
                raise ValueError("value out of the INT64 range")
            return v
        return int64
    if kind is TypeKind.FLOAT64:
        def float64(v: Any) -> float:
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                raise TypeError(f"expected float, got {type(v).__name__}")
            f = float(v)
            if not math.isfinite(f):
                raise ValueError("FLOAT64 values must be finite")
            return f
        return float64
    if kind is TypeKind.DECIMAL:
        scale, limit = dtype.scale, 10**dtype.precision

        def dec(v: Any) -> int:
            if isinstance(v, bool) or not isinstance(v, (int, _decimal.Decimal)):
                raise TypeError(f"expected Decimal or int, got {type(v).__name__}")
            d = _decimal.Decimal(v)
            if not d.is_finite():
                raise ValueError("DECIMAL values must be finite")
            scaled = _EXACT.scaleb(d, scale)
            unscaled = int(scaled)
            if scaled != unscaled:
                raise ValueError(f"{v} has more than {scale} fractional digits")
            if abs(unscaled) >= limit:
                raise ValueError(f"{v} does not fit {dtype.name}")
            return unscaled
        return dec
    if kind is TypeKind.STRING:
        def string(v: Any) -> str:
            if not isinstance(v, str):
                raise TypeError(f"expected str, got {type(v).__name__}")
            return v
        return string
    if kind is TypeKind.DATE:
        def date(v: Any) -> int:
            if not isinstance(v, _dt.date) or isinstance(v, _dt.datetime):
                raise TypeError(f"expected datetime.date, got {type(v).__name__}")
            return v.toordinal() - _EPOCH_ORDINAL
        return date
    if kind is TypeKind.TIMESTAMP:
        def timestamp(v: Any) -> int:
            if isinstance(v, _dt.datetime):
                if v.tzinfo is not None:
                    v = v.astimezone(_dt.timezone.utc).replace(tzinfo=None)
                delta = v - _EPOCH
            elif isinstance(v, _dt.date):
                delta = _dt.datetime(v.year, v.month, v.day) - _EPOCH
            else:
                raise TypeError(f"expected datetime.datetime, got {type(v).__name__}")
            return (delta.days * 86_400 + delta.seconds) * 1_000_000 + delta.microseconds
        return timestamp
    raise TypeError(f"unsupported column type {dtype.name}")
