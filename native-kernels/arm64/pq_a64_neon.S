/*
 * pq_a64_neon.S — PolyQuery native kernels, AArch64 Advanced SIMD variant
 * ("a64_neon"). GNU as syntax, AAPCS64. 20 kernels (ABI revision 1).
 *
 * ABI / register conventions (all kernels):
 *   - Arguments in x0..x6, results in x0/w0/d0; `int` args read as W only.
 *   - Only caller-saved registers are written: x0-x17 and v0-v7, v16-v31,
 *     plus the flags. v8-v15 (whose low halves d8-d15 are callee-saved) and
 *     x19-x29 are never touched; every kernel is a leaf (the only branch to
 *     other code is the tail call of filter_i64_bitmap / compare_i64 into
 *     the local popcount loop), sp is never modified, so no frame, stack
 *     alignment or red zone is involved. x18 is never used.
 *   - Loads/stores are LD1/LD1R/LD2/LD4/LDR/LDP/ST1/STR/STP, which accept any
 *     alignment on AArch64 Linux user space (no exclusive or
 *     alignment-checked forms).
 *   - Vector loops only run while a whole block is in bounds; the remaining
 *     rows (< block size) are processed by scalar tail code. Validity bytes
 *     are read with byte/halfword loads covering exactly the rows processed,
 *     so nothing outside ceil(n/8) validity bytes or the n elements is read,
 *     and nothing outside the documented output size is written.
 *
 * Kernel skeleton (identical in all three variant files, see README.md):
 *   header comment: Args / Result / Clobbers / Registers / Algorithm / Tail
 *   FUNC pqk_a64_neon_<kernel>
 *       // -- 1. arguments / empty input   (constants, n < block -> tail)
 *       // -- 2. main loop                 .Lneon_<kernel>_main[_v|_nv]
 *       //       + horizontal reduction    (where there are accumulators)
 *       // -- 3. tail                      .Lneon_<kernel>_tail
 *       // -- 4. result                    .Lneon_<kernel>_result
 *       error exits                        .Lneon_<kernel>_inval
 *   ENDF pqk_a64_neon_<kernel>
 * `_v` / `_nv` main loops are the with-validity / without-validity copies.
 *
 * Shared building blocks: pq_a64_common.h (operator validation, scalar
 * predicates for the tails, validity bits, exact-sum folds and results,
 * min/max helpers, bitmap byte steps, fmix64, compare_fixed record result,
 * group_sum scatter-add, return helpers) and pq_a64_neon.h (constant
 * tables, CMTST validity masks, 16-row and 128-bit range predicates, table
 * compaction, bitmap-writer tails). Macros used by one kernel only are
 * defined next to that kernel.
 */
#include "pq_a64_common.h"
#include "pq_a64_neon.h"

    NEON_TABLES

/* Block sizes of the bounded accumulation loops (see the kernels). Shrink
 * them to a few iterations to exercise the block-flush paths in testing. */
#define NEON_SUM64_BLOCK     (1<<24)        /* sum_i64: 8-row groups per block */
#define NEON_POPCNT_BLOCK    256            /* bitmap_popcount: 128-byte steps per block */
#define NEON_SUM128_BLOCK    (1<<28)        /* sum_i128: rows per block */

/* ========================================================================
 * filter_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b, x6 out_idx
 * Result:    x0 = number of selected rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x1, x3, x7-x17, v0-v7, v16-v31, flags
 * Registers: x3 original validity, x7 lo, x8 span, w9 inv (0/~0),
 *            x10 row i, x11 output cursor, x12 .Lneon_selpos16,
 *            x13 .Lneon_selcnt, x15 main-loop row limit, w16 row mask,
 *            x17 temp; v16 lo, v17 hi/span (PRED64_FORM), v18 bit weights,
 *            v19 row base (u32 x4), v20 = 8 (u32 x4), v21/v30/v31 EMIT8
 *            temps, v0-v7/v22-v29 rows and lane masks
 * Algorithm: PRED_SETUP range form; PRED64_FORM picks the cheapest lane
 *            test (one CMEQ/CMGE per 2 rows for every op but a genuine
 *            BETWEEN, which keeps SUB + CMHS) and enters the main-loop copy
 *            of that form. 32 rows per iteration: PRED32 -> 32-bit mask
 *            (PACK32), EOR inversion, AND the validity word; each mask byte
 *            is compacted with EMIT8 (u16 positions table, 8 indices stored
 *            branch-free, cursor += count from the popcount table).
 * Tail:      0-31 rows: scalar SPRED + AND_VBIT, unconditional index store,
 *            cursor advanced by the predicate bit.
 * ======================================================================== */
/* FILTER32_LOOP form, loop, tail: main loop (label `loop`) of one predicate
 * form: PRED32, inversion, validity, 4 x EMIT8; then branches to `tail`. */
    .macro  FILTER32_LOOP form, loop, tail
\loop:
    PRED32  \form, x0, w16
    eor     w16, w16, w9
    cbz     x1, .Lfilter32_loop_emit\@
    ldr     w17, [x1], #4                   // validity of rows i..i+31
    and     w16, w16, w17
.Lfilter32_loop_emit\@:
    and     w17, w16, #0xff
    EMIT8   17, 19, 20, 21, 30, 31
    ubfx    w17, w16, #8, #8
    EMIT8   17, 19, 20, 21, 30, 31
    ubfx    w17, w16, #16, #8
    EMIT8   17, 19, 20, 21, 30, 31
    lsr     w17, w16, #24
    EMIT8   17, 19, 20, 21, 30, 31
    add     x10, x10, #32
    cmp     x10, x15
    b.lo    \loop
    b       \tail
    .endm

FUNC pqk_a64_neon_filter_i64
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lneon_filter_i64_inval
    mov     x3, x1
    mov     x10, #0
    mov     x11, x6
    and     x15, x2, #~31
    cbz     x15, .Lneon_filter_i64_tail
    LOADADDR x12, .Lneon_bitsel16
    ld1     {v18.16b}, [x12]
    EMIT8_SETUP 19, 20
    PRED64_FORM .Lneon_filter_i64_main_eq, .Lneon_filter_i64_main_le, \
                .Lneon_filter_i64_main_ge, .Lneon_filter_i64_main_rng, x14, x16
    // -- 2. main loop: 32 rows, one copy per predicate form
    FILTER32_LOOP eq, .Lneon_filter_i64_main_eq, .Lneon_filter_i64_tail
    FILTER32_LOOP le, .Lneon_filter_i64_main_le, .Lneon_filter_i64_tail
    FILTER32_LOOP ge, .Lneon_filter_i64_main_ge, .Lneon_filter_i64_tail
    FILTER32_LOOP rng, .Lneon_filter_i64_main_rng, .Lneon_filter_i64_tail
    // -- 3. tail: 0-31 rows
.Lneon_filter_i64_tail:
    cmp     x10, x2
    b.hs    .Lneon_filter_i64_result
.Lneon_filter_i64_tail_row:
    ldr     x14, [x0], #8
    SPRED   14, 7, 8, 9
    AND_VBIT 14, 3, 10, 15, 16
    and     w14, w14, #1
    str     w10, [x11]
    add     x11, x11, x14, lsl #2
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lneon_filter_i64_tail_row
    // -- 4. result
.Lneon_filter_i64_result:
    sub     x0, x11, x6
    lsr     x0, x0, #2
    ret
.Lneon_filter_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_neon_filter_i64

/* ========================================================================
 * filter_i64_bitmap
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b, x6 out_bits
 * Result:    x0 = number of set bits, (size_t)-1 for an invalid op
 * Clobbers:  x0-x4, x6-x17, v0-v7, v16-v18, v22-v29, flags (includes the
 *            popcount tail call)
 * Registers: as filter_i64; w12 tail bits, x13 tail row, w14 tail bit
 * Algorithm: PRED64_FORM as filter_i64. 32 rows per iteration: PRED32,
 *            EOR inversion, AND validity, one 32-bit STR of the mask. The
 *            count is the popcount of the finished bitmap
 *            (POPCOUNT_TAILCALL into bitmap_popcount: about 1/64 of the
 *            input bytes, keeps the main loop short).
 * Tail:      0-31 rows: scalar SPRED + AND_VBIT into w12 (BITS_TAIL_PUT),
 *            stored as 1-4 zero-padded bytes (BITS_TAIL_STORE).
 * ======================================================================== */
/* BITMAP32_LOOP form, loop, tail: main loop (label `loop`) of one predicate
 * form: PRED32, inversion, validity, STR; then branches to `tail`. */
    .macro  BITMAP32_LOOP form, loop, tail
\loop:
    PRED32  \form, x0, w16
    eor     w16, w16, w9
    cbz     x1, .Lbitmap32_loop_store\@
    ldr     w17, [x1], #4
    and     w16, w16, w17
.Lbitmap32_loop_store\@:
    str     w16, [x11], #4
    add     x10, x10, #32
    cmp     x10, x15
    b.lo    \loop
    b       \tail
    .endm

FUNC pqk_a64_neon_filter_i64_bitmap
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lneon_filter_i64_bitmap_inval
    mov     x3, x1
    mov     x10, #0
    mov     x11, x6
    and     x15, x2, #~31
    cbz     x15, .Lneon_filter_i64_bitmap_tail
    LOADADDR x12, .Lneon_bitsel16
    ld1     {v18.16b}, [x12]
    PRED64_FORM .Lneon_filter_i64_bitmap_main_eq, .Lneon_filter_i64_bitmap_main_le, \
                .Lneon_filter_i64_bitmap_main_ge, .Lneon_filter_i64_bitmap_main_rng, x14, x16
    // -- 2. main loop: 32 rows, one copy per predicate form
    BITMAP32_LOOP eq, .Lneon_filter_i64_bitmap_main_eq, .Lneon_filter_i64_bitmap_tail
    BITMAP32_LOOP le, .Lneon_filter_i64_bitmap_main_le, .Lneon_filter_i64_bitmap_tail
    BITMAP32_LOOP ge, .Lneon_filter_i64_bitmap_main_ge, .Lneon_filter_i64_bitmap_tail
    BITMAP32_LOOP rng, .Lneon_filter_i64_bitmap_main_rng, .Lneon_filter_i64_bitmap_tail
    // -- 3. tail: 0-31 rows -> 1-4 bytes
.Lneon_filter_i64_bitmap_tail:
    cmp     x10, x2
    b.hs    .Lneon_filter_i64_bitmap_result
    mov     w12, #0
    mov     x13, x10
