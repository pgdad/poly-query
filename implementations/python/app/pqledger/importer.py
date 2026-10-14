"""``pqledger import``: duplicate detection (pqledger.md §6.4) and adding a
statement's new transactions and its batch to the ledger."""

from __future__ import annotations

import datetime as dt
import os
from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal

from .bankcsv import Record
from .ledger import Ledger
from .sql import date_literal, literal, where

Key = tuple[dt.date, int, str]  # (date, amount in cents, merchant) within one account


@dataclass(frozen=True)
class ImportResult:
    batch: int
    imported: int
    duplicates: int


def select_new(records: Sequence[Record], existing: Mapping[Key, int]) -> list[bool]:
    """Which records to import: for a key with ``f`` records in the file and
    ``l`` transactions in the ledger, the last ``max(0, f - l)`` records."""
    by_key: dict[Key, list[int]] = defaultdict(list)
    for i, r in enumerate(records):
        by_key[(r.date, r.cents, r.merchant)].append(i)
    keep = [False] * len(records)
    for key, indexes in by_key.items():
        new = max(0, len(indexes) - existing.get(key, 0))
        for i in indexes[len(indexes) - new:]:
            keep[i] = True
    return keep


def existing_counts(ledger: Ledger, account: str, records: Sequence[Record]) -> dict[Key, int]:
    """The ledger's transactions of ``account`` per key, within the dates of
    ``records``."""
    if not records:
        return {}
    first = min(r.date for r in records)
    last = max(r.date for r in records)
    result = ledger.query(
        'SELECT "date", amount, merchant, COUNT(*) AS n FROM transactions'
        + where(f"account = {literal(account)}", f'"date" >= {date_literal(first)}', f'"date" <= {date_literal(last)}')
        + ' GROUP BY "date", amount, merchant'
    )
    return {(day, int(amount.scaleb(2)), merchant): n for day, amount, merchant, n in result}


def import_records(ledger: Ledger, account: str, path: str, records: Sequence[Record]) -> ImportResult:
    """Adds the new records as transactions and records the batch; writes
    the changed ledger files."""
    keep = select_new(records, existing_counts(ledger, account, records))
    max_id, max_tx_batch = ledger.query("SELECT MAX(id), MAX(batch) FROM transactions").rows[0]
    max_batch = ledger.scalar("SELECT MAX(batch) FROM batches")
    next_id = (max_id or 0) + 1
    batch = max(max_batch or 0, max_tx_batch or 0) + 1
    rows = []
    for r, kept in zip(records, keep):
        if kept:
            amount = Decimal(r.cents).scaleb(-2)
            rows.append((next_id + len(rows), account, r.date, r.description, r.merchant, amount, batch))
    duplicates = len(records) - len(rows)
    if rows:
        ledger.append("transactions", rows)
    ledger.append("batches", [(batch, account, os.path.basename(path), len(rows), duplicates)])
    if rows:
        ledger.save("transactions")
    ledger.save("batches")
    return ImportResult(batch, len(rows), duplicates)
