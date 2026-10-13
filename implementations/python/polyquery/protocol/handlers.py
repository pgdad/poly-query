"""Protocol request handling (spec/protocol/protocol.md §4-§6).

:class:`RequestHandler` validates request objects, dispatches them to the
engine and builds response objects. It is transport-independent (used by the
session and exec CLI modes and by the HTTP server, which passes a
:class:`QueryControl` to make queries cancellable and to impose deadlines).
"""

from __future__ import annotations

import logging
import os
import platform
import threading
import time
from collections.abc import Generator
from dataclasses import dataclass
from typing import Any

from .. import ENGINE_NAME, ENGINE_VERSION, PROTOCOL_VERSION, SPEC_VERSION, errors
from ..datatypes import InvalidTypeError, parse_type
from ..execution.context import gc_paused, gc_paused_iter
from ..ingest.loader import FORMATS
from ..service import Engine, QueryOptions, StorageOptions
from ..storage import pqcf
from ..storage.catalog import Column
from ..storage.table import LAYOUTS
from .serialize import row_serializer, serialize_rows, serialize_value

log = logging.getLogger("polyquery")

CAPABILITIES = [
    "phase1",
    "ingest.csv",
    "ingest.json",
    "ingest.jsonl",
    "sql.basic",
    "test.functions",
    "phase2",
    "sql.groupby",
    "sql.join",
    "sql.functions",
    "sql.subquery",
    "sql.cte",
    "sql.correlated_subquery",
    "phase3",
    "storage.pqcf",
    "storage.mmap",
    "index.hash",
    "index.btree",
    "phase4",
    "http.streaming",
    "phase5",
    "exec.row",
    "exec.vectorized",
    "exec.parallel",
    "join.hash",
    "join.merge",
    "join.nested_loop",
    "native.kernels",
    "change.union_all",
    "change.decimal38",
]


def version_info() -> dict[str, Any]:
    return {
        "ok": True,
        "engine": ENGINE_NAME,
        "engine_version": ENGINE_VERSION,
        "language": "python",
        "protocol_version": PROTOCOL_VERSION,
        "spec_version": SPEC_VERSION,
        "runtime": f"{platform.python_implementation()} {platform.python_version()}",
        "build": {"profile": "release", "flags": ""},
    }


def capabilities_info() -> dict[str, Any]:
    return {"ok": True, "protocol_version": PROTOCOL_VERSION, "capabilities": list(CAPABILITIES)}


# ------------------------------------------------------------ field validation


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _require_str(req: dict, key: str, *, allow_empty: bool = False) -> str:
    v = req.get(key)
    if not isinstance(v, str) or (not allow_empty and v == ""):
        raise errors.invalid_request(f"field '{key}' must be a non-empty string")
    return v


def _optional_bool(obj: dict, key: str, default: bool) -> bool:
    v = obj.get(key, default)
    if v is None:
        return default
    if not isinstance(v, bool):
        raise errors.invalid_request(f"field '{key}' must be a boolean")
    return v


def _optional_object(req: dict, key: str) -> dict:
    v = req.get(key)
    if v is None:
        return {}
    if not isinstance(v, dict):
        raise errors.invalid_request(f"field '{key}' must be an object")
    return v


def _optional_nonneg_int(obj: dict, key: str) -> int | None:
    v = obj.get(key)
    if v is None:
        return None
    if not _is_int(v) or v < 0:
        raise errors.invalid_request(f"option '{key}' must be a non-negative integer")
    return v


def _parse_schema(raw: Any) -> list[Column] | None:
    if raw is None:
        return None
    if not isinstance(raw, list):
        raise errors.invalid_request("field 'schema' must be an array")
    columns = []
    for entry in raw:
        if not isinstance(entry, dict):
            raise errors.invalid_request("schema entries must be objects")
        name, type_text = entry.get("name"), entry.get("type")
        if not isinstance(name, str) or not isinstance(type_text, str):
            raise errors.invalid_request("schema entries need string 'name' and 'type'")
        try:
            dtype = parse_type(type_text)
        except InvalidTypeError as e:
            raise errors.invalid_request(f"invalid schema type: {e}") from None
        columns.append(Column(name, dtype))
    return columns


def _storage_options(raw: dict) -> StorageOptions:
    """The in-memory layout options of ``load`` / ``open``."""
    layout = raw.get("layout")
    if layout is None:
        layout = "column"
    if not isinstance(layout, str) or layout not in LAYOUTS:
        raise errors.invalid_request("option 'layout' must be 'row' or 'column'")
    dictionary = raw.get("dictionary")
    if dictionary is not None and not isinstance(dictionary, bool):
        raise errors.invalid_request("option 'dictionary' must be a boolean")
    return StorageOptions(layout, dictionary, _optional_bool(raw, "mmap", False))


