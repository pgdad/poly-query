/*
 * pq_a64_sve.S — PolyQuery native kernels, AArch64 SVE variant ("a64_sve").
 * Vector-length agnostic (any VL from 128 to 2048 bits, including
 * non-power-of-two lengths). GNU as syntax, AAPCS64 (base PCS: no SVE
 * arguments or results). Only selected by the dispatcher when HWCAP_SVE is
 * present. Validated under qemu-user emulation only (no SVE hardware).
 *
 * ABI / register conventions (all functions):
 *   - Arguments in x0..x6, results in x0/w0/d0; `int` args read as W only.
 *   - Only caller-saved state is used: x0-x17, z0-z7, z16-z31, p0-p15.
 *     z8-z15 (whose low 64 bits d8-d15 are callee-saved) and x19-x29 are
 *     never touched. All functions are leaves, sp is never modified, so no
 *     frame, stack alignment or red zone is involved. x18 is never used.
 *   - Loops are predicated with WHILELO, so the final partial vector is
 *     handled by the governing predicate: inactive lanes are neither loaded
 *     nor stored (predicated contiguous/gather accesses do not touch inactive
 *     elements), so nothing outside the documented buffers is accessed.
 *     SVE loads/stores accept unaligned addresses on normal memory, so
 *     unaligned pointers are handled natively.
 *
 * Common building blocks:
 *   - Row predicate p0 = WHILELO(i, n); z1 = INDEX(i, 1) row numbers.
 *   - SVE_VALID: p1 = p0 & validity(row): validity bytes are gathered with
 *     LD1B (vector of byte offsets row>>3, active lanes only, so never past
 *     ceil(n/8) bytes), shifted right by row&7 and tested.
 *   - Range predicate (PRED_SETUP): p2 = CMPHS(span, x - lo) under p1, then
 *     EOR with p6 (all-true when the op is inverted) zeroed by p1.
 *   - Bitmap outputs (filter_i64_bitmap, compare_i64) are produced in blocks
 *     of 64 rows: each lane contributes 1 << (row & 63) when selected, ORV
 *     reduces the vector into a 64-bit word, and each block word is stored
 *     with one STR (or byte stores for the final partial block).
 *
 * Kernel algorithms:
 *   filter_i64        COMPACT of the row-number vector under p2, stored with
 *                     ST1W (truncating .d -> 32 bit) under WHILELO(0, count).
 *   count_i64         INCP of p2.
 *   sum_i64           exact: each int64 is split into its unsigned low 32
 *                     bits (AND) and signed high 32 bits (ASR); both are
 *                     added (merging, under p1) into 64-bit lanes. Blocks of
 *                     2^24 rows bound the lanes (< 2^56), each block is
 *                     reduced with UADDV (modular, exact here) and folded
 *                     into a 128-bit GPR total as lo + (hi << 32).
 *   sum_f64           merging FADD into one lane-wise accumulator, FADDV.
 *   minmax_i64        merging SMIN/SMAX, SMINV/SMAXV, INCP for the count.
 *   minmax_f64        merging FMINNM/FMAXNM, then the same first-valid-zero
 *                     fix-up as the NEON variant for bit-exact signed zeros.
 *   bitmap ops        byte vectors under WHILELO .b (load both, then store:
 *                     aliasing-safe).
 *   bitmap_popcount   CNT .b + UADDV per vector, scalar masked partial byte.
 *   hash_i64          fully vectorized fmix64: SVE has a 64-bit MUL.
 *   compare_i64       CMPEQ/CMPGT (+operand swap for LT/GE, inversion for
 *                     NE/LE/GE) into the 64-row block bitmap writer.
 *   compare_fixed     per record, byte vectors: CMPNE finds a difference,
 *                     BRKB + LASTA extract the first differing bytes.
 *   group_sum_i64     validation: merging UMAX of zero-extended ids under p1
 *                     plus INCP (EINVAL iff a valid row exists and max id >=
 *                     ngroups); accumulation is scalar in row order (ADDS +
 *                     CSINC overflow flag), as SVE has no conflict-free
 *                     scatter-add.
 *   gather_i64        LD1W (zero-extend) + LD1D gather (scaled) + ST1D.
 */
#include "pq_a64_macros.h"

    .arch   armv8.2-a+sve

