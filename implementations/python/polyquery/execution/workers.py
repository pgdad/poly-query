"""A persistent pool of forked worker processes for parallel pipelines.

Forking a worker per partition and query (``parallel._run_forked``) costs
a few milliseconds per fork once the catalog holds large tables (the page
tables of the whole heap are copied), which eats most of the parallel
speed-up of a query that takes ~100 ms. The pool forks its workers once
per catalog version instead and keeps them:

* A worker inherits a copy-on-write snapshot of the parent, including
  every table and index of the catalog. It right away freezes the
  inherited objects out of the cyclic GC (``gc.freeze``), so collections
  in the worker never touch (and copy) the inherited heap.
* Per query, the parent pickles the parallel pipeline (the ``Gather``),
  the partition task (a picklable callable: a module-level function or a
  ``functools.partial`` of one), the pipeline preparation function and
  the execution settings. Tables and indexes are not pickled: they are
  sent as *persistent ids* (their ``id()``), which the worker resolves to
  its inherited copy. The parent holds a reference to every object it
  registered, so an id can never be reused while the workers live.
* Each worker prepares the pipeline (builds join hash tables) itself, runs
  its partitions ``w, w + k, …`` and sends back the pickled results.

The pool is invalidated whenever the catalog changes (its workers would
not know the new tables). A plan that references a table the workers do
not have (planned against an older snapshot) restarts the pool. Only one
query uses the pool at a time; concurrent queries fall back to forking.
Cancellation and timeouts kill the workers; the next query starts new
ones.
"""

from __future__ import annotations

import gc
import io
import os
import pickle
import selectors
import signal
import stat
import struct
import threading
from typing import Any, Callable

from .. import errors
from ..planner import physical as pp
from ..storage.indexes import Index
from ..storage.table import Table
from .context import ExecutionContext

_HEADER = struct.Struct("<Q")
_POLL_SECONDS = 0.05
# objects that are shared with the workers by identity instead of being pickled
_SHARED_TYPES = (Table, Index)

Task = Callable[[ExecutionContext], Any]
Prepare = Callable[[pp.Gather, ExecutionContext], None]


def available_cpus() -> int:
    try:
        return len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        return os.cpu_count() or 1


class _Unregistered(Exception):
    pass


class _PlanPickler(pickle.Pickler):
    """Pickles plan fragments, sending registered tables and indexes by id
    and recording the shared objects the workers do not have."""

    def __init__(self, file: io.BytesIO, registry: dict[int, Any]):
        super().__init__(file, protocol=pickle.HIGHEST_PROTOCOL)
        self.registry = registry
        self.missing: list[Any] = []

    def persistent_id(self, obj: Any) -> Any:
        if isinstance(obj, _SHARED_TYPES):
            if self.registry.get(id(obj)) is not obj:
                self.missing.append(obj)
            return id(obj)
        return None


class _PlanUnpickler(pickle.Unpickler):
    def __init__(self, file: io.BytesIO, registry: dict[int, Any]):
        super().__init__(file)
        self.registry = registry

    def persistent_load(self, pid: Any) -> Any:
        obj = self.registry.get(pid)
        if obj is None:
            raise _Unregistered(pid)
        return obj