.Lneon_filter_i64_bitmap_tail_row:
    ldr     x14, [x0], #8
    SPRED   14, 7, 8, 9
    and     w14, w14, #1
    AND_VBIT 14, 3, 13, 15, 16
    BITS_TAIL_PUT
    add     x13, x13, #1
    cmp     x13, x2
    b.lo    .Lneon_filter_i64_bitmap_tail_row
    BITS_TAIL_STORE
    // -- 4. result: popcount of the bitmap
.Lneon_filter_i64_bitmap_result:
    POPCOUNT_TAILCALL x6
.Lneon_filter_i64_bitmap_inval:
    RET_INVALID_OP
ENDF pqk_a64_neon_filter_i64_bitmap

/* ========================================================================
 * sum_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_sum
 * Result:    w0 = PQK_OK (*out_sum written) or PQK_OVERFLOW
 * Clobbers:  x0, x1, x4-x11, v0-v3, v16-v22, v26, v27, flags
 * Registers: x5:x4 128-bit total, x6 8-row groups left, x7 groups in the
 *            current block, x8/x9 block sums, x10/x11 temps;
 *            v16/v18 unsigned low-half sums, v17/v19 signed high-half sums,
 *            v20 validity byte, v21/v22 row masks, v26/v27 .Lneon_bits4s
 * Algorithm: exact. LD2 {.4s} splits every int64 into its unsigned low and
 *            signed high 32-bit halves; UADALP / SADALP accumulate them
 *            pairwise into 64-bit lanes (two independent accumulator pairs,
 *            8 rows per iteration; invalid rows zeroed with VMASK4S masks).
 *            A block is at most NEON_SUM64_BLOCK = 2^24 iterations, so the
 *            lanes stay below 2^58 / 2^57 and cannot wrap; each block is
 *            folded into the 128-bit GPR total as lo + (hi << 32)
 *            (FOLD_SUM64). Overflow iff the final 128-bit value is outside
 *            int64 (SUM64_RESULT).
 * Tail:      0-7 rows: scalar ADD128S, validity from TAIL_VBYTE.
 * ======================================================================== */
/* SUM64_ACC: v16-v19 += pairwise halves of v0-v3 (rows 0-3 / 4-7). */
    .macro  SUM64_ACC
    uadalp  v16.2d, v0.4s
    sadalp  v17.2d, v1.4s
    uadalp  v18.2d, v2.4s
    sadalp  v19.2d, v3.4s
    .endm

FUNC pqk_a64_neon_sum_i64
    // -- 1. arguments / empty input
    mov     x4, #0
    mov     x5, #0
    lsr     x6, x2, #3
    cbz     x6, .Lneon_sum_i64_tail
    cbz     x1, .Lneon_sum_i64_block
    LOADADDR x7, .Lneon_bits4s
    ld1     {v26.4s, v27.4s}, [x7]
    // -- 2. main loop: blocks of up to NEON_SUM64_BLOCK x 8 rows
.Lneon_sum_i64_block:
    mov     x7, #NEON_SUM64_BLOCK
    cmp     x6, x7
    csel    x7, x6, x7, lo
    sub     x6, x6, x7
    movi    v16.2d, #0
    movi    v17.2d, #0
    movi    v18.2d, #0
    movi    v19.2d, #0
    cbz     x1, .Lneon_sum_i64_main_nv
.Lneon_sum_i64_main_v:
    ld1r    {v20.16b}, [x1], #1
    ld2     {v0.4s, v1.4s}, [x0], #32       // v0 = low words, v1 = high words
    ld2     {v2.4s, v3.4s}, [x0], #32
    VMASK4S 20, 21, 22, 26, 27
    and     v0.16b, v0.16b, v21.16b
    and     v1.16b, v1.16b, v21.16b
    and     v2.16b, v2.16b, v22.16b
    and     v3.16b, v3.16b, v22.16b
    SUM64_ACC
    subs    x7, x7, #1
    b.ne    .Lneon_sum_i64_main_v
    b       .Lneon_sum_i64_fold
.Lneon_sum_i64_main_nv:
    ld2     {v0.4s, v1.4s}, [x0], #32
    ld2     {v2.4s, v3.4s}, [x0], #32
    SUM64_ACC
    subs    x7, x7, #1
    b.ne    .Lneon_sum_i64_main_nv
.Lneon_sum_i64_fold:                        // lanes: |lo| < 2^58, |hi| < 2^57
    add     v16.2d, v16.2d, v18.2d
    add     v17.2d, v17.2d, v19.2d
    addp    d16, v16.2d
    addp    d17, v17.2d
    fmov    x8, d16                         // unsigned sum of low halves
    fmov    x9, d17                         // signed sum of high halves
    FOLD_SUM64 x4, x5, x8, x9, x10, x11
    cbnz    x6, .Lneon_sum_i64_block
    // -- 3. tail: 0-7 rows
.Lneon_sum_i64_tail:
    ands    x6, x2, #7
    b.eq    .Lneon_sum_i64_result
    TAIL_VBYTE w8, x1, x1
.Lneon_sum_i64_tail_row:
    ldr     x9, [x0], #8
    sbfx    x10, x8, #0, #1
    and     x9, x9, x10
    ADD128S 4, 5, 9, 10
    lsr     w8, w8, #1
    subs    x6, x6, #1
    b.ne    .Lneon_sum_i64_tail_row
    // -- 4. result
.Lneon_sum_i64_result:
    SUM64_RESULT x4, x5, x3
ENDF pqk_a64_neon_sum_i64

/* ========================================================================
 * sum_f64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n
 * Result:    d0 = sum of the valid values
 * Clobbers:  x0, x1, x6-x8, v0-v3, v16-v24, v26-v29, flags
 * Registers: x6 8-row groups / tail rows, w8 tail validity; v16-v19 lane
 *            accumulators, v20 validity byte, v21-v24 row masks, v26-v29
 *            .Lneon_bits2d, d1 = +0.0 and d2 value in the tail
 * Algorithm: 4 x 2-lane FADD accumulators (8 partial sums, a reassociation
 *            allowed by the header's tolerance); invalid lanes zeroed with
 *            AND of the VMASK2D masks. Reduction: FADD tree + FADDP.
 * Tail:      0-7 rows: sequential FADD into d0, invalid rows add +0.0.
 * ======================================================================== */
/* F64_ACC8: v16-v19 += v0-v3. */
    .macro  F64_ACC8
    fadd    v16.2d, v16.2d, v0.2d
    fadd    v17.2d, v17.2d, v1.2d
    fadd    v18.2d, v18.2d, v2.2d
    fadd    v19.2d, v19.2d, v3.2d
    .endm

FUNC pqk_a64_neon_sum_f64
    // -- 1. arguments / empty input
    movi    v16.2d, #0
    movi    v17.2d, #0
    movi    v18.2d, #0
    movi    v19.2d, #0
    lsr     x6, x2, #3
    cbz     x6, .Lneon_sum_f64_reduce
    cbz     x1, .Lneon_sum_f64_main_nv
    LOADADDR x7, .Lneon_bits2d
    ld1     {v26.2d-v29.2d}, [x7]
    // -- 2. main loop: 8 rows
.Lneon_sum_f64_main_v:
    LD8_VMASK2D
    and     v0.16b, v0.16b, v21.16b
    and     v1.16b, v1.16b, v22.16b
    and     v2.16b, v2.16b, v23.16b
    and     v3.16b, v3.16b, v24.16b
    F64_ACC8
    subs    x6, x6, #1
    b.ne    .Lneon_sum_f64_main_v
    b       .Lneon_sum_f64_reduce
.Lneon_sum_f64_main_nv:
    ld1     {v0.2d-v3.2d}, [x0], #64
    F64_ACC8
    subs    x6, x6, #1
    b.ne    .Lneon_sum_f64_main_nv
.Lneon_sum_f64_reduce:
    fadd    v16.2d, v16.2d, v17.2d
    fadd    v18.2d, v18.2d, v19.2d
    fadd    v16.2d, v16.2d, v18.2d
    faddp   d0, v16.2d
    // -- 3. tail: 0-7 rows
    ands    x6, x2, #7
    b.eq    .Lneon_sum_f64_result
    fmov    d1, xzr
    TAIL_VBYTE w8, x1, x1
.Lneon_sum_f64_tail_row:
    ldr     d2, [x0], #8
    tst     w8, #1
    fcsel   d2, d2, d1, ne
    fadd    d0, d0, d2
    lsr     w8, w8, #1
    subs    x6, x6, #1
    b.ne    .Lneon_sum_f64_tail_row
    // -- 4. result
.Lneon_sum_f64_result:
    ret
ENDF pqk_a64_neon_sum_f64

/* ========================================================================
 * minmax_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x1, x5-x14, v0-v7, v16-v31, flags
 * Registers: x5 min, x6 max, x7 groups / tail rows, x8/x9 temps,
 *            x10 original validity, x11 count, w12 tail validity,
 *            x13 INT64_MAX, x14 INT64_MIN; four (min, max) accumulator
 *            pairs v16/v17, v18/v19, v6/v7, v25/v31 (one per input vector
 *            of an iteration), v4/v5 update masks, v20 validity byte,
 *            v21-v24 row masks, v26-v29 .Lneon_bits2d, v30 valid count
 * Algorithm: NEON has no 64-bit SMIN/SMAX: CMGT + BIT (MMSTEP). Each of
 *            the 4 vectors of an 8-row iteration has its own accumulator
 *            pair, so every accumulator is updated once per iteration: the
 *            loop-carried CMGT -> BIT chain (2 dependent ops) no longer
 *            limits the loop, which runs at the throughput of its 16
 *            (unmasked) vector ops. Validity is ANDed into the update masks;
 *            valid rows counted by subtracting the all-ones masks.
 *            Reduction: merge the four pairs, then GPR CMP/CSEL of the two
 *            lanes.
 * Tail:      0-7 rows: scalar CMP/CSEL, invalid rows replaced by the
 *            neutral extremes.
 * ======================================================================== */
/* MMSTEP x, m, lo, hi: masked (m) or unmasked (m = none) min/max update. */
    .macro  MMSTEP x, m, lo, hi
    cmgt    v4.2d, \lo\().2d, \x\().2d
    cmgt    v5.2d, \x\().2d, \hi\().2d
    .ifnc   \m, none
    and     v4.16b, v4.16b, \m\().16b
    and     v5.16b, v5.16b, \m\().16b
    .endif
    bit     \lo\().16b, \x\().16b, v4.16b
    bit     \hi\().16b, \x\().16b, v5.16b
    .endm