/* SVE_VALID: p1 = p0 & validity bits of rows z1 (validity base x1).
 * Clobbers z28, z29. */
    .macro  SVE_VALID
    lsr     z28.d, z1.d, #3
    ld1b    {z28.d}, p0/z, [x1, z28.d]
    movprfx z29, z1
    and     z29.d, z29.d, #7
    lsr     z28.d, p0/m, z28.d, z29.d
    and     z28.d, z28.d, #1
    cmpne   p1.d, p0/z, z28.d, #0
    .endm

/* ROWPRED: p1 = valid active rows (uses x1; p0, z1 must be set). */
    .macro  ROWPRED
    cbz     x1, .Lrp_all\@
    SVE_VALID
    b       .Lrp_done\@
.Lrp_all\@:
    mov     p1.b, p0.b
.Lrp_done\@:
    .endm

/* INVPRED xinv: p6 = all-true (.d) if xinv != 0 else all-false. */
    .macro  INVPRED xinv
    pfalse  p6.b
    cbz     \xinv, .Lip\@
    ptrue   p6.d
.Lip\@:
    .endm

/* ------------------------------------------------------------------------
 * size_t filter_i64(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b, x6 out_idx)
 * x7 lo, x8 span, x9 inv, x10 row, x11 count, x12 selected in vector,
 * z16 lo, z17 span, z0 values, z1 rows, z2 compacted rows,
 * p0 rows, p1 valid rows, p2 selected, p3 store predicate, p6 inversion,
 * p7 all-true.
 */
FUNC pqk_a64_sve_filter_i64
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lvf_inval
    mov     x10, #0
    mov     x11, #0
    dup     z16.d, x7
    dup     z17.d, x8
    INVPRED x9
    ptrue   p7.d
    whilelo p0.d, x10, x2
    b.none  .Lvf_done
