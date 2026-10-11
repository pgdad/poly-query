"""Persistent worker processes for parallel pipelines.

Forking a worker per partition per query costs ~10 ms per child for every
GB of engine memory (the kernel copies the page tables), and every child
then pays copy-on-write faults for the table pages it touches. For queries
of a few hundred milliseconds that overhead ate most of the parallel
speed-up. A :class:`WorkerPool` therefore forks its workers *once*, after the
tables are loaded, and reuses them for every parallel query:

* a worker inherits the catalog's tables and indexes at fork time. Plans are
  sent to it as pickles in which every ``Table`` / ``Index`` is replaced by a
  reference (``persistent_id``); the worker resolves the reference in its
  registry, so table data is never copied. A plan that references an object
  the workers do not have (a table loaded or replaced after the fork) makes
  the pool fork a fresh set of workers first;
* what a worker computes is described by a picklable :class:`PartitionTask`
  (engine, consumer operator, kind, argument), from which the worker builds
  the same per-partition function as the in-process path, using the
  consumer functions each engine registers (``register_engine``). The worker
  prepares the pipeline's join build sides itself;
* a worker keeps the copied pages of the tables it touched, so later queries
  run without page faults.

The pool serves one query at a time (a concurrent query uses the
fork-per-query path of ``parallel``). Errors raised in a worker are returned
like results; on cancellation, timeout or any failure of the protocol itself
all workers are killed and the next query forks new ones. Workers exit when
the engine process exits (their task pipe reaches EOF).
"""

from __future__ import annotations

import gc
import io
import os
import pickle
import selectors
import signal
import struct
import threading
from dataclasses import dataclass
from typing import Any, Callable, Iterable

from .. import errors
from ..planner import physical as pp
from ..storage.catalog import Table
from ..storage.indexes import Index
from .context import ExecutionContext

_POLL_SECONDS = 0.05
_HEADER = struct.Struct("<Q")


@dataclass(frozen=True, eq=False)
class PartitionTask:
    """Picklable description of the work done per partition of a Gather:
    ``ENGINES[engine]`` builds ``consume(consumer, ctx, arg)`` and applies it
    to the partition's output of the Gather's input."""

    engine: str  # "vec" or "row"
    kind: str  # consumer kind registered by the engine
    consumer: pp.PhysicalNode | None  # the operator consuming the partial results
    arg: Any = None


@dataclass(frozen=True)
class _Engine:
    execute: Callable[[pp.PhysicalNode, ExecutionContext], Any]
    prepare: Callable[[pp.Gather, ExecutionContext], None]
    consumers: dict[str, Callable[[Any, ExecutionContext, Any], Callable[[Any], Any]]]


ENGINES: dict[str, _Engine] = {}


def register_engine(
    name: str,
    execute: Callable[[pp.PhysicalNode, ExecutionContext], Any],
    prepare: Callable[[pp.Gather, ExecutionContext], None],
    consumers: dict[str, Callable[[Any, ExecutionContext, Any], Callable[[Any], Any]]],
) -> None:
    ENGINES[name] = _Engine(execute, prepare, consumers)


def partition_function(gather: pp.Gather, task: PartitionTask, ctx: ExecutionContext) -> Callable[[], Any]:
    """The per-partition function of ``task`` (the pipeline is not prepared)."""
    engine = ENGINES[task.engine]
    consume = engine.consumers[task.kind](task.consumer, ctx, task.arg)
    return lambda: consume(engine.execute(gather.input, ctx))


class _StaleObject(Exception):
    """The plan references a table or index the workers do not have."""


class _RefPickler(pickle.Pickler):
    def __init__(self, file: io.BytesIO, registry: dict[int, object]):
        super().__init__(file, protocol=pickle.HIGHEST_PROTOCOL)
        self.registry = registry

    def persistent_id(self, obj: Any) -> Any:
        if isinstance(obj, (Table, Index)):
            if self.registry.get(id(obj)) is not obj:
                raise _StaleObject
            return id(obj)
        return None


