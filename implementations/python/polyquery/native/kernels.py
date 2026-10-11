"""``ctypes`` binding of the native kernel C ABI (native-kernels/include/pq_kernels.h,
ABI version 1).

The library is optional: :func:`load_kernels` returns ``None`` (and logs a
warning) when it cannot be loaded or has an unexpected ABI version, and the
engine then runs its own code paths.

Buffers are passed **without copying**: the kernels receive the address of an
``array.array`` (``buffer_info()``) or of a ``bytes`` object, plus an element
offset where needed. Callers keep the buffers alive (they are referenced by
immutable column vectors or by the caller's locals) and never resize them
during a call. Every wrapper takes element counts, not byte counts, except the
bitmap operations, which take byte counts like the C functions.

``ctypes`` releases the GIL while a foreign function runs, and the kernels
are thread-safe after ``pqk_init`` and do not allocate, so concurrent queries
(HTTP server threads) and forked parallel workers can share one binding.
"""

from __future__ import annotations

import array
import ctypes
import logging
from typing import Any

log = logging.getLogger("polyquery")

ABI_VERSION = 1

# status codes
OK = 0
OVERFLOW = 1
EINVAL = 2

# comparison operators of the filter / count / compare kernels
EQ, NE, LT, LE, GT, GE, BETWEEN = range(7)

INT64_MIN = -(1 << 63)
INT64_MAX = (1 << 63) - 1
_SIZE_ERROR = ctypes.c_size_t(-1).value

_p = ctypes.c_void_p
_size = ctypes.c_size_t
_i64 = ctypes.c_int64
_int = ctypes.c_int

# name -> (restype, argtypes)
_SIGNATURES: dict[str, tuple[Any, list[Any]]] = {
    "pqk_abi_version": (_int, []),
    "pqk_init": (_int, []),
    "pqk_set_variant": (_int, [ctypes.c_char_p]),
    "pqk_variant": (ctypes.c_char_p, []),
    "pqk_available_variants": (ctypes.c_char_p, []),
    "pqk_filter_i64": (_size, [_p, _p, _size, _int, _i64, _i64, _p]),
    "pqk_filter_i64_bitmap": (_size, [_p, _p, _size, _int, _i64, _i64, _p]),
    "pqk_sum_i64": (_int, [_p, _p, _size, _p]),
    "pqk_sum_f64": (ctypes.c_double, [_p, _p, _size]),
    "pqk_minmax_i64": (_size, [_p, _p, _size, _p, _p]),
    "pqk_minmax_f64": (_size, [_p, _p, _size, _p, _p]),
    "pqk_count_i64": (_size, [_p, _p, _size, _int, _i64, _i64]),
    "pqk_bitmap_and": (None, [_p, _p, _p, _size]),
    "pqk_bitmap_or": (None, [_p, _p, _p, _size]),
    "pqk_bitmap_andnot": (None, [_p, _p, _p, _size]),
    "pqk_bitmap_popcount": (_size, [_p, _size]),
    "pqk_hash_i64": (None, [_p, _size, ctypes.c_uint64, _p]),
    "pqk_compare_i64": (_size, [_p, _p, _size, _int, _p]),
    "pqk_compare_fixed": (None, [_p, _p, _size, _size, _p]),
    "pqk_group_sum_i64": (_int, [_p, _p, _p, _size, _p, _p, _size]),
    "pqk_gather_i64": (None, [_p, _p, _size, _p]),
}


class NativeKernelError(Exception):
    """A kernel rejected its arguments (a bug in the caller)."""


def address(buf: Any, offset: int = 0) -> int | None:
    """Address of element ``offset`` of an ``array.array`` or of byte
    ``offset`` of a ``bytes`` object (None for an absent buffer)."""
    if buf is None:
        return None
    if isinstance(buf, array.array):
        return buf.buffer_info()[0] + offset * buf.itemsize
    if isinstance(buf, bytes):
        return ctypes.cast(buf, ctypes.c_void_p).value + offset  # type: ignore[operator]
    raise TypeError(f"unsupported buffer type {type(buf).__name__}")


