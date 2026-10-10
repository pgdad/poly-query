# PolyQuery native kernels: AArch64 assembly

This directory has the AArch64 (GNU `as`, AAPCS64) implementations of all 16
kernels declared in `../include/pq_kernels.h`:

| File | Variant | Status |
|---|---|---|
| `pq_a64_scalar.S` | `a64_scalar` (required) | 16/16 kernels, base A64 only (GPR + scalar FP) |
| `pq_a64_neon.S`   | `a64_neon` (required)   | 16/16 kernels, Advanced SIMD |
| `pq_a64_sve.S`    | `a64_sve` (optional)    | 16/16 kernels, SVE, vector-length agnostic |
| `pq_a64_macros.h` | shared assembler macros | `FUNC`/`ENDF`, `PRED_SETUP`, `SPRED`, `VBIT`, fmix64 helpers |

Each kernel is exported as a global `pqk_<variant>_<kernel>` function with
`.type`/`.size`. The dispatcher in `../reference-c/pq_dispatch.c` finds them
through weak references. Every `.S` file ends with a `.note.GNU-stack`
section. Each file starts with a header comment covering register usage and
algorithms, and each function has a comment listing its register roles.

## Test results

All AArch64 testing ran under **qemu-user emulation** (qemu 8.2.2,
`aarch64-linux-gnu-gcc` 13.3). The emulated runs check correctness only.
No AArch64 hardware was available.

```
$ make -C native-kernels test-cross
== AArch64 (qemu-user emulation; functional only) ==
available variants: reference,a64_sve,a64_neon,a64_scalar (default: a64_sve)
  a64_scalar  16/16 kernels  PASS
  a64_neon    16/16 kernels  PASS
  a64_sve     16/16 kernels  PASS
kernel tests: 3 variant(s) tested, 0 failure(s)
```

`make -C native-kernels test` also passes. On this x86-64 host its native and
ASan stages test only the C reference, because there is no `x86_64/`
directory yet.

I also ran checks beyond the official test. They used a throwaway harness
that is not committed, because the rules allow only assembly here:

* **Guard pages**: every input and output buffer ended exactly at a
  `PROT_NONE` page, so any read or write past the documented size faults.
  qemu-user enforces this; a deliberate over-read was confirmed to SEGV. All
  variants passed with validity bitmaps of exactly `ceil(n/8)` bytes,
  exact-size bitmaps for popcount, and exact-size outputs.
* **Bit-exactness**: `minmax_f64` was compared with `memcmp`, not `==`,
  using data full of `+0.0`/`-0.0`. Scalar `sum_f64` was also compared
  bit for bit.
* **Edge cases**: `a = INT64_MIN/INT64_MAX` with LT/GT, BETWEEN with `a > b`,
  invalid ops (including negative values), `ngroups == 0`,
  `ngroups >= 2^32`, ids of `0xFFFFFFFF`, `counts == NULL`, every
  aliasing mode of the bitmap ops, `compare_fixed` widths 0..69, and large
  sums that overflow or cancel.
* **SVE vector lengths**: VL = 128, 256, 384, 512, 640, 1024 and 2048 bits
  (`-cpu max,sve-default-vector-length=N`). This includes non-power-of-two
  lengths.
* **Block boundaries**: the long-input flush paths are `sum_i64` blocks
  (2^24 groups for NEON, 2^24 rows for SVE) and `bitmap_popcount` blocks
  (2^20 iterations). Normal test sizes never reach them. I tested them by
  rebuilding a temporary copy with the block constants shrunk to 2–4.
* **Shared library**: `-fPIC -shared` links with `-z text` and fatal linker
  warnings: no text relocations, and `GNU_STACK` is RW (not executable).
  The test also passes when linked dynamically against that `.so`.

## Benchmarks

**None.** `make bench` runs only on the native architecture, and this
machine is x86-64, where `make bench` measures only the C reference and x86 variants. Timings
under qemu are meaningless, so I did not record or report any. Once AArch64
hardware is available, run
`make -C native-kernels bench` to get the `a64_scalar` / `a64_neon` /
`a64_sve` numbers in `build/aarch64/bench.jsonl`.

As a rough guide only, here are instruction counts for the hot loops,
counted from the source. They are **not** measurements.