def _save_options(raw: dict) -> pqcf.SaveOptions:
    size = raw.get("row_group_size")
    if size is None:
        size = pqcf.DEFAULT_ROW_GROUP_SIZE
    if not _is_int(size) or size < 1:
        raise errors.invalid_request("option 'row_group_size' must be a positive integer")
    encoding = raw.get("encoding")
    if encoding is None:
        encoding = "auto"
    if not isinstance(encoding, str) or encoding.lower() not in pqcf.FORCED_ENCODINGS:
        raise errors.invalid_request("option 'encoding' must be one of auto, plain, dict, rle")
    return pqcf.SaveOptions(size, encoding.lower())


def _csv_options(raw: dict) -> dict[str, Any]:
    header = _optional_bool(raw, "header", True)
    delimiter = raw.get("delimiter", ",")
    if delimiter is None:
        delimiter = ","
    if (
        not isinstance(delimiter, str)
        or len(delimiter) != 1
        or not delimiter.isascii()
        or delimiter in '"\r\n'
    ):
        raise errors.invalid_request("option 'delimiter' must be a single ASCII character")
    return {"header": header, "delimiter": delimiter}


# ------------------------------------------------------------ path safety


def resolve_data_path(data_dir: str, path: str) -> str:
    """Resolves a request path inside the data directory (protocol.md §6)."""
    if path == "" or "\x00" in path or os.path.isabs(path):
        raise errors.access_denied("path must be a non-empty relative path")
    parts = path.replace("\\", "/").split("/")
    if ".." in parts:
        raise errors.access_denied("path must not contain '..' components")
    return os.path.join(data_dir, path)


