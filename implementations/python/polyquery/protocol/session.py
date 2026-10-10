"""JSON-lines session loop and exec mode (protocol.md §2-§3)."""

from __future__ import annotations

import json
import logging
from typing import Any, BinaryIO, Iterable

from .. import errors
from .handlers import RequestHandler
from .serialize import dumps

log = logging.getLogger("polyquery")


def _encode(response: dict[str, Any]) -> bytes:
    try:
        text = dumps(response)
    except (ValueError, TypeError):
        log.exception("could not serialize response")
        text = dumps(
            {
                "id": response.get("id") if _json_safe(response.get("id")) else None,
                "ok": False,
                "error": {"code": errors.INTERNAL_ERROR, "message": "response serialization failed"},
            }
        )
    return text.encode("utf-8") + b"\n"


def _json_safe(value: Any) -> bool:
    try:
        dumps(value)
        return True
    except (ValueError, TypeError):
        return False


def _invalid(message: str) -> dict[str, Any]:
    return {"id": None, "ok": False, "error": {"code": errors.INVALID_REQUEST, "message": message}}


def _reject_constant(name: str) -> Any:
    raise ValueError(f"{name} is not valid JSON")


def decode_request(text: str) -> Any:
    """Strict RFC 8259 decoding (NaN/Infinity are rejected)."""
    return json.loads(text, parse_constant=_reject_constant)


def handle_request(handler: RequestHandler, request: Any) -> dict[str, Any]:
    if not isinstance(request, dict):
        return _invalid("request must be a JSON object")
    if not _json_safe(request.get("id")):
        # e.g. a number beyond the FLOAT64 range: it could not be echoed, so the
        # request is rejected before it can have any effect
        return _invalid("request id cannot be echoed")
    return handler.handle(request)


def handle_line(handler: RequestHandler, line: bytes) -> dict[str, Any] | None:
    """Decodes and handles one request line; returns None for blank lines."""
    if not line.strip():
        return None
    try:
        request = decode_request(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        return _invalid("request is not valid JSON")
    return handle_request(handler, request)


def run_session(handler: RequestHandler, stdin: BinaryIO, stdout: BinaryIO) -> None:
    for line in stdin:
        response = handle_line(handler, line)
        if response is None:
            continue
        stdout.write(_encode(response))
        stdout.flush()


def run_exec(handler: RequestHandler, payload: bytes, stdout: BinaryIO) -> None:
    """Executes one request or a JSON array of requests in order."""
    try:
        doc = decode_request(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        stdout.write(_encode(_invalid("request is not valid JSON")))
        stdout.flush()
        return
    requests: Iterable[Any] = doc if isinstance(doc, list) else [doc]
    for request in requests:
        stdout.write(_encode(handle_request(handler, request)))
        stdout.flush()