.Lvf_loop:
    ld1d    {z0.d}, p0/z, [x0, x10, lsl #3]
    index   z1.d, x10, #1
    ROWPRED
    sub     z0.d, z0.d, z16.d
    cmphs   p2.d, p1/z, z17.d, z0.d
    eor     p2.b, p1/z, p2.b, p6.b
    compact z2.d, p2, z1.d
    cntp    x12, p7, p2.d
    whilelo p3.d, xzr, x12
    st1w    {z2.d}, p3, [x6, x11, lsl #2]
    add     x11, x11, x12
    incd    x10
    whilelo p0.d, x10, x2
    b.first .Lvf_loop
.Lvf_done:
    mov     x0, x11
    ret
.Lvf_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_sve_filter_i64

/* BITMAP_BLOCKS body: generic 64-row block bitmap writer.
 * Expects: x2 n, x6 out_bits, p7 all-true .d. Returns (ret) the number of
 * selected rows, counted in x9. The `pred` macro argument names a macro that, given p0
 * (active rows), x12 (first row of the vector) and z1 (row numbers),
 * leaves the selected rows in p2. Uses x10 block start, x11 block end,
 * x12 row, x13 block word, x14/x15 temps, z2, z3.
 */
    .macro  BITMAP_BLOCKS pred
    mov     x9, #0
    mov     x10, #0
    cbz     x2, .Lbb_end\@
.Lbb_block\@:
    add     x11, x10, #64
    cmp     x11, x2
    csel    x11, x11, x2, lo
    mov     x13, #0
    mov     x12, x10
    whilelo p0.d, x12, x11
.Lbb_vec\@:
    index   z1.d, x12, #1
    \pred
    and     z1.d, z1.d, #63
    mov     z2.d, #1
    lsl     z2.d, p7/m, z2.d, z1.d          // 1 << (row & 63)
    orv     d3, p2, z2.d
    fmov    x14, d3
    orr     x13, x13, x14
    incp    x9, p2.d
    incd    x12
    whilelo p0.d, x12, x11
    b.first .Lbb_vec\@
    sub     x14, x11, x10                   // rows in this block
    lsr     x15, x10, #3
    cmp     x14, #64
    b.ne    .Lbb_part\@
    str     x13, [x6, x15]
    b       .Lbb_next\@
.Lbb_part\@:                                // final partial block: ceil(rows/8) bytes
    add     x14, x14, #7
    lsr     x14, x14, #3
    add     x15, x6, x15
.Lbb_byte\@:
    strb    w13, [x15], #1
    lsr     x13, x13, #8
    subs    x14, x14, #1
    b.ne    .Lbb_byte\@
.Lbb_next\@:
    mov     x10, x11
    cmp     x10, x2
    b.lo    .Lbb_block\@
.Lbb_end\@:
    mov     x0, x9
    ret
    .endm

/* Range predicate for the block writer (x0 data, x1 validity). */
    .macro  RANGE_PRED
    ld1d    {z0.d}, p0/z, [x0, x12, lsl #3]
    ROWPRED
    sub     z0.d, z0.d, z16.d
    cmphs   p2.d, p1/z, z17.d, z0.d
    eor     p2.b, p1/z, p2.b, p6.b
    .endm

/* ------------------------------------------------------------------------
 * size_t filter_i64_bitmap(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b,
 *                          x6 out_bits)
 * x7 lo, x8 span, z16 lo, z17 span, p6 inversion; block writer registers.
 */
FUNC pqk_a64_sve_filter_i64_bitmap
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lvfb_inval
    dup     z16.d, x7
    dup     z17.d, x8
    INVPRED x9
    ptrue   p7.d
    BITMAP_BLOCKS RANGE_PRED
.Lvfb_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_sve_filter_i64_bitmap

/* ------------------------------------------------------------------------
 * int sum_i64(x0 data, x1 validity, x2 n, x3 out_sum)
 * x4:x5 128-bit total, x6 row, x8 block end, x9/x10 block sums,
 * z16 low-half sums, z17 high-half sums, z0 values, z2 low, z3 high.
 */
FUNC pqk_a64_sve_sum_i64
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    ptrue   p7.d
    cbz     x2, .Lvs_fin
.Lvs_block:
    mov     x8, #(1 << 24)
    add     x8, x8, x6
    cmp     x8, x2
    csel    x8, x8, x2, lo
    mov     z16.d, #0
    mov     z17.d, #0
    whilelo p0.d, x6, x8
.Lvs_loop:
    ld1d    {z0.d}, p0/z, [x0, x6, lsl #3]
    index   z1.d, x6, #1
    ROWPRED
    movprfx z2, z0
    and     z2.d, z2.d, #0xffffffff
    asr     z3.d, z0.d, #32
    add     z16.d, p1/m, z16.d, z2.d
    add     z17.d, p1/m, z17.d, z3.d
    incd    x6
    whilelo p0.d, x6, x8
    b.first .Lvs_loop
    mov     x6, x8                          // resume exactly at the block end
    uaddv   d16, p7, z16.d                  // < 32 * 2^56: no wrap
    uaddv   d17, p7, z17.d                  // two's complement sum, |.| < 2^60
    fmov    x9, d16
    fmov    x10, d17
    adds    x4, x4, x9
    adc     x5, x5, xzr
    lsl     x11, x10, #32
    asr     x12, x10, #32
    adds    x4, x4, x11
    adc     x5, x5, x12
    cmp     x6, x2
    b.lo    .Lvs_block
.Lvs_fin:
    cmp     x5, x4, asr #63
    b.ne    .Lvs_ovf
    str     x4, [x3]
    mov     w0, #0
    ret
.Lvs_ovf:
    mov     w0, #1
    ret
ENDF pqk_a64_sve_sum_i64

/* ------------------------------------------------------------------------
 * double sum_f64(x0 data, x1 validity, x2 n)
 * x6 row, z16 lane sums, z0 values.
 */
FUNC pqk_a64_sve_sum_f64
    mov     x6, #0
    ptrue   p7.d
    mov     z16.d, #0
    whilelo p0.d, x6, x2
    b.none  2f
1:  ld1d    {z0.d}, p0/z, [x0, x6, lsl #3]
    index   z1.d, x6, #1
    ROWPRED
    fadd    z16.d, p1/m, z16.d, z0.d
    incd    x6
    whilelo p0.d, x6, x2
    b.first 1b
2:  faddv   d0, p7, z16.d
    ret
ENDF pqk_a64_sve_sum_f64

/* ------------------------------------------------------------------------
 * size_t minmax_i64(x0 data, x1 validity, x2 n, x3 out_min, x4 out_max)
 * x6 row, x9 count, z16 mins, z17 maxs.
 */
FUNC pqk_a64_sve_minmax_i64
    mov     x6, #0
    mov     x9, #0
    ptrue   p7.d
    mov     x7, #0x7fffffffffffffff
    dup     z16.d, x7
    mov     x7, #0x8000000000000000
    dup     z17.d, x7
    whilelo p0.d, x6, x2
    b.none  2f
1:  ld1d    {z0.d}, p0/z, [x0, x6, lsl #3]
    index   z1.d, x6, #1
    ROWPRED
    smin    z16.d, p1/m, z16.d, z0.d
    smax    z17.d, p1/m, z17.d, z0.d
    incp    x9, p1.d
    incd    x6
    whilelo p0.d, x6, x2
    b.first 1b
    cbz     x9, 2f
    sminv   d0, p7, z16.d
    smaxv   d1, p7, z17.d
    str     d0, [x3]
    str     d1, [x4]
2:  mov     x0, x9
    ret
ENDF pqk_a64_sve_minmax_i64

/* ------------------------------------------------------------------------
 * size_t minmax_f64(x0 data, x1 validity, x2 n, x3 out_min, x4 out_max)
 * x6 row, x9 count, z16 mins (+inf), z17 maxs (-inf), d0/d1 results.
 * Zero results are replaced by the first valid zero (bit-exact signed zero
 * semantics of the sequential reference).
 */
FUNC pqk_a64_sve_minmax_f64
    mov     x6, #0
    mov     x9, #0
    ptrue   p7.d
    mov     x7, #0x7ff0000000000000
    dup     z16.d, x7
    mov     x7, #0xfff0000000000000
    dup     z17.d, x7
    whilelo p0.d, x6, x2
    b.none  .Lvmf_ret
1:  ld1d    {z0.d}, p0/z, [x0, x6, lsl #3]
    index   z1.d, x6, #1
    ROWPRED
    fminnm  z16.d, p1/m, z16.d, z0.d
    fmaxnm  z17.d, p1/m, z17.d, z0.d
    incp    x9, p1.d
    incd    x6
    whilelo p0.d, x6, x2
    b.first 1b
    cbz     x9, .Lvmf_ret
    fminnmv d0, p7, z16.d
    fmaxnmv d1, p7, z17.d
    fcmp    d0, #0.0
    b.eq    .Lvmf_zero
    fcmp    d1, #0.0
    b.ne    .Lvmf_store
.Lvmf_zero:
    mov     x10, #0
3:  cmp     x10, x2
    b.hs    .Lvmf_store
    ldr     x8, [x0, x10, lsl #3]
    lsl     x12, x8, #1                     // zero iff +0.0 or -0.0
    cbnz    x12, 4f
    cbz     x1, 5f
    VBIT    12, 1, 10, 13
    tbnz    w12, #0, 5f
4:  add     x10, x10, #1
    b       3b
5:  fmov    d4, x8
    fcmp    d0, #0.0
    fcsel   d0, d4, d0, eq
    fcmp    d1, #0.0
    fcsel   d1, d4, d1, eq
.Lvmf_store:
    str     d0, [x3]
    str     d1, [x4]
.Lvmf_ret:
    mov     x0, x9
    ret
ENDF pqk_a64_sve_minmax_f64

/* ------------------------------------------------------------------------
 * size_t count_i64(x0 data, x1 validity, x2 n, w3 op, x4 a, x5 b)
 * x7 lo, x8 span, x9 inv, x10 row, x11 count, z16/z17 lo/span, p6 inversion.
 */
FUNC pqk_a64_sve_count_i64
    PRED_SETUP w3, x4, x5, x7, x8, x9, x10, .Lvc_inval
    mov     x10, #0
    mov     x11, #0
    dup     z16.d, x7
    dup     z17.d, x8
    INVPRED x9
    whilelo p0.d, x10, x2
    b.none  2f
1:  ld1d    {z0.d}, p0/z, [x0, x10, lsl #3]
    index   z1.d, x10, #1
    ROWPRED
    sub     z0.d, z0.d, z16.d
    cmphs   p2.d, p1/z, z17.d, z0.d
    eor     p2.b, p1/z, p2.b, p6.b
    incp    x11, p2.d
    incd    x10
    whilelo p0.d, x10, x2
    b.first 1b
2:  mov     x0, x11
    ret
.Lvc_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_sve_count_i64

/* ------------------------------------------------------------------------
 * void bitmap_{and,or,andnot}(x0 a, x1 b, x2 out, x3 nbytes)
 * x4 offset, z0/z1 operands, p0 active bytes.
 */
    .macro  VBITOP name, insn
FUNC pqk_a64_sve_bitmap_\name
    mov     x4, #0
    whilelo p0.b, x4, x3
    b.none  2f
1:  ld1b    {z0.b}, p0/z, [x0, x4]
    ld1b    {z1.b}, p0/z, [x1, x4]
    \insn   z0.d, z0.d, z1.d
    st1b    {z0.b}, p0, [x2, x4]
    incb    x4
    whilelo p0.b, x4, x3
    b.first 1b
2:  ret
ENDF pqk_a64_sve_bitmap_\name
    .endm

    VBITOP  and, and
    VBITOP  or, orr
    VBITOP  andnot, bic

/* ------------------------------------------------------------------------
 * size_t bitmap_popcount(x0 bits, x1 nbits)
 * x3 full bytes, x4 offset, x6 partial bits, x7 total, z0 bytes/counts.
 */
FUNC pqk_a64_sve_bitmap_popcount
    and     x6, x1, #7
    lsr     x3, x1, #3
    mov     x4, #0
    mov     x7, #0
    whilelo p0.b, x4, x3
    b.none  2f
1:  ld1b    {z0.b}, p0/z, [x0, x4]
    cnt     z0.b, p0/m, z0.b
    uaddv   d1, p0, z0.b
    fmov    x5, d1
    add     x7, x7, x5
    incb    x4
    whilelo p0.b, x4, x3
    b.first 1b
2:  cbz     x6, 3f
    ldrb    w5, [x0, x3]
    mov     w4, #1
    lsl     w4, w4, w6
    sub     w4, w4, #1
    and     w5, w5, w4
    fmov    s0, w5
    cnt     v0.8b, v0.8b
    umov    w5, v0.b[0]
    add     x7, x7, x5
3:  mov     x0, x7
    ret
ENDF pqk_a64_sve_bitmap_popcount

/* ------------------------------------------------------------------------
 * void hash_i64(x0 data, x1 n, x2 seed, x3 out)
 * x6 row, z16 seed, z17/z18 multipliers, z0 state, z1 temp.
 */
FUNC pqk_a64_sve_hash_i64
    LOAD_FMIX 4, 5
    mov     x6, #0
    ptrue   p7.d
    dup     z16.d, x2
    dup     z17.d, x4
    dup     z18.d, x5
    whilelo p0.d, x6, x1
    b.none  2f
1:  ld1d    {z0.d}, p0/z, [x0, x6, lsl #3]
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
    b.first 1b
2:  ret
ENDF pqk_a64_sve_hash_i64

/* ------------------------------------------------------------------------
 * size_t compare_i64(x0 a, x1 b, x2 n, w3 op, x4 out_bits)
 * Operands swapped for LT/GE, p6 inverts NE/LE/GE; x5 holds out_bits for
 * the duration (copied to x6 for the block writer), w7 type (0 EQ, 1 GT).
 */
    .macro  CMPEQ_PRED
    ld1d    {z0.d}, p0/z, [x0, x12, lsl #3]
    ld1d    {z2.d}, p0/z, [x1, x12, lsl #3]
    cmpeq   p2.d, p0/z, z0.d, z2.d
    eor     p2.b, p0/z, p2.b, p6.b
    .endm
    .macro  CMPGT_PRED
    ld1d    {z0.d}, p0/z, [x0, x12, lsl #3]
    ld1d    {z2.d}, p0/z, [x1, x12, lsl #3]
    cmpgt   p2.d, p0/z, z0.d, z2.d
    eor     p2.b, p0/z, p2.b, p6.b
    .endm

FUNC pqk_a64_sve_compare_i64
    cmp     w3, #5
    b.hi    .Lvci_inval
    and     w9, w3, #1
    INVPRED x9
    cmp     w3, #2
    b.eq    1f
    cmp     w3, #5
    b.ne    2f
1:  mov     x5, x0                          // LT / GE: swap -> GT / LE
    mov     x0, x1
    mov     x1, x5
2:  mov     x6, x4
    ptrue   p7.d
    cmp     w3, #2
    b.hs    .Lvci_gt
    BITMAP_BLOCKS CMPEQ_PRED
.Lvci_gt:
    BITMAP_BLOCKS CMPGT_PRED
.Lvci_inval:
    mov     x0, #-1
    ret
ENDF pqk_a64_sve_compare_i64

/* ------------------------------------------------------------------------
 * void compare_fixed(x0 a, x1 b, x2 width, x3 n, x4 out)
 * x5 offset in record, w8/w9 first differing bytes, w10 result,
 * p0 active bytes, p1 differing bytes, p2 bytes before the first difference.
 */
FUNC pqk_a64_sve_compare_fixed
    cbz     x3, .Lvcf_ret
.Lvcf_rec:
    mov     x5, #0
    whilelo p0.b, x5, x2
    b.none  .Lvcf_eq
1:  ld1b    {z0.b}, p0/z, [x0, x5]
    ld1b    {z1.b}, p0/z, [x1, x5]
    cmpne   p1.b, p0/z, z0.b, z1.b
    b.any   .Lvcf_diff
    incb    x5
    whilelo p0.b, x5, x2
    b.first 1b
.Lvcf_eq:
    strb    wzr, [x4], #1
    b       .Lvcf_next
.Lvcf_diff:
    brkb    p2.b, p0/z, p1.b
    lasta   w8, p2, z0.b                    // element after the last "equal"
    lasta   w9, p2, z1.b
    and     w8, w8, #0xff
    and     w9, w9, #0xff
    cmp     w8, w9
    mov     w10, #1
    cneg    w10, w10, lo
    strb    w10, [x4], #1
.Lvcf_next:
    add     x0, x0, x2
    add     x1, x1, x2
    subs    x3, x3, #1
    b.ne    .Lvcf_rec
.Lvcf_ret:
    ret
ENDF pqk_a64_sve_compare_fixed

/* ------------------------------------------------------------------------
 * int group_sum_i64(x0 group_ids, x1 values, x2 validity, x3 n, x4 sums,
 *                   x5 counts, x6 ngroups)
 * Validation: x10 row, x11 valid count, z16 max id, z0 ids (zero-extended).
 * The ROWPRED macro reads the validity pointer from x1, so values/validity
 * are temporarily swapped (x1 <-> x2) during validation.
 * Accumulation: w9 overflow flag, x10 row, x11 id, x12/x13 temps.
 */
FUNC pqk_a64_sve_group_sum_i64
    cbz     x3, .Lvg_ok
    mov     x7, x1
    mov     x1, x2
    mov     x2, x7
    mov     x10, #0
    mov     x11, #0
    ptrue   p7.d
    mov     z16.d, #0
    whilelo p0.d, x10, x3
1:  ld1w    {z0.d}, p0/z, [x0, x10, lsl #2]
    index   z1.d, x10, #1
    ROWPRED
    umax    z16.d, p1/m, z16.d, z0.d
    incp    x11, p1.d
    incd    x10
    whilelo p0.d, x10, x3
    b.first 1b
    mov     x7, x1                          // restore x1 = values, x2 = validity
    mov     x1, x2
    mov     x2, x7
    cbz     x11, .Lvg_ok                    // no valid row: nothing to do
    umaxv   d16, p7, z16.d
    fmov    x12, d16
    cmp     x12, x6
    b.hs    .Lvg_inval
    mov     w9, #0
    mov     x10, #0
2:  cbz     x2, 3f
    VBIT    12, 2, 10, 13
    tbz     w12, #0, 4f
3:  ldr     w11, [x0, x10, lsl #2]
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
    b.lo    2b
    mov     w0, w9
    ret
.Lvg_ok:
    mov     w0, #0
    ret
.Lvg_inval:
    mov     w0, #2
    ret
ENDF pqk_a64_sve_group_sum_i64

/* ------------------------------------------------------------------------
 * void gather_i64(x0 data, x1 idx, x2 m, x3 out)
 * x4 position, z0 indices (zero-extended), z1 gathered values.
 */
FUNC pqk_a64_sve_gather_i64
    mov     x4, #0
    whilelo p0.d, x4, x2
    b.none  2f
1:  ld1w    {z0.d}, p0/z, [x1, x4, lsl #2]
    ld1d    {z1.d}, p0/z, [x0, z0.d, lsl #3]
    st1d    {z1.d}, p0, [x3, x4, lsl #3]
    incd    x4
    whilelo p0.d, x4, x2
    b.first 1b
2:  ret
ENDF pqk_a64_sve_gather_i64

    .section .note.GNU-stack, "", %progbits
