"""CSV ingestion (spec/data-types/ingestion.md §1)."""

from __future__ import annotations

import csv
import io
from typing import Any

from .. import errors
from ..names import same_name
from ..storage.catalog import Column
from ..datatypes import DataType, TypeKind
from .convert import TRIM_CHARS, InvalidText, converter_for, infer_text_type
from .limits import MAX_FIELD_CHARS, IngestLimits, check_column_names

csv.field_size_limit(MAX_FIELD_CHARS + 1)


def _read_records(text: str, delimiter: str) -> list[list[str | None]]:
    """Splits CSV text into records. Unquoted empty fields become None, quoted
    empty fields the empty string. Completely empty lines are skipped."""
    if text.startswith("﻿"):
        text = text[1:]
    reader = csv.reader(
        io.StringIO(text, newline=""),
        delimiter=delimiter,
        quotechar='"',
        doublequote=True,
        strict=True,
        quoting=csv.QUOTE_NOTNULL,
    )
    records: list[list[str | None]] = []
    try:
        for record in reader:
            if record:
                records.append(record)
    except csv.Error as e:
        raise errors.ingest_error(
            f"malformed CSV near record {len(records) + 1}: {e}", record=len(records) + 1
        ) from None
    return records


def _check_field_lengths(text: str, records: list[list[str | None]]) -> None:
    if len(text) <= MAX_FIELD_CHARS:
        return
    for n, record in enumerate(records, 1):
        for field in record:
            if field is not None and len(field) > MAX_FIELD_CHARS:
                raise errors.ingest_error(f"field longer than 16 MiB in record {n}", record=n)


def _header_names(record: list[str | None]) -> list[str]:
    return ["" if f is None else f for f in record]


def _to_columns(records: list[list[str | None]], width: int, first_record: int) -> list[tuple]:
    for n, record in enumerate(records):
        if len(record) != width:
            rec_no = n + first_record
            raise errors.ingest_error(
                f"record {rec_no} has {len(record)} fields, expected {width}", record=rec_no
            )
    if not records:
        return [() for _ in range(width)]
    return list(zip(*records))


def _distinct_texts(raw: tuple) -> dict[str, str]:
    """Maps each distinct non-empty raw field (in order of first appearance)
    to its trimmed text."""
    return {f: f.strip(TRIM_CHARS) for f in dict.fromkeys(raw) if f}


def _materialize(raw: tuple, trimmed: dict[str, str], converted: dict[str, Any]) -> list[Any]:
    """Builds the column from per-distinct-text conversions. Unquoted empty,
    quoted empty and blank fields become NULL."""
    lookup = {f: converted.get(t) for f, t in trimmed.items()}
    return list(map(lookup.get, raw))


def _convert_column(raw: tuple, dtype: DataType, name: str, first_record: int) -> list[Any]:
    """Converts raw field texts to values of ``dtype`` (raises CONVERSION_ERROR)."""
    if dtype.kind is TypeKind.STRING:
        return list(raw)
    trimmed = _distinct_texts(raw)
    convert = converter_for(dtype)
    converted: dict[str, Any] = {}
    for field, text in trimmed.items():
        if not text or text in converted:
            continue
        try:
            converted[text] = convert(text)
        except InvalidText:
            rec_no = raw.index(field) + first_record
            raise errors.conversion_error(
                f"cannot convert '{text[:100]}' to {dtype.name} (record {rec_no}, column '{name}')",
                record=rec_no,
                column_name=name,
            ) from None
    return _materialize(raw, trimmed, converted)


def _infer_column(raw: tuple) -> tuple[DataType, list[Any]]:
    trimmed = _distinct_texts(raw)
    dtype, converted = infer_text_type({t for t in trimmed.values() if t})
    if converted is None:
        return dtype, list(raw)
    return dtype, _materialize(raw, trimmed, converted)


def ingest_csv(
    text: str,
    schema: list[Column] | None,
    options: dict[str, Any],
    limits: IngestLimits,
) -> tuple[list[Column], list[list[Any]], int]:
    """Parses CSV text into (columns, column data, row count)."""
    delimiter = options.get("delimiter", ",")
    header = options.get("header", True)
    records = _read_records(text, delimiter)
    _check_field_lengths(text, records)

    if header:
        if not records:
            raise errors.ingest_error("CSV input has no header record")
        names = _header_names(records[0])
        body = records[1:]
        first_record = 2
        check_column_names(names)
        if schema is not None:
            if len(schema) != len(names) or any(
                not same_name(c.name, n) for c, n in zip(schema, names)
            ):
                raise errors.ingest_error("CSV header does not match the explicit schema")
    else:
        assert schema is not None
        names = [c.name for c in schema]
        body = records
        first_record = 1

    limits.check_rows(len(body))
    raw_columns = _to_columns(body, len(names), first_record)

    if schema is not None:
        columns = schema
        data = [
            _convert_column(raw, col.type, col.name, first_record)
            for raw, col in zip(raw_columns, columns)
        ]
    else:
        columns, data = [], []
        for name, raw in zip(names, raw_columns):
            dtype, column_values = _infer_column(raw)
            columns.append(Column(name, dtype))
            data.append(column_values)
    return columns, data, len(body)
