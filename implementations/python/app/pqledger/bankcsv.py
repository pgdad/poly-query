"""Reading bank-statement CSV exports (pqledger.md §6.2): CSV records with
their physical line numbers, and the conversion of dates and amounts."""

from __future__ import annotations

import csv
import datetime as dt
import re
from collections.abc import Callable, Iterator
from dataclasses import dataclass

from .config import ColumnRef, ImportSettings
from .errors import ImportDataError
from .merchant import normalize
from .names import ascii_lower

BLANKS = " \t"
MAX_INTEGER_DIGITS = 16
_AMOUNT = re.compile(r"([0-9]+)(?:\.([0-9]{1,2}))?")

_DATE_PATTERNS = {
    "YYYY-MM-DD": (re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})"), "ymd"),
    "YYYYMMDD": (re.compile(r"([0-9]{4})([0-9]{2})([0-9]{2})"), "ymd"),
    "MM/DD/YYYY": (re.compile(r"([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})"), "mdy"),
    "DD/MM/YYYY": (re.compile(r"([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})"), "dmy"),
    "DD.MM.YYYY": (re.compile(r"([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})"), "dmy"),
}


@dataclass(frozen=True, slots=True)
class Record:
    """A converted statement record."""

    line: int  # 1-based physical line on which the record starts
    date: dt.date
    description: str
    merchant: str
    cents: int  # the amount in cents


class RecordError(ValueError):
    """A field that cannot be converted."""


# ------------------------------------------------------------ conversions


def date_parser(date_format: str) -> Callable[[str], dt.date]:
    pattern, order = _DATE_PATTERNS[date_format]
    cache: dict[str, dt.date] = {}

    def parse(field: str) -> dt.date:
        text = field.strip(BLANKS)
        value = cache.get(text)
        if value is not None:
            return value
        m = pattern.fullmatch(text)
        if m is None:
            raise RecordError(f"date '{text}' does not match {date_format}")
        a, b, c = (int(g) for g in m.groups())
        y, mo, d = (a, b, c) if order == "ymd" else (c, a, b) if order == "mdy" else (c, b, a)
        try:
            value = dt.date(y, mo, d)
        except ValueError:
            raise RecordError(f"'{text}' is not a valid date") from None
        cache[text] = value
        return value

    return parse


def amount_parser(settings: ImportSettings) -> Callable[[str], int]:
    """Converts an amount field to cents (§6.2 step 3, before invert_sign)."""
    symbol = settings.currency_symbol
    thousands = settings.thousands_separator
    decimal = settings.decimal_separator

    def parse(field: str) -> int:
        text = field.strip(BLANKS)
        negative = False
        if len(text) >= 2 and text.startswith("(") and text.endswith(")"):
            negative, text = True, text[1:-1]
        elif text.startswith("-"):
            negative, text = True, text[1:]
        elif text.startswith("+"):
            text = text[1:]
        if symbol:
            if text.startswith(symbol):
                text = text[len(symbol):]
            elif text.endswith(symbol):
                text = text[: -len(symbol)]
            text = text.strip(BLANKS)
        if thousands:
            text = text.replace(thousands, "")
        if decimal != ".":
            text = text.replace(decimal, ".")
        m = _AMOUNT.fullmatch(text)
        if m is None or len(m.group(1)) > MAX_INTEGER_DIGITS:
            raise RecordError(f"invalid amount '{field.strip(BLANKS)}'")
        cents = int(m.group(1)) * 100 + int((m.group(2) or "").ljust(2, "0"))
        return -cents if negative else cents

    return parse


# ------------------------------------------------------------ CSV records


def _physical_lines(text: str, skip: int) -> Iterator[str]:
    """The lines after the first ``skip``, each with its ``\\n``."""
    lines = text.split("\n")
    last = len(lines) - 1
    for i in range(skip, len(lines)):
        if i < last:
            yield lines[i] + "\n"
        elif lines[i]:
            yield lines[i]


