"""Single-column secondary indexes (indexes-and-planning.md §2).

* ``HASH``: a dict from value to the ascending positions of its rows;
  supports equality and IN lookups.
* ``BTREE``: an ordered structure — the sorted permutation of the non-NULL
  rows (parallel ``keys`` / ``row_ids`` lists) searched with ``bisect``;
  supports equality, IN and range lookups.

NULLs are never indexed, so no lookup returns them. Index structures are
built once from the (immutable) table and are themselves immutable.
"""

from __future__ import annotations

import bisect
from dataclasses import dataclass
from typing import Any, Iterable

from .table import Table

HASH = "HASH"
BTREE = "BTREE"
KINDS = (HASH, BTREE)


class HashStructure:
    def __init__(self, values: list[Any]):
        buckets: dict[Any, list[int]] = {}
        get = buckets.get
        for i, v in enumerate(values):
            if v is None:
                continue
            bucket = get(v)
            if bucket is None:
                buckets[v] = [i]
            else:
                bucket.append(i)
        self.buckets = buckets

    def lookup_values(self, keys: Iterable[Any]) -> list[int]:
        out: list[int] = []
        for key in set(keys):
            out.extend(self.buckets.get(key, ()))
        return out

    supports_ranges = False


class OrderedStructure:
    def __init__(self, values: list[Any]):
        row_ids = [i for i, v in enumerate(values) if v is not None]
        row_ids.sort(key=values.__getitem__)  # stable: equal keys stay in row order
        self.row_ids = row_ids
        self.keys = [values[i] for i in row_ids]

    def lookup_values(self, keys: Iterable[Any]) -> list[int]:
        out: list[int] = []
        for key in set(keys):
            lo = bisect.bisect_left(self.keys, key)
            hi = bisect.bisect_right(self.keys, key, lo)
            out.extend(self.row_ids[lo:hi])
        return out

    def lookup_range(
        self, low: Any, low_inclusive: bool, high: Any, high_inclusive: bool
    ) -> list[int]:
        """Rows with ``low <(=) key <(=) high``; a None bound is open."""
        keys = self.keys
        if low is None:
            lo = 0
        elif low_inclusive:
            lo = bisect.bisect_left(keys, low)
        else:
            lo = bisect.bisect_right(keys, low)
        if high is None:
            hi = len(keys)
        elif high_inclusive:
            hi = bisect.bisect_right(keys, high)
        else:
            hi = bisect.bisect_left(keys, high)
        return self.row_ids[lo:hi] if lo < hi else []

    supports_ranges = True


@dataclass(eq=False)
class Index:
    name: str
    table: Table
    column: int
    kind: str  # HASH or BTREE
    structure: HashStructure | OrderedStructure

    @property
    def column_name(self) -> str:
        return self.table.columns[self.column].name

    def to_json(self) -> dict[str, str]:
        return {"name": self.name, "column": self.column_name, "kind": self.kind}


def build_index(name: str, table: Table, column: int, kind: str) -> Index:
    values = table.column_values(column)
    structure = HashStructure(values) if kind == HASH else OrderedStructure(values)
    return Index(name, table, column, kind, structure)