FUNC pqk_a64_neon_minmax_i64
    // -- 1. arguments / empty input
    mov     x10, x1
    mov     x13, #PQ_INT64_MAX
    mov     x14, #PQ_INT64_MIN
    dup     v16.2d, x13
    dup     v18.2d, x13
    dup     v6.2d, x13
    dup     v25.2d, x13
    dup     v17.2d, x14
    dup     v19.2d, x14
    dup     v7.2d, x14
    dup     v31.2d, x14
    movi    v30.2d, #0
    lsr     x7, x2, #3
    cbz     x7, .Lneon_minmax_i64_reduce
    cbz     x1, .Lneon_minmax_i64_main_nv
    LOADADDR x8, .Lneon_bits2d
    ld1     {v26.2d-v29.2d}, [x8]
    // -- 2. main loop: 8 rows
.Lneon_minmax_i64_main_v:
    LD8_VMASK2D
    COUNT_VALID8
    MMSTEP  v0, v21, v16, v17
    MMSTEP  v1, v22, v18, v19
    MMSTEP  v2, v23, v6, v7
    MMSTEP  v3, v24, v25, v31
    subs    x7, x7, #1
    b.ne    .Lneon_minmax_i64_main_v
    b       .Lneon_minmax_i64_reduce
.Lneon_minmax_i64_main_nv:
    ld1     {v0.2d-v3.2d}, [x0], #64
    MMSTEP  v0, none, v16, v17
    MMSTEP  v1, none, v18, v19
    MMSTEP  v2, none, v6, v7
    MMSTEP  v3, none, v25, v31
    subs    x7, x7, #1
    b.ne    .Lneon_minmax_i64_main_nv
.Lneon_minmax_i64_reduce:
    cmgt    v4.2d, v16.2d, v18.2d           // merge the four accumulator pairs
    bit     v16.16b, v18.16b, v4.16b
    cmgt    v5.2d, v19.2d, v17.2d
    bit     v17.16b, v19.16b, v5.16b
    cmgt    v4.2d, v6.2d, v25.2d
    bit     v6.16b, v25.16b, v4.16b
    cmgt    v5.2d, v31.2d, v7.2d
    bit     v7.16b, v31.16b, v5.16b
    cmgt    v4.2d, v16.2d, v6.2d
    bit     v16.16b, v6.16b, v4.16b
    cmgt    v5.2d, v7.2d, v17.2d
    bit     v17.16b, v7.16b, v5.16b
    mov     x8, v16.d[0]
    mov     x9, v16.d[1]
    cmp     x9, x8
    csel    x5, x9, x8, lt
    mov     x8, v17.d[0]
    mov     x9, v17.d[1]
    cmp     x9, x8
    csel    x6, x9, x8, gt
    addp    d30, v30.2d
    fmov    x11, d30
    // -- 3. tail: 0-7 rows
    ands    x7, x2, #7
    b.eq    .Lneon_minmax_i64_result
    TAIL_VBYTE w12, x10, x1
.Lneon_minmax_i64_tail_row:
    ldr     x8, [x0], #8
    tst     w12, #1
    csel    x9, x8, x13, ne
    csel    x8, x8, x14, ne
    cinc    x11, x11, ne
    MINMAX64_STEP x5, x6, x9, x8
    lsr     w12, w12, #1
    subs    x7, x7, #1
    b.ne    .Lneon_minmax_i64_tail_row
    // -- 4. result
.Lneon_minmax_i64_result:
    cbnz    x10, .Lneon_minmax_i64_counted
    mov     x11, x2                         // no validity: every row counts
.Lneon_minmax_i64_counted:
    MINMAX_RESULT x11, x5, x6
ENDF pqk_a64_neon_minmax_i64

/* ========================================================================
 * minmax_f64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x1, x7-x13, x15-x17, v0-v5, v16-v24, v26-v30, flags
 * Registers: x7 groups / tail rows, x8/x9 temps, x10 original validity,
 *            x11 count, w12 tail validity, x15 original data, x16/d2 +inf,
 *            x17/d3 -inf; v16/v18 min (+inf), v17/v19 max (-inf),
 *            v20 validity byte, v21-v24 row masks, v26-v29 .Lneon_bits2d,
 *            v30 valid count; d0/d1 results, d4/d5 tail candidates
 * Algorithm: FMINNM/FMAXNM; invalid lanes are forced to all-ones (a quiet
 *            NaN, ignored by FMINNM/FMAXNM) with ORN. The only lane-order
 *            dependent part is the sign of a zero result: F64_FIRST_ZERO
 *            replaces a zero result by the first valid zero of the input,
 *            which is what the sequential reference returns.
 * Tail:      0-7 rows: scalar FCMP/FCSEL with strict comparisons.
 * ======================================================================== */
/* F64_MINMAX8: v16/v18 = min, v17/v19 = max with the 8 rows in v0-v3. */
    .macro  F64_MINMAX8
    fminnm  v16.2d, v16.2d, v0.2d
    fmaxnm  v17.2d, v17.2d, v0.2d
    fminnm  v18.2d, v18.2d, v1.2d
    fmaxnm  v19.2d, v19.2d, v1.2d
    fminnm  v16.2d, v16.2d, v2.2d
    fmaxnm  v17.2d, v17.2d, v2.2d
    fminnm  v18.2d, v18.2d, v3.2d
    fmaxnm  v19.2d, v19.2d, v3.2d
    .endm

FUNC pqk_a64_neon_minmax_f64
    // -- 1. arguments / empty input
    mov     x10, x1
    mov     x15, x0
    mov     x16, #PQ_F64_PINF
    dup     v16.2d, x16
    dup     v18.2d, x16
    mov     x17, #PQ_F64_NINF
    dup     v17.2d, x17
    dup     v19.2d, x17
    movi    v30.2d, #0
    lsr     x7, x2, #3
    cbz     x7, .Lneon_minmax_f64_reduce
    cbz     x1, .Lneon_minmax_f64_main_nv
    LOADADDR x8, .Lneon_bits2d
    ld1     {v26.2d-v29.2d}, [x8]
    // -- 2. main loop: 8 rows
.Lneon_minmax_f64_main_v:
    LD8_VMASK2D
    COUNT_VALID8
    orn     v0.16b, v0.16b, v21.16b         // invalid -> all-ones (qNaN)
    orn     v1.16b, v1.16b, v22.16b
    orn     v2.16b, v2.16b, v23.16b
    orn     v3.16b, v3.16b, v24.16b
    F64_MINMAX8
    subs    x7, x7, #1
    b.ne    .Lneon_minmax_f64_main_v
    b       .Lneon_minmax_f64_reduce
.Lneon_minmax_f64_main_nv:
    ld1     {v0.2d-v3.2d}, [x0], #64
    F64_MINMAX8
    subs    x7, x7, #1
    b.ne    .Lneon_minmax_f64_main_nv
.Lneon_minmax_f64_reduce:
    fminnm  v16.2d, v16.2d, v18.2d
    fmaxnm  v17.2d, v17.2d, v19.2d
    fminnmp d0, v16.2d
    fmaxnmp d1, v17.2d
    addp    d30, v30.2d
    fmov    x11, d30
    fmov    d2, x16
    fmov    d3, x17
    // -- 3. tail: 0-7 rows
    ands    x7, x2, #7
    b.eq    .Lneon_minmax_f64_result
    TAIL_VBYTE w12, x10, x1
.Lneon_minmax_f64_tail_row:
    ldr     d4, [x0], #8
    tst     w12, #1
    fcsel   d5, d4, d3, ne
    fcsel   d4, d4, d2, ne
    cinc    x11, x11, ne
    F64_MINMAX_STEP d0, d1, d4, d5
    lsr     w12, w12, #1
    subs    x7, x7, #1
    b.ne    .Lneon_minmax_f64_tail_row
    // -- 4. result
.Lneon_minmax_f64_result:
    cbnz    x10, .Lneon_minmax_f64_counted
    mov     x11, x2
.Lneon_minmax_f64_counted:
    cbz     x11, .Lneon_minmax_f64_ret
    F64_FIRST_ZERO 15, 10, 9
    str     d0, [x3]
    str     d1, [x4]
.Lneon_minmax_f64_ret:
    RET_X   x11
ENDF pqk_a64_neon_minmax_f64

/* ========================================================================
 * count_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b
 * Result:    x0 = number of selected valid rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x1, x6-x16, v0-v7, v16-v21, v26-v29, flags
 * Registers: x6 groups / tail rows, x7 lo, x8 span, x9 inv (0/-1), x11
 *            original validity, x12 count, x13 temp, w14 tail validity,
 *            x15 tail value, x16 temp; v16 lo, v17 hi/span (PRED64_FORM),
 *            v18 inv, v19 validity byte, v20/v21 lane counters, v4-v7 row
 *            masks, v26-v29 .Lneon_bits2d
 * Algorithm: 8 rows per iteration in the lane form chosen by PRED64_FORM
 *            (one CMEQ/CMGE per 2 rows, SUB + CMHS for a genuine BETWEEN);
 *            the all-ones lane masks are subtracted from two 2x64 counters.
 *            With validity each mask is EORed with the inversion and ANDed
 *            with the VMASK2D mask; without validity the inversion is
 *            applied algebraically at the end (count = rows - count).
 * Tail:      0-7 rows: scalar SPRED, validity from TAIL_VBYTE.
 * ======================================================================== */
/* COUNT8: v20/v21 -= lane masks v0-v3 (all-ones = +1). */
    .macro  COUNT8
    sub     v20.2d, v20.2d, v0.2d
    sub     v21.2d, v21.2d, v1.2d
    sub     v20.2d, v20.2d, v2.2d
    sub     v21.2d, v21.2d, v3.2d
    .endm

/* COUNT_FORM form: entry .Lneon_count_i64_<form> and the with-validity /
 * without-validity main loops of one predicate form. */
    .macro  COUNT_FORM form
.Lneon_count_i64_\form:
    cbz     x1, .Lneon_count_i64_main_nv_\form
.Lneon_count_i64_main_v_\form:
    ld1r    {v19.16b}, [x1], #1
    ld1     {v0.2d-v3.2d}, [x0], #64
    VMASK2D 19, 4, 5, 6, 7, 26, 27, 28, 29
    PRED_LANES \form, 0, 1, 2, 3
    eor     v0.16b, v0.16b, v18.16b
    eor     v1.16b, v1.16b, v18.16b
    eor     v2.16b, v2.16b, v18.16b
    eor     v3.16b, v3.16b, v18.16b
    and     v0.16b, v0.16b, v4.16b
    and     v1.16b, v1.16b, v5.16b
    and     v2.16b, v2.16b, v6.16b
    and     v3.16b, v3.16b, v7.16b
    COUNT8
    subs    x6, x6, #1
    b.ne    .Lneon_count_i64_main_v_\form
    b       .Lneon_count_i64_reduce_v
