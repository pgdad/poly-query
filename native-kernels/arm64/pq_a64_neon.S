/*
 * pq_a64_neon.S — PolyQuery native kernels, AArch64 Advanced SIMD variant
 * ("a64_neon"). GNU as syntax, AAPCS64.
 *
 * ABI / register conventions (all functions):
 *   - Arguments in x0..x6, results in x0/w0/d0; `int` args read as W only.
 *   - Only caller-saved registers are used: x0-x17 and v0-v7, v16-v31.
 *     v8-v15 (whose low halves d8-d15 are callee-saved) and x19-x29 are never
 *     touched; every function is a leaf (the only branch to other code is a
 *     tail call to the local popcount routine), sp is never modified, so no
 *     frame, stack alignment or red zone is involved. x18 is never used.
 *   - Loads/stores are LD1/LDR/LDP/ST1/STR/STP, which accept any alignment
 *     on AArch64 Linux user space (no exclusive or alignment-checked forms).
 *   - Vector loops only run while a whole block is in bounds; the remaining
 *     rows (< block size) are processed by scalar tail code. Validity bytes
 *     are read with byte/halfword loads covering exactly the rows processed,
 *     so nothing outside ceil(n/8) validity bytes or the n elements is read,
 *     and nothing outside the documented output size is written.
 *
 * Common building blocks:
 *   v16/v17 = lo/span of the canonical range predicate
 *             pred(x) = ((x - lo) <=u span) ^ inv   (PRED_SETUP in the macro
 *             header): SUB + CMHS per 2 rows, inversion applied once per
 *             16-row mask in a GPR (or per lane for count with validity).
 *   PACK16  narrows eight 2x64-bit lane masks (16 rows) to a 16-bit row mask:
 *             3 levels of UZP1, AND with the bit-weight vector, 3x ADDP.
 *   Validity bytes are expanded to lane masks with LD1R (replicate byte)
 *   + CMTST against per-lane bit constants.
 *
 * Kernel algorithms:
 *   filter_i64        16 rows/iter -> 16-bit mask (& validity, ^ inv); each
 *                     mask byte indexes a 256x8 table of packed positions,
 *                     widened to u32, offset by the row base and stored as 8
 *                     indices (32 bytes) branch-free; the cursor advances by
 *                     popcount from a 256-entry table. The over-store is safe:
 *                     cursor k <= row i and i + 8 <= n inside the main loop.
 *   filter_i64_bitmap 16 rows/iter -> STRH of the mask; scalar tail builds
 *                     the last (zero padded) bytes; the count is a popcount of
 *                     the finished bitmap (tail call to the popcount loop).
 *   count_i64         8 rows/iter, lane masks accumulated with SUB into 2x64
 *                     counters; without validity the inversion is applied
 *                     algebraically at the end (count = rows - count).
 *   sum_i64           exact: LD2 splits each int64 into its unsigned low and
 *                     signed high 32-bit halves; UADALP / SADALP accumulate
 *                     them pairwise into 64-bit lanes (no overflow possible
 *                     within a block of 2^24 iterations); each block is
 *                     folded into a 128-bit GPR total as lo + (hi << 32).
 *                     Overflow iff the final 128-bit value is outside int64.
 *   sum_f64           4 x 2-lane accumulators (8 partial sums), invalid lanes
 *                     zeroed with AND; scalar sequential tail.
 *   minmax_i64        CMGT + BIT (NEON has no 64-bit SMIN/SMAX), validity
 *                     folded into the update mask, two accumulator pairs.
 *   minmax_f64        FMINNM/FMAXNM; invalid lanes are forced to all-ones
 *                     (a quiet NaN, ignored by FMINNM/FMAXNM) with ORN. To be
 *                     bit-identical with the sequential reference for signed
 *                     zeros, a zero result is replaced by the first valid zero
 *                     of the input (which is what the reference returns).
 *   bitmap and/or/andnot 64-byte LD1/ST1 blocks, then 16, 8, 1 byte steps.
 *   bitmap_popcount   CNT + ADD + UADDLP + UADALP over 64-byte blocks
 *                     (bounded blocks of 2^20 iterations), byte tail, masked
 *                     partial byte.
 *   hash_i64          NEON has no 64x64-bit multiply; emulating it costs ~7
 *                     vector ops per multiply per 2 lanes, so this variant
 *                     uses a 4-way interleaved GPR pipeline (LDP/STP + MUL).
 *   compare_i64       16 rows/iter, CMEQ or CMGT (LT/GE swap the operands,
 *                     NE/LE/GE invert the 16-bit mask), STRH; popcount tail.
 *   compare_fixed     16-byte CMEQ chunks; first difference located with the
 *                     SHRN #4 nibble mask + RBIT/CLZ; then 8-byte BE words
 *                     and single bytes.
 *   group_sum_i64     id validation vectorized (UMAX of masked ids vs.
 *                     ngroups); the scatter-add itself is scalar (no NEON
 *                     scatter), in row order with ADDS/CSINC overflow flag.
 *   gather_i64        4-way unrolled scalar loads (no NEON gather).
 */
#include "pq_a64_macros.h"

/* ---------------------------------------------------------------------- */
/* Constant tables                                                         */
/* ---------------------------------------------------------------------- */
    .section .rodata
    .p2align 4
.Lbitsel16:                                 // bit weight of each row in a byte
    .byte   1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128
.Lbits2d:                                   // CMTST constants, 2 x 64-bit lanes
    .quad   1, 2, 4, 8, 16, 32, 64, 128
.Lbits4s:                                   // CMTST constants, 4 x 32-bit lanes
    .word   1, 2, 4, 8, 16, 32, 64, 128

/* .Lselpos: for every byte value m, the ascending positions of its set bits
 * (8 bytes per entry, unused slots 0). .Lselcnt: popcount of m.
 * Generated by the assembler from the definition (no external generator). */
    .p2align 3
.Lselpos:
    .set    .Lm, 0
    .rept   256
    .set    .Lc, 0
    .set    .Lj, 0
    .rept   8
    .if     (.Lm >> .Lj) & 1
    .byte   .Lj
    .set    .Lc, .Lc + 1
    .endif
    .set    .Lj, .Lj + 1
    .endr
    .rept   8 - .Lc
    .byte   0
    .endr
    .set    .Lm, .Lm + 1
    .endr
.Lselcnt:
    .set    .Lm, 0
    .rept   256
    .set    .Lc, 0
    .set    .Lj, 0
    .rept   8
    .set    .Lc, .Lc + ((.Lm >> .Lj) & 1)
    .set    .Lj, .Lj + 1
    .endr
    .byte   .Lc
    .set    .Lm, .Lm + 1
    .endr

    .macro  LOADADDR xr, sym
    adrp    \xr, \sym
    add     \xr, \xr, :lo12:\sym
    .endm

/* PACK16 wout: v0..v7 hold 64-bit lane masks for rows 0..15 (v0 = rows 0,1).
 * Produces the 16-bit row mask in wout. Needs v18 = .Lbitsel16. Clobbers
 * v0, v2, v4, v6. */
    .macro  PACK16 wout
    uzp1    v0.4s, v0.4s, v1.4s
    uzp1    v2.4s, v2.4s, v3.4s
    uzp1    v4.4s, v4.4s, v5.4s
    uzp1    v6.4s, v6.4s, v7.4s
    uzp1    v0.8h, v0.8h, v2.8h
    uzp1    v4.8h, v4.8h, v6.8h
    uzp1    v0.16b, v0.16b, v4.16b
    and     v0.16b, v0.16b, v18.16b
    addp    v0.16b, v0.16b, v0.16b
    addp    v0.16b, v0.16b, v0.16b
    addp    v0.16b, v0.16b, v0.16b
    umov    \wout, v0.h[0]
    .endm

/* RANGE16 xp, wout: loads 16 int64 from [xp] (post-increment) and produces
 * the un-inverted 16-bit range mask. Needs v16 = lo, v17 = span, v18. */
    .macro  RANGE16 xp, wout
    ld1     {v0.2d-v3.2d}, [\xp], #64
    ld1     {v4.2d-v7.2d}, [\xp], #64
    sub     v0.2d, v0.2d, v16.2d
    sub     v1.2d, v1.2d, v16.2d
    sub     v2.2d, v2.2d, v16.2d
    sub     v3.2d, v3.2d, v16.2d
    sub     v4.2d, v4.2d, v16.2d
    sub     v5.2d, v5.2d, v16.2d
    sub     v6.2d, v6.2d, v16.2d
    sub     v7.2d, v7.2d, v16.2d
    cmhs    v0.2d, v17.2d, v0.2d
    cmhs    v1.2d, v17.2d, v1.2d
    cmhs    v2.2d, v17.2d, v2.2d
    cmhs    v3.2d, v17.2d, v3.2d
    cmhs    v4.2d, v17.2d, v4.2d
    cmhs    v5.2d, v17.2d, v5.2d
    cmhs    v6.2d, v17.2d, v6.2d
    cmhs    v7.2d, v17.2d, v7.2d
    PACK16  \wout
    .endm

