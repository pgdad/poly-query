"""The catalog: tables and (globally named) indexes, case-insensitive names."""

from __future__ import annotations

import threading

from .. import errors
from ..names import fold
from .indexes import Index
from .table import Column, Table

__all__ = ["Catalog", "CatalogSnapshot", "Column", "Table"]


class Catalog:
    """Name -> table and name -> index mappings. Thread-safe; every mutation
    is atomic (all checks happen before anything is changed)."""

    def __init__(self) -> None:
        self._tables: dict[str, Table] = {}
        self._indexes: dict[str, Index] = {}
        self._lock = threading.RLock()

    # ------------------------------------------------------------ tables

    def get(self, name: str) -> Table | None:
        with self._lock:
            return self._tables.get(fold(name))

    def require(self, name: str) -> Table:
        table = self.get(name)
        if table is None:
            raise errors.not_found(f"table '{name}' does not exist", table=name)
        return table

    def exists(self, name: str) -> bool:
        return self.get(name) is not None

    def put(self, table: Table, *, replace: bool, indexes: list[Index] | None = None) -> None:
        """Adds a table (and indexes built on it) atomically. Fails with
        ALREADY_EXISTS if the table exists and not ``replace``, or if one of
        the index names is taken by an index that would survive the
        replacement. A replaced table's indexes are dropped."""
        key = fold(table.name)
        indexes = indexes or []
        with self._lock:
            old = self._tables.get(key)
            if old is not None and not replace:
                raise errors.already_exists(f"table '{table.name}' already exists", table=table.name)
            for index in indexes:
                existing = self._indexes.get(fold(index.name))
                if existing is not None and existing.table is not old:
                    raise errors.already_exists(
                        f"index '{index.name}' already exists", index=index.name
                    )
            if old is not None:
                self._drop_indexes_of(old)
            self._tables[key] = table
            for index in indexes:
                self._indexes[fold(index.name)] = index

    def drop(self, name: str) -> None:
        with self._lock:
            table = self._tables.pop(fold(name), None)
            if table is None:
                raise errors.not_found(f"table '{name}' does not exist", table=name)
            self._drop_indexes_of(table)

    def reset(self) -> None:
        with self._lock:
            self._tables.clear()
            self._indexes.clear()

    def tables(self) -> list[Table]:
        with self._lock:
            return sorted(self._tables.values(), key=lambda t: (fold(t.name), t.name))

    def objects(self) -> list[Table | Index]:
        """Every table and index (what parallel worker processes inherit)."""
        with self._lock:
            return [*self._tables.values(), *self._indexes.values()]

    # ------------------------------------------------------------ indexes

    def get_index(self, name: str) -> Index | None:
        with self._lock:
            return self._indexes.get(fold(name))

    def add_index(self, index: Index) -> None:
        """Registers an index on a table that must still be in the catalog."""
        with self._lock:
            if fold(index.name) in self._indexes:
                raise errors.already_exists(f"index '{index.name}' already exists", index=index.name)
            if self._tables.get(fold(index.table.name)) is not index.table:
                raise errors.not_found(f"table '{index.table.name}' does not exist")
            self._indexes[fold(index.name)] = index

    def drop_index(self, name: str) -> bool:
        """Removes an index; False if it does not exist."""
        with self._lock:
            return self._indexes.pop(fold(name), None) is not None

    def indexes_of(self, table: Table) -> list[Index]:
        """The indexes of a table, in creation order."""
        with self._lock:
            return [i for i in self._indexes.values() if i.table is table]

    def snapshot(self) -> CatalogSnapshot:
        """An immutable view of the current tables and indexes: a query binds
        and plans against one snapshot, so it sees exactly one version of
        every table it references (concurrency.md §1)."""
        with self._lock:
            return CatalogSnapshot(dict(self._tables), dict(self._indexes))

    def _drop_indexes_of(self, table: Table) -> None:
        for key in [k for k, i in self._indexes.items() if i.table is table]:
            del self._indexes[key]


class CatalogSnapshot:
    """Read-only catalog state captured at one instant (see Catalog.snapshot)."""

    def __init__(self, tables: dict[str, Table], indexes: dict[str, Index]):
        self._tables = tables
        self._indexes = indexes

    def get(self, name: str) -> Table | None:
        return self._tables.get(fold(name))

    def get_index(self, name: str) -> Index | None:
        return self._indexes.get(fold(name))

    def indexes_of(self, table: Table) -> list[Index]:
        return [i for i in self._indexes.values() if i.table is table]
