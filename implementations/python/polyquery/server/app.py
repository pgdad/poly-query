"""The `serve` mode: server lifecycle, signal handling and graceful shutdown
(concurrency.md §5)."""

from __future__ import annotations

import logging
import os
import signal
import sys
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field

from .. import errors
from ..limits import configure_interpreter
from ..protocol.handlers import RequestHandler
from ..protocol.serialize import dumps
from .http import PolyQueryHTTPServer
from .metrics import Metrics
from .queries import QueryManager
from .watcher import DisconnectWatcher

log = logging.getLogger("polyquery")

# after the grace period, how long cancelled queries get to deliver their
# CANCELLED responses before the process exits
_CANCEL_DRAIN_SECONDS = 2.0


def default_workers() -> int:
    return os.process_cpu_count() or os.cpu_count() or 1


@dataclass
class ServerConfig:
    host: str = "127.0.0.1"
    port: int = 0
    workers: int = field(default_factory=default_workers)
    queue_depth: int = 64
    query_timeout_ms: int = 0
    shutdown_grace_ms: int = 10_000
    max_request_bytes: int = 1024**3


class Server:
    """An HTTP server around one engine: owns the query manager, metrics
    and the listening socket."""

    def __init__(self, handler: RequestHandler, config: ServerConfig):
        self.handler = handler
        self.config = config
        self.metrics = Metrics()
        self.queries = QueryManager(config.workers, config.queue_depth)
        self.watcher = DisconnectWatcher()
        self.shutting_down = threading.Event()
        self._busy = 0
        self._busy_cond = threading.Condition()
        self.httpd = PolyQueryHTTPServer((config.host, config.port), self)
        self._thread: threading.Thread | None = None

    @property
    def port(self) -> int:
        return self.httpd.server_port

    def start(self) -> None:
        self._thread = threading.Thread(
            target=self.httpd.serve_forever, kwargs={"poll_interval": 0.1}, name="http-accept", daemon=True
        )
        self._thread.start()

    @contextmanager
    def busy(self) -> Iterator[None]:
        """Marks an HTTP request as being processed."""
        with self._busy_cond:
            self._busy += 1
        try:
            yield
        finally:
            with self._busy_cond:
                self._busy -= 1
                self._busy_cond.notify_all()

    def query_finished(
        self, query_id: str | None, error: errors.PolyQueryError | None, started: float, rows: int
    ) -> None:
        seconds = time.monotonic() - started
        self.metrics.query_finished(error.code if error else None, seconds)
        fields = {
            "query_id": query_id,
            "status": "ok" if error is None else "error",
            "duration_ms": round(seconds * 1000, 3),
            "rows": rows,
        }
        if error is not None:
            fields["error_code"] = error.code
        log.info("query finished", extra={"fields": fields})

    def render_metrics(self) -> str:
        running, queued = self.queries.counts()
        tables = len(self.handler.engine.catalog.tables())
        return self.metrics.render(in_flight=running, queued=queued, tables=tables)

    def shutdown(self) -> None:
        """Graceful shutdown: stop accepting connections, let active queries
        finish within the grace period, then cancel the rest."""
        log.info("shutdown started", extra={"fields": {"grace_ms": self.config.shutdown_grace_ms}})
        self.shutting_down.set()
        self.queries.close()
        self.httpd.shutdown()
        self.httpd.server_close()
        if not self.queries.wait_idle(self.config.shutdown_grace_ms / 1000.0):
            count = self.queries.cancel_all()
            log.warning("grace period expired; cancelling queries", extra={"fields": {"queries": count}})
            self.queries.wait_idle(_CANCEL_DRAIN_SECONDS)
        self._wait_not_busy(_CANCEL_DRAIN_SECONDS)
        log.info("shutdown complete")

    def _wait_not_busy(self, timeout: float) -> None:
        end = time.monotonic() + timeout
        with self._busy_cond:
            while self._busy:
                remaining = end - time.monotonic()
                if remaining <= 0:
                    return
                self._busy_cond.wait(remaining)


def run_server(handler: RequestHandler, config: ServerConfig) -> int:
    """Runs the server until SIGTERM / SIGINT; returns the exit status."""
    stop = threading.Event()

    def on_signal(signum: int, frame: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    # request threads run deep statements (polyquery.limits)
    configure_interpreter()
    try:
        server = Server(handler, config)
    except OSError as e:
        log.error("cannot listen", extra={"fields": {"host": config.host, "port": config.port, "error": str(e)}})
        return 1
    server.start()
    sys.stdout.write(dumps({"event": "listening", "host": config.host, "port": server.port}) + "\n")
    sys.stdout.flush()
    log.info(
        "listening",
        extra={
            "fields": {
                "host": config.host,
                "port": server.port,
                "workers": server.queries.workers,
                "queue_depth": server.queries.queue_depth,
            }
        },
    )
    while not stop.wait(0.5):
        pass
    server.shutdown()
    return 0
