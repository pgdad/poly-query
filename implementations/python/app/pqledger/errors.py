"""Application errors and their exit statuses (pqledger.md §10)."""

from __future__ import annotations

OK = 0
USAGE = 1
CONFIG = 2
OVER_BUDGET = 3
IMPORT_DATA = 4
QUERY = 5
LEDGER_STATE = 6
OTHER = 7


class AppError(Exception):
    """A failure reported as ``pqledger: error: MESSAGE`` with ``exit_status``."""

    exit_status = OTHER

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class UsageError(AppError):
    exit_status = USAGE


class ConfigError(AppError):
    """Configuration, rules or budget file."""

    exit_status = CONFIG


class ImportDataError(AppError):
    exit_status = IMPORT_DATA


class QueryError(AppError):
    """The engine rejected the SQL of ``pqledger query``."""

    exit_status = QUERY


class LedgerStateError(AppError):
    """No ledger, ledger already exists, unknown transaction id."""

    exit_status = LEDGER_STATE
