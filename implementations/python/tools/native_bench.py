"""Kernel micro-benchmark from the engine's point of view: each native kernel
called through the ``ctypes`` binding on a column of ``--rows`` values,
against the CPython code the engine runs without it (the vectorized
engine's C-level builtins). Times are medians in ms.

    python3 tools/native_bench.py --lib ../../native-kernels/build/x86_64/libpqkernels.so \\
        [--rows 1000000] [--repeat 7] [--variant x86_avx2]
"""

from __future__ import annotations

import argparse
import array
import itertools
import operator
import random
import statistics
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from polyquery.native import kernels as nk  # noqa: E402
from polyquery.native.kernels import address, load_kernels, new_bitmap  # noqa: E402
from polyquery.storage.vectors import flags_to_bits  # noqa: E402

MASK64 = (1 << 64) - 1


def fmix64(k: int) -> int:
    k ^= k >> 33
    k = (k * 0xFF51AFD7ED558CCD) & MASK64
    k ^= k >> 33
    k = (k * 0xC4CEB9FE1A85EC53) & MASK64
    return k ^ (k >> 33)


def median_ms(fn: Callable[[], object], repeat: int) -> float:
    times = []
    for _ in range(repeat):
        t0 = time.perf_counter()
        fn()
        times.append((time.perf_counter() - t0) * 1000)
    return statistics.median(times)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--rows", type=int, default=1_000_000)
    ap.add_argument("--repeat", type=int, default=7)
    ap.add_argument("--variant")
    args = ap.parse_args()
    k = load_kernels(args.lib)
    if k is None:
        print("native kernels could not be loaded", file=sys.stderr)
        return 2
    if args.variant and not k.set_variant(args.variant):
        print(f"variant {args.variant} unavailable", file=sys.stderr)
        return 2
    n = args.rows
    rng = random.Random(1)
    values = [rng.randint(0, 1_000_000) for _ in range(n)]
    data = array.array("q", values)
    other = array.array("q", reversed(values))
    ids_list = [rng.randrange(1024) for _ in range(n)]
    ids = array.array("I", ids_list)
    sel = sorted(rng.sample(range(n), n // 10))
    idx = array.array("I", sel)
    bits = array.array("B", flags_to_bits(bytes(rng.random() < 0.5 for _ in range(n))))
    pd = address(data)

    def py_filter() -> object:  # predicate vector + compaction of one column
        return list(itertools.compress(values, map(operator.gt, values, itertools.repeat(900_000))))

    def nat_filter() -> object:
        out = new_bitmap(n)
        count = k.filter_bitmap(pd, None, n, nk.GT, 900_000, 0, out)
        positions = array.array("I", bytes(4 * n))
        k.filter_indices(pd, None, n, nk.GT, 900_000, 0, positions)
        gathered = array.array("q", bytes(8 * count))
        k.gather(pd, positions, count, gathered)
        return gathered.tolist()

    def py_group_sum() -> object:
        sums = [0] * 1024
        for g, v in zip(ids_list, values):
            sums[g] += v
        return sums, Counter(ids_list)

    def nat_group_sum() -> object:
        sums, counts = array.array("q", bytes(8 * 1024)), array.array("q", bytes(8 * 1024))
        k.group_sum_i64(ids, pd, None, n, sums, counts, 1024)
        return sums

    def nat_hash() -> object:
        out = array.array("Q", bytes(8 * n))
        k.hash_i64(pd, n, 0, out)
        return out

    def nat_compare() -> object:
        out = new_bitmap(n)
        return k.compare(pd, address(other), n, nk.LT, out)

    gather_values = operator.itemgetter(*sel)

    def nat_gather() -> object:
        out = array.array("q", bytes(8 * len(sel)))
        k.gather(pd, idx, len(sel), out)
        return out.tolist()

    cases: list[tuple[str, str, Callable[[], object], Callable[[], object]]] = [
        ("filter `x > 900000` → values (10%)", "filter_i64_bitmap + filter_i64 + gather_i64", py_filter, nat_filter),
        ("count `x BETWEEN …`", "count_i64",
         lambda: sum(map(operator.and_, map(operator.ge, values, itertools.repeat(100)),
                         map(operator.le, values, itertools.repeat(500_000)))),
         lambda: k.count(pd, None, n, nk.BETWEEN, 100, 500_000)),
        ("SUM", "sum_i64", lambda: sum(values), lambda: k.sum_i64(pd, None, n)),
        ("MIN + MAX", "minmax_i64", lambda: (min(values), max(values)), lambda: k.minmax_i64(pd, None, n)),
        ("popcount of a selection", "bitmap_popcount",
         lambda: int.from_bytes(bits, "little").bit_count(), lambda: k.popcount(address(bits), n)),
        ("SUM + COUNT by 1024 groups", "group_sum_i64", py_group_sum, nat_group_sum),
        ("hash (fmix64)", "hash_i64", lambda: list(map(fmix64, values[: n // 10])), nat_hash),
        ("column < column", "compare_i64", lambda: list(map(operator.lt, values, other)), nat_compare),
        ("gather 10% of the rows", "gather_i64", lambda: gather_values(values), nat_gather),
    ]
    print(f"variant {k.variant}, {n} int64 values, median of {args.repeat} (ms)")
    print("| operation | kernel(s) | CPython | native | speedup |")
    print("|---|---|---:|---:|---:|")
    for name, kernel, py, nat in cases:
        tp = median_ms(py, args.repeat)
        if name.startswith("hash"):
            tp *= 10  # measured on a tenth of the values (pure Python)
        tn = median_ms(nat, args.repeat)
        print(f"| {name} | `{kernel}` | {tp:.2f} | {tn:.2f} | {tp / tn:.0f}× |", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
