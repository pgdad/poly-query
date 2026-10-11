/*
 * pq_a64_sve.h — building blocks shared by several kernels of the SVE
 * variant (pq_a64_sve.S). Included after pq_a64_common.h. Macros only.
 * All of them are vector-length agnostic.
 *
 *   SVE_VALID, ROWPRED   validity bits -> valid-row predicate p1
 *   SVE_LD64, SVE_LD128  load the active rows + row numbers + p1
 *   INVPRED, PRED_BCAST64, SETUP128
 *                        broadcast the canonical range predicate
 *   RANGE64, RANGE128    evaluate the range predicate into p2
 *   BITMAP_BLOCKS        64-row block bitmap writer + count result
 *
 * Common register roles (all kernels using these macros):
 *   p0 active rows (WHILELO), p1 valid active rows, p2 selected rows,
 *   p6 inversion (all-true when the op is inverted), p7 all-true .d;
 *   z0 values (64-bit kernels), z2/z3 lo/hi words (128-bit kernels),
 *   z1 row numbers, z16-z19 broadcast constants, z28/z29 validity temps,
 *   x1 validity base. Only caller-saved state is used (z0-z7, z16-z31,
 *   p0-p15).
 */
#ifndef PQ_A64_SVE_H
#define PQ_A64_SVE_H

/* ======================================================================
 * Validity
 * ====================================================================== */

/* SVE_VALID: p1 = p0 & validity bits of rows z1 (validity base x1).
 * The validity bytes are gathered with LD1B (byte offsets row >> 3, active
 * lanes only, so never past ceil(n/8) bytes; the only general method for
 * any VL, which need not be a multiple of 8 rows), shifted right by
 * row & 7 and tested. Clobbers z28, z29. */
    .macro  SVE_VALID
    lsr     z28.d, z1.d, #3
    ld1b    {z28.d}, p0/z, [x1, z28.d]
    movprfx z29, z1
    and     z29.d, z29.d, #7
    lsr     z28.d, p0/m, z28.d, z29.d
    and     z28.d, z28.d, #1
    cmpne   p1.d, p0/z, z28.d, #0
    .endm

/* ROWPRED: p1 = valid active rows: SVE_VALID if x1 != NULL, else p0.
 * Needs p0, z1. Clobbers z28, z29. */
    .macro  ROWPRED
    cbz     x1, .Lrowpred_all\@
    SVE_VALID
    b       .Lrowpred_done\@
.Lrowpred_all\@:
    mov     p1.b, p0.b
.Lrowpred_done\@:
    .endm

