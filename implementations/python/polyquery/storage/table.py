"""Immutable tables in the row- or column-oriented in-memory layout
(indexes-and-planning.md §1), plus their statistics (§3).

* :class:`RowTable` stores a list of row tuples.
* :class:`ColumnTable` stores a list of :class:`RowGroup`\\ s, each holding one
  :class:`~.vectors.ColumnVector` per column. Tables loaded from CSV/JSON have
  a single group; tables opened from PQCF keep the file's row groups together
  with their min/max statistics (used for row-group skipping), and their
  vectors may be decoded lazily from a memory-mapped file.

Both layouts expose the same interface to the executor: ``scan`` yields row
tuples restricted to the requested columns, ``fetch`` gathers rows by
position (index scans) and ``column_values`` materializes a whole column.
"""

from __future__ import annotations

import bisect
import itertools
import operator
import threading
from dataclasses import dataclass
from typing import Any, Callable, Iterator, Sequence

from ..datatypes import DataType
from ..names import fold
from .vectors import ColumnVector, build_vector

ROW = "row"
COLUMN = "column"
LAYOUTS = (ROW, COLUMN)


@dataclass(frozen=True, slots=True)
class Column:
    name: str
    type: DataType

    def to_json(self) -> dict[str, str]:
        return {"name": self.name, "type": self.type.name}


@dataclass(frozen=True, slots=True)
class ColumnStats:
    """Exact statistics of one column (``min``/``max`` None if all NULL)."""

    null_count: int
    distinct_count: int
    min: Any
    max: Any


def compute_stats(values: Sequence[Any]) -> ColumnStats:
    distinct = set(values)
    nulls = values.count(None) if isinstance(values, list) else sum(v is None for v in values)
    distinct.discard(None)
    if not distinct:
        return ColumnStats(nulls, 0, None, None)
    return ColumnStats(nulls, len(distinct), min(distinct), max(distinct))


@dataclass(frozen=True, slots=True)
class ChunkBounds:
    """Statistics of one column chunk of a row group (from PQCF metadata):
    exact NULL count and bounds of the non-NULL values (None = unknown)."""

    null_count: int
    min: Any = None
    max: Any = None


class Table:
    """Base class of both layouts."""

    layout: str

    def __init__(self, name: str, columns: list[Column], row_count: int):
        self.name = name
        self.columns = columns
        self.row_count = row_count
        self._index = {fold(c.name): i for i, c in enumerate(columns)}
        self._stats: dict[int, ColumnStats] = {}
        self._stats_lock = threading.Lock()

    def column_index(self, name: str) -> int | None:
        return self._index.get(fold(name))

    def schema_json(self) -> list[dict[str, str]]:
        return [c.to_json() for c in self.columns]

    # ------------------------------------------------------------ data access

    def scan(
        self, column_indexes: Sequence[int], keep_group: Callable[[RowGroup], bool] | None = None
    ) -> Iterator[tuple]:
        """Yields row tuples restricted to the given columns. ``keep_group``
        lets the caller skip row groups (only meaningful for column tables)."""
        raise NotImplementedError

    def fetch(self, row_ids: Sequence[int], column_indexes: Sequence[int]) -> list[tuple]:
        """The given rows (ascending positions), restricted to the given columns."""
        raise NotImplementedError

    def column_values(self, i: int) -> list[Any]:
        """All values of column ``i`` (runtime representation, None = NULL)."""
        raise NotImplementedError

    def row_groups(self) -> list[RowGroup]:
        return []

    # ------------------------------------------------------------ statistics

    def column_stats(self, i: int) -> ColumnStats:
        """Statistics of column ``i``, computed on first use (tables are immutable)."""
        stats = self._stats.get(i)
        if stats is None:
            with self._stats_lock:
                stats = self._stats.get(i)
                if stats is None:
                    stats = self._stats[i] = compute_stats(self.column_values(i))
        return stats


