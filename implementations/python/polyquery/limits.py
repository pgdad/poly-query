"""Statement size limits and deep-recursion support (change request CR-6,
spec/changes/expression-limits.md).

The engine processes expressions recursively (parser, binder, optimizer,
both expression compilers). A long chain of one binary operator such as
``x + 1 + 1 + …`` is a left-deep tree as deep as the chain is long, so the
recursion depth of a statement within the limits below can reach about
``MAX_OPERANDS`` levels. Two measures make that safe:

* every thread that handles requests runs with a large stack
  (:data:`THREAD_STACK_BYTES`) and the interpreter's recursion limit is
  raised accordingly (:func:`configure_interpreter`); CPython 3.14 checks the
  real C stack of each thread and raises ``RecursionError`` before it
  overflows, which the protocol layer reports as ``RESOURCE_LIMIT``;
* the parser rejects statements beyond the limits with ``RESOURCE_LIMIT``
  before any deeper stage sees them (:class:`StatementMeter`).
"""

from __future__ import annotations

import sys
import threading
import time
from typing import Any, Callable

from . import errors

# SQL text of one statement, in UTF-8 bytes (CR-6 minimum: 1 MiB)
MAX_SQL_BYTES = 16 * 1024 * 1024
# expression nesting depth as CR-6 §1 measures it (minimum: 1,000)
MAX_NESTING_DEPTH = 4096
# literals, column references and ``*`` arguments (minimum: 25,000)
MAX_OPERANDS = 200_000

# Stack of the threads that run statements (virtual address space; only the
# pages a deep statement touches are committed). A left-deep chain of
# MAX_OPERANDS operands needs well under a quarter of it.
THREAD_STACK_BYTES = 512 * 1024 * 1024
# Python frames do not use the C stack, so this only bounds the interpreter's
# frame memory; MAX_OPERANDS-deep trees need a few frames per level.
RECURSION_LIMIT = 2_000_000


def configure_interpreter() -> None:
    """Raises the recursion limit and the stack size of new threads."""
    sys.setrecursionlimit(max(sys.getrecursionlimit(), RECURSION_LIMIT))
    threading.stack_size(THREAD_STACK_BYTES)


def run_with_large_stack(fn: Callable[[], Any]) -> Any:
    """Runs ``fn`` in a thread with a THREAD_STACK_BYTES stack and returns
    its result (re-raising its exception). The calling thread waits."""
    configure_interpreter()
    outcome: dict[str, Any] = {}

    def target() -> None:
        try:
            outcome["value"] = fn()
        except BaseException as e:  # noqa: BLE001 - re-raised in the caller
            outcome["error"] = e

    thread = threading.Thread(target=target, name="polyquery-main", daemon=True)
    thread.start()
    while thread.is_alive():
        thread.join(0.5)
    if "error" in outcome:
        raise outcome["error"]
    return outcome.get("value")


def check_text_length(sql: str) -> None:
    """RESOURCE_LIMIT for SQL text longer than MAX_SQL_BYTES."""
    # a str has at most 4 UTF-8 bytes per character: skip encoding short text
    if len(sql) * 4 <= MAX_SQL_BYTES:
        return
    size = len(sql.encode("utf-8", "surrogatepass"))
    if size > MAX_SQL_BYTES:
        raise errors.resource_limit(
            f"SQL text length {size} bytes exceeds {MAX_SQL_BYTES}", measure="text_length"
        )


class StatementMeter:
    """Counts the CR-6 measures of a statement while it is parsed."""

    __slots__ = ("depth", "operands")

    def __init__(self) -> None:
        self.depth = 0
        self.operands = 0

    def enter(self) -> None:
        self.depth += 1
        if self.depth > MAX_NESTING_DEPTH:
            raise errors.resource_limit(
                f"expression nesting depth exceeds {MAX_NESTING_DEPTH}", measure="nesting_depth"
            )

    def leave(self) -> None:
        self.depth -= 1

    def operand(self) -> None:
        self.operands += 1
        if self.operands > MAX_OPERANDS:
            raise errors.resource_limit(
                f"operand count exceeds {MAX_OPERANDS}", measure="operand_count"
            )


Check = Callable[[], None]


def no_check() -> None:
    """The deadline check of work that has no deadline."""


def deadline_check(deadline: float | None, cancel_event: threading.Event | None = None) -> Check:
    """A check that raises TIMEOUT once ``deadline`` (time.monotonic()) has
    passed and CANCELLED once ``cancel_event`` is set; used by the stages
    before execution (lexing, parsing, binding, planning)."""
    if deadline is None and cancel_event is None:
        return no_check
    monotonic = time.monotonic

    def check() -> None:
        if cancel_event is not None and cancel_event.is_set():
            raise errors.cancelled("query was cancelled")
        if deadline is not None and monotonic() > deadline:
            raise errors.timeout_error("query exceeded its timeout")

    return check
