"""Structured engine errors (spec/errors)."""

from __future__ import annotations

from typing import Any

PARSE_ERROR = "PARSE_ERROR"
SEMANTIC_ERROR = "SEMANTIC_ERROR"
TYPE_ERROR = "TYPE_ERROR"
NUMERIC_OVERFLOW = "NUMERIC_OVERFLOW"
DIVISION_BY_ZERO = "DIVISION_BY_ZERO"
CONVERSION_ERROR = "CONVERSION_ERROR"
INVALID_ARGUMENT = "INVALID_ARGUMENT"
SUBQUERY_CARDINALITY = "SUBQUERY_CARDINALITY"
INVALID_REQUEST = "INVALID_REQUEST"
INGEST_ERROR = "INGEST_ERROR"
UNSUPPORTED = "UNSUPPORTED"
ACCESS_DENIED = "ACCESS_DENIED"
NOT_FOUND = "NOT_FOUND"
ALREADY_EXISTS = "ALREADY_EXISTS"
CANCELLED = "CANCELLED"
RESOURCE_LIMIT = "RESOURCE_LIMIT"
IO_ERROR = "IO_ERROR"
STORAGE_CORRUPT = "STORAGE_CORRUPT"
STORAGE_VERSION_UNSUPPORTED = "STORAGE_VERSION_UNSUPPORTED"
INTERNAL_ERROR = "INTERNAL_ERROR"
OVERLOADED = "OVERLOADED"
SHUTTING_DOWN = "SHUTTING_DOWN"
TIMEOUT = "TIMEOUT"


class PolyQueryError(Exception):
    """An error reported to clients as {"code", "message", "details"}."""

    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details:
            out["details"] = self.details
        return out

    def __repr__(self) -> str:
        return f"PolyQueryError({self.code!r}, {self.message!r})"


def _factory(code: str):
    def make(message: str, **details: Any) -> PolyQueryError:
        return PolyQueryError(code, message, details or None)

    make.__name__ = code.lower()
    return make


parse_error = _factory(PARSE_ERROR)
semantic_error = _factory(SEMANTIC_ERROR)
type_error = _factory(TYPE_ERROR)
numeric_overflow = _factory(NUMERIC_OVERFLOW)
division_by_zero = _factory(DIVISION_BY_ZERO)
conversion_error = _factory(CONVERSION_ERROR)
invalid_argument = _factory(INVALID_ARGUMENT)
invalid_request = _factory(INVALID_REQUEST)
ingest_error = _factory(INGEST_ERROR)
unsupported = _factory(UNSUPPORTED)
access_denied = _factory(ACCESS_DENIED)
not_found = _factory(NOT_FOUND)
already_exists = _factory(ALREADY_EXISTS)
resource_limit = _factory(RESOURCE_LIMIT)
io_error = _factory(IO_ERROR)
timeout_error = _factory(TIMEOUT)
storage_corrupt = _factory(STORAGE_CORRUPT)
storage_version_unsupported = _factory(STORAGE_VERSION_UNSUPPORTED)
cancelled = _factory(CANCELLED)
