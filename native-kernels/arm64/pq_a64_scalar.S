/*
 * pq_a64_scalar.S — PolyQuery native kernels, AArch64 scalar variant
 * ("a64_scalar"). GNU as syntax, AAPCS64, general-purpose/FP registers only
 * (no Advanced SIMD vector instructions).
 *
 * ABI / register conventions (all functions):
 *   - Arguments arrive in x0..x6 (no FP arguments), results in x0/w0/d0.
 *   - Only caller-saved registers are used: x0-x17 and v0-v7 (d0-d7). No
 *     callee-saved register (x19-x28, d8-d15) is touched, no stack frame is
 *     needed (every function is a leaf), sp is never modified, so stack
 *     alignment and red-zone questions do not arise. x18 (platform register)
 *     is never used.
 *   - `int` arguments (op) are read from the W view only.
 *   - All memory accesses are plain LDR/STR, which are alignment-agnostic on
 *     AArch64 Linux user space, so unaligned pointers are handled natively.
 *   - Every loop is guarded by n == 0 checks before the first access, so
 *     NULL pointers with n == 0 are never dereferenced.
 *
 * Algorithms:
 *   - Predicates (filter/filter_bitmap/count) use the branch-free range form
 *     pred(x) = ((x - lo) <=u span) ^ inv  (see PRED_SETUP in pq_a64_macros.h),
 *     so one loop serves every op.
 *   - Validity bits are fetched per row (VBIT: byte load + shift); when the
 *     validity pointer is NULL the (perfectly predicted) branch skips it.
 *   - filter_i64 stores every candidate index unconditionally and advances the
 *     output cursor by the predicate bit (branch-free compaction; the store at
 *     out[k] with k <= i < n is always inside the documented capacity).
 *   - sum_i64 keeps an exact 128-bit accumulator (adds/adc with the sign
 *     word); overflow iff the high word differs from the sign of the low word.
 *   - sum_f64 is strictly sequential (identical to the reference); invalid
 *     rows add +0.0, which is the identity because the running sum can never
 *     be -0.0 (it starts at +0.0 under round-to-nearest).
 *   - minmax_f64 starts from +inf/-inf and uses fcmp/fcsel with the same
 *     strict comparisons as the reference, so even signed zeros match.
 *   - bitmap ops and popcount work on 64-bit words (SWAR popcount) with byte
 *     tails; compare_fixed compares 8-byte big-endian words then bytes.
 *   - hash_i64 is the MurmurHash3 fmix64 finalizer with MUL.
 *   - group_sum_i64 validates all ids first, then accumulates with ADDS,
 *     collecting the V flag (signed wrap) via CSINC.
 */
#include "pq_a64_macros.h"

/* ------------------------------------------------------------------------
 * size_t filter_i64(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b, x6 out_idx)
 * x7 lo, x8 span, w9 inv(0/1), x10 i, x11 k, x12 value/pred, x13/x14 temps
 */
FUNC pqk_a64_scalar_filter_i64
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lsf_inval
    and     w9, w9, #1
    mov     x10, #0
    mov     x11, #0
    cbz     x2, .Lsf_done
