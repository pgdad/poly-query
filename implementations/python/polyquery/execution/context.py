"""Per-query execution context: timeout/cancellation checks and the memory budget."""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field

from .. import errors

# Approximate in-memory cost of one materialized row and of one value in it.
ROW_OVERHEAD_BYTES = 64
VALUE_BYTES = 16


@dataclass
class ExecutionContext:
    deadline: float | None = None  # time.monotonic() deadline
    cancel_event: threading.Event | None = None
    max_memory_bytes: int = 4 * 1024**3
    test_functions: bool = False
    memory_used: int = field(default=0, init=False)

    @classmethod
    def create(
        cls,
        *,
        timeout_ms: int = 0,
        max_memory_mb: int = 4096,
        test_functions: bool = False,
        cancel_event: threading.Event | None = None,
    ) -> ExecutionContext:
        deadline = time.monotonic() + timeout_ms / 1000.0 if timeout_ms else None
        return cls(deadline, cancel_event, max_memory_mb * 1024 * 1024, test_functions)

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
