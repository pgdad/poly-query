# PolyQuery native kernels — x86-64 assembly

All 20 kernels of `include/pq_kernels.h` (ABI v1, revision 1), hand-written
in GNU `as` (AT&T syntax). The `.S` files are run through the C preprocessor,
which pulls in the shared include files (`*.h`) and the `#define` constants.
That is the 16 original kernels plus the four 128-bit kernels of change
request CR-4 (`filter_i128`, `count_i128`, `sum_i128`, `minmax_i128`; see
[128-bit kernels (CR-4)](#128-bit-kernels-cr-4)). There are three complete
variants:

| variant source | variant | ISA | kernels |
|---|---|---|---|
| `pqk_x86_scalar.S` | `x86_scalar` | baseline x86-64 (GPRs + SSE2 scalar `addsd/minsd/maxsd` only; no POPCNT/BMI) | 20/20 |
| `pqk_x86_avx2.S` | `x86_avx2` | AVX2 + BMI1 + BMI2 + POPCNT | 20/20 |
| `pqk_x86_avx512.S` | `x86_avx512` (optional) | AVX-512 F/BW/VL/DQ (+BMI/POPCNT) | 20/20 |

The AVX2 variant was then optimized for throughput (1.3x geometric mean
over the 17 benchmark workloads with L3-resident data, up to 2x per kernel,
bit-identical results); see
[Throughput optimization of `x86_avx2`](#throughput-optimization-of-x86_avx2-kernel-optimize-task).
The sections after it describe the code as of CR-5 and are annotated where
the AVX2 code has changed since.

Change request CR-5 restructured the three sources without changing
behaviour. Building blocks are now defined once in shared include files, and
every kernel has the same documented shape and a header comment. See
[Source structure (CR-5)](#source-structure-cr-5) for the module map, the
list of shared building blocks with their users, and how "no behaviour
change" was verified. The machine code of 138 of the 140 functions is
identical to before CR-5; the two exceptions are the operand order of one
`add` in the scalar i128 jump-table dispatch.

The dispatcher finds the variants through their global symbols
`pqk_<variant>_<kernel>`. On this host it picks `x86_avx512` by default, and
`PQ_KERNELS_VARIANT=avx2|scalar|reference` overrides that. The AVX-512 file
uses only instructions from the F/BW/VL/DQ subsets, because those are the only
ones the dispatcher checks. It does **not** use VPOPCNTDQ, CD, VBMI2 or the
like, even though this Zen 5 has them.

`verify/` holds extra test and verification tools (C, Python and one test
trampoline). They are **not** part of the library: the Makefile only
assembles `x86_64/*.S`, and `verify/` is not matched by that wildcard. See
[Verification](#verification).

## Build, test, benchmark

```bash
make -C native-kernels test        # differential tests (native + ASan/UBSan) + AArch64 cross (reference only)
make -C native-kernels bench       # micro-benchmarks, JSON lines in build/x86_64/bench.jsonl
sh native-kernels/x86_64/verify/run.sh   # extra checks: guard pages, edge cases, ABI, CR-5 structure (run from anywhere)
BASE=16e68a2 sh native-kernels/x86_64/verify/run.sh   # ... plus machine-code comparison with the pre-CR-5 sources
python3 -I native-kernels/x86_64/verify/structure_check.py -v   # CR-5 structure + per-kernel clobber lists
python3 -I native-kernels/x86_64/verify/disasm_compare.py 16e68a2 -R c_sign_q=c_i64min
python3 native-kernels/x86_64/verify/bench_table.py native-kernels/build/x86_64/bench.jsonl
sh native-kernels/x86_64/verify/cmp.sh [kernel]           # AVX2 before/after (vs 424e5a4), interleaved, pinned
```

The Makefile lists only the `*.S` files as prerequisites, not the `*.h`
include files. After editing a header, run `make -C native-kernels clean`
(or touch the `.S` files) before `make test`.

Result of `make -C native-kernels test` on the final commit:

```
available variants: reference,x86_avx512,x86_avx2,x86_scalar (default: x86_avx512)
  x86_scalar  20/20 kernels  PASS
  x86_avx2    20/20 kernels  PASS
  x86_avx512  20/20 kernels  PASS
kernel tests: 3 variant(s) tested, 0 failure(s)      (native, 3000 iterations)
... same with -fsanitize=address,undefined (1500 iterations)
```

The ASan/UBSan run prints one `runtime error: load of misaligned address` at
`tests/kernel_test.c:69`. That load is in the test program's own C code
(`data[rnd_below(n)]` on a deliberately misaligned buffer), not in a kernel.
It is non-fatal, and it was there before any assembly existed.

## Throughput optimization of `x86_avx2` (kernel-optimize task)

This change makes the AVX2 variant faster on the kernel micro-benchmark
(`make -C native-kernels bench`, n = 4,194,304, 17 workloads) with
bit-identical results. Only `pqk_x86_avx2.S`, `pqk_x86_avx2.h` and new
AVX2-only tables in `pqk_x86_consts.h` changed. The scalar and AVX-512
machine code is **byte-for-byte identical** to the starting point
(`verify/disasm_compare.py 424e5a4` reports differences only in AVX2
symbols), so the scalar algorithms are untouched.

### Results (measured, ns per element, lower is better)

Before = commit `424e5a4` (start of this task), after = final commit. Both
binaries were built from `verify/vbench.c` (the same 17 workloads and data
as `tests/kernel_bench.c`, restricted to `x86_avx2`) and run **alternately**
by `verify/cmp.sh`, pinned to one CPU. Every run takes the median of 15
repetitions like `make bench`. The left half of each table is the median of
9 such runs, the right half ("min") the minimum over all repetitions. The
minimum is the more robust figure here: other jobs were running on this
machine (these final runs were made at load average 4–6, earlier runs during
development at 7–11), so a run can be slowed down at random, never sped up.
Unchanged code (`sum_f64`, `bitmap_and`, `compare_i64`) moves by up to ±5 %
between runs; a dedicated 12-round alternating run of `compare_i64` gave
0.134 → 0.127 (min).

**Pinned to CPU 2 (V-cache CCD, columns L3-resident; this is where an unpinned run usually lands when the machine is idle)**

| kernel | before | after | speedup | before (min) | after (min) | speedup (min) |
|---|---|---|---|---|---|---|
| filter_i64_sel10 | 0.1546 | 0.1114 | 1.39x | 0.1515 | 0.1091 | 1.39x |
| filter_i64_bitmap | 0.0769 | 0.0736 | 1.04x | 0.0709 | 0.0615 | 1.15x |
| count_i64_between | 0.0685 | 0.0537 | 1.28x | 0.0586 | 0.0506 | 1.16x |
| sum_i64 | 0.0732 | 0.0540 | 1.36x | 0.0698 | 0.0506 | 1.38x |
| sum_i64_validity | 0.1179 | 0.0808 | 1.46x | 0.1130 | 0.0713 | 1.59x |
| sum_f64 | 0.0538 | 0.0554 | 0.97x | 0.0509 | 0.0531 | 0.96x |
| minmax_i64 | 0.1075 | 0.0549 | 1.96x | 0.1037 | 0.0527 | 1.97x |
| bitmap_and | 0.0025 | 0.0025 | 1.00x | 0.0024 | 0.0024 | 1.00x |
| bitmap_popcount | 0.0020 | 0.0010 | 2.00x | 0.0020 | 0.0010 | 1.95x |
| hash_i64 | 0.3675 | 0.2433 | 1.51x | 0.3536 | 0.2243 | 1.58x |
| compare_i64 | 0.1581 | 0.1638 | 0.97x | 0.1302 | 0.1365 | 0.95x |
| group_sum_i64_1024 | 0.4310 | 0.2843 | 1.52x | 0.4233 | 0.2670 | 1.59x |
| gather_i64 | 0.7799 | 0.7440 | 1.05x | 0.6801 | 0.6684 | 1.02x |
| filter_i128_sel10 | 0.3141 | 0.2251 | 1.40x | 0.2566 | 0.1830 | 1.40x |
| count_i128_between | 0.2297 | 0.1716 | 1.34x | 0.1885 | 0.1452 | 1.30x |
| sum_i128 | 0.1828 | 0.1537 | 1.19x | 0.1463 | 0.1337 | 1.09x |
| minmax_i128 | 0.2453 | 0.1724 | 1.42x | 0.2083 | 0.1361 | 1.53x |
| **geometric mean** | | | **1.31x** | | | **1.32x** |

**Pinned to CPU 10 (32 MB L3 CCD, columns stream from DRAM)**

| kernel | before | after | speedup | before (min) | after (min) | speedup (min) |
|---|---|---|---|---|---|---|
| filter_i64_sel10 | 0.2679 | 0.2128 | 1.26x | 0.2071 | 0.1664 | 1.24x |
| filter_i64_bitmap | 0.1757 | 0.1794 | 0.98x | 0.1440 | 0.1386 | 1.04x |
| count_i64_between | 0.1681 | 0.1650 | 1.02x | 0.1423 | 0.1376 | 1.03x |
| sum_i64 | 0.1775 | 0.1653 | 1.07x | 0.1508 | 0.1428 | 1.06x |
| sum_i64_validity | 0.2112 | 0.1874 | 1.13x | 0.1760 | 0.1389 | 1.27x |
| sum_f64 | 0.1615 | 0.1617 | 1.00x | 0.1100 | 0.1085 | 1.01x |
| minmax_i64 | 0.2098 | 0.1754 | 1.20x | 0.1522 | 0.1321 | 1.15x |
| bitmap_and | 0.0026 | 0.0025 | 1.04x | 0.0023 | 0.0022 | 1.04x |
| bitmap_popcount | 0.0019 | 0.0010 | 1.90x | 0.0018 | 0.0009 | 1.95x |
| hash_i64 | 0.5399 | 0.5021 | 1.08x | 0.4681 | 0.4256 | 1.10x |
| compare_i64 | 0.3791 | 0.3722 | 1.02x | 0.3068 | 0.3024 | 1.01x |
| group_sum_i64_1024 | 0.5070 | 0.4387 | 1.16x | 0.4898 | 0.3685 | 1.33x |
| gather_i64 | 2.8157 | 1.7976 | 1.57x | 2.3531 | 1.5326 | 1.54x |
| filter_i128_sel10 | 0.5566 | 0.4733 | 1.18x | 0.4178 | 0.3940 | 1.06x |
| count_i128_between | 0.4503 | 0.4086 | 1.10x | 0.3692 | 0.3412 | 1.08x |
| sum_i128 | 0.4397 | 0.3960 | 1.11x | 0.3421 | 0.3438 | 1.00x |
| minmax_i128 | 0.4520 | 0.3802 | 1.19x | 0.3617 | 0.3400 | 1.06x |
| **geometric mean** | | | **1.16x** | | | **1.16x** |

**Pinned to CPU 2, n = 32,768 (L2-resident: compute speed), minimum of 5 x 2001 repetitions**

| kernel | before | after | speedup |
|---|---|---|---|
| filter_i64_sel10 | 0.1410 | 0.0954 | 1.48x |
| filter_i64_bitmap | 0.0514 | 0.0511 | 1.01x |
| count_i64_between | 0.0556 | 0.0480 | 1.16x |
| sum_i64 | 0.0657 | 0.0486 | 1.35x |
| sum_i64_validity | 0.1061 | 0.0682 | 1.56x |
| sum_f64 | 0.0361 | 0.0373 | 0.97x |
| minmax_i64 | 0.0988 | 0.0504 | 1.96x |
| bitmap_and | 0.0012 | 0.0012 | 1.00x |
| bitmap_popcount | 0.0021 | 0.0015 | 1.40x |
| hash_i64 | 0.3366 | 0.2045 | 1.65x |
| compare_i64 | 0.0786 | 0.0752 | 1.05x |
| group_sum_i64_1024 | 0.4070 | 0.2737 | 1.49x |
| gather_i64 | 0.2094 | 0.2085 | 1.00x |
| filter_i128_sel10 | 0.2314 | 0.1397 | 1.66x |
| count_i128_between | 0.1617 | 0.1003 | 1.61x |
| sum_i128 | 0.0972 | 0.0966 | 1.01x |
| minmax_i128 | 0.1853 | 0.1168 | 1.59x |
| **geometric mean** | | | **1.32x** |

**Official `make -C native-kernels bench` after the change** (unpinned, one
run at load average ≈ 5; it landed on the DRAM-bound CCD, as did the original
official run in [Benchmark results](#benchmark-results), whose AVX2 column is
repeated for reference). Runs made at different times on this shared host
differ by ±10 % for unchanged code (compare the reference and AVX-512
columns with the original tables), so the pinned, interleaved tables above
are the before/after evidence.

| kernel | reference | x86_scalar | x86_avx2 (original official run) | x86_avx2 (now) | x86_avx512 |
|---|---|---|---|---|---|
| filter_i64_sel10 | 0.8095 | 0.3516 | 0.1972 | 0.1701 | 0.1611 |
| filter_i64_bitmap | 2.6459 | 0.2518 | 0.1364 | 0.1387 | 0.1427 |
| count_i64_between | 0.3787 | 0.2863 | 0.1364 | 0.1258 | 0.1255 |
| sum_i64 | 0.2337 | 0.2329 | 0.1376 | 0.1329 | 0.1117 |
| sum_i64_validity | 0.3865 | 0.3391 | 0.1543 | 0.1386 | 0.1229 |
| sum_f64 | 0.3757 | 0.3831 | 0.1247 | 0.1217 | 0.1001 |
| minmax_i64 | 0.5489 | 0.5484 | 0.1533 | 0.1310 | 0.1172 |
| bitmap_and | 0.0024 | 0.0030 | 0.0024 | 0.0025 | 0.0024 |
| bitmap_popcount | 0.1122 | 0.0136 | 0.0018 | 0.0009 | 0.0008 |
| hash_i64 | 0.6103 | 0.5894 | 0.4572 | 0.4288 | 0.4094 |
| compare_i64 | 2.7654 | 0.3368 | 0.3095 | 0.3031 | 0.3157 |
| group_sum_i64_1024 | 0.7615 | 0.6065 | 0.4717 | 0.3632 | 0.4839 |
| gather_i64 | 2.7500 | 2.5581 | 2.2942 | 1.4716 | 2.2950 |
| filter_i128_sel10 | 1.1020 | 0.4528 | 0.3731 | 0.3841 | 0.3946 |
| count_i128_between | 0.6213 | 0.3828 | 0.3115 | 0.3367 | 0.4133 |
| sum_i128 | 0.4789 | 0.3718 | 0.3031 | 0.3353 | 0.3382 |
| minmax_i128 | 0.8179 | 0.5311 | 0.3239 | 0.3273 | 0.3617 |

Reading the numbers:

* On the V-cache CCD the 32 MB columns are L3-resident. Everything with real
  compute per row got faster: 1.3–2× for most kernels. `sum_f64`,
  `bitmap_and` and `filter_i64_bitmap` were already at the L3 bandwidth limit
  (≈ 0.05 ns per 8-byte row), and `compare_i64` reads two columns
  (16 bytes per row) and is close to that limit too, so they did not change.
* On the DRAM-bound CCD most 8-byte streaming kernels are limited by
  memory bandwidth (≈ 0.14–0.17 ns per row), so the compute savings mostly
  disappear there. The exceptions are `bitmap_popcount` (1.9×; its 512 KB
  bitmap stays in L2), `gather_i64` (software prefetch: 1.55×), the
  compute-heavier `group_sum_i64` (1.2–1.3×), `filter_i64` (1.25×),
  `sum_i64` with validity, `minmax_i64` and `minmax_i128` (1.1–1.2×).
* The L2-resident run (n = 32,768; 256 KB per 8-byte column, 512 KB per
  128-bit column) shows the compute speed of the kernels without memory
  effects. (`bitmap_*` are only 4 KB at this n and mostly measure call
  overhead.)

### What limits AVX2 on Zen 5 (measured on this host)

All decisions below are based on these numbers, measured with small
dependent / independent instruction loops (cycles at 5.4 GHz):

| instruction (ymm) | latency | throughput per cycle |
|---|---|---|
| `vpaddq`, `vpxor`, `vpand`, `vpor`, `vpunpck*qdq` | 2 | 4 |
| `vpcmpgtq`, `vpcmpeqq`, `vblendvpd` | 2 | 2 |
| `vpsrlq`/`vpsllq`, `vpsllvq` | 2 | 2 |
| `vpmuludq`, `vpmulld` | 3 | 2 (shared) |
| `vpshufb`, `vpsadbw`, `vmovmskpd`, `vtestpd` | – | 2 |
| scalar `popcnt` / `imul r64` | 1 / 3 | ≈ 5 / ≈ 2.8 |

* **Simple vector integer ops have 2-cycle latency on Zen 5.** Every loop
  whose accumulator is updated by a chain of two such ops (compare → blend in
  `minmax`, add → add in the sums) was latency-bound with the original two
  accumulator sets. Four sets fix that.
* **Compares, blends, shifts, multiplies, `vpshufb` and `vmovmskpd` issue
  only twice per cycle** (on two pipes; multiplies and shifts use different
  pipes, compares and blends partly overlap), while adds and logic ops issue
  4 per cycle. So the number of compare/blend/shift ops per row decides most
  compute-bound loops, and replacing two compares by `vpsubq` + one compare
  (range tests) pays off.
* The integer side (6 ALUs, scalar `popcnt`, `imul`) runs in parallel with
  the vector pipes; `bitmap_popcount` and `hash_i64` use both at once.
* L3 streams at ≈ 0.05 ns per 8-byte row (≈ 150 GB/s per core) on the
  V-cache CCD; L2 at ≈ 0.035. A kernel is only as fast as the slower of its
  compute and its memory stream, so compute below ≈ 0.05 ns/row no longer
  shows at bench size.

### The optimizations, per kernel

* **`bitmap_popcount` (2×).** 640 bytes per iteration: 512 bytes go through
  a **Harley-Seal carry-save adder tree** on ymm (ones/twos/fours/eights
  vectors absorb 16 inputs with `vpxor`/`vpand`/`vpor`, which issue 4 per
  cycle; only the "sixteens" vector is popcounted with the nibble-LUT
  `vpshufb` + `vpsadbw` method), and at the same time 128 bytes go through
  scalar `popcnt` on the integer pipes. The CSA is ordered so that each
  running vector sees one dependent op per step (2-cycle latency).
  L2: `popcnt` loop 0.0018 ns/bit, `vpshufb` only 0.0014, Harley-Seal
  0.0011, hybrid 0.0010.
* **`minmax_i64` (2×).** Four accumulator sets instead of two (the
  compare → blend chain is 4 cycles), then a **quick reject per 64-row
  block**: the current overall min/max `G` is the value of an already
  processed row, so a row with `gmin < x < gmax` cannot change the result.
  As an unsigned range test that is one `vpsubq` + one `vpcmpgtq` per 4 rows
  (`(x − (gmin+1)) <u gmax − gmin − 1`), instead of 2 compares + 2 blends.
  If any row of the block is outside, the block runs through the exact
  min/max code and the test is skipped for the next 8, 16, … 1024 blocks
  (exponential back-off, reset after a success), so sorted or otherwise
  update-heavy data pays < 1 % for the attempts. `G` is recomputed from the
  lanes only before an attempt that follows a full block.
* **`sum_i64` (1.4×), with validity (1.5×).** New exactness argument with
  fewer ops: bias every value, `x' = x ^ 2^63 = x + 2^63` is an unsigned
  64-bit number; per lane `S = Σx' mod 2^64` and `U = Σ(x' >>> 32)` give the
  exact unsigned lane sum `U·2^32 + (S − U·2^32 mod 2^64)`; the fold
  subtracts `c·2^63` (`c` = rows added). That is 4 vector ops per 4 rows
  (xor, add, shift, add) instead of 5, and only one shift instead of two.
  Four accumulator sets. With validity, invalid rows must add exactly 0
  (`x'' = (x ^ 2^63) & mask`, `c` = number of valid rows = popcnt of the
  validity words); the lane mask of 4 rows is loaded from a 16-entry table
  (`nibmask`) indexed with `rorx` + `and` on the integer side, which replaces
  `vpsllvq` + `vpcmpgtq` (two ops on the busy pipes) per 4 rows.
* **`hash_i64` (1.5×).** `k·C mod 2^64 = lo·clo + ((lo·chi + hi·clo) mod
  2^32) << 32`: one `vpmulld` against the dword-swapped constant
  `(chi, clo)` yields both cross products at once, so a 64-bit multiply is 2
  multiplies + 1 shift + 3 adds/ands instead of 3 multiplies + 2 shifts +
  2 adds. On
  top of that each 24-row iteration hashes 16 rows on the vector unit (4
  vectors, interleaved step by step because one fmix64 is a ~30-cycle chain)
  and 8 rows with scalar `imul` on the integer unit, in parallel. L2: 0.34
  (original) → 0.30 (`vpmulld` form alone) → 0.21 ns/row (hybrid).
* **`group_sum_i64` (1.5×).** The two scalar read-modify-writes per row
  (`sums[g]`, `counts[g]`) were the bottleneck. Without validity, with
  counts, `ngroups ≤ 1024` and `n ≥ 4·ngroups`, `{sum, count}` pairs are
  accumulated in a 16-byte-per-group table on the stack (zeroed,
  page-probed, ≤ 20 KB) with **one `vpaddq` read-modify-write of `(x, 1)` per
  row**, 4 rows per iteration. There is no per-row overflow test: the table is
  only committed if no addition can wrap **in any order**, i.e.
  `n · max|x| < 2^62` (`max|x|` bounded by the OR of `x ^ sign(x)`, tracked
  on the fly) and every touched `sums[g]` is in `[−2^62, 2^62)`. Then all
  partial sums stay inside int64, the reference would not have wrapped
  either, and the result (`PQK_OK`, sums, counts) is identical to it.
  Otherwise the table is discarded (`sums`/`counts` are untouched up to that
  point) and the original exact row-order loop runs, so the overflow flag
  is always exactly the reference's.
* **`gather_i64` (DRAM: 1.5×).** Random rows are latency-bound, and the
  out-of-order window alone keeps too few misses in flight. Rows
  `j+128 … j+135` are now software-prefetched while rows `j … j+7` are
  loaded (the look-ahead index loads stop 128 rows before the end of `idx`).
  Distances 32…512 were tried: 256 is best from DRAM but costs ~10 % when the
  column is L3-resident, 128 is neutral there. When the rows are
  cache-resident the extra loads cost ~40 %, so prefetching is only enabled
  if 16 indices sampled across `idx` reach 2^19 (a span ≥ 4 MB).
* **`filter_i64` (1.4×).** Index emission for full blocks with a hit: the
  former `pdep` + `imul` + `pext` + `vmovq` per 8 rows became one
  `vpmovzxbd` load from a 2 KB table (`idx8`) that holds the packed bit
  positions of every byte value. L2: 0.146 → 0.098 ns/row.
* **`count_i64` BETWEEN (1.15×), also `filter_i64`/`filter_i64_bitmap`.**
  With `a ≤ b`, `x ∉ [a,b] ⇔ (x − a) >u (b − a) ⇔ (x − (a^2^63)) >s
  ((b−a)^2^63)`: one `vpsubq` + one `vpcmpgtq` instead of two compares and a
  `vpor`. The driver switches to this "kind 4" through a pseudo-operator
  index (7) in the jump tables; `a > b` keeps the old form (empty range).
* **`filter_i128` (1.4×), `count_i128` BETWEEN (1.3×).** Three changes:
  * the `idx8` index emission (as `filter_i64`);
  * BETWEEN with `a ≤ b` as one unsigned 128-bit range test
    (`d = x − a` with the borrow from a biased compare, then
    `d >u b − a`): 4 compares + 1 blend per 4 rows instead of 6 + 2;
  * a **high-word fast path** per 64-row block for LT/LE/GT/GE (mask
    routines `vop128f_*`) and for the LT/GT/BETWEEN direct counters: a row
    whose high word differs from the bound(s) is decided by the high word
    alone (2 compares per 4 rows instead of 3 compares + blend + low-word
    de-interleave and bias). If a row's high word equals a bound, the block is
    recomputed exactly, with the same exponential back-off as `minmax`
    (e.g. small values with all high words 0 fall back at < 1 % cost).
* **`minmax_i128` (1.5×).** The same block quick reject as `minmax_i64`, on
  the high words: if every row has `gminH < hi < gmaxH` (one `vpsubq` +
  one `vpcmpgtq` per 4 rows), the block is skipped. It must use the *global*
  min/max, not the per-lane accumulators: with the bench's validity pattern
  `0xF7` one lane of one set only ever sees invalid rows, so its accumulator
  stays at the start value and a per-lane test would never pass.
* **`sum_i128`.** Four accumulator sets and the validity lane masks from a
  2-row table (`pairmask`), as in `sum_i64`. At bench size it is
  memory-bound (16 bytes per row), so this shows only in L2.

### Rejected experiments

* `minmax_i64`: a tournament tree (pairwise min/max before touching the
  accumulators, 3.5 instead of 4 compare/blend ops per 4 rows) and a lazy
  per-32-row test against the per-set accumulators — no faster in L3 than
  four plain sets. Superseded by the block quick reject with the range test.
* `filter_i64`: per-step row bases from a table (to break the `ymm4 += 8`
  chain) and straight-line `tzcnt`/`blsr` emission with 4-byte stores for
  blocks with ≤ 12 hits — both no faster; the emission seems limited by its
  stores.
* `hash_i64`: vector-only variants (the `vpmulld` form, a 3-multiply
  `vpslldq` form, 2 or 4 interleaved vectors) all stayed at 0.29–0.31
  ns/row in L2; only adding the scalar stream helped (0.21).
* `bitmap_popcount`: unrolled scalar `popcnt` (0.0014), `vpshufb` only
  (0.0014), Harley-Seal in the textbook order (0.0017, latency-bound on the
  "ones" chain).
* `group_sum_i64`: 2 or 4 sub-tables (even/odd rows) to shorten
  store-to-load forwarding chains — slower (more L1 footprint).
* Software prefetch for the sequential kernels (`sum_i64`, `compare_i64`,
  `sum_i128`) — no measurable gain under the noise; not used.
* `compare_i64`: 32-byte-aligned inputs would make the loop ≈ 15 % faster
  (fewer split loads), but two independently aligned inputs plus a
  bit-aligned output make a peel impractical; the kernel is near the L3
  limit anyway.

### Verification of the changes

* `make -C native-kernels test`: 20/20 kernels PASS for `x86_scalar`,
  `x86_avx2` and `x86_avx512` (native and ASan/UBSan).
* `verify/run.sh` (guard pages, edge cases, small-chunk builds, ABI check,
  structure/clobber check) passes. It now also runs **`verify/stress.c`**:
  a randomized differential test with sizes up to 70,000 rows and 20,000
  bitmap bytes (the stock tests stop at 5,000 rows / 200 bytes, so they
  never reach the 640-byte popcount loop or many 64-row block paths),
  adversarial columns (sorted, constant, extremes, alternating, high words
  equal to the bounds, ties with the current extreme), extreme constants
  (`INT64_MIN/MAX`, `a > b`, `a == b`), extreme initial group sums, every
  buffer against a `PROT_NONE` guard page, and the overflow flag of
  `group_sum` compared exactly. It is also built with tiny sum chunks.
* Mutation checks: the stress test caught every deliberately broken
  variant that was tried — the popcount operator-precedence bug during
  development, the `minmax_i128` quick reject reading low instead of high
  words, the `group_sum` init-bound check disabled, and the `filter_i128`
  fast path treating "equal" as decided.
* `verify/disasm_compare.py 424e5a4`: scalar and AVX-512 identical.
* ABI: the new code follows the same rules as before (see [ABI](#abi)).
  `group_sum_i64` is the only kernel with a larger stack frame: it moves
  `rsp` down page by page (touching each page) and restores it from `rbp`.
  `vcnt128_k4` uses 32 bytes of stack for a constant. Neither uses memory
  below `rsp`.

### Tools added for this task (`verify/`, not part of the library)

```bash
sh native-kernels/x86_64/verify/cmp.sh [kernel-substring]   # before/after, interleaved, pinned
CPU=10 ROUNDS=9 BASE=<rev|dir> sh native-kernels/x86_64/verify/cmp.sh
native-kernels/build/verify/stress [iterations] [seed] [variant]   # built by run.sh
```

`vbench.c` is `tests/kernel_bench.c` with a variant and kernel filter.
`cmp.sh` builds it from a git revision (default `424e5a4`) or a source
directory and from the working tree, runs both alternately and prints the
median of the run medians and the minimum over all repetitions.

## Source structure (CR-5)

CR-5 (`spec/changes/kernel-refactor.md`) asks for building blocks defined
once, a uniform kernel shape, per-kernel header comments and this module map.
The refactoring keeps every instruction of every kernel. Code was only
moved into macros and include files, labels were renamed, and comments were
added. So results and performance are unchanged by construction, and that
claim is checked mechanically (see
[How "no behaviour change" was verified](#how-no-behaviour-change-was-verified)).

### Module map

**Before CR-5** (commit `16e68a2`): three self-contained files, 6896 lines.
Each file had its own copies of the shared machinery.

| file | lines (code only¹) | contents |
|---|---|---|
| `pqk_x86_scalar.S` | 1724 (1424) | own `FUNC/LFUNC/ENDF` macros; `popcnt64` helper **and** a second inline SWAR popcount (`POPC`); `lvp`; `sop_*`/`scmp_*` mask routines and tables; `PRED_DRIVER`; the 20 kernels with mixed label styles (`.Lsi_*`, `.Lgs_*`, `1:`…); i128 predicate macros |
| `pqk_x86_avx2.S` | 2682 (2268) | own `FUNC/LFUNC/ENDF`, `lvp`, `HSUMQ`, rodata tables (`shc`, `c_pinf`, …); `vop_*/vcnt_*/vcmp_*`; `PRED_DRIVER`; the 20 kernels; i128 tables, `VG128`/`NIBFIX`/`P128_DRIVER`, `SMIN128/SMAX128`, `fold128` |
| `pqk_x86_avx512.S` | 2490 (2109) | own `FUNC/LFUNC/ENDF`, `lvp`, `HSUMZ`, rodata tables (again `c_pinf`, `c_ninf`, `c_hibias`, …); `kop_*/kcnt_*/kcmp_*`; `PRED_DRIVER`; the 20 kernels; i128 macros, `P128_DRIVER`, `SMIN128/SMAX128` (copy of AVX2), `fold512` |
| `verify/` | 384 | guard-page, edge-case and ABI test tools |

Code that existed more than once before CR-5: the symbol macros (3×), `lvp`
(3×), operator check + jump-table dispatch (18×), the 64-row block driver
loop (6×), index emission (6×), the partial bitmap store (6×), the sum
overflow test (6×), SWAR popcount (2× in the scalar file), scalar `fmix64`
(2×), `SMIN128/SMAX128` (2×), the scalar half of the i128 lane fold (2×), the
2^127 bias removal (2×), the signed-zero fix-up (2×), `group_sum` pass 2
(3×), `gather_i64` (3×), the byte tail of the bitmap ops (2×), index
compress (2× per SIMD file), and the constants `c_pinf`/`c_ninf`/`c_hibias`,
`INT64_MIN`, `SUM_CHUNK_ROWS`, `SUM128_CHUNK_ROWS` (2× each).

**After CR-5**: three variant sources that contain only kernels and the
instantiation of their helpers, plus six include files.

| file | lines (code only¹) | contents | included by |
|---|---|---|---|
| `pqk_x86_common.h` | 618 (387) | ABI constants (status, operators, `ARG7`, driver modes); symbol directives `FUNC LFUNC ENDF OBJ ENDOBJ`; `PROLOGUE EPILOGUE VRET`; operator validation and dispatch `OP_CHECK OP_INVALID JTAB_LOAD JUMPTABLE OPTABLE CMPTABLE`; validity extraction `DEFINE_LVP VBIT_* VWORD_BLOCK`; 64-row driver pieces `DRV_* EMIT_IDX_BITS STORE_BITS_*`; GPR parts `JNE_SEXT FMIX64 LOWMASK BYTE_BITOP GATHER_I64 GSUM_PASS2`. Also documents the kernel skeleton and the label scheme. Includes `pqk_x86_consts.h`. | all three |
| `pqk_x86_consts.h` | 191 (126) | every constant value (`#define C_*`) and every rodata table (emit macros `TAB_*`) | via `common.h` |
| `pqk_x86_simd.h` | 171 (109) | shared by AVX2 and AVX-512: `HSUMQ HSUMZ F64_ZERO_FIXUP SMIN128 SMAX128 FOLD_LANES128 UNBIAS192`, chunk sizes | avx2, avx512 |
| `pqk_x86_scalar.h` | 410 (304) | scalar blocks used by ≥ 2 scalar kernels: SWAR popcount, `sop_*` generator, `PRED_DRIVER`, `BITOP`, i128 `P128*` | scalar |
| `pqk_x86_avx2.h` | 632 (475) | AVX2 blocks used by ≥ 2 AVX2 kernels: `VPRED ROWPRED VOP VCNT EMIT_IDX_COMPRESS8 VDRIVER VBITOP`, i128 `LTX GTX VG128 NIBFIX VOP128 VCNT128 VDRIVER128` | avx2 |
| `pqk_x86_avx512.h` | 666 (494) | AVX-512 blocks used by ≥ 2 AVX-512 kernels: `LANES8 PEELMASK GROUPMASK KPRED KOP KCNT EMIT_IDX_COMPRESS16 KDRIVER ZBITOP`, i128 `LG128 LGU128 KFIX GLANES KP128 KOP128 KCNT128 KDRIVER128` | avx512 |
| `pqk_x86_scalar.S` | 1098 (742) | section 1: helper/table instantiation (`popcnt64`, `lvp`, `sop_*`, `sop_table`); section 2: the 20 kernels with header comments, plus the scalar-only kernel-private blocks (`SCMP`, `SADD128/SVADD128`, `mm128_upd/MM128_ROW`) | — |
| `pqk_x86_avx2.S` | 1718 (1266) | section 1: tables, `lvp`, `vop_* vcnt_* vop128_* vcnt128_*` + jump tables; section 2: the 20 kernels, plus kernel-private blocks (`VCMP`, `SACC/SZERO/SFOLD`, `MMI_STEP`, `MUL64/VFMIX`, `fold128/SV128`, `MMG128`) | — |
| `pqk_x86_avx512.S` | 1550 (1132) | section 1: tables, `lvp`, `kop_* kcnt_* kop128_* kcnt128_*` + jump tables; section 2: the 20 kernels, plus kernel-private blocks (`KCMP`, `MULA`, `ZFMIX`, `fold512/ZS128/DOUBLE2`, `ZMM128/ZTAIL`) | — |
| `verify/` | 1012 | as before, plus `disasm_compare.py` (213) and `structure_check.py` (409); `run.sh` runs them | — |

¹ Code only: non-blank lines after removing comments
(`cpp -P -fpreprocessed`). Assembly code went from 5801 to 5035 lines. The
total grew (6896 → 7054) because every kernel now has a full header comment
and every block has a usage comment.

Rules for the include files (stated at the top of `pqk_x86_common.h`):

* **Headers emit no bytes.** They only define `#define` constants and gas
  macros. Every instruction and table of a variant comes from a statement in
  its `.S` file, usually a macro invocation. File-local helpers (`lvp`,
  `popcnt64`, mask routines, `fold128`) and tables (`shc`, `c_pinf`, …) are
  therefore *defined* once in source but *emitted* once per variant object
  that uses them, as local symbols. That keeps each variant object
  self-contained. The library's exported symbol set and the variant/kernel
  set are unchanged, and no cross-file references were introduced.
* **Names end in `.h`.** The Makefile assembles every `x86_64/*.S` as a
  translation unit, so headers must not end in `.S`. They are pulled in with
  cpp `#include`, so `#define` constants work inside macro bodies.
* **Constants before use.** `pqk_x86_common.h` includes `pqk_x86_consts.h`
  before any macro. Otherwise cpp would leave an unknown constant name in a
  macro body, and gas would silently turn it into an undefined symbol.
  `disasm_compare.py` rejects objects with undefined symbols; this
  actually happened once during the refactoring.
* **ISA switch.** Blocks with a baseline and a BMI form (`LOWEST_IDX`,
  `CLEAR_LOWEST`, `EMIT_IDX_BITS`, `GSUM_PASS2`) test the gas symbol
  `PQK_BMI`. Each variant sets it once (`scalar`: 0, `avx2`/`avx512`: 1).
* **Placement.** A block lives in the most specific header that covers all
  its users: all variants → `common.h`, both SIMD variants → `simd.h`,
  several kernels of one variant → `pqk_x86_<variant>.h`. Blocks used by a
  single kernel stay next to that kernel in the `.S` file, so a kernel can
  be read and changed without opening the others.

### Kernel skeleton and label scheme

Every kernel of every variant follows one skeleton. Each part is marked with
the same comment tag in the code. When the part is in a shared body macro
such as `PRED_DRIVER` or `VBITOP`, the tag is in that macro.

| tag | part | typical content |
|---|---|---|
| `[check]` | argument check / empty input | `OP_CHECK` (invalid op → `(size_t)-1` before any memory is touched), `n == 0`, `PROLOGUE`, accumulator setup |
| `[main]` | main (vector) loop(s) | full steps, or full 64-row blocks; often two flavours: no validity (`_main`) and validity (`_vmain`) |
| `[tail]` | rows left over by the main loop | 1–3 / 1–7 single rows, masked groups, or the final partial 64-row block (`_tail`, `_vtail`) |
| `[result]` | result | lane reduction, output stores, status (`JNE_SEXT` for sums), `EPILOGUE`, `ret`/`VRET` |

The tags appear in the order the code is laid out. Two exceptions keep the
original layout, because moving code would change code alignment and branch
layout: `compare_fixed`, which has an out-of-line tail after the `ret`, and
the 64-row block drivers, whose last block goes through the same loop
(marked `[main] + [tail]`).

Labels follow one scheme in all files:

* inside a kernel: `.L<kernel>_<step>`, where `<kernel>` is the ABI name
  without variant prefix. The same step names are used in every variant,
  e.g. `.Lsum_i64_main`, `.Lsum_i64_vmain`, `.Lsum_i64_tail`,
  `.Lsum_i64_vtail`, `.Lsum_i64_result`, `.Lsum_i64_ovf`, `.Lsum_i64_ret`,
  `.Lfilter_i64_inval`;
* inside a helper: `.L<helper>_<step>` (e.g. `.Lvop_eq_part`);
* inside a building-block macro: `.L<block>_<step>\@` (unique per expansion,
  e.g. `.Ldv_part\@`, `.Lgs_vrow\@`), or `.L\k\()_<step>` when the macro is
  a whole kernel body and gets the kernel name `k`;
* no numeric labels (`1:`, `2f`) anywhere. Before CR-5 they were common,
  and one macro had to use `77:` to avoid colliding with them.

Every kernel starts with a header comment block in the same format:

```
/* ========================================================================
 * <C prototype with pqk_x86_<variant>_ name>
 * Args:     argument registers (7th argument: 8(%rsp))
 * Returns:  result register and meaning (status / count / -1)
 * Clobbers: caller-saved registers written, flags
 *           (callee-saved registers saved and restored; stack use)
 * Algorithm: algorithm, shared blocks used, register roles
 * Tail:     tail strategy (no out-of-bounds access)
 * ====================================================================== */
```

The `Clobbers:` lines are checked against the machine code by
`structure_check.py`. Callee-saved registers are listed once per kernel in a
`#define SAVED …`, which `PROLOGUE SAVED` and `EPILOGUE SAVED` use, so the
push and pop sequences cannot drift apart.

### Shared building blocks and their users

Kernel names below are ABI names. "all" = all three variants; `s`/`a2`/`a5`
= scalar / AVX2 / AVX-512.

**`pqk_x86_common.h`** (used by all variants)

| block | what | users |
|---|---|---|
| `PQK_OK … PQK_EINVAL`, `PQK_EQ … PQK_BETWEEN`, `PQK_OP_LAST`, `PQK_CMP_OP_LAST`, `ARG7()`, `MODE_*` | ABI constants (mirror `pq_kernels.h`) | all kernels returning a status or taking an op / 7th argument |
| `FUNC`, `ENDF` | global `@function`, 32-byte aligned, `.size` | all 60 kernels |
| `LFUNC` | local helper `@function`, 16-byte aligned | every helper: `lvp`, `popcnt64`, `sop_* scmp_* sop_false mm128_upd` (s), `vop_* vcnt_* vcmp_* vop128_* vop128f_* vcnt128_* fold128` (a2), `kop_* kcnt_* kcmp_* kop128_* kcnt128_* fold512` (a5) |
| `OBJ`, `ENDOBJ` | rodata `@object` with `.size` | every table (`TAB_*`, `JUMPTABLE`) |
| `PROLOGUE`, `EPILOGUE` | push / reverse-pop of the kernel's `SAVED` list | every kernel that uses callee-saved registers (all except `bitmap_popcount`, `compare_fixed`, `gather_i64` (s); `sum_f64`, bitmap ops, `bitmap_popcount`, `gather_i64` (a2); `sum_f64`, `minmax_i64`, bitmap ops, `bitmap_popcount`, `hash_i64`, `gather_i64` (a5)) |
| `VRET` | `vzeroupper; ret` | every AVX2/AVX-512 kernel exit after vector use (all a2/a5 kernels except both `gather_i64`, which use no vector registers; `compare_fixed` spells out `vzeroupper` / `ret` because its `n == 0` exit jumps between them) |
| `OP_CHECK`, `OP_INVALID` | operator validation (unsigned, so negative ints fail too), `(size_t)-1` exit | `filter_i64`, `filter_i64_bitmap`, `count_i64`, `compare_i64`, `filter_i128`, `count_i128` (all) |
| `JTAB_LOAD` | target of a self-relative jump table entry | the same six kernels (all), plus the direct-counter tables of `count_i64`/`count_i128` (a2, a5) |
| `JUMPTABLE`, `OPTABLE`, `CMPTABLE` | PIC jump tables in ABI operator order | `sop_table` `.L<k>_tab` `scmp_table` (s); `vop_table vcnt_table vcmp_table vop128_table vcnt128_table` (a2); `kop_table kcnt_table kcmp_table kop128_table kcnt128_table` (a5) |
| `DEFINE_LVP` → `lvp` | partial validity word, exactly ceil(len/8) bytes | s: `filter_i64`, `filter_i64_bitmap`, `count_i64`, `sum_i64`, `sum_f64`, `minmax_i64`, `minmax_f64`, `bitmap_popcount`, `group_sum_i64`, `filter_i128`, `count_i128`, `sum_i128`, `minmax_i128`; a2: the same; a5: `filter_i64`, `filter_i64_bitmap`, `count_i64`, `bitmap_popcount`, `group_sum_i64`, `filter_i128`, `count_i128`, `sum_i128`, `minmax_i128` |
| `VBIT_CF` | CF = next validity bit | s: `minmax_i64`, `minmax_f64`, `group_sum_i64`; a2: `minmax_i64`, `minmax_f64`, `minmax_i128` |
| `VBIT_MASK` | 0/-1 mask of the next validity bit | s: `sum_i64`, `sum_f64`, `sum_i128`, `minmax_i128`; a2: `sum_i64`, `sum_f64`, `sum_i128` |
| `VBIT_TEST` | CF = validity bit of row r | a2: `group_sum_i64`; `F64_ZERO_FIXUP` (a2, a5 `minmax_f64`) |
| `VWORD_BLOCK` | full/partial validity word of a scalar 64-row block | s: `sum_i64`, `sum_f64`, `minmax_i64`, `minmax_f64` |
| `DRV_ENTER`, `DRV_LEAVE` | driver entry (op check, saves, output start) / exit | `filter_i64`, `filter_i64_bitmap`, `count_i64`, `filter_i128`, `count_i128` (all) |
| `DRV_ARGS`, `DRV_MASK`, `DRV_VALIDITY`, `DRV_NEXT` | 64-row block loop: mask routine call, `& validity word` | `filter_i64`, `filter_i64_bitmap`, `count_i64` (all); `filter_i128`, `count_i128` (a2, a5) |
| `LOWEST_IDX`, `CLEAR_LOWEST` | bsf / x&(x-1) or tzcnt / blsr (`PQK_BMI`) | `EMIT_IDX_BITS`, `GSUM_PASS2` |
| `EMIT_IDX_BITS` | indices of the set bits of a block mask | `filter_i64`, `filter_i128` (all) |
| `STORE_BITS_FULL`, `STORE_BITS_TAIL` | 8-byte / ceil(len/8)-byte bitmap store | `filter_i64_bitmap`, `compare_i64` (all) |
| `JNE_SEXT` | exact-overflow test (hi ≠ sign extension of lo) | `sum_i64`, `sum_i128` (all) |
| `FMIX_CONSTS`, `FMIX64` | scalar MurmurHash3 finalizer | s `hash_i64`; a2 `hash_i64` (`FMIX_CONSTS` only; its scalar rows use `HROW` with `shrx`) |
| `LOWMASK` | (1 << n) - 1 without bzhi | s: `bitmap_popcount`, `GSUM_PASS2` (baseline path) |
| `BYTE_BITOP` | byte loop of and/or/andnot | `bitmap_and`, `bitmap_or`, `bitmap_andnot` (s, a2) |
| `GATHER_I64` | whole gather body (unroll 4 or 8) | `gather_i64` (all) |
| `GSUM_PASS2` | group_sum scatter-add in row order + overflow flag | `group_sum_i64` (all) |

**`pqk_x86_consts.h`** (constants and tables)

| constant / table | users |
|---|---|
| `C_I64MAX`, `C_SIGN64` | s `minmax_i64`, s `P128_KERNEL`, a2 `minmax_i64`, a2 `minmax_i128`, `UNBIAS192`, tables below |
| `C_F64_PINF`, `C_F64_NINF` | s `minmax_f64`, `TAB_PINF_NINF` |
| `C_FMIX1`, `C_FMIX2` | `FMIX_CONSTS`, `TAB_FMIX_HALVES`, `TAB_FMIX` |
| `C_BITS_EVEN`, `C_BITS_2OF4`, `C_NIBBLE_LO`, `C_BYTE_ONES` | `SWAR_POPCNT` (s), `KFIX`, `DOUBLE2` (a5) |
| `C_NIB_BIT1`, `C_SIGN32` | `NIBFIX`, a2 `group_sum_i64` / `TAB_SIGN_D` |
| `TAB_SHC` → `shc` | a2 `sum_f64`, `minmax_i64`, `minmax_f64` (validity paths) |
| `TAB_SHC128M` | a2 `minmax_i128` |
| `TAB_EIGHT_D`, `TAB_SIGN_D`, `TAB_FMIX_LO`, `TAB_VOP_INV` | a2 `filter_i64`/`filter_i128`; a2 `group_sum_i64`; a2 `hash_i64`; a2 `count_i64`/`count_i128` (8 entries: index 7 = `PQK_OP_RANGE`) |
| `TAB_FMIX_SWAP`, `TAB_NIBMASK`, `TAB_PAIRMASK`, `TAB_IDX8` | a2 `hash_i64` (`vpmulld` constants, high-dword mask); a2 `sum_i64` (4-row validity lane masks); a2 `sum_i128` (2-row masks); a2 `EMIT_IDX_COMPRESS8` (bit positions of each byte value) |
| `TAB_SIGN4`, `TAB_SIXTEEN_Q` | a2 `minmax_i64`, `minmax_i128`, `VOP128F`, `VCNT128_HI` (32-byte 2^63 operand); a2 `VCNT128_HI` |
| `TAB_IOTA16`, `TAB_SIXTEEN_D` | a5 `filter_i64`, `filter_i128` |
| `TAB_FMIX`, `TAB_I64MAX`, `TAB_NIB_LUT`, `TAB_0F`, `TAB_IDX_EVEN_ODD`, `TAB_KINV128` | a5 `hash_i64`; a5 `minmax_i64`/`minmax_i128`; a5 and a2 `bitmap_popcount` (2); a5 `minmax_i128`; a5 `count_i128` |
| `TAB_PINF_NINF` | `minmax_f64` (a2, a5) |
| `TAB_I64MIN` → `c_i64min` | a2 `filter_i128`, `count_i128`, `minmax_i128`; a5 `minmax_i64`, `minmax_i128` |
| `TAB_HIBIAS` → `c_hibias` | `sum_i128` (a2, a5) |

**`pqk_x86_simd.h`** (AVX2 and AVX-512)

| block | users |
|---|---|
| `HSUMQ` | a2: `count_i64` (`VCNT`), `count_i128` (`VCNT128`), `sum_i64`, `bitmap_popcount`; `HSUMZ` |
| `HSUMZ` | a5: `count_i64` (`KCNT`), `count_i128` (`KCNT128`), `sum_i64`, `bitmap_popcount` |
| `F64_ZERO_FIXUP` | `minmax_f64` (a2, a5) |
| `SMIN128`, `SMAX128` | `minmax_i128` (a2, a5) |
| `FOLD_LANES128`, `UNBIAS192`, `SUM128_CHUNK_ROWS` | `sum_i128` (a2 via `fold128`, a5 via `fold512`) |
| `SUM_CHUNK_ROWS` | `sum_i64` (a2, a5) |

**`pqk_x86_scalar.h`**, **`pqk_x86_avx2.h`**, **`pqk_x86_avx512.h`** (one variant each)

| block | users |
|---|---|
| s `SWAR_POPCNT`, `DEFINE_POPCNT64` → `popcnt64`, `POPC` | `filter_i64_bitmap`, `count_i64`, `compare_i64`, `bitmap_popcount`; `count_i128` (`POPC`) |
| s `SPRED`, `SOP` → `sop_*`, `PRED_DRIVER` | `filter_i64`, `filter_i64_bitmap`, `count_i64` |
| s `BQ`, `BITOP` | `bitmap_and`, `bitmap_or`, `bitmap_andnot` |
| s `P128`, `P128_BODY`, `P128_KERNEL` | `filter_i128`, `count_i128` |
| a2 `VPRED`, `ROWPRED`, `VOP` → `vop_*`, `RANGE_SETUP`, `VDRIVER` | `filter_i64`, `filter_i64_bitmap`, `count_i64` (`VCNT` → `vcnt_*`: `count_i64`) |
| a2 `EMIT_IDX_COMPRESS8` | `filter_i64`, `filter_i128` |
| a2 `VBOP`, `VBITOP` | `bitmap_and`, `bitmap_or`, `bitmap_andnot` |
| a2 `LTX`, `GTX`, `VG128`, `NIBFIX`, `VOP128` → `vop128_*`, `VOP128F` → `vop128f_*`, `RANGE128_SETUP`, `VDRIVER128` | `filter_i128`, `count_i128` (`VCNT128` → `vcnt128_*` with `VCNT128_HI` / `VCNT128_EXACT`: `count_i128`) |
| a2 `QR_BACKOFF`, `QR_BACKOFF_MAX` | quick-reject / fast-path back-off: `minmax_i64`, `minmax_i128`, `VOP128F`, `VCNT128` |
| a5 `LANES8` | `KOP`, `KCNT`, `GROUPMASK`; `compare_i64` (`KCMP`), `hash_i64` |
| a5 `PEELMASK` | `count_i64` (`KCNT`), `sum_i64`, `sum_f64`, `minmax_i64`, `minmax_f64` |
| a5 `GROUPMASK` | `sum_i64`, `sum_f64`, `minmax_i64`, `minmax_f64` |
| a5 `KPRED`, `KOP` → `kop_*`, `KCNT` → `kcnt_*`, `KDRIVER` | `filter_i64`, `filter_i64_bitmap`, `count_i64` |
| a5 `EMIT_IDX_COMPRESS16` | `filter_i64`, `filter_i128` |
| a5 `ZBOP`, `ZBITOP` | `bitmap_and`, `bitmap_or`, `bitmap_andnot` |
| a5 `LG128`, `GLANES` | `minmax_i128` (`ZTAIL`); `GLANES` also `KOP128`, `KCNT128` |
| a5 `LGU128`, `KFIX`, `KP128`, `KOP128` → `kop128_*`, `KCNT128` → `kcnt128_*`, `KDRIVER128` | `filter_i128`, `count_i128` |

`structure_check.py` verifies that each of these macros, constants, helpers
and tables is defined in exactly one place (232 definitions at CR-5, 260
after the AVX2 throughput work).

### How "no behaviour change" was verified

1. **Machine code.** `verify/disasm_compare.py <rev>` assembles the variant
   files of a git revision and of the working tree, links each into a
   throw-away shared object, and compares every function and every rodata
   object by name. Addresses are normalised; branch, call and RIP-relative
   targets are compared as `<symbol+offset>`. Against the pre-CR-5 commit
   (`16e68a2`, with `-R c_sign_q=c_i64min`): **138 of 140 functions and all
   but one object are identical**, also with the test-only chunk overrides
   (`-D SUM_CHUNK_ROWS=24 -D SUM_CHUNK_BLOCKS=1 -D SUM128_CHUNK_ROWS=64`).
   The intentional differences:
   * `pqk_x86_scalar_filter_i128` and `pqk_x86_scalar_count_i128`: the
     operator dispatch now uses the shared `JTAB_LOAD`. It computes the
     target as `add %rax,%rdx; jmp *%rdx` instead of
     `add %rdx,%rax; jmp *%rax`: same length, same jump target, executed once
     per call.
   * AVX2 `c_sign_q` (2^63) was the same constant as AVX-512 `c_i64min`. It
     is now one table, `TAB_I64MIN`, so the AVX2 code references
     `c_i64min`, which has the same 8 bytes.
   * `c_hibias` is one 32-byte table for both SIMD variants. AVX-512 used to
     have a 16-byte copy; its `vbroadcasti32x4` still reads the same first 16
     bytes.
   The tool caught one real refactoring bug on the way (a constant used
   before its `#define`), see the include-file rules above.
2. **Tests.** `make -C native-kernels test` (native and ASan/UBSan) and
   `verify/run.sh` pass: guard pages, edge cases, small-chunk fold builds,
   the ABI register/stack/vzeroupper check, and the structure check.
3. **Structure.** `verify/structure_check.py` checks, on every run:
   building blocks are defined once; headers emit no bytes; each variant has
   exactly the 20 kernels of `pq_kernels.h`; the label scheme; header
   comments and skeleton tags; and each kernel's `Clobbers:` list against
   the registers its machine code can write (following helper calls and
   jump tables), including that every written callee-saved register is
   saved. Negative controls were run: a missing tag, a wrongly named label,
   a removed `PROLOGUE` and an undocumented clobber are each reported.

### Performance before / after CR-5

Because the instructions are identical, no change is expected. Measured with
`tests/kernel_bench.c` (n = 4,194,304, 15 repetitions per run, median). The
pre-CR-5 binary (`16e68a2`) and the CR-5 binary ran interleaved, 9 runs
each, pinned to CPU 0 (V-cache CCD, data L3-resident) and to CPU 8 (data
from DRAM). Shown: median ns per element, and the ratio new / before. The
last column is the reference C implementation, which is the same code in
both binaries, so it shows the measurement noise.

CPU 0 (L3-resident):

| kernel | scalar before | scalar after | ratio | avx2 before | avx2 after | ratio | avx512 before | avx512 after | ratio | reference ratio (noise) |
|---|---|---|---|---|---|---|---|---|---|---|
| filter_i64_sel10 | 0.3326 | 0.3307 | 0.994 | 0.1538 | 0.1538 | 1.000 | 0.1041 | 0.1046 | 1.005 | 1.001 |
| filter_i64_bitmap | 0.2171 | 0.2177 | 1.003 | 0.0938 | 0.0919 | 0.980 | 0.0660 | 0.0666 | 1.009 | 0.994 |
| count_i64_between | 0.2596 | 0.2597 | 1.000 | 0.0902 | 0.0880 | 0.976 | 0.0508 | 0.0508 | 1.000 | 1.001 |
| sum_i64 | 0.1903 | 0.1906 | 1.002 | 0.0786 | 0.0759 | 0.966 | 0.0501 | 0.0500 | 0.998 | 1.002 |
| sum_i64_validity | 0.3241 | 0.3224 | 0.995 | 0.1157 | 0.1172 | 1.013 | 0.0522 | 0.0523 | 1.002 | 1.001 |
| sum_f64 | 0.3686 | 0.3687 | 1.000 | 0.0574 | 0.0540 | 0.941 | 0.0514 | 0.0512 | 0.996 | 1.000 |
| minmax_i64 | 0.5542 | 0.5540 | 1.000 | 0.1068 | 0.1067 | 0.999 | 0.0502 | 0.0502 | 1.000 | 1.001 |
| bitmap_and | 0.0039 | 0.0039 | 1.000 | 0.0025 | 0.0025 | 1.000 | 0.0024 | 0.0023 | 0.958 | 1.000 |
| bitmap_popcount | 0.0141 | 0.0141 | 1.000 | 0.0020 | 0.0020 | 1.000 | 0.0009 | 0.0009 | 1.000 | 1.002 |
| hash_i64 | 0.5971 | 0.5909 | 0.990 | 0.3637 | 0.3634 | 0.999 | 0.1257 | 0.1245 | 0.990 | 0.991 |
| compare_i64 | 0.2832 | 0.2805 | 0.990 | 0.1420 | 0.1400 | 0.986 | 0.1617 | 0.1577 | 0.975 | 0.997 |
| group_sum_i64_1024 | 0.5810 | 0.5803 | 0.999 | 0.4337 | 0.4333 | 0.999 | 0.4340 | 0.4321 | 0.996 | 1.001 |
| gather_i64 | 0.7555 | 0.7502 | 0.993 | 0.7676 | 0.7491 | 0.976 | 0.7803 | 0.7408 | 0.949 | 1.031 |
| filter_i128_sel10 | 0.3576 | 0.3580 | 1.001 | 0.2803 | 0.2752 | 0.982 | 0.2035 | 0.1999 | 0.982 | 1.000 |
| count_i128_between | 0.2789 | 0.2794 | 1.002 | 0.2020 | 0.2006 | 0.993 | 0.2037 | 0.2063 | 1.013 | 0.998 |
| sum_i128 | 0.2235 | 0.2258 | 1.010 | 0.1553 | 0.1597 | 1.028 | 0.1555 | 0.1564 | 1.006 | 0.998 |
| minmax_i128 | 0.4674 | 0.4644 | 0.994 | 0.2143 | 0.2124 | 0.991 | 0.2292 | 0.2323 | 1.014 | 1.000 |

Geometric mean of the ratios over the 51 variant kernels: **0.994**
(range 0.941–1.028).

CPU 8 (DRAM):

| kernel | scalar before | scalar after | ratio | avx2 before | avx2 after | ratio | avx512 before | avx512 after | ratio | reference ratio (noise) |
|---|---|---|---|---|---|---|---|---|---|---|
| filter_i64_sel10 | 0.3487 | 0.3498 | 1.003 | 0.1971 | 0.1976 | 1.003 | 0.1624 | 0.1565 | 0.964 | 1.009 |
| filter_i64_bitmap | 0.2470 | 0.2466 | 0.998 | 0.1335 | 0.1340 | 1.004 | 0.1376 | 0.1394 | 1.013 | 0.998 |
| count_i64_between | 0.2843 | 0.2850 | 1.002 | 0.1265 | 0.1295 | 1.024 | 0.1206 | 0.1218 | 1.010 | 1.013 |
| sum_i64 | 0.2237 | 0.2224 | 0.994 | 0.1355 | 0.1360 | 1.004 | 0.1079 | 0.1084 | 1.005 | 1.008 |
| sum_i64_validity | 0.3382 | 0.3386 | 1.001 | 0.1543 | 0.1569 | 1.017 | 0.1207 | 0.1220 | 1.011 | 1.001 |
| sum_f64 | 0.3754 | 0.3760 | 1.002 | 0.1214 | 0.1208 | 0.995 | 0.0954 | 0.0972 | 1.019 | 1.002 |
| minmax_i64 | 0.5417 | 0.5421 | 1.001 | 0.1479 | 0.1488 | 1.006 | 0.1139 | 0.1116 | 0.980 | 1.001 |
| bitmap_and | 0.0033 | 0.0032 | 0.970 | 0.0022 | 0.0023 | 1.045 | 0.0023 | 0.0022 | 0.957 | 0.923 |
| bitmap_popcount | 0.0137 | 0.0137 | 1.000 | 0.0019 | 0.0019 | 1.000 | 0.0010 | 0.0010 | 1.000 | 1.003 |
| hash_i64 | 0.5957 | 0.5860 | 0.984 | 0.4661 | 0.4686 | 1.005 | 0.4209 | 0.4231 | 1.005 | 0.995 |
| compare_i64 | 0.3626 | 0.3587 | 0.989 | 0.3123 | 0.3105 | 0.994 | 0.3201 | 0.3191 | 0.997 | 0.994 |
| group_sum_i64_1024 | 0.6107 | 0.6102 | 0.999 | 0.4805 | 0.4782 | 0.995 | 0.4826 | 0.4814 | 0.998 | 1.005 |
| gather_i64 | 2.4984 | 2.5064 | 1.003 | 2.2686 | 2.2726 | 1.002 | 2.2734 | 2.2606 | 0.994 | 1.001 |
| filter_i128_sel10 | 0.4442 | 0.4503 | 1.014 | 0.4074 | 0.4033 | 0.990 | 0.3791 | 0.3766 | 0.993 | 1.000 |
| count_i128_between | 0.3797 | 0.3803 | 1.002 | 0.3459 | 0.3459 | 1.000 | 0.3463 | 0.3468 | 1.001 | 1.002 |
| sum_i128 | 0.3645 | 0.3614 | 0.991 | 0.3327 | 0.3341 | 1.004 | 0.3260 | 0.3186 | 0.977 | 0.997 |
| minmax_i128 | 0.5252 | 0.5235 | 0.997 | 0.3558 | 0.3548 | 0.997 | 0.3617 | 0.3625 | 1.002 | 0.999 |

Geometric mean over the 51 variant kernels: **0.999** (range 0.957–1.045).

All deviations are within run-to-run noise (the reference column moves by up
to ±3 %, and up to 8 % for the 0.002 ns/bit `bitmap_and`). There is no
regression. That is as expected: the instructions are identical, and
functions are still 32-byte aligned (helpers 16), so loop alignment within
each function is unchanged.

An unpinned `make -C native-kernels bench` on the final commit reproduced
the earlier official numbers within noise (for example `filter_i64_sel10`
0.82 / 0.34 / 0.19 / 0.16 ns for reference / scalar / AVX2 / AVX-512). In
that run the process moved between the two CCDs (AVX2 `sum_f64` got the L3
figure 0.058, AVX-512 the DRAM figure 0.095), which is why the pinned,
interleaved runs above are the before/after comparison.

## Common architecture

### Predicate kernels: 64-row block masks

`filter_i64`, `filter_i64_bitmap`, `count_i64` and `compare_i64` share one
structure in every variant:

1. The operator is validated (`op > 6`, or `> 5` for `compare_i64`, compared
   unsigned, so negative ints are rejected too) and returns `(size_t)-1`. A
   per-operator **mask routine** is then chosen once through a PIC-relative
   jump table (`.long routine - table`, so there are no text relocations).
2. Rows are processed in blocks of 64. The mask routine returns a 64-bit mask
   in `rax`, where bit *j* is row *j* of the block and bits at or above `len`
   are 0.
3. The driver ANDs the mask with the block's validity word. A full block uses
   one unaligned 8-byte load; the final partial block loads exactly
   `ceil(len/8)` bytes (`lvp` helper), so nothing past `ceil(n/8)` is read.
4. The mask is then consumed. `filter_i64` emits indices, `filter_i64_bitmap`
   stores 8 bytes per full block (per-byte for the last block, so trailing bits
   are zero and nothing past `ceil(n/8)` is written), and `count_i64` adds a
   popcount.

The mask routines differ per variant:

* **scalar**: walks forward, 8 rows per step, `cmp` + `setcc` with fixed
  shifts into a byte (independent dependency chains), and the byte is then
  shifted into place by `cl`. BETWEEN uses the unsigned range trick
  `(x-a) <=u (b-a)`. The driver selects an always-false routine when `a > b`.
* **AVX2**: has only `==` and signed `>`, so every operator maps to
  (kind, invert): `EQ x==a`, `NE !(x==a)`, `LT a>x`, `LE !(x>a)`, `GT x>a`,
  `GE !(a>x)`, `BETWEEN !(a>x | x>b)`. Each group of 4 rows does
  `vpcmpeqq`/`vpcmpgtq` + `vmovmskpd`, and the 4-bit pieces are OR-ed on two
  independent chains. (Since the throughput work, BETWEEN with `a <= b` is
  the unsigned range test `(x-a) >u (b-a)` as one `vpsubq` + `vpcmpgtq`,
  "kind 4".) In the partial block, whole vectors are used while at
  least 4 rows remain, the last 1–3 rows are compared in scalar code, and the
  result is trimmed with `bzhi`.
* **AVX-512**: `vpcmpq` with an immediate predicate writes k-masks directly
  (written as "a OP' x" so that x can be a memory operand). Eight compares are
  merged with `kunpckbw/wd/dq` and moved out with `kmovq`. BETWEEN is
  `a<=x`, then a masked `b>=x`. The partial block uses zero-masked
  `vmovdqu64 {z}` loads.

Index emission in `filter_i64`:

* **scalar**: `bsf` / `x &= x-1`.
* **AVX2**: every full block that has any hit uses an 8-row compress step:
  one `vpmovzxbd` from the 2 KB table `idx8` (the packed bit positions of
  every byte value) + `vpaddd base` produce 8 indices, which are stored as
  one 32-byte store. The output pointer then advances by `popcnt`. Partial
  and empty blocks use `tzcnt`/`blsr`. (Before the throughput work the
  positions were computed with `pdep`, `imul 0xff`, `pext`.)
* **AVX-512**: `vpcompressd` of an index vector, 16 rows per step.

The vector stores can write past the last emitted index. This is safe: after
*i* rows at most *i* indices exist, so a store of 8 (or 16) dwords starting at
index *k ≤ i* stays below `out_idx + 4*(i+8) ≤ out_idx + 4n`, because only full
blocks use this path. Bytes beyond the returned count are scratch, which the
API allows (`capacity >= n`).

`count_i64` without validity skips the masks altogether. AVX2 accumulates the
compare results (`vpsubq` of all-ones lanes, inversion applied at the end via
`rows - count`). AVX-512 does a merge-masked `acc -= -1` per k-mask.

### Validity handling in streaming kernels

* **scalar**: branch-free. Shifting the validity word right moves the row's
  bit into CF, and `sbb r,r` turns it into a 0/-1 mask. Invalid rows add 0,
  `cmovnc` substitutes neutral elements for min/max, and `adc $0` counts.
* **AVX2**: the 64-bit validity word of a full block is broadcast and shifted
  per lane with `vpsllvq` (by `63-(4g+j)`, from a 16×4 table), which puts each
  row's bit into its lane's sign bit. `vblendvpd` uses that sign bit directly
  (min/max); `sum_f64` widens it with `vpcmpgtq` against zero. The integer
  sums now load the lane mask of 4 rows (`sum_i64`, table `nibmask`) or 2
  rows (`sum_i128`, table `pairmask`) indexed by the validity bits (`rorx` +
  `and` on the integer side) and AND it with a plain load. The final partial
  block (< 64 rows) runs scalar code.
* **AVX-512**: `kmovb`/`kmovw` read validity bytes straight into k registers,
  which act as merge masks on the arithmetic. Masked loads are used only for
  tails.

### Exactness

* **`sum_i64`** is exact in every variant (the result must be the exact
  mathematical sum, and wrap-around that cancels out is fine).
  * scalar: a 128-bit accumulator (`add`/`adc` with `cqo` sign extension).
  * AVX2: per lane, it accumulates the biased values `x' = x ^ 2^63`
    (unsigned): `S = Σx' mod 2^64` and `U = Σ(x' >>> 32)`. The exact
    unsigned lane sum is `U·2^32 + LU` with `LU = (S − U·2^32) mod 2^64`,
    exact while `LU < 2^64`; chunks of at most 2^28 rows keep `U, LU < 2^60`.
    Each chunk is folded into a 128-bit scalar total and `c·2^63` (`c` =
    rows added) is subtracted. The cost is 4 vector ops per 4 rows. (Before
    the throughput work: `S`, `HU = Σ(x >>> 32)` and `N = #negatives`, 5 ops.)
  * AVX-512: has `vpsraq`, so it uses signed high halves:
    `Σx = H·2^32 + L`, `L = (S − H·2^32) mod 2^64`. That is 3 ops per 8 rows,
    with no N term.
  * Overflow ⇔ the 128-bit total's high word ≠ the sign extension of its low
    word. `*out_sum` is only written on `PQK_OK`, like the reference.
  * The fold path triggers only past 2^28 rows. `SUM_CHUNK_ROWS` /
    `SUM_CHUNK_BLOCKS` can be overridden with `-D` to test it with tiny chunks;
    `verify/run.sh` does this.
* **`sum_f64`**: the scalar variant adds sequentially, exactly like the
  reference (bit-identical). Invalid rows add `+0.0`, which is an exact no-op
  because a sum that starts at `+0.0` can never be `-0.0`. The SIMD variants
  use 16 (AVX2) or 32 (AVX-512) lane-wise partial sums. That reassociation is
  allowed by the header's tolerance.
* **`minmax_f64`**: lanes merge in a different order than the sequential scan,
  so with SIMD only the sign of a zero result could differ (`-0.0 == +0.0`).
  To stay bit-identical, the SIMD variants do a fix-up: when the min (max)
  compares equal to `0.0`, it is replaced by the first valid zero in row
  order, which is provably what the reference returns in that case. This costs
  an extra scan only when the result is zero. The per-lane update
  (`vminpd acc, x` = "x < acc ? x : acc") already matches the reference's
  strict comparison.
* **`group_sum_i64`**: every variant validates all valid group ids first
  (outputs untouched on `PQK_EINVAL`), then adds in row order. The wrap flag is
  therefore exactly the reference's, and sums and counts are bit-identical.
  * AVX2 (throughput work): without validity and for at most 1024 groups it
    first accumulates `{sum, count}` pairs in a stack table and commits them
    only if no addition can wrap in any order (then the reference cannot
    wrap either); otherwise it discards the table and adds in row order.
  * AVX2 range check: `(id ^ 2^31) >s ((ng-1) ^ 2^31)`, 32 ids per `vptest`.
  * AVX-512 range check: native unsigned `vpcmpud`. `ngroups == 0` rejects
    every valid row, and `ngroups > UINT32_MAX` skips the check.
* **`hash_i64`**: AVX2 has no 64-bit multiply, so `k·c` is computed as
  `lo·clo + ((hi·clo + lo·chi) << 32)`: `vpmulld` against `(chi, clo)` gives
  both cross products, `vpmuludq` gives `lo·clo` (originally three
  `vpmuludq`); a third of the rows are hashed with scalar `imul` in
  parallel. AVX-512 uses `vpmullq`.

### Memory safety and aliasing

* No kernel reads or writes outside the documented buffers:
  * data: `n` elements; validity: `ceil(n/8)` bytes.
  * bitmaps: `ceil(n/8)` (or `nbytes`) bytes; `out_idx`: `n` dwords.
  * `compare_fixed`: `width*n` bytes.
  * Unaligned pointers are fine everywhere: all vector loads/stores are the
    unaligned forms, and scalar code has no alignment needs.
* `n == 0` touches no memory, so NULL pointers are fine. `sum_i64` still
  writes `*out_sum = 0`, as the reference and the test require.
* AVX2 never uses `vpmaskmovq`/`vmaskmovpd`. AMD documents that faults on
  masked-off elements are implementation dependent, and they were also slow
  (see below). Tails are scalar instead.
* AVX-512 tails rely on architectural fault suppression of masked-off
  elements (`vmovdqu64/8 {k}{z}`, masked stores).
* `compare_fixed`:
  * AVX2 issues a full 32-byte load only when at least 32 bytes remain before
    the end of the *whole* buffer. Such a load may run into the next record,
    but never past `a + width*n`.
  * The last few records use 8-byte (`bswap`) compares and single bytes.
  * AVX-512 byte-masks the loads within the last 64 bytes.
* Bitmap and/or/andnot load all inputs of a step before storing it, at
  identical offsets, so `out == a` or `out == b` works (tested).

### ABI

System V AMD64 throughout:

* Arguments arrive in `rdi, rsi, rdx, rcx, r8, r9`, with the 7th
  (`out_idx`/`out_bits`/`ngroups`) at `8(%rsp)` on entry.
* Every callee-saved register that is used (`rbx, rbp, r12–r15`) is pushed and
  popped (`PROLOGUE` / `EPILOGUE` over one `SAVED` list per kernel;
  `structure_check.py` verifies against the machine code that no written
  callee-saved register is left unsaved). The direction flag is never
  touched. MXCSR is not modified.
* No red zone is used. Internal helpers (mask routines, `lvp`, `popcnt64`)
  have documented private register conventions and use the stack only for
  `call/ret` (exception: `vcnt128_k4` keeps one 32-byte constant on the
  stack, between `sub`/`add` of `rsp`), so stack alignment is irrelevant to
  them. AVX2 `group_sum_i64` allocates up to 20 KB for its local table by
  moving `rsp` down page by page (touching each page, like stack-clash
  probing) and restores it from `rbp`. No external function is ever called.
* Every function that touches ymm/zmm ends with `vzeroupper` (`VRET`).
  AVX-512 code uses only zmm0–15, so `vzeroupper` leaves no dirty upper or
  Hi16 state.
* Every symbol has `.type`/`.size`: functions as `@function` (`FUNC`,
  `LFUNC`, `ENDF`), rodata tables as `@object` (`OBJ`, `ENDOBJ`).
* Each file ends with `.section .note.GNU-stack,"",@progbits`, and the
  resulting `.so` has a non-executable `GNU_STACK` and no `TEXTREL`.
* The code is position independent: RIP-relative constants and
  self-relative jump tables.

## 128-bit kernels (CR-4)

`pqk_i128` is `{uint64_t lo; int64_t hi;}`: 16 bytes, little-endian, any
alignment. Row *i* is at `data + 16*i`. Each kernel's header comment covers
register usage, the algorithm and, for `sum_i128`, the exact-overflow
argument. This section summarizes them.

### Common rules (all variants)

* **Operator check first.** `op` is compared unsigned against 6, so negative
  ints are rejected as well. An invalid op returns `(size_t)-1` before `a` or
  `b` is touched. `b` is loaded only for `PQK_BETWEEN`. `a` is always
  loaded, also for `n == 0`, as the spec requires. Both are loaded once into
  registers before any row is read, so `a`/`b` aliasing `data` is harmless.
* **Same structure as the 64-bit predicates.** `filter_i128` and
  `count_i128` reuse the 64-row block-mask structure (mask routine, then
  `& validity word`, then emit or popcount). The final partial validity
  block loads exactly `ceil(len/8)` bytes (`lvp`), and filter index emission
  is identical to `filter_i64`.
* **Operators map to (kind, invert)** so each variant needs only 3–4
  predicate kernels:
  * scalar/AVX2: `EQ`, `LT` (x<a), `GT` (x>a), and `OUT` (x<a | x>b, or
    the range trick); `BETWEEN = !OUT`. AVX2 uses the 128-bit range trick
    for `a <= b` since the throughput work (kind 4), and decides LT/GT and
    the range kind on the high words first, per 64-row block.
  * AVX-512: `IN` (a≤x≤b) directly.

  With `a > b`, `BETWEEN` is empty automatically in the vector variants. The
  scalar range trick needs `a ≤ b`, so the scalar code checks `a > b` up
  front and returns 0.
* **`sum_i128` writes `*out_sum` only on `PQK_OK`**, like the reference.
  `n == 0` stores 0 and returns OK. **`minmax_i128` writes its outputs only
  if the count is > 0.**

### Signed 128-bit comparison

* **scalar**: `cmp lo; sbb hi` on sign-biased high words (`hi ^ 2^63`), which
  turns the signed compare into an unsigned one, so the result is in CF.
  (In)equality is `(x.lo^a.lo) | (x.hi^a.hi)`, then `neg`, which sets CF iff
  the value is non-zero. BETWEEN uses the unsigned range trick
  `(x-a) mod 2^128 ≤u (b-a)`, with `sub/sbb` followed by `cmp/sbb`.
  Each row's CF is rotated into the block mask with `rcr $1` (a 1-cycle op).
  After `len` rows, row *j* sits at bit `64-len+j`, so one `shr` by `64-len`
  aligns a partial block and clears the bits ≥ len. The rows are walked
  forward, which keeps the prefetcher happy (see the i64 lesson below).
* **AVX2** has only signed 64-bit `vpcmpgtq`/`vpcmpeqq`. A group of 4 rows is
  two 32-byte loads, de-interleaved within lanes by
  `vpunpcklqdq`/`vpunpckhqdq` into `L`/`H` in lane order (0,2,1,3). Low words
  are biased with `^2^63`, so they compare as unsigned. Then:
  * `x < c` is `c.hi >s x.hi | (c.hi == x.hi & c.lo' >s x.lo')`: three
    compares plus one `vblendvpd`, which selects the low-word result where
    the high words are equal.
  * `vmovmskpd` nibbles arrive with bits 1 and 2 swapped. A SWAR delta swap
    per 64-row mask (`NIBFIX`, 6 ops) restores row order.
  * The 1–3 rows left in a partial block are evaluated one row at a time
    as 16-byte xmm loads with the same code, so nothing past the buffer is
    read.
* **AVX-512** has unsigned compares into k-masks:
  * `x < c` is `vpcmpq(hi <) | vpcmpuq(lo <u){vpcmpq(hi ==)}`, i.e. a
    write-masked compare plus `korb`.
  * filter/count de-interleave a group of 8 rows with in-lane `vpunpck`
    (lane order 0,4,1,5,2,6,3,7). The 64-bit block mask is put back in row
    order with `pext`/`pdep` (`KFIX`, 4 BMI2 ops per 64 rows).
  * minmax uses `vpermt2q`, which gives natural order, so validity bytes
    can be used directly as write masks.
  * Tails use zero-masked loads (fault suppression), as elsewhere in the
    AVX-512 file.
* **count without validity** skips the masks in the SIMD variants:
  * AVX2: `vpsubq` of all-ones lanes on two accumulators over `n & ~3`
    rows; the remaining 1–3 rows go through the mask path. For LT/GT and
    BETWEEN (`a <= b`) full 64-row blocks are first counted on the high
    words alone and recounted exactly only if a row is undecided.
  * AVX-512: merge-masked `acc -= -1` per group. Tail groups are ANDed
    with a row mask in permuted lane order (`pdep` with `0x55`/`0xaa`).
  * The inversion is applied once at the end: `rows − count`.

### Exact `sum_i128` (overflow beyond 128 bits)

The exact sum needs at most 160 bits (`n < 2^32`), so every variant ends in a
**192-bit scalar total** `T` (three GPRs). `PQK_OVERFLOW` ⇔ `T`'s top word ≠
the sign extension (`sar 63`) of its middle word. So intermediate wrap-around
of the low 128 bits that cancels out can never cause a false overflow, and
any final sum outside `[-2^127, 2^127-1]` is always reported.

* **scalar**: every row is sign-extended to 192 bits and added with
  `add/adc/adc`, unrolled 4×. Invalid rows are and-masked to 0 (`shr` →
  CF, `sbb` → 0/-1).
* **AVX2 / AVX-512**: the interleaved words of a load (`[lo, hi, lo, hi…]`)
  are treated as unsigned after biasing the high words,
  `hi ^ 2^63 = hi + 2^63`. So `x = lo + 2^64·(hi^2^63) − 2^127`.
  * Per 64-bit lane the variants keep `S = Σv mod 2^64` and
    `H = Σ(v >>> 32)` (exact). The lane sum `E = H·2^32 + L` is exact with
    `L = (S − H·2^32) mod 2^64`, as long as `L < 2^64`. Chunks of at most
    2^28 rows keep `H, L < 2^60`.
  * `E mod 2^64 = S`, and `E div 2^64 = (H>>32) + carry(H<<32 + L)`. The
    fold computes this as `sub`, `add` (CF), `adc`.
  * The fold adds even lanes into `T` at weight 1 and odd lanes at weight
    2^64. At the end, `T −= cnt·2^127`, where `cnt` is the number of rows
    that were biased.
  * Cost: 4 vector ops per 2 rows (AVX2) or per 4 rows (AVX-512). The
    `vpxor` with the bias constant is fused with the load.
* **Validity handling** depends on the variant:
  * AVX2: per 2-row load, the lane mask is loaded from the 4-entry table
    `pairmask` indexed by the two validity bits (originally `vpsllvq` +
    `vpcmpgtq`), and ANDed with the load. Invalid rows become 0
    *before* the bias, so they still contribute exactly 2^127 and are
    counted in `cnt`. The final partial block is scalar.
  * AVX-512: the 64-bit validity word is expanded to a 128-bit lane mask
    (`pdep 0x5555…` then `·3`). A zero-masking `vpxorq` removes invalid
    rows entirely (not biased, not counted). Tails use the same mask on a
    zero-masked load.
* `SUM128_CHUNK_ROWS` (default 2^28, a multiple of 64) can be overridden
  with `-D`. `verify/run.sh` builds `tests/kernel_test.c` and `edge_cases.c`
  with 64-row chunks, so the fold path runs constantly.

### `minmax_i128`

* **scalar**: range test. `min = max =` the first valid row `f`, found by a
  byte scan of the bitmap (or `f = 0` without validity).
  * From `f`'s 64-row block on, each row is tested with **one** 128-bit
    compare: `x ∈ [min,max]` ⇔ `(x−min) mod 2^128 ≤u w`, where
    `w = max−min`.
  * Inside, which is the common case, needs no update. Outside calls a
    small out-of-line routine that decides `x<min` or `x>max` (exactly one
    holds), updates it and recomputes `w`.
  * Invalid rows get `d = 0` (and-masked), i.e. they always count as inside.
  * The count is `n`, or the `sbb` masks summed per row.
* **AVX2**: lane-wise 128-bit min/max on de-interleaved groups, with
  accumulators that keep biased low words (all compares are signed).
  * Since the throughput work, every full 64-row block is first checked on
    the high words against the overall min/max (skip if all rows are
    strictly inside; exponential back-off when the check fails).
  * Two accumulator sets alternate between groups and start at the neutral
    values `INT128_MAX`/`INT128_MIN`. If the true minimum is `INT128_MAX`
    it is bit-identical to the neutral value, so no first-element case is
    needed.
  * Lazy update: `lt`/`gt` are computed, then one `vtestpd` (which reads
    sign bits, so validity can be folded in) decides whether the four
    `vblendvpd` are needed at all.
  * The count is `popcnt` of the validity words (`bzhi`'d to `n`). The 0–3
    tail rows run in scalar after the lanes are reduced.
* **AVX-512**: natural-order groups (`vpermt2q`). Compares are write-masked
  by the validity byte, and updates are merge-masked `vmovdqa64`, so this
  path is branch-free. Tail groups use zero-masked loads, so there is no
  scalar tail.

### Performance decisions for CR-4 (measured on this host)

* **AVX2 `vblendvpd` vs. `vpand`+`vpor`** for combining the high/low
  compare results: no difference within noise (count/filter, L2-resident).
  The blend was kept because it is one op.
* **AVX2 minmax lazy update** vs. always blending, measured over 64K rows in
  L2 (ns/row):
  * random data: 0.27 → 0.22;
  * ~50% of groups with unpredictable updates (row *i* is ±*i* with p = 1/6,
    else 0): 0.27 → 0.24;
  * strictly ascending data, where every group updates: 0.27 → 0.28.

  It was adopted. For AVX-512 the same change was −7% on random data and
  +6% on ascending data, so AVX-512 stays branch-free.
* **AVX-512 de-interleave:** in-lane `vpunpck` + `KFIX` instead of
  `vpermt2q` for filter/count gave count 0.185 → 0.163 ns/row and filter
  0.167 → 0.160. For minmax it made no difference, so minmax keeps
  `vpermt2q` and its natural row order.
* **Scalar `sum_i128` with validity**, unrolled 4×: 0.41 → 0.36 ns/row (L2).
* **Scalar minmax worst case.** The range test is data-dependent:

  | data (64K rows, L2, ns/row) | x86_scalar | x86_avx2 | x86_avx512 |
  |---|---|---|---|
  | bench data (random decimals), validity / none | 0.44 / 0.28 | 0.22 / 0.20 | 0.20 / 0.19 |
  | small values (hi = 0), validity / none | 0.44 / 0.28 | 0.23 / 0.19 | 0.20 / 0.19 |
  | strictly ascending, validity / none | 0.80 / 0.79 | 0.28 / 0.24 | 0.20 / 0.19 |
  | ±*i* with p = 1/6 (unpredictable updates), validity / none | 0.56 / 0.96 | 0.24 / 0.21 | 0.20 / 0.19 |

  In the worst case the scalar kernel is about as fast as the reference
  (reference: 0.83–1.4 ns/row on the same data, built with -O2 in this
  harness). It is 1.6–1.8× faster on typical data. A branch-free cmov
  version has a 3-cycle loop-carried chain per row, which would be about
  0.6 ns/row everywhere, so the range test was kept.
* All four kernels are **compute-bound when the data is cache-resident.**
  An L2-resident run (64K rows) gives about the same ns/row as the
  L3-resident run below. The AVX2/AVX-512 i128 kernels need 2–4 vector ops
  per row versus about 1 for the i64 kernels.

## Verification

Besides `make test`, `verify/run.sh` builds and runs the tools below, plus
`stress.c`, the randomized large-size differential test added for the AVX2
throughput work (see
[Verification of the changes](#verification-of-the-changes)):

* **`guard_pages.c`**: every buffer handed to a kernel either ends exactly at a
  `PROT_NONE` page or starts right after one. It runs n = 0…300, with and
  without validity, all ops, `compare_fixed` widths 0…39, and inputs with `-0.0`
  and all-non-negative / all-non-positive columns (which exercise the
  signed-zero fix-up). Results are compared with the reference, and
  `minmax_f64` is compared bit-for-bit. This catches out-of-bounds reads by
  the assembly, which ASan cannot see. **Result: all variants ok.**
* **`edge_cases.c`**:
  * `compare_fixed` widths up to 300 (multi-chunk paths);
  * `group_sum` with `ngroups` = 0, 3 and 2^33, with and without counts;
  * n = 300001 with all-`INT64_MAX`, all-`INT64_MIN`, random and alternating
    columns, with and without validity;
  * `count` with full-range and `a > b` BETWEEN bounds;
  * a second build with `SUM_CHUNK_ROWS=24`, plus `tests/kernel_test.c` with
    the same tiny chunks.

  **Result: all ok.**
* **`abi_check.c` + `abi_trampoline.S`**: calls every kernel of every variant
  (n ∈ {0,1,7,63,64,65,200,1000}, with and without validity, including an
  invalid op). Before each call, `rbx/rbp/r12–r15` get magic values and the
  7th argument goes on a 16-byte-aligned stack. Afterwards it checks those
  registers, `rsp`, DF, and `XINUSE` (`xgetbv(1)`, where any upper YMM/ZMM
  state left dirty means `vzeroupper` was missing). A negative control (a
  function that clobbers `rbx`, and one that leaves a dirty ymm) is detected.
  **Result: all variants ok.**

For CR-4 the three tools were extended:

* **`guard_pages.c`**:
  * runs the 128-bit kernels for n = 0…300 with every buffer at a guard page:
    the data (16·n bytes), validity, `out_idx`, `*a`, `*b` (separately, with
    `b = NULL` unless BETWEEN), `*out_sum`, `*out_min` and `*out_max`;
  * the values mix small numbers, all-ones/2^63 low words and high words
    0, ±1, `INT64_MIN/MAX`, so equal-high-word comparisons on the low word
    are exercised.
* **`edge_cases.c`**:
  * n = 300001 with all-`INT128_MAX`, all-`INT128_MIN`, random,
    exactly-cancelling alternating, ascending and descending (high-limb)
    columns, and a mixed MAX/MAX/MIN pattern. Each runs with and without
    validity and with n not a multiple of the block size;
  * count for all ops with `a`/`b` pointing into `data`, `a > b`, and
    `{0, INT64_MIN}` / `{~0, INT64_MAX}` bounds;
  * 2000 random columns whose exact sum is **exactly** `INT128_MAX` or
    `INT128_MIN` (must be OK) plus one more ±1 row (must be
    `PQK_OVERFLOW`);
  * all rows invalid.
* **`abi_check.c`**: adds the four new kernels, plus invalid ops with NULL
  `a`/`b`.
* **`-DSUM128_CHUNK_ROWS=64`** builds of `edge_cases.c` and
  `tests/kernel_test.c` exercise the vector-sum fold path.

A negative control (a scalar copy with a broken overflow check) is caught by
`edge_cases`. **Result: all variants ok.**

For CR-5 two tools were added, and `run.sh` runs them as well:

* **`structure_check.py`**: building blocks defined once, headers emit no
  bytes, 20/20 kernels per variant, label scheme, header comments and
  skeleton tags, and every `Clobbers:` list checked against the machine code
  (see [How "no behaviour change" was verified](#how-no-behaviour-change-was-verified)).
  **Result: ok** (232 definitions, 60/60 clobber lists).
* **`disasm_compare.py <rev>`**: per-symbol machine-code comparison with a
  git revision (`BASE=<rev> sh verify/run.sh`). **Result against `16e68a2`:
  identical except the three documented changes.**

## Performance decisions (measured on this host)

Host: AMD Ryzen 9 9950X3D (Zen 5, 16 cores on two CCDs, AVX-512 with full
512-bit datapaths), Linux 7.0, gcc 13.3, binutils 2.42. `perf` was broken on
this machine (missing libLLVM symbol), so all tuning used wall-clock
microbenchmarks.

* **The two CCDs behave very differently.** CCD0 (CPUs 0–7, 16–23) has 96 MB
  of 3D V-cache, so the bench's 32 MB columns are L3-resident. CCD1 (CPUs
  8–15) has 32 MB of L3, so the same columns stream from DRAM. An unpinned
  `make bench` lands on either one. All results are therefore reported three
  ways below.
* **Masked loads are slow when streaming from DRAM on Zen 5.**
  * AVX2 `vpmaskmovq` in `sum_i64` with validity: 0.68 ns/row from DRAM vs
    0.18 ns/row with plain load + `vpcmpgtq` + `vpand`. The reference got
    0.40, so the masked version was even slower than plain C.
  * AVX-512 zero-masked `vmovdqu64 {z}`: 2.5× slower than plain loads with
    merge-masked adds.
  * AVX-512 merge-masked arithmetic with a *memory* operand behaves the same
    (`sum_f64`: 0.197 → 0.130), as does a k-masked `vpcmpq mem` (BETWEEN:
    0.186 → 0.138).
  * So hot loops use only unmasked loads, and masks are applied in registers.
* **The scalar mask routine must walk forward.** The first version built the
  mask by walking each 64-row block backwards (`m = 2m + p`). That defeated
  the hardware prefetcher: 2.3–2.9 ns/row from DRAM, versus 0.26–0.35 ns/row
  for the forward version with 8 independent rows per step.
* **The AVX2 `filter_i64` compress threshold was swept** over hits-per-block
  values of 1, 2, 3, 4, 8 and 16. With "compress if the block has any hit",
  the cost is nearly flat across 1–100% selectivity (0.145–0.157 ns/row in
  L3). The previous threshold of 16 peaked at 0.198 ns/row at 20%
  selectivity, because of `tzcnt` loop-exit mispredicts.
* **`gather_i64` uses plain scalar loads (8 per iteration) in all variants.**
  `vpgatherqq` was about 5% faster with L3-resident data but 15–20% slower
  from DRAM. The kernel is latency-bound either way. (AVX2 now adds software
  prefetch 128 rows ahead for spans >= 4 MB, see the throughput section.)
* **`group_sum_i64` must not mispredict on overflow-heavy data.** A `jo` to a
  cold path cost up to 2× with full-range values. Now the first `jo` sets the
  flag and jumps into a copy of the loop without the check, since the flag is
  final by then. The validity path uses branch-free `seto`/`or`.
* **`compare_fixed` is branch-free per record.** The mask of differing bytes
  goes through `tzcnt` and `& (W-1)`. When nothing differs this lands on byte
  0, which is equal, so the same byte compare (`seta`/`sbb` → -1/0/1)
  returns 0. Records wider than the vector track `min(offset + tzcnt)` with
  `cmovc`/`cmova` (tzcnt sets CF on an empty mask). Measured with 1M records
  and random differences:

  | width (bytes) | reference | x86_scalar | x86_avx2 | x86_avx512 |
  |---|---|---|---|---|
  | 8   | 2.28 | 1.15 | 0.67 | 0.77 |
  | 16  | 3.39 | 1.93 | 0.66 | 0.76 |
  | 40  | 5.61 | 3.92 | 2.01 | 1.15 |
  | 64  | 7.01 | 5.33 | 2.60 | 2.30 |
  | 100 | 8.33 | 6.33 | 4.31 | 3.92 |

  (ns per record.) Small repeated inputs let the branch predictor memorize
  the data and flatter branchy code, so 1M-record inputs were used.
* **AVX-512 alignment peel.** `malloc` returns addresses that are 16 mod 64,
  so every 64-byte load splits a cache line. The no-validity loops of `count`,
  `sum_i64`, `sum_f64` and `minmax` handle up to 7 leading rows with a masked
  group, so the main loop is aligned. From DRAM: `sum_f64` 0.104 → 0.087,
  `sum_i64` 0.123 → 0.110 ns/row. AVX2 showed no measurable alignment effect.
* **AVX-512 `count` uses a direct loop** (`vpcmpq` → k → merge-masked
  increment) instead of masks + popcnt: 0.070 → 0.051 ns/row in L3.
* **AVX-512 `bitmap_popcount`** uses the Mula nibble-LUT method on zmm
  (`vpshufb` + `vpsadbw`, BW), because VPOPCNTQ is not in the checked feature
  set. AVX2 originally used `popcnt` on 64-bit words with 4 accumulators,
  which beat a `vpshufb` ymm version on Zen; it now runs a Harley-Seal tree
  on ymm and scalar `popcnt` in parallel (2x, see the throughput section).

## Benchmark results

`make -C native-kernels bench`: n = 4,194,304 rows (32 MB per int64 column),
median of 15 repetitions, **ns per element** (for `bitmap_*`, per bit), so
lower is better. The speedup columns are reference ns / variant ns. The
reference is the C17 implementation compiled with `-O3` (gcc auto-vectorizes
some loops with SSE2).

**These are the numbers from before the AVX2 throughput work** (for the
current AVX2 numbers see
[Throughput optimization of `x86_avx2`](#throughput-optimization-of-x86_avx2-kernel-optimize-task);
scalar and AVX-512 are unchanged). The three tables below cover the 16
original kernels; they come from the original acceptance run of that code, which neither CR-4 nor CR-5 changed
(CR-5 kept the instructions; see
[Performance before / after CR-5](#performance-before--after-cr-5)). The
[128-bit kernels](#128-bit-kernels-cr-4-1) follow after them.

### Official `make bench` run (unpinned; it landed on the DRAM-bound CCD)

| kernel | reference | x86_scalar | x86_avx2 | x86_avx512 | x86_scalar vs ref | x86_avx2 vs ref | x86_avx512 vs ref |
|---|---|---|---|---|---|---|---|
| filter_i64_sel10 | 0.7812 | 0.3525 | 0.1972 | 0.1553 | 2.22x | 3.96x | 5.03x |
| filter_i64_bitmap | 2.9093 | 0.2484 | 0.1364 | 0.1365 | 11.71x | 21.33x | 21.31x |
| count_i64_between | 0.3658 | 0.2830 | 0.1364 | 0.1188 | 1.29x | 2.68x | 3.08x |
| sum_i64 | 0.2473 | 0.2253 | 0.1376 | 0.1104 | 1.10x | 1.80x | 2.24x |
| sum_i64_validity | 0.3683 | 0.3319 | 0.1543 | 0.1196 | 1.11x | 2.39x | 3.08x |
| sum_f64 | 0.3657 | 0.3719 | 0.1247 | 0.0999 | 0.98x | 2.93x | 3.66x |
| minmax_i64 | 0.5452 | 0.5339 | 0.1533 | 0.1107 | 1.02x | 3.56x | 4.93x |
| bitmap_and | 0.0023 | 0.0033 | 0.0024 | 0.0022 | 0.70x | 0.96x | 1.05x |
| bitmap_popcount | 0.1125 | 0.0135 | 0.0018 | 0.0010 | 8.33x | 62.50x | 112.50x |
| hash_i64 | 0.6169 | 0.5810 | 0.4572 | 0.4358 | 1.06x | 1.35x | 1.42x |
| compare_i64 | 2.8114 | 0.3669 | 0.3095 | 0.3188 | 7.66x | 9.08x | 8.82x |
| group_sum_i64_1024 | 0.6952 | 0.6064 | 0.4717 | 0.4744 | 1.15x | 1.47x | 1.47x |
| gather_i64 | 2.9301 | 2.6265 | 2.2942 | 2.2889 | 1.12x | 1.28x | 1.28x |

### Pinned to CPU 0 (V-cache CCD, data L3-resident), median of 3 runs

| kernel | reference | x86_scalar | x86_avx2 | x86_avx512 | scalar/ref | avx2/ref | avx512/ref | avx2 vs scalar |
|---|---|---|---|---|---|---|---|---|
| filter_i64_sel10 | 0.7745 | 0.3396 | 0.1504 | 0.0947 | 2.28x | 5.15x | 8.18x | 2.26x |
| filter_i64_bitmap | 2.8089 | 0.2172 | 0.0823 | 0.0648 | 12.93x | 34.13x | 43.35x | 2.64x |
| count_i64_between | 0.3452 | 0.2596 | 0.0897 | 0.0567 | 1.33x | 3.85x | 6.09x | 2.89x |
| sum_i64 | 0.2008 | 0.1909 | 0.0810 | 0.0494 | 1.05x | 2.48x | 4.06x | 2.36x |
| sum_i64_validity | 0.3510 | 0.3217 | 0.1164 | 0.0541 | 1.09x | 3.02x | 6.49x | 2.76x |
| sum_f64 | 0.3695 | 0.3688 | 0.0556 | 0.0513 | 1.00x | 6.65x | 7.20x | 6.63x |
| minmax_i64 | 0.5536 | 0.5539 | 0.1063 | 0.0501 | 1.00x | 5.21x | 11.05x | 5.21x |
| bitmap_and | 0.0029 | 0.0039 | 0.0025 | 0.0024 | 0.74x | 1.16x | 1.21x | 1.56x |
| bitmap_popcount | 0.1149 | 0.0141 | 0.0020 | 0.0009 | 8.15x | 57.45x | 127.67x | 7.05x |
| hash_i64 | 0.6308 | 0.5853 | 0.3611 | 0.1242 | 1.08x | 1.75x | 5.08x | 1.62x |
| compare_i64 | 2.9858 | 0.2848 | 0.1410 | 0.1658 | 10.48x | 21.18x | 18.01x | 2.02x |
| group_sum_i64_1024 | 0.6928 | 0.5819 | 0.4326 | 0.4372 | 1.19x | 1.60x | 1.58x | 1.35x |
| gather_i64 | 0.8514 | 0.7322 | 0.8159 | 0.7300 | 1.16x | 1.04x | 1.17x | 0.90x |

### Pinned to CPU 8 (32 MB L3 CCD, data streams from DRAM), median of 3 runs

| kernel | reference | x86_scalar | x86_avx2 | x86_avx512 | scalar/ref | avx2/ref | avx512/ref | avx2 vs scalar |
|---|---|---|---|---|---|---|---|---|
| filter_i64_sel10 | 0.7558 | 0.3558 | 0.1966 | 0.1589 | 2.12x | 3.84x | 4.76x | 1.81x |
| filter_i64_bitmap | 2.7648 | 0.2510 | 0.1450 | 0.1387 | 11.02x | 19.07x | 19.93x | 1.73x |
| count_i64_between | 0.3581 | 0.2837 | 0.1290 | 0.1270 | 1.26x | 2.78x | 2.82x | 2.20x |
| sum_i64 | 0.2336 | 0.2343 | 0.1412 | 0.1113 | 1.00x | 1.65x | 2.10x | 1.66x |
| sum_i64_validity | 0.3626 | 0.3457 | 0.1574 | 0.1284 | 1.05x | 2.30x | 2.82x | 2.20x |
| sum_f64 | 0.3735 | 0.3800 | 0.1237 | 0.1023 | 0.98x | 3.02x | 3.65x | 3.07x |
| minmax_i64 | 0.5421 | 0.5459 | 0.1543 | 0.1144 | 0.99x | 3.51x | 4.74x | 3.54x |
| bitmap_and | 0.0025 | 0.0034 | 0.0022 | 0.0023 | 0.74x | 1.14x | 1.09x | 1.55x |
| bitmap_popcount | 0.1131 | 0.0138 | 0.0019 | 0.0010 | 8.20x | 59.53x | 113.10x | 7.26x |
| hash_i64 | 0.6118 | 0.5929 | 0.4797 | 0.4321 | 1.03x | 1.28x | 1.42x | 1.24x |
| compare_i64 | 2.8804 | 0.3715 | 0.3232 | 0.3198 | 7.75x | 8.91x | 9.01x | 1.15x |
| group_sum_i64_1024 | 0.7041 | 0.6129 | 0.4853 | 0.4844 | 1.15x | 1.45x | 1.45x | 1.26x |
| gather_i64 | 2.9159 | 2.5522 | 2.3178 | 2.3175 | 1.14x | 1.26x | 1.26x | 1.10x |

Reading the numbers:

* From DRAM, most streaming kernels hit the memory-bandwidth ceiling of
  roughly 60–80 GB/s per core: `sum_*`, `minmax`, `count` and `hash` (which
  reads 8 bytes, writes 8 and does an RFO of 8 per row). There, AVX2 and
  AVX-512 converge. In L3 the compute advantage shows: AVX-512 `hash` is 5×
  the reference, `minmax_i64` 11×, `sum_i64_validity` 6.5×.
* `filter_i64_bitmap` and `compare_i64` gain the most (10–43×), because the
  reference sets bits one at a time.
* `group_sum_i64` is bounded by the dependent scatter (load-add-store into
  `sums[g]` and `counts[g]`). `gather_i64` is bounded by random-access latency.
  Both gain only modestly.

### 128-bit kernels (CR-4)

These are the four kernels that `tests/kernel_bench.c` added for CR-4:

* `filter_i128_sel10`: LT, about 12% selected, no validity;
* `count_i128_between`: no validity;
* `sum_i128`: no validity;
* `minmax_i128`: with validity, 7/8 valid.

The column is 4,194,304 wide decimals with values `±d·10^20`, which need the
high limb; it takes 64 MB. The numbers are ns per row, so lower is better.

**Official `make -C native-kernels bench` (final commit, unpinned):**

| kernel | reference | x86_scalar | x86_avx2 | x86_avx512 | x86_scalar vs ref | x86_avx2 vs ref | x86_avx512 vs ref |
|---|---|---|---|---|---|---|---|
| filter_i128_sel10 | 1.0794 | 0.4289 | 0.3731 | 0.3686 | 2.52x | 2.89x | 2.93x |
| count_i128_between | 0.5867 | 0.3442 | 0.3115 | 0.3115 | 1.70x | 1.88x | 1.88x |
| sum_i128 | 0.4324 | 0.3315 | 0.3031 | 0.2900 | 1.30x | 1.43x | 1.49x |
| minmax_i128 | 0.8006 | 0.4833 | 0.3239 | 0.3264 | 1.66x | 2.47x | 2.45x |

**Pinned to CPU 0 (V-cache CCD, column L3-resident), median of 3 runs:**

| kernel | reference | x86_scalar | x86_avx2 | x86_avx512 | scalar/ref | avx2/ref | avx512/ref | avx2 vs scalar |
|---|---|---|---|---|---|---|---|---|
| filter_i128_sel10 | 1.1181 | 0.3533 | 0.2756 | 0.1952 | 3.16x | 4.06x | 5.73x | 1.28x |
| count_i128_between | 0.5807 | 0.2730 | 0.1902 | 0.1931 | 2.13x | 3.05x | 3.01x | 1.44x |
| sum_i128 | 0.3863 | 0.2159 | 0.1478 | 0.1458 | 1.79x | 2.61x | 2.65x | 1.46x |
| minmax_i128 | 0.8124 | 0.4546 | 0.2051 | 0.2208 | 1.79x | 3.96x | 3.68x | 2.22x |

**Pinned to CPU 8 (32 MB L3 CCD, column streams from DRAM), median of 3 runs:**

| kernel | reference | x86_scalar | x86_avx2 | x86_avx512 | scalar/ref | avx2/ref | avx512/ref | avx2 vs scalar |
|---|---|---|---|---|---|---|---|---|
| filter_i128_sel10 | 1.0936 | 0.4265 | 0.3899 | 0.3568 | 2.56x | 2.80x | 3.07x | 1.09x |
| count_i128_between | 0.6043 | 0.3582 | 0.3394 | 0.3288 | 1.69x | 1.78x | 1.84x | 1.06x |
| sum_i128 | 0.4575 | 0.3424 | 0.3257 | 0.3119 | 1.34x | 1.40x | 1.47x | 1.05x |
| minmax_i128 | 0.8180 | 0.5040 | 0.3371 | 0.3385 | 1.62x | 2.43x | 2.42x | 1.50x |

The official unpinned run landed on the DRAM-bound CCD, so its numbers match
the CPU 8 table. In the same run the 16 original kernels reproduced the
tables above within noise (for example `filter_i64_sel10` 0.79 / 0.34 / 0.19
/ 0.16 ns).

Reading the 128-bit numbers:

* **From DRAM** the SIMD variants converge at about 0.29–0.39 ns/row
  (16-byte rows) and scalar at 0.33–0.50. That is memory-bound.
  * The vector variants still beat scalar by 5–50%. Most of that comes from
    `minmax` (1.5×).
  * A standalone harness running the same kernels reached about 72 GB/s for
    `sum_i128` on CPU 8, versus about 50 GB/s here. So part of the gap to
    the 64-bit kernels' ~75 GB/s comes from the benchmark process (memory
    placement), not from the kernels.
* **In L3** the SIMD variants are 2.6–5.7× faster than the reference.
  * AVX-512 is clearly ahead only for `filter_i128`, where `vpcompressd`
    emission is cheap.
  * For count, sum and minmax AVX-512 is on par with AVX2. Its k-mask
    compare chains (3 compares + `korb` per 128-bit predicate) cost about
    as much as AVX2's vector compares + blend at half the width.
  * With its lazy update, AVX2 `minmax_i128` is slightly faster than the
    branch-free AVX-512 version on this (random) data.
* **Scalar** is 1.3–3.2× faster than the reference everywhere. The reference
  pays for `__int128` compares through `memcpy` loads and branches.

## Limitations / notes

* `x86_scalar` is GPR-only by design (so it runs on any x86-64). Its
  `bitmap_and/or/andnot` (8-byte words) are about 0.75× the reference, which
  gcc auto-vectorizes with SSE2. Every other scalar kernel is faster than the
  reference or within measurement noise of it (`sum_f64` 0.98–1.00× because
  it must keep the sequential order; `gather_i64` 0.96–1.16× across runs).
* SIMD `sum_f64` is not bit-identical to sequential summation (reassociation,
  allowed by the header). Everything else in every variant is bit-identical to
  the reference, including the sign of zero in `minmax_f64`.
* `gather_i64` and `group_sum_i64` are essentially scalar in all variants
  (AVX2 `group_sum_i64` now uses one 16-byte vector read-modify-write per
  row on a local table when no overflow is possible). `vpgatherqq` was
  measured and rejected (above). A conflict-free vector scatter would need
  AVX512CD, which is not in the checked feature set.
* No software prefetching (except AVX2 `gather_i64`, where it is 1.5–2x from
  DRAM) and no non-temporal stores. Prefetching sequential streams gained
  about 10% from DRAM in isolated tests, and nothing measurable on this busy
  host during the throughput work. NT stores would help `hash_i64` from DRAM
  but hurt when the hashes are consumed right away from cache, which is the
  usual case.
* The AVX-512 alignment peel only applies when the column is 8-byte aligned
  and validity is NULL. Kernels with validity or with bitmap output keep their
  64-row/8-row block alignment relative to row 0, so the bitmap bits stay
  byte-aligned.
* 128-bit kernels:
  * The scalar `minmax_i128` range test is data-dependent. Monotonic data or
    frequent unpredictable updates bring it down to about reference speed
    (see the table under CR-4 performance decisions). The SIMD variants are
    robust: AVX2 is at most +30% on ascending data, and AVX-512 is
    branch-free.
  * AVX2 handles the last 1–3 rows of a predicate block one row at a time,
    and `sum_i128` with validity runs its final partial 64-row block in
    scalar code. The cost is bounded by 63 rows per call.
  * No AVX-512 instruction outside F/BW/VL/DQ (+BMI2) is used for CR-4
    either. VPOPCNTDQ or AVX512-IFMA were not considered.
  * Values outside the decimal(38) range are not special-cased. Following
    CR-4, the kernels work on the full int128 domain.
* All results come from this single Zen 5 host. Microarchitecture-specific
  choices (masked loads, gathers, POPCNT vs. `vpshufb`) may need revisiting on
  Intel cores.
* CR-5 structure:
  * The Makefile does not list the `*.h` include files as prerequisites
    (the Makefile is outside this directory and was not changed). After
    editing a header, `make clean` first.
  * Helpers and tables defined once in a header are emitted once per variant
    object that uses them (e.g. `lvp` is in all three objects, as before
    CR-5). Sharing them across objects would have needed cross-file hidden
    symbols, and it would have changed code placement for no benefit.
  * The skeleton tags follow the existing code layout instead of reordering
    code (see [Kernel skeleton](#kernel-skeleton-and-label-scheme)), so a few
    kernels have an out-of-line part after their `ret`.
  * `structure_check.py` checks `Clobbers:` against the registers the code
    *can* write (all paths, all reachable helpers). A register that a kernel
    pushes and pops around a helper call may be listed or omitted; such
    cases say "preserved" in the header comment.