.Lneon_count_i64_main_nv_\form:
    ld1     {v0.2d-v3.2d}, [x0], #64
    PRED_LANES \form, 0, 1, 2, 3
    COUNT8
    subs    x6, x6, #1
    b.ne    .Lneon_count_i64_main_nv_\form
    b       .Lneon_count_i64_reduce_nv
    .endm

FUNC pqk_a64_neon_count_i64
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lneon_count_i64_inval
    mov     x11, x1
    mov     x12, #0
    lsr     x6, x2, #3
    cbz     x6, .Lneon_count_i64_tail
    dup     v18.2d, x9
    movi    v20.2d, #0
    movi    v21.2d, #0
    LOADADDR x10, .Lneon_bits2d
    ld1     {v26.2d-v29.2d}, [x10]
    PRED64_FORM .Lneon_count_i64_eq, .Lneon_count_i64_le, \
                .Lneon_count_i64_ge, .Lneon_count_i64_rng, x13, x16
    // -- 2. main loop: 8 rows, one copy per predicate form
    COUNT_FORM eq
    COUNT_FORM le
    COUNT_FORM ge
    COUNT_FORM rng
.Lneon_count_i64_reduce_v:
    ADDV2X  x12, 20, 21
    b       .Lneon_count_i64_tail
.Lneon_count_i64_reduce_nv:
    ADDV2X  x12, 20, 21
    cbz     x9, .Lneon_count_i64_tail
    and     x13, x2, #~7                    // inverted: rows - in-range rows
    sub     x12, x13, x12
    // -- 3. tail: 0-7 rows
.Lneon_count_i64_tail:
    ands    x6, x2, #7
    b.eq    .Lneon_count_i64_result
    TAIL_VBYTE w14, x11, x1
.Lneon_count_i64_tail_row:
    ldr     x15, [x0], #8
    SPRED   15, 7, 8, 9
    and     w15, w15, w14
    and     w15, w15, #1
    add     x12, x12, x15
    lsr     w14, w14, #1
    subs    x6, x6, #1
    b.ne    .Lneon_count_i64_tail_row
    // -- 4. result
.Lneon_count_i64_result:
    RET_X   x12
.Lneon_count_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_neon_count_i64

/* ========================================================================
 * bitmap_and / bitmap_or / bitmap_andnot (one template, NEON_BITOP)
 * Args:      x0 a, x1 b, x2 out, x3 nbytes
 * Result:    none
 * Clobbers:  x0-x5, v0-v7, v16-v23, flags
 * Registers: v0-v3/v16-v19 op v4-v7/v20-v23 (128-byte blocks), q0/q4
 *            (16-byte steps), x4/x5 (8-byte step and bytes); x0-x3
 *            advanced in place
 * Algorithm: 128-byte blocks: 4 LD1 x4 + 8 ops + 2 ST1 x4 per iteration
 *            (half the loop overhead of 64-byte blocks). Every chunk is
 *            loaded from both inputs before it is stored, so out == a or
 *            out == b is safe (no overlapping re-processing of already
 *            written bytes, which would be wrong for andnot with out == b).
 * Tail:      16-byte steps, one 8-byte step (BITOP_STEP8), then bytes
 *            (BITOP_BYTES).
 * ======================================================================== */
    .macro  NEON_BITOP name, insn
FUNC pqk_a64_neon_bitmap_\name
    // -- 1. arguments / empty input: fewer than 128 bytes -> tail only
    cmp     x3, #128
    b.lo    .Lneon_bitmap_\name\()_tail
    // -- 2. main loop: 128 bytes
.Lneon_bitmap_\name\()_main:
    ld1     {v0.16b-v3.16b}, [x0], #64
    ld1     {v4.16b-v7.16b}, [x1], #64
    ld1     {v16.16b-v19.16b}, [x0], #64
    ld1     {v20.16b-v23.16b}, [x1], #64
    \insn   v0.16b, v0.16b, v4.16b
    \insn   v1.16b, v1.16b, v5.16b
    \insn   v2.16b, v2.16b, v6.16b
    \insn   v3.16b, v3.16b, v7.16b
    \insn   v16.16b, v16.16b, v20.16b
    \insn   v17.16b, v17.16b, v21.16b
    \insn   v18.16b, v18.16b, v22.16b
    \insn   v19.16b, v19.16b, v23.16b
    st1     {v0.16b-v3.16b}, [x2], #64
    st1     {v16.16b-v19.16b}, [x2], #64
    sub     x3, x3, #128
    cmp     x3, #128
    b.hs    .Lneon_bitmap_\name\()_main
    // -- 3. tail: 16-byte steps, one 8-byte step, bytes; 4. result: ret
.Lneon_bitmap_\name\()_tail:
    cmp     x3, #16
    b.lo    .Lneon_bitmap_\name\()_tail8
    ldr     q0, [x0], #16
    ldr     q4, [x1], #16
    \insn   v0.16b, v0.16b, v4.16b
    str     q0, [x2], #16
    sub     x3, x3, #16
    b       .Lneon_bitmap_\name\()_tail
.Lneon_bitmap_\name\()_tail8:
    cmp     x3, #8
    b.lo    .Lneon_bitmap_\name\()_bytes
    BITOP_STEP8 \insn
.Lneon_bitmap_\name\()_bytes:
    BITOP_BYTES \insn
ENDF pqk_a64_neon_bitmap_\name
    .endm

    NEON_BITOP and, and
    NEON_BITOP or, orr
    NEON_BITOP andnot, bic

/* ========================================================================
 * bitmap_popcount
 * Args:      x0 bits, x1 nbits
 *            internal entry .Lneon_bitmap_popcount_bytes (POPCOUNT_TAILCALL
 *            of filter_i64_bitmap / compare_i64): x0 pointer, x1 whole
 *            bytes, x6 extra bits (0..7) of one more partial byte
 * Result:    x0 = number of set bits
 * Clobbers:  x0-x4, x6, x7, v0-v7, v16, flags
 * Registers: x1 bytes left, x2 iterations in the block, x3/x4 temps,
 *            x6 partial bits, x7 total; v16 8x16-bit accumulator
 * Algorithm: 128 bytes per iteration: CNT per byte (8 ops), ADD tree
 *            (7 ops, <= 64 per byte), one UADALP into 8x16-bit lanes
 *            (<= 128 per halfword per iteration): 2 vector ops per 16
 *            bytes, the minimum for CNT-based counting. Blocks of
 *            NEON_POPCNT_BLOCK = 256 iterations keep the halfwords
 *            <= 32768; each block is reduced with UADDLV into x7.
 * Tail:      16-byte steps (CNT + UADDLV), single bytes (ADD_CNT8), then the
 *            masked partial byte (ADD_POPCNT_LOW).
 * ======================================================================== */
FUNC pqk_a64_neon_bitmap_popcount
    // -- 1. arguments / empty input
    and     x6, x1, #7
    lsr     x1, x1, #3
.Lneon_bitmap_popcount_bytes:
    mov     x7, #0
    cmp     x1, #128
    b.lo    .Lneon_bitmap_popcount_tail
    // -- 2. main loop: blocks of 128-byte iterations
.Lneon_bitmap_popcount_block:
    lsr     x2, x1, #7
    mov     x3, #NEON_POPCNT_BLOCK
    cmp     x2, x3
    csel    x2, x2, x3, lo
    sub     x1, x1, x2, lsl #7
    movi    v16.2d, #0
.Lneon_bitmap_popcount_main:
    ld1     {v0.16b-v3.16b}, [x0], #64
    ld1     {v4.16b-v7.16b}, [x0], #64
    cnt     v0.16b, v0.16b
    cnt     v1.16b, v1.16b
    cnt     v2.16b, v2.16b
    cnt     v3.16b, v3.16b
    cnt     v4.16b, v4.16b
    cnt     v5.16b, v5.16b
    cnt     v6.16b, v6.16b
    cnt     v7.16b, v7.16b
    add     v0.16b, v0.16b, v1.16b
    add     v2.16b, v2.16b, v3.16b
    add     v4.16b, v4.16b, v5.16b
    add     v6.16b, v6.16b, v7.16b
    add     v0.16b, v0.16b, v2.16b
    add     v4.16b, v4.16b, v6.16b
    add     v0.16b, v0.16b, v4.16b          // <= 64 per byte
    uadalp  v16.8h, v0.16b                  // <= 128 per halfword per iteration
    subs    x2, x2, #1
    b.ne    .Lneon_bitmap_popcount_main
    uaddlv  s16, v16.8h                     // <= 8 * 32768
    fmov    w3, s16
    add     x7, x7, x3
    cmp     x1, #128
    b.hs    .Lneon_bitmap_popcount_block
    // -- 3. tail: 16-byte steps, bytes, partial byte
.Lneon_bitmap_popcount_tail:
    cmp     x1, #16
    b.lo    .Lneon_bitmap_popcount_tail_bytes
    ldr     q0, [x0], #16
    cnt     v0.16b, v0.16b
    uaddlv  h0, v0.16b
    umov    w3, v0.h[0]
    add     x7, x7, x3
    sub     x1, x1, #16
    b       .Lneon_bitmap_popcount_tail
.Lneon_bitmap_popcount_tail_bytes:
    cbz     x1, .Lneon_bitmap_popcount_partial
    ldrb    w3, [x0], #1
    ADD_CNT8 3, 7
    sub     x1, x1, #1
    b       .Lneon_bitmap_popcount_tail_bytes
.Lneon_bitmap_popcount_partial:
    cbz     x6, .Lneon_bitmap_popcount_result
    ldrb    w3, [x0]
    ADD_POPCNT_LOW 3, 6, 4, 7
    // -- 4. result
.Lneon_bitmap_popcount_result:
    RET_X   x7
ENDF pqk_a64_neon_bitmap_popcount

/* ========================================================================
 * hash_i64
 * Args:      x0 data, x1 n, x2 seed, x3 out
 * Result:    none
 * Clobbers:  x0, x1, x3-x9, flags
 * Registers: x4/x5 fmix64 multipliers, x6-x9 four rows; x0, x1, x3 advanced
 * Algorithm: Advanced SIMD has no 64x64-bit multiply (emulating it costs
 *            ~7 vector ops per multiply per 2 lanes), so this kernel is a
 *            4-way interleaved GPR fmix64 pipeline (LDP/STP + MUL), the same
 *            arithmetic as FMIX1 with more instruction-level parallelism.
 * Tail:      0-3 rows: FMIX1 one row at a time.
 * ======================================================================== */