/* SVE_LD64 xi: z0 = int64/double rows xi.. under p0 (data x0, zeroing),
 * z1 = their row numbers, p1 = valid active rows (ROWPRED). */
    .macro  SVE_LD64 xi
    ld1d    {z0.d}, p0/z, [x0, \xi, lsl #3]
    index   z1.d, \xi, #1
    ROWPRED
    .endm

/* SVE_LD128 xi: z2/z3 = lo/hi words of the pqk_i128 rows xi.. under p0
 * (LD2D de-interleaves VL/64 rows; addressed as [x0, 2*row, lsl #3], so the
 * row counter alone locates the data and block loops can restart at any
 * row), z1 = row numbers, p1 = valid active rows. Clobbers x13 (= 2*row). */
    .macro  SVE_LD128 xi
    lsl     x13, \xi, #1
    ld2d    {z2.d, z3.d}, p0/z, [x0, x13, lsl #3]
    index   z1.d, \xi, #1
    ROWPRED
    .endm

/* ======================================================================
 * Range predicate (filter / count kernels)
 * ====================================================================== */

/* INVPRED xinv: p6 = all-true (.d) if xinv != 0 else all-false. */
    .macro  INVPRED xinv
    pfalse  p6.b
    cbz     \xinv, .Linvpred_done\@
    ptrue   p6.d
.Linvpred_done\@:
    .endm

/* PRED_BCAST64: broadcasts the PRED_SETUP result x7 lo, x8 span, x9 inv
 * into z16 = lo, z17 = span, p6 = inversion. */
    .macro  PRED_BCAST64
    dup     z16.d, x7
    dup     z17.d, x8
    INVPRED x9
    .endm

/* RANGE64: p2 = valid rows (p1) whose value z0 satisfies
 * ((x - lo) <=u span) ^ inv. Needs z16 lo, z17 span, p6. Clobbers z0. */
    .macro  RANGE64
    sub     z0.d, z0.d, z16.d
    cmphs   p2.d, p1/z, z17.d, z0.d
    eor     p2.b, p1/z, p2.b, p6.b
    .endm

/* SETUP128 invalid: PRED128_SETUP from (w3 op, x4 &a, x5 &b) into the
 * vector constants z16:z17 = lo (lo / hi word), z18:z19 = span, z30 = 1,
 * p6 (inversion), p7 = all-true. Branches to `invalid` for an unknown op
 * before *a / *b are read. Clobbers x7-x13. */
    .macro  SETUP128 invalid
    PRED128_SETUP w3, x4, x5, x7, x8, x9, x10, x11, x12, x13, \invalid
    dup     z16.d, x7
    dup     z17.d, x8
    dup     z18.d, x9
    dup     z19.d, x10
    mov     z30.d, #1
    INVPRED x11
    ptrue   p7.d
    .endm

/* RANGE128: p2 = valid rows (p1) whose value (z2 lo / z3 hi words)
 * satisfies ((x - lo) <=u span) ^ inv in 128 bits, composed from 64-bit
 * lane compares and a predicate SEL (Pd = Pg ? Pn : Pm):
 *   d = x - lo (borrow from CMPHI applied to the hi word by a merging SUB)
 *   d <=u span : SEL(d_hi == span_hi, d_lo <=u span_lo, d_hi <u span_hi)
 * All compares are zeroing under p1, so inactive or invalid lanes never
 * count. Needs z16/z17 = lo, z18/z19 = span, z30 = 1, p6 inversion.
 * Clobbers z2, z3, p3-p5. */
    .macro  RANGE128
    cmphi   p3.d, p1/z, z16.d, z2.d         // borrow: lo_lo >u x_lo
    sub     z2.d, z2.d, z16.d               // d_lo
    sub     z3.d, z3.d, z17.d
    sub     z3.d, p3/m, z3.d, z30.d         // d_hi (borrow applied)
    cmphs   p4.d, p1/z, z18.d, z2.d         // d_lo <=u span_lo
    cmphi   p5.d, p1/z, z19.d, z3.d         // d_hi <u span_hi
    cmpeq   p2.d, p1/z, z19.d, z3.d         // d_hi == span_hi
    sel     p2.b, p2, p4.b, p5.b
    eor     p2.b, p1/z, p2.b, p6.b
    .endm

/* ======================================================================
 * Bitmap output
 * ====================================================================== */

/* BITMAP_BLOCKS pred: complete main loop + result section of a kernel that
 * writes a bitmap (filter_i64_bitmap, compare_i64). Rows are processed in
 * blocks of 64: every vector (p0 = active rows of the block, x12 = first
 * row, z1 = row numbers) is evaluated by the macro named `pred`, which must
 * leave the selected rows in p2; each selected lane contributes
 * 1 << (row & 63), ORV reduces the vector into the 64-bit block word, and
 * the word is stored with one STR (byte stores, ceil(rows/8) of them, for
 * the final partial block). Works for any VL; the row counter restarts at
 * the exact block end. Returns (RET) the number of selected rows.
 * Expects x2 n, x6 out_bits, p7 all-true .d. Uses x9 count, x10 block
 * start, x11 block end, x12 row, x13 block word, x14/x15 temps, z1-z3. */
    .macro  BITMAP_BLOCKS pred
    mov     x9, #0
    mov     x10, #0
    cbz     x2, .Lbitmap_blocks_end\@
.Lbitmap_blocks_block\@:
    add     x11, x10, #64
    cmp     x11, x2
    csel    x11, x11, x2, lo
    mov     x13, #0
    mov     x12, x10
    whilelo p0.d, x12, x11
.Lbitmap_blocks_vec\@:
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
    b.first .Lbitmap_blocks_vec\@
    sub     x14, x11, x10                   // rows in this block
    lsr     x15, x10, #3
    cmp     x14, #64
    b.ne    .Lbitmap_blocks_part\@
    str     x13, [x6, x15]
    b       .Lbitmap_blocks_next\@
.Lbitmap_blocks_part\@:                     // final partial block: ceil(rows/8) bytes
    add     x14, x14, #7
    lsr     x14, x14, #3
    add     x15, x6, x15
.Lbitmap_blocks_byte\@:
    strb    w13, [x15], #1
    lsr     x13, x13, #8
    subs    x14, x14, #1
    b.ne    .Lbitmap_blocks_byte\@
.Lbitmap_blocks_next\@:
    mov     x10, x11
    cmp     x10, x2
    b.lo    .Lbitmap_blocks_block\@
.Lbitmap_blocks_end\@:
    RET_X   x9
    .endm

#endif /* PQ_A64_SVE_H */
