"""The ledger (pqledger.md §4): three PQCF tables in ``data_dir``, accessed
through one in-process engine instance (``polyquery.Database``)."""

from __future__ import annotations

import os
from collections.abc import Iterable, Sequence
from typing import Any

import polyquery

from .errors import AppError, LedgerStateError

TRANSACTIONS = (
    ("id", "INT64"),
    ("account", "STRING"),
    ("date", "DATE"),
    ("description", "STRING"),
    ("merchant", "STRING"),
    ("amount", "DECIMAL(18,2)"),
    ("batch", "INT64"),
)
BATCHES = (
    ("batch", "INT64"),
    ("account", "STRING"),
    ("file", "STRING"),
    ("imported", "INT64"),
    ("duplicates", "INT64"),
)
OVERRIDES = (("id", "INT64"), ("category", "STRING"))

#: the ledger's tables, their columns and (§4) the key their rows are stored in
TABLES = {
    "transactions": (TRANSACTIONS, "id"),
    "batches": (BATCHES, "batch"),
    "overrides": (OVERRIDES, "id"),
}


def file_name(table: str) -> str:
    return f"{table}.pqcf"


class EngineFailure(AppError):
    """An engine error in one of pqledger's own operations (exit 7)."""

    def __init__(self, error: polyquery.Error, doing: str):
        super().__init__(f"{doing}: {error.code}: {error.message}")
        self.error = error


class Ledger:
    """An open ledger: the engine instance with the ledger's tables loaded.
    Changes are made to the in-memory tables and written back with
    :meth:`save` (each file is replaced atomically)."""

    def __init__(self, db: polyquery.Database, threads: int | None):
        self.db = db
        self.threads = threads

    # ------------------------------------------------------------ lifecycle

    @staticmethod
    def engine(data_dir: str, threads: int | None, memory_mb: int | None) -> polyquery.Database:
        options: dict[str, Any] = {}
        if memory_mb is not None:
            options["max_query_memory_mb"] = memory_mb
        if threads is not None:
            options["threads"] = threads
        try:
            return polyquery.Database(data_dir, **options)
        except polyquery.Error as e:
            raise EngineFailure(e, "cannot start the engine") from None

    @classmethod
    def open(cls, data_dir: str, threads: int | None = None, memory_mb: int | None = None) -> Ledger:
        """Opens an existing ledger (LedgerStateError if there is none)."""
        if not os.path.isfile(os.path.join(data_dir, file_name("transactions"))):
            raise LedgerStateError(f"no ledger in {data_dir} (run 'pqledger init')")
        ledger = cls(cls.engine(data_dir, threads, memory_mb), threads)
        try:
            for table, (columns, _) in TABLES.items():
                ledger._open_table(table, columns)
        except BaseException:
            ledger.close()
            raise
        return ledger

    @classmethod
    def initialize(cls, data_dir: str, threads: int | None = None, memory_mb: int | None = None) -> Ledger:
        """Creates ``data_dir`` and an empty ledger in it (LedgerStateError if
        a ledger exists)."""
        if os.path.exists(os.path.join(data_dir, file_name("transactions"))):
            raise LedgerStateError(f"a ledger already exists in {data_dir}")
        try:
            os.makedirs(data_dir, exist_ok=True)
        except OSError as e:
            raise AppError(f"cannot create {data_dir}: {e.strerror}") from None
        ledger = cls(cls.engine(data_dir, threads, memory_mb), threads)
        try:
            # overrides and batches first: transactions.pqcf marks the ledger as existing
            for table in ("overrides", "batches", "transactions"):
                ledger.replace_rows(table, [])
                ledger.save(table)
        except BaseException:
            ledger.close()
            raise
        return ledger

    def close(self) -> None:
        self.db.close()

    def __enter__(self) -> Ledger:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _open_table(self, table: str, columns: Sequence[tuple[str, str]]) -> None:
        path = file_name(table)
        if not os.path.exists(os.path.join(self.db.data_dir, path)):
            # a ledger missing its (empty) side tables is still readable
            self.replace_rows(table, [])
            return
        try:
            info = self.db.open(table, path)
        except polyquery.Error as e:
            raise EngineFailure(e, f"cannot read {path}") from None
        got = [(c.name, c.type) for c in info.columns]
        if got != list(columns):
            raise AppError(f"{path} does not have the columns of a ledger table: {got}")

    # ------------------------------------------------------------ access

    def query(self, sql: str, doing: str = "query failed") -> polyquery.Result:
        """Runs one of pqledger's own statements (engine errors: exit 7)."""
        try:
            return self.db.query(sql, threads=self.threads)
        except polyquery.Error as e:
            raise EngineFailure(e, doing) from None

    def scalar(self, sql: str) -> Any:
        return self.query(sql).scalar()

    def replace_rows(self, table: str, rows: Iterable[Sequence[Any]]) -> None:
        """Replaces the in-memory table with ``rows`` (native values)."""
        columns, _ = TABLES[table]
        try:
            self.db.create_table(table, columns, rows, replace=True)
        except polyquery.Error as e:
            raise EngineFailure(e, f"cannot build table {table}") from None

    def create(self, table: str, columns: Sequence[tuple[str, str]], rows: Iterable[Sequence[Any]]) -> None:
        """Adds a helper table (not part of the ledger files)."""
        try:
            self.db.create_table(table, columns, rows, replace=True)
        except polyquery.Error as e:
            raise EngineFailure(e, f"cannot build table {table}") from None

    def append(self, table: str, rows: Sequence[Sequence[Any]]) -> None:
        """Adds ``rows`` to a ledger table, keeping it in key order."""
        columns, key = TABLES[table]
        staging = f"new_{table}"
        self.create(staging, columns, rows)
        try:
            self.db.create_table_as(
                table,
                f"SELECT * FROM {table} UNION ALL SELECT * FROM {staging} ORDER BY {key}",
                replace=True,
                threads=self.threads,
            )
            self.db.drop(staging)
        except polyquery.Error as e:
            raise EngineFailure(e, f"cannot update table {table}") from None

    def rebuild(self, table: str, sql: str) -> None:
        """Replaces a ledger table by the result of ``sql``."""
        try:
            self.db.create_table_as(table, sql, replace=True, threads=self.threads)
        except polyquery.Error as e:
            raise EngineFailure(e, f"cannot update table {table}") from None

    def save(self, table: str) -> None:
        """Writes a ledger table to its PQCF file (atomically)."""
        try:
            self.db.save(table, file_name(table))
        except polyquery.Error as e:
            raise EngineFailure(e, f"cannot write {file_name(table)}") from None
