"""In-memory catalog of immutable, column-oriented tables."""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Any, Iterator, Sequence

from .. import errors
from ..datatypes import DataType
from ..names import fold


@dataclass(frozen=True, slots=True)
class Column:
    name: str
    type: DataType

    def to_json(self) -> dict[str, str]:
        return {"name": self.name, "type": self.type.name}


@dataclass(eq=False)
class Table:
    """An immutable table stored column-wise: ``data[i]`` holds column i's values."""

    name: str
    columns: list[Column]
    data: list[list[Any]]
    row_count: int
    _index: dict[str, int] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        self._index = {fold(c.name): i for i, c in enumerate(self.columns)}

    def column_index(self, name: str) -> int | None:
        return self._index.get(fold(name))

    def scan(self, column_indexes: Sequence[int]) -> Iterator[tuple]:
        """Yields row tuples restricted to the given columns."""
        if not column_indexes:
            return iter([()] * self.row_count)
        return zip(*(self.data[i] for i in column_indexes))

    def schema_json(self) -> list[dict[str, str]]:
        return [c.to_json() for c in self.columns]


class Catalog:
    """Name -> table mapping with case-insensitive lookup. Thread-safe."""

    def __init__(self) -> None:
        self._tables: dict[str, Table] = {}
        self._lock = threading.RLock()

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

    def put(self, table: Table, *, replace: bool) -> None:
        """Adds a table atomically; fails with ALREADY_EXISTS unless ``replace``."""
        key = fold(table.name)
        with self._lock:
            if key in self._tables and not replace:
                raise errors.already_exists(f"table '{table.name}' already exists", table=table.name)
            self._tables[key] = table

    def drop(self, name: str) -> None:
        with self._lock:
            if self._tables.pop(fold(name), None) is None:
                raise errors.not_found(f"table '{name}' does not exist", table=name)

    def reset(self) -> None:
        with self._lock:
            self._tables.clear()

    def tables(self) -> list[Table]:
        with self._lock:
            return sorted(self._tables.values(), key=lambda t: (fold(t.name), t.name))
