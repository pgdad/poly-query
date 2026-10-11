/*
 * pq_a64_scalar.S — PolyQuery native kernels, AArch64 scalar variant
 * ("a64_scalar"). GNU as syntax, AAPCS64, general-purpose/FP registers only
 * (no Advanced SIMD vector instructions). 20 kernels (ABI revision 1).
 *
 * ABI / register conventions (all kernels):
 *   - Arguments arrive in x0..x6 (no FP arguments), results in x0/w0/d0.
 *   - Only caller-saved registers are written: x0-x17 and v0-v5 (d0-d5),
 *     plus the flags. No callee-saved register (x19-x28, d8-d15) is touched,
 *     no stack frame is needed (every kernel is a leaf), sp is never
 *     modified, so stack alignment and red-zone questions do not arise. x18
 *     (platform register) is never used.
 *   - `int` arguments (op) are read from the W view only.
 *   - All memory accesses are plain LDR/STR/LDP/STP, which are
 *     alignment-agnostic on AArch64 Linux user space, so unaligned pointers
 *     are handled natively.
 *   - Every loop is guarded by an n == 0 check before the first access, so
 *     NULL pointers with n == 0 are never dereferenced.
 *
 * Kernel skeleton (identical in all three variant files, see README.md):
 *   header comment: Args / Result / Clobbers / Registers / Algorithm / Tail
 *   FUNC pqk_a64_scalar_<kernel>
 *       // -- 1. arguments / empty input
 *       // -- 2. main loop          label .Lscalar_<kernel>_main
 *       // -- 3. tail               label .Lscalar_<kernel>_tail
 *       // -- 4. result             label .Lscalar_<kernel>_result
 *       error exits                 labels _inval (and _ovf in macros)
 *   ENDF pqk_a64_scalar_<kernel>
 * In this variant the main loop of most kernels handles one row per
 * iteration, so there is no tail; kernels that work on 8-byte words
 * (bitmap ops, popcount, compare_fixed) have a byte tail.
 *
 * Shared building blocks come from pq_a64_common.h (PRED_SETUP,
 * PRED128_SETUP, CMPOP_CHECK/SWAP, SPRED, SPRED128, VBIT, AND_VBIT, ADD128S,
 * ADD192S, SUM64/128_RESULT, MIN128/MAX128, MINMAX64_STEP, F64_MINMAX_STEP,
 * MINMAX(128)_RESULT, SBITMAP_PUT/FLUSH, BITOP_STEP8/BYTES, LOWBITS,
 * LOAD_FMIX, FMIX1, CFX_BYTES, CFX_RESULT, GSUM_ADD/ROWS, return helpers).
 * Macros used by a single kernel (SCALAR_BITOP, SWARPOP, SCALAR_CMPBITS,
 * MIN128V/MAX128V) are defined next to that kernel.
 */
#include "pq_a64_common.h"

/* ========================================================================
 * filter_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b, x6 out_idx
 * Result:    x0 = number of selected rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x14, flags
 * Registers: x7 lo, x8 span, w9 inv (0/1), x10 row i, x11 output count k,
 *            x12 value / predicate bit, x13/x14 validity temps
 * Algorithm: PRED_SETUP range form; per row SPRED (SUB, CMP, CSET, EOR) AND
 *            the validity bit. The row index is stored unconditionally at
 *            out[k] (k <= i < n: inside the capacity) and k advances by the
 *            predicate bit (branch-free compaction).
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_filter_i64
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lscalar_filter_i64_inval
    and     w9, w9, #1
    mov     x10, #0
    mov     x11, #0
    cbz     x2, .Lscalar_filter_i64_result
    // -- 2. main loop: one row
.Lscalar_filter_i64_main:
    ldr     x12, [x0, x10, lsl #3]
    SPRED   12, 7, 8, 9
    AND_VBIT 12, 1, 10, 13, 14
    str     w10, [x6, x11, lsl #2]          // unconditional store, k <= i < n
    add     x11, x11, x12
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lscalar_filter_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_filter_i64_result:
    RET_X   x11
.Lscalar_filter_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_scalar_filter_i64

/* ========================================================================
 * filter_i64_bitmap
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b, x6 out_bits
 * Result:    x0 = number of set bits, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x15, flags
 * Registers: x7 lo, x8 span, w9 inv (0/1), x10 row i, x11 count,
 *            x12 value / predicate bit, x13/x14 temps, w15 output byte
 * Algorithm: as filter_i64; the predicate bits are collected into w15 by the
 *            scalar bitmap writer (SBITMAP_PUT), one STRB per 8 rows.
 * Tail:      none for the rows; SBITMAP_FLUSH stores the zero-padded partial
 *            last byte.
 * ======================================================================== */
