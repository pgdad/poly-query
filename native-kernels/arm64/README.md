# PolyQuery native kernels: AArch64 assembly

This directory has the AArch64 (GNU `as`, AAPCS64) implementations of all 20
kernels declared in `../include/pq_kernels.h` (ABI version 1, revision 1:
the 16 original kernels plus the four 128-bit kernels of change request CR-4,
`../../spec/changes/kernels-i128.md`), in three variants:

| Variant | File | Status |
|---|---|---|
| `a64_scalar` (required) | `pq_a64_scalar.S` | 20/20 kernels, base A64 only (GPR + scalar FP) |
| `a64_neon` (required)   | `pq_a64_neon.S`   | 20/20 kernels, Advanced SIMD |
| `a64_sve` (optional)    | `pq_a64_sve.S`    | 20/20 kernels, SVE, vector-length agnostic |

Each kernel is exported as a global `pqk_<variant>_<kernel>` function with
`.type`/`.size`. The dispatcher in `../reference-c/pq_dispatch.c` finds them
through weak references. The sources were restructured under change request
CR-5 (`../../spec/changes/kernel-refactor.md`); the sections below describe
the structure first, then the algorithms.

## CR-5 restructuring at a glance

* **Shared building blocks are defined once**, in three include files
  (C preprocessor `#include`, suffix `.h`, so the Makefile does not assemble
  them as translation units): `pq_a64_common.h` (all variants),
  `pq_a64_neon.h` (several NEON kernels) and `pq_a64_sve.h` (several SVE
  kernels). They contain only constants and GNU `as` macros; the NEON
  constant tables are a macro that `pq_a64_neon.S` invokes exactly once.
* **Every kernel has the same skeleton and a header comment** (Args, Result,
  Clobbers, Registers, Algorithm, Tail), and all labels follow one scheme
  (see below).
