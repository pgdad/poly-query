"""Typed column vectors of the column-oriented in-memory layout
(indexes-and-planning.md §1).

A vector holds the values of one column for a run of rows:

* fixed-width types live in an ``array.array`` (``q`` for INT64, narrow
  DECIMAL unscaled values and TIMESTAMP, ``i`` for DATE, ``d`` for FLOAT64)
  and BOOLEAN in a ``bytearray`` of 0/1 bytes; NULL slots hold 0;
* wide DECIMAL (precision > 18) unscaled values do not fit 64 bits: they
  are a list of Python ints (NULL slots 0), which has no int64 view, so
  the native kernels never see them;
* STRING is either plain (a list of ``str``, NULL slots ``""``) or
  dictionary-encoded (distinct strings plus an ``array('I')`` of codes);
* NULLs are recorded in a validity bitmap (LSB-first, 1 = non-NULL, the PQCF
  convention) that is omitted when the vector has no NULLs.

Vectors are immutable. ``to_list`` materializes the runtime values (with
``None`` for NULL) for scans; ``take`` gathers individual rows for index scans.
"""

from __future__ import annotations

import array
import bisect
import collections
import itertools
import operator
from typing import Any, Iterable, Sequence

from ..datatypes import DataType, TypeKind

# array typecode per fixed-width type kind
TYPECODES = {
    TypeKind.INT64: "q",
    TypeKind.DECIMAL: "q",
    TypeKind.TIMESTAMP: "q",
    TypeKind.DATE: "i",
    TypeKind.FLOAT64: "d",
}

# byte value -> its 8 bits as 0/1 bytes (LSB first), and the inverse mapping
_EXPAND = [bytes((b >> j) & 1 for j in range(8)) for b in range(256)]
_PACK = {pattern: b for b, pattern in enumerate(_EXPAND)}


# ------------------------------------------------------------------ bitmaps


def bits_to_flags(bitmap: bytes, n: int) -> bytes:
    """Expands an LSB-first bitmap into ``n`` 0/1 bytes (trailing bits ignored)."""
    return b"".join([_EXPAND[b] for b in bitmap])[:n]


def flags_to_bits(flags: bytes | bytearray) -> bytes:
    """Packs 0/1 bytes into an LSB-first bitmap; unused trailing bits are 0."""
    n = len(flags)
    padded = bytes(flags) + bytes(-n % 8)
    return bytes([_PACK[padded[i : i + 8]] for i in range(0, len(padded), 8)])


def count_set_bits(bitmap: bytes, n: int) -> int:
    """Number of 1 bits among the first ``n`` bits of an LSB-first bitmap."""
    return (int.from_bytes(bitmap, "little") & ((1 << n) - 1)).bit_count()


def null_positions(flags: bytes) -> list[int]:
    """Row positions whose validity flag is 0."""
    out: list[int] = []
    find = flags.find
    i = find(0)
    while i >= 0:
        out.append(i)
        i = find(0, i + 1)
    return out


def validity_of(values: Sequence[Any]) -> tuple[bytes | None, int]:
    """(validity bitmap or None if there are no NULLs, NULL count)."""
    nulls = values.count(None) if isinstance(values, list) else sum(v is None for v in values)
    if nulls == 0:
        return None, 0
    flags = bytes([v is not None for v in values])
    return flags_to_bits(flags), nulls


# ------------------------------------------------------------------ vectors


class ColumnVector:
    dtype: DataType
    length: int
    null_count: int
    validity: bytes | None  # LSB-first, 1 = non-NULL; None when null_count == 0
    _nulls: Sequence[int] | None

    def to_list(self, start: int = 0, stop: int | None = None) -> list[Any]:
        """The runtime values of rows ``start`` .. ``stop`` (default: all)."""
        raise NotImplementedError

    def take(self, positions: Iterable[int]) -> list[Any]:
        raise NotImplementedError

    def null_rows(self) -> Sequence[int]:
        """Positions of the NULL rows, ascending (expanded from the bitmap once
        and cached: vectors are immutable)."""
        if self.validity is None:
            return ()
        nulls = self._nulls
        if nulls is None:
            nulls = self._nulls = array.array("i", null_positions(bits_to_flags(self.validity, self.length)))
        return nulls

    def _null_positions(self, start: int = 0, stop: int | None = None) -> Iterable[int]:
        """Positions (relative to ``start``) of the NULL rows in ``start`` .. ``stop``."""
        nulls = self.null_rows()
        if not nulls:
            return ()
        stop = self.length if stop is None else min(stop, self.length)
        if start == 0 and stop == self.length:
            return nulls
        lo, hi = bisect.bisect_left(nulls, start), bisect.bisect_left(nulls, stop)
        return map(operator.sub, nulls[lo:hi], itertools.repeat(start))

    def _set_nulls(self, values: list[Any], start: int, stop: int | None) -> list[Any]:
        """Sets the NULL slots of decoded values (C-level loop)."""
        positions = self._null_positions(start, stop)
        if positions:
            collections.deque(map(values.__setitem__, positions, itertools.repeat(None)), maxlen=0)
        return values

    def _is_valid(self, i: int) -> bool:
        validity = self.validity
        return validity is None or (validity[i >> 3] >> (i & 7)) & 1 == 1

    def int64_view(self) -> array.array | None:
        """The stored values as an ``array('q')`` (NULL slots hold 0), for the
        native kernels: the stored array itself for INT64 / DECIMAL /
        TIMESTAMP, a widened copy (made once and cached) of DATE values and
        of dictionary codes; None for other representations."""
        return None


