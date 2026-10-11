/*
 * pq_a64_sve.S — PolyQuery native kernels, AArch64 SVE variant ("a64_sve").
 * Vector-length agnostic (any VL from 128 to 2048 bits, including
 * non-power-of-two lengths). GNU as syntax, AAPCS64 (base PCS: no SVE
 * arguments or results). 20 kernels (ABI revision 1). Only selected by the
 * dispatcher when HWCAP_SVE is present. Validated under qemu-user emulation
 * only (no SVE hardware).
 *
 * ABI / register conventions (all kernels):
 *   - Arguments in x0..x6, results in x0/w0/d0; `int` args read as W only.
 *   - Only caller-saved state is written: x0-x17, z0-z7, z16-z31, p0-p15
 *     and the flags. z8-z15 (whose low 64 bits d8-d15 are callee-saved) and
 *     x19-x29 are never touched. All kernels are leaves, sp is never
 *     modified, so no frame, stack alignment or red zone is involved. x18
 *     is never used.
 *   - Loops are predicated with WHILELO, so the final partial vector is
 *     handled by the governing predicate: inactive lanes are neither loaded
 *     nor stored (predicated contiguous/gather accesses do not touch inactive
 *     elements), so nothing outside the documented buffers is accessed.
 *     SVE loads/stores accept unaligned addresses on normal memory, so
 *     unaligned pointers are handled natively.
 *
 * Kernel skeleton (identical in all three variant files, see README.md):
 *   header comment: Args / Result / Clobbers / Registers / Algorithm / Tail
 *   FUNC pqk_a64_sve_<kernel>
 *       // -- 1. arguments / empty input   (constants, WHILELO / b.none)
 *       // -- 2. main loop                 .Lsve_<kernel>_main
 *       //       + horizontal reduction    (where there are accumulators)
 *       // -- 3. tail: none (the WHILELO predicate covers the last vector)
 *       // -- 4. result                    .Lsve_<kernel>_result
 *       error exits                        .Lsve_<kernel>_inval
 *   ENDF pqk_a64_sve_<kernel>
 * Block loops (sum_i64, sum_i128, BITMAP_BLOCKS) reset the row counter to
 * the exact block end, because with non-power-of-two VLs INCD can overshoot
 * a block boundary.
 *
 * Shared building blocks: pq_a64_common.h (operator validation, validity
 * bit, exact-sum folds and results, F64_FIRST_ZERO, popcount of a partial
 * byte, fmix64 constants, group_sum row loop, return helpers) and
 * pq_a64_sve.h (validity predicate, row loads, range predicates, block
 * bitmap writer). Macros used by one kernel only are defined next to it.
 */
#include "pq_a64_common.h"
#include "pq_a64_sve.h"

    .arch   armv8.2-a+sve

/* Block size of the bounded accumulation loops (rows per block). Shrink it
 * to a few rows to exercise the block-flush paths in testing. */
#define SVE_SUM_BLOCK        (1 << 24)      /* sum_i64 and sum_i128 */

/* ========================================================================
 * filter_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b, x6 out_idx
 * Result:    x0 = number of selected rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x12, z0-z2, z16, z17, z28, z29, p0-p3, p6, p7, flags
 * Registers: x7 lo, x8 span, x9 inv, x10 row, x11 count, x12 selected in
 *            this vector; z16 lo, z17 span, z0 values, z1 rows, z2
 *            compacted rows; p0 rows, p1 valid rows, p2 selected, p3 store
 *            predicate, p6 inversion, p7 all-true
 * Algorithm: PRED_SETUP range form (RANGE64: SUB + CMPHS + EOR); COMPACT of
 *            the row-number vector under p2, stored with a truncating ST1W
 *            (.d -> 32 bit) under WHILELO(0, count): exactly `count` indices
 *            are written, no over-store.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_filter_i64
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lsve_filter_i64_inval
    mov     x10, #0
    mov     x11, #0
    PRED_BCAST64
    ptrue   p7.d
    whilelo p0.d, x10, x2
    b.none  .Lsve_filter_i64_result
    // -- 2. main loop: one vector of rows
.Lsve_filter_i64_main:
    SVE_LD64 x10
    RANGE64
    compact z2.d, p2, z1.d
    cntp    x12, p7, p2.d
    whilelo p3.d, xzr, x12
    st1w    {z2.d}, p3, [x6, x11, lsl #2]
    add     x11, x11, x12
    incd    x10
    whilelo p0.d, x10, x2
    b.first .Lsve_filter_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_filter_i64_result:
    RET_X   x11
.Lsve_filter_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_sve_filter_i64

/* ========================================================================
 * filter_i64_bitmap
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b, x6 out_bits
 * Result:    x0 = number of set bits, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x15, z0-z3, z16, z17, z28, z29, p0-p2, p6, p7, flags
 * Registers: x7 lo, x8 span, z16 lo, z17 span, p6 inversion; block writer
 *            registers (BITMAP_BLOCKS)
 * Algorithm: BITMAP_BLOCKS with the range predicate (RANGE_PRED: LD1D,
 *            ROWPRED, RANGE64) as the per-vector predicate.
 * Tail:      none (WHILELO-predicated last vector); the final partial block
 *            is stored byte-wise by BITMAP_BLOCKS.
 * ======================================================================== */