class _RefUnpickler(pickle.Unpickler):
    def __init__(self, file: io.BytesIO, registry: dict[int, object]):
        super().__init__(file)
        self.registry = registry

    def persistent_load(self, pid: Any) -> Any:
        return self.registry[pid]


@dataclass
class _Worker:
    pid: int
    task_fd: int  # parent -> worker
    result_fd: int  # worker -> parent


class WorkerPool:
    """A set of forked worker processes sharing a snapshot of the catalog.
    ``objects`` returns the tables and indexes the workers should hold."""

    def __init__(self, objects: Callable[[], Iterable[object]], max_workers: int | None = None):
        self._objects = objects
        self._max_workers = max_workers or os.cpu_count() or 1
        self._lock = threading.Lock()
        self._workers: list[_Worker] = []
        # objects inherited by the workers, by id(); holding them also keeps
        # their ids from being reused while the workers live
        self._registry: dict[int, object] = {}

    def run(self, gather: pp.Gather, ctx: ExecutionContext, task: PartitionTask) -> list[Any] | None:
        """The results of ``task`` for every partition of ``gather`` in
        partition order, computed by the workers; None if the pool cannot
        run it now (busy with another query, or the plan cannot be sent),
        in which case the caller runs the partitions itself."""
        if ctx.native is not None or ctx.params or not hasattr(os, "fork"):
            return None
        if not self._lock.acquire(blocking=False):
            return None
        try:
            count = gather.partitions
            size = max(1, min(count, self._max_workers))
            blob = self._encode(gather, ctx, task)
            if blob is None or len(self._workers) < size:
                self._restart(max(size, len(self._workers)))
                blob = self._encode(gather, ctx, task)
                if blob is None:
                    return None
            workers = self._workers[:size]
            try:
                for w, worker in enumerate(workers):
                    _write_message(worker.task_fd, pickle.dumps((list(range(w, count, size)), count, blob)))
            except OSError:  # a worker died (e.g. killed from outside)
                self._shutdown()
                return None
            try:
                payloads = self._collect(workers, ctx)
            except BaseException:
                self._shutdown()
                raise
            results: list[Any] = [None] * count
            for w, payload in enumerate(payloads):
                ok, value = pickle.loads(payload)
                if not ok:
                    raise value
                for index, result in zip(range(w, count, size), value):
                    results[index] = result
            return results
        finally:
            self._lock.release()

    def close(self) -> None:
        with self._lock:
            self._shutdown()

    # ------------------------------------------------------------ parent side

    def _encode(self, gather: pp.Gather, ctx: ExecutionContext, task: PartitionTask) -> bytes | None:
        settings = {
            "deadline": ctx.deadline,
            "max_memory_bytes": ctx.max_memory_bytes,
            "test_functions": ctx.test_functions,
            "max_join_rows": ctx.max_join_rows,
            "mode": ctx.mode,
            "threads": ctx.threads,
            "parallel_min_rows": ctx.parallel_min_rows,
        }
        buffer = io.BytesIO()
        try:
            _RefPickler(buffer, self._registry).dump((gather, task, ctx.subplans, settings))
        except _StaleObject:
            return None
        return buffer.getvalue()

    def _restart(self, size: int) -> None:
        """Replaces the workers by ``size`` fresh ones forked now."""
        self._shutdown()
        self._registry = {id(o): o for o in self._objects()}
        parent_fds: list[int] = []
        try:
            for _ in range(size):
                task_read, task_write = os.pipe()
                result_read, result_write = os.pipe()
                pid = os.fork()
                if pid == 0:  # pragma: no cover - runs in the child
                    for fd in (*parent_fds, task_write, result_read):
                        os.close(fd)
                    _serve(task_read, result_write, self._registry)
                os.close(task_read)
                os.close(result_write)
                parent_fds += [task_write, result_read]
                self._workers.append(_Worker(pid, task_write, result_read))
        except BaseException:
            self._shutdown()
            raise

    def _collect(self, workers: list[_Worker], ctx: ExecutionContext) -> list[bytes]:
        """Reads one framed message from every worker, checking for
        cancellation and the deadline while waiting."""
        buffers = {w.result_fd: bytearray() for w in workers}
        selector = selectors.DefaultSelector()
        try:
            for w in workers:
                selector.register(w.result_fd, selectors.EVENT_READ)
            pending = len(workers)
            while pending:
                for key, _ in selector.select(_POLL_SECONDS):
                    chunk = os.read(key.fd, 1 << 20)
                    if not chunk:
                        raise errors.PolyQueryError(errors.INTERNAL_ERROR, "parallel worker exited unexpectedly")
                    buffer = buffers[key.fd]
                    buffer += chunk
                    if len(buffer) >= _HEADER.size and len(buffer) - _HEADER.size >= _HEADER.unpack_from(buffer)[0]:
                        selector.unregister(key.fd)
                        pending -= 1
                ctx.check()
        finally:
            selector.close()
        return [bytes(memoryview(buffers[w.result_fd])[_HEADER.size :]) for w in workers]

    def _shutdown(self) -> None:
        for worker in self._workers:
            for fd in (worker.task_fd, worker.result_fd):
                try:
                    os.close(fd)
                except OSError:
                    pass
            try:
                os.kill(worker.pid, signal.SIGKILL)
                os.waitpid(worker.pid, 0)
            except (ChildProcessError, ProcessLookupError):
                pass
        self._workers = []
        self._registry = {}