def _read_file(full_path: str, max_bytes: int) -> bytes:
    try:
        with open(full_path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size > max_bytes:
                raise errors.resource_limit(f"input file exceeds the ingestion limit of {max_bytes} bytes")
            return f.read()
    except FileNotFoundError:
        raise errors.not_found("file does not exist") from None
    except PermissionError:
        raise errors.access_denied("permission denied") from None
    except IsADirectoryError:
        raise errors.io_error("path is a directory") from None
    except OSError as e:
        raise errors.io_error(f"cannot read file: {e.strerror}") from None


# ------------------------------------------------------------ handler


def error_of(exc: Exception) -> errors.PolyQueryError:
    """The protocol error reported for an exception raised by an operation."""
    if isinstance(exc, errors.PolyQueryError):
        return exc
    if isinstance(exc, RecursionError):
        return errors.resource_limit("statement is too deeply nested")
    if isinstance(exc, MemoryError):
        return errors.resource_limit("out of memory")
    log.error("internal error while handling request", exc_info=exc)
    return errors.PolyQueryError(errors.INTERNAL_ERROR, "internal error")


@dataclass
class QueryControl:
    """Server-side control of one query: cancellation and an absolute
    ``time.monotonic()`` deadline (None = no timeout)."""

    cancel_event: threading.Event
    deadline: float | None = None


@dataclass
class QueryStream:
    """An executing query whose rows are produced incrementally."""

    columns: list[dict[str, str]]
    batches: Generator[list[Any]]  # serialized row batches


# ops that honour a QueryControl
CONTROLLED_OPS = frozenset({"query"})


class RequestHandler:
    def __init__(self, engine: Engine):
        self.engine = engine
        self.config = engine.config
        # per thread: the exception of the last failed request (see handle)
        self._failed = threading.local()

    def handle(self, request: Any, control: QueryControl | None = None) -> dict[str, Any]:
        """Handles one decoded request; never raises."""
        req_id = request.get("id") if isinstance(request, dict) else None
        started = time.perf_counter()
        try:
            if not isinstance(request, dict):
                raise errors.invalid_request("request must be a JSON object")
            op = request.get("op")
            if not isinstance(op, str):
                raise errors.invalid_request("field 'op' must be a string")
            method = getattr(self, "op_" + op, None)
            if method is None:
                raise errors.invalid_request(f"unknown op '{op}'")
            with gc_paused():
                body = method(request, control) if op in CONTROLLED_OPS else method(request)
            response: dict[str, Any] = {"id": req_id, "ok": True}
            response.update(body)
            if "stats" in response:
                response["stats"]["elapsed_us"] = int((time.perf_counter() - started) * 1e6)
            return response
        except Exception as e:  # noqa: BLE001 - must never crash the session
            # The traceback holds everything the failed statement built
            # (parse tree, plans, compiled closures): for a large statement,
            # freeing it takes long enough to delay the answer (a TIMEOUT is
            # due within 1 s of expiry). It is kept until the transport has
            # sent the response and calls release_failed().
            self._failed.error = e
            return {"id": req_id, "ok": False, "error": error_of(e).to_json()}

    def release_failed(self) -> None:
        """Frees what the last failed request of this thread left behind;
        transports call it after sending the response."""
        self._failed.error = None

    # ---------------------------------------------------------------- ops

    def op_version(self, req: dict) -> dict[str, Any]:
        info = version_info()
        del info["ok"]
        return info

    def op_capabilities(self, req: dict) -> dict[str, Any]:
        info = capabilities_info()
        del info["ok"]
        return info

    def op_load(self, req: dict) -> dict[str, Any]:
        name = _require_str(req, "table")
        fmt = req.get("format")
        if fmt not in FORMATS:
            raise errors.invalid_request("field 'format' must be one of csv, json, jsonl")
        path, data = req.get("path"), req.get("data")
        if (path is None) == (data is None):
            raise errors.invalid_request("exactly one of 'path' or 'data' is required")
        schema = _parse_schema(req.get("schema"))
        raw_options = _optional_object(req, "options")
        storage = _storage_options(raw_options)
        options = _csv_options(raw_options) if fmt == "csv" else {}
        if fmt == "csv" and not options["header"] and schema is None:
            raise errors.invalid_request("header=false requires an explicit schema")
        replace = _optional_bool(req, "replace", False)

        limits = self.engine.ingest_limits
        if path is not None:
            if not isinstance(path, str):
                raise errors.invalid_request("field 'path' must be a string")
            raw = _read_file(resolve_data_path(self.config.data_dir, path), limits.max_bytes)
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                raise errors.ingest_error("input is not valid UTF-8") from None
        else:
            if not isinstance(data, str):
                raise errors.invalid_request("field 'data' must be a string")
            limits.check_bytes(len(data.encode("utf-8", "surrogatepass")))
            text = data
        table = self.engine.load(name, fmt, text, schema, options, replace, storage)
        return {"table": table.name, "row_count": table.row_count, "columns": table.schema_json()}

    def _path(self, req: dict) -> tuple[str, str]:
        path = req.get("path")
        if not isinstance(path, str):
            raise errors.invalid_request("field 'path' must be a string")
        return path, resolve_data_path(self.config.data_dir, path)

    def op_save(self, req: dict) -> dict[str, Any]:
        name = _require_str(req, "table")
        path, full_path = self._path(req)
        options = _save_options(_optional_object(req, "options"))
        table, size = self.engine.save(name, full_path, options)
        return {"table": table.name, "path": path, "bytes": size}

    def op_open(self, req: dict) -> dict[str, Any]:
        name = _require_str(req, "table")
        path, full_path = self._path(req)
        storage = _storage_options(_optional_object(req, "options"))
        replace = _optional_bool(req, "replace", False)
        table = self.engine.open(name, full_path, storage, replace)
        return {
            "table": table.name,
            "path": path,
            "row_count": table.row_count,
            "columns": table.schema_json(),
            "indexes": [i.to_json() for i in self.engine.indexes_of(table)],
        }

    def op_stats(self, req: dict) -> dict[str, Any]:
        table = self.engine.catalog.require(_require_str(req, "table"))
        columns = []
        for i, column in enumerate(table.columns):
            stats = table.column_stats(i)
            columns.append(
                {
                    "name": column.name,
                    "type": column.type.name,
                    "null_count": stats.null_count,
                    "distinct_count": stats.distinct_count,
                    "min": serialize_value(stats.min, column.type),
                    "max": serialize_value(stats.max, column.type),
                }
            )
        return {"table": table.name, "row_count": table.row_count, "columns": columns}

    def _query_request(
        self, req: dict, control: QueryControl | None = None
    ) -> tuple[str, QueryOptions, bool]:
        sql = req.get("sql")
        if not isinstance(sql, str):
            raise errors.invalid_request("field 'sql' must be a string")
        raw = _optional_object(req, "options")
        options = QueryOptions(
            max_rows=_optional_nonneg_int(raw, "max_rows"),
            timeout_ms=_optional_nonneg_int(raw, "timeout_ms") or 0,
        )
        if control is not None:
            options.cancel_event = control.cancel_event
            options.deadline = control.deadline
        elif options.timeout_ms:
            # the timeout counts from receipt of the request and covers
            # parsing, binding, planning and execution (CR-6 §4)
            options.deadline = time.monotonic() + options.timeout_ms / 1000.0
        count_only = self._validate_query_options(raw)
        options.optimize = _optional_bool(raw, "optimize", True)
        options.use_indexes = _optional_bool(raw, "use_indexes", True)
        options.join = raw.get("join") or "auto"
        options.mode = raw.get("mode") or "auto"
        options.threads = raw.get("threads")
        options.native = _optional_bool(raw, "native", False)
        return sql, options, count_only

    def op_explain(self, req: dict) -> dict[str, Any]:
        sql, options, _ = self._query_request(req)
        return {"plan": self.engine.explain(sql, options)}

    def op_query(self, req: dict, control: QueryControl | None = None) -> dict[str, Any]:
        sql, options, count_only = self._query_request(req, control)
        if count_only:
            columns, row_count = self.engine.count(sql, options)
            return {"columns": [c.to_json() for c in columns], "row_count": row_count, "stats": {}}
        result = self.engine.query(sql, options)
        body: dict[str, Any] = {"columns": [c.to_json() for c in result.columns]}
        body["rows"] = serialize_rows(result.columns, result.rows)
        body["row_count"] = len(result.rows)
        body["stats"] = {}
        return body

    def open_stream(self, req: dict, control: QueryControl | None = None) -> QueryStream:
        """Starts a query for streaming. Errors found before execution starts
        (validation, parsing, binding, planning) are raised as PolyQueryError;
        later errors are raised while iterating the batches."""
        sql, options, _ = self._query_request(req, control)
        cursor = self.engine.open_cursor(sql, options)
        convert = row_serializer(cursor.columns)
        return QueryStream(
            [c.to_json() for c in cursor.columns],
            gc_paused_iter(convert(batch) for batch in cursor.batches),
        )

    @staticmethod
    def _validate_query_options(raw: dict) -> bool:
        """Validates the known query options; returns True for result=count."""
        result = raw.get("result", "rows")
        if not isinstance(result, str):
            raise errors.invalid_request("option 'result' must be a string")
        if result not in ("rows", "count"):
            raise errors.unsupported(f"result mode '{result}' is not supported")
        mode = raw.get("mode", "auto")
        if not isinstance(mode, str):
            raise errors.invalid_request("option 'mode' must be a string")
        if mode not in ("auto", "row", "vectorized"):
            raise errors.unsupported(f"execution mode '{mode}' is not supported")
        threads = raw.get("threads")
        if threads is not None and (not _is_int(threads) or threads < 1):
            raise errors.invalid_request("option 'threads' must be a positive integer")
        join = raw.get("join", "auto")
        if not isinstance(join, str):
            raise errors.invalid_request("option 'join' must be a string")
        if join not in ("auto", "hash", "merge", "nested_loop"):
            raise errors.unsupported(f"join algorithm '{join}' is not supported")
        for key in ("optimize", "use_indexes", "native"):
            _optional_bool(raw, key, False)
        query_id = raw.get("query_id")
        if query_id is not None and not isinstance(query_id, str):
            raise errors.invalid_request("option 'query_id' must be a string")
        return result == "count"

    def op_tables(self, req: dict) -> dict[str, Any]:
        return {
            "tables": [{"name": t.name, "row_count": t.row_count} for t in self.engine.catalog.tables()]
        }

    def op_schema(self, req: dict) -> dict[str, Any]:
        table = self.engine.catalog.require(_require_str(req, "table"))
        return {
            "table": table.name,
            "row_count": table.row_count,
            "columns": table.schema_json(),
            "indexes": [i.to_json() for i in self.engine.indexes_of(table)],
            "layout": table.layout,
        }

    def op_drop(self, req: dict) -> dict[str, Any]:
        self.engine.catalog.drop(_require_str(req, "table"))
        return {}

    def op_reset(self, req: dict) -> dict[str, Any]:
        self.engine.catalog.reset()
        return {}

    def op_sleep(self, req: dict) -> dict[str, Any]:
        if not self.config.test_functions:
            raise errors.invalid_request("the sleep op requires --enable-test-functions")
        ms = req.get("ms")
        if not _is_int(ms) or ms < 0:
            raise errors.invalid_request("field 'ms' must be a non-negative integer")
        time.sleep(ms / 1000.0)
        return {}