def write_frame(fd: int, data: bytes) -> None:
    view = memoryview(_HEADER.pack(len(data)) + data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def _read_exact(fd: int, n: int) -> bytes | None:
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        k = os.readv(fd, [view[got:]])
        if k == 0:
            return None
        got += k
    return bytes(buf)


def _read_frame(fd: int) -> bytes | None:
    header = _read_exact(fd, _HEADER.size)
    if header is None:
        return None
    (size,) = _HEADER.unpack(header)
    return _read_exact(fd, size)


def _worker_state(ctx: ExecutionContext, subplans: dict[int, Any]) -> dict[str, Any]:
    """The settings a worker needs to rebuild the query's execution context."""
    return {
        "deadline": ctx.deadline,
        "max_memory_bytes": ctx.max_memory_bytes,
        "test_functions": ctx.test_functions,
        "max_join_rows": ctx.max_join_rows,
        "mode": ctx.mode,
        "threads": ctx.threads,
        "parallel_min_rows": ctx.parallel_min_rows,
        "memory_used": ctx.memory_used,
        "params": dict(ctx.params),
        "subplans": subplans,
    }


def _worker_context(state: dict[str, Any]) -> ExecutionContext:
    ctx = ExecutionContext(
        deadline=state["deadline"],
        max_memory_bytes=state["max_memory_bytes"],
        test_functions=state["test_functions"],
        max_join_rows=state["max_join_rows"],
        mode=state["mode"],
        threads=state["threads"],
        parallel_min_rows=state["parallel_min_rows"],
    )
    ctx.memory_used = state["memory_used"]
    ctx.params.update(state["params"])
    ctx.subplans = state["subplans"]
    ctx.in_worker = True
    return ctx


class _Worker:
    __slots__ = ("pid", "task_fd", "result_fd")

    def __init__(self, pid: int, task_fd: int, result_fd: int):
        self.pid = pid
        self.task_fd = task_fd  # parent -> worker
        self.result_fd = result_fd  # worker -> parent


class WorkerPool:
    """Pre-forked workers sharing the catalog's tables (see module docstring).

    ``version`` returns the catalog version; a pool forked at another
    version is restarted before use. ``objects`` returns the tables and
    indexes to register when the pool starts."""

    def __init__(
        self,
        max_workers: int,
        version: Callable[[], int],
        objects: Callable[[], list[Any]],
    ):
        self.max_workers = max(1, max_workers)
        self._version = version
        self._objects = objects
        self._lock = threading.Lock()
        self._workers: list[_Worker] = []
        self._registry: dict[int, Any] = {}
        self._pool_version: int | None = None
        self._stale = False

    # ------------------------------------------------------------ lifecycle

    def invalidate(self) -> None:
        """Called on catalog changes: the workers' snapshot is outdated.
        Stops them now if the pool is idle, else after the running query."""
        self._stale = True
        if self._lock.acquire(blocking=False):
            try:
                self._stop()
            finally:
                self._lock.release()

    def close(self) -> None:
        with self._lock:
            self._stop()

    def _stop(self) -> None:
        workers, self._workers = self._workers, []
        for worker in workers:
            for fd in (worker.task_fd, worker.result_fd):
                try:
                    os.close(fd)
                except OSError:
                    pass
        for worker in workers:
            try:
                os.kill(worker.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(worker.pid, 0)
            except ChildProcessError:
                pass
        self._registry = {}
        self._pool_version = None
        self._stale = False

    def _start(self, extra: list[Any]) -> None:
        """(Re)starts with an empty pool registering the catalog's objects
        and ``extra``; workers are forked on demand by :meth:`_ensure`."""
        self._stop()
        self._pool_version = self._version()
        registry: dict[int, Any] = {}
        for obj in [*self._objects(), *extra]:
            registry[id(obj)] = obj
        self._registry = registry

    def _ensure(self, count: int) -> None:
        while len(self._workers) < count:
            self._workers.append(self._fork())

    def _fork(self) -> _Worker:
        task_read, task_write = os.pipe()
        result_read, result_write = os.pipe()
        pid = os.fork()
        if pid == 0:  # pragma: no cover - runs in the child
            status = 1
            try:
                close_inherited_streams({task_read, result_write})
                _worker_main(task_read, result_write, self._registry)
                status = 0
            finally:
                os._exit(status)
        os.close(task_read)
        os.close(result_write)
        return _Worker(pid, task_write, result_read)

    # ------------------------------------------------------------ queries

    def run(
        self,
        gather: pp.Gather,
        ctx: ExecutionContext,
        task: Task,
        prepare: Prepare | None,
        count: int | None = None,
        inputs: dict[int, Any] | None = None,
    ) -> list[Any] | None:
        """Runs ``task`` for every partition of ``gather`` (or for ``count``
        task indexes) in the workers and returns the results in partition
        order; None if the pool cannot run it (busy with another query, or
        the task cannot be pickled). ``inputs[i]`` is sent only to the
        worker running task ``i`` (``ctx.task_inputs[i]`` there)."""
        if not self._lock.acquire(blocking=False):
            return None
        try:
            if self._stale or self._pool_version != self._version():
                self._start([])
            payload = self._payload(gather, ctx, task, prepare)
            if payload is None:
                return None
            count = gather.partitions if count is None else count
            k = min(count, self.max_workers)
            self._ensure(k)
            workers = self._workers[:k]
            try:
                for w, worker in enumerate(workers):
                    indexes = list(range(w, count, k))
                    own = {i: inputs[i] for i in indexes if i in inputs} if inputs else {}
                    write_frame(worker.task_fd, pickle.dumps((indexes, own), protocol=pickle.HIGHEST_PROTOCOL))
                    write_frame(worker.task_fd, payload)
                replies = self._collect(workers, ctx)
            except BaseException:
                self._stop()  # workers may be mid-task: never reuse them
                raise
            return _results(replies, count, k)
        finally:
            if self._stale:
                self._stop()
            self._lock.release()

    def _payload(self, gather: pp.Gather, ctx: ExecutionContext, task: Task, prepare: Prepare | None) -> bytes | None:
        message = (gather, task, prepare, _worker_state(ctx, ctx.subplans))
        for attempt in range(2):
            buffer = io.BytesIO()
            pickler = _PlanPickler(buffer, self._registry)
            try:
                pickler.dump(message)
            except (pickle.PicklingError, TypeError, AttributeError, RecursionError):
                return None
            if not pickler.missing:
                return buffer.getvalue()
            if attempt == 0:
                # planned against tables the workers do not have: restart
                self._start(pickler.missing)
        return None

    def _collect(self, workers: list[_Worker], ctx: ExecutionContext) -> list[Any]:
        return read_frames([w.result_fd for w in workers], ctx, pickle.loads)


def read_frames(fds: list[int], ctx: ExecutionContext, decode: Callable[[Any], Any] = bytes) -> list[Any]:
    """Reads one length-prefixed frame from every fd, observing cancellation
    and the deadline while waiting, and returns ``decode(frame)`` for each;
    a frame is decoded as soon as it is complete, while the others are
    still being computed. (Frames, not EOF, delimit a reply: a concurrently
    forked process may hold a copy of a pipe's write end.)"""
    buffers: dict[int, bytearray] = {fd: bytearray() for fd in fds}
    decoded: dict[int, Any] = {}
    sizes: dict[int, int | None] = {fd: None for fd in fds}
    selector = selectors.DefaultSelector()
    try:
        for fd in fds:
            selector.register(fd, selectors.EVENT_READ)
        pending = len(fds)
        while pending:
            for key, _ in selector.select(_POLL_SECONDS):
                fd = key.fd
                buf = buffers[fd]
                size = sizes[fd]
                want = (_HEADER.size if size is None else _HEADER.size + size) - len(buf)
                chunk = os.read(fd, max(want, 1 << 16))
                if not chunk:
                    raise errors.PolyQueryError(errors.INTERNAL_ERROR, "parallel worker exited without a result")
                buf += chunk
                if size is None and len(buf) >= _HEADER.size:
                    size = sizes[fd] = _HEADER.unpack_from(buf)[0]
                if size is not None and len(buf) >= _HEADER.size + size:
                    selector.unregister(fd)
                    pending -= 1
                    decoded[fd] = decode(memoryview(buf)[_HEADER.size :])
                    buffers[fd] = bytearray()
            ctx.check()
    finally:
        selector.close()
    return [decoded[fd] for fd in fds]


def close_inherited_streams(keep: set[int]) -> None:
    """In a forked child: closes the inherited pipes and sockets (other
    workers' pipes, client connections, listening sockets) except ``keep``,
    so that the child never keeps them open for others. Regular files stay
    open (memory-mapped tables own their descriptors)."""
    try:
        fds = [int(name) for name in os.listdir("/proc/self/fd")]
    except OSError:
        return
    for fd in fds:
        if fd < 3 or fd in keep:
            continue
        try:
            mode = os.fstat(fd).st_mode
        except OSError:
            continue
        if stat.S_ISSOCK(mode) or stat.S_ISFIFO(mode):
            os.close(fd)


def _results(replies: list[tuple[bool, Any]], count: int, k: int) -> list[Any]:
    """Partition results in partition order. If partitions failed, raises
    the error of the first failing partition: the one a serial run would
    have reached first."""
    results: list[Any] = [None] * count
    failure: tuple[int, BaseException] | None = None
    for w, (ok, value) in enumerate(replies):
        if ok:
            for index, result in zip(range(w, count, k), value):
                results[index] = result
        elif failure is None or value[0] < failure[0]:
            failure = value
    if failure is not None:
        raise failure[1]
    return results


# ------------------------------------------------------------ worker side


def dumps_result(value: Any) -> bytes:
    """Pickles a result without the memo (``fast`` mode): results are acyclic
    value lists whose objects' identities do not matter, and memoizing every
    object of a large result triples the pickling time. Falls back to
    regular pickling for cyclic objects."""
    buffer = io.BytesIO()
    pickler = pickle.Pickler(buffer, protocol=pickle.HIGHEST_PROTOCOL)
    pickler.fast = True
    try:
        pickler.dump(value)
    except ValueError:
        return pickle.dumps(value, protocol=pickle.HIGHEST_PROTOCOL)
    return buffer.getvalue()


def _worker_main(task_fd: int, result_fd: int, registry: dict[int, Any]) -> None:  # pragma: no cover
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    # the protocol streams belong to the parent
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    os.close(devnull)
    gc.disable()
    gc.freeze()  # inherited objects: never traversed (nor copied) by collections
    while True:
        header = _read_frame(task_fd)
        payload = _read_frame(task_fd) if header is not None else None
        if payload is None:
            return  # the parent closed the pipe (pool stopped or parent gone)
        indexes, inputs = pickle.loads(header)  # type: ignore[arg-type]
        reply = _run_task(payload, indexes, inputs, registry)
        write_frame(result_fd, reply)
        del reply, payload
        gc.collect()


def _run_task(
    payload: bytes, indexes: list[int], inputs: dict[int, Any], registry: dict[int, Any]
) -> bytes:  # pragma: no cover
    from .parallel import in_partition  # local import: parallel uses this module

    first = indexes[0] if indexes else 0
    current = first
    try:
        gather, task, prepare, state = _PlanUnpickler(io.BytesIO(payload), registry).load()
        ctx = _worker_context(state)
        ctx.task_inputs = inputs
        if prepare is not None:
            prepare(gather, ctx)
        results = []
        for index in indexes:
            current = index
            results.append(in_partition(gather, ctx, index, task))
        reply: tuple[bool, Any] = (True, results)
    except errors.PolyQueryError as e:
        reply = (False, (current, e))
    except RecursionError:
        reply = (False, (current, errors.resource_limit("expression nesting too deep")))
    except MemoryError:
        reply = (False, (current, errors.resource_limit("out of memory in a parallel worker")))
    except Exception as e:
        reply = (False, (current, errors.PolyQueryError(errors.INTERNAL_ERROR, f"parallel worker failed: {e!r}")))
    try:
        return dumps_result(reply)
    except Exception as e:
        failure = errors.PolyQueryError(errors.INTERNAL_ERROR, f"parallel worker result not picklable: {e!r}")
        return pickle.dumps((False, (first, failure)))