* **Nothing observable changed.** The object files assembled from the new
  sources are *byte-identical* to the ones before the restructuring: same
  `.text` and `.rodata` bytes, same symbols with the same values and sizes,
  same relocations, same section layout. This is how behaviour preservation
  and "no performance regression" were established (details under
  [Behaviour and performance](#behaviour-and-performance)).

## Module map

### Before (baseline 2b9f40d)

| File | Lines | Contents |
|---|---:|---|
| `pq_a64_macros.h` | 250 | 13 macros shared by all variants: `FUNC`/`ENDF`, `PRED_SETUP`, `SPRED`, `VBIT`, `LOAD_FMIX`, `FMIX1`, `PRED128_SETUP`, `SPRED128`, `MIN128`/`MAX128`, `MIN128V`/`MAX128V` |
| `pq_a64_scalar.S` | 709 | 20 scalar kernels; local macros `SBITOP`, `SWARPOP`, `SCMPBITS` |
| `pq_a64_neon.S` | 1753 | constant tables (`.Lbitsel16`, `.Lbits2d`, `.Lbits4s`, `.Lselpos`, `.Lselcnt`); 13 macros (`LOADADDR`, `PACK16`, `RANGE16`, `EMIT8`, `MMSTEP`, `NBITOP`, `CMP16`, `RNG2`, `RNG8`, `PACK8`, `MM2`, `MMV`, `REDMM`); 20 NEON kernels |
| `pq_a64_sve.S` | 937 | 10 macros (`SVE_VALID`, `ROWPRED`, `INVPRED`, `BITMAP_BLOCKS`, `RANGE_PRED`, `VBITOP`, `CMPEQ_PRED`, `CMPGT_PRED`, `RANGE128`, `SETUP128`); 20 SVE kernels |
| `README.md` | 345 | documentation |
| **Total (sources)** | **3649** | |

Problems that CR-5 addresses: variant-specific helpers were mixed with the
kernels; several blocks were written out more than once (the compare_i64
operator check and operand swap in all three files, the sum_i64/sum_i128
overflow epilogues in all three, the 192-bit limb fold in NEON and SVE, the
signed-zero fix-up of minmax_f64 in NEON and SVE, the group_sum
scatter-add four times, the bitmap byte tail, popcount of a partial byte,
validity-mask expansion and tail validity bytes many times in NEON, ...);
labels mixed three-letter prefixes (`.Lsf_`, `.Lnfb_`, `.Lvs8_`, ...) with
122 numeric labels (`1:`/`1b`); per-kernel comments had different shapes.

### After

| File | Lines | Contents |
|---|---:|---|
| `pq_a64_common.h` | 735 | Building blocks of all variants (43 macros + constants), in 11 sections: 1. constants (`PQK_*` status/op codes mirrored from the ABI header, `PQ_INT64_MIN/MAX`, `PQ_F64_PINF/NINF`, `PQ_FMIX_C1/C2`); 2. framing (`FUNC`, `ENDF`, `PQ_FILE_END`, `RET_*`); 3. operator validation and dispatch; 4. scalar predicates and validity bits; 5. exact integer accumulation and sum results; 6. min/max; 7. bitmaps and bit counting; 8. fmix64; 9. compare_fixed; 10. group_sum; 11. `LOADADDR` |
| `pq_a64_neon.h` | 362 | NEON building blocks used by more than one NEON kernel (22 macros): `NEON_TABLES` (all constant tables), validity masks, 16-row range predicate and compaction, 128-bit row helpers, bitmap-writer tails |
| `pq_a64_sve.h` | 198 | SVE building blocks used by more than one SVE kernel (10 macros): validity predicate, row loads, range predicates, 64-row block bitmap writer |
| `pq_a64_scalar.S` | 796 | 20 scalar kernels in the uniform skeleton; kernel-local macros `SCALAR_BITOP`, `SWARPOP`, `SCALAR_CMPBITS`, `MIN128V`/`MAX128V` |
| `pq_a64_neon.S` | 1578 | `NEON_TABLES` invocation, block-size constants, 20 NEON kernels; kernel-local macros `SUM64_ACC`, `F64_ACC8`, `MMSTEP`, `F64_MINMAX8`, `COUNT8`, `NEON_BITOP`, `CMP16`, `CMP16_LOOP`, `PACK8`, `COUNT128_8`, `SUM128_ACC`, `MM2`, `MMV`, `REDMM` |
| `pq_a64_sve.S` | 873 | block-size constant, 20 SVE kernels; kernel-local macros `RANGE_PRED`, `SVE_BITOP`, `CMP_PRED` |
| `README.md` | — | this file |
| **Total (sources)** | **4542** | |

The sources grew by about 900 lines although duplicated code was removed:
the per-kernel header comments (Args/Result/Clobbers/Registers/Algorithm/
Tail for 60 functions), the documented macro interfaces and the section
markers account for more than that. The amount of *instruction* text fell.

Include order: every variant includes `pq_a64_common.h` first, then its own
`pq_a64_neon.h` / `pq_a64_sve.h`. All headers have include guards. Placement
rule: a block lives in a header iff more than one kernel or more than one
variant uses it; a macro used by exactly one kernel is defined directly
above that kernel (so one kernel can be read and changed without the
others).

## Kernel skeleton and naming

Every kernel in every file has this shape:

```
/* ========================================================================
 * <kernel>
 * Args:      argument registers (x0 data, x1 validity, ...)
 * Result:    return register and value
 * Clobbers:  every register the kernel writes, plus flags
 * Registers: role of each register inside the kernel
 * Algorithm: what the main loop does and why it is exact / safe
 * Tail:      how the rows after the last full vector / block are handled
 * ======================================================================== */
FUNC pqk_a64_<variant>_<kernel>
    // -- 1. arguments / empty input   op validation, constants, n == 0 / n < block
    // -- 2. main loop                 .L<variant>_<kernel>_main  (_main_v / _main_nv)
    //       (+ horizontal reduction of vector accumulators, where present)
    // -- 3. tail                      .L<variant>_<kernel>_tail  (or "tail: none")
    // -- 4. result                    .L<variant>_<kernel>_result
    error exits                        .L<variant>_<kernel>_inval
ENDF pqk_a64_<variant>_<kernel>
```

* The `Clobbers` lines were checked mechanically against the disassembly
  (registers written by each of the 60 functions, including the NEON
  popcount tail call); they match exactly.
* Label scheme: kernels use only named labels
  `.L<variant>_<kernel>_<step>` with `<variant>` ∈ {`scalar`, `neon`,
  `sve`}. Standard steps are `main`, `main_v`/`main_nv` (copies with / without
  validity), `tail`, `tail_row`, `result`, `inval`, `ok`; other steps have
  descriptive names (`block`, `fold`, `reduce`, `rec`, `diff`, ...). Labels
  inside macros are `.L<macro>_<step>\@`. There are no numeric labels left.
  The only data labels are the NEON tables, `.Lneon_<table>`.
* Macro arguments: macros that need both the W and the X view of a register
  take bare numbers (`SPRED 12, 7, 8, 9`), all others take full register
  names.
* In the scalar variant most kernels process one row per iteration, so their
  section 3 is "tail: none". In the SVE variant section 3 is always "none":
  the `WHILELO` predicate covers the last partial vector.

## Shared building blocks and their users

S = `a64_scalar`, N = `a64_neon`, V = `a64_sve`. "Users" are the kernels
that expand the block, directly or through another block.

### `pq_a64_common.h` (all variants)

| Block | Purpose | Users |
|---|---|---|
| `PQK_*`, `PQ_INT64_MIN/MAX`, `PQ_F64_PINF/NINF`, `PQ_FMIX_C1/C2` | constants (status/op codes as in the ABI header, value limits, fmix64 multipliers) | op checks, sum results, minmax inits (S N V), hash_i64 (S N V) |
| `FUNC`, `ENDF` | `.text`, `.globl`, `.type %function`, `.p2align 4`, `.size` | all 60 functions |
| `PQ_FILE_END` | `.note.GNU-stack` (non-executable stack) | the three variant files |
| `RET_INVALID_OP` | return `(size_t)-1` | filter_i64, filter_i64_bitmap, count_i64, compare_i64, filter_i128, count_i128 (S N V) |
| `RET_STATUS` | return a status constant | sum_i64, sum_i128, group_sum_i64 (S N V) |
| `RET_X`, `RET_W` | return a register | RET_X: count results of popcount, count_*, minmax_*, and of filter_*/compare_i64 in S and V; RET_W: group_sum_i64 (S N V) |
| `PRED_SETUP` | validate op, build the 64-bit range predicate `((x-lo) <=u span) ^ inv` | filter_i64, filter_i64_bitmap, count_i64 (S N V) |
| `PRED128_SETUP` | validate op before `*a`/`*b` are read, 128-bit range predicate | filter_i128, count_i128 (S N V) |
| `CMPOP_CHECK`, `CMPOP_SWAP` | compare_i64 op validation, EQ/GT + inversion reduction, LT/GE operand swap | compare_i64 (S N V) |
| `SPRED` | scalar 64-bit range predicate | filter_i64, filter_i64_bitmap, count_i64 (S; N tails) |
| `SPRED128` | scalar 128-bit range predicate | filter_i128, count_i128 (S; N tails) |
| `VBIT` | fetch the validity bit of one row | S: every kernel with a validity argument; N: tails of filter_i64, filter_i64_bitmap, filter_i128, count_i128, sum_i128, minmax_i128, plus minmax_f64 (zero scan) and group_sum_i64; V: minmax_f64 (zero scan), group_sum_i64 |
| `AND_VBIT` | AND a predicate bit with the row's validity (NULL-aware) | filter_i64, filter_i64_bitmap, count_i64, filter_i128, count_i128 (S; N tails) |
| `ADD128S`, `ADD192S` | add one sign-extended row to a 128-bit / 192-bit accumulator | sum_i64 / sum_i128 (S; N tails) |
| `FOLD_SUM64` | fold a block of split-half sums: `lo + (hi << 32)` | sum_i64 (N V) |
| `FOLD_LIMBS192` | fold a block of four 32-bit limb sums into 192 bits | sum_i128 (N V) |
| `BLOCK_END` | end row of the next bounded accumulation block | sum_i128 (N V), sum_i64 (V) |
| `SUM64_RESULT`, `SUM128_RESULT` | exact-sum overflow test, store, status | sum_i64, sum_i128 (S N V) |
| `MIN128`, `MAX128` | signed 128-bit min/max in GPR pairs (CMP/SBCS + CSEL) | minmax_i128 (S; N reduction and tail) |
| `MINMAX64_STEP`, `F64_MINMAX_STEP` | scalar min/max update (strict `<`/`>` for doubles) | minmax_i64, minmax_f64 (S; N tails) |
| `MINMAX_RESULT`, `MINMAX128_RESULT` | store outputs iff count > 0, return count | minmax_i64 (S N), minmax_f64 (S), minmax_i128 (S N) |
| `F64_FIRST_ZERO` | signed-zero fix-up (first valid zero, as the reference) | minmax_f64 (N V) |
| `SBITMAP_PUT`, `SBITMAP_FLUSH` | row-at-a-time bitmap writer | filter_i64_bitmap, compare_i64 (S) |
| `BITOP_STEP8`, `BITOP_BYTES` | 8-byte step / byte tail of and/or/andnot | bitmap_and/or/andnot (S N) |
| `LOWBITS` | mask of the low n bits | bitmap_popcount (S N V), group_sum_i64 (N) |
| `ADD_CNT8`, `ADD_POPCNT_LOW` | popcount of a (partial) byte with `CNT` | bitmap_popcount (N V) |
| `LOAD_FMIX`, `FMIX1` | fmix64 multipliers / one fmix64 round | hash_i64 (S N V / S N) |
| `CFX_BYTES`, `CFX_RESULT` | compare_fixed byte loop / per-record result | compare_fixed (S N) |
| `GSUM_ADD` | row-order scatter-add with overflow flag | group_sum_i64 (S N V) |
| `GSUM_ROWS` | complete row-order accumulation loop | group_sum_i64 (S V) |
| `LOADADDR` | PC-relative address of a table | 13 NEON kernels (all that use a table) |

### `pq_a64_neon.h` (NEON kernels)

| Block | Purpose | Users (N) |
|---|---|---|
| `NEON_TABLES` | `.rodata`: `.Lneon_bitsel16`, `.Lneon_bits2d`, `.Lneon_bits4s`, `.Lneon_selpos`, `.Lneon_selcnt` (the last two generated with `.rept`) | emitted once by pq_a64_neon.S; used by the kernels listed below |
| `VMASK2D`, `VMASK4S` | validity byte → 64-/32-bit lane masks (`CMTST`) | sum_f64, minmax_i64, minmax_f64, count_i64, count_i128 / sum_i64, group_sum_i64, sum_i128 |
| `LD8_VMASK2D`, `COUNT_VALID8` | 8 rows + validity masks; valid-row counter | sum_f64, minmax_i64, minmax_f64 / minmax_i64, minmax_f64 |
| `TAIL_VBYTE` | validity byte of a ≤ 7-row tail | sum_i64, sum_f64, minmax_i64, minmax_f64, count_i64, group_sum_i64 |
| `RANGE_LANES` (+`RANGE_SUB`, `RANGE_CMHS`) | `SUB` + `CMHS` range test on a register list | filter_i64, filter_i64_bitmap, count_i64 |
| `PACK16` | 8 lane masks → 16-bit row mask | filter_i64, filter_i64_bitmap, compare_i64 |
| `RANGE16`, `FILTER16_PROLOGUE` | 16-row range mask; section 1 of the 16-row filters | filter_i64, filter_i64_bitmap |
| `EMIT8_SETUP`, `EMIT8` | table-driven index compaction of 8 rows | filter_i64, filter_i128 |
| `PRED128_BCAST`, `RNG2`, `RNG8` | 128-bit range predicate on LD2-split rows | filter_i128, count_i128 |
| `LD2X4` | 8 pqk_i128 rows → lo/hi word vectors | filter_i128, count_i128, minmax_i128 |
| `ADDV2X` | horizontal sum of two lane counters | count_i64, count_i128 |
| `BITS_TAIL_PUT`, `BITS_TAIL_STORE`, `POPCOUNT_TAILCALL` | scalar tail and popcount result of the 16-row bitmap writers | filter_i64_bitmap, compare_i64 |

### `pq_a64_sve.h` (SVE kernels)

| Block | Purpose | Users (V) |
|---|---|---|
| `SVE_VALID`, `ROWPRED` | gathered validity bits → valid-row predicate `p1` | all row kernels except bitmap ops, popcount, hash, compare_i64, compare_fixed, gather (12 kernels) |
| `SVE_LD64` | load rows, row numbers, `p1` | filter_i64, sum_i64, sum_f64, minmax_i64, minmax_f64, count_i64 |
| `SVE_LD128` | `LD2D` rows, row numbers, `p1` | filter_i128, count_i128, sum_i128, minmax_i128 |
| `INVPRED` | inversion predicate `p6` | filter_i64, filter_i64_bitmap, count_i64, compare_i64, filter_i128, count_i128 |
| `PRED_BCAST64`, `RANGE64` | broadcast / evaluate the 64-bit range predicate | filter_i64, filter_i64_bitmap, count_i64 |
| `SETUP128`, `RANGE128` | broadcast / evaluate the 128-bit range predicate | filter_i128, count_i128 |
| `BITMAP_BLOCKS` | 64-row block bitmap writer + count result (any VL) | filter_i64_bitmap, compare_i64 |

What is deliberately *not* factored: loop control (`add`/`cmp`/`b.lo`,
`incd`/`whilelo`/`b.first`), plain register initialisation (`mov x, #0`,
`movi v, #0`), the explicitly interleaved 4-row fmix64 pipeline of NEON
`hash_i64`, and two- or three-line compositions of shared macros. A
mechanical scan for repeated runs of four or more instruction lines across
all sources now finds only such initialisation sequences.

## Behaviour and performance

**Verification that nothing changed.** Before touching anything, the three
baseline objects were assembled and kept. After every step the new sources
were assembled with the same toolchain (`aarch64-linux-gnu-gcc -c`) and
compared:

* `.text`, `.rodata`, `.data`, `.bss` and `.note.GNU-stack`: byte for byte;
* the symbol table (value, size, type, binding of all 60 functions);
* the section headers (sizes, alignment) and all relocations.

All three variants are identical in all of these. A deliberately changed
instruction was confirmed to be detected. Since the linked library is built
from the same objects in the same order, every kernel runs exactly the same
instructions at the same addresses and alignments as before.

**Expected effect of each change on the Cortex-X925 target.**

| Change | Effect on generated code | Expected performance effect |
|---|---|---|
| Shared blocks moved into `pq_a64_common.h` / `pq_a64_neon.h` / `pq_a64_sve.h` macros | none (the macro expansions are the former instruction sequences, operand for operand) | none |
| `PRED_SETUP` etc. use named constants (`PQK_*`, `PQ_INT64_*`), `LOAD_FMIX` derives its `MOVZ`/`MOVK` halves from `PQ_FMIX_C1/C2` | identical encodings | none |
| Tables emitted by `NEON_TABLES`, renamed `.Lneon_*` | identical `.rodata` bytes, alignment and relocations | none |
| Labels renamed to `.L<variant>_<kernel>_<step>`, numeric labels removed | local labels are not emitted; branch offsets identical | none |
| Kernel-local macros (`SUM64_ACC`, `CMP16_LOOP`, `MIN128V`, ...) | identical expansions | none |
| Header comments, section markers, README | none | none |

So the independent before/after measurement on native hardware should show
only run-to-run noise. Any difference larger than noise would point to an
environmental cause (frequency, placement), not to these sources.

## Test results

All AArch64 testing ran under **qemu-user emulation** (qemu 8.2.2,
`aarch64-linux-gnu-gcc` 13.3). The emulated runs check correctness only.
No AArch64 hardware was available.

```
$ make -C native-kernels test-cross
== AArch64 (qemu-user emulation; functional only) ==
available variants: reference,a64_sve,a64_neon,a64_scalar (default: a64_sve)
  a64_scalar  20/20 kernels  PASS
  a64_neon    20/20 kernels  PASS
  a64_sve     20/20 kernels  PASS
kernel tests: 3 variant(s) tested, 0 failure(s)
```

The variants and kernel counts are the same as before CR-5. Also run after
the restructuring:

* `make -C native-kernels test` passes. On this x86-64 host its native and
  ASan stages test only the C reference, because there is no `x86_64/`
  directory.
* SVE at VL = 128, 384, 512 and 2048 bits
  (`-cpu max,sve-default-vector-length=N`): `a64_sve` 20/20 PASS.
* PIC shared library (`-fPIC -shared -Wl,-z,text,--fatal-warnings`): links
  without text relocations, `GNU_STACK` is RW, all 60 `pqk_a64_*` symbols
  exported.
* ABI audit of the disassembly: no function writes x18–x30, sp, v8–v15 or
  z8–z15.

The more extensive pre-CR-5 checks (guard pages on every buffer, bit-exact
`minmax_f64`, edge values, block-boundary flushes with shrunken block
constants, SVE lengths up to 2048 bits, CR-4 128-bit harness) were done
with throwaway harnesses that are not committed, because only assembly
belongs here. Their conclusions carry over unchanged because the machine
code is byte-identical. The block sizes are now named constants
(`NEON_SUM64_BLOCK`, `NEON_POPCNT_BLOCK`, `NEON_SUM128_BLOCK`,
`SVE_SUM_BLOCK`), so the block-flush paths can be exercised by redefining
them in a temporary copy.

## Benchmarks

**None.** `make bench` runs only on the native architecture, and this
machine is x86-64, where `make bench` measures only the C reference and x86
variants. Timings under qemu are meaningless, so I did not record or report
any. Once AArch64 hardware is available, run `make -C native-kernels bench`
to get the `a64_scalar` / `a64_neon` / `a64_sve` numbers in
`build/aarch64/bench.jsonl`.

As a rough guide only, here are instruction counts for the hot loops,
counted from the source. They are **not** measurements, and CR-5 did not
change them.

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
| filter_i128 | 13 | ≈7.25 (58 per 8 rows, branch-free) |
| count_i128 | 12 | ≈5.4 |
| sum_i128 (exact) | 9 | ≈1.6 (2×LD4 + 8×U/SADALP per 8 rows) |
| minmax_i128 | 12 | ≈6.9 |

## Design decisions (algorithms)

### One predicate form for every op
`PRED_SETUP` turns `(op, a, b)` into `pred(x) = ((uint64)(x - lo) <= span) XOR inv`.
For example, LT becomes `[INT64_MIN, a-1]`, and an empty set (LT `INT64_MIN`,
GT `INT64_MAX`, BETWEEN with `a > b`) becomes an inverted always-true range.
The full table is in `pq_a64_common.h`. Because of this, each predicate
kernel has a single branch-free inner loop: `SUB`+`CMP`+`CSET` in scalar
code (`SPRED`), `SUB`+`CMHS` in NEON (`RANGE_LANES`), `SUB`+`CMPHS` in SVE
(`RANGE64`). The inversion costs one `EOR` on a 16-bit mask (NEON) or on a
predicate (SVE). Invalid ops are rejected by checking `op` as an unsigned
32-bit value, before anything is read, so `n == 0` still returns
`(size_t)-1` for a bad op, as in the reference. Only the W view of `int`
arguments is used, because AAPCS64 leaves the upper 32 bits undefined.
compare_i64 uses its own reduction (`CMPOP_CHECK`/`CMPOP_SWAP`): every op
becomes EQ or GT plus an inversion bit, with LT/GE swapping the operands.

### Validity bitmaps
* Scalar: the bit is fetched per row (`VBIT`: byte load + shift). When the
  pointer is NULL, a well-predicted branch skips the fetch (`AND_VBIT`).
* NEON: `LD1R` replicates one validity byte, and `CMTST` against per-lane
  bit constants turns it into 64-bit lane masks for 8 rows (`VMASK2D`,
  `VMASK4S`). Index and bitmap filters build a 16-bit row mask instead and
  `AND` it with an unaligned `LDRH` of the validity. Tails take one byte
  (`TAIL_VBYTE`) and shift it per row.
* SVE: `LD1B` gathers each lane's byte (`row >> 3`) under the loop
  predicate, then shifts and tests it (`SVE_VALID`). The vector length need
  not be a multiple of 8 rows, so a gather is the only general method that
  never reads past `ceil(n/8)` bytes.

### filter_i64 (index output)
NEON uses a 256×8 position table (`.Lneon_selpos`) and a 256-entry popcount
table (`.Lneon_selcnt`). The assembler generates both from their definitions
with `.rept`/`.if`; no external generator is involved. Each 8-row mask byte
loads 8 packed positions, widens them to u32, adds the row base, and stores
32 bytes unconditionally (`EMIT8`). The cursor then advances by the
popcount. The over-store stays inside the documented capacity (`>= n`): in
the main loop the cursor `k <= i` and `i + 8 <= n` for both halves of a
16-row block. The scalar variant uses the same idea one row at a time. SVE
uses `COMPACT` and a predicated truncating `ST1W`, so it never over-stores.

### sum_i64 exact overflow handling
The reference accumulates in 128 bits, and only the final sum must fit in
int64 (`SUM64_RESULT`).
* Scalar: `ADDS`/`ADC` into a 128-bit register pair (`ADD128S`).
* NEON: `LD2 {.4s}` splits every int64 into an unsigned low half and a
  signed high half. `UADALP`/`SADALP` accumulate them pairwise into 64-bit
  lanes, using two independent accumulator pairs. A block is at most 2^24
  iterations, so the lanes stay below 2^58 and 2^57 and cannot wrap. Each
  block is folded into a 128-bit GPR total as `lo + (hi << 32)`
  (`FOLD_SUM64`).
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
  comparisons, starting from ±inf (`F64_MINMAX_STEP`). NEON uses
  `FMINNM`/`FMAXNM`; invalid lanes are forced to all-ones with `ORN`, which
  is a quiet NaN that `FMINNM` ignores. The only lane-order-dependent part is
  the sign of a zero result. The reference returns the *first valid zero* in
  row order in that case, so NEON and SVE re-scan for it when the result is
  ±0 (`F64_FIRST_ZERO`). That makes them bit-identical to the reference, not
  just `==`-equal.

### Kernels where SIMD gives little and why
* `hash_i64` (NEON): Advanced SIMD has no 64×64-bit multiply. Building one
  from `UMULL`/`MUL .2s`/`MLA`/`SHLL` costs about 7 vector ops per multiply
  for 2 lanes, roughly 10 ops per element against 6 GPR ops. The NEON
  variant therefore uses a 4-way interleaved GPR pipeline. SVE does have
  `MUL .d`, so the SVE version is fully vectorized.
* `group_sum_i64`: scatter-adds with possible id conflicts cannot be done in
  NEON or base SVE. Id validation is vectorized (`UMAX` of masked ids, or
  `UMAX`+`INCP` in SVE). The accumulation is scalar in row order, with an
  `ADDS` + `CSINC` overflow flag (`GSUM_ADD`), so the overflow flag matches
  the reference exactly. Pass 1 validates every valid row before any output
  is written, so outputs stay untouched on EINVAL.
* `gather_i64`: NEON has no gather, so it uses unrolled scalar loads. SVE
  uses `LD1W` + `LD1D` gather.

### Bitmap outputs and counts
* NEON writes 16 rows per `STRH`, and a scalar tail writes the last 1–2
  zero-padded bytes (`BITS_TAIL_PUT`/`BITS_TAIL_STORE`). The returned count
  is the popcount of the finished bitmap, via a tail call into the
  `bitmap_popcount` loop (`POPCOUNT_TAILCALL` to the internal entry
  `.Lneon_bitmap_popcount_bytes`). That pass is about 1/64 of the input
  bytes and keeps the main loop short.
* SVE builds 64-row blocks with `ORV` of `1 << (row & 63)` and stores one
  word per block (byte stores for the last partial block): `BITMAP_BLOCKS`.
  This works for any VL.

### Bitmap and/or/andnot aliasing
`out` may equal `a` or `b`. Every chunk is loaded from both inputs before it
is stored, and there is no overlapping "last vector" trick. That trick would
be wrong for `andnot` when `out == b`. The tails step down 64 → 16 → 8 → 1
bytes (`BITOP_STEP8`, `BITOP_BYTES`).

### compare_fixed
* NEON compares 16-byte `CMEQ` chunks. `SHRN #4` packs them into a 64-bit
  nibble mask, `CMN #1` tests for all-equal, and `RBIT`+`CLZ` finds the
  first differing byte. After that come one 8-byte step (`REV` makes the
  words big-endian, so unsigned compare gives lexicographic order) and
  single bytes (`CFX_BYTES`, shared with the scalar variant, as is the
  per-record result `CFX_RESULT`).
* SVE uses `CMPNE` on byte vectors, then `BRKB`+`LASTA` to pick out the
  first differing bytes.

### ABI conformance
* Every function is a leaf. NEON's `filter_i64_bitmap` and `compare_i64`
  tail-call a local label, which is a plain branch. No function uses the
  stack or `sp`.
* Only caller-saved registers are used: x0–x17, v0–v7, v16–v31, and
  z0–z7, z16–z31 plus p0–p15 for SVE. x18 and x19–x29 are never touched,
  and neither are v8–v15/z8–z15, whose low halves d8–d15 are callee-saved.
  This was checked on the disassembly of every function.
* All loads and stores are ordinary (non-exclusive) accesses, so unaligned
  pointers are fine on AArch64 Linux. No load ever spans past a buffer end.
* Constant tables live in `.rodata` and are addressed with `ADRP`/`:lo12:`
  (`LOADADDR`), which is position independent and works both static and in
  a shared library.

### 128-bit kernels (CR-4)

A `pqk_i128` is `{uint64 lo; int64 hi}`, which is the little-endian int128.
Scalar code keeps a value in a GPR pair (one `LDP`). The SIMD variants split
rows into a lo-word vector and a hi-word vector with structure loads (`LD2`
/ `LD2D`: `LD2X4`, `SVE_LD128`). `LD4 {.4s}` splits them into 32-bit limbs.

* **Comparisons.** In scalar code, `CMP lo; SBCS xzr, hi` leaves the flags
  of the full 128-bit subtraction. `hs`/`lo` give unsigned order and
  `lt`/`ge` give signed order. `Z` only reflects the high word, so the code
  never uses eq/gt/le on such a chain. In vector code, each 128-bit compare
  is three 64-bit lane compares plus one select:
  `(hi <  hi') | (hi == hi' & lo <u lo')`, signed or unsigned on the high
  word. That is `CMGT`/`CMHI`, `CMEQ`, `CMHI`/`CMHS` and `BIT`/`BIF` in
  NEON, and three compares plus predicate `SEL` in SVE.
* **One predicate form.** `filter_i128`/`count_i128` reuse the canonical
  range form of the 64-bit kernels, widened to 128 bits:
  `((x - lo) <=u span) ^ inv`. `PRED128_SETUP` builds `lo`/`span`/`inv`
  from `(op, *a, *b)`. Subtracting or adding 2^127 only flips bit 63 of the
  high word, so `span = a - MIN` and `MAX - lo` need no arithmetic. The
  empty-set cases are detected with the `V` flag of the `SBCS`/`ADCS` that
  forms `a ∓ 1`: LT with `a == INT128_MIN`, GT with `a == INT128_MAX`, and
  BETWEEN with `a > b` (signed flags of `b - a`). `op` is validated before
  `*a` is read, and `*b` is read only for BETWEEN, as the ABI requires.
  `*a` is read even when `n == 0`. The NEON cost is 8 lane ops per 2 rows
  (`RNG2`): the borrow is a `CMHI` all-ones mask added to the high word,
  then `CMHS`/`CMHI`/`CMEQ` + `BIF`.
* **NEON filter_i128** handles 8 rows per iteration. It packs an 8-bit row
  mask (`PACK8`: `UZP1`×3, `XTN`, `AND` with bit weights, `ADDV`), ANDs it
  with one validity byte, and reuses the `EMIT8` table compaction of
  `filter_i64`. The 32-byte over-store is again bounded by `k <= i` and
  `i + 8 <= n`. `count_i128` subtracts all-ones lane masks into two
  counters. With validity, it applies the inversion per lane with `EOR`.
  Without validity, it applies the inversion once at the end as
  `rows - count`.
* **Exact sum_i128.** The exact sum of `n < 2^32` int128 values has
  magnitude below 2^159, so a **192-bit** two's-complement accumulator
  never wraps and holds the exact mathematical sum. Intermediate
  excursions outside int128 therefore cancel by construction: for example,
  `INT128_MAX, 1, -1` is OK. The result fits in int128 iff the top word
  equals the sign extension of the middle word (`top == mid ASR 63`), and
  this is the only overflow test (`SUM128_RESULT`). On overflow `*out_sum`
  is not written.
  * Scalar: `ADDS`/`ADCS`/`ADC` with the value sign-extended to 192 bits,
    3 additions per row (`ADD192S`).
  * NEON: `LD4 {.4s}` gives one vector per 32-bit limb (lane j = row j).
    `UADALP` accumulates limbs 0–2 and `SADALP` accumulates the signed top
    limb 3 into 64-bit lanes, with two accumulator sets for 8 rows per
    iteration. Invalid rows are zeroed by `AND` with `CMTST` masks. In
    blocks of at most 2^28 rows, every lane stays below 2^58, so it cannot
    wrap even after both sets and both lanes are added. Each block is
    folded into the 192-bit GPR total as
    `L0 + L1·2^32 + L2·2^64 + L3·2^96`, with L3 sign-extended
    (`FOLD_LIMBS192`).
  * SVE: the same limb decomposition (`AND`/`LSR` of the lo word,
    `AND`/`ASR` of the hi word), merging `ADD`s under the valid-row
    predicate, and blocks of 2^24 rows. The block totals are below 2^56,
    so the modular `UADDV` is exact.
  * Why limbs and not a carry count: NEON has no add-with-carry. Splitting
    into 32-bit limbs lets the widening pairwise accumulate instructions do
    the work exactly at about 1 instruction per limb per 4 rows. The
    alternative, `ADD` + `CMHI` carry detection + carry accumulation,
    costs more and still needs a separate signed top word.
* **minmax_i128.**
  * Scalar: `CMP`/`SBCS` + two `CSEL`s per bound. With validity, `CCMP`
    folds "lt and valid" into one condition, so the loop stays branch-free
    (`MIN128V`/`MAX128V`).
  * NEON: lane-wise signed 128-bit compares (12 ops per 2 rows, `MM2`) with
    two independent accumulator sets. This halves the loop-carried
    `BIT`→compare chain. Validity is ANDed into the update masks. The 8
    lane candidates are folded in GPRs (`REDMM`).
  * SVE: lane-wise compare + `SEL`, then a two-step horizontal reduction:
    `SMINV` of the hi words, then `UMINV` of the lo words over the lanes
    whose hi word equals that minimum. This works because int128 order is
    the lexicographic order of (signed hi, unsigned lo).
  * All variants start from INT128_MAX/INT128_MIN. For integers this is
    indistinguishable from the reference's "first valid value"
    initialisation, and outputs are written only when the count is > 0.
* **Tails and unaligned data.** NEON main loops run only over whole 8-row
  groups, which also makes validity a whole byte per iteration. The 0–7
  remaining rows use the scalar GPR macros. SVE needs no tail: `WHILELO`
  predicates the last vector. `LD2D` is addressed as
  `[x0, 2·row, lsl #3]`, so a block loop can restart at any row. All
  accesses are ordinary loads and stores, so any alignment works.

### SVE specifics
* The file uses `.arch armv8.2-a+sve`, so no Makefile flags are needed. The
  code runs only when the dispatcher sees `HWCAP_SVE`.
* Loops are `WHILELO`/`B.FIRST` with `INCD`/`INCB`, so there are no scalar
  tails. Block loops reset the row counter to the exact block end, because
  with non-power-of-two VLs `INCD` can overshoot a block boundary.
* qemu's default CPU (`max`) reports SVE, so `test-cross` tests all three
  variants, and `a64_sve` becomes the default variant under emulation.

## Decisions taken for CR-5

* **Byte-identical output as the acceptance bar.** CR-5 forbids algorithmic
  changes and asks for no performance regression, which cannot be measured
  here. Keeping the machine code identical makes both properties hold by
  construction and verifiable without hardware. Where a shared macro would
  have needed a different instruction order (e.g. one compare_i64 setup
  macro for all variants), the block was split instead (`CMPOP_CHECK` +
  `CMPOP_SWAP`, with variant code in between), and where a macro would have
  added an instruction (`SVE_LD64` inside `BITMAP_BLOCKS`, whose loop
  already computes the row numbers) it is not used.
* **Three headers instead of one.** Variant-specific blocks (NEON tables,
  SVE predicates) are only meaningful to one variant; keeping them out of
  `pq_a64_common.h` keeps that file about the parts every variant shares.
* **Headers end in `.h`**, are pulled in with `#include` (the files were
  already preprocessed `.S`), and have include guards.
* **The old `pq_a64_macros.h` was removed**; its content is in
  `pq_a64_common.h` (except `MIN128V`/`MAX128V`, which only scalar
  `minmax_i128` uses and which now sit next to it).

## Limitations
* No performance numbers: there is no AArch64 hardware, and emulated timings
  are meaningless. The SIMD design choices are based on instruction counts
  and published pipeline characteristics, not measurements. For CR-5 the
  expected performance effect is nil, because the code is byte-identical.
* NEON `hash_i64`, `gather_i64` and `group_sum_i64` (accumulation pass) are
  scalar by design, for the reasons above.
* `filter_i64` assumes `n < 2^32`, as the header specifies: indices are
  formed in 32-bit lanes. `sum_i128` relies on the same bound: the
  192-bit accumulator is exact for up to 2^64 rows anyway, and the
  per-block lane bounds do not depend on `n`.
* The 128-bit SIMD kernels gain less than the 64-bit ones. A 128-bit
  compare costs 3–4 lane ops plus a select, and a 128-bit register holds
  only two rows. By instruction count, NEON filter/count/minmax are about
  1.7–2.2× fewer instructions per row than scalar; `sum_i128` is about
  5.6× fewer. This has not been measured on hardware.
* SVE has been run only under emulation. `filter_i64_bitmap`/`compare_i64`
  and the validity gather are written for generality across vector lengths,
  not peak speed on a particular core.
* The verification tools used for CR-5 (object comparison, clobber check,
  duplicate scan) are throwaway scripts outside the repository, like the
  earlier test harnesses. To repeat the main check: assemble each variant
  at the baseline commit and at the current commit with
  `aarch64-linux-gnu-gcc -c`, then compare `objcopy -O binary
  --only-section=.text` (and `.rodata`) outputs and `readelf -sW` / `-rW`.