/* ------------------------------------------------------------------------
 * size_t filter_i64(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b, x6 out_idx)
 * x3 original validity, x7 lo, x8 span, w9 inv (0/0xffff), x10 i,
 * x11 output cursor, x12 .Lselpos, x13 .Lselcnt, x15 main-loop row limit,
 * w16 row mask, x17 temp, v20 = row base (u32 x4), v21 = 8 (u32 x4).
 */
/* EMIT8 m: append the indices selected by mask byte x<m> (clobbers x<m>). */
    .macro  EMIT8 m
    ldr     d0, [x12, x\m, lsl #3]
    ldrb    w\m, [x13, x\m]
    uxtl    v0.8h, v0.8b
    uxtl2   v1.4s, v0.8h
    uxtl    v0.4s, v0.4h
    add     v0.4s, v0.4s, v20.4s
    add     v1.4s, v1.4s, v20.4s
    stp     q0, q1, [x11]
    add     x11, x11, x\m, lsl #2
    add     v20.4s, v20.4s, v21.4s
    .endm

FUNC pqk_a64_neon_filter_i64
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lnf_inval
    and     w9, w9, #0xffff
    mov     x3, x1
    mov     x10, #0
    mov     x11, x6
    and     x15, x2, #~15
    cbz     x15, .Lnf_tail
    dup     v16.2d, x7
    dup     v17.2d, x8
    LOADADDR x12, .Lbitsel16
    ld1     {v18.16b}, [x12]
    LOADADDR x12, .Lselpos
    LOADADDR x13, .Lselcnt
    movi    v20.4s, #0
    movi    v21.4s, #8
.Lnf_main:
    RANGE16 x0, w16
    eor     w16, w16, w9
    cbz     x1, 1f
    ldrh    w17, [x1], #2                   // validity of rows i..i+15
    and     w16, w16, w17
1:  and     w17, w16, #0xff
    EMIT8   17
    lsr     w17, w16, #8
    EMIT8   17
    add     x10, x10, #16
    cmp     x10, x15
    b.lo    .Lnf_main
.Lnf_tail:
    cmp     x10, x2
    b.hs    .Lnf_done
1:  ldr     x14, [x0], #8
    SPRED   14, 7, 8, 9
    cbz     x3, 2f
    VBIT    15, 3, 10, 16
    and     w14, w14, w15
2:  and     w14, w14, #1
    str     w10, [x11]
    add     x11, x11, x14, lsl #2
    add     x10, x10, #1
    cmp     x10, x2
    b.lo    1b
.Lnf_done:
    sub     x0, x11, x6
    lsr     x0, x0, #2
    ret
.Lnf_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_neon_filter_i64

/* ------------------------------------------------------------------------
 * size_t filter_i64_bitmap(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b,
 *                          x6 out_bits)
 * Same registers as filter_i64; w12 tail bit accumulator, x13 tail row.
 */
FUNC pqk_a64_neon_filter_i64_bitmap
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lnfb_inval
    and     w9, w9, #0xffff
    mov     x3, x1
    mov     x10, #0
    mov     x11, x6
    and     x15, x2, #~15
    cbz     x15, .Lnfb_tail
    dup     v16.2d, x7
    dup     v17.2d, x8
    LOADADDR x12, .Lbitsel16
    ld1     {v18.16b}, [x12]
.Lnfb_main:
    RANGE16 x0, w16
    eor     w16, w16, w9
    cbz     x1, 1f
    ldrh    w17, [x1], #2
    and     w16, w16, w17
1:  strh    w16, [x11], #2
    add     x10, x10, #16
    cmp     x10, x15
    b.lo    .Lnfb_main
.Lnfb_tail:                                 // < 16 rows left: build 1-2 bytes
    cmp     x10, x2
    b.hs    .Lnfb_count
    mov     w12, #0
    mov     x13, x10
1:  ldr     x14, [x0], #8
    SPRED   14, 7, 8, 9
    and     w14, w14, #1
    cbz     x3, 2f
    VBIT    15, 3, 13, 16
    and     w14, w14, w15
2:  sub     x15, x13, x10
    lsl     w14, w14, w15
    orr     w12, w12, w14
    add     x13, x13, #1
    cmp     x13, x2
    b.lo    1b
    strb    w12, [x11]
    sub     x15, x2, x10
    cmp     x15, #8
    b.ls    .Lnfb_count
    lsr     w12, w12, #8
    strb    w12, [x11, #1]
.Lnfb_count:                                // return popcount(out_bits, nb bytes)
    mov     x0, x6
    add     x1, x2, #7
    lsr     x1, x1, #3
    mov     x6, #0
    b       .Lnp_bytes
.Lnfb_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_neon_filter_i64_bitmap

/* ------------------------------------------------------------------------
 * int sum_i64(x0 data, x1 validity, x2 n, x3 out_sum)
 * x4:x5 128-bit total, x6 8-row groups left, x7 groups in current block,
 * v16/v18 = unsigned low-half sums, v17/v19 = signed high-half sums,
 * v26/v27 = .Lbits4s, v20 validity byte, v21/v22 row masks.
 */
FUNC pqk_a64_neon_sum_i64
    mov     x4, #0
    mov     x5, #0
    lsr     x6, x2, #3
    cbz     x6, .Lns_tail
    cbz     x1, .Lns_block
    LOADADDR x7, .Lbits4s
    ld1     {v26.4s, v27.4s}, [x7]
.Lns_block:
    mov     x7, #(1 << 24)
    cmp     x6, x7
    csel    x7, x6, x7, lo
    sub     x6, x6, x7
    movi    v16.2d, #0
    movi    v17.2d, #0
    movi    v18.2d, #0
    movi    v19.2d, #0
    cbz     x1, .Lns_nv
.Lns_v:
    ld1r    {v20.16b}, [x1], #1
    ld2     {v0.4s, v1.4s}, [x0], #32       // v0 = low words, v1 = high words
    ld2     {v2.4s, v3.4s}, [x0], #32
    cmtst   v21.4s, v20.4s, v26.4s
    cmtst   v22.4s, v20.4s, v27.4s
    and     v0.16b, v0.16b, v21.16b
    and     v1.16b, v1.16b, v21.16b
    and     v2.16b, v2.16b, v22.16b
    and     v3.16b, v3.16b, v22.16b
    uadalp  v16.2d, v0.4s
    sadalp  v17.2d, v1.4s
    uadalp  v18.2d, v2.4s
    sadalp  v19.2d, v3.4s
    subs    x7, x7, #1
    b.ne    .Lns_v
    b       .Lns_fold
.Lns_nv:
    ld2     {v0.4s, v1.4s}, [x0], #32
    ld2     {v2.4s, v3.4s}, [x0], #32
    uadalp  v16.2d, v0.4s
    sadalp  v17.2d, v1.4s
    uadalp  v18.2d, v2.4s
    sadalp  v19.2d, v3.4s
    subs    x7, x7, #1
    b.ne    .Lns_nv
.Lns_fold:                                  // lanes: |lo| < 2^58, |hi| < 2^57
    add     v16.2d, v16.2d, v18.2d
    add     v17.2d, v17.2d, v19.2d
    addp    d16, v16.2d
    addp    d17, v17.2d
    fmov    x8, d16                         // unsigned sum of low halves
    fmov    x9, d17                         // signed sum of high halves
    adds    x4, x4, x8
    adc     x5, x5, xzr
    lsl     x10, x9, #32                    // + hi * 2^32 (128-bit)
    asr     x11, x9, #32
    adds    x4, x4, x10
    adc     x5, x5, x11
    cbnz    x6, .Lns_block
.Lns_tail:
    ands    x6, x2, #7
    b.eq    .Lns_fin
    mov     w8, #0xff
    cbz     x1, 1f
    ldrb    w8, [x1]
1:  ldr     x9, [x0], #8
    sbfx    x10, x8, #0, #1
    and     x9, x9, x10
    asr     x10, x9, #63
    adds    x4, x4, x9
    adc     x5, x5, x10
    lsr     w8, w8, #1
    subs    x6, x6, #1
    b.ne    1b
.Lns_fin:
    cmp     x5, x4, asr #63
    b.ne    .Lns_ovf
    str     x4, [x3]
    mov     w0, #0
    ret
.Lns_ovf:
    mov     w0, #1
    ret
ENDF pqk_a64_neon_sum_i64

/* ------------------------------------------------------------------------
 * double sum_f64(x0 data, x1 validity, x2 n)
 * v16-v19 lane accumulators, v26-v29 = .Lbits2d, v20 validity byte,
 * v21-v24 row masks, x6 groups, d1 = +0.0 for the tail, w8 tail validity.
 */
FUNC pqk_a64_neon_sum_f64
    movi    v16.2d, #0
    movi    v17.2d, #0
    movi    v18.2d, #0
    movi    v19.2d, #0
    lsr     x6, x2, #3
    cbz     x6, .Lnsf_red
    cbz     x1, .Lnsf_nv
    LOADADDR x7, .Lbits2d
    ld1     {v26.2d-v29.2d}, [x7]
.Lnsf_v:
    ld1r    {v20.16b}, [x1], #1
    ld1     {v0.2d-v3.2d}, [x0], #64
    cmtst   v21.2d, v20.2d, v26.2d
    cmtst   v22.2d, v20.2d, v27.2d
    cmtst   v23.2d, v20.2d, v28.2d
    cmtst   v24.2d, v20.2d, v29.2d
    and     v0.16b, v0.16b, v21.16b
    and     v1.16b, v1.16b, v22.16b
    and     v2.16b, v2.16b, v23.16b
    and     v3.16b, v3.16b, v24.16b
    fadd    v16.2d, v16.2d, v0.2d
    fadd    v17.2d, v17.2d, v1.2d
    fadd    v18.2d, v18.2d, v2.2d
    fadd    v19.2d, v19.2d, v3.2d
    subs    x6, x6, #1
    b.ne    .Lnsf_v
    b       .Lnsf_red
.Lnsf_nv:
    ld1     {v0.2d-v3.2d}, [x0], #64
    fadd    v16.2d, v16.2d, v0.2d
    fadd    v17.2d, v17.2d, v1.2d
    fadd    v18.2d, v18.2d, v2.2d
    fadd    v19.2d, v19.2d, v3.2d
    subs    x6, x6, #1
    b.ne    .Lnsf_nv
.Lnsf_red:
    fadd    v16.2d, v16.2d, v17.2d
    fadd    v18.2d, v18.2d, v19.2d
    fadd    v16.2d, v16.2d, v18.2d
    faddp   d0, v16.2d
    ands    x6, x2, #7
    b.eq    2f
    fmov    d1, xzr
    mov     w8, #0xff
    cbz     x1, 1f
    ldrb    w8, [x1]
1:  ldr     d2, [x0], #8
    tst     w8, #1
    fcsel   d2, d2, d1, ne
    fadd    d0, d0, d2
    lsr     w8, w8, #1
    subs    x6, x6, #1
    b.ne    1b
2:  ret
ENDF pqk_a64_neon_sum_f64

/* ------------------------------------------------------------------------
 * size_t minmax_i64(x0 data, x1 validity, x2 n, x3 out_min, x4 out_max)
 * v16/v18 min accumulators, v17/v19 max accumulators, v30 valid count,
 * v26-v29 .Lbits2d, x10 original validity, x11 count, x13 MAX, x14 MIN.
 */
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
    mov     x10, x1
    mov     x13, #0x7fffffffffffffff
    mov     x14, #0x8000000000000000
    dup     v16.2d, x13
    dup     v18.2d, x13
    dup     v17.2d, x14
    dup     v19.2d, x14
    movi    v30.2d, #0
    lsr     x7, x2, #3
    cbz     x7, .Lnmm_red
    cbz     x1, .Lnmm_nv
    LOADADDR x8, .Lbits2d
    ld1     {v26.2d-v29.2d}, [x8]
.Lnmm_v:
    ld1r    {v20.16b}, [x1], #1
    ld1     {v0.2d-v3.2d}, [x0], #64
    cmtst   v21.2d, v20.2d, v26.2d
    cmtst   v22.2d, v20.2d, v27.2d
    cmtst   v23.2d, v20.2d, v28.2d
    cmtst   v24.2d, v20.2d, v29.2d
    sub     v30.2d, v30.2d, v21.2d
    sub     v30.2d, v30.2d, v22.2d
    sub     v30.2d, v30.2d, v23.2d
    sub     v30.2d, v30.2d, v24.2d
    MMSTEP  v0, v21, v16, v17
    MMSTEP  v1, v22, v18, v19
    MMSTEP  v2, v23, v16, v17
    MMSTEP  v3, v24, v18, v19
    subs    x7, x7, #1
    b.ne    .Lnmm_v
    b       .Lnmm_red
.Lnmm_nv:
    ld1     {v0.2d-v3.2d}, [x0], #64
    MMSTEP  v0, none, v16, v17
    MMSTEP  v1, none, v18, v19
    MMSTEP  v2, none, v16, v17
    MMSTEP  v3, none, v18, v19
    subs    x7, x7, #1
    b.ne    .Lnmm_nv
.Lnmm_red:
    cmgt    v4.2d, v16.2d, v18.2d           // merge the two accumulator pairs
    bit     v16.16b, v18.16b, v4.16b
    cmgt    v5.2d, v19.2d, v17.2d
    bit     v17.16b, v19.16b, v5.16b
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
    ands    x7, x2, #7
    b.eq    .Lnmm_fin
    mov     w12, #0xff
    cbz     x10, 1f
    ldrb    w12, [x1]
1:  ldr     x8, [x0], #8
    tst     w12, #1
    csel    x9, x8, x13, ne
    csel    x8, x8, x14, ne
    cinc    x11, x11, ne
    cmp     x9, x5
    csel    x5, x9, x5, lt
    cmp     x8, x6
    csel    x6, x8, x6, gt
    lsr     w12, w12, #1
    subs    x7, x7, #1
    b.ne    1b
.Lnmm_fin:
    cbnz    x10, 2f
    mov     x11, x2                         // no validity: every row counts
2:  cbz     x11, 3f
    str     x5, [x3]
    str     x6, [x4]
3:  mov     x0, x11
    ret
ENDF pqk_a64_neon_minmax_i64

/* ------------------------------------------------------------------------
 * size_t minmax_f64(x0 data, x1 validity, x2 n, x3 out_min, x4 out_max)
 * v16/v18 min (init +inf), v17/v19 max (init -inf), v30 valid count,
 * x10 original validity, x15 original data, x11 count, d0/d1 results,
 * x16/d2 +inf, x17/d3 -inf.
 */
FUNC pqk_a64_neon_minmax_f64
    mov     x10, x1
    mov     x15, x0
    mov     x16, #0x7ff0000000000000
    dup     v16.2d, x16
    dup     v18.2d, x16
    mov     x17, #0xfff0000000000000
    dup     v17.2d, x17
    dup     v19.2d, x17
    movi    v30.2d, #0
    lsr     x7, x2, #3
    cbz     x7, .Lnmf_red
    cbz     x1, .Lnmf_nv
    LOADADDR x8, .Lbits2d
    ld1     {v26.2d-v29.2d}, [x8]
.Lnmf_v:
    ld1r    {v20.16b}, [x1], #1
    ld1     {v0.2d-v3.2d}, [x0], #64
    cmtst   v21.2d, v20.2d, v26.2d
    cmtst   v22.2d, v20.2d, v27.2d
    cmtst   v23.2d, v20.2d, v28.2d
    cmtst   v24.2d, v20.2d, v29.2d
    sub     v30.2d, v30.2d, v21.2d
    sub     v30.2d, v30.2d, v22.2d
    sub     v30.2d, v30.2d, v23.2d
    sub     v30.2d, v30.2d, v24.2d
    orn     v0.16b, v0.16b, v21.16b         // invalid -> all-ones (qNaN)
    orn     v1.16b, v1.16b, v22.16b
    orn     v2.16b, v2.16b, v23.16b
    orn     v3.16b, v3.16b, v24.16b
    fminnm  v16.2d, v16.2d, v0.2d
    fmaxnm  v17.2d, v17.2d, v0.2d
    fminnm  v18.2d, v18.2d, v1.2d
    fmaxnm  v19.2d, v19.2d, v1.2d
    fminnm  v16.2d, v16.2d, v2.2d
    fmaxnm  v17.2d, v17.2d, v2.2d
    fminnm  v18.2d, v18.2d, v3.2d
    fmaxnm  v19.2d, v19.2d, v3.2d
    subs    x7, x7, #1
    b.ne    .Lnmf_v
    b       .Lnmf_red
.Lnmf_nv:
    ld1     {v0.2d-v3.2d}, [x0], #64
    fminnm  v16.2d, v16.2d, v0.2d
    fmaxnm  v17.2d, v17.2d, v0.2d
    fminnm  v18.2d, v18.2d, v1.2d
    fmaxnm  v19.2d, v19.2d, v1.2d
    fminnm  v16.2d, v16.2d, v2.2d
    fmaxnm  v17.2d, v17.2d, v2.2d
    fminnm  v18.2d, v18.2d, v3.2d
    fmaxnm  v19.2d, v19.2d, v3.2d
    subs    x7, x7, #1
    b.ne    .Lnmf_nv
.Lnmf_red:
    fminnm  v16.2d, v16.2d, v18.2d
    fmaxnm  v17.2d, v17.2d, v19.2d
    fminnmp d0, v16.2d
    fmaxnmp d1, v17.2d
    addp    d30, v30.2d
    fmov    x11, d30
    fmov    d2, x16
    fmov    d3, x17
    ands    x7, x2, #7
    b.eq    .Lnmf_fin
    mov     w12, #0xff
    cbz     x10, 1f
    ldrb    w12, [x1]
1:  ldr     d4, [x0], #8
    tst     w12, #1
    fcsel   d5, d4, d3, ne
    fcsel   d4, d4, d2, ne
    cinc    x11, x11, ne
    fcmp    d4, d0
    fcsel   d0, d4, d0, mi
    fcmp    d5, d1
    fcsel   d1, d5, d1, gt
    lsr     w12, w12, #1
    subs    x7, x7, #1
    b.ne    1b
.Lnmf_fin:
    cbnz    x10, 2f
    mov     x11, x2
2:  cbz     x11, .Lnmf_ret
    fcmp    d0, #0.0
    b.eq    .Lnmf_zero
    fcmp    d1, #0.0
    b.ne    .Lnmf_store
.Lnmf_zero:                                 // reference returns the first valid zero
    mov     x9, #0
3:  cmp     x9, x2
    b.hs    .Lnmf_store
    ldr     x8, [x15, x9, lsl #3]
    lsl     x12, x8, #1                     // zero iff +0.0 or -0.0
    cbnz    x12, 4f
    cbz     x10, 5f
    VBIT    12, 10, 9, 13
    tbnz    w12, #0, 5f
4:  add     x9, x9, #1
    b       3b
5:  fmov    d4, x8
    fcmp    d0, #0.0
    fcsel   d0, d4, d0, eq
    fcmp    d1, #0.0
    fcsel   d1, d4, d1, eq
.Lnmf_store:
    str     d0, [x3]
    str     d1, [x4]
.Lnmf_ret:
    mov     x0, x11
    ret
ENDF pqk_a64_neon_minmax_f64

/* ------------------------------------------------------------------------
 * size_t count_i64(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b)
 * x7 lo, x8 span, x9 inv (0/-1), x6 groups, x11 original validity,
 * x12 count, v16 lo, v17 span, v18 inv, v19 validity byte, v20/v21 counts,
 * v4-v7 row masks, v26-v29 .Lbits2d.
 */
FUNC pqk_a64_neon_count_i64
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lnc_inval
    mov     x11, x1
    mov     x12, #0
    lsr     x6, x2, #3
    cbz     x6, .Lnc_tail
    dup     v16.2d, x7
    dup     v17.2d, x8
    dup     v18.2d, x9
    movi    v20.2d, #0
    movi    v21.2d, #0
    cbz     x1, .Lnc_nv
    LOADADDR x10, .Lbits2d
    ld1     {v26.2d-v29.2d}, [x10]
.Lnc_v:
    ld1r    {v19.16b}, [x1], #1
    ld1     {v0.2d-v3.2d}, [x0], #64
    cmtst   v4.2d, v19.2d, v26.2d
    cmtst   v5.2d, v19.2d, v27.2d
    cmtst   v6.2d, v19.2d, v28.2d
    cmtst   v7.2d, v19.2d, v29.2d
    sub     v0.2d, v0.2d, v16.2d
    sub     v1.2d, v1.2d, v16.2d
    sub     v2.2d, v2.2d, v16.2d
    sub     v3.2d, v3.2d, v16.2d
    cmhs    v0.2d, v17.2d, v0.2d
    cmhs    v1.2d, v17.2d, v1.2d
    cmhs    v2.2d, v17.2d, v2.2d
    cmhs    v3.2d, v17.2d, v3.2d
    eor     v0.16b, v0.16b, v18.16b
    eor     v1.16b, v1.16b, v18.16b
    eor     v2.16b, v2.16b, v18.16b
    eor     v3.16b, v3.16b, v18.16b
    and     v0.16b, v0.16b, v4.16b
    and     v1.16b, v1.16b, v5.16b
    and     v2.16b, v2.16b, v6.16b
    and     v3.16b, v3.16b, v7.16b
    sub     v20.2d, v20.2d, v0.2d
    sub     v21.2d, v21.2d, v1.2d
    sub     v20.2d, v20.2d, v2.2d
    sub     v21.2d, v21.2d, v3.2d
    subs    x6, x6, #1
    b.ne    .Lnc_v
    add     v20.2d, v20.2d, v21.2d
    addp    d20, v20.2d
    fmov    x12, d20
    b       .Lnc_tail
.Lnc_nv:
    ld1     {v0.2d-v3.2d}, [x0], #64
    sub     v0.2d, v0.2d, v16.2d
    sub     v1.2d, v1.2d, v16.2d
    sub     v2.2d, v2.2d, v16.2d
    sub     v3.2d, v3.2d, v16.2d
    cmhs    v0.2d, v17.2d, v0.2d
    cmhs    v1.2d, v17.2d, v1.2d
    cmhs    v2.2d, v17.2d, v2.2d
    cmhs    v3.2d, v17.2d, v3.2d
    sub     v20.2d, v20.2d, v0.2d
    sub     v21.2d, v21.2d, v1.2d
    sub     v20.2d, v20.2d, v2.2d
    sub     v21.2d, v21.2d, v3.2d
    subs    x6, x6, #1
    b.ne    .Lnc_nv
    add     v20.2d, v20.2d, v21.2d
    addp    d20, v20.2d
    fmov    x12, d20
    cbz     x9, .Lnc_tail
    and     x13, x2, #~7                    // inverted: rows - in-range rows
    sub     x12, x13, x12
.Lnc_tail:
    ands    x6, x2, #7
    b.eq    .Lnc_done
    mov     w14, #0xff
    cbz     x11, 1f
    ldrb    w14, [x1]
1:  ldr     x15, [x0], #8
    SPRED   15, 7, 8, 9
    and     w15, w15, w14
    and     w15, w15, #1
    add     x12, x12, x15
    lsr     w14, w14, #1
    subs    x6, x6, #1
    b.ne    1b
.Lnc_done:
    mov     x0, x12
    ret
.Lnc_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_neon_count_i64

/* ------------------------------------------------------------------------
 * void bitmap_{and,or,andnot}(x0 a, x1 b, x2 out, x3 nbytes)
 * 64-byte blocks (v0-v3 op v4-v7), 16-byte steps, one 8-byte GPR step, bytes.
 * Every chunk is loaded from both inputs before it is stored, so out == a or
 * out == b is safe (no overlapping re-processing of already written bytes).
 */
    .macro  NBITOP name, insn
FUNC pqk_a64_neon_bitmap_\name
    cmp     x3, #64
    b.lo    2f
1:  ld1     {v0.16b-v3.16b}, [x0], #64
    ld1     {v4.16b-v7.16b}, [x1], #64
    \insn   v0.16b, v0.16b, v4.16b
    \insn   v1.16b, v1.16b, v5.16b
    \insn   v2.16b, v2.16b, v6.16b
    \insn   v3.16b, v3.16b, v7.16b
    st1     {v0.16b-v3.16b}, [x2], #64
    sub     x3, x3, #64
    cmp     x3, #64
    b.hs    1b
2:  cmp     x3, #16
    b.lo    3f
    ldr     q0, [x0], #16
    ldr     q4, [x1], #16
    \insn   v0.16b, v0.16b, v4.16b
    str     q0, [x2], #16
    sub     x3, x3, #16
    b       2b
3:  cmp     x3, #8
    b.lo    4f
    ldr     x4, [x0], #8
    ldr     x5, [x1], #8
    \insn   x4, x4, x5
    str     x4, [x2], #8
    sub     x3, x3, #8
4:  cbz     x3, 5f
    ldrb    w4, [x0], #1
    ldrb    w5, [x1], #1
    \insn   w4, w4, w5
    strb    w4, [x2], #1
    sub     x3, x3, #1
    b       4b
5:  ret
ENDF pqk_a64_neon_bitmap_\name
    .endm

    NBITOP  and, and
    NBITOP  or, orr
    NBITOP  andnot, bic

/* ------------------------------------------------------------------------
 * size_t bitmap_popcount(x0 bits, x1 nbits)
 * .Lnp_bytes is also the tail-call target of filter_i64_bitmap and
 * compare_i64: in x0 = pointer, x1 = full bytes, x6 = extra bits (0..7) of
 * one more partial byte; out x0 = popcount. Clobbers x1-x7, v0-v3, v16.
 * x7 total, x2 iterations in block, v16 4x32-bit accumulator.
 */
FUNC pqk_a64_neon_bitmap_popcount
    and     x6, x1, #7
    lsr     x1, x1, #3
.Lnp_bytes:
    mov     x7, #0
    cmp     x1, #64
    b.lo    3f
1:  lsr     x2, x1, #6
    mov     x3, #(1 << 20)
    cmp     x2, x3
    csel    x2, x2, x3, lo
    sub     x1, x1, x2, lsl #6
    movi    v16.2d, #0
2:  ld1     {v0.16b-v3.16b}, [x0], #64
    cnt     v0.16b, v0.16b
    cnt     v1.16b, v1.16b
    cnt     v2.16b, v2.16b
    cnt     v3.16b, v3.16b
    add     v0.16b, v0.16b, v1.16b
    add     v2.16b, v2.16b, v3.16b
    add     v0.16b, v0.16b, v2.16b          // <= 32 per byte
    uaddlp  v0.8h, v0.16b                   // <= 64 per halfword
    uadalp  v16.4s, v0.8h                   // <= 128 per word per iteration
    subs    x2, x2, #1
    b.ne    2b
    uaddlv  d16, v16.4s
    fmov    x3, d16
    add     x7, x7, x3
    cmp     x1, #64
    b.hs    1b
3:  cmp     x1, #16
    b.lo    4f
    ldr     q0, [x0], #16
    cnt     v0.16b, v0.16b
    uaddlv  h0, v0.16b
    umov    w3, v0.h[0]
    add     x7, x7, x3
    sub     x1, x1, #16
    b       3b
4:  cbz     x1, 5f
    ldrb    w3, [x0], #1
    fmov    s0, w3
    cnt     v0.8b, v0.8b
    umov    w3, v0.b[0]
    add     x7, x7, x3
    sub     x1, x1, #1
    b       4b
5:  cbz     x6, 6f
    ldrb    w3, [x0]
    mov     w4, #1
    lsl     w4, w4, w6
    sub     w4, w4, #1
    and     w3, w3, w4
    fmov    s0, w3
    cnt     v0.8b, v0.8b
    umov    w3, v0.b[0]
    add     x7, x7, x3
6:  mov     x0, x7
    ret
ENDF pqk_a64_neon_bitmap_popcount

/* ------------------------------------------------------------------------
 * void hash_i64(x0 data, x1 n, x2 seed, x3 out)
 * 4-way interleaved GPR fmix64 (see header: no 64-bit NEON multiply).
 * x4/x5 multipliers, x6-x9 four lanes.
 */
FUNC pqk_a64_neon_hash_i64
    LOAD_FMIX 4, 5
    cmp     x1, #4
    b.lo    2f
1:  ldp     x6, x7, [x0], #16
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
    b.hs    1b
2:  cbz     x1, 3f
    ldr     x6, [x0], #8
    FMIX1   6, 2, 4, 5
    str     x6, [x3], #8
    sub     x1, x1, #1
    b       2b
3:  ret
ENDF pqk_a64_neon_hash_i64

/* ------------------------------------------------------------------------
 * size_t compare_i64(x0 a, x1 b, x2 n, w3 op, x4 out_bits)
 * w5 type (0 = EQ-based, 1 = GT-based), w9 inversion mask (0/0xffff),
 * x10 row, x11 output cursor, x15 main-loop limit, w16 mask, v18 bit weights,
 * v0-v7 lanes of a, v20-v27 lanes of b. Tail: w12 bits, x13 row.
 */
    .macro  CMP16 insn, wout
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
    PACK16  \wout
    .endm

FUNC pqk_a64_neon_compare_i64
    cmp     w3, #5
    b.hi    .Lnci_inval
    and     w9, w3, #1                      // NE, LE, GE are inverted ops
    neg     w9, w9
    and     w9, w9, #0xffff
    cmp     w3, #2
    b.eq    1f
    cmp     w3, #5
    b.ne    2f
1:  mov     x5, x0                          // LT / GE: swap -> GT / LE
    mov     x0, x1
    mov     x1, x5
2:  cmp     w3, #2
    cset    w5, hs
    mov     x10, #0
    mov     x11, x4
    and     x15, x2, #~15
    cbz     x15, .Lnci_tail
    LOADADDR x12, .Lbitsel16
    ld1     {v18.16b}, [x12]
    cbnz    w5, .Lnci_gt
.Lnci_eq:
    CMP16   cmeq, w16
    eor     w16, w16, w9
    strh    w16, [x11], #2
    add     x10, x10, #16
    cmp     x10, x15
    b.lo    .Lnci_eq
    b       .Lnci_tail
.Lnci_gt:
    CMP16   cmgt, w16
    eor     w16, w16, w9
    strh    w16, [x11], #2
    add     x10, x10, #16
    cmp     x10, x15
    b.lo    .Lnci_gt
.Lnci_tail:
    cmp     x10, x2
    b.hs    .Lnci_count
    mov     w12, #0
    mov     x13, x10
3:  ldr     x14, [x0], #8
    ldr     x15, [x1], #8
    cmp     x14, x15
    cset    w14, eq
    cset    w16, gt
    cmp     w5, #0
    csel    w14, w14, w16, eq
    eor     w14, w14, w9
    and     w14, w14, #1
    sub     x15, x13, x10
    lsl     w14, w14, w15
    orr     w12, w12, w14
    add     x13, x13, #1
    cmp     x13, x2
    b.lo    3b
    strb    w12, [x11]
    sub     x15, x2, x10
    cmp     x15, #8
    b.ls    .Lnci_count
    lsr     w12, w12, #8
    strb    w12, [x11, #1]
.Lnci_count:
    mov     x0, x4
    add     x1, x2, #7
    lsr     x1, x1, #3
    mov     x6, #0
    b       .Lnp_bytes
.Lnci_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_neon_compare_i64

/* ------------------------------------------------------------------------
 * void compare_fixed(x0 a, x1 b, x2 width, x3 n, x4 out)
 * x5 bytes left in record, x6 nibble mask / index, x7 temp,
 * w8/w9 (or x8/x9) differing operands, w10 result.
 */
FUNC pqk_a64_neon_compare_fixed
    cbz     x3, .Lncf_ret
.Lncf_rec:
    mov     x5, x2
1:  cmp     x5, #16
    b.lo    3f
    ldr     q0, [x0], #16
    ldr     q1, [x1], #16
    sub     x5, x5, #16
    cmeq    v0.16b, v0.16b, v1.16b
    shrn    v0.8b, v0.8h, #4                // 4 bits per byte: 1111 = equal
    fmov    x6, d0
    cmn     x6, #1
    b.eq    1b
    mvn     x6, x6
    rbit    x6, x6
    clz     x6, x6
    lsr     x6, x6, #2                      // index of first differing byte
    sub     x7, x0, #16
    ldrb    w8, [x7, x6]
    sub     x7, x1, #16
    ldrb    w9, [x7, x6]
    cmp     w8, w9
    b       .Lncf_diff
3:  cmp     x5, #8
    b.lo    4f
    ldr     x8, [x0], #8
    ldr     x9, [x1], #8
    sub     x5, x5, #8
    cmp     x8, x9
    b.eq    4f
    rev     x8, x8
    rev     x9, x9
    cmp     x8, x9
    b       .Lncf_diff
4:  cbz     x5, .Lncf_eq
    ldrb    w8, [x0], #1
    ldrb    w9, [x1], #1
    sub     x5, x5, #1
    cmp     w8, w9
    b.eq    4b
.Lncf_diff:
    mov     w10, #1
    cneg    w10, w10, lo
    strb    w10, [x4], #1
    add     x0, x0, x5
    add     x1, x1, x5
    b       .Lncf_next
.Lncf_eq:
    strb    wzr, [x4], #1
.Lncf_next:
    subs    x3, x3, #1
    b.ne    .Lncf_rec
.Lncf_ret:
    ret
ENDF pqk_a64_neon_compare_fixed

/* ------------------------------------------------------------------------
 * int group_sum_i64(x0 group_ids, x1 values, x2 validity, x3 n, x4 sums,
 *                   x5 counts, x6 ngroups)
 * Pass 1 (vector): w11 = max id over valid rows (invalid ids masked to 0)
 *   x8 id cursor, x9 validity cursor, x10 groups/rows, v16/v17 UMAX
 *   accumulators, v26/v27 .Lbits4s, v20-v22 validity masks.
 *   ngroups == 0 and ngroups >= 2^32 are handled separately.
 * Pass 2 (scalar): row-order accumulation, w9 overflow flag, x10 row,
 *   x11 id, x12/x13 temps.
 */
FUNC pqk_a64_neon_group_sum_i64
    cbz     x3, .Lng_ok
    lsr     x7, x6, #32
    cbnz    x7, .Lng_p2                     // every uint32 id is in range
    cbz     x6, .Lng_any
    mov     x8, x0
    mov     x9, x2
    movi    v16.4s, #0
    movi    v17.4s, #0
    lsr     x10, x3, #3
    cbz     x10, .Lng_p1tail
    cbz     x2, .Lng_p1nv
    LOADADDR x7, .Lbits4s
    ld1     {v26.4s, v27.4s}, [x7]
.Lng_p1v:
    ld1r    {v20.16b}, [x9], #1
    ld1     {v0.4s, v1.4s}, [x8], #32
    cmtst   v21.4s, v20.4s, v26.4s
    cmtst   v22.4s, v20.4s, v27.4s
    and     v0.16b, v0.16b, v21.16b
    and     v1.16b, v1.16b, v22.16b
    umax    v16.4s, v16.4s, v0.4s
    umax    v17.4s, v17.4s, v1.4s
    subs    x10, x10, #1
    b.ne    .Lng_p1v
    b       .Lng_p1tail
.Lng_p1nv:
    ld1     {v0.4s, v1.4s}, [x8], #32
    umax    v16.4s, v16.4s, v0.4s
    umax    v17.4s, v17.4s, v1.4s
    subs    x10, x10, #1
    b.ne    .Lng_p1nv
.Lng_p1tail:
    umax    v16.4s, v16.4s, v17.4s
    umaxv   s16, v16.4s
    fmov    w11, s16
    ands    x10, x3, #7
    b.eq    .Lng_p1chk
    mov     w12, #0xff
    cbz     x2, 1f
    ldrb    w12, [x9]
1:  ldr     w13, [x8], #4
    tst     w12, #1
    csel    w13, w13, wzr, ne
    cmp     w13, w11
    csel    w11, w13, w11, hi
    lsr     w12, w12, #1
    subs    x10, x10, #1
    b.ne    1b
.Lng_p1chk:
    cmp     x11, x6
    b.hs    .Lng_inval
    b       .Lng_p2
.Lng_any:                                   // ngroups == 0: EINVAL iff a valid row exists
    cbz     x2, .Lng_inval
    lsr     x10, x3, #3
    mov     x9, x2
1:  cbz     x10, 2f
    ldrb    w12, [x9], #1
    cbnz    w12, .Lng_inval
    sub     x10, x10, #1
    b       1b
2:  ands    x10, x3, #7
    b.eq    .Lng_ok
    ldrb    w12, [x9]
    mov     w13, #1
    lsl     w13, w13, w10
    sub     w13, w13, #1
    tst     w12, w13
    b.ne    .Lng_inval
    b       .Lng_ok
.Lng_p2:
    mov     w9, #0
    cbnz    x2, .Lng_p2v
1:  ldr     w11, [x0], #4                   // no validity
    ldr     x12, [x1], #8
    ldr     x13, [x4, x11, lsl #3]
    adds    x13, x13, x12
    csinc   w9, w9, wzr, vc
    str     x13, [x4, x11, lsl #3]
    cbz     x5, 2f
    ldr     x13, [x5, x11, lsl #3]
    add     x13, x13, #1
    str     x13, [x5, x11, lsl #3]
2:  subs    x3, x3, #1
    b.ne    1b
    mov     w0, w9
    ret
.Lng_p2v:
    mov     x10, #0
3:  VBIT    12, 2, 10, 13
    tbz     w12, #0, 4f
    ldr     w11, [x0, x10, lsl #2]
    ldr     x12, [x1, x10, lsl #3]
    ldr     x13, [x4, x11, lsl #3]
    adds    x13, x13, x12
    csinc   w9, w9, wzr, vc
    str     x13, [x4, x11, lsl #3]
    cbz     x5, 4f
    ldr     x13, [x5, x11, lsl #3]
    add     x13, x13, #1
    str     x13, [x5, x11, lsl #3]
4:  add     x10, x10, #1
    cmp     x10, x3
    b.lo    3b
    mov     w0, w9
    ret
.Lng_ok:
    mov     w0, #0
    ret
.Lng_inval:
    mov     w0, #2
    ret
ENDF pqk_a64_neon_group_sum_i64

/* ------------------------------------------------------------------------
 * void gather_i64(x0 data, x1 idx, x2 m, x3 out)
 * 4-way unrolled; w4-w7 indices (zero-extended), x4-x7 values.
 */
FUNC pqk_a64_neon_gather_i64
    cmp     x2, #4
    b.lo    2f
1:  ldp     w4, w5, [x1], #8
    ldp     w6, w7, [x1], #8
    ldr     x4, [x0, x4, lsl #3]
    ldr     x5, [x0, x5, lsl #3]
    ldr     x6, [x0, x6, lsl #3]
    ldr     x7, [x0, x7, lsl #3]
    stp     x4, x5, [x3], #16
    stp     x6, x7, [x3], #16
    sub     x2, x2, #4
    cmp     x2, #4
    b.hs    1b
2:  cbz     x2, 3f
    ldr     w4, [x1], #4
    ldr     x4, [x0, x4, lsl #3]
    str     x4, [x3], #8
    sub     x2, x2, #1
    b       2b
3:  ret
ENDF pqk_a64_neon_gather_i64

/* ========================================================================
 * 128-bit kernels (CR-4, kernels 17-20).
 *
 * Data layout: LD2 {.2d} of 32 bytes de-interleaves two pqk_i128 rows into
 * a lo-word vector and a hi-word vector (lane j = row j), so every 128-bit
 * operation becomes a short sequence of 64-bit lane operations:
 *   unsigned 128-bit a <= b : (a_hi <u b_hi) | (a_hi == b_hi & a_lo <=u b_lo)
 *   signed   128-bit a <  b : (a_hi <s b_hi) | (a_hi == b_hi & a_lo <u b_lo)
 * evaluated as CMHI/CMGT + CMEQ + CMHS/CMHI and one BIT/BIF select; the
 * 128-bit subtraction x - lo propagates the borrow with CMHI (all-ones
 * mask = -1) added to the high word.
 * Main loops process 8 rows (128 bytes, 4 x LD2; one validity byte); the
 * remaining 0-7 rows go through the scalar GPR code of the macro header.
 * ======================================================================== */

/* RNG2 l, h, t: v<l>/v<h> hold the lo/hi words of 2 rows. Leaves the 2x64
 * lane mask of ((x - lo) <=u span) (128-bit) in v<l>; clobbers v<h>, v<t>.
 * Needs v16/v17 = lo (lo word / hi word), v18/v19 = span. 8 ops. */
    .macro  RNG2 l, h, t
    cmhi    v\t\().2d, v16.2d, v\l\().2d    // borrow: lo_lo >u x_lo (-1)
    sub     v\l\().2d, v\l\().2d, v16.2d    // d_lo
    sub     v\h\().2d, v\h\().2d, v17.2d
    add     v\h\().2d, v\h\().2d, v\t\().2d // d_hi (borrow applied)
    cmhs    v\l\().2d, v18.2d, v\l\().2d    // d_lo <=u span_lo
    cmhi    v\t\().2d, v19.2d, v\h\().2d    // d_hi <u span_hi
    cmeq    v\h\().2d, v19.2d, v\h\().2d    // d_hi == span_hi
    bif     v\l\().16b, v\t\().16b, v\h\().16b  // eq ? lo test : hi test
    .endm

/* RNG8 xp: loads 8 rows from [xp] (post-increment by 128) and leaves the
 * un-inverted range masks of rows (0,1),(2,3),(4,5),(6,7) in v0,v2,v4,v6.
 * Clobbers v1,v3,v5,v7, v22-v25. */
    .macro  RNG8 xp
    ld2     {v0.2d, v1.2d}, [\xp], #32
    ld2     {v2.2d, v3.2d}, [\xp], #32
    ld2     {v4.2d, v5.2d}, [\xp], #32
    ld2     {v6.2d, v7.2d}, [\xp], #32
    RNG2    0, 1, 22
    RNG2    2, 3, 23
    RNG2    4, 5, 24
    RNG2    6, 7, 25
    .endm

/* PACK8 wout: narrows the lane masks v0,v2,v4,v6 (rows 0..7) to an 8-bit row
 * mask (bit j = row j). Needs v28 = .Lbitsel16 (low 8 bytes). */
    .macro  PACK8 wout
    uzp1    v0.4s, v0.4s, v2.4s
    uzp1    v4.4s, v4.4s, v6.4s
    uzp1    v0.8h, v0.8h, v4.8h
    xtn     v0.8b, v0.8h
    and     v0.8b, v0.8b, v28.8b
    addv    b0, v0.8b
    umov    \wout, v0.b[0]
    .endm

/* ------------------------------------------------------------------------
 * size_t filter_i128(x0 data, x1 validity, x2 n, w3 op, x4 &a, x5 &b,
 *                    x6 out_idx)
 * Registers: x8:x7 lo, x10:x9 span (scalar copies for the tail), w5 mask
 * inversion (0/0xff), w4 row inversion (0/1), x3 validity base, x14 row i,
 * x11 output cursor, x12 .Lselpos, x13 .Lselcnt, x15 main-loop row limit,
 * w16 row mask, w17 validity byte; v16:v17 lo, v18:v19 span, v20 row base
 * (u32 x4), v21 = 8 (u32 x4), v28 bit weights, v0-v7/v22-v25 work.
 * Algorithm: PRED128_SETUP (op validated before *a / *b are read) gives the
 * canonical 128-bit range predicate. 8 rows per iteration: RNG8 (LD2 + 8
 * lane ops per 2 rows), PACK8 to an 8-bit mask, EOR inversion, AND the
 * validity byte, then EMIT8: table-driven compaction storing 8 indices
 * branch-free (cursor k <= i and i + 8 <= n, so the 32-byte over-store stays
 * inside the documented capacity >= n). Tail: scalar SPRED128 per row.
 */
FUNC pqk_a64_neon_filter_i128
    PRED128_SETUP w3, x4, x5, x7, x8, x9, x10, x11, x12, x13, .Lnf8_inval
    and     w5, w11, #0xff
    and     w4, w11, #1
    mov     x3, x1
    mov     x14, #0
    mov     x11, x6
    and     x15, x2, #~7
    cbz     x15, .Lnf8_tail
    dup     v16.2d, x7
    dup     v17.2d, x8
    dup     v18.2d, x9
    dup     v19.2d, x10
    LOADADDR x12, .Lbitsel16
    ldr     d28, [x12]
    LOADADDR x12, .Lselpos
    LOADADDR x13, .Lselcnt
    movi    v20.4s, #0
    movi    v21.4s, #8
.Lnf8_main:
    RNG8    x0
    PACK8   w16
    eor     w16, w16, w5
    cbz     x1, 1f
    ldrb    w17, [x1], #1                   // validity of rows i..i+7
    and     w16, w16, w17
1:  EMIT8   16
    add     x14, x14, #8
    cmp     x14, x15
    b.lo    .Lnf8_main
.Lnf8_tail:
    cmp     x14, x2
    b.hs    .Lnf8_done
1:  ldp     x16, x17, [x0], #16
    SPRED128 16, 17, 7, 8, 9, 10, 4
    cbz     x3, 2f
    VBIT    12, 3, 14, 13
    and     w16, w16, w12
2:  str     w14, [x11]
    add     x11, x11, x16, lsl #2
    add     x14, x14, #1
    cmp     x14, x2
    b.lo    1b
.Lnf8_done:
    sub     x0, x11, x6
    lsr     x0, x0, #2
    ret
.Lnf8_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_neon_filter_i128

/* ------------------------------------------------------------------------
 * size_t count_i128(x0 data, x1 validity, x2 n, w3 op, x4 &a, x5 &b)
 * Registers: x8:x7 lo, x10:x9 span, x11 inv (0/-1), w4 row inversion (0/1),
 * x3 validity base, x6 count, x14 row i, x15 main-loop row limit,
 * x16/x17/x12/x13 tail temps; v16-v19 predicate constants, v26/v27 lane
 * counters, v20 lane inversion, v21 replicated validity byte, v28-v31
 * .Lbits2d (CMTST constants), v22-v25 validity lane masks.
 * Algorithm: 8 rows per iteration through RNG8; selected lanes (all-ones)
 * are accumulated with SUB into two 2x64 counters. Without validity the
 * inversion is applied algebraically once (count = rows - count); with
 * validity each lane mask is EORed with the inversion and ANDed with the
 * CMTST-expanded validity byte. Tail: scalar SPRED128.
 */
FUNC pqk_a64_neon_count_i128
    PRED128_SETUP w3, x4, x5, x7, x8, x9, x10, x11, x12, x13, .Lnc8_inval
    and     w4, w11, #1
    mov     x3, x1
    mov     x14, #0
    mov     x6, #0
    and     x15, x2, #~7
    cbz     x15, .Lnc8_tail
    dup     v16.2d, x7
    dup     v17.2d, x8
    dup     v18.2d, x9
    dup     v19.2d, x10
    movi    v26.2d, #0
    movi    v27.2d, #0
    cbz     x1, .Lnc8_nv
    dup     v20.2d, x11
    LOADADDR x12, .Lbits2d
    ld1     {v28.2d-v31.2d}, [x12]
.Lnc8_v:
    RNG8    x0
    ld1r    {v21.16b}, [x1], #1
    cmtst   v22.2d, v21.2d, v28.2d
    cmtst   v23.2d, v21.2d, v29.2d
    cmtst   v24.2d, v21.2d, v30.2d
    cmtst   v25.2d, v21.2d, v31.2d
    eor     v0.16b, v0.16b, v20.16b
    eor     v2.16b, v2.16b, v20.16b
    eor     v4.16b, v4.16b, v20.16b
    eor     v6.16b, v6.16b, v20.16b
    and     v0.16b, v0.16b, v22.16b
    and     v2.16b, v2.16b, v23.16b
    and     v4.16b, v4.16b, v24.16b
    and     v6.16b, v6.16b, v25.16b
    sub     v26.2d, v26.2d, v0.2d
    sub     v27.2d, v27.2d, v2.2d
    sub     v26.2d, v26.2d, v4.2d
    sub     v27.2d, v27.2d, v6.2d
    add     x14, x14, #8
    cmp     x14, x15
    b.lo    .Lnc8_v
    add     v26.2d, v26.2d, v27.2d
    addp    d26, v26.2d
    fmov    x6, d26
    b       .Lnc8_tail
.Lnc8_nv:
    RNG8    x0
    sub     v26.2d, v26.2d, v0.2d
    sub     v27.2d, v27.2d, v2.2d
    sub     v26.2d, v26.2d, v4.2d
    sub     v27.2d, v27.2d, v6.2d
    add     x14, x14, #8
    cmp     x14, x15
    b.lo    .Lnc8_nv
    add     v26.2d, v26.2d, v27.2d
    addp    d26, v26.2d
    fmov    x6, d26
    cbz     x11, .Lnc8_tail
    sub     x6, x15, x6                     // inverted op: rows - in-range
.Lnc8_tail:
    cmp     x14, x2
    b.hs    .Lnc8_done
1:  ldp     x16, x17, [x0], #16
    SPRED128 16, 17, 7, 8, 9, 10, 4
    cbz     x3, 2f
    VBIT    12, 3, 14, 13
    and     w16, w16, w12
2:  add     x6, x6, x16
    add     x14, x14, #1
    cmp     x14, x2
    b.lo    1b
.Lnc8_done:
    mov     x0, x6
    ret
.Lnc8_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_neon_count_i128

/* ------------------------------------------------------------------------
 * int sum_i128(x0 data, x1 validity, x2 n, x3 out_sum)
 * Registers: x6:x5:x4 = exact 192-bit total (lo, mid, top), x7 row i,
 * x8 block end, x9 validity base, x15 main-loop row limit, x10-x14/x16
 * temps; v16-v19 / v20-v23 two sets of limb accumulators (limb 0..3) for
 * rows 0-3 / 4-7 of each iteration, v24/v25 validity lane masks, v26/v27
 * .Lbits4s (CMTST constants).
 * Algorithm (exact): LD4 {.4s} of 64 bytes splits 4 rows into their four
 * 32-bit limbs, one vector per limb (lane j = row j): limbs 0-2 unsigned,
 * limb 3 signed (it carries the sign of the int128). UADALP (limbs 0-2) and
 * SADALP (limb 3) add pairs of limbs into 64-bit lanes, i.e.
 *     sum = L0 + L1 * 2^32 + L2 * 2^64 + L3 * 2^96
 * with each Lk an exact lane sum. Invalid rows are zeroed beforehand (AND
 * with the CMTST-expanded validity byte). Blocks of at most 2^28 rows
 * (2^25 iterations) bound every lane below 2^58 (|.| < 2^57 for L3), so the
 * lanes cannot wrap even after adding the two sets and the two lanes
 * (< 2^60). Each block is folded into the 192-bit GPR total with
 * ADDS/ADCS/ADC (L1 and L3 split into their << 32 parts, L3 sign-extended).
 * The scalar tail adds rows sign-extended to 192 bits. Since |sum| < 2^160,
 * the 192-bit total is the exact mathematical sum, so cancelling
 * intermediate overflow is OK; the result fits in int128 iff
 * top == mid ASR 63, otherwise PQK_OVERFLOW (out_sum untouched).
 */
FUNC pqk_a64_neon_sum_i128
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    mov     x7, #0
    mov     x9, x1
    and     x15, x2, #~7
    cbz     x15, .Lns8_tail
    LOADADDR x10, .Lbits4s
    ld1     {v26.4s, v27.4s}, [x10]
.Lns8_block:
    mov     x8, #(1 << 28)
    add     x8, x8, x7
    cmp     x8, x15
    csel    x8, x8, x15, lo                 // multiple of 8, <= x15
    movi    v16.2d, #0
    movi    v17.2d, #0
    movi    v18.2d, #0
    movi    v19.2d, #0
    movi    v20.2d, #0
    movi    v21.2d, #0
    movi    v22.2d, #0
    movi    v23.2d, #0
    cbz     x1, .Lns8_nv
.Lns8_v:
    ld4     {v0.4s-v3.4s}, [x0], #64        // rows 0-3: limbs 0..3
    ld4     {v4.4s-v7.4s}, [x0], #64        // rows 4-7
    ld1r    {v24.16b}, [x1], #1
    cmtst   v25.4s, v24.4s, v26.4s          // rows 0-3 valid
    cmtst   v24.4s, v24.4s, v27.4s          // rows 4-7 valid
    and     v0.16b, v0.16b, v25.16b
    and     v1.16b, v1.16b, v25.16b
    and     v2.16b, v2.16b, v25.16b
    and     v3.16b, v3.16b, v25.16b
    and     v4.16b, v4.16b, v24.16b
    and     v5.16b, v5.16b, v24.16b
    and     v6.16b, v6.16b, v24.16b
    and     v7.16b, v7.16b, v24.16b
    uadalp  v16.2d, v0.4s
    uadalp  v17.2d, v1.4s
    uadalp  v18.2d, v2.4s
    sadalp  v19.2d, v3.4s
    uadalp  v20.2d, v4.4s
    uadalp  v21.2d, v5.4s
    uadalp  v22.2d, v6.4s
    sadalp  v23.2d, v7.4s
    add     x7, x7, #8
    cmp     x7, x8
    b.lo    .Lns8_v
    b       .Lns8_fold
.Lns8_nv:
    ld4     {v0.4s-v3.4s}, [x0], #64
    ld4     {v4.4s-v7.4s}, [x0], #64
    uadalp  v16.2d, v0.4s
    uadalp  v17.2d, v1.4s
    uadalp  v18.2d, v2.4s
    sadalp  v19.2d, v3.4s
    uadalp  v20.2d, v4.4s
    uadalp  v21.2d, v5.4s
    uadalp  v22.2d, v6.4s
    sadalp  v23.2d, v7.4s
    add     x7, x7, #8
    cmp     x7, x8
    b.lo    .Lns8_nv
.Lns8_fold:
    add     v16.2d, v16.2d, v20.2d
    add     v17.2d, v17.2d, v21.2d
    add     v18.2d, v18.2d, v22.2d
    add     v19.2d, v19.2d, v23.2d
    addp    d16, v16.2d
    addp    d17, v17.2d
    addp    d18, v18.2d
    addp    d19, v19.2d
    fmov    x10, d16                        // L0 (unsigned)
    fmov    x11, d17                        // L1 (unsigned)
    fmov    x12, d18                        // L2 (unsigned)
    fmov    x13, d19                        // L3 (signed)
    adds    x4, x4, x10                     // += L0
    adcs    x5, x5, xzr
    adc     x6, x6, xzr
    lsl     x14, x11, #32                   // += L1 << 32
    lsr     x16, x11, #32
    adds    x4, x4, x14
    adcs    x5, x5, x16
    adc     x6, x6, xzr
    adds    x5, x5, x12                     // += L2 << 64
    adc     x6, x6, xzr
    lsl     x14, x13, #32                   // += L3 << 96 (sign-extended)
    asr     x16, x13, #32
    adds    x5, x5, x14
    adc     x6, x6, x16
    cmp     x7, x15
    b.lo    .Lns8_block
.Lns8_tail:
    cmp     x7, x2
    b.hs    .Lns8_fin
1:  ldp     x10, x11, [x0], #16
    cbz     x9, 2f
    VBIT    12, 9, 7, 13
    sbfx    x12, x12, #0, #1
    and     x10, x10, x12
    and     x11, x11, x12
2:  asr     x12, x11, #63
    adds    x4, x4, x10
    adcs    x5, x5, x11
    adc     x6, x6, x12
    add     x7, x7, #1
    cmp     x7, x2
    b.lo    1b
.Lns8_fin:
    cmp     x6, x5, asr #63                 // fits in int128 <=> top == sign(mid)
    b.ne    .Lns8_ovf
    stp     x4, x5, [x3]
    mov     w0, #0
    ret
.Lns8_ovf:
    mov     w0, #1
    ret
ENDF pqk_a64_neon_sum_i128

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

/* ------------------------------------------------------------------------
 * size_t minmax_i128(x0 data, x1 validity, x2 n, x3 out_min, x4 out_max)
 * Registers: x5 count, x7:x6 min, x12:x11 max (GPR results), x9 validity
 * base, x10 row i, x15 main-loop row limit, x13/x14/x16/x17 temps;
 * v16-v19 (rows 0,1 / 4,5) and v20-v23 (rows 2,3 / 6,7) two independent
 * sets of 2-lane min-lo, min-hi, max-lo, max-hi accumulators, v24-v26
 * compare temps, v27 validity byte, v28 = {1, 2}, v29 lane validity,
 * v30 valid-row lane counter.
 * Algorithm: 8 rows per iteration (4 x LD2), signed 128-bit compares per
 * lane (MM2, 12 ops per 2 rows), two accumulator sets to halve the
 * loop-carried dependency chain. Accumulators start at INT128_MAX /
 * INT128_MIN; invalid lanes never update (mask ANDed into the update
 * masks). The 8 lane candidates are folded into GPRs with the scalar
 * MIN128/MAX128 chain, then the 0-7 tail rows are processed the same way.
 * Outputs are written only when count > 0.
 */
FUNC pqk_a64_neon_minmax_i128
    mov     x5, #0
    mov     x6, #-1                         // min = INT128_MAX
    mov     x7, #0x7fffffffffffffff
    mov     x11, #0                         // max = INT128_MIN
    mov     x12, #0x8000000000000000
    mov     x9, x1
    mov     x10, #0
    and     x15, x2, #~7
    cbz     x15, .Lnm8_tail
    dup     v16.2d, x6
    dup     v17.2d, x7
    dup     v18.2d, x11
    dup     v19.2d, x12
    mov     v20.16b, v16.16b
    mov     v21.16b, v17.16b
    mov     v22.16b, v18.16b
    mov     v23.16b, v19.16b
    cbz     x1, .Lnm8_nv
    LOADADDR x13, .Lbits2d
    ld1     {v28.2d}, [x13]
    movi    v30.2d, #0
.Lnm8_v:
    ld2     {v0.2d, v1.2d}, [x0], #32
    ld2     {v2.2d, v3.2d}, [x0], #32
    ld2     {v4.2d, v5.2d}, [x0], #32
    ld2     {v6.2d, v7.2d}, [x0], #32
    ld1r    {v27.16b}, [x1], #1
    MMV     0, 1, 16, 17, 18, 19
    MMV     2, 3, 20, 21, 22, 23
    MMV     4, 5, 16, 17, 18, 19
    MMV     6, 7, 20, 21, 22, 23
    add     x10, x10, #8
    cmp     x10, x15
    b.lo    .Lnm8_v
    addp    d30, v30.2d
    fmov    x5, d30
    b       .Lnm8_red
.Lnm8_nv:
    ld2     {v0.2d, v1.2d}, [x0], #32
    ld2     {v2.2d, v3.2d}, [x0], #32
    ld2     {v4.2d, v5.2d}, [x0], #32
    ld2     {v6.2d, v7.2d}, [x0], #32
    MM2     0, 1, 16, 17, 18, 19
    MM2     2, 3, 20, 21, 22, 23
    MM2     4, 5, 16, 17, 18, 19
    MM2     6, 7, 20, 21, 22, 23
    add     x10, x10, #8
    cmp     x10, x15
    b.lo    .Lnm8_nv
    mov     x5, x15
.Lnm8_red:
    REDMM   16, 17, 18, 19, 0
    REDMM   16, 17, 18, 19, 1
    REDMM   20, 21, 22, 23, 0
    REDMM   20, 21, 22, 23, 1
.Lnm8_tail:
    cmp     x10, x2
    b.hs    .Lnm8_fin
1:  ldp     x13, x14, [x0], #16
    cbz     x9, 2f
    VBIT    16, 9, 10, 17
    tbz     w16, #0, 3f                     // invalid row (tail: <= 7 rows)
2:  add     x5, x5, #1
    MIN128  6, 7, 13, 14
    MAX128  11, 12, 13, 14
3:  add     x10, x10, #1
    cmp     x10, x2
    b.lo    1b
.Lnm8_fin:
    cbz     x5, 4f
    stp     x6, x7, [x3]
    stp     x11, x12, [x4]
4:  mov     x0, x5
    ret
ENDF pqk_a64_neon_minmax_i128

    .section .note.GNU-stack, "", %progbits
