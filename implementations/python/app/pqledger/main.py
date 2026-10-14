"""The program's entry point: runs one invocation and maps failures to the
exit statuses and messages of pqledger.md §10."""

from __future__ import annotations

import io
import sys
from typing import TextIO

from . import commands, errors
from .cli import parse_args
from .errors import AppError


def main(argv: list[str], stdout: TextIO | None = None, stderr: TextIO | None = None) -> int:
    """Runs one invocation; returns the exit status (§10)."""
    stdout = stdout or sys.stdout
    stderr = stderr or sys.stderr
    try:
        inv = parse_args(argv)
        handler = commands.HANDLERS[inv.command]
        # the output is written only once the command has succeeded (§10)
        buffer = io.StringIO()
        status = handler(inv, buffer)
        stdout.write(buffer.getvalue())
        stdout.flush()
        return errors.OK if status is None else status
    except AppError as e:
        stderr.write(f"pqledger: error: {e.message}\n")
        return e.exit_status
    except MemoryError:
        stderr.write("pqledger: error: out of memory\n")
        return errors.OTHER
    except OSError as e:
        stderr.write(f"pqledger: error: {e.strerror or e}\n")
        return errors.OTHER
    except Exception as e:  # noqa: BLE001 - a bug: still exit 7 with a message
        stderr.write(f"pqledger: error: internal error: {e!r}\n")
        return errors.OTHER
