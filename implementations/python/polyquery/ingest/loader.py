"""Entry point for table ingestion: dispatches on the input format."""

from __future__ import annotations

from typing import Any

from ..storage.table import COLUMN, Column, Table, make_table
from .csv_ingest import ingest_csv
from .json_ingest import ingest_json
from .limits import IngestLimits, check_column_names

FORMATS = ("csv", "json", "jsonl")


def load_table(
    name: str,
    fmt: str,
    text: str,
    schema: list[Column] | None,
    options: dict[str, Any],
    limits: IngestLimits,
    *,
    layout: str = COLUMN,
    dictionary: bool | None = None,
) -> Table:
    """Builds an immutable table from input text in the given in-memory
    layout. ``options`` holds the validated CSV options (``header``,
    ``delimiter``); ``dictionary`` forces dictionary encoding of STRING
    columns (None: automatic)."""
    if schema is not None:
        check_column_names([c.name for c in schema])
    if fmt == "csv":
        columns, data, rows = ingest_csv(text, schema, options, limits)
    else:
        columns, data, rows = ingest_json(text, fmt, schema, limits)
    return make_table(name, list(columns), data, rows, layout, dictionary)
