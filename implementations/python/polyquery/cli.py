"""Command-line interface (protocol.md §2)."""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from typing import Any

from .execution.context import DEFAULT_PARALLEL_MIN_ROWS
from .limits import configure_interpreter, run_with_large_stack
from .protocol.handlers import RequestHandler, capabilities_info, version_info
from .protocol.serialize import dumps
from .protocol.session import run_exec, run_session
from .server.app import ServerConfig, default_workers, run_server
from .service import Engine, EngineConfig

MODES = ("version", "capabilities", "session", "exec", "serve")
LOG_LEVELS = {
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warn": logging.WARNING,
    "error": logging.ERROR,
    "off": logging.CRITICAL + 10,
}


class _UsageParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        self.print_usage(sys.stderr)
        print(f"polyquery: error: {message}", file=sys.stderr)
        sys.exit(2)


def _positive_int(text: str) -> int:
    value = int(text)
    if value < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return value


def build_parser() -> argparse.ArgumentParser:
    ap = _UsageParser(prog="polyquery", description="PolyQuery analytical database engine")
    ap.add_argument("mode", choices=MODES)
    ap.add_argument("--data-dir", default=".")
    ap.add_argument("--enable-test-functions", action="store_true")
    ap.add_argument("--max-query-memory-mb", type=_positive_int, default=4096)
    ap.add_argument("--max-ingest-bytes", type=_positive_int, default=4 * 1024**3)
    ap.add_argument("--max-table-rows", type=_positive_int, default=200_000_000)
    ap.add_argument("--max-join-rows", type=_positive_int, default=100_000_000)
    ap.add_argument("--threads", type=_positive_int)  # default: automatic
    ap.add_argument("--parallel-min-rows", type=_positive_int, default=DEFAULT_PARALLEL_MIN_ROWS)
    ap.add_argument("--log-level", choices=sorted(LOG_LEVELS), default="info")
    ap.add_argument("--native-kernels")
    ap.add_argument("--request", help="exec mode: request file, or - for stdin")
    # serve (Phase 4)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=_positive_int)
    ap.add_argument("--workers", type=_positive_int)
    ap.add_argument("--queue-depth", type=_positive_int, default=64)
    ap.add_argument("--query-timeout-ms", type=_positive_int, default=0)
    ap.add_argument("--shutdown-grace-ms", type=_positive_int, default=10000)
    ap.add_argument("--max-request-bytes", type=_positive_int, default=1024**3)
    return ap


class _JsonLogFormatter(logging.Formatter):
    """One JSON object per line: ts (RFC 3339 UTC), level, msg, plus the
    structured fields passed as ``extra={"fields": {...}}``."""

    LEVEL_NAMES = {"WARNING": "warn", "CRITICAL": "error"}

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "level": self.LEVEL_NAMES.get(record.levelname, record.levelname.lower()),
            "msg": record.getMessage(),
        }
        fields = getattr(record, "fields", None)
        if isinstance(fields, dict):
            for key, value in fields.items():
                entry.setdefault(key, value)
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


def _setup_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(_JsonLogFormatter())
    logger = logging.getLogger("polyquery")
    logger.handlers[:] = [handler]
    logger.setLevel(LOG_LEVELS[level])
    logger.propagate = False


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    _setup_logging(args.log_level)
    configure_interpreter()

    if args.mode == "version":
        print(dumps(version_info()), flush=True)
        return 0
    if args.mode == "capabilities":
        print(dumps(capabilities_info()), flush=True)
        return 0
    data_dir = os.path.abspath(args.data_dir)
    if not os.path.isdir(data_dir):
        print(f"polyquery: data directory does not exist: {args.data_dir}", file=sys.stderr)
        return 2
    config = EngineConfig(
        data_dir=data_dir,
        test_functions=args.enable_test_functions,
        max_query_memory_mb=args.max_query_memory_mb,
        max_ingest_bytes=args.max_ingest_bytes,
        max_table_rows=args.max_table_rows,
        max_join_rows=args.max_join_rows,
        threads=args.threads,
        parallel_min_rows=args.parallel_min_rows,
        log_level=args.log_level,
        native_kernels=args.native_kernels,
    )
    handler = RequestHandler(Engine(config))

    if args.mode == "serve":
        if args.port is None:
            print("polyquery: serve requires --port N", file=sys.stderr)
            return 2
        if args.port > 65535:
            print("polyquery: --port must be between 0 and 65535", file=sys.stderr)
            return 2
        return run_server(
            handler,
            ServerConfig(
                host=args.host,
                port=args.port,
                workers=args.workers or default_workers(),
                queue_depth=args.queue_depth,
                query_timeout_ms=args.query_timeout_ms,
                shutdown_grace_ms=args.shutdown_grace_ms,
                max_request_bytes=args.max_request_bytes,
            ),
        )

    if args.mode == "session":
        try:
            # deep statements need a larger stack than the main thread's
            run_with_large_stack(lambda: run_session(handler, sys.stdin.buffer, sys.stdout.buffer))
        except (BrokenPipeError, KeyboardInterrupt):
            return 0
        return 0

    # exec
    if args.request is None:
        print("polyquery: exec requires --request FILE or --request -", file=sys.stderr)
        return 2
    try:
        if args.request == "-":
            payload = sys.stdin.buffer.read()
        else:
            with open(args.request, "rb") as f:
                payload = f.read()
    except OSError as e:
        print(f"polyquery: cannot read request: {e}", file=sys.stderr)
        return 1
    run_with_large_stack(lambda: run_exec(handler, payload, sys.stdout.buffer))
    return 0
