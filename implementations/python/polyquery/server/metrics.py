"""Server metrics in the Prometheus text exposition format 0.0.4 (protocol.md §7.3)."""

from __future__ import annotations

import threading
import time

from .. import errors

CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"


class Metrics:
    """Thread-safe counters of finished queries. Gauges describing the current
    state (running / queued queries, tables) are supplied at render time."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._started = time.monotonic()
        self._queries = {"ok": 0, "error": 0}
        self._rejected = 0
        self._cancelled = 0
        self._timeouts = 0
        self._duration_sum = 0.0
        self._duration_count = 0
        self._http_requests: dict[int, int] = {}

    def query_finished(self, error_code: str | None, seconds: float) -> None:
        """Records a finished query; ``error_code`` is None on success."""
        with self._lock:
            self._queries["ok" if error_code is None else "error"] += 1
            if error_code == errors.OVERLOADED:
                self._rejected += 1
            elif error_code == errors.CANCELLED:
                self._cancelled += 1
            elif error_code == errors.TIMEOUT:
                self._timeouts += 1
            self._duration_sum += seconds
            self._duration_count += 1

    def http_request(self, status: int) -> None:
        with self._lock:
            self._http_requests[status] = self._http_requests.get(status, 0) + 1

    def uptime(self) -> float:
        return time.monotonic() - self._started

    def render(self, *, in_flight: int, queued: int, tables: int) -> str:
        with self._lock:
            families = [
                ("polyquery_queries_total", "counter", "Finished queries by outcome.",
                 [(f'{{status="{s}"}}', n) for s, n in self._queries.items()]),
                ("polyquery_queries_in_flight", "gauge", "Queries currently executing.", [("", in_flight)]),
                ("polyquery_queries_queued", "gauge", "Queries waiting for a worker.", [("", queued)]),
                ("polyquery_queries_rejected_total", "counter", "Queries rejected with OVERLOADED.",
                 [("", self._rejected)]),
                ("polyquery_queries_cancelled_total", "counter", "Queries that ended CANCELLED.",
                 [("", self._cancelled)]),
                ("polyquery_queries_timeout_total", "counter", "Queries that ended with TIMEOUT.",
                 [("", self._timeouts)]),
                ("polyquery_query_duration_seconds", "summary", "Query duration including queueing.",
                 [("_sum", self._duration_sum), ("_count", self._duration_count)]),
                ("polyquery_tables", "gauge", "Tables in the catalog.", [("", tables)]),
                ("polyquery_uptime_seconds", "gauge", "Seconds since the server started.", [("", self.uptime())]),
                ("polyquery_http_requests_total", "counter", "HTTP responses by status code.",
                 [(f'{{code="{c}"}}', n) for c, n in sorted(self._http_requests.items())]),
            ]
        lines = []
        for name, kind, help_text, samples in families:
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} {kind}")
            for suffix, value in samples:
                lines.append(f"{name}{suffix} {_format(value)}")
        return "\n".join(lines) + "\n"


def _format(value: float) -> str:
    if isinstance(value, int):
        return str(value)
    return repr(float(value))