def csv_records(text: str, delimiter: str, skip_lines: int, source: str) -> Iterator[tuple[int, list[str]]]:
    """Yields ``(line, fields)`` per non-empty CSV record; ``line`` is the
    1-based physical line on which the record starts."""
    reader = csv.reader(_physical_lines(text, skip_lines), delimiter=delimiter, quotechar='"', strict=True)
    consumed = skip_lines
    while True:
        start = consumed + 1
        try:
            fields = next(reader)
        except StopIteration:
            return
        except csv.Error as e:
            raise ImportDataError(f"{source}:{start}: malformed CSV: {e}") from None
        consumed = skip_lines + reader.line_num
        if fields:
            yield start, fields


# ------------------------------------------------------------ statements


def read_file(path: str, source: str) -> str:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        raise ImportDataError(f"{source}: file does not exist") from None
    except OSError as e:
        raise ImportDataError(f"{source}: cannot read file: {e.strerror}") from None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        line = raw[: e.start].count(b"\n") + 1
        raise ImportDataError(f"{source}:{line}: invalid UTF-8") from None
    return text[1:] if text.startswith("﻿") else text


def _resolve(ref: ColumnRef, header: list[str] | None, width: int, key: str, source: str) -> int:
    """The 0-based field index of a column reference."""
    if ref.position is not None:
        if ref.position > width:
            raise ImportDataError(f"{source}: {key} {ref.position} is beyond the {width} columns of the file")
        return ref.position - 1
    assert header is not None and ref.name is not None
    wanted = ascii_lower(ref.name)
    for i, name in enumerate(header):
        if ascii_lower(name.strip(BLANKS)) == wanted:
            return i
    raise ImportDataError(f"{source}: the header has no column '{ref.name}' ({key})")


def parse_statement(text: str, settings: ImportSettings, source: str) -> list[Record]:
    """Converts the records of a statement; any failure is an ImportDataError
    naming ``source:LINE``."""
    records = csv_records(text, settings.delimiter, settings.skip_lines, source)
    header: list[str] | None = None
    if settings.header:
        first = next(records, None)
        if first is None:
            raise ImportDataError(f"{source}: the file has no header record")
        header = first[1]
        width = len(header)
        rows = records
    else:
        first = next(records, None)
        if first is None:
            return []
        width = len(first[1])
        rows = _chain(first, records)

    columns = {key: _resolve(ref, header, width, key, source) for key, ref in settings.columns()}
    date_at, description_at = columns["date_column"], columns["description_column"]
    parse_date = date_parser(settings.date_format)
    parse_amount = amount_parser(settings)
    debit_credit = settings.amount_mode == "debit_credit"
    invert = settings.invert_sign
    merchants: dict[str, str] = {}

    out: list[Record] = []
    for line, fields in rows:
        if len(fields) != width:
            raise ImportDataError(f"{source}:{line}: the record has {len(fields)} fields, expected {width}")
        try:
            date = parse_date(fields[date_at])
            if debit_credit:
                debit = fields[columns["debit_column"]].strip(BLANKS)
                credit = fields[columns["credit_column"]].strip(BLANKS)
                if not debit and not credit:
                    raise RecordError("both debit and credit are empty")
                cents = (parse_amount(credit) if credit else 0) - (parse_amount(debit) if debit else 0)
            else:
                cents = parse_amount(fields[columns["amount_column"]])
        except RecordError as e:
            raise ImportDataError(f"{source}:{line}: {e}") from None
        if invert:
            cents = -cents
        description = fields[description_at].strip(BLANKS)
        merchant = merchants.get(description)
        if merchant is None:
            merchant = merchants[description] = normalize(description)
        out.append(Record(line, date, description, merchant, cents))
    return out


def _chain(first: tuple[int, list[str]], rest: Iterator[tuple[int, list[str]]]) -> Iterator[tuple[int, list[str]]]:
    yield first
    yield from rest
