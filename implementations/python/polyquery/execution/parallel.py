"""Partitioned execution of parallel pipelines (``Gather`` plan nodes).

CPython's GIL serializes threads, so threads cannot speed up CPU-bound
operators. Large partitioned pipelines therefore run in *forked worker
processes*: a child inherits a copy-on-write snapshot of the (immutable)
tables, the compiled plan and the already prepared join build sides, runs
its partition's task and sends the (small) partial result back through a
pipe as a pickle. Small inputs, where forking would cost more than it saves,
run their partitions one after the other in the calling thread; the
partial/merge logic is the same either way, so the result does not depend
on how the partitions were executed.

The parent waits for the workers while observing the query's cancellation
and deadline; on error, cancellation or timeout all workers are killed.
"""

from __future__ import annotations

import os
import pickle
import signal
import warnings
from functools import partial
from typing import Any, Callable, Iterator

from .. import errors
from ..planner import physical as pp
from . import native_ops
from .context import ExecutionContext
from .workers import Prepare, Task, read_frames, write_frame

# forking a process that also runs threads (HTTP server) is safe here: the
# child only computes and then calls os._exit
warnings.filterwarnings("ignore", message=r".*fork\(\).*", category=DeprecationWarning)



def use_processes(gather: pp.Gather, ctx: ExecutionContext) -> bool:
    if ctx.in_worker or not hasattr(os, "fork"):
        return False
    return native_ops.python_rows(gather, ctx) >= ctx.parallel_min_rows


def run_partitions(gather: pp.Gather, ctx: ExecutionContext, task: Task, prepare: Prepare | None = None) -> list[Any]:
    """Runs ``task(ctx)`` once per partition of ``gather`` (each run sees its
    partition of the driver scan) and returns the results in partition
    order. ``prepare(gather, ctx)`` builds what the partitions share (join
    build sides) once, before they run."""
    count = gather.partitions
    if use_processes(gather, ctx):
        if ctx.pool is not None and ctx.native is None:
            results = ctx.pool.run(gather, ctx, task, prepare)
            if results is not None:
                return results
        if prepare is not None:
            prepare(gather, ctx)  # before forking: the workers inherit it
        return _run_forked(gather, ctx, task)
    if prepare is not None:
        prepare(gather, ctx)
    return [in_partition(gather, ctx, index, task) for index in range(count)]


def iterate_partitions(
    gather: pp.Gather, ctx: ExecutionContext, produce: Callable[[ExecutionContext], Iterator[Any]], prepare: Prepare
) -> Iterator[Any]:
    """Streams the outputs of ``produce(ctx)`` for every partition in
    partition order. In-process partitions are consumed lazily (a LIMIT
    above can stop early); worker processes collect their partition's
    output completely."""
    if use_processes(gather, ctx):
        for items in run_partitions(gather, ctx, partial(_listed, produce), prepare):
            yield from items
        return
    prepare(gather, ctx)
    driver = id(gather.driver)
    for index in range(gather.partitions):
        ctx.partitions[driver] = (index, gather.partitions)
        try:
            items = produce(ctx)
            while True:
                ctx.partitions[driver] = (index, gather.partitions)
                try:
                    item = next(items)
                except StopIteration:
                    break
                yield item
        finally:
            ctx.partitions.pop(driver, None)


def _listed(produce: Callable[[ExecutionContext], Iterator[Any]], ctx: ExecutionContext) -> list[Any]:
    return list(produce(ctx))


def in_partition(gather: pp.Gather, ctx: ExecutionContext, index: int, task: Task) -> Any:
    """Runs ``task`` with the driver scan of ``gather`` reading partition ``index``."""
    driver = id(gather.driver)
    ctx.partitions[driver] = (index, gather.partitions)
    try:
        return task(ctx)
    finally:
        ctx.partitions.pop(driver, None)


# ------------------------------------------------------------ worker processes


def _run_forked(gather: pp.Gather, ctx: ExecutionContext, task: Task) -> list[Any]:
    """Forks at most one worker per CPU; worker ``w`` runs partitions
    ``w, w + workers, …`` and returns their results in that order."""
    count = gather.partitions
    workers = max(1, min(count, os.cpu_count() or 1))
    children: list[tuple[int, int]] = []  # (pid, read fd)
    try:
        for w in range(workers):
            read_fd, write_fd = os.pipe()
            pid = os.fork()
            if pid == 0:  # pragma: no cover - runs in the child
                os.close(read_fd)
                _worker(gather, ctx, range(w, count, workers), task, write_fd)
            os.close(write_fd)
            children.append((pid, read_fd))
        replies = read_frames([fd for _, fd in children], ctx, pickle.loads)
    finally:
        _reap(children)
    results: list[Any] = [None] * count
    for w, (ok, value) in enumerate(replies):
        if not ok:
            raise value
        for index, result in zip(range(w, count, workers), value):
            results[index] = result
    return results


def _worker(
    gather: pp.Gather, ctx: ExecutionContext, indexes: range, task: Task, fd: int
) -> None:  # pragma: no cover - runs in the child
    status = 1
    try:
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        ctx.in_worker = True
        ctx.cancel_event = None  # the parent observes cancellation and kills us
        try:
            payload: tuple[bool, Any] = (True, [in_partition(gather, ctx, i, task) for i in indexes])
        except errors.PolyQueryError as e:
            payload = (False, e)
        except RecursionError:
            payload = (False, errors.resource_limit("expression nesting too deep"))
        except MemoryError:
            payload = (False, errors.resource_limit("out of memory in a parallel worker"))
        except Exception as e:
            payload = (False, errors.PolyQueryError(errors.INTERNAL_ERROR, f"parallel worker failed: {e!r}"))
        try:
            data = pickle.dumps(payload, protocol=pickle.HIGHEST_PROTOCOL)
        except Exception as e:
            failure = errors.PolyQueryError(errors.INTERNAL_ERROR, f"parallel worker result not picklable: {e!r}")
            data = pickle.dumps((False, failure))
        write_frame(fd, data)
        status = 0
    finally:
        os._exit(status)


def _reap(children: list[tuple[int, int]]) -> None:
    for pid, fd in children:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done == 0:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
        except (ChildProcessError, ProcessLookupError):
            pass