| kernel (no validity) | a64_scalar instr/row | a64_neon instr/row |
|---|---|---|
| filter_i64 | 11 | ≈3.6 (57 per 16 rows, branch-free) |
| count_i64 | 10 | ≈1.9 |
| sum_i64 (exact) | 8 | 1.0 (LD2 + UADALP/SADALP) |
| sum_f64 | 6 (one serial FADD chain) | ≈0.9 (8 independent partial sums) |
| minmax_i64 | 11 | ≈2.4 |
| compare_i64 | ≈14 | ≈1.8 |
| bitmap_and (per byte) | ≈0.9 | ≈0.16 |
| bitmap_popcount (per byte) | ≈1.75 (SWAR) | ≈0.19 (CNT) |
| hash_i64 | 10 | ≈7.75 (4-way interleaved GPR, more ILP) |

## Design decisions

### One predicate form for every op
`PRED_SETUP` turns `(op, a, b)` into `pred(x) = ((uint64)(x - lo) <= span) XOR inv`.
For example, LT becomes `[INT64_MIN, a-1]`, and an empty set (LT `INT64_MIN`,
GT `INT64_MAX`, BETWEEN with `a > b`) becomes an inverted always-true range.
The full table is in the macro header. Because of this, each predicate
kernel has a single branch-free inner loop: `SUB`+`CMP`+`CSET` in scalar
code, `SUB`+`CMHS` in NEON, `SUB`+`CMPHS` in SVE. The inversion costs one
`EOR` on a 16-bit mask (NEON) or on a predicate (SVE). Invalid ops are
rejected by checking `op` as an unsigned 32-bit value, before anything is
read, so `n == 0` still returns `(size_t)-1` for a bad op, as in the
reference. Only the W view of `int` arguments is used, because AAPCS64
leaves the upper 32 bits undefined.

### Validity bitmaps
* Scalar: the bit is fetched per row (byte load + shift). When the pointer
  is NULL, a well-predicted branch skips the fetch.
* NEON: `LD1R` replicates one validity byte, and `CMTST` against per-lane
  bit constants turns it into 64-bit lane masks for 8 rows. Index and bitmap
  filters build a 16-bit row mask instead and `AND` it with an unaligned
  `LDRH` of the validity.
* SVE: `LD1B` gathers each lane's byte (`row >> 3`) under the loop
  predicate, then shifts and tests it. The vector length need not be a
  multiple of 8 rows, so a gather is the only general method that never
  reads past `ceil(n/8)` bytes.

### filter_i64 (index output)
NEON uses a 256×8 position table (`.Lselpos`) and a 256-entry popcount table
(`.Lselcnt`). The assembler generates both from their definitions with
`.rept`/`.if`; no external generator is involved. Each 8-row mask byte
loads 8 packed positions, widens them to u32, adds the row base, and stores
32 bytes unconditionally. The cursor then advances by the popcount. The
over-store stays inside the documented capacity (`>= n`): in the main loop
the cursor `k <= i` and `i + 8 <= n` for both halves of a 16-row block. The
scalar variant uses the same idea one row at a time. SVE uses `COMPACT` and
a predicated truncating `ST1W`, so it never over-stores.

### sum_i64 exact overflow handling
The reference accumulates in 128 bits, and only the final sum must fit in
int64.
* Scalar: `ADDS`/`ADC` into a 128-bit register pair.
* NEON: `LD2 {.4s}` splits every int64 into an unsigned low half and a
  signed high half. `UADALP`/`SADALP` accumulate them pairwise into 64-bit
  lanes, using two independent accumulator pairs. A block is at most 2^24
  iterations, so the lanes stay below 2^58 and 2^57 and cannot wrap. Each
  block is folded into a 128-bit GPR total as `lo + (hi << 32)`.
* SVE: the same split, with `AND`/`ASR` and merging `ADD` in blocks of 2^24
  rows, reduced with `UADDV`.
* In every variant, overflow means the 128-bit result is outside int64.
  Intermediate overflow that later cancels out is therefore correctly
  reported as OK.

### Floating point
* `sum_f64`: scalar is strictly sequential and bit-identical to the
  reference. Invalid rows add `+0.0`, which changes nothing because the
  running sum can never be `-0.0`. NEON keeps 8 lane-wise partial sums, SVE
  keeps VL/64 of them. The header's tolerance allows this reassociation.
* `minmax_f64`: scalar uses `FCMP`/`FCSEL` with the reference's strict
  comparisons, starting from ±inf. NEON uses `FMINNM`/`FMAXNM`; invalid
  lanes are forced to all-ones with `ORN`, which is a quiet NaN that
  `FMINNM` ignores. The only lane-order-dependent part is the sign of a zero
  result. The reference returns the *first valid zero* in row order in that
  case, so NEON and SVE re-scan for it when the result is ±0. That makes
  them bit-identical to the reference, not just `==`-equal.

