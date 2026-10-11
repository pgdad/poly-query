"""Per-query execution context: timeout/cancellation checks and the memory budget."""

from __future__ import annotations

import contextlib
import gc
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any, Callable, TypeVar

from .. import errors
from ..native import NativeKernels

T = TypeVar("T")

# Approximate in-memory cost of one materialized row and of one value in it.
ROW_OVERHEAD_BYTES = 64
VALUE_BYTES = 16

ROW = "row"
VECTORIZED = "vectorized"
# parallel pipelines whose driving scan has fewer rows run their partitions
# one after the other in the calling thread instead of in worker processes
DEFAULT_PARALLEL_MIN_ROWS = 200_000


@dataclass
class ExecutionContext:
    deadline: float | None = None  # time.monotonic() deadline
    cancel_event: threading.Event | None = None
    max_memory_bytes: int = 4 * 1024**3
    test_functions: bool = False
    max_join_rows: int = 100_000_000
    mode: str = VECTORIZED  # ROW (Volcano iterators) or VECTORIZED (column batches)
    threads: int = 1
    parallel_min_rows: int = DEFAULT_PARALLEL_MIN_ROWS
    # the native kernel library when the query runs with ``native: true``
    # and it is loaded (else None: the engine's own code paths)
    native: NativeKernels | None = None
    memory_used: int = field(default=0, init=False)
    # partition (index, count) of each partitioned driver scan of a parallel
    # pipeline, by id() of the scan node; ``in_worker`` is set in worker
    # processes (which never fork again)
    partitions: dict[int, tuple[int, int]] = field(default_factory=dict, init=False)
    in_worker: bool = field(default=False, init=False)
    # physical plans of subqueries (by Subquery.id) and the current values of
    # correlation parameters (by column key)
    subplans: dict[int, Any] = field(default_factory=dict, init=False)
    params: dict[tuple[int, int], Any] = field(default_factory=dict, init=False)
    # statement-lifetime caches: compiled operator closures (subplans of
    # correlated subqueries run many times) and LookupScan hash tables
    compiled: dict[tuple[int, str], Any] = field(default_factory=dict, init=False)
    lookup_tables: dict[tuple, dict[Any, list[tuple]]] = field(default_factory=dict, init=False)
    # join build sides prepared once for all partitions of a parallel pipeline
    prepared: dict[tuple[int, str], Any] = field(default_factory=dict, init=False)

    def cached(self, owner: object, tag: str, factory: Callable[[], Any]) -> Any:
        """Returns the value cached for ``(owner, tag)``, creating it on first use."""
        key = (id(owner), tag)
        value = self.compiled.get(key)
        if value is None:
            value = self.compiled[key] = factory()
        return value

    def shared(self, owner: object, tag: str, factory: Callable[[], Any]) -> Any:
        """The value prepared for ``(owner, tag)`` by :meth:`prepare`, else a
        fresh ``factory()`` (operator state that depends on correlation
        parameters must not be cached across executions)."""
        value = self.prepared.get((id(owner), tag))
        return factory() if value is None else value

    def prepare(self, owner: object, tag: str, factory: Callable[[], Any]) -> None:
        key = (id(owner), tag)
        if key not in self.prepared:
            self.prepared[key] = factory()

    @classmethod
    def create(
        cls,
        *,
        timeout_ms: int = 0,
        deadline: float | None = None,
        max_memory_mb: int = 4096,
        test_functions: bool = False,
        cancel_event: threading.Event | None = None,
        max_join_rows: int = 100_000_000,
        mode: str = VECTORIZED,
        threads: int = 1,
        parallel_min_rows: int = DEFAULT_PARALLEL_MIN_ROWS,
        native: NativeKernels | None = None,
    ) -> ExecutionContext:
        """``deadline`` (a time.monotonic() value) takes precedence over
        ``timeout_ms``, which counts from now."""
        if deadline is None and timeout_ms:
            deadline = time.monotonic() + timeout_ms / 1000.0
        return cls(
            deadline,
            cancel_event,
            max_memory_mb * 1024 * 1024,
            test_functions,
            max_join_rows,
            mode,
            threads,
            parallel_min_rows,
            native,
        )

    def check(self) -> None:
        """Raises TIMEOUT / CANCELLED when the query must stop."""
        if self.cancel_event is not None and self.cancel_event.is_set():
            raise errors.cancelled("query was cancelled")
        if self.deadline is not None and time.monotonic() > self.deadline:
            raise errors.timeout_error("query exceeded its timeout")

    def sleep(self, seconds: float) -> None:
        """Sleeps cooperatively, observing timeout and cancellation within ~10 ms."""
        end = time.monotonic() + seconds
        while True:
            self.check()
            remaining = end - time.monotonic()
            if remaining <= 0:
                return
            step = min(remaining, 0.01)
            if self.deadline is not None:
                step = min(step, max(self.deadline - time.monotonic(), 0.0) + 0.001)
            time.sleep(step)

    def reserve_rows(self, rows: int, width: int) -> None:
        """Accounts for materialized rows against the query memory budget."""
        self.memory_used += rows * (ROW_OVERHEAD_BYTES + width * VALUE_BYTES)
        if self.memory_used > self.max_memory_bytes:
            raise errors.resource_limit("query exceeded its memory budget")


# ------------------------------------------------------------ garbage collection

_gc_lock = threading.Lock()
_gc_pauses = 0
_gc_was_enabled = False


@contextlib.contextmanager
def gc_paused() -> Iterator[None]:
    """Suspends CPython's cyclic garbage collector while engine work runs.

    Query operators allocate millions of short-lived, acyclic objects (row
    tuples, lists, numbers) that reference counting frees immediately, but
    every allocation burst also triggers collections that traverse all live
    objects — including the millions held by loaded tables — which made
    large sorts and loads several times slower. Pauses nest across
    concurrent queries (threads); the collector runs again when the last one
    ends."""
    global _gc_pauses, _gc_was_enabled
    with _gc_lock:
        if _gc_pauses == 0:
            _gc_was_enabled = gc.isenabled()
            gc.disable()
        _gc_pauses += 1
    try:
        yield
    finally:
        with _gc_lock:
            _gc_pauses -= 1
            if _gc_pauses == 0 and _gc_was_enabled:
                gc.enable()


def gc_paused_iter(items: Iterator[T]) -> Iterator[T]:
    """Pauses the collector while each item of ``items`` is produced."""
    while True:
        with gc_paused():
            try:
                item = next(items)
            except StopIteration:
                return
        yield item
