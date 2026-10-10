"""Ingestion limits and column-name validation (ingestion.md §3)."""

from __future__ import annotations

from dataclasses import dataclass

from .. import errors
from ..names import fold

MAX_FIELD_CHARS = 16 * 1024 * 1024
DEFAULT_MAX_INGEST_BYTES = 4 * 1024**3
DEFAULT_MAX_TABLE_ROWS = 200_000_000


@dataclass(frozen=True)
class IngestLimits:
    max_bytes: int = DEFAULT_MAX_INGEST_BYTES
    max_rows: int = DEFAULT_MAX_TABLE_ROWS

    def check_bytes(self, size: int) -> None:
        if size > self.max_bytes:
            raise errors.resource_limit(
                f"input of {size} bytes exceeds the ingestion limit of {self.max_bytes} bytes"
            )

    def check_rows(self, rows: int) -> None:
        if rows > self.max_rows:
            raise errors.resource_limit(
                f"input of {rows} rows exceeds the table row limit of {self.max_rows}"
            )


def check_column_names(names: list[str]) -> None:
    """Rejects empty and (case-insensitively) duplicate column names."""
    seen: set[str] = set()
    for name in names:
        if name == "":
            raise errors.ingest_error("empty column name")
        key = fold(name)
        if key in seen:
            raise errors.ingest_error(f"duplicate column name '{name}'", column_name=name)
        seen.add(key)