FUNC pqk_a64_neon_hash_i64
    // -- 1. arguments / empty input
    LOAD_FMIX 4, 5
    cmp     x1, #4
    b.lo    .Lneon_hash_i64_tail
    // -- 2. main loop: 4 rows
.Lneon_hash_i64_main:
    ldp     x6, x7, [x0], #16
    ldp     x8, x9, [x0], #16
    eor     x6, x6, x2
    eor     x7, x7, x2
    eor     x8, x8, x2
    eor     x9, x9, x2
    eor     x6, x6, x6, lsr #33
    eor     x7, x7, x7, lsr #33
    eor     x8, x8, x8, lsr #33
    eor     x9, x9, x9, lsr #33
    mul     x6, x6, x4
    mul     x7, x7, x4
    mul     x8, x8, x4
    mul     x9, x9, x4
    eor     x6, x6, x6, lsr #33
    eor     x7, x7, x7, lsr #33
    eor     x8, x8, x8, lsr #33
    eor     x9, x9, x9, lsr #33
    mul     x6, x6, x5
    mul     x7, x7, x5
    mul     x8, x8, x5
    mul     x9, x9, x5
    eor     x6, x6, x6, lsr #33
    eor     x7, x7, x7, lsr #33
    eor     x8, x8, x8, lsr #33
    eor     x9, x9, x9, lsr #33
    stp     x6, x7, [x3], #16
    stp     x8, x9, [x3], #16
    sub     x1, x1, #4
    cmp     x1, #4
    b.hs    .Lneon_hash_i64_main
    // -- 3. tail: 0-3 rows
.Lneon_hash_i64_tail:
    cbz     x1, .Lneon_hash_i64_result
    ldr     x6, [x0], #8
    FMIX1   6, 2, 4, 5
    str     x6, [x3], #8
    sub     x1, x1, #1
    b       .Lneon_hash_i64_tail
    // -- 4. result
.Lneon_hash_i64_result:
    ret
ENDF pqk_a64_neon_hash_i64

/* ========================================================================
 * compare_i64
 * Args:      x0 a, x1 b, x2 n, w3 op, x4 out_bits
 * Result:    x0 = number of set bits, (size_t)-1 for an invalid op
 * Clobbers:  x0-x7, x9-x16, v0-v7, v16, v18, v20-v31, flags (includes the
 *            popcount tail call)
 * Registers: w5 type (0 = EQ-based, 1 = GT-based; also the swap temp),
 *            w9 inversion mask (0/~0), x10 row, x11 output cursor,
 *            x15 main-loop row limit, w16 mask, v18 bit weights;
 *            rows 0-15: v0-v7 (a), v20-v27 (b); rows 16-31: v1-v4/v28-v31
 *            (a), v20-v27 (b); tail: w12 bits, x13 row, x14/x15 operands,
 *            w14/w16 predicate bits
 * Algorithm: CMPOP_CHECK / CMPOP_SWAP reduce every op to EQ or GT plus an
 *            inversion (LT/GE swap the operands, NE/LE/GE invert the mask).
 *            32 rows per iteration: CMEQ or CMGT (one loop copy each,
 *            CMP32), PACK16B twice + PACK32, EOR, one 32-bit STR. The count
 *            is the popcount of the finished bitmap (POPCOUNT_TAILCALL).
 * Tail:      0-31 rows: scalar CMP + CSET eq/gt selected by w5, collected
 *            by BITS_TAIL_PUT and stored by BITS_TAIL_STORE.
 * ======================================================================== */
/* CMP32 insn, wout: 32 rows of a and b -> 32-bit mask of `insn`. */
    .macro  CMP32 insn, wout
    ld1     {v0.2d-v3.2d}, [x0], #64
    ld1     {v4.2d-v7.2d}, [x0], #64
    ld1     {v20.2d-v23.2d}, [x1], #64
    ld1     {v24.2d-v27.2d}, [x1], #64
    \insn   v0.2d, v0.2d, v20.2d
    \insn   v1.2d, v1.2d, v21.2d
    \insn   v2.2d, v2.2d, v22.2d
    \insn   v3.2d, v3.2d, v23.2d
    \insn   v4.2d, v4.2d, v24.2d
    \insn   v5.2d, v5.2d, v25.2d
    \insn   v6.2d, v6.2d, v26.2d
    \insn   v7.2d, v7.2d, v27.2d
    PACK16B 0, 1, 2, 3, 4, 5, 6, 7
    ld1     {v1.2d-v4.2d}, [x0], #64
    ld1     {v28.2d-v31.2d}, [x0], #64
    ld1     {v20.2d-v23.2d}, [x1], #64
    ld1     {v24.2d-v27.2d}, [x1], #64
    \insn   v1.2d, v1.2d, v20.2d
    \insn   v2.2d, v2.2d, v21.2d
    \insn   v3.2d, v3.2d, v22.2d
    \insn   v4.2d, v4.2d, v23.2d
    \insn   v28.2d, v28.2d, v24.2d
    \insn   v29.2d, v29.2d, v25.2d
    \insn   v30.2d, v30.2d, v26.2d
    \insn   v31.2d, v31.2d, v27.2d
    PACK16B 1, 2, 3, 4, 28, 29, 30, 31
    PACK32  \wout, 0, 1
    .endm

/* CMP32_LOOP insn, loop: main loop (label `loop`) of one compare type:
 * CMP32, EOR inversion, STR, while x10 < x15. */
    .macro  CMP32_LOOP insn, loop
\loop:
    CMP32   \insn, w16
    eor     w16, w16, w9
    str     w16, [x11], #4
    add     x10, x10, #32
    cmp     x10, x15
    b.lo    \loop
    .endm

FUNC pqk_a64_neon_compare_i64
    // -- 1. arguments / empty input
    CMPOP_CHECK w3, w9, .Lneon_compare_i64_inval
    neg     w9, w9
    CMPOP_SWAP w3, x0, x1, x5
    cmp     w3, #PQK_LT
    cset    w5, hs
    mov     x10, #0
    mov     x11, x4
    and     x15, x2, #~31
    cbz     x15, .Lneon_compare_i64_tail
    LOADADDR x12, .Lneon_bitsel16
    ld1     {v18.16b}, [x12]
    cbnz    w5, .Lneon_compare_i64_main_gt
    // -- 2. main loop: 32 rows, EQ-based ops
    CMP32_LOOP cmeq, .Lneon_compare_i64_main_eq
    b       .Lneon_compare_i64_tail
    // -- 2. main loop: 32 rows, GT-based ops
    CMP32_LOOP cmgt, .Lneon_compare_i64_main_gt
    // -- 3. tail: 0-31 rows -> 1-4 bytes
.Lneon_compare_i64_tail:
    cmp     x10, x2
    b.hs    .Lneon_compare_i64_result
    mov     w12, #0
    mov     x13, x10
.Lneon_compare_i64_tail_row:
    ldr     x14, [x0], #8
    ldr     x15, [x1], #8
    cmp     x14, x15
    cset    w14, eq
    cset    w16, gt
    cmp     w5, #0
    csel    w14, w14, w16, eq
    eor     w14, w14, w9
    and     w14, w14, #1
    BITS_TAIL_PUT
    add     x13, x13, #1
    cmp     x13, x2
    b.lo    .Lneon_compare_i64_tail_row
    BITS_TAIL_STORE
    // -- 4. result: popcount of the bitmap
.Lneon_compare_i64_result:
    POPCOUNT_TAILCALL x4
.Lneon_compare_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_neon_compare_i64

/* ========================================================================
 * compare_fixed
 * Args:      x0 a, x1 b, x2 width, x3 n, x4 out
 * Result:    none (out[i] = -1 / 0 / 1)
 * Clobbers:  x0, x1, x3-x10, v0, v1, flags
 * Registers: x5 bytes left in the record, x6 nibble mask / byte index,
 *            x7 temp, w8/w9 (or x8/x9) differing operands, w10 result;
 *            x0, x1, x3, x4 advanced
 * Algorithm: per record, 16-byte CMEQ chunks; SHRN #4 packs the byte mask
 *            into a 64-bit nibble mask, CMN #1 tests for all-equal, and
 *            RBIT + CLZ locate the first differing byte, compared unsigned.
 * Tail:      per record, one 8-byte step (REV makes the words big-endian so
 *            the unsigned compare is lexicographic), then single bytes
 *            (CFX_BYTES); CFX_RESULT stores the result and skips the unread
 *            bytes.
 * ======================================================================== */
FUNC pqk_a64_neon_compare_fixed
    // -- 1. arguments / empty input
    cbz     x3, .Lneon_compare_fixed_result
.Lneon_compare_fixed_rec:
    mov     x5, x2
    // -- 2. main loop: 16-byte chunks of one record
.Lneon_compare_fixed_main:
    cmp     x5, #16
    b.lo    .Lneon_compare_fixed_tail
    ldr     q0, [x0], #16
    ldr     q1, [x1], #16
    sub     x5, x5, #16
    cmeq    v0.16b, v0.16b, v1.16b
    shrn    v0.8b, v0.8h, #4                // 4 bits per byte: 1111 = equal
    fmov    x6, d0
    cmn     x6, #1
    b.eq    .Lneon_compare_fixed_main
    mvn     x6, x6
    rbit    x6, x6
    clz     x6, x6
    lsr     x6, x6, #2                      // index of first differing byte
    sub     x7, x0, #16
    ldrb    w8, [x7, x6]
    sub     x7, x1, #16
    ldrb    w9, [x7, x6]
    cmp     w8, w9
    b       .Lneon_compare_fixed_diff
    // -- 3. tail: one 8-byte word, then bytes of the record
.Lneon_compare_fixed_tail:
    cmp     x5, #8
    b.lo    .Lneon_compare_fixed_tail_bytes
    ldr     x8, [x0], #8
    ldr     x9, [x1], #8
    sub     x5, x5, #8
    cmp     x8, x9
    b.eq    .Lneon_compare_fixed_tail_bytes
    rev     x8, x8
    rev     x9, x9
    cmp     x8, x9
    b       .Lneon_compare_fixed_diff
    CFX_BYTES w8, w9, .Lneon_compare_fixed_tail_bytes, .Lneon_compare_fixed_eq
    // -- 4. result: per record, then next record
    CFX_RESULT w10, .Lneon_compare_fixed_diff, .Lneon_compare_fixed_eq, \
               .Lneon_compare_fixed_next, .Lneon_compare_fixed_rec
