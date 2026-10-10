"""Registry of active queries plus admission control (concurrency.md §2-§4).

At most ``workers`` queries execute at once; up to ``queue_depth`` more wait
in FIFO order. Every active (queued or running) query is registered under
its query id so that it can be listed and cancelled.
"""

from __future__ import annotations

import itertools
import threading
import time
from collections import deque
from typing import Any

from .. import errors

QUEUED = "queued"
RUNNING = "running"

# upper bound on how long a queued query sleeps between checks of its
# deadline (cancellation and freed workers wake it immediately)
_QUEUE_POLL_SECONDS = 0.05


class ActiveQuery:
    def __init__(self, query_id: str):
        self.query_id = query_id
        self.cancel_event = threading.Event()
        self.arrived = time.monotonic()
        self.state = QUEUED

    def elapsed_ms(self) -> int:
        return int((time.monotonic() - self.arrived) * 1000)


class QueryManager:
    def __init__(self, workers: int, queue_depth: int):
        self.workers = max(1, workers)
        self.queue_depth = max(0, queue_depth)
        self._cond = threading.Condition()
        self._active: dict[str, ActiveQuery] = {}
        self._queue: deque[ActiveQuery] = deque()
        self._running = 0
        self._ids = itertools.count(1)
        self._closed = False

    # ------------------------------------------------------------ registry

    def register(self, query_id: str | None) -> ActiveQuery:
        """Registers a new query (assigning an id if none is given)."""
        with self._cond:
            if self._closed:
                raise errors.PolyQueryError(errors.SHUTTING_DOWN, "the server is shutting down")
            if query_id is None:
                query_id = self._new_id()
            elif query_id in self._active:
                raise errors.already_exists(f"query id '{query_id}' is already in use", query_id=query_id)
            query = ActiveQuery(query_id)
            self._active[query_id] = query
            return query

    def _new_id(self) -> str:
        while True:
            candidate = f"q-{next(self._ids)}"
            if candidate not in self._active:
                return candidate

    def unregister(self, query: ActiveQuery) -> None:
        with self._cond:
            if self._active.get(query.query_id) is query:
                del self._active[query.query_id]
            self._cond.notify_all()

    def cancel(self, query_id: str) -> bool:
        """Requests cancellation; False if no such query is active."""
        with self._cond:
            query = self._active.get(query_id)
            if query is None:
                return False
            query.cancel_event.set()
            self._cond.notify_all()
            return True

    def cancel_all(self) -> int:
        with self._cond:
            for query in self._active.values():
                query.cancel_event.set()
            self._cond.notify_all()
            return len(self._active)

    def list(self) -> list[dict[str, Any]]:
        with self._cond:
            queries = sorted(self._active.values(), key=lambda q: q.arrived)
            return [{"query_id": q.query_id, "state": q.state, "elapsed_ms": q.elapsed_ms()} for q in queries]

    def counts(self) -> tuple[int, int]:
        """(running, queued)."""
        with self._cond:
            return self._running, len(self._queue)

    # ------------------------------------------------------------ admission

    def admit(self, query: ActiveQuery, deadline: float | None) -> None:
        """Blocks until the query may execute. Raises OVERLOADED when the
        queue is full, TIMEOUT / CANCELLED while waiting."""
        with self._cond:
            if self._running < self.workers and not self._queue:
                self._start(query)
                return
            if len(self._queue) >= self.queue_depth:
                raise errors.PolyQueryError(
                    errors.OVERLOADED,
                    f"all {self.workers} workers are busy and {len(self._queue)} queries are queued",
                )
            self._queue.append(query)
            try:
                while True:
                    if query.cancel_event.is_set():
                        raise errors.cancelled("query was cancelled while queued")
                    wait = _QUEUE_POLL_SECONDS
                    if deadline is not None:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise errors.timeout_error("query timed out while queued")
                        wait = min(wait, remaining)
                    if self._queue[0] is query and self._running < self.workers:
                        self._queue.popleft()
                        self._start(query)
                        return
                    self._cond.wait(wait)
            except BaseException:
                if query in self._queue:
                    self._queue.remove(query)
                    self._cond.notify_all()  # the next one may now be at the head
                raise

    def _start(self, query: ActiveQuery) -> None:
        self._running += 1
        query.state = RUNNING

    def release(self, query: ActiveQuery) -> None:
        """Frees the worker held by an admitted query."""
        with self._cond:
            self._running -= 1
            self._cond.notify_all()

    # ------------------------------------------------------------ shutdown

    def close(self) -> None:
        """Rejects new queries from now on (SHUTTING_DOWN)."""
        with self._cond:
            self._closed = True

    def wait_idle(self, timeout: float) -> bool:
        """Waits until no query is active; False on timeout."""
        end = time.monotonic() + timeout
        with self._cond:
            while self._active:
                remaining = end - time.monotonic()
                if remaining <= 0:
                    return False
                self._cond.wait(remaining)
            return True