.Lsf_loop:
    ldr     x12, [x0, x10, lsl #3]
    SPRED   12, 7, 8, 9
    cbz     x1, 1f
    VBIT    13, 1, 10, 14
    and     w12, w12, w13
1:  str     w10, [x6, x11, lsl #2]          // unconditional store, k <= i < n
    add     x11, x11, x12
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lsf_loop
.Lsf_done:
    mov     x0, x11
    ret
.Lsf_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_scalar_filter_i64

/* ------------------------------------------------------------------------
 * size_t filter_i64_bitmap(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b,
 *                          x6 out_bits)
 * x7 lo, x8 span, w9 inv, x10 i, x11 count, w15 current output byte
 */
FUNC pqk_a64_scalar_filter_i64_bitmap
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lsfb_inval
    and     w9, w9, #1
    mov     x10, #0
    mov     x11, #0
    mov     w15, #0
    cbz     x2, .Lsfb_done
.Lsfb_loop:
    ldr     x12, [x0, x10, lsl #3]
    SPRED   12, 7, 8, 9
    cbz     x1, 1f
    VBIT    13, 1, 10, 14
    and     w12, w12, w13
1:  and     x14, x10, #7
    lsl     w13, w12, w14
    orr     w15, w15, w13
    add     x11, x11, x12
    add     x10, x10, #1
    tst     x10, #7
    b.ne    2f
    lsr     x13, x10, #3                    // byte (i-1)/8 is complete
    sub     x13, x13, #1
    strb    w15, [x6, x13]
    mov     w15, #0
2:  cmp     x10, x2
    b.lo    .Lsfb_loop
    tst     x2, #7                          // partial last byte (zero padded)
    b.eq    .Lsfb_done
    lsr     x13, x2, #3
    strb    w15, [x6, x13]
.Lsfb_done:
    mov     x0, x11
    ret
.Lsfb_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_scalar_filter_i64_bitmap

/* ------------------------------------------------------------------------
 * int sum_i64(x0 data, x1 validity, x2 n, x3 out_sum)
 * x4:x5 = 128-bit accumulator (lo:hi), x6 i, x7 value, x8 sign/mask
 */
FUNC pqk_a64_scalar_sum_i64
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    cbz     x2, .Lss_fin
.Lss_loop:
    ldr     x7, [x0, x6, lsl #3]
    cbz     x1, 1f
    VBIT    8, 1, 6, 9
    sbfx    x8, x8, #0, #1                  // 0 or -1
    and     x7, x7, x8                      // invalid rows contribute 0
1:  asr     x8, x7, #63
    adds    x4, x4, x7
    adc     x5, x5, x8
    add     x6, x6, #1
    cmp     x6, x2
    b.lo    .Lss_loop
.Lss_fin:
    cmp     x5, x4, asr #63                 // fits in int64 <=> hi == sign(lo)
    b.ne    .Lss_ovf
    str     x4, [x3]
    mov     w0, #0
    ret
.Lss_ovf:
    mov     w0, #1
    ret
ENDF pqk_a64_scalar_sum_i64

/* ------------------------------------------------------------------------
 * double sum_f64(x0 data, x1 validity, x2 n)
 * d0 running sum, d1 value, d2 = +0.0, x6 i
 */
FUNC pqk_a64_scalar_sum_f64
    fmov    d0, xzr
    fmov    d2, xzr
    mov     x6, #0
    cbz     x2, 2f
1:  ldr     d1, [x0, x6, lsl #3]
    cbz     x1, 3f
    VBIT    8, 1, 6, 9
    tst     w8, #1
    fcsel   d1, d1, d2, ne
3:  fadd    d0, d0, d1
    add     x6, x6, #1
    cmp     x6, x2
    b.lo    1b
2:  ret
ENDF pqk_a64_scalar_sum_f64

/* ------------------------------------------------------------------------
 * size_t minmax_i64(x0 data, x1 validity, x2 n, x3 out_min, x4 out_max)
 * x5 count, x6 min, x7 max, x8/x9 candidates, x10 i, x15 MAX, x16 MIN
 */
FUNC pqk_a64_scalar_minmax_i64
    mov     x5, #0
    mov     x15, #0x7fffffffffffffff
    mov     x16, #0x8000000000000000
    mov     x6, x15
    mov     x7, x16
    mov     x10, #0
    cbz     x2, .Lsmm_fin
.Lsmm_loop:
    ldr     x8, [x0, x10, lsl #3]
    mov     x9, x8
    cbz     x1, 1f
    VBIT    12, 1, 10, 13
    tst     w12, #1
    csel    x8, x8, x15, ne                 // invalid: neutral for min
    csel    x9, x9, x16, ne                 // invalid: neutral for max
    cinc    x5, x5, ne
    b       2f
1:  add     x5, x5, #1
2:  cmp     x8, x6
    csel    x6, x8, x6, lt
    cmp     x9, x7
    csel    x7, x9, x7, gt
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lsmm_loop
.Lsmm_fin:
    cbz     x5, 3f
    str     x6, [x3]
    str     x7, [x4]
3:  mov     x0, x5
    ret
ENDF pqk_a64_scalar_minmax_i64

/* ------------------------------------------------------------------------
 * size_t minmax_f64(x0 data, x1 validity, x2 n, x3 out_min, x4 out_max)
 * x5 count, d0 min, d1 max, d2 +inf, d3 -inf, d4/d5 candidates, x10 i
 * Strict "<" / ">" exactly like the reference (first of equal values wins).
 */
FUNC pqk_a64_scalar_minmax_f64
    mov     x5, #0
    mov     x6, #0x7ff0000000000000
    fmov    d2, x6
    mov     x6, #0xfff0000000000000
    fmov    d3, x6
    fmov    d0, d2
    fmov    d1, d3
    mov     x10, #0
    cbz     x2, .Lsmf_fin
.Lsmf_loop:
    ldr     d4, [x0, x10, lsl #3]
    fmov    d5, d4
    cbz     x1, 1f
    VBIT    12, 1, 10, 13
    tst     w12, #1
    fcsel   d4, d4, d2, ne
    fcsel   d5, d5, d3, ne
    cinc    x5, x5, ne
    b       2f
1:  add     x5, x5, #1
2:  fcmp    d4, d0
    fcsel   d0, d4, d0, mi
    fcmp    d5, d1
    fcsel   d1, d5, d1, gt
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lsmf_loop
.Lsmf_fin:
    cbz     x5, 3f
    str     d0, [x3]
    str     d1, [x4]
3:  mov     x0, x5
    ret
ENDF pqk_a64_scalar_minmax_f64

/* ------------------------------------------------------------------------
 * size_t count_i64(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b)
 * x7 lo, x8 span, w9 inv, x10 i, x11 count
 */
FUNC pqk_a64_scalar_count_i64
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lsc_inval
    and     w9, w9, #1
    mov     x10, #0
    mov     x11, #0
    cbz     x2, .Lsc_done
.Lsc_loop:
    ldr     x12, [x0, x10, lsl #3]
    SPRED   12, 7, 8, 9
    cbz     x1, 1f
    VBIT    13, 1, 10, 14
    and     w12, w12, w13
1:  add     x11, x11, x12
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    .Lsc_loop
.Lsc_done:
    mov     x0, x11
    ret
.Lsc_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_scalar_count_i64

/* ------------------------------------------------------------------------
 * void bitmap_{and,or,andnot}(x0 a, x1 b, x2 out, x3 nbytes)
 * 8-byte words then a byte tail. Each word is fully loaded from both inputs
 * before the store, so out == a or out == b is safe.
 * x4/x5 operands.
 */
    .macro SBITOP name, insn
FUNC pqk_a64_scalar_bitmap_\name
    cmp     x3, #8
    b.lo    2f
1:  ldr     x4, [x0], #8
    ldr     x5, [x1], #8
    \insn   x4, x4, x5
    str     x4, [x2], #8
    sub     x3, x3, #8
    cmp     x3, #8
    b.hs    1b
2:  cbz     x3, 3f
    ldrb    w4, [x0], #1
    ldrb    w5, [x1], #1
    \insn   w4, w4, w5
    strb    w4, [x2], #1
    sub     x3, x3, #1
    b       2b
3:  ret
ENDF pqk_a64_scalar_bitmap_\name
    .endm

    SBITOP  and, and
    SBITOP  or, orr
    SBITOP  andnot, bic

/* ------------------------------------------------------------------------
 * size_t bitmap_popcount(x0 bits, x1 nbits)
 * SWAR popcount on 64-bit words; x2 full bytes left, x3 total,
 * x7 = 0x0101..01 multiplier, x8/x9 temps, x10 partial bit count.
 */
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
    mov     x7, #0x0101010101010101
    and     x10, x1, #7
    lsr     x2, x1, #3
    mov     x3, #0
    cmp     x2, #8
    b.lo    2f
1:  ldr     x8, [x0], #8
    SWARPOP 8, 9
    add     x3, x3, x8
    sub     x2, x2, #8
    cmp     x2, #8
    b.hs    1b
2:  cbz     x2, 3f
    ldrb    w8, [x0], #1
    SWARPOP 8, 9
    add     x3, x3, x8
    sub     x2, x2, #1
    b       2b
3:  cbz     x10, 4f                         // partial byte: keep low nbits%8 bits
    ldrb    w8, [x0]
    mov     w9, #1
    lsl     w9, w9, w10
    sub     w9, w9, #1
    and     w8, w8, w9
    SWARPOP 8, 9
    add     x3, x3, x8
4:  mov     x0, x3
    ret
ENDF pqk_a64_scalar_bitmap_popcount

/* ------------------------------------------------------------------------
 * void hash_i64(x0 data, x1 n, x2 seed, x3 out)
 * x4/x5 fmix64 multipliers, x6 value
 */
FUNC pqk_a64_scalar_hash_i64
    cbz     x1, 2f
    LOAD_FMIX 4, 5
1:  ldr     x6, [x0], #8
    FMIX1   6, 2, 4, 5
    str     x6, [x3], #8
    subs    x1, x1, #1
    b.ne    1b
2:  ret
ENDF pqk_a64_scalar_hash_i64

/* ------------------------------------------------------------------------
 * size_t compare_i64(x0 a, x1 b, x2 n, w3 op, x4 out_bits)
 * Ops are reduced to EQ or GT plus an inversion bit (w9 = op & 1):
 *   EQ=eq, NE=!eq, GT=gt, LE=!gt, LT=gt(swapped), GE=!gt(swapped).
 * x10 i, x11 count, w15 current output byte.
 */
    .macro SCMPBITS cond
.Lscb_loop\@:
    ldr     x12, [x0, x10, lsl #3]
    ldr     x13, [x1, x10, lsl #3]
    cmp     x12, x13
    cset    w12, \cond
    eor     w12, w12, w9
    and     x14, x10, #7
    lsl     w13, w12, w14
    orr     w15, w15, w13
    add     x11, x11, x12
    add     x10, x10, #1
    tst     x10, #7
    b.ne    .Lscb_next\@
    lsr     x13, x10, #3
    sub     x13, x13, #1
    strb    w15, [x4, x13]
    mov     w15, #0
.Lscb_next\@:
    cmp     x10, x2
    b.lo    .Lscb_loop\@
    tst     x2, #7
    b.eq    .Lscb_end\@
    lsr     x13, x2, #3
    strb    w15, [x4, x13]
.Lscb_end\@:
    .endm

FUNC pqk_a64_scalar_compare_i64
    cmp     w3, #5
    b.hi    .Lsci_inval
    and     w9, w3, #1
    cmp     w3, #2
    b.eq    1f
    cmp     w3, #5
    b.ne    2f
1:  mov     x5, x0                          // LT / GE: swap operands
    mov     x0, x1
    mov     x1, x5
2:  mov     x10, #0
    mov     x11, #0
    mov     w15, #0
    cbz     x2, .Lsci_done
    cmp     w3, #1
    b.hi    .Lsci_gt
    SCMPBITS eq
    b       .Lsci_done
.Lsci_gt:
    SCMPBITS gt
.Lsci_done:
    mov     x0, x11
    ret
.Lsci_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_scalar_compare_i64

/* ------------------------------------------------------------------------
 * void compare_fixed(x0 a, x1 b, x2 width, x3 n, x4 out)
 * Per record: 8-byte words compared as big-endian (REV) unsigned integers,
 * then single bytes. x5 bytes left in record, x6/x7 operands, w8 result.
 */
FUNC pqk_a64_scalar_compare_fixed
    cbz     x3, .Lscf_ret
.Lscf_rec:
    mov     x5, x2
1:  cmp     x5, #8
    b.lo    2f
    ldr     x6, [x0], #8
    ldr     x7, [x1], #8
    sub     x5, x5, #8
    cmp     x6, x7
    b.eq    1b
    rev     x6, x6                          // lexicographic order = BE order
    rev     x7, x7
    cmp     x6, x7
    b       .Lscf_diff
2:  cbz     x5, .Lscf_eq
    ldrb    w6, [x0], #1
    ldrb    w7, [x1], #1
    sub     x5, x5, #1
    cmp     w6, w7
    b.eq    2b
.Lscf_diff:
    mov     w8, #1
    cneg    w8, w8, lo                      // a < b -> -1, a > b -> 1
    strb    w8, [x4], #1
    add     x0, x0, x5                      // skip rest of the record
    add     x1, x1, x5
    b       .Lscf_next
.Lscf_eq:
    strb    wzr, [x4], #1
.Lscf_next:
    subs    x3, x3, #1
    b.ne    .Lscf_rec
.Lscf_ret:
    ret
ENDF pqk_a64_scalar_compare_fixed

/* ------------------------------------------------------------------------
 * int group_sum_i64(x0 group_ids, x1 values, x2 validity, x3 n, x4 sums,
 *                   x5 counts, x6 ngroups)
 * Pass 1 validates every valid row's id (outputs untouched on EINVAL).
 * Pass 2 accumulates in row order; w9 collects signed-overflow (V flag).
 * x10 i, x11 group id, x12/x13 temps.
 */
FUNC pqk_a64_scalar_group_sum_i64
    mov     x10, #0
    cbz     x3, .Lsg_ok
.Lsg_chk:
    cbz     x2, 1f
    VBIT    12, 2, 10, 13
    tbz     w12, #0, 2f
1:  ldr     w11, [x0, x10, lsl #2]
    cmp     x11, x6
    b.hs    .Lsg_inval
2:  add     x10, x10, #1
    cmp     x10, x3
    b.lo    .Lsg_chk
    mov     x10, #0
    mov     w9, #0
.Lsg_loop:
    cbz     x2, 1f
    VBIT    12, 2, 10, 13
    tbz     w12, #0, 3f
1:  ldr     w11, [x0, x10, lsl #2]
    ldr     x12, [x1, x10, lsl #3]
    ldr     x13, [x4, x11, lsl #3]
    adds    x13, x13, x12
    csinc   w9, w9, wzr, vc                 // w9 = 1 on signed wrap
    str     x13, [x4, x11, lsl #3]
    cbz     x5, 3f
    ldr     x13, [x5, x11, lsl #3]
    add     x13, x13, #1
    str     x13, [x5, x11, lsl #3]
3:  add     x10, x10, #1
    cmp     x10, x3
    b.lo    .Lsg_loop
    mov     w0, w9                          // PQK_OK (0) or PQK_OVERFLOW (1)
    ret
.Lsg_ok:
    mov     w0, #0
    ret
.Lsg_inval:
    mov     w0, #2
    ret
ENDF pqk_a64_scalar_group_sum_i64

/* ------------------------------------------------------------------------
 * void gather_i64(x0 data, x1 idx, x2 m, x3 out)
 * x4 index (zero-extended uint32), x5 value
 */
FUNC pqk_a64_scalar_gather_i64
    cbz     x2, 2f
1:  ldr     w4, [x1], #4
    ldr     x5, [x0, x4, lsl #3]
    str     x5, [x3], #8
    subs    x2, x2, #1
    b.ne    1b
2:  ret
ENDF pqk_a64_scalar_gather_i64

    .section .note.GNU-stack, "", %progbits