class PlainVector(ColumnVector):
    """Values stored one per row (array / bytearray / list of str)."""

    __slots__ = ("dtype", "length", "null_count", "validity", "data", "_nulls", "_wide")

    def __init__(self, dtype: DataType, data: Any, validity: bytes | None, null_count: int):
        self.dtype = dtype
        self.data = data
        self.length = len(data)
        self.validity = validity
        self.null_count = null_count
        self._nulls: Sequence[int] | None = None
        self._wide: array.array | None = None

    def int64_view(self) -> array.array | None:
        data = self.data
        if not isinstance(data, array.array):
            return None
        if data.typecode == "q":
            return data
        if data.typecode != "i":
            return None
        wide = self._wide
        if wide is None:
            wide = self._wide = array.array("q", data)
        return wide

    def to_list(self, start: int = 0, stop: int | None = None) -> list[Any]:
        whole = start == 0 and (stop is None or stop >= self.length)
        data = self.data if whole else self.data[start:stop]
        if self.dtype.kind is TypeKind.BOOLEAN:
            values = list(map(bool, data))
        elif isinstance(data, list):
            values = list(data) if whole else data
        else:
            values = data.tolist()
        return self._set_nulls(values, start, stop)

    def take(self, positions: Iterable[int]) -> list[Any]:
        data, valid = self.data, self._is_valid
        if self.dtype.kind is TypeKind.BOOLEAN:
            return [bool(data[i]) if valid(i) else None for i in positions]
        if self.validity is None:
            return [data[i] for i in positions]
        return [data[i] if valid(i) else None for i in positions]


class DictVector(ColumnVector):
    """Dictionary-encoded STRING vector: ``dictionary[codes[i]]`` is row i's value."""

    __slots__ = ("dtype", "length", "null_count", "validity", "dictionary", "codes", "_nulls", "_wide")

    def __init__(
        self,
        dtype: DataType,
        dictionary: list[str],
        codes: array.array,
        validity: bytes | None,
        null_count: int,
    ):
        self.dtype = dtype
        self.dictionary = dictionary
        self.codes = codes
        self.length = len(codes)
        self.validity = validity
        self.null_count = null_count
        self._nulls: Sequence[int] | None = None
        self._wide: array.array | None = None

    def int64_view(self) -> array.array:
        """The dictionary codes widened to int64."""
        wide = self._wide
        if wide is None:
            wide = self._wide = array.array("q", self.codes)
        return wide

    def to_list(self, start: int = 0, stop: int | None = None) -> list[Any]:
        codes = self.codes if start == 0 and stop is None else self.codes[start:stop]
        values = list(map(self.dictionary.__getitem__, codes))
        return self._set_nulls(values, start, stop)

    def take(self, positions: Iterable[int]) -> list[Any]:
        dictionary, codes, valid = self.dictionary, self.codes, self._is_valid
        return [dictionary[codes[i]] if valid(i) else None for i in positions]


# ------------------------------------------------------------------ construction


def build_vector(dtype: DataType, values: list[Any], dictionary: bool | None = None) -> ColumnVector:
    """Builds a vector from runtime values. For STRING columns ``dictionary``
    forces (True) or prevents (False) dictionary encoding; None chooses it
    automatically when the column has few distinct values."""
    validity, nulls = validity_of(values)
    kind = dtype.kind
    if kind is TypeKind.STRING:
        if dictionary is None:
            dictionary = should_dictionary_encode(values)
        if dictionary:
            return dictionary_encode(dtype, values, validity, nulls)
        data: Any = [v if v is not None else "" for v in values] if nulls else list(values)
        return PlainVector(dtype, data, validity, nulls)
    if kind is TypeKind.BOOLEAN:
        return PlainVector(dtype, bytearray([v is True for v in values]), validity, nulls)
    filled = [0 if v is None else v for v in values] if nulls else values
    if dtype.is_wide:
        return PlainVector(dtype, list(filled), validity, nulls)
    return PlainVector(dtype, array.array(TYPECODES[kind], filled), validity, nulls)


def should_dictionary_encode(values: list[Any]) -> bool:
    """Dictionary encoding pays off when there are fewer than n/2 distinct values."""
    n = len(values)
    if n < 2:
        return False
    seen: set[Any] = set()
    for v in values:
        if v is not None:
            seen.add(v)
            if 2 * len(seen) >= n:
                return False
    return True


def dictionary_encode(
    dtype: DataType, values: list[Any], validity: bytes | None, nulls: int
) -> DictVector:
    codes_of: dict[str, int] = {}
    dictionary: list[str] = []
    codes = array.array("I")
    append = codes.append
    for v in values:
        if v is None:
            append(0)
            continue
        code = codes_of.get(v)
        if code is None:
            code = codes_of[v] = len(dictionary)
            dictionary.append(v)
        append(code)
    if not dictionary:
        dictionary.append("")  # keeps the code of NULL slots valid
    return DictVector(dtype, dictionary, codes, validity, nulls)


def vector_from_runtime(dtype: DataType, values: Iterable[Any]) -> ColumnVector:
    return build_vector(dtype, list(values), dictionary=False)


def concat_lists(vectors: Iterable[ColumnVector]) -> list[Any]:
    return list(itertools.chain.from_iterable(v.to_list() for v in vectors))
