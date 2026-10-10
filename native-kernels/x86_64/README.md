# PolyQuery native kernels — x86-64 assembly

All 16 kernels of `include/pq_kernels.h` (ABI v1), hand-written in GNU `as`
(AT&T syntax, `.S` files run through the C preprocessor only for `#define`
constants). There are three complete variants:

| file | variant | ISA | kernels |
|---|---|---|---|
| `pqk_x86_scalar.S` | `x86_scalar` | baseline x86-64 (GPRs + SSE2 scalar `addsd/minsd/maxsd` only; no POPCNT/BMI) | 16/16 |
| `pqk_x86_avx2.S` | `x86_avx2` | AVX2 + BMI1 + BMI2 + POPCNT | 16/16 |
| `pqk_x86_avx512.S` | `x86_avx512` (optional) | AVX-512 F/BW/VL/DQ (+BMI/POPCNT) | 16/16 |

The dispatcher finds the variants through their global symbols
`pqk_<variant>_<kernel>`. On this host it picks `x86_avx512` by default, and
`PQ_KERNELS_VARIANT=avx2|scalar|reference` overrides that. The AVX-512 file
uses only instructions from the F/BW/VL/DQ subsets, because those are the only
ones the dispatcher checks. It does **not** use VPOPCNTDQ, CD, VBMI2 or the
like, even though this Zen 5 has them.