.Lneon_compare_fixed_result:
    ret
ENDF pqk_a64_neon_compare_fixed

/* ========================================================================
 * group_sum_i64
 * Args:      x0 group_ids, x1 values, x2 validity (NULL = all valid), x3 n,
 *            x4 sums, x5 counts (may be NULL), x6 ngroups
 * Result:    w0 = PQK_OK, PQK_OVERFLOW or PQK_EINVAL (outputs untouched)
 * Clobbers:  x0, x1, x3, x7-x13, v0, v1, v16, v17, v20-v22, v26, v27, flags
 * Registers: pass 1: x8 id cursor, x9 validity cursor, x10 groups / rows,
 *            w11 max id, w12 tail validity, w13 tail id; v16/v17 UMAX
 *            accumulators, v20 validity byte, v21/v22 masks, v26/v27
 *            .Lneon_bits4s. pass 2: w9 overflow flag, x10 row, x11 id,
 *            x12/x13 temps.
 * Algorithm: pass 1 (vector) computes the max id over valid rows (invalid
 *            ids masked to 0 with VMASK4S) and compares it with ngroups
 *            before any output is written; ngroups == 0 (EINVAL iff a valid
 *            row exists) and ngroups >= 2^32 (every id is in range) are
 *            handled separately. Pass 2 is the scalar scatter-add in row
 *            order (GSUM_ADD: ADDS + CSINC overflow flag), as NEON has no
 *            conflict-free scatter.
 * Tail:      pass 1: 0-7 rows scalar (TAIL_VBYTE); pass 2: none (rows).
 * ======================================================================== */
FUNC pqk_a64_neon_group_sum_i64
    // -- 1. arguments / empty input
    cbz     x3, .Lneon_group_sum_i64_ok
    lsr     x7, x6, #32
    cbnz    x7, .Lneon_group_sum_i64_acc    // every uint32 id is in range
    cbz     x6, .Lneon_group_sum_i64_any
    mov     x8, x0
    mov     x9, x2
    movi    v16.4s, #0
    movi    v17.4s, #0
    lsr     x10, x3, #3
    cbz     x10, .Lneon_group_sum_i64_check_tail
    cbz     x2, .Lneon_group_sum_i64_check_nv
    LOADADDR x7, .Lneon_bits4s
    ld1     {v26.4s, v27.4s}, [x7]
    // -- 2. main loop, pass 1: max id of valid rows, 8 rows
.Lneon_group_sum_i64_check_v:
    ld1r    {v20.16b}, [x9], #1
    ld1     {v0.4s, v1.4s}, [x8], #32
    VMASK4S 20, 21, 22, 26, 27
    and     v0.16b, v0.16b, v21.16b
    and     v1.16b, v1.16b, v22.16b
    umax    v16.4s, v16.4s, v0.4s
    umax    v17.4s, v17.4s, v1.4s
    subs    x10, x10, #1
    b.ne    .Lneon_group_sum_i64_check_v
    b       .Lneon_group_sum_i64_check_tail
.Lneon_group_sum_i64_check_nv:
    ld1     {v0.4s, v1.4s}, [x8], #32
    umax    v16.4s, v16.4s, v0.4s
    umax    v17.4s, v17.4s, v1.4s
    subs    x10, x10, #1
    b.ne    .Lneon_group_sum_i64_check_nv
    // -- 3. tail, pass 1: 0-7 rows
.Lneon_group_sum_i64_check_tail:
    umax    v16.4s, v16.4s, v17.4s
    umaxv   s16, v16.4s
    fmov    w11, s16
    ands    x10, x3, #7
    b.eq    .Lneon_group_sum_i64_check
    TAIL_VBYTE w12, x2, x9
.Lneon_group_sum_i64_check_tail_row:
    ldr     w13, [x8], #4
    tst     w12, #1
    csel    w13, w13, wzr, ne
    cmp     w13, w11
    csel    w11, w13, w11, hi
    lsr     w12, w12, #1
    subs    x10, x10, #1
    b.ne    .Lneon_group_sum_i64_check_tail_row
.Lneon_group_sum_i64_check:
    cmp     x11, x6
    b.hs    .Lneon_group_sum_i64_inval
    b       .Lneon_group_sum_i64_acc
    // ngroups == 0: EINVAL iff a valid row exists
.Lneon_group_sum_i64_any:
    cbz     x2, .Lneon_group_sum_i64_inval
    lsr     x10, x3, #3
    mov     x9, x2
.Lneon_group_sum_i64_any_byte:
    cbz     x10, .Lneon_group_sum_i64_any_partial
    ldrb    w12, [x9], #1
    cbnz    w12, .Lneon_group_sum_i64_inval
    sub     x10, x10, #1
    b       .Lneon_group_sum_i64_any_byte
.Lneon_group_sum_i64_any_partial:
    ands    x10, x3, #7
    b.eq    .Lneon_group_sum_i64_ok
    ldrb    w12, [x9]
    LOWBITS w13, w10
    tst     w12, w13
    b.ne    .Lneon_group_sum_i64_inval
    b       .Lneon_group_sum_i64_ok
    // -- 2. main loop, pass 2: row-order accumulation
.Lneon_group_sum_i64_acc:
    mov     w9, #0
    cbnz    x2, .Lneon_group_sum_i64_acc_v
.Lneon_group_sum_i64_acc_nv:
    ldr     w11, [x0], #4                   // no validity
    ldr     x12, [x1], #8
    GSUM_ADD .Lneon_group_sum_i64_acc_nv_next
.Lneon_group_sum_i64_acc_nv_next:
    subs    x3, x3, #1
    b.ne    .Lneon_group_sum_i64_acc_nv
    RET_W   w9
.Lneon_group_sum_i64_acc_v:
    mov     x10, #0
