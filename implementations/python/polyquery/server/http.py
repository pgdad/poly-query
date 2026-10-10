"""HTTP/1.1 front end (protocol.md §7): routing, request bodies, JSON
responses, NDJSON streaming with backpressure and the query lifecycle
(registration, admission, execution, metrics and logging)."""

from __future__ import annotations

import logging
import select
import socket
import socketserver
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TYPE_CHECKING, Any
from urllib.parse import parse_qs, unquote, urlsplit

from .. import errors
from ..protocol.handlers import QueryControl, capabilities_info, error_of, version_info
from ..protocol.serialize import dumps
from ..protocol.session import decode_request, encode_response, precheck_request
from .metrics import CONTENT_TYPE as METRICS_CONTENT_TYPE

if TYPE_CHECKING:
    from .app import Server

log = logging.getLogger("polyquery")

# protocol.md §7.1
STATUS_OF_CODE = {
    **dict.fromkeys(
        [
            errors.PARSE_ERROR,
            errors.SEMANTIC_ERROR,
            errors.TYPE_ERROR,
            errors.CONVERSION_ERROR,
            errors.INVALID_ARGUMENT,
            errors.INVALID_REQUEST,
            errors.INGEST_ERROR,
            errors.NUMERIC_OVERFLOW,
            errors.DIVISION_BY_ZERO,
            errors.SUBQUERY_CARDINALITY,
            errors.UNSUPPORTED,
        ],
        400,
    ),
    errors.ACCESS_DENIED: 403,
    errors.NOT_FOUND: 404,
    errors.ALREADY_EXISTS: 409,
    errors.CANCELLED: 409,
    errors.RESOURCE_LIMIT: 413,
    **dict.fromkeys(
        [errors.INTERNAL_ERROR, errors.IO_ERROR, errors.STORAGE_CORRUPT, errors.STORAGE_VERSION_UNSUPPORTED],
        500,
    ),
    errors.OVERLOADED: 503,
    errors.SHUTTING_DOWN: 503,
    errors.TIMEOUT: 504,
}

QUERY_ID_HEADER = "X-PolyQuery-Query-Id"
STREAM_ROWS_PER_LINE = 10_000
# oversized request bodies up to this size are read and discarded so that
# the 413 response reaches the client; larger ones close the connection
_DISCARD_LIMIT = 64 * 1024 * 1024
_WRITE_POLL_MS = 50

# (path pattern, method -> endpoint); "{}" matches one percent-decoded segment
ROUTES: list[tuple[tuple[str, ...], dict[str, str]]] = [
    (("health",), {"GET": "health"}),
    (("metrics",), {"GET": "metrics"}),
    (("v1", "version"), {"GET": "version"}),
    (("v1", "capabilities"), {"GET": "capabilities"}),
    (("v1", "query"), {"POST": "query"}),
    (("v1", "query", "stream"), {"POST": "query_stream"}),
    (("v1", "explain"), {"POST": "explain"}),
    (("v1", "request"), {"POST": "request"}),
    (("v1", "tables"), {"GET": "tables"}),
    (("v1", "tables", "{}"), {"PUT": "load", "DELETE": "drop"}),
    (("v1", "tables", "{}", "schema"), {"GET": "schema"}),
    (("v1", "tables", "{}", "stats"), {"GET": "stats"}),
    (("v1", "queries"), {"GET": "queries"}),
    (("v1", "queries", "{}"), {"DELETE": "cancel"}),
]


def match_route(path: str) -> tuple[dict[str, str], list[str]] | None:
    """The endpoints of a path and its parameters, or None if unknown."""
    segments = path.split("/")[1:] if path.startswith("/") else None
    if not segments:
        return None
    for pattern, methods in ROUTES:
        if len(pattern) != len(segments):
            continue
        params = []
        for expected, actual in zip(pattern, segments):
            if expected == "{}":
                if not actual:
                    break
                params.append(unquote(actual))
            elif expected != actual:
                break
        else:
            return methods, params
    return None


def status_of(response: dict[str, Any], success: int = 200) -> int:
    if response.get("ok"):
        return success
    return STATUS_OF_CODE.get(response["error"]["code"], 500)