def new_bitmap(nbits: int) -> array.array:
    """A zeroed bitmap buffer for ``nbits`` bits."""
    return array.array("B", bytes((nbits + 7) >> 3))


class NativeKernels:
    """The loaded library. Methods mirror the C functions; data arguments are
    addresses (see :func:`address`) or arrays, as documented per method."""

    def __init__(self, lib: ctypes.CDLL, path: str):
        self.path = path
        self._lib = lib
        for name, (restype, argtypes) in _SIGNATURES.items():
            fn = getattr(lib, name)
            fn.restype = restype
            fn.argtypes = argtypes
        self.abi_version = lib.pqk_abi_version()
        lib.pqk_init()
        self.variant = lib.pqk_variant().decode("ascii", "replace")
        self.available = lib.pqk_available_variants().decode("ascii", "replace")
        # hot functions bound once (attribute lookups on CDLL are slow)
        self._filter_bitmap = lib.pqk_filter_i64_bitmap
        self._filter = lib.pqk_filter_i64
        self._count = lib.pqk_count_i64
        self._sum = lib.pqk_sum_i64
        self._minmax_i64 = lib.pqk_minmax_i64
        self._minmax_f64 = lib.pqk_minmax_f64
        self._and = lib.pqk_bitmap_and
        self._or = lib.pqk_bitmap_or
        self._andnot = lib.pqk_bitmap_andnot
        self._popcount = lib.pqk_bitmap_popcount
        self._hash = lib.pqk_hash_i64
        self._group_sum = lib.pqk_group_sum_i64
        self._gather = lib.pqk_gather_i64

    def set_variant(self, name: str) -> bool:
        ok = self._lib.pqk_set_variant(name.encode("ascii")) == OK
        self.variant = self._lib.pqk_variant().decode("ascii", "replace")
        return ok

    # ------------------------------------------------------------ filtering

    def filter_bitmap(
        self, data: int, validity: int | None, n: int, op: int, a: int, b: int, out: array.array
    ) -> int:
        """Predicate ``op(data[i], a, b)`` on valid rows as a bitmap written to
        ``out`` (an ``array('B')`` of at least ceil(n/8) bytes); returns the
        number of set bits."""
        count = self._filter_bitmap(data, validity, n, op, a, b, out.buffer_info()[0])
        if count == _SIZE_ERROR:
            raise NativeKernelError(f"pqk_filter_i64_bitmap: invalid op {op}")
        return count

    def filter_indices(
        self, data: int, validity: int | None, n: int, op: int, a: int, b: int, out: array.array
    ) -> int:
        """Ascending indices of the valid rows satisfying the predicate,
        written to ``out`` (an ``array('I')`` of at least n elements);
        returns their count."""
        count = self._filter(data, validity, n, op, a, b, out.buffer_info()[0])
        if count == _SIZE_ERROR:
            raise NativeKernelError(f"pqk_filter_i64: invalid op {op}")
        return count

    def count(self, data: int, validity: int | None, n: int, op: int, a: int, b: int) -> int:
        count = self._count(data, validity, n, op, a, b)
        if count == _SIZE_ERROR:
            raise NativeKernelError(f"pqk_count_i64: invalid op {op}")
        return count

    # ------------------------------------------------------------ aggregation

    def sum_i64(self, data: int, validity: int | None, n: int) -> int | None:
        """Exact sum of the valid values, or None if it does not fit in int64
        (PQK_OVERFLOW: the caller recomputes with Python integers)."""
        out = ctypes.c_int64()
        status = self._sum(data, validity, n, ctypes.byref(out))
        if status == OVERFLOW:
            return None
        if status != OK:
            raise NativeKernelError(f"pqk_sum_i64: status {status}")
        return out.value

    def minmax_i64(self, data: int, validity: int | None, n: int) -> tuple[int, int, int]:
        """(number of valid values, min, max); min/max meaningless if 0."""
        lo, hi = ctypes.c_int64(), ctypes.c_int64()
        count = self._minmax_i64(data, validity, n, ctypes.byref(lo), ctypes.byref(hi))
        return count, lo.value, hi.value

    def minmax_f64(self, data: int, validity: int | None, n: int) -> tuple[int, float, float]:
        lo, hi = ctypes.c_double(), ctypes.c_double()
        count = self._minmax_f64(data, validity, n, ctypes.byref(lo), ctypes.byref(hi))
        return count, lo.value, hi.value

    def group_sum_i64(
        self,
        group_ids: array.array,
        values: array.array,
        validity: int | None,
        n: int,
        sums: array.array,
        counts: array.array | None,
        ngroups: int,
    ) -> bool:
        """Accumulates ``values`` (``array('q')``) into ``sums`` / ``counts``
        (``array('q')`` of ``ngroups``) by ``group_ids`` (``array('I')``).
        Returns False when the kernel reports a possible int64 wrap-around
        (PQK_OVERFLOW): the sums are then not exact and must be recomputed."""
        status = self._group_sum(
            group_ids.buffer_info()[0],
            values.buffer_info()[0],
            validity,
            n,
            sums.buffer_info()[0],
            None if counts is None else counts.buffer_info()[0],
            ngroups,
        )
        if status == EINVAL:
            raise NativeKernelError("pqk_group_sum_i64: group id out of range")
        return status == OK

    # ------------------------------------------------------------ bitmaps

    def bitmap_and(self, a: array.array, b: int | None, nbytes: int) -> None:
        """``a &= b`` (``b`` an address)."""
        pa = a.buffer_info()[0]
        self._and(pa, b, pa, nbytes)

    def bitmap_or(self, a: array.array, b: array.array, nbytes: int) -> None:
        """``a |= b``."""
        pa = a.buffer_info()[0]
        self._or(pa, b.buffer_info()[0], pa, nbytes)

    def bitmap_andnot(self, a: array.array, b: int | None, nbytes: int) -> None:
        """``a &= ~b`` (``b`` an address)."""
        pa = a.buffer_info()[0]
        self._andnot(pa, b, pa, nbytes)

    def popcount(self, bits: int | None, nbits: int) -> int:
        return self._popcount(bits, nbits)

    # ------------------------------------------------------------ hashing / gathering

    def hash_i64(self, data: int, n: int, seed: int, out: array.array) -> None:
        """MurmurHash3 fmix64 of ``data[i] ^ seed`` into ``out`` (``array('Q')``)."""
        self._hash(data, n, seed, out.buffer_info()[0])

    def gather(self, data: int, idx: array.array, m: int, out: array.array) -> None:
        """``out[j] = data[idx[j]]`` for 8-byte elements (``idx`` an
        ``array('I')``, ``out`` an ``array('q')`` / ``array('d')``)."""
        self._gather(data, idx.buffer_info()[0], m, out.buffer_info()[0])


def load_kernels(path: str | None) -> NativeKernels | None:
    """Loads ``libpqkernels`` from ``path``; None (with a warning) if that is
    impossible, so the engine falls back to its own code paths."""
    if not path:
        return None
    try:
        lib = ctypes.CDLL(path)
        kernels = NativeKernels(lib, path)
    except (OSError, AttributeError) as e:
        log.warning("native kernels unavailable", extra={"fields": {"path": path, "error": str(e)}})
        return None
    if kernels.abi_version != ABI_VERSION:
        log.warning(
            "native kernels have an unsupported ABI version",
            extra={"fields": {"path": path, "abi_version": kernels.abi_version}},
        )
        return None
    log.info(
        "native kernels loaded",
        extra={"fields": {"path": path, "variant": kernels.variant, "available": kernels.available}},
    )
    return kernels