class RowTable(Table):
    layout = ROW

    def __init__(self, name: str, columns: list[Column], rows: list[tuple]):
        super().__init__(name, columns, len(rows))
        self.rows = rows

    def scan(
        self, column_indexes: Sequence[int], keep_group: Callable[[RowGroup], bool] | None = None
    ) -> Iterator[tuple]:
        if not column_indexes:
            return itertools.repeat((), self.row_count)
        if list(column_indexes) == list(range(len(self.columns))):
            return iter(self.rows)
        return map(_row_getter(column_indexes), self.rows)

    def fetch(self, row_ids: Sequence[int], column_indexes: Sequence[int]) -> list[tuple]:
        rows = self.rows
        if not column_indexes:
            return [()] * len(row_ids)
        get = _row_getter(column_indexes)
        return [get(rows[i]) for i in row_ids]

    def column_values(self, i: int) -> list[Any]:
        return [row[i] for row in self.rows]


def _row_getter(column_indexes: Sequence[int]) -> Callable[[tuple], tuple]:
    if len(column_indexes) == 1:
        (only,) = column_indexes
        return lambda row: (row[only],)
    return operator.itemgetter(*column_indexes)


class RowGroup:
    """A horizontal slice of a column table: one vector per column, loaded on
    first access through ``loader`` when not given up front."""

    def __init__(
        self,
        start: int,
        row_count: int,
        vectors: list[ColumnVector | None],
        bounds: list[ChunkBounds] | None = None,
        loader: Callable[[int], ColumnVector] | None = None,
    ):
        self.start = start
        self.row_count = row_count
        self._vectors = vectors
        self.bounds = bounds
        self._loader = loader

    def vector(self, i: int) -> ColumnVector:
        v = self._vectors[i]
        if v is None:
            assert self._loader is not None
            v = self._vectors[i] = self._loader(i)
        return v


class ColumnTable(Table):
    layout = COLUMN

    def __init__(self, name: str, columns: list[Column], groups: list[RowGroup]):
        super().__init__(name, columns, sum(g.row_count for g in groups))
        self.groups = groups
        self._starts = [g.start for g in groups]

    def row_groups(self) -> list[RowGroup]:
        return self.groups

    def scan(
        self, column_indexes: Sequence[int], keep_group: Callable[[RowGroup], bool] | None = None
    ) -> Iterator[tuple]:
        for group in self.groups:
            if group.row_count == 0 or (keep_group is not None and not keep_group(group)):
                continue
            if not column_indexes:
                yield from itertools.repeat((), group.row_count)
            else:
                yield from zip(*[group.vector(i).to_list() for i in column_indexes])

    def fetch(self, row_ids: Sequence[int], column_indexes: Sequence[int]) -> list[tuple]:
        if not column_indexes:
            return [()] * len(row_ids)
        out: list[tuple] = []
        pos = 0
        while pos < len(row_ids):
            g = bisect.bisect_right(self._starts, row_ids[pos]) - 1
            group = self.groups[g]
            end = bisect.bisect_left(row_ids, group.start + group.row_count, pos)
            local = [r - group.start for r in row_ids[pos:end]]
            out.extend(zip(*[group.vector(i).take(local) for i in column_indexes]))
            pos = end
        return out

    def column_values(self, i: int) -> list[Any]:
        if len(self.groups) == 1:
            return self.groups[0].vector(i).to_list()
        out: list[Any] = []
        for group in self.groups:
            out.extend(group.vector(i).to_list())
        return out

    def vectors(self, i: int) -> list[ColumnVector]:
        return [g.vector(i) for g in self.groups]


def make_table(
    name: str,
    columns: list[Column],
    data: list[list[Any]],
    row_count: int,
    layout: str = COLUMN,
    dictionary: bool | None = None,
) -> Table:
    """Builds a table from column-wise runtime values in the requested layout.
    ``dictionary`` forces (True) / allows automatic (None) dictionary
    encoding of STRING columns in the column layout."""
    if layout == ROW:
        rows = list(zip(*data)) if columns else [()] * row_count
        return RowTable(name, columns, rows)
    vectors: list[ColumnVector | None] = [
        build_vector(c.type, values, dictionary) for c, values in zip(columns, data)
    ]
    return ColumnTable(name, columns, [RowGroup(0, row_count, vectors)])


def relayout(table: Table, name: str, layout: str, dictionary: bool | None = None) -> Table:
    """A copy of ``table`` named ``name`` in another layout."""
    data = [table.column_values(i) for i in range(len(table.columns))]
    return make_table(name, list(table.columns), data, table.row_count, layout, dictionary)