def error_response(request: Any, error: errors.PolyQueryError) -> dict[str, Any]:
    req_id = request.get("id") if isinstance(request, dict) else None
    return {"id": req_id, "ok": False, "error": error.to_json()}


class _HttpError(Exception):
    """A request-level failure answered with an error response."""

    def __init__(self, status: int, error: errors.PolyQueryError):
        super().__init__(error.message)
        self.status = status
        self.error = error


class _StreamAborted(Exception):
    """The stream cannot continue: the client is gone or stopped reading
    while the query was cancelled or timed out."""

    def __init__(self, error: errors.PolyQueryError):
        super().__init__(error.message)
        self.error = error


@dataclass
class _Outcome:
    """Result of executing one query request."""

    response: dict[str, Any] | None  # still to be sent (None: already streamed)
    error: errors.PolyQueryError | None
    rows: int = 0


def _requested_control(request: dict) -> tuple[str | None, int]:
    """The query id and timeout requested in a query's options. Ill-typed
    values are ignored here; request validation reports them."""
    options = request.get("options")
    if not isinstance(options, dict):
        return None, 0
    query_id = options.get("query_id")
    timeout = options.get("timeout_ms")
    if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout < 0:
        timeout = 0
    return (query_id if isinstance(query_id, str) else None), timeout


class ChunkedWriter:
    """Writes HTTP chunks directly to the socket. When the client stops
    reading, writing blocks (backpressure on the producing query) while
    still observing cancellation and the query deadline."""

    def __init__(self, sock: socket.socket, control: QueryControl):
        self.sock = sock
        self.control = control
        self.poller = select.poll()
        self.poller.register(sock.fileno(), select.POLLOUT)

    def line(self, obj: dict[str, Any]) -> None:
        data = dumps(obj).encode("utf-8") + b"\n"
        self._send(b"%X\r\n" % len(data) + data + b"\r\n")

    def finish(self) -> None:
        self._send(b"0\r\n\r\n")

    def _send(self, data: bytes) -> None:
        view = memoryview(data)
        while view:
            try:
                sent = self.sock.send(view, socket.MSG_DONTWAIT)
            except (BlockingIOError, InterruptedError):
                self._wait_writable()
                continue
            except OSError:
                raise _StreamAborted(errors.cancelled("the client disconnected")) from None
            view = view[sent:]

    def _wait_writable(self) -> None:
        while True:
            if self.control.cancel_event.is_set():
                raise _StreamAborted(errors.cancelled("query was cancelled"))
            deadline = self.control.deadline
            if deadline is not None and time.monotonic() > deadline:
                raise _StreamAborted(errors.timeout_error("query exceeded its timeout"))
            if self.poller.poll(_WRITE_POLL_MS):
                return


class PolyQueryHTTPServer(ThreadingHTTPServer):
    """Thread-per-connection HTTP server bound to one :class:`Server`."""

    daemon_threads = True
    block_on_close = False  # shutdown must not wait for idle keep-alive connections
    allow_reuse_address = True
    request_queue_size = 256

    def __init__(self, address: tuple[str, int], app: Server):
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        self.app = app
        super().__init__(address, ApiRequestHandler)

    def server_bind(self) -> None:
        # HTTPServer.server_bind resolves the host's FQDN, which may be slow
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)

    def handle_error(self, request: Any, client_address: Any) -> None:
        log.debug("connection error", exc_info=True)


class ApiRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "polyquery"
    sys_version = ""
    server: PolyQueryHTTPServer

    @property
    def app(self) -> Server:
        return self.server.app

    # ------------------------------------------------------------ dispatch

    def do_GET(self) -> None:
        self._dispatch()

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_GET

    def _dispatch(self) -> None:
        with self.app.busy():
            self._started = time.monotonic()
            url = urlsplit(self.path)
            try:
                body = self._read_body()
                route = match_route(url.path)
                if route is None:
                    raise _HttpError(404, errors.not_found(f"no such endpoint: {url.path}"))
                methods, params = route
                endpoint = methods.get(self.command)
                if endpoint is None:
                    self._allow = ", ".join(sorted(methods))
                    raise _HttpError(
                        405, errors.invalid_request(f"method {self.command} is not allowed for {url.path}")
                    )
                query = parse_qs(url.query, keep_blank_values=True)
                getattr(self, "api_" + endpoint)(*params, query=query, body=body)
            except _HttpError as e:
                headers = [("Allow", self._allow)] if e.status == 405 else []
                self._send_json(e.status, {"id": None, "ok": False, "error": e.error.to_json()}, headers)

    _allow = ""

    # ------------------------------------------------------------ request bodies

    def _read_body(self) -> bytes:
        limit = self.app.config.max_request_bytes
        encoding = self.headers.get("Transfer-Encoding", "").strip().lower()
        if encoding and encoding != "identity":
            if encoding.split(",")[-1].strip() != "chunked":
                self.close_connection = True
                raise _HttpError(400, errors.invalid_request(f"unsupported transfer encoding '{encoding}'"))
            return self._read_chunked(limit)
        length_text = self.headers.get("Content-Length")
        if length_text is None:
            return b""
        try:
            length = int(length_text)
            if length < 0:
                raise ValueError
        except ValueError:
            self.close_connection = True
            raise _HttpError(400, errors.invalid_request("invalid Content-Length")) from None
        if length > limit:
            self._discard(length)
            raise _HttpError(413, errors.resource_limit(f"request body exceeds {limit} bytes"))
        data = self.rfile.read(length)
        if len(data) < length:
            self.close_connection = True
            raise _HttpError(400, errors.invalid_request("incomplete request body"))
        return data

    def _read_chunked(self, limit: int) -> bytes:
        parts: list[bytes] = []
        total = 0
        while True:
            line = self.rfile.readline(65537)
            try:
                size = int(line.split(b";", 1)[0].strip(), 16)
            except ValueError:
                self.close_connection = True
                raise _HttpError(400, errors.invalid_request("malformed chunked body")) from None
            if size == 0:
                while self.rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                    pass  # trailer fields are ignored
                return b"".join(parts)
            total += size
            if total > limit:
                self.close_connection = True
                raise _HttpError(413, errors.resource_limit(f"request body exceeds {limit} bytes"))
            parts.append(self.rfile.read(size))
            self.rfile.readline()

    def _discard(self, length: int) -> None:
        if length > _DISCARD_LIMIT:
            self.close_connection = True
            return
        while length > 0:
            chunk = self.rfile.read(min(length, 65536))
            if not chunk:
                self.close_connection = True
                return
            length -= len(chunk)

    def _json_request(self, body: bytes) -> dict[str, Any]:
        """Decodes a JSON request object (400 INVALID_REQUEST otherwise)."""
        try:
            request = decode_request(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError, RecursionError):
            raise _HttpError(400, errors.invalid_request("request body is not valid JSON")) from None
        problem = precheck_request(request)
        if problem is not None:
            raise _HttpError(400, errors.invalid_request(problem["error"]["message"]))
        return request

    # ------------------------------------------------------------ responses

    def _send_json(self, status: int, obj: dict[str, Any], headers: list[tuple[str, str]] | None = None) -> None:
        self._send_body(status, encode_response(obj), "application/json", headers)

    def _send_protocol(self, response: dict[str, Any], success: int = 200, headers=None) -> None:
        self._send_json(status_of(response, success), response, headers)

    def _send_body(
        self, status: int, body: bytes, content_type: str, headers: list[tuple[str, str]] | None = None
    ) -> None:
        if self.app.shutting_down.is_set():
            self.close_connection = True
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for name, value in headers or []:
                self.send_header(name, value)
            if self.close_connection:
                self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except OSError:
            self.close_connection = True

    def send_error(self, code: int, message: str | None = None, explain: str | None = None) -> None:
        """Errors detected by http.server itself (malformed request line,
        oversized headers, unsupported method), answered with a JSON body."""
        if code == HTTPStatus.NOT_IMPLEMENTED:  # unknown method
            code = HTTPStatus.METHOD_NOT_ALLOWED
        if code == HTTPStatus.NOT_FOUND:
            error = errors.not_found(message or "not found")
        elif code in (HTTPStatus.REQUEST_ENTITY_TOO_LARGE, HTTPStatus.REQUEST_URI_TOO_LONG,
                      HTTPStatus.REQUEST_HEADER_FIELDS_TOO_LARGE):
            error = errors.resource_limit(message or "request too large")
        elif code >= 500:
            error = errors.PolyQueryError(errors.INTERNAL_ERROR, message or "internal error")
        else:
            error = errors.invalid_request(message or "bad request")
        if code >= 400 and code != HTTPStatus.METHOD_NOT_ALLOWED:
            self.close_connection = True
        if not hasattr(self, "_started"):
            self._started = time.monotonic()
        self._send_json(code, {"id": None, "ok": False, "error": error.to_json()})

    def log_request(self, code: int | str = "-", size: int | str = "-") -> None:
        status = int(code) if isinstance(code, (int, HTTPStatus)) else 0
        self.app.metrics.http_request(status)
        started = getattr(self, "_started", None)
        log.debug(
            "http request",
            extra={
                "fields": {
                    "method": self.command,
                    "path": urlsplit(getattr(self, "path", None) or "").path,
                    "status": status,
                    "duration_ms": round((time.monotonic() - started) * 1000, 3) if started else None,
                }
            },
        )

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 - stdlib signature
        log.debug(format % args)

    # ------------------------------------------------------------ endpoints

    def api_health(self, *, query, body) -> None:
        if self.app.shutting_down.is_set():
            self._send_json(503, {"status": "shutting_down"})
        else:
            self._send_json(200, {"status": "ok"})

    def api_metrics(self, *, query, body) -> None:
        self._send_body(200, self.app.render_metrics().encode("utf-8"), METRICS_CONTENT_TYPE)

    def api_version(self, *, query, body) -> None:
        self._send_json(200, version_info())

    def api_capabilities(self, *, query, body) -> None:
        self._send_json(200, capabilities_info())

    def api_query(self, *, query, body) -> None:
        self._run_query({**self._json_request(body), "op": "query"}, stream=False)

    def api_query_stream(self, *, query, body) -> None:
        self._run_query({**self._json_request(body), "op": "query"}, stream=True)

    def api_explain(self, *, query, body) -> None:
        self._send_protocol(self.app.handler.handle({**self._json_request(body), "op": "explain"}))

    def api_request(self, *, query, body) -> None:
        request = self._json_request(body)
        if request.get("op") == "query":
            self._run_query(request, stream=False)
        else:
            self._send_protocol(self.app.handler.handle(request))

    def api_tables(self, *, query, body) -> None:
        self._send_protocol(self.app.handler.handle({"op": "tables"}))

    def api_schema(self, name: str, *, query, body) -> None:
        self._send_protocol(self.app.handler.handle({"op": "schema", "table": name}))

    def api_stats(self, name: str, *, query, body) -> None:
        self._send_protocol(self.app.handler.handle({"op": "stats", "table": name}))

    def api_drop(self, name: str, *, query, body) -> None:
        self._send_protocol(self.app.handler.handle({"op": "drop", "table": name}))

    def api_load(self, name: str, *, query: dict[str, list[str]], body: bytes) -> None:
        request: dict[str, Any] = {
            "op": "load",
            "table": name,
            "format": _param(query, "format"),
            "replace": _bool_param(query, "replace") or False,
        }
        options: dict[str, Any] = {}
        header = _bool_param(query, "header")
        if header is not None:
            options["header"] = header
        for key in ("delimiter", "layout"):
            value = _param(query, key)
            if value is not None:
                options[key] = value
        if options:
            request["options"] = options
        try:
            request["data"] = body.decode("utf-8")
        except UnicodeDecodeError:
            raise _HttpError(400, errors.ingest_error("input is not valid UTF-8")) from None
        self._send_protocol(self.app.handler.handle(request), success=201)

    def api_queries(self, *, query, body) -> None:
        self._send_json(200, {"ok": True, "queries": self.app.queries.list()})

    def api_cancel(self, query_id: str, *, query, body) -> None:
        if not self.app.queries.cancel(query_id):
            raise _HttpError(404, errors.not_found(f"no active query with id '{query_id}'", query_id=query_id))
        self._send_json(200, {"ok": True, "cancelled": True})

    # ------------------------------------------------------------ queries

    def _run_query(self, request: dict[str, Any], *, stream: bool) -> None:
        """Registers, admits and executes one query, then reports it."""
        app = self.app
        started = time.monotonic()
        query_id, timeout_ms = _requested_control(request)
        timeout_ms = timeout_ms or app.config.query_timeout_ms
        try:
            active = app.queries.register(query_id)
        except errors.PolyQueryError as e:
            app.query_finished(query_id, e, started, 0)
            headers = [(QUERY_ID_HEADER, query_id)] if query_id is not None else []
            self._send_json(STATUS_OF_CODE[e.code], error_response(request, e), headers)
            return
        headers = [(QUERY_ID_HEADER, active.query_id)]
        control = QueryControl(
            active.cancel_event, active.arrived + timeout_ms / 1000.0 if timeout_ms else None
        )
        try:
            with app.watcher.watch(self.connection, active.cancel_event.set):
                try:
                    app.queries.admit(active, control.deadline)
                except errors.PolyQueryError as e:
                    outcome = _Outcome(error_response(request, e), e)
                else:
                    try:
                        if stream:
                            outcome = self._execute_stream(request, control, active.query_id)
                        else:
                            outcome = self._execute(request, control)
                    finally:
                        app.queries.release(active)
        finally:
            app.queries.unregister(active)
        app.query_finished(active.query_id, outcome.error, started, outcome.rows)
        if outcome.response is not None:
            self._send_protocol(outcome.response, headers=headers)

    def _execute(self, request: dict[str, Any], control: QueryControl) -> _Outcome:
        response = self.app.handler.handle(request, control)
        if response.get("ok"):
            return _Outcome(response, None, response.get("row_count", 0))
        error = response["error"]
        return _Outcome(response, errors.PolyQueryError(error["code"], error["message"]))

    def _execute_stream(self, request: dict[str, Any], control: QueryControl, query_id: str) -> _Outcome:
        """Streams a query result as NDJSON (protocol.md §7.2). Errors before
        the first row batch is available yield a regular error response."""
        try:
            stream = self.app.handler.open_stream(request, control)
            batch = next(stream.batches, None)
        except Exception as exc:  # noqa: BLE001 - reported to the client
            error = error_of(exc)
            return _Outcome(error_response(request, error), error)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header(QUERY_ID_HEADER, query_id)
        self.end_headers()
        writer = ChunkedWriter(self.connection, control)
        rows = 0
        error: errors.PolyQueryError | None = None
        try:
            try:
                writer.line({"type": "header", "query_id": query_id, "columns": stream.columns})
                while batch is not None:
                    for start in range(0, len(batch), STREAM_ROWS_PER_LINE):
                        writer.line({"type": "rows", "rows": batch[start : start + STREAM_ROWS_PER_LINE]})
                    rows += len(batch)
                    batch = next(stream.batches, None)
                writer.line({"type": "end", "row_count": rows})
            except _StreamAborted:
                raise
            except Exception as exc:  # noqa: BLE001 - reported in the stream
                error = error_of(exc)
                writer.line({"type": "error", "error": error.to_json()})
            writer.finish()
        except _StreamAborted as aborted:
            control.cancel_event.set()
            self.close_connection = True
            error = error or aborted.error
        finally:
            stream.batches.close()
        return _Outcome(None, error, rows)


def _param(query: dict[str, list[str]], key: str) -> str | None:
    values = query.get(key)
    return values[-1] if values else None


def _bool_param(query: dict[str, list[str]], key: str) -> bool | None:
    value = _param(query, key)
    if value is None:
        return None
    lowered = value.lower()
    if lowered in ("true", "1", "yes"):
        return True
    if lowered in ("false", "0", "no"):
        return False
    raise _HttpError(400, errors.invalid_request(f"query parameter '{key}' must be true or false"))