### Kernels where SIMD gives little and why
* `hash_i64` (NEON): Advanced SIMD has no 64×64-bit multiply. Building one
  from `UMULL`/`MUL .2s`/`MLA`/`SHLL` costs about 7 vector ops per multiply
  for 2 lanes, roughly 10 ops per element against 6 GPR ops. The NEON
  variant therefore uses a 4-way interleaved GPR pipeline. SVE does have
  `MUL .d`, so the SVE version is fully vectorized.
* `group_sum_i64`: scatter-adds with possible id conflicts cannot be done in
  NEON or base SVE. Id validation is vectorized (`UMAX` of masked ids, or
  `UMAX`+`INCP` in SVE). The accumulation is scalar in row order, with an
  `ADDS` + `CSINC` overflow flag, so the overflow flag matches the
  reference exactly. Pass 1 validates every valid row before any output is
  written, so outputs stay untouched on EINVAL.
* `gather_i64`: NEON has no gather, so it uses unrolled scalar loads. SVE
  uses `LD1W` + `LD1D` gather.

### Bitmap outputs and counts
* NEON writes 16 rows per `STRH`, and a scalar tail writes the last 1–2
  zero-padded bytes. The returned count is the popcount of the finished
  bitmap, via a tail call into the shared `bitmap_popcount` loop. That pass
  is about 1/64 of the input bytes and keeps the main loop short.
* SVE builds 64-row blocks with `ORV` of `1 << (row & 63)` and stores one
  word per block (byte stores for the last partial block). This works for
  any VL.

### Bitmap and/or/andnot aliasing
`out` may equal `a` or `b`. Every chunk is loaded from both inputs before it
is stored, and there is no overlapping "last vector" trick. That trick would
be wrong for `andnot` when `out == b`. The tails step down 64 → 16 → 8 → 1
bytes.

### compare_fixed
* NEON compares 16-byte `CMEQ` chunks. `SHRN #4` packs them into a 64-bit
  nibble mask, `CMN #1` tests for all-equal, and `RBIT`+`CLZ` finds the
  first differing byte. After that come one 8-byte step (`REV` makes the
  words big-endian, so unsigned compare gives lexicographic order) and
  single bytes.
* SVE uses `CMPNE` on byte vectors, then `BRKB`+`LASTA` to pick out the
  first differing bytes.

### ABI conformance
* Every function is a leaf. NEON's `filter_i64_bitmap` and `compare_i64`
  tail-call a local label, which is a plain branch. No function uses the
  stack or `sp`.
* Only caller-saved registers are used: x0–x17, v0–v7, v16–v31, and
  z0–z7, z16–z31 plus p0–p15 for SVE. x18 and x19–x29 are never touched,
  and neither are v8–v15/z8–z15, whose low halves d8–d15 are callee-saved.
  I checked this with grep over the sources.
* All loads and stores are ordinary (non-exclusive) accesses, so unaligned
  pointers are fine on AArch64 Linux. No load ever spans past a buffer end.
* Constant tables live in `.rodata` and are addressed with `ADRP`/`:lo12:`,
  which is position independent and works both static and in a shared
  library.

### SVE specifics
* The file uses `.arch armv8.2-a+sve`, so no Makefile flags are needed. The
  code runs only when the dispatcher sees `HWCAP_SVE`.
* Loops are `WHILELO`/`B.FIRST` with `INCD`/`INCB`, so there are no scalar
  tails. Block loops reset the row counter to the exact block end, because
  with non-power-of-two VLs `INCD` can overshoot a block boundary.
* qemu's default CPU (`max`) reports SVE, so `test-cross` tests all three
  variants, and `a64_sve` becomes the default variant under emulation.

## Limitations
* No performance numbers: there is no AArch64 hardware, and emulated timings
  are meaningless. The SIMD design choices are based on instruction counts
  and published pipeline characteristics, not measurements.
* NEON `hash_i64`, `gather_i64` and `group_sum_i64` (accumulation pass) are
  scalar by design, for the reasons above.
* `filter_i64` assumes `n < 2^32`, as the header specifies: indices are
  formed in 32-bit lanes.
* SVE has been run only under emulation. `filter_i64_bitmap`/`compare_i64`
  and the validity gather are written for generality across vector lengths,
  not peak speed on a particular core.