/* RANGE_PRED: per-vector predicate for BITMAP_BLOCKS (row x12; z1 already
 * holds the row numbers, so no INDEX here). */
    .macro  RANGE_PRED
    ld1d    {z0.d}, p0/z, [x0, x12, lsl #3]
    ROWPRED
    RANGE64
    .endm

FUNC pqk_a64_sve_filter_i64_bitmap
    // -- 1. arguments / empty input (n == 0 handled by BITMAP_BLOCKS)
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lsve_filter_i64_bitmap_inval
    PRED_BCAST64
    ptrue   p7.d
    // -- 2. main loop: 64-row blocks; 3. tail: none; 4. result: count
    BITMAP_BLOCKS RANGE_PRED
.Lsve_filter_i64_bitmap_inval:
    RET_INVALID_OP
ENDF pqk_a64_sve_filter_i64_bitmap

/* ========================================================================
 * sum_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_sum
 * Result:    w0 = PQK_OK (*out_sum written) or PQK_OVERFLOW
 * Clobbers:  x0, x4-x6, x8-x12, z0-z3, z16, z17, z28, z29, p0, p1, p7, flags
 * Registers: x5:x4 128-bit total, x6 row, x8 block end, x9/x10 block sums,
 *            x11/x12 temps; z16 low-half sums, z17 high-half sums,
 *            z0 values, z2 low halves, z3 high halves
 * Algorithm: exact. Each int64 is split into its unsigned low 32 bits (AND)
 *            and signed high 32 bits (ASR); both are added (merging, under
 *            p1) into 64-bit lanes. Blocks of SVE_SUM_BLOCK = 2^24 rows
 *            bound the lanes (< 2^56), each block is reduced with UADDV
 *            (modular, exact here) and folded into the 128-bit GPR total as
 *            lo + (hi << 32) (FOLD_SUM64). Overflow iff the final 128-bit
 *            value is outside int64 (SUM64_RESULT).
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_sum_i64
    // -- 1. arguments / empty input
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    ptrue   p7.d
    cbz     x2, .Lsve_sum_i64_result
    // -- 2. main loop: blocks of up to SVE_SUM_BLOCK rows, one vector
.Lsve_sum_i64_block:
    mov     x8, #SVE_SUM_BLOCK
    add     x8, x8, x6
    cmp     x8, x2
    csel    x8, x8, x2, lo
    mov     z16.d, #0
    mov     z17.d, #0
    whilelo p0.d, x6, x8
.Lsve_sum_i64_main:
    SVE_LD64 x6
    movprfx z2, z0
    and     z2.d, z2.d, #0xffffffff
    asr     z3.d, z0.d, #32
    add     z16.d, p1/m, z16.d, z2.d
    add     z17.d, p1/m, z17.d, z3.d
    incd    x6
    whilelo p0.d, x6, x8
    b.first .Lsve_sum_i64_main
    mov     x6, x8                          // resume exactly at the block end
    uaddv   d16, p7, z16.d                  // < 32 * 2^56: no wrap
    uaddv   d17, p7, z17.d                  // two's complement sum, |.| < 2^60
    fmov    x9, d16
    fmov    x10, d17
    FOLD_SUM64 x4, x5, x9, x10, x11, x12
    cmp     x6, x2
    b.lo    .Lsve_sum_i64_block
    // -- 3. tail: none
    // -- 4. result
.Lsve_sum_i64_result:
    SUM64_RESULT x4, x5, x3
ENDF pqk_a64_sve_sum_i64

/* ========================================================================
 * sum_f64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n
 * Result:    d0 = sum of the valid values
 * Clobbers:  x6, z0, z1, z16, z28, z29, p0, p1, p7, flags
 * Registers: x6 row, z16 lane sums, z0 values
 * Algorithm: merging FADD (under p1) into one lane-wise accumulator
 *            (VL/64 partial sums, a reassociation allowed by the header's
 *            tolerance), FADDV at the end.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_sum_f64
    // -- 1. arguments / empty input
    mov     x6, #0
    ptrue   p7.d
    mov     z16.d, #0
    whilelo p0.d, x6, x2
    b.none  .Lsve_sum_f64_result
    // -- 2. main loop: one vector
.Lsve_sum_f64_main:
    SVE_LD64 x6
    fadd    z16.d, p1/m, z16.d, z0.d
    incd    x6
    whilelo p0.d, x6, x2
    b.first .Lsve_sum_f64_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_sum_f64_result:
    faddv   d0, p7, z16.d
    ret
ENDF pqk_a64_sve_sum_f64

/* ========================================================================
 * minmax_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x6, x7, x9, z0, z1, z16, z17, z28, z29, p0, p1, p7, flags
 * Registers: x6 row, x7 temp, x9 count; z16 lane minima, z17 lane maxima
 * Algorithm: merging SMIN/SMAX under p1, INCP for the count; SMINV/SMAXV
 *            reduction only when the count is > 0.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_minmax_i64
    // -- 1. arguments / empty input
    mov     x6, #0
    mov     x9, #0
    ptrue   p7.d
    mov     x7, #PQ_INT64_MAX
    dup     z16.d, x7
    mov     x7, #PQ_INT64_MIN
    dup     z17.d, x7
    whilelo p0.d, x6, x2
    b.none  .Lsve_minmax_i64_result
    // -- 2. main loop: one vector
.Lsve_minmax_i64_main:
    SVE_LD64 x6
    smin    z16.d, p1/m, z16.d, z0.d
    smax    z17.d, p1/m, z17.d, z0.d
    incp    x9, p1.d
    incd    x6
    whilelo p0.d, x6, x2
    b.first .Lsve_minmax_i64_main
    // -- 3. tail: none
    // -- 4. result: reduce and store if count > 0
    cbz     x9, .Lsve_minmax_i64_result
    sminv   d0, p7, z16.d
    smaxv   d1, p7, z17.d
    str     d0, [x3]
    str     d1, [x4]
.Lsve_minmax_i64_result:
    RET_X   x9
ENDF pqk_a64_sve_minmax_i64

/* ========================================================================
 * minmax_f64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x6-x10, x12, x13, z0, z1, z4, z16, z17, z28, z29, p0, p1,
 *            p7, flags
 * Registers: x6 row, x7 temp, x9 count, x8/x10/x12/x13 zero scan;
 *            z16 lane minima (+inf), z17 lane maxima (-inf), d0/d1 results
 * Algorithm: merging FMINNM/FMAXNM under p1, INCP for the count,
 *            FMINNMV/FMAXNMV; then F64_FIRST_ZERO replaces a zero result by
 *            the first valid zero (bit-exact signed zero semantics of the
 *            sequential reference).
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_minmax_f64
    // -- 1. arguments / empty input
    mov     x6, #0
    mov     x9, #0
    ptrue   p7.d
    mov     x7, #PQ_F64_PINF
    dup     z16.d, x7
    mov     x7, #PQ_F64_NINF
    dup     z17.d, x7
    whilelo p0.d, x6, x2
    b.none  .Lsve_minmax_f64_result
    // -- 2. main loop: one vector
.Lsve_minmax_f64_main:
    SVE_LD64 x6
    fminnm  z16.d, p1/m, z16.d, z0.d
    fmaxnm  z17.d, p1/m, z17.d, z0.d
    incp    x9, p1.d
    incd    x6
    whilelo p0.d, x6, x2
    b.first .Lsve_minmax_f64_main
    // -- 3. tail: none
    // -- 4. result: reduce, signed-zero fix-up and store if count > 0
    cbz     x9, .Lsve_minmax_f64_result
    fminnmv d0, p7, z16.d
    fmaxnmv d1, p7, z17.d
    F64_FIRST_ZERO 0, 1, 10
    str     d0, [x3]
    str     d1, [x4]
.Lsve_minmax_f64_result:
    RET_X   x9
ENDF pqk_a64_sve_minmax_f64

/* ========================================================================
 * count_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b
 * Result:    x0 = number of selected valid rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x11, z0, z1, z16, z17, z28, z29, p0-p2, p6, flags
 * Registers: x7 lo, x8 span, x9 inv, x10 row, x11 count; z16/z17 lo/span,
 *            p6 inversion
 * Algorithm: RANGE64 per vector, INCP of p2.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_count_i64
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lsve_count_i64_inval
    mov     x10, #0
    mov     x11, #0
    PRED_BCAST64
    whilelo p0.d, x10, x2
    b.none  .Lsve_count_i64_result
    // -- 2. main loop: one vector
.Lsve_count_i64_main:
    SVE_LD64 x10
    RANGE64
    incp    x11, p2.d
    incd    x10
    whilelo p0.d, x10, x2
    b.first .Lsve_count_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_count_i64_result:
    RET_X   x11
.Lsve_count_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_sve_count_i64

/* ========================================================================
 * bitmap_and / bitmap_or / bitmap_andnot (one template, SVE_BITOP)
 * Args:      x0 a, x1 b, x2 out, x3 nbytes
 * Result:    none
 * Clobbers:  x4, z0, z1, p0, flags
 * Registers: x4 byte offset, z0/z1 operands, p0 active bytes
 * Algorithm: byte vectors under WHILELO .b; both inputs are loaded before
 *            the store, so out == a or out == b is safe.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
    .macro  SVE_BITOP name, insn
FUNC pqk_a64_sve_bitmap_\name
    // -- 1. arguments / empty input
    mov     x4, #0
    whilelo p0.b, x4, x3
    b.none  .Lsve_bitmap_\name\()_result
    // -- 2. main loop: one byte vector
.Lsve_bitmap_\name\()_main:
    ld1b    {z0.b}, p0/z, [x0, x4]
    ld1b    {z1.b}, p0/z, [x1, x4]
    \insn   z0.d, z0.d, z1.d
    st1b    {z0.b}, p0, [x2, x4]
    incb    x4
    whilelo p0.b, x4, x3
    b.first .Lsve_bitmap_\name\()_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_bitmap_\name\()_result:
    ret
ENDF pqk_a64_sve_bitmap_\name
    .endm

    SVE_BITOP and, and
    SVE_BITOP or, orr
    SVE_BITOP andnot, bic

/* ========================================================================
 * bitmap_popcount
 * Args:      x0 bits, x1 nbits
 * Result:    x0 = number of set bits among the first nbits bits
 * Clobbers:  x0, x3-x7, z0, z1, p0, flags
 * Registers: x3 full bytes, x4 offset, x5 temp, x6 partial bits,
 *            x7 total; z0 bytes / counts
 * Algorithm: CNT .b + UADDV per byte vector of the ceil-less byte count
 *            nbits >> 3.
 * Tail:      none for the full bytes (WHILELO); the partial last byte is
 *            masked and counted with ADD_POPCNT_LOW.
 * ======================================================================== */
FUNC pqk_a64_sve_bitmap_popcount
    // -- 1. arguments / empty input
    and     x6, x1, #7
    lsr     x3, x1, #3
    mov     x4, #0
    mov     x7, #0
    whilelo p0.b, x4, x3
    b.none  .Lsve_bitmap_popcount_tail
    // -- 2. main loop: one byte vector
.Lsve_bitmap_popcount_main:
    ld1b    {z0.b}, p0/z, [x0, x4]
    cnt     z0.b, p0/m, z0.b
    uaddv   d1, p0, z0.b
    fmov    x5, d1
    add     x7, x7, x5
    incb    x4
    whilelo p0.b, x4, x3
    b.first .Lsve_bitmap_popcount_main
    // -- 3. tail: partial last byte
.Lsve_bitmap_popcount_tail:
    cbz     x6, .Lsve_bitmap_popcount_result
    ldrb    w5, [x0, x3]
    ADD_POPCNT_LOW 5, 6, 4, 7
    // -- 4. result
.Lsve_bitmap_popcount_result:
    RET_X   x7
ENDF pqk_a64_sve_bitmap_popcount

/* ========================================================================
 * hash_i64
 * Args:      x0 data, x1 n, x2 seed, x3 out
 * Result:    none
 * Clobbers:  x4-x6, z0, z1, z16-z18, p0, p7, flags
 * Registers: x4/x5 fmix64 multipliers, x6 row; z16 seed, z17/z18
 *            multipliers, z0 state, z1 temp
 * Algorithm: fully vectorized fmix64 (SVE has a 64-bit MUL): EOR seed, then
 *            3x (LSR #33 + EOR) and 2x MUL per vector.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_hash_i64
    // -- 1. arguments / empty input
    LOAD_FMIX 4, 5
    mov     x6, #0
    ptrue   p7.d
    dup     z16.d, x2
    dup     z17.d, x4
    dup     z18.d, x5
    whilelo p0.d, x6, x1
    b.none  .Lsve_hash_i64_result
    // -- 2. main loop: one vector
.Lsve_hash_i64_main:
    ld1d    {z0.d}, p0/z, [x0, x6, lsl #3]
    eor     z0.d, z0.d, z16.d
    lsr     z1.d, z0.d, #33
    eor     z0.d, z0.d, z1.d
    mul     z0.d, p7/m, z0.d, z17.d
    lsr     z1.d, z0.d, #33
    eor     z0.d, z0.d, z1.d
    mul     z0.d, p7/m, z0.d, z18.d
    lsr     z1.d, z0.d, #33
    eor     z0.d, z0.d, z1.d
    st1d    {z0.d}, p0, [x3, x6, lsl #3]
    incd    x6
    whilelo p0.d, x6, x1
    b.first .Lsve_hash_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_hash_i64_result:
    ret
ENDF pqk_a64_sve_hash_i64

/* ========================================================================
 * compare_i64
 * Args:      x0 a, x1 b, x2 n, w3 op, x4 out_bits
 * Result:    x0 = number of set bits, (size_t)-1 for an invalid op
 * Clobbers:  x0, x1, x5, x6, x9-x15, z0-z3, p0, p2, p6, p7, flags
 * Registers: x5 swap temp, x6 = out_bits for the block writer, w9 inversion
 *            bit; block writer registers (BITMAP_BLOCKS)
 * Algorithm: CMPOP_CHECK / CMPOP_SWAP reduce every op to EQ or GT (LT/GE
 *            swap the operands) plus an inversion (NE/LE/GE, applied with
 *            EOR p6); BITMAP_BLOCKS with CMPEQ or CMPGT as the per-vector
 *            predicate (CMP_PRED, one copy each).
 * Tail:      none (WHILELO-predicated last vector); the final partial block
 *            is stored byte-wise by BITMAP_BLOCKS.
 * ======================================================================== */
/* CMP_PRED insn: per-vector predicate for BITMAP_BLOCKS (row x12):
 * p2 = (a insn b) ^ inversion over the active rows. */
    .macro  CMP_PRED insn
    ld1d    {z0.d}, p0/z, [x0, x12, lsl #3]
    ld1d    {z2.d}, p0/z, [x1, x12, lsl #3]
    \insn   p2.d, p0/z, z0.d, z2.d
    eor     p2.b, p0/z, p2.b, p6.b
    .endm

FUNC pqk_a64_sve_compare_i64
    // -- 1. arguments / empty input (n == 0 handled by BITMAP_BLOCKS)
    CMPOP_CHECK w3, w9, .Lsve_compare_i64_inval
    INVPRED x9
    CMPOP_SWAP w3, x0, x1, x5
    mov     x6, x4
    ptrue   p7.d
    cmp     w3, #PQK_LT
    b.hs    .Lsve_compare_i64_gt
    // -- 2. main loop: 64-row blocks, EQ-based ops; 4. result: count
    BITMAP_BLOCKS "CMP_PRED cmpeq"
.Lsve_compare_i64_gt:
    // -- 2. main loop: 64-row blocks, GT-based ops; 4. result: count
    BITMAP_BLOCKS "CMP_PRED cmpgt"
.Lsve_compare_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_sve_compare_i64

/* ========================================================================
 * compare_fixed
 * Args:      x0 a, x1 b, x2 width, x3 n, x4 out
 * Result:    none (out[i] = -1 / 0 / 1)
 * Clobbers:  x0, x1, x3-x5, x8-x10, z0, z1, p0-p2, flags
 * Registers: x5 offset in the record, w8/w9 first differing bytes,
 *            w10 result; p0 active bytes, p1 differing bytes, p2 bytes
 *            before the first difference; x0, x1, x3, x4 advanced
 * Algorithm: per record, byte vectors under WHILELO .b: CMPNE finds a
 *            difference, BRKB + LASTA extract the first differing bytes,
 *            compared unsigned.
 * Tail:      none (WHILELO-predicated last vector of each record).
 * ======================================================================== */
FUNC pqk_a64_sve_compare_fixed
    // -- 1. arguments / empty input
    cbz     x3, .Lsve_compare_fixed_result
.Lsve_compare_fixed_rec:
    mov     x5, #0
    whilelo p0.b, x5, x2
    b.none  .Lsve_compare_fixed_eq
    // -- 2. main loop: byte vectors of one record
.Lsve_compare_fixed_main:
    ld1b    {z0.b}, p0/z, [x0, x5]
    ld1b    {z1.b}, p0/z, [x1, x5]
    cmpne   p1.b, p0/z, z0.b, z1.b
    b.any   .Lsve_compare_fixed_diff
    incb    x5
    whilelo p0.b, x5, x2
    b.first .Lsve_compare_fixed_main
    // -- 3. tail: none
    // -- 4. result: per record, then next record
.Lsve_compare_fixed_eq:
    strb    wzr, [x4], #1
    b       .Lsve_compare_fixed_next
.Lsve_compare_fixed_diff:
    brkb    p2.b, p0/z, p1.b
    lasta   w8, p2, z0.b                    // element after the last "equal"
    lasta   w9, p2, z1.b
    and     w8, w8, #0xff
    and     w9, w9, #0xff
    cmp     w8, w9
    mov     w10, #1
    cneg    w10, w10, lo                    // a < b -> -1, a > b -> 1
    strb    w10, [x4], #1
.Lsve_compare_fixed_next:
    add     x0, x0, x2
    add     x1, x1, x2
    subs    x3, x3, #1
    b.ne    .Lsve_compare_fixed_rec
.Lsve_compare_fixed_result:
    ret
ENDF pqk_a64_sve_compare_fixed

/* ========================================================================
 * group_sum_i64
 * Args:      x0 group_ids, x1 values, x2 validity (NULL = all valid), x3 n,
 *            x4 sums, x5 counts (may be NULL), x6 ngroups
 * Result:    w0 = PQK_OK, PQK_OVERFLOW or PQK_EINVAL (outputs untouched)
 * Clobbers:  x0-x2, x7, x9-x13, z0, z1, z16, z28, z29, p0, p1, p7, flags
 *            (x1/x2 are swapped during validation and restored)
 * Registers: validation: x10 row, x11 valid count, x12 max id, z16 lane
 *            max id, z0 ids (zero-extended); accumulation: w9 overflow
 *            flag, x10 row, x11 id, x12/x13 temps
 * Algorithm: validation: merging UMAX of the zero-extended ids under p1
 *            plus INCP (EINVAL iff a valid row exists and max id >=
 *            ngroups), before any output is written. ROWPRED reads the
 *            validity pointer from x1, so values/validity are swapped
 *            (x1 <-> x2) meanwhile. Accumulation: scalar row-order
 *            scatter-add (GSUM_ROWS: ADDS + CSINC overflow flag), as SVE has
 *            no conflict-free scatter-add.
 * Tail:      none (WHILELO-predicated last vector; row loop).
 * ======================================================================== */
FUNC pqk_a64_sve_group_sum_i64
    // -- 1. arguments / empty input
    cbz     x3, .Lsve_group_sum_i64_ok
    mov     x7, x1                          // x1 = validity, x2 = values
    mov     x1, x2
    mov     x2, x7
    mov     x10, #0
    mov     x11, #0
    ptrue   p7.d
    mov     z16.d, #0
    whilelo p0.d, x10, x3
    // -- 2. main loop, pass 1: max id of valid rows, one vector
.Lsve_group_sum_i64_main:
    ld1w    {z0.d}, p0/z, [x0, x10, lsl #2]
    index   z1.d, x10, #1
    ROWPRED
    umax    z16.d, p1/m, z16.d, z0.d
    incp    x11, p1.d
    incd    x10
    whilelo p0.d, x10, x3
    b.first .Lsve_group_sum_i64_main
    mov     x7, x1                          // restore x1 = values, x2 = validity
    mov     x1, x2
    mov     x2, x7
    cbz     x11, .Lsve_group_sum_i64_ok     // no valid row: nothing to do
    umaxv   d16, p7, z16.d
    fmov    x12, d16
    cmp     x12, x6
    b.hs    .Lsve_group_sum_i64_inval
    // -- 2. main loop, pass 2: row-order accumulation
    mov     w9, #0
    mov     x10, #0
    GSUM_ROWS
    // -- 3. tail: none
    // -- 4. result
    RET_W   w9
.Lsve_group_sum_i64_ok:
    RET_STATUS PQK_OK
.Lsve_group_sum_i64_inval:
    RET_STATUS PQK_EINVAL
ENDF pqk_a64_sve_group_sum_i64

/* ========================================================================
 * gather_i64
 * Args:      x0 data, x1 idx, x2 m, x3 out
 * Result:    none
 * Clobbers:  x4, z0, z1, p0, flags
 * Registers: x4 position, z0 indices (zero-extended), z1 gathered values
 * Algorithm: LD1W (zero-extending) of the indices, LD1D gather (scaled by
 *            8), ST1D.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_gather_i64
    // -- 1. arguments / empty input
    mov     x4, #0
    whilelo p0.d, x4, x2
    b.none  .Lsve_gather_i64_result
    // -- 2. main loop: one vector
.Lsve_gather_i64_main:
    ld1w    {z0.d}, p0/z, [x1, x4, lsl #2]
    ld1d    {z1.d}, p0/z, [x0, z0.d, lsl #3]
    st1d    {z1.d}, p0, [x3, x4, lsl #3]
    incd    x4
    whilelo p0.d, x4, x2
    b.first .Lsve_gather_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_gather_i64_result:
    ret
ENDF pqk_a64_sve_gather_i64

/* ========================================================================
 * 128-bit kernels (CR-4, kernels 17-20), vector-length agnostic.
 * SVE_LD128 de-interleaves VL/64 pqk_i128 rows into a lo-word and a hi-word
 * vector (lane j = row j). 128-bit comparisons are composed from 64-bit lane
 * compares into predicates:
 *   unsigned d <= s : SEL(d_hi == s_hi, d_lo <=u s_lo, d_hi <u s_hi)
 *   signed   x <  m : SEL(x_hi == m_hi, x_lo <u m_lo,  x_hi <s m_hi)
 * using predicate SEL (Pd = Pg ? Pn : Pm). All compares are zeroing under
 * the valid-row predicate p1, so inactive or invalid lanes never count.
 * ======================================================================== */

/* ========================================================================
 * filter_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 &a,
 *            x5 &b (read only for BETWEEN), x6 out_idx
 * Result:    x0 = number of selected rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x13, z1-z4, z16-z19, z28-z30, p0-p7, flags
 * Registers: x10 row, x11 count, x12 selected in this vector, x13 = 2*row;
 *            z16:z17 lo, z18:z19 span, z30 = 1, z2/z3 lo/hi words, z1 row
 *            numbers, z4 compacted rows; p0 rows, p1 valid rows, p2
 *            selected, p3 store predicate (and RANGE128 temps p3-p5),
 *            p6 inversion, p7 all-true
 * Algorithm: SETUP128 (PRED128_SETUP: op validated before *a / *b are
 *            read), then per vector SVE_LD128 + RANGE128 (4 vector ops,
 *            4 compares, SEL, EOR), COMPACT of the row numbers and a
 *            truncating ST1W under WHILELO(0, count): exactly `count`
 *            indices are written, no over-store.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_filter_i128
    // -- 1. arguments / empty input
    SETUP128 .Lsve_filter_i128_inval
    mov     x10, #0
    mov     x11, #0
    whilelo p0.d, x10, x2
    b.none  .Lsve_filter_i128_result
    // -- 2. main loop: one vector of rows
.Lsve_filter_i128_main:
    SVE_LD128 x10
    RANGE128
    compact z4.d, p2, z1.d
    cntp    x12, p7, p2.d
    whilelo p3.d, xzr, x12
    st1w    {z4.d}, p3, [x6, x11, lsl #2]
    add     x11, x11, x12
    incd    x10
    whilelo p0.d, x10, x2
    b.first .Lsve_filter_i128_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_filter_i128_result:
    RET_X   x11
.Lsve_filter_i128_inval:
    RET_INVALID_OP
ENDF pqk_a64_sve_filter_i128

/* ========================================================================
 * count_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 &a,
 *            x5 &b (read only for BETWEEN)
 * Result:    x0 = number of selected valid rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x13, z1-z3, z16-z19, z28-z30, p0-p7, flags
 * Registers: as filter_i128; x11 count
 * Algorithm: SETUP128, SVE_LD128 + RANGE128 per vector, INCP of p2.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_count_i128
    // -- 1. arguments / empty input
    SETUP128 .Lsve_count_i128_inval
    mov     x10, #0
    mov     x11, #0
    whilelo p0.d, x10, x2
    b.none  .Lsve_count_i128_result
    // -- 2. main loop: one vector of rows
.Lsve_count_i128_main:
    SVE_LD128 x10
    RANGE128
    incp    x11, p2.d
    incd    x10
    whilelo p0.d, x10, x2
    b.first .Lsve_count_i128_main
    // -- 3. tail: none
    // -- 4. result
.Lsve_count_i128_result:
    RET_X   x11
.Lsve_count_i128_inval:
    RET_INVALID_OP
ENDF pqk_a64_sve_count_i128

/* ========================================================================
 * sum_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_sum
 * Result:    w0 = PQK_OK (*out_sum written) or PQK_OVERFLOW
 * Clobbers:  x0, x4-x8, x10-x14, x16, z1-z7, z16-z19, z28, z29, p0, p1, p7,
 *            flags
 * Registers: x6:x5:x4 exact 192-bit total (top, mid, lo), x7 row, x8 block
 *            end, x13 = 2*row, x10-x14/x16 fold temps; z16-z19 lane sums of
 *            limbs 0..3, z2/z3 lo/hi words, z4-z7 limbs; p0 rows, p1 valid
 *            rows, p7 all-true
 * Algorithm: exact. Every value is split into four 32-bit limbs (AND / LSR
 *            of the lo word: unsigned; AND / ASR of the hi word: unsigned
 *            and signed top limb), and each limb is added (merging, under
 *            p1, so invalid and inactive lanes add nothing) into its own
 *            64-bit lane accumulator:
 *                sum = L0 + L1 * 2^32 + L2 * 2^64 + L3 * 2^96.
 *            Blocks of at most SVE_SUM_BLOCK = 2^24 rows keep every lane
 *            and every UADDV total below 2^56 (|.| < 2^55 for L3), so the
 *            modular UADDV is exact. Each block is folded into the 192-bit
 *            GPR total (FOLD_LIMBS192). |sum| < 2^160, so the total is the
 *            exact sum (cancelling intermediate overflow is OK;
 *            SUM128_RESULT).
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_sum_i128
    // -- 1. arguments / empty input
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    mov     x7, #0
    ptrue   p7.d
    cbz     x2, .Lsve_sum_i128_result
    // -- 2. main loop: blocks of up to SVE_SUM_BLOCK rows, one vector
.Lsve_sum_i128_block:
    mov     x8, #SVE_SUM_BLOCK
    add     x8, x8, x7
    cmp     x8, x2
    csel    x8, x8, x2, lo
    mov     z16.d, #0
    mov     z17.d, #0
    mov     z18.d, #0
    mov     z19.d, #0
    whilelo p0.d, x7, x8
.Lsve_sum_i128_main:
    SVE_LD128 x7
    movprfx z4, z2
    and     z4.d, z4.d, #0xffffffff         // limb 0
    lsr     z5.d, z2.d, #32                 // limb 1
    movprfx z6, z3
    and     z6.d, z6.d, #0xffffffff         // limb 2
    asr     z7.d, z3.d, #32                 // limb 3 (signed)
    add     z16.d, p1/m, z16.d, z4.d
    add     z17.d, p1/m, z17.d, z5.d
    add     z18.d, p1/m, z18.d, z6.d
    add     z19.d, p1/m, z19.d, z7.d
    incd    x7
    whilelo p0.d, x7, x8
    b.first .Lsve_sum_i128_main
    mov     x7, x8                          // resume exactly at the block end
    uaddv   d16, p7, z16.d
    uaddv   d17, p7, z17.d
    uaddv   d18, p7, z18.d
    uaddv   d19, p7, z19.d                  // two's complement, |.| < 2^55
    fmov    x10, d16
    fmov    x11, d17
    fmov    x12, d18
    fmov    x13, d19
    FOLD_LIMBS192 x4, x5, x6, x10, x11, x12, x13, x14, x16
    cmp     x7, x2
    b.lo    .Lsve_sum_i128_block
    // -- 3. tail: none
    // -- 4. result
.Lsve_sum_i128_result:
    SUM128_RESULT x4, x5, x6, x3
ENDF pqk_a64_sve_sum_i128

/* ========================================================================
 * minmax_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x6-x9, x13, z0-z4, z16-z19, z28, z29, p0, p1, p3-p5, p7,
 *            flags
 * Registers: x6 row, x9 count, x13 = 2*row, x7/x8 temps; z16/z17 lane
 *            minima (lo/hi words, start INT128_MAX), z18/z19 lane maxima
 *            (start INT128_MIN), z2/z3 values, z4 broadcast; p0 rows, p1
 *            valid rows, p3-p5 compare predicates, p7 all-true
 * Algorithm: per lane signed 128-bit compares (CMPGT hi, CMPEQ hi, CMPHI lo,
 *            predicate SEL) give the update predicates, applied with vector
 *            SEL to both words; INCP counts valid rows. Horizontal reduction
 *            in two steps: SMINV of the hi words, then UMINV of the lo words
 *            over the lanes whose hi word equals that minimum (CMPEQ) --
 *            the lexicographic order of (signed hi, unsigned lo) is the
 *            int128 order. Same with SMAXV/UMAXV.
 * Tail:      none (WHILELO-predicated last vector).
 * ======================================================================== */
FUNC pqk_a64_sve_minmax_i128
    // -- 1. arguments / empty input
    mov     x6, #0
    mov     x9, #0
    ptrue   p7.d
    mov     z16.d, #-1                      // min = INT128_MAX
    mov     x7, #PQ_INT64_MAX
    dup     z17.d, x7
    mov     z18.d, #0                       // max = INT128_MIN
    mov     x7, #PQ_INT64_MIN
    dup     z19.d, x7
    whilelo p0.d, x6, x2
    b.none  .Lsve_minmax_i128_result
    // -- 2. main loop: one vector of rows
.Lsve_minmax_i128_main:
    SVE_LD128 x6
    cmpgt   p3.d, p1/z, z17.d, z3.d         // x_hi <s min_hi
    cmpeq   p4.d, p1/z, z17.d, z3.d
    cmphi   p5.d, p1/z, z16.d, z2.d         // x_lo <u min_lo
    sel     p3.b, p4, p5.b, p3.b            // x <s min
    sel     z16.d, p3, z2.d, z16.d
    sel     z17.d, p3, z3.d, z17.d
    cmpgt   p3.d, p1/z, z3.d, z19.d         // x_hi >s max_hi
    cmpeq   p4.d, p1/z, z3.d, z19.d
    cmphi   p5.d, p1/z, z2.d, z18.d         // x_lo >u max_lo
    sel     p3.b, p4, p5.b, p3.b            // x >s max
    sel     z18.d, p3, z2.d, z18.d
    sel     z19.d, p3, z3.d, z19.d
    incp    x9, p1.d
    incd    x6
    whilelo p0.d, x6, x2
    b.first .Lsve_minmax_i128_main
    // -- 3. tail: none
    // -- 4. result: two-step reduction and store if count > 0
    cbz     x9, .Lsve_minmax_i128_result
    sminv   d0, p7, z17.d                   // min hi word
    fmov    x7, d0
    dup     z4.d, x7
    cmpeq   p3.d, p7/z, z17.d, z4.d
    uminv   d1, p3, z16.d                   // min lo word among those lanes
    fmov    x8, d1
    stp     x8, x7, [x3]
    smaxv   d0, p7, z19.d
    fmov    x7, d0
    dup     z4.d, x7
    cmpeq   p3.d, p7/z, z19.d, z4.d
    umaxv   d1, p3, z18.d
    fmov    x8, d1
    stp     x8, x7, [x4]
.Lsve_minmax_i128_result:
    RET_X   x9
ENDF pqk_a64_sve_minmax_i128

    PQ_FILE_END