# ------------------------------------------------------------ worker side


def _serve(task_fd: int, result_fd: int, registry: dict[int, object]) -> None:  # pragma: no cover - child
    """The worker's loop: one framed task in, one framed result out, until
    the parent closes the task pipe."""
    status = 1
    try:
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        # everything inherited is long-lived (tables): exclude it from
        # collections, which then only see the objects of the current task
        gc.disable()
        gc.freeze()
        while True:
            message = _read_message(task_fd)
            if message is None:
                status = 0
                return
            indexes, count, blob = pickle.loads(message)
            payload = _run_task(blob, registry, indexes, count)
            try:
                data = pickle.dumps(payload, protocol=pickle.HIGHEST_PROTOCOL)
            except Exception as e:
                failure = errors.PolyQueryError(errors.INTERNAL_ERROR, f"parallel worker result not picklable: {e!r}")
                data = pickle.dumps((False, failure))
            del payload
            _write_message(result_fd, data)
            del data
            gc.collect()
    finally:
        os._exit(status)


def _run_task(blob: bytes, registry: dict[int, object], indexes: list[int], count: int) -> tuple[bool, Any]:  # pragma: no cover - child
    try:
        gather, task, subplans, settings = _RefUnpickler(io.BytesIO(blob), registry).load()
        ctx = ExecutionContext(**settings)
        ctx.in_worker = True
        ctx.subplans = subplans
        ENGINES[task.engine].prepare(gather, ctx)
        run = partition_function(gather, task, ctx)
        driver = id(gather.driver)
        results = []
        for index in indexes:
            ctx.partitions[driver] = (index, count)
            results.append(run())
        return True, results
    except errors.PolyQueryError as e:
        return False, e
    except RecursionError:
        return False, errors.resource_limit("expression nesting too deep")
    except MemoryError:
        return False, errors.resource_limit("out of memory in a parallel worker")
    except Exception as e:
        return False, errors.PolyQueryError(errors.INTERNAL_ERROR, f"parallel worker failed: {e!r}")


# ------------------------------------------------------------ framing


def _write_message(fd: int, data: bytes) -> None:
    view = memoryview(_HEADER.pack(len(data)) + data)
    while view:
        view = view[os.write(fd, view) :]


def _read_message(fd: int) -> bytes | None:
    header = _read_exactly(fd, _HEADER.size)
    if header is None:
        return None
    return _read_exactly(fd, _HEADER.unpack(header)[0])


def _read_exactly(fd: int, size: int) -> bytes | None:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = os.read(fd, min(size - len(chunks), 1 << 20))
        if not chunk:
            return None
        chunks += chunk
    return bytes(chunks)