FUNC pqk_a64_scalar_filter_i64_bitmap
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lscalar_filter_i64_bitmap_inval
    and     w9, w9, #1
    mov     x10, #0
    mov     x11, #0
    mov     w15, #0
    cbz     x2, .Lscalar_filter_i64_bitmap_result
    // -- 2. main loop: one row
.Lscalar_filter_i64_bitmap_main:
    ldr     x12, [x0, x10, lsl #3]
    SPRED   12, 7, 8, 9
    AND_VBIT 12, 1, 10, 13, 14
    SBITMAP_PUT x6
    cmp     x10, x2
    b.lo    .Lscalar_filter_i64_bitmap_main
    // -- 3. tail: partial last output byte
    SBITMAP_FLUSH x6
    // -- 4. result
.Lscalar_filter_i64_bitmap_result:
    RET_X   x11
.Lscalar_filter_i64_bitmap_inval:
    RET_INVALID_OP
ENDF pqk_a64_scalar_filter_i64_bitmap

/* ========================================================================
 * sum_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_sum
 * Result:    w0 = PQK_OK (*out_sum written) or PQK_OVERFLOW
 * Clobbers:  x0, x4-x9, flags
 * Registers: x5:x4 128-bit accumulator (hi:lo), x6 row i, x7 value,
 *            x8 validity mask / sign word, x9 temp
 * Algorithm: exact 128-bit accumulation (ADD128S: ADDS/ADC with the sign
 *            word); invalid rows are masked to 0 (SBFX of the validity bit).
 *            Overflow iff the final 128-bit sum is outside int64
 *            (SUM64_RESULT), so cancelling intermediate overflow is OK.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_sum_i64
    // -- 1. arguments / empty input
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    cbz     x2, .Lscalar_sum_i64_result
    // -- 2. main loop: one row
.Lscalar_sum_i64_main:
    ldr     x7, [x0, x6, lsl #3]
    cbz     x1, .Lscalar_sum_i64_add
    VBIT    8, 1, 6, 9
    sbfx    x8, x8, #0, #1                  // 0 or -1
    and     x7, x7, x8                      // invalid rows contribute 0
.Lscalar_sum_i64_add:
    ADD128S 4, 5, 7, 8
    add     x6, x6, #1
    cmp     x6, x2
    b.lo    .Lscalar_sum_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_sum_i64_result:
    SUM64_RESULT x4, x5, x3
ENDF pqk_a64_scalar_sum_i64

/* ========================================================================
 * sum_f64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n
 * Result:    d0 = sum of the valid values
 * Clobbers:  x6, x8, x9, d0-d2, flags
 * Registers: d0 running sum, d1 value, d2 = +0.0, x6 row i, x8/x9 validity
 * Algorithm: strictly sequential FADD chain, bit-identical to the
 *            reference. Invalid rows add +0.0 (FCSEL), the identity because
 *            the running sum can never be -0.0 (it starts at +0.0 under
 *            round-to-nearest).
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_sum_f64
    // -- 1. arguments / empty input
    fmov    d0, xzr
    fmov    d2, xzr
    mov     x6, #0
    cbz     x2, .Lscalar_sum_f64_result
    // -- 2. main loop: one row
.Lscalar_sum_f64_main:
    ldr     d1, [x0, x6, lsl #3]
    cbz     x1, .Lscalar_sum_f64_add
    VBIT    8, 1, 6, 9
    tst     w8, #1
    fcsel   d1, d1, d2, ne
.Lscalar_sum_f64_add:
    fadd    d0, d0, d1
    add     x6, x6, #1
    cmp     x6, x2
    b.lo    .Lscalar_sum_f64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_sum_f64_result:
    ret
ENDF pqk_a64_scalar_sum_f64

/* ========================================================================
 * minmax_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x5-x10, x12, x13, x15, x16, flags
 * Registers: x5 count, x6 min, x7 max, x8/x9 min/max candidates, x10 row i,
 *            x12/x13 validity, x15 INT64_MAX, x16 INT64_MIN
 * Algorithm: CMP/CSEL min and max from INT64_MAX / INT64_MIN; an invalid
 *            row's candidates are replaced by the neutral extremes (CSEL), so
 *            the update itself is branch-free.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_minmax_i64
    // -- 1. arguments / empty input
    mov     x5, #0
    mov     x15, #PQ_INT64_MAX
    mov     x16, #PQ_INT64_MIN
    mov     x6, x15
    mov     x7, x16
    mov     x10, #0
    cbz     x2, .Lscalar_minmax_i64_result
    // -- 2. main loop: one row
.Lscalar_minmax_i64_main:
    ldr     x8, [x0, x10, lsl #3]
    mov     x9, x8
    cbz     x1, .Lscalar_minmax_i64_all
    VBIT    12, 1, 10, 13
    tst     w12, #1
    csel    x8, x8, x15, ne                 // invalid: neutral for min
    csel    x9, x9, x16, ne                 // invalid: neutral for max
    cinc    x5, x5, ne
    b       .Lscalar_minmax_i64_update
.Lscalar_minmax_i64_all:
    add     x5, x5, #1
.Lscalar_minmax_i64_update:
    MINMAX64_STEP x6, x7, x8, x9
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lscalar_minmax_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_minmax_i64_result:
    MINMAX_RESULT x5, x6, x7
ENDF pqk_a64_scalar_minmax_i64

/* ========================================================================
 * minmax_f64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x5, x6, x10, x12, x13, d0-d5, flags
 * Registers: x5 count, d0 min, d1 max, d2 +inf, d3 -inf, d4/d5 min/max
 *            candidates, x6 temp, x10 row i, x12/x13 validity
 * Algorithm: FCMP/FCSEL from +inf / -inf with the reference's strict "<" /
 *            ">" (first of equal values wins, so signed zeros match too).
 *            Invalid rows become +inf / -inf candidates.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_minmax_f64
    // -- 1. arguments / empty input
    mov     x5, #0
    mov     x6, #PQ_F64_PINF
    fmov    d2, x6
    mov     x6, #PQ_F64_NINF
    fmov    d3, x6
    fmov    d0, d2
    fmov    d1, d3
    mov     x10, #0
    cbz     x2, .Lscalar_minmax_f64_result
    // -- 2. main loop: one row
.Lscalar_minmax_f64_main:
    ldr     d4, [x0, x10, lsl #3]
    fmov    d5, d4
    cbz     x1, .Lscalar_minmax_f64_all
    VBIT    12, 1, 10, 13
    tst     w12, #1
    fcsel   d4, d4, d2, ne
    fcsel   d5, d5, d3, ne
    cinc    x5, x5, ne
    b       .Lscalar_minmax_f64_update
.Lscalar_minmax_f64_all:
    add     x5, x5, #1
.Lscalar_minmax_f64_update:
    F64_MINMAX_STEP d0, d1, d4, d5
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lscalar_minmax_f64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_minmax_f64_result:
    MINMAX_RESULT x5, d0, d1
ENDF pqk_a64_scalar_minmax_f64

/* ========================================================================
 * count_i64
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 a,
 *            x5 b
 * Result:    x0 = number of selected valid rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x14, flags
 * Registers: x7 lo, x8 span, w9 inv (0/1), x10 row i, x11 count,
 *            x12 value / predicate bit, x13/x14 validity temps
 * Algorithm: as filter_i64, adding the predicate bit to the count.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_count_i64
    // -- 1. arguments / empty input
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lscalar_count_i64_inval
    and     w9, w9, #1
    mov     x10, #0
    mov     x11, #0
    cbz     x2, .Lscalar_count_i64_result
    // -- 2. main loop: one row
.Lscalar_count_i64_main:
    ldr     x12, [x0, x10, lsl #3]
    SPRED   12, 7, 8, 9
    AND_VBIT 12, 1, 10, 13, 14
    add     x11, x11, x12
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lscalar_count_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_count_i64_result:
    RET_X   x11
.Lscalar_count_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_scalar_count_i64

/* ========================================================================
 * bitmap_and / bitmap_or / bitmap_andnot (one template, SCALAR_BITOP)
 * Args:      x0 a, x1 b, x2 out, x3 nbytes
 * Result:    none
 * Clobbers:  x0-x5, flags
 * Registers: x4/x5 operands; x0-x3 are advanced in place
 * Algorithm: 8-byte words (BITOP_STEP8: AND / ORR / BIC). Each word is
 *            loaded from both inputs before the store, so out == a or
 *            out == b is safe.
 * Tail:      BITOP_BYTES: the remaining 0-7 bytes one at a time.
 * ======================================================================== */
    .macro SCALAR_BITOP name, insn
FUNC pqk_a64_scalar_bitmap_\name
    // -- 1. arguments / empty input: fewer than 8 bytes -> tail only
    cmp     x3, #8
    b.lo    .Lscalar_bitmap_\name\()_tail
    // -- 2. main loop: 8 bytes
.Lscalar_bitmap_\name\()_main:
    BITOP_STEP8 \insn
    cmp     x3, #8
    b.hs    .Lscalar_bitmap_\name\()_main
    // -- 3. tail: bytes; 4. result: ret
.Lscalar_bitmap_\name\()_tail:
    BITOP_BYTES \insn
ENDF pqk_a64_scalar_bitmap_\name
    .endm

    SCALAR_BITOP and, and
    SCALAR_BITOP or, orr
    SCALAR_BITOP andnot, bic

/* ========================================================================
 * bitmap_popcount
 * Args:      x0 bits, x1 nbits
 * Result:    x0 = number of set bits among the first nbits bits
 * Clobbers:  x0, x2, x3, x7-x10, flags
 * Registers: x2 full bytes left, x3 total, x7 = 0x0101..01 multiplier,
 *            x8/x9 SWAR temps, x10 bits of the partial last byte (nbits & 7)
 * Algorithm: SWAR popcount per 64-bit word (SWARPOP: 2-, 4-, 8-bit field
 *            sums, then a multiply by 0x0101..01 adds the bytes).
 * Tail:      full bytes one at a time, then the partial last byte masked
 *            to its low nbits & 7 bits (LOWBITS); no byte past ceil(nbits/8)
 *            is read.
 * ======================================================================== */
/* SWARPOP r, t : x<r> = popcount(x<r>); clobbers x<t>; needs x7. */
    .macro SWARPOP r, t
    and     x\t, x\r, #0xaaaaaaaaaaaaaaaa
    sub     x\r, x\r, x\t, lsr #1             // 2-bit counts
    and     x\t, x\r, #0xcccccccccccccccc
    and     x\r, x\r, #0x3333333333333333
    add     x\r, x\r, x\t, lsr #2             // 4-bit counts
    add     x\r, x\r, x\r, lsr #4
    and     x\r, x\r, #0x0f0f0f0f0f0f0f0f     // 8-bit counts
    mul     x\r, x\r, x7
    lsr     x\r, x\r, #56                     // sum of bytes
    .endm

FUNC pqk_a64_scalar_bitmap_popcount
    // -- 1. arguments / empty input
    mov     x7, #0x0101010101010101
    and     x10, x1, #7
    lsr     x2, x1, #3
    mov     x3, #0
    cmp     x2, #8
    b.lo    .Lscalar_bitmap_popcount_tail
    // -- 2. main loop: 8 bytes
.Lscalar_bitmap_popcount_main:
    ldr     x8, [x0], #8
    SWARPOP 8, 9
    add     x3, x3, x8
    sub     x2, x2, #8
    cmp     x2, #8
    b.hs    .Lscalar_bitmap_popcount_main
    // -- 3. tail: full bytes, then the partial last byte
.Lscalar_bitmap_popcount_tail:
    cbz     x2, .Lscalar_bitmap_popcount_partial
    ldrb    w8, [x0], #1
    SWARPOP 8, 9
    add     x3, x3, x8
    sub     x2, x2, #1
    b       .Lscalar_bitmap_popcount_tail
.Lscalar_bitmap_popcount_partial:
    cbz     x10, .Lscalar_bitmap_popcount_result // keep low nbits%8 bits
    ldrb    w8, [x0]
    LOWBITS w9, w10
    and     w8, w8, w9
    SWARPOP 8, 9
    add     x3, x3, x8
    // -- 4. result
.Lscalar_bitmap_popcount_result:
    RET_X   x3
ENDF pqk_a64_scalar_bitmap_popcount

/* ========================================================================
 * hash_i64
 * Args:      x0 data, x1 n, x2 seed, x3 out
 * Result:    none
 * Clobbers:  x0, x1, x3-x6, flags
 * Registers: x4/x5 fmix64 multipliers, x6 value; x0, x1, x3 advanced
 * Algorithm: out[i] = fmix64(data[i] ^ seed) (FMIX1: 3 EOR-shift, 2 MUL).
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_hash_i64
    // -- 1. arguments / empty input
    cbz     x1, .Lscalar_hash_i64_result
    LOAD_FMIX 4, 5
    // -- 2. main loop: one row
.Lscalar_hash_i64_main:
    ldr     x6, [x0], #8
    FMIX1   6, 2, 4, 5
    str     x6, [x3], #8
    subs    x1, x1, #1
    b.ne    .Lscalar_hash_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_hash_i64_result:
    ret
ENDF pqk_a64_scalar_hash_i64

/* ========================================================================
 * compare_i64
 * Args:      x0 a, x1 b, x2 n, w3 op, x4 out_bits
 * Result:    x0 = number of set bits, (size_t)-1 for an invalid op
 * Clobbers:  x0, x1, x5, x9-x15, flags
 * Registers: w9 inversion bit (op & 1), x10 row i, x11 count,
 *            x12/x13 operands / predicate bit, x14 temp, w15 output byte,
 *            x5 swap temp
 * Algorithm: CMPOP_CHECK / CMPOP_SWAP reduce every op to EQ or GT plus an
 *            inversion bit; per row CMP + CSET eq|gt + EOR, collected by the
 *            scalar bitmap writer (SCALAR_CMPBITS, one copy per condition so
 *            the loop is branch-free).
 * Tail:      none for the rows; SBITMAP_FLUSH stores the zero-padded partial
 *            last byte.
 * ======================================================================== */
/* SCALAR_CMPBITS cond : main loop + partial-byte flush for one condition. */
    .macro SCALAR_CMPBITS cond
.Lscalar_cmpbits_main\@:
    ldr     x12, [x0, x10, lsl #3]
    ldr     x13, [x1, x10, lsl #3]
    cmp     x12, x13
    cset    w12, \cond
    eor     w12, w12, w9
    SBITMAP_PUT x4
    cmp     x10, x2
    b.lo    .Lscalar_cmpbits_main\@
    SBITMAP_FLUSH x4
    .endm

FUNC pqk_a64_scalar_compare_i64
    // -- 1. arguments / empty input
    CMPOP_CHECK w3, w9, .Lscalar_compare_i64_inval
    CMPOP_SWAP w3, x0, x1, x5
    mov     x10, #0
    mov     x11, #0
    mov     w15, #0
    cbz     x2, .Lscalar_compare_i64_result
    cmp     w3, #PQK_NE
    b.hi    .Lscalar_compare_i64_gt
    // -- 2. main loop: one row (EQ-based ops); 3. tail: partial byte
    SCALAR_CMPBITS eq
    b       .Lscalar_compare_i64_result
.Lscalar_compare_i64_gt:
    // -- 2. main loop: one row (GT-based ops); 3. tail: partial byte
    SCALAR_CMPBITS gt
    // -- 4. result
.Lscalar_compare_i64_result:
    RET_X   x11
.Lscalar_compare_i64_inval:
    RET_INVALID_OP
ENDF pqk_a64_scalar_compare_i64

/* ========================================================================
 * compare_fixed
 * Args:      x0 a, x1 b, x2 width, x3 n, x4 out
 * Result:    none (out[i] = -1 / 0 / 1)
 * Clobbers:  x0, x1, x3-x8, flags
 * Registers: x5 bytes left in the record, x6/x7 operands, w8 result;
 *            x0, x1, x3, x4 advanced
 * Algorithm: per record, 8-byte words compared for equality; the first
 *            differing word is byte-reversed (REV: lexicographic order =
 *            big-endian order) and compared unsigned.
 * Tail:      per record, the remaining 0-7 bytes one at a time (CFX_BYTES);
 *            CFX_RESULT stores the result and skips the unread bytes.
 * ======================================================================== */
FUNC pqk_a64_scalar_compare_fixed
    // -- 1. arguments / empty input
    cbz     x3, .Lscalar_compare_fixed_result
.Lscalar_compare_fixed_rec:
    mov     x5, x2
    // -- 2. main loop: 8-byte words of one record
.Lscalar_compare_fixed_main:
    cmp     x5, #8
    b.lo    .Lscalar_compare_fixed_tail
    ldr     x6, [x0], #8
    ldr     x7, [x1], #8
    sub     x5, x5, #8
    cmp     x6, x7
    b.eq    .Lscalar_compare_fixed_main
    rev     x6, x6                          // lexicographic order = BE order
    rev     x7, x7
    cmp     x6, x7
    b       .Lscalar_compare_fixed_diff
    // -- 3. tail: bytes of the record
    CFX_BYTES w6, w7, .Lscalar_compare_fixed_tail, .Lscalar_compare_fixed_eq
    // -- 4. result: per record, then next record
    CFX_RESULT w8, .Lscalar_compare_fixed_diff, .Lscalar_compare_fixed_eq, \
               .Lscalar_compare_fixed_next, .Lscalar_compare_fixed_rec
.Lscalar_compare_fixed_result:
    ret
ENDF pqk_a64_scalar_compare_fixed

/* ========================================================================
 * group_sum_i64
 * Args:      x0 group_ids, x1 values, x2 validity (NULL = all valid), x3 n,
 *            x4 sums, x5 counts (may be NULL), x6 ngroups
 * Result:    w0 = PQK_OK, PQK_OVERFLOW or PQK_EINVAL (outputs untouched)
 * Clobbers:  x0, x9-x13, flags
 * Registers: x10 row i, x11 group id, x12/x13 temps, w9 overflow flag
 * Algorithm: pass 1 validates the id of every valid row (EINVAL before any
 *            output is written); pass 2 (GSUM_ROWS) accumulates in row order
 *            with ADDS, collecting the signed-overflow V flag via CSINC.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_group_sum_i64
    // -- 1. arguments / empty input
    mov     x10, #0
    cbz     x3, .Lscalar_group_sum_i64_ok
    // -- 2. main loop, pass 1: validate the ids of valid rows
.Lscalar_group_sum_i64_main:
    cbz     x2, .Lscalar_group_sum_i64_check
    VBIT    12, 2, 10, 13
    tbz     w12, #0, .Lscalar_group_sum_i64_next
.Lscalar_group_sum_i64_check:
    ldr     w11, [x0, x10, lsl #2]
    cmp     x11, x6
    b.hs    .Lscalar_group_sum_i64_inval
.Lscalar_group_sum_i64_next:
    add     x10, x10, #1
    cmp     x10, x3
    b.lo    .Lscalar_group_sum_i64_main
    // -- 2. main loop, pass 2: row-order accumulation
    mov     x10, #0
    mov     w9, #0
    GSUM_ROWS
    // -- 3. tail: none
    // -- 4. result
    RET_W   w9                              // PQK_OK (0) or PQK_OVERFLOW (1)
.Lscalar_group_sum_i64_ok:
    RET_STATUS PQK_OK
.Lscalar_group_sum_i64_inval:
    RET_STATUS PQK_EINVAL
ENDF pqk_a64_scalar_group_sum_i64

/* ========================================================================
 * gather_i64
 * Args:      x0 data, x1 idx, x2 m, x3 out
 * Result:    none
 * Clobbers:  x1-x5, flags
 * Registers: x4 index (zero-extended uint32), x5 value; x1-x3 advanced
 * Algorithm: out[j] = data[idx[j]], one row per iteration.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_gather_i64
    // -- 1. arguments / empty input
    cbz     x2, .Lscalar_gather_i64_result
    // -- 2. main loop: one row
.Lscalar_gather_i64_main:
    ldr     w4, [x1], #4
    ldr     x5, [x0, x4, lsl #3]
    str     x5, [x3], #8
    subs    x2, x2, #1
    b.ne    .Lscalar_gather_i64_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_gather_i64_result:
    ret
ENDF pqk_a64_scalar_gather_i64

/* ========================================================================
 * 128-bit kernels (CR-4, kernels 17-20). Values are pqk_i128 {lo, hi}
 * pairs, loaded with one LDP (any alignment). Comparisons use the CMP/SBCS
 * multi-word chain (flags of the full 128-bit subtraction).
 * ======================================================================== */

/* ========================================================================
 * filter_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 &a,
 *            x5 &b (read only for BETWEEN), x6 out_idx
 * Result:    x0 = number of selected rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x17, flags
 * Registers: x8:x7 lo, x10:x9 span, w11 inv (0/1), x12/x13 setup temps,
 *            then value lo/hi and predicate bit, x14 row i, x15 output
 *            count k, x16/x17 validity bit / temp
 * Algorithm: PRED128_SETUP validates op before touching *a / *b and builds
 *            pred(x) = ((x - lo) <=u span) ^ inv in 128 bits. Per row: LDP,
 *            SPRED128 (SUBS/SBC x - lo, CMP/SBCS span - d, CSET, EOR), AND
 *            the validity bit. The row index is stored unconditionally at
 *            out[k] (k <= i < n) and k advances by the predicate bit.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_filter_i128
    // -- 1. arguments / empty input
    PRED128_SETUP w3, x4, x5, x7, x8, x9, x10, x11, x12, x13, .Lscalar_filter_i128_inval
    and     w11, w11, #1
    mov     x14, #0
    mov     x15, #0
    cbz     x2, .Lscalar_filter_i128_result
    // -- 2. main loop: one row
.Lscalar_filter_i128_main:
    ldp     x12, x13, [x0], #16
    SPRED128 12, 13, 7, 8, 9, 10, 11
    AND_VBIT 12, 1, 14, 16, 17
    str     w14, [x6, x15, lsl #2]          // unconditional store, k <= i < n
    add     x15, x15, x12
    add     x14, x14, #1
    cmp     x14, x2
    b.lo    .Lscalar_filter_i128_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_filter_i128_result:
    RET_X   x15
.Lscalar_filter_i128_inval:
    RET_INVALID_OP
ENDF pqk_a64_scalar_filter_i128

/* ========================================================================
 * count_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, w3 op, x4 &a,
 *            x5 &b (read only for BETWEEN)
 * Result:    x0 = number of selected valid rows, (size_t)-1 for an invalid op
 * Clobbers:  x0, x7-x17, flags
 * Registers: as filter_i128; x15 = count
 * Algorithm: as filter_i128, adding the predicate bit to the count.
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_count_i128
    // -- 1. arguments / empty input
    PRED128_SETUP w3, x4, x5, x7, x8, x9, x10, x11, x12, x13, .Lscalar_count_i128_inval
    and     w11, w11, #1
    mov     x14, #0
    mov     x15, #0
    cbz     x2, .Lscalar_count_i128_result
    // -- 2. main loop: one row
.Lscalar_count_i128_main:
    ldp     x12, x13, [x0], #16
    SPRED128 12, 13, 7, 8, 9, 10, 11
    AND_VBIT 12, 1, 14, 16, 17
    add     x15, x15, x12
    add     x14, x14, #1
    cmp     x14, x2
    b.lo    .Lscalar_count_i128_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_count_i128_result:
    RET_X   x15
.Lscalar_count_i128_inval:
    RET_INVALID_OP
ENDF pqk_a64_scalar_count_i128

/* ========================================================================
 * sum_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_sum
 * Result:    w0 = PQK_OK (*out_sum written) or PQK_OVERFLOW
 * Clobbers:  x0, x4-x12, flags
 * Registers: x6:x5:x4 192-bit accumulator (top, mid, lo), x7 row i,
 *            x8/x9 value lo/hi, x10 sign word, x11/x12 validity mask / temp
 * Algorithm: every value is sign-extended to 192 bits and added with
 *            ADDS/ADCS/ADC (ADD192S). With n < 2^32 the exact sum has
 *            |S| < 2^159, so the accumulator never wraps and holds the exact
 *            sum; intermediate excursions outside int128 cancel out. The sum
 *            fits in int128 iff top == mid ASR 63 (SUM128_RESULT), otherwise
 *            PQK_OVERFLOW and *out_sum is not written. Invalid rows are
 *            masked to 0 (SBFX of the validity bit, AND).
 * Tail:      none (one row per iteration).
 * ======================================================================== */
FUNC pqk_a64_scalar_sum_i128
    // -- 1. arguments / empty input
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    mov     x7, #0
    cbz     x2, .Lscalar_sum_i128_result
    // -- 2. main loop: one row
.Lscalar_sum_i128_main:
    ldp     x8, x9, [x0], #16
    cbz     x1, .Lscalar_sum_i128_add
    VBIT    11, 1, 7, 12
    sbfx    x11, x11, #0, #1                // 0 or -1
    and     x8, x8, x11
    and     x9, x9, x11
.Lscalar_sum_i128_add:
    ADD192S 4, 5, 6, 8, 9, 10
    add     x7, x7, #1
    cmp     x7, x2
    b.lo    .Lscalar_sum_i128_main
    // -- 3. tail: none
    // -- 4. result
.Lscalar_sum_i128_result:
    SUM128_RESULT x4, x5, x6, x3
ENDF pqk_a64_scalar_sum_i128

/* ========================================================================
 * minmax_i128
 * Args:      x0 data, x1 validity (NULL = all valid), x2 n, x3 out_min,
 *            x4 out_max
 * Result:    x0 = number of valid rows (outputs written only if > 0)
 * Clobbers:  x0, x5-x14, flags
 * Registers: x5 count, x7:x6 min (starts at INT128_MAX), x9:x8 max (starts
 *            at INT128_MIN), x10 row i, x12:x11 value, w13 validity bit,
 *            x14 temp
 * Algorithm: signed 128-bit ordering from the CMP/SBCS chain (lt), CSEL of
 *            both words (MIN128/MAX128). With validity the update condition
 *            is "lt AND valid", folded with CCMP (MIN128V/MAX128V), so both
 *            loops are branch-free. Starting from the neutral extremes gives
 *            the same result as the reference's "first valid value"
 *            initialisation (integers: ties are indistinguishable).
 * Tail:      none (one row per iteration).
 * ======================================================================== */
/* MIN128V / MAX128V ml, mh, xl, xh, v : as MIN128 / MAX128, but only when
 * w<v> (0 or 1) is 1. CCMP folds the validity into the condition:
 * if lt then Z = (v == 0) else Z = 1; the update happens on ne. */
    .macro MIN128V ml, mh, xl, xh, v
    cmp     x\xl, x\ml
    sbcs    xzr, x\xh, x\mh
    ccmp    w\v, #0, #4, lt
    csel    x\ml, x\xl, x\ml, ne
    csel    x\mh, x\xh, x\mh, ne
    .endm

    .macro MAX128V ml, mh, xl, xh, v
    cmp     x\ml, x\xl
    sbcs    xzr, x\mh, x\xh
    ccmp    w\v, #0, #4, lt
    csel    x\ml, x\xl, x\ml, ne
    csel    x\mh, x\xh, x\mh, ne
    .endm

FUNC pqk_a64_scalar_minmax_i128
    // -- 1. arguments / empty input
    mov     x5, #0
    mov     x6, #-1                         // min = INT128_MAX
    mov     x7, #PQ_INT64_MAX
    mov     x8, #0                          // max = INT128_MIN
    mov     x9, #PQ_INT64_MIN
    mov     x10, #0
    cbz     x2, .Lscalar_minmax_i128_result
    cbz     x1, .Lscalar_minmax_i128_main_nv
    // -- 2. main loop: one row, with validity
.Lscalar_minmax_i128_main_v:
    ldp     x11, x12, [x0], #16
    VBIT    13, 1, 10, 14
    and     w13, w13, #1
    add     x5, x5, x13
    MIN128V 6, 7, 11, 12, 13
    MAX128V 8, 9, 11, 12, 13
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lscalar_minmax_i128_main_v
    b       .Lscalar_minmax_i128_result
    // -- 2. main loop: one row, no validity
.Lscalar_minmax_i128_main_nv:
    ldp     x11, x12, [x0], #16
    MIN128  6, 7, 11, 12
    MAX128  8, 9, 11, 12
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lscalar_minmax_i128_main_nv
    mov     x5, x2
    // -- 3. tail: none
    // -- 4. result
.Lscalar_minmax_i128_result:
    MINMAX128_RESULT x5, x6, x7, x8, x9
ENDF pqk_a64_scalar_minmax_i128

    PQ_FILE_END