`verify/` holds extra test tools (C and one test trampoline). They are **not**
part of the library: the Makefile only assembles `x86_64/*.S`, and `verify/`
is not matched by that wildcard. See [Verification](#verification).

## Build, test, benchmark

```bash
make -C native-kernels test        # differential tests (native + ASan/UBSan) + AArch64 cross (reference only)
make -C native-kernels bench       # micro-benchmarks, JSON lines in build/x86_64/bench.jsonl
sh native-kernels/x86_64/verify/run.sh   # extra checks: guard pages, edge cases, ABI (run from anywhere)
python3 native-kernels/x86_64/verify/bench_table.py native-kernels/build/x86_64/bench.jsonl
```

Result of `make -C native-kernels test` on the final commit:

```
available variants: reference,x86_avx512,x86_avx2,x86_scalar (default: x86_avx512)
  x86_scalar  16/16 kernels  PASS
  x86_avx2    16/16 kernels  PASS
  x86_avx512  16/16 kernels  PASS
kernel tests: 3 variant(s) tested, 0 failure(s)      (native, 3000 iterations)
... same with -fsanitize=address,undefined (1500 iterations)
```

The ASan/UBSan run prints one `runtime error: load of misaligned address` at
`tests/kernel_test.c:69`. That load is in the test program's own C code
(`data[rnd_below(n)]` on a deliberately misaligned buffer), not in a kernel.
It is non-fatal, and it was there before any assembly existed.

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
  independent chains. In the partial block, whole vectors are used while at
  least 4 rows remain, the last 1–3 rows are compared in scalar code, and the
  result is trimmed with `bzhi`.
* **AVX-512**: `vpcmpq` with an immediate predicate writes k-masks directly
  (written as "a OP' x" so that x can be a memory operand). Eight compares are
  merged with `kunpckbw/wd/dq` and moved out with `kmovq`. BETWEEN is
  `a<=x`, then a masked `b>=x`. The partial block uses zero-masked
  `vmovdqu64 {z}` loads.

Index emission in `filter_i64`:

* **scalar**: `bsf` / `x &= x-1`.
* **AVX2**: every full block that has any hit uses an 8-row compress step.
  `pdep` spreads the 8 mask bits to bytes, `imul 0xff` turns them into byte
  masks, `pext` packs the row positions `0..7`, and then `vpmovzxbd` +
  `vpaddd base` produce 8 indices, which are stored as one 32-byte store. The
  output pointer then advances by `popcnt`. Partial and empty blocks use
  `tzcnt`/`blsr`.
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
  (min/max). For sums it is widened to a full lane mask (`vpcmpgtq` against
  zero) and ANDed with a plain load. The final partial block (< 64 rows) runs
  scalar code.
* **AVX-512**: `kmovb`/`kmovw` read validity bytes straight into k registers,
  which act as merge masks on the arithmetic. Masked loads are used only for
  tails.

### Exactness

* **`sum_i64`** is exact in every variant (the result must be the exact
  mathematical sum, and wrap-around that cancels out is fine).
  * scalar: a 128-bit accumulator (`add`/`adc` with `cqo` sign extension).
  * AVX2: per lane, it accumulates `S = Σx mod 2^64`, `HU = Σ(x >>> 32)` and
    `N = #negatives`. With `LU` = the exact sum of the low 32-bit halves:
    `Σx = HU·2^32 + LU − N·2^64` and `LU = (S − HU·2^32) mod 2^64`. That is
    exact while `LU < 2^64`. Chunks of at most 2^28 rows keep `HU, LU < 2^60`.
    Each chunk is folded into a 128-bit scalar total. The cost is 5 vector ops
    per 4 rows.
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
  * AVX2 range check: `(id ^ 2^31) >s ((ng-1) ^ 2^31)`, 32 ids per `vptest`.
  * AVX-512 range check: native unsigned `vpcmpud`. `ngroups == 0` rejects
    every valid row, and `ngroups > UINT32_MAX` skips the check.
* **`hash_i64`**: AVX2 has no 64-bit multiply, so `k·c` is computed as
  `lo·clo + ((hi·clo + lo·chi) << 32)` with three `vpmuludq`. AVX-512 uses
  `vpmullq`.

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
  popped. The direction flag is never touched. MXCSR is not modified.
* No red zone is used. Internal helpers (mask routines, `lvp`, `popcnt64`)
  have documented private register conventions and use the stack only for
  `call/ret`, so stack alignment is irrelevant to them. No external function
  is ever called.
* Every function that touches ymm/zmm ends with `vzeroupper`. AVX-512 code
  uses only zmm0–15, so `vzeroupper` leaves no dirty upper or Hi16 state.
* Every symbol has `.type`/`.size`: functions as `@function`, rodata tables as
  `@object`.
* Each file ends with `.section .note.GNU-stack,"",@progbits`, and the
  resulting `.so` has a non-executable `GNU_STACK` and no `TEXTREL`.
* The code is position independent: RIP-relative constants and
  self-relative jump tables.

## Verification

Besides `make test`, `verify/run.sh` builds and runs:

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
  from DRAM. The kernel is latency-bound either way.
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
  set. AVX2 uses `popcnt` on 64-bit words with 4 accumulators, which beat a
  `vpshufb` ymm version on Zen (4 POPCNT/cycle).

## Benchmark results

`make -C native-kernels bench`: n = 4,194,304 rows (32 MB per int64 column),
median of 15 repetitions, **ns per element** (for `bitmap_*`, per bit), so
lower is better. The speedup columns are reference ns / variant ns. The
reference is the C17 implementation compiled with `-O3` (gcc auto-vectorizes
some loops with SSE2).

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

## Limitations / notes

* `x86_scalar` is GPR-only by design (so it runs on any x86-64). Its
  `bitmap_and/or/andnot` (8-byte words) are about 0.75× the reference, which
  gcc auto-vectorizes with SSE2. Every other scalar kernel is faster than the
  reference or within measurement noise of it (`sum_f64` 0.98–1.00× because
  it must keep the sequential order; `gather_i64` 0.96–1.16× across runs).
* SIMD `sum_f64` is not bit-identical to sequential summation (reassociation,
  allowed by the header). Everything else in every variant is bit-identical to
  the reference, including the sign of zero in `minmax_f64`.
* `gather_i64` and `group_sum_i64` are essentially scalar in all variants.
  `vpgatherqq` was measured and rejected (above). A conflict-free vector
  scatter would need AVX512CD, which is not in the checked feature set.
* No software prefetching and no non-temporal stores. Prefetching gained about
  10% from DRAM in isolated tests. NT stores would help `hash_i64` from DRAM
  but hurt when the hashes are consumed right away from cache, which is the
  usual case.
* The AVX-512 alignment peel only applies when the column is 8-byte aligned
  and validity is NULL. Kernels with validity or with bitmap output keep their
  64-row/8-row block alignment relative to row 0, so the bitmap bits stay
  byte-aligned.
* All results come from this single Zen 5 host. Microarchitecture-specific
  choices (masked loads, gathers, POPCNT vs. `vpshufb`) may need revisiting on
  Intel cores.
