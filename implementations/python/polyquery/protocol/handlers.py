"""Protocol request handling (spec/protocol/protocol.md §4-§6).

:class:`RequestHandler` validates request objects, dispatches them to the
engine and builds response objects. It is transport-independent (used by the
session and exec CLI modes).
"""

from __future__ import annotations

import logging
import os
import platform
import time
from typing import Any

from .. import ENGINE_NAME, ENGINE_VERSION, PROTOCOL_VERSION, SPEC_VERSION, errors
from ..datatypes import InvalidTypeError, parse_type
from ..ingest.loader import FORMATS
from ..service import Engine, QueryOptions
from ..storage.catalog import Column
from .serialize import serialize_rows

log = logging.getLogger("polyquery")

CAPABILITIES = ["phase1", "ingest.csv", "ingest.json", "ingest.jsonl", "sql.basic", "test.functions"]

_LATER_PHASE_OPS = frozenset({"explain", "save", "open", "stats"})


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


class RequestHandler:
    def __init__(self, engine: Engine):
        self.engine = engine
        self.config = engine.config

    def handle(self, request: Any) -> dict[str, Any]:
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
                if op in _LATER_PHASE_OPS:
                    raise errors.unsupported(f"operation '{op}' is not supported")
                raise errors.invalid_request(f"unknown op '{op}'")
            body = method(request)
            response: dict[str, Any] = {"id": req_id, "ok": True}
            response.update(body)
            if "stats" in response:
                response["stats"]["elapsed_us"] = int((time.perf_counter() - started) * 1e6)
            return response
        except errors.PolyQueryError as e:
            return {"id": req_id, "ok": False, "error": e.to_json()}
        except RecursionError:
            return {
                "id": req_id,
                "ok": False,
                "error": {"code": errors.RESOURCE_LIMIT, "message": "statement is too deeply nested"},
            }
        except MemoryError:
            return {
                "id": req_id,
                "ok": False,
                "error": {"code": errors.RESOURCE_LIMIT, "message": "out of memory"},
            }
        except Exception:  # noqa: BLE001 - must never crash the session
            log.exception("internal error while handling request")
            return {
                "id": req_id,
                "ok": False,
                "error": {"code": errors.INTERNAL_ERROR, "message": "internal error"},
            }

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
        options = _csv_options(_optional_object(req, "options")) if fmt == "csv" else {}
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
        table = self.engine.load(name, fmt, text, schema, options, replace)
        return {"table": table.name, "row_count": table.row_count, "columns": table.schema_json()}

    def op_query(self, req: dict) -> dict[str, Any]:
        sql = req.get("sql")
        if not isinstance(sql, str):
            raise errors.invalid_request("field 'sql' must be a string")
        raw = _optional_object(req, "options")
        options = QueryOptions(
            max_rows=_optional_nonneg_int(raw, "max_rows"),
            timeout_ms=_optional_nonneg_int(raw, "timeout_ms") or 0,
        )
        count_only = self._validate_query_options(raw)
        result = self.engine.query(sql, options)
        body: dict[str, Any] = {"columns": [c.to_json() for c in result.columns]}
        if not count_only:
            body["rows"] = serialize_rows(result.columns, result.rows)
        body["row_count"] = len(result.rows)
        body["stats"] = {}
        return body

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
        if mode not in ("auto", "row"):
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
            "indexes": [],
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