.Lneon_group_sum_i64_acc_v_row:
    VBIT    12, 2, 10, 13
    tbz     w12, #0, .Lneon_group_sum_i64_acc_v_next
    ldr     w11, [x0, x10, lsl #2]
    ldr     x12, [x1, x10, lsl #3]
    GSUM_ADD .Lneon_group_sum_i64_acc_v_next
.Lneon_group_sum_i64_acc_v_next:
    add     x10, x10, #1
    cmp     x10, x3
    b.lo    .Lneon_group_sum_i64_acc_v_row
    // -- 4. result
    RET_W   w9
.Lneon_group_sum_i64_ok:
    RET_STATUS PQK_OK
.Lneon_group_sum_i64_inval:
    RET_STATUS PQK_EINVAL
ENDF pqk_a64_neon_group_sum_i64

/* ========================================================================
 * gather_i64
 * Args:      x0 data, x1 idx, x2 m, x3 out
 * Result:    none
 * Clobbers:  x1-x7, flags
 * Registers: w4-w7 indices (zero-extended), then x4-x7 values; x1-x3
 *            advanced
 * Algorithm: NEON has no gather: 4-way unrolled scalar loads (LDP of the
 *            indices, 4 independent LDR, 2 STP).
 * Tail:      0-3 rows one at a time.
 * ======================================================================== */
FUNC pqk_a64_neon_gather_i64
    // -- 1. arguments / empty input
    cmp     x2, #4
    b.lo    .Lneon_gather_i64_tail
    // -- 2. main loop: 4 rows
.Lneon_gather_i64_main:
    ldp     w4, w5, [x1], #8
    ldp     w6, w7, [x1], #8
    ldr     x4, [x0, x4, lsl #3]
    ldr     x5, [x0, x5, lsl #3]
    ldr     x6, [x0, x6, lsl #3]
    ldr     x7, [x0, x7, lsl #3]
    stp     x4, x5, [x3], #16
    stp     x6, x7, [x3], #16
    sub     x2, x2, #4
    cmp     x2, #4
    b.hs    .Lneon_gather_i64_main
    // -- 3. tail: 0-3 rows
.Lneon_gather_i64_tail:
    cbz     x2, .Lneon_gather_i64_result
    ldr     w4, [x1], #4
    ldr     x4, [x0, x4, lsl #3]
    str     x4, [x3], #8
    sub     x2, x2, #1
    b       .Lneon_gather_i64_tail
    // -- 4. result
.Lneon_gather_i64_result:
    ret
ENDF pqk_a64_neon_gather_i64

/* ========================================================================
 * 128-bit kernels (CR-4, kernels 17-20). Main loops process 8 rows
 * (128 bytes, LD2X4; one validity byte); the remaining 0-7 rows go through
 * the scalar GPR code of pq_a64_common.h (SPRED128, MIN128/MAX128, ADD192S).
 * ======================================================================== */

/* ========================================================================
 * filter_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 &a,
 *            x5 &b (read only for BETWEEN), x6 out_idx
 * Result:    x0 = number of selected rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x1, x3-x5, x7-x17, v0-v7, v16-v26, v28, v30, v31, flags
 * Registers: x8:x7 lo, x10:x9 span (scalar copies for the tail), w5 mask
 *            inversion (0/0xff), w4 row inversion (0/1), x3 validity base,
 *            x14 row i, x11 output cursor, x12 .Lneon_selpos16,
 *            x13 .Lneon_selcnt, x15 main-loop row limit, w16 row mask,
 *            w17 validity byte; v16-v19 predicate constants
 *            (PRED128_FORM), v20 row base (u32 x4), v21 = 8 (u32 x4),
 *            v28 = .Lneon_bits8h, v0-v7 / v22-v25 work, v26/v30/v31 EMIT8
 *            temps
 * Algorithm: PRED128_SETUP (op validated before *a / *b are read);
 *            PRED128_FORM picks the cheapest lane test (3-4 ops per 2 rows
 *            for EQ/NE/LT/LE/GT/GE, RNG2 with 8 ops only for a genuine
 *            BETWEEN) and enters the main-loop copy of that form. 8 rows per
 *            iteration: PRED128_8, PACK8 to an 8-bit mask, EOR inversion,
 *            AND the validity byte, then EMIT8 (cursor k <= i and
 *            i + 8 <= n, so the 32-byte over-store stays inside the
 *            documented capacity >= n).
 * Tail:      0-7 rows: scalar SPRED128 + AND_VBIT, unconditional store.
 * ======================================================================== */
/* PACK8 wout: narrows the lane masks v0,v2,v4,v6 (rows 0..7) to an 8-bit row
 * mask (bit j = row j): UZP1 x3 to 8 halfword masks, AND with the weights
 * v28 = .Lneon_bits8h, ADDV. Clobbers v0, v4. */
    .macro  PACK8 wout
    uzp1    v0.4s, v0.4s, v2.4s
    uzp1    v4.4s, v4.4s, v6.4s
    uzp1    v0.8h, v0.8h, v4.8h
    and     v0.16b, v0.16b, v28.16b
    addv    h0, v0.8h
    umov    \wout, v0.h[0]
    .endm

/* FILTER128_LOOP form, loop, tail: main loop (label `loop`) of one
 * predicate form; then branches to `tail`. */
    .macro  FILTER128_LOOP form, loop, tail
\loop:
    PRED128_8 \form, x0
    PACK8   w16
    eor     w16, w16, w5
    cbz     x1, .Lfilter128_loop_emit\@
    ldrb    w17, [x1], #1                   // validity of rows i..i+7
    and     w16, w16, w17
.Lfilter128_loop_emit\@:
    EMIT8   16, 20, 21, 26, 30, 31
    add     x14, x14, #8
    cmp     x14, x15
    b.lo    \loop
    b       \tail
    .endm

FUNC pqk_a64_neon_filter_i128
    // -- 1. arguments / empty input
    PRED128_SETUP w3, x4, x5, x7, x8, x9, x10, x11, x12, x13, .Lneon_filter_i128_inval
    and     w5, w11, #0xff
    and     w4, w11, #1
    mov     x3, x1
    mov     x14, #0
    mov     x11, x6
    and     x15, x2, #~7
    cbz     x15, .Lneon_filter_i128_tail
    PRED128_BCAST
    LOADADDR x12, .Lneon_bits8h
    ldr     q28, [x12]
    EMIT8_SETUP 20, 21
    PRED128_FORM .Lneon_filter_i128_main_eq, .Lneon_filter_i128_main_le, \
                 .Lneon_filter_i128_main_ge, .Lneon_filter_i128_main_rng, x16, x17
    // -- 2. main loop: 8 rows, one copy per predicate form
    FILTER128_LOOP eq, .Lneon_filter_i128_main_eq, .Lneon_filter_i128_tail
    FILTER128_LOOP le, .Lneon_filter_i128_main_le, .Lneon_filter_i128_tail
    FILTER128_LOOP ge, .Lneon_filter_i128_main_ge, .Lneon_filter_i128_tail
    FILTER128_LOOP rng, .Lneon_filter_i128_main_rng, .Lneon_filter_i128_tail
    // -- 3. tail: 0-7 rows
.Lneon_filter_i128_tail:
    cmp     x14, x2
    b.hs    .Lneon_filter_i128_result
.Lneon_filter_i128_tail_row:
    ldp     x16, x17, [x0], #16
    SPRED128 16, 17, 7, 8, 9, 10, 4
    AND_VBIT 16, 3, 14, 12, 13
    str     w14, [x11]
    add     x11, x11, x16, lsl #2
    add     x14, x14, #1
    cmp     x14, x2
    b.lo    .Lneon_filter_i128_tail_row
    // -- 4. result
.Lneon_filter_i128_result:
    sub     x0, x11, x6
    lsr     x0, x0, #2
    ret
.Lneon_filter_i128_inval:
    RET_INVALID_OP
ENDF pqk_a64_neon_filter_i128

/* ========================================================================
 * count_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 &a,
 *            x5 &b (read only for BETWEEN)
 * Result:    x0 = number of selected valid rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x1, x3, x4, x6-x17, v0-v7, v16-v31, flags
 * Registers: x8:x7 lo, x10:x9 span, x11 inv (0/-1), w4 row inversion (0/1),
 *            x3 validity base, x6 count, x14 row i, x15 main-loop row
 *            limit, x16/x17/x12/x13 tail temps; v16-v19 predicate
 *            constants (PRED128_FORM), v26/v27 lane counters, v20 lane
 *            inversion, v21 replicated validity byte, v22-v25 validity lane
 *            masks, v28-v31 .Lneon_bits2d
 * Algorithm: 8 rows per iteration through PRED128_8 in the form chosen by
 *            PRED128_FORM; selected lanes (all-ones) are subtracted from two
 *            2x64 counters. Without validity the inversion is applied
 *            algebraically once (count = rows - count); with validity each
 *            lane mask is EORed with the inversion and ANDed with the
 *            VMASK2D mask.
 * Tail:      0-7 rows: scalar SPRED128 + AND_VBIT.
 * ======================================================================== */
/* COUNT128_8: v26/v27 -= lane masks v0, v2, v4, v6 (all-ones = +1). */
    .macro  COUNT128_8
    sub     v26.2d, v26.2d, v0.2d
    sub     v27.2d, v27.2d, v2.2d
    sub     v26.2d, v26.2d, v4.2d
    sub     v27.2d, v27.2d, v6.2d
    .endm

/* COUNT128_FORM form: entry .Lneon_count_i128_<form> and the with-validity
 * / without-validity main loops of one predicate form. */
    .macro  COUNT128_FORM form
.Lneon_count_i128_\form:
    cbz     x1, .Lneon_count_i128_main_nv_\form
.Lneon_count_i128_main_v_\form:
    PRED128_8 \form, x0
    ld1r    {v21.16b}, [x1], #1
    VMASK2D 21, 22, 23, 24, 25, 28, 29, 30, 31
    eor     v0.16b, v0.16b, v20.16b
    eor     v2.16b, v2.16b, v20.16b
    eor     v4.16b, v4.16b, v20.16b
    eor     v6.16b, v6.16b, v20.16b
    and     v0.16b, v0.16b, v22.16b
    and     v2.16b, v2.16b, v23.16b
    and     v4.16b, v4.16b, v24.16b
    and     v6.16b, v6.16b, v25.16b
    COUNT128_8
    add     x14, x14, #8
    cmp     x14, x15
    b.lo    .Lneon_count_i128_main_v_\form
    b       .Lneon_count_i128_reduce_v
.Lneon_count_i128_main_nv_\form:
    PRED128_8 \form, x0
    COUNT128_8
    add     x14, x14, #8
    cmp     x14, x15
    b.lo    .Lneon_count_i128_main_nv_\form
    b       .Lneon_count_i128_reduce_nv
    .endm

FUNC pqk_a64_neon_count_i128
    // -- 1. arguments / empty input
    PRED128_SETUP w3, x4, x5, x7, x8, x9, x10, x11, x12, x13, .Lneon_count_i128_inval
    and     w4, w11, #1
    mov     x3, x1
    mov     x14, #0
    mov     x6, #0
    and     x15, x2, #~7
    cbz     x15, .Lneon_count_i128_tail
    PRED128_BCAST
    movi    v26.2d, #0
    movi    v27.2d, #0
    dup     v20.2d, x11
    LOADADDR x12, .Lneon_bits2d
    ld1     {v28.2d-v31.2d}, [x12]
    PRED128_FORM .Lneon_count_i128_eq, .Lneon_count_i128_le, \
                 .Lneon_count_i128_ge, .Lneon_count_i128_rng, x16, x17
    // -- 2. main loop: 8 rows, one copy per predicate form
    COUNT128_FORM eq
    COUNT128_FORM le
    COUNT128_FORM ge
    COUNT128_FORM rng
.Lneon_count_i128_reduce_v:
    ADDV2X  x6, 26, 27
    b       .Lneon_count_i128_tail
.Lneon_count_i128_reduce_nv:
    ADDV2X  x6, 26, 27
    cbz     x11, .Lneon_count_i128_tail
    sub     x6, x15, x6                     // inverted op: rows - in-range
    // -- 3. tail: 0-7 rows
.Lneon_count_i128_tail:
    cmp     x14, x2
    b.hs    .Lneon_count_i128_result
.Lneon_count_i128_tail_row:
    ldp     x16, x17, [x0], #16
    SPRED128 16, 17, 7, 8, 9, 10, 4
    AND_VBIT 16, 3, 14, 12, 13
    add     x6, x6, x16
    add     x14, x14, #1
    cmp     x14, x2
    b.lo    .Lneon_count_i128_tail_row
    // -- 4. result
.Lneon_count_i128_result:
    RET_X   x6
.Lneon_count_i128_inval:
    RET_INVALID_OP
ENDF pqk_a64_neon_count_i128

/* ========================================================================
 * sum_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_sum
 * Result:    w0 = PQK_OK (*out_sum written) or PQK_OVERFLOW
 * Clobbers:  x0, x1, x4-x16, v0-v7, v16-v27, flags
 * Registers: x6:x5:x4 exact 192-bit total (top, mid, lo), x7 row i,
 *            x8 block end, x9 validity base, x15 main-loop row limit,
 *            x10-x14/x16 temps; v16-v19 / v20-v23 two sets of limb
 *            accumulators (limb 0..3) for rows 0-3 / 4-7 of each
 *            iteration, v24/v25 validity lane masks, v26/v27 .Lneon_bits4s
 * Algorithm: exact. LD4 {.4s} of 64 bytes splits 4 rows into their four
 *            32-bit limbs, one vector per limb (lane j = row j): limbs 0-2
 *            unsigned, limb 3 signed. UADALP (limbs 0-2) and SADALP (limb 3)
 *            add pairs of limbs into 64-bit lanes, i.e.
 *                sum = L0 + L1 * 2^32 + L2 * 2^64 + L3 * 2^96.
 *            Invalid rows are zeroed beforehand (AND with VMASK4S masks).
 *            Blocks of at most NEON_SUM128_BLOCK = 2^28 rows bound every
 *            lane below 2^58 (|.| < 2^57 for L3), so the lanes cannot wrap
 *            even after adding the two sets and the two lanes (< 2^60). Each
 *            block is folded into the 192-bit GPR total (FOLD_LIMBS192).
 *            Since |sum| < 2^160 the total is the exact mathematical sum, so
 *            cancelling intermediate overflow is OK (SUM128_RESULT).
 * Tail:      0-7 rows: scalar ADD192S with SBFX validity masks.
 * ======================================================================== */
/* SUM128_ACC: limb accumulators v16-v23 += limbs v0-v7 (rows 0-3, 4-7). */
    .macro  SUM128_ACC
    uadalp  v16.2d, v0.4s
    uadalp  v17.2d, v1.4s
    uadalp  v18.2d, v2.4s
    sadalp  v19.2d, v3.4s
    uadalp  v20.2d, v4.4s
    uadalp  v21.2d, v5.4s
    uadalp  v22.2d, v6.4s
    sadalp  v23.2d, v7.4s
    .endm

FUNC pqk_a64_neon_sum_i128
    // -- 1. arguments / empty input
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    mov     x7, #0
    mov     x9, x1
    and     x15, x2, #~7
    cbz     x15, .Lneon_sum_i128_tail
    LOADADDR x10, .Lneon_bits4s
    ld1     {v26.4s, v27.4s}, [x10]
    // -- 2. main loop: blocks of up to NEON_SUM128_BLOCK rows, 8 rows
.Lneon_sum_i128_block:
    BLOCK_END x8, x7, x15, NEON_SUM128_BLOCK // multiple of 8, <= x15
    movi    v16.2d, #0
    movi    v17.2d, #0
    movi    v18.2d, #0
    movi    v19.2d, #0
    movi    v20.2d, #0
    movi    v21.2d, #0
    movi    v22.2d, #0
    movi    v23.2d, #0
    cbz     x1, .Lneon_sum_i128_main_nv
.Lneon_sum_i128_main_v:
    ld4     {v0.4s-v3.4s}, [x0], #64        // rows 0-3: limbs 0..3
    ld4     {v4.4s-v7.4s}, [x0], #64        // rows 4-7
    ld1r    {v24.16b}, [x1], #1
    VMASK4S 24, 25, 24, 26, 27              // v25 rows 0-3, v24 rows 4-7
    and     v0.16b, v0.16b, v25.16b
    and     v1.16b, v1.16b, v25.16b
    and     v2.16b, v2.16b, v25.16b
    and     v3.16b, v3.16b, v25.16b
    and     v4.16b, v4.16b, v24.16b
    and     v5.16b, v5.16b, v24.16b
    and     v6.16b, v6.16b, v24.16b
    and     v7.16b, v7.16b, v24.16b
    SUM128_ACC
    add     x7, x7, #8
    cmp     x7, x8
    b.lo    .Lneon_sum_i128_main_v
    b       .Lneon_sum_i128_fold
.Lneon_sum_i128_main_nv:
    ld4     {v0.4s-v3.4s}, [x0], #64
    ld4     {v4.4s-v7.4s}, [x0], #64
    SUM128_ACC
    add     x7, x7, #8
    cmp     x7, x8
    b.lo    .Lneon_sum_i128_main_nv
.Lneon_sum_i128_fold:
    add     v16.2d, v16.2d, v20.2d
    add     v17.2d, v17.2d, v21.2d
    add     v18.2d, v18.2d, v22.2d
    add     v19.2d, v19.2d, v23.2d
    addp    d16, v16.2d
    addp    d17, v17.2d
    addp    d18, v18.2d
    addp    d19, v19.2d
    FOLD_LIMBS192 x4, x5, x6, x10, x11, x12, x13, x14, x16
    cmp     x7, x15
    b.lo    .Lneon_sum_i128_block
    // -- 3. tail: 0-7 rows
.Lneon_sum_i128_tail:
    cmp     x7, x2
    b.hs    .Lneon_sum_i128_result
.Lneon_sum_i128_tail_row:
    ldp     x10, x11, [x0], #16
    cbz     x9, .Lneon_sum_i128_tail_add
    VBIT    12, 9, 7, 13
    sbfx    x12, x12, #0, #1
    and     x10, x10, x12
    and     x11, x11, x12
.Lneon_sum_i128_tail_add:
    ADD192S 4, 5, 6, 10, 11, 12
    add     x7, x7, #1
    cmp     x7, x2
    b.lo    .Lneon_sum_i128_tail_row
    // -- 4. result
.Lneon_sum_i128_result:
    SUM128_RESULT x4, x5, x6, x3
ENDF pqk_a64_neon_sum_i128

/* ========================================================================
 * minmax_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x1, x5-x7, x9-x17, v0-v7, v16-v30, flags
 * Registers: x5 count, x7:x6 min, x12:x11 max (GPR results), x9 validity
 *            base, x10 row i, x15 main-loop row limit, x13/x14/x16/x17
 *            temps; v16-v19 (rows 0,1 / 4,5) and v20-v23 (rows 2,3 / 6,7)
 *            two independent sets of 2-lane min-lo, min-hi, max-lo, max-hi
 *            accumulators, v24-v26 compare temps, v27 validity byte,
 *            v28 = {1, 2}, v29 lane validity, v30 valid-row lane counter
 * Algorithm: 8 rows per iteration (LD2X4), signed 128-bit compares per lane
 *            (MM2: CMGT hi, CMEQ hi, CMHI lo, BIT; 12 ops per 2 rows), two
 *            accumulator sets to halve the loop-carried dependency chain.
 *            Accumulators start at INT128_MAX / INT128_MIN; invalid lanes
 *            never update (MMV ANDs the lane validity into the update
 *            masks). The 8 lane candidates are folded into GPRs with the
 *            scalar MIN128/MAX128 chain (REDMM).
 * Tail:      0-7 rows: scalar MIN128/MAX128, invalid rows skipped.
 * ======================================================================== */
/* MM2 xl, xh, nl, nh, ml, mh [, vm]: updates the 2-lane min (v<nl>/v<nh>)
 * and max (v<ml>/v<mh>) accumulators with the 2 rows in v<xl>/v<xh> (signed
 * 128-bit: CMGT on the hi words, CMEQ, CMHI on the lo words, BIT select);
 * with vm, only lanes whose mask v<vm> is set. Clobbers v24-v26. */
    .macro  MM2 xl, xh, nl, nh, ml, mh, vm
    cmgt    v24.2d, v\nh\().2d, v\xh\().2d  // x_hi <s min_hi
    cmeq    v25.2d, v\nh\().2d, v\xh\().2d
    cmhi    v26.2d, v\nl\().2d, v\xl\().2d  // x_lo <u min_lo
    bit     v24.16b, v26.16b, v25.16b       // x <s min
    .ifnb   \vm
    and     v24.16b, v24.16b, v\vm\().16b
    .endif
    bit     v\nl\().16b, v\xl\().16b, v24.16b
    bit     v\nh\().16b, v\xh\().16b, v24.16b
    cmgt    v24.2d, v\xh\().2d, v\mh\().2d  // x_hi >s max_hi
    cmeq    v25.2d, v\xh\().2d, v\mh\().2d
    cmhi    v26.2d, v\xl\().2d, v\ml\().2d  // x_lo >u max_lo
    bit     v24.16b, v26.16b, v25.16b       // x >s max
    .ifnb   \vm
    and     v24.16b, v24.16b, v\vm\().16b
    .endif
    bit     v\ml\().16b, v\xl\().16b, v24.16b
    bit     v\mh\().16b, v\xh\().16b, v24.16b
    .endm

/* MMV xl, xh, nl, nh, ml, mh: MM2 for the next 2 rows of the validity byte
 * replicated in v27 (CMTST with v28 = {1, 2}, then shift the byte by 2);
 * the valid-lane mask is also counted into v30. */
    .macro  MMV xl, xh, nl, nh, ml, mh
    cmtst   v29.2d, v27.2d, v28.2d
    ushr    v27.2d, v27.2d, #2
    sub     v30.2d, v30.2d, v29.2d
    MM2     \xl, \xh, \nl, \nh, \ml, \mh, 29
    .endm

/* REDMM nl, nh, ml, mh, lane: folds lane `lane` of a vector min/max set into
 * the GPR min (x7:x6) and max (x12:x11). Clobbers x13, x14. */
    .macro  REDMM nl, nh, ml, mh, lane
    umov    x13, v\nl\().d[\lane]
    umov    x14, v\nh\().d[\lane]
    MIN128  6, 7, 13, 14
    umov    x13, v\ml\().d[\lane]
    umov    x14, v\mh\().d[\lane]
    MAX128  11, 12, 13, 14
    .endm

FUNC pqk_a64_neon_minmax_i128
    // -- 1. arguments / empty input
    mov     x5, #0
    mov     x6, #-1                         // min = INT128_MAX
    mov     x7, #PQ_INT64_MAX
    mov     x11, #0                         // max = INT128_MIN
    mov     x12, #PQ_INT64_MIN
    mov     x9, x1
    mov     x10, #0
    and     x15, x2, #~7
    cbz     x15, .Lneon_minmax_i128_tail
    dup     v16.2d, x6
    dup     v17.2d, x7
    dup     v18.2d, x11
    dup     v19.2d, x12
    mov     v20.16b, v16.16b
    mov     v21.16b, v17.16b
    mov     v22.16b, v18.16b
    mov     v23.16b, v19.16b
    cbz     x1, .Lneon_minmax_i128_main_nv
    LOADADDR x13, .Lneon_bits2d
    ld1     {v28.2d}, [x13]
    movi    v30.2d, #0
    // -- 2. main loop: 8 rows
.Lneon_minmax_i128_main_v:
    LD2X4   x0
    ld1r    {v27.16b}, [x1], #1
    MMV     0, 1, 16, 17, 18, 19
    MMV     2, 3, 20, 21, 22, 23
    MMV     4, 5, 16, 17, 18, 19
    MMV     6, 7, 20, 21, 22, 23
    add     x10, x10, #8
    cmp     x10, x15
    b.lo    .Lneon_minmax_i128_main_v
    addp    d30, v30.2d
    fmov    x5, d30
    b       .Lneon_minmax_i128_reduce
.Lneon_minmax_i128_main_nv:
    LD2X4   x0
    MM2     0, 1, 16, 17, 18, 19
    MM2     2, 3, 20, 21, 22, 23
    MM2     4, 5, 16, 17, 18, 19
    MM2     6, 7, 20, 21, 22, 23
    add     x10, x10, #8
    cmp     x10, x15
    b.lo    .Lneon_minmax_i128_main_nv
    mov     x5, x15
.Lneon_minmax_i128_reduce:
    REDMM   16, 17, 18, 19, 0
    REDMM   16, 17, 18, 19, 1
    REDMM   20, 21, 22, 23, 0
    REDMM   20, 21, 22, 23, 1
    // -- 3. tail: 0-7 rows
.Lneon_minmax_i128_tail:
    cmp     x10, x2
    b.hs    .Lneon_minmax_i128_result
.Lneon_minmax_i128_tail_row:
    ldp     x13, x14, [x0], #16
    cbz     x9, .Lneon_minmax_i128_tail_valid
    VBIT    16, 9, 10, 17
    tbz     w16, #0, .Lneon_minmax_i128_tail_next // invalid row (<= 7 rows)
.Lneon_minmax_i128_tail_valid:
    add     x5, x5, #1
    MIN128  6, 7, 13, 14
    MAX128  11, 12, 13, 14
.Lneon_minmax_i128_tail_next:
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lneon_minmax_i128_tail_row
    // -- 4. result
.Lneon_minmax_i128_result:
    MINMAX128_RESULT x5, x6, x7, x11, x12
ENDF pqk_a64_neon_minmax_i128

    PQ_FILE_END
