/*
 * pq_a64_common.h — building blocks shared by all AArch64 PolyQuery variants.
 *
 * Included (C preprocessor) first by pq_a64_scalar.S, pq_a64_neon.S and
 * pq_a64_sve.S. Emits no code or data by itself: it only defines constants
 * (cpp) and GNU as macros. Variant-specific blocks shared by several kernels
 * of one variant live in pq_a64_neon.h and pq_a64_sve.h. The README has the
 * full list of building blocks and the kernels that use each one.
 *
 * Sections of this file:
 *   1. Constants mirrored from ../include/pq_kernels.h, value limits,
 *      MurmurHash3 fmix64 multipliers.
 *   2. File and function framing: FUNC / ENDF, PQ_FILE_END, return helpers.
 *   3. Operator validation and dispatch: PRED_SETUP, PRED128_SETUP (filter /
 *      count), CMPOP_CHECK / CMPOP_SWAP (compare_i64).
 *   4. Scalar predicate evaluation and validity bits: SPRED, SPRED128, VBIT,
 *      AND_VBIT.
 *   5. Exact integer accumulation: ADD128S, ADD192S, FOLD_SUM64,
 *      FOLD_LIMBS192, BLOCK_END and the result epilogues SUM64_RESULT,
 *      SUM128_RESULT.
 *   6. Min/max: MIN128(V), MAX128(V), MINMAX64_STEP, F64_MINMAX_STEP,
 *      MINMAX_RESULT, MINMAX128_RESULT, F64_FIRST_ZERO.
 *   7. Bitmaps and bit counting: SBITMAP_PUT / SBITMAP_FLUSH (scalar bitmap
 *      writer), BITOP_STEP8, BITOP_BYTES, LOWBITS, ADD_CNT8, ADD_POPCNT_LOW.
 *   8. Hashing: LOAD_FMIX, FMIX1.
 *   9. Fixed-width comparison: CFX_BYTES, CFX_RESULT.
 *  10. Grouped aggregation: GSUM_ADD, GSUM_ROWS.
 *  11. Addressing: LOADADDR.
 *
 * Conventions:
 *   - Macros that must name both the W and the X view of a register take bare
 *     register numbers (e.g. `SPRED 12, 7, 8, 9` uses x12 and w12). All other
 *     macros take full register names (e.g. `FOLD_SUM64 x4, x5, x8, ...`).
 *   - Macro-internal labels are `.L<macro>_<step>\@` (\@ makes them unique
 *     per expansion); macros never use numeric local labels.
 *   - Every macro documents its inputs, outputs and the registers it
 *     clobbers. Unless stated otherwise the condition flags are clobbered.
 *   - Only caller-saved registers appear in these macros (x0-x17, v0-v7,
 *     v16-v31), in line with the AAPCS64 rules of the variant files.
 */
#ifndef PQ_A64_COMMON_H
#define PQ_A64_COMMON_H

/* ======================================================================
 * 1. Constants
 * ====================================================================== */

/* Status codes and comparison operators: same values as pq_kernels.h (that
 * header contains C declarations and cannot be included by the assembler). */
#define PQK_OK        0
#define PQK_OVERFLOW  1
#define PQK_EINVAL    2

#define PQK_EQ        0
#define PQK_NE        1
#define PQK_LT        2
#define PQK_LE        3
#define PQK_GT        4
#define PQK_GE        5
#define PQK_BETWEEN   6

/* 64-bit value limits (also the high words of INT128_MIN / INT128_MAX). */
#define PQ_INT64_MIN  0x8000000000000000
#define PQ_INT64_MAX  0x7fffffffffffffff

/* IEEE-754 binary64 bit patterns of +infinity and -infinity. */
#define PQ_F64_PINF   0x7ff0000000000000
#define PQ_F64_NINF   0xfff0000000000000

/* MurmurHash3 fmix64 multipliers (pqk_hash_i64). */
#define PQ_FMIX_C1    0xff51afd7ed558ccd
#define PQ_FMIX_C2    0xc4ceb9fe1a85ec53

/* ======================================================================
 * 2. File and function framing
 * ====================================================================== */

/* FUNC name / ENDF name: start / end of an exported kernel. FUNC switches to
 * .text, declares a global %function symbol and aligns the entry to 16 bytes;
 * ENDF records the symbol size. Every kernel is a leaf: there is no stack
 * frame, sp is never touched, so no prologue/epilogue code is needed and the
 * only "epilogue" is the RET of one of the return helpers below. */
    .macro FUNC name
    .text
    .globl  \name
    .type   \name, %function
    .p2align 4
\name:
    .endm

    .macro ENDF name
    .size   \name, . - \name
    .endm

/* PQ_FILE_END: last line of every variant file. Marks the stack as
 * non-executable (empty .note.GNU-stack section). */
    .macro PQ_FILE_END
    .section .note.GNU-stack, "", %progbits
    .endm

/* Return helpers.
 * RET_INVALID_OP : return (size_t)-1 (unknown op of a size_t kernel).
 * RET_STATUS st  : return the int status constant st (PQK_OK, ...).
 * RET_X xr       : return the 64-bit value in xr (xr != x0).
 * RET_W wr       : return the 32-bit value in wr (wr != w0). */
    .macro RET_INVALID_OP
    mov     x0, #-1
    ret
    .endm

    .macro RET_STATUS st
    mov     w0, #\st
    ret
    .endm

    .macro RET_X xr
    mov     x0, \xr
    ret
    .endm

    .macro RET_W wr
    mov     w0, \wr
    ret
    .endm

/* ======================================================================
 * 3. Operator validation and dispatch
 * ====================================================================== */

/* PRED_SETUP wop, xa, xb, xlo, xspan, xinv, xt, invalid
 *
 * Converts a predicate (op, a, b) of filter_i64 / filter_i64_bitmap /
 * count_i64 into the canonical unsigned range form used by every predicate
 * kernel:
 *
 *     pred(x) = ((uint64)(x - lo) <= span) XOR inv
 *
 * lo/span are 64-bit, inv is 0 or all-ones. Mapping:
 *   EQ      lo=a      span=0          inv=0
 *   NE      lo=a      span=0          inv=-1
 *   LT      lo=MIN    span=(a-1)-MIN  inv=(a==MIN ? -1 : 0)
 *   LE      lo=MIN    span=a-MIN      inv=0
 *   GT      lo=a+1    span=MAX-lo     inv=(a==MAX ? -1 : 0)
 *   GE      lo=a      span=MAX-a      inv=0
 *   BETWEEN lo=a      span=b-a        inv=0     (a <= b)
 *           lo=a      span=~0         inv=-1    (a >  b: empty)
 * An "empty" predicate is encoded as span=~0 (always true) inverted. Signed
 * range membership x in [lo,hi] is equivalent to (x-lo) <=u (hi-lo) when
 * lo <= hi.
 *
 * Validation: branches to `invalid` when op is not in 0..6. The op is
 * compared as an unsigned 32-bit value, so negative ints are rejected too;
 * the upper half of the X register is ignored (AAPCS64 leaves it unspecified
 * for `int`). Nothing is read from memory.
 * In: wop, xa, xb. Out: xlo, xspan, xinv. Clobbers xt and flags. All
 * registers must be distinct. */
    .macro PRED_SETUP wop, xa, xb, xlo, xspan, xinv, xt, invalid
    cmp     \wop, #PQK_BETWEEN
    b.hi    \invalid
    mov     \xlo, \xa
    mov     \xinv, #0
    mov     \xt, #PQ_INT64_MIN
    cmp     \wop, #PQK_NE
    b.hi    .Lpred_setup_lt\@
    mov     \xspan, #0                      // EQ / NE: (x - a) <=u 0
    csetm   \xinv, eq                       // NE: inverted
    b       .Lpred_setup_done\@
.Lpred_setup_lt\@:
    cmp     \wop, #PQK_LE
    b.hi    .Lpred_setup_gt\@
    sub     \xspan, \xa, #1
    csel    \xspan, \xspan, \xa, ne         // hi = (LT) ? a-1 : a
    ccmp    \xa, \xt, #0, ne                // LT with a == MIN -> empty set
    csetm   \xinv, eq
    eor     \xspan, \xspan, \xt             // span = hi - MIN
    mov     \xlo, \xt
    b       .Lpred_setup_done\@
.Lpred_setup_gt\@:
    cmp     \wop, #PQK_GE
    b.hi    .Lpred_setup_bt\@
    add     \xlo, \xa, #1
    csel    \xlo, \xlo, \xa, ne             // lo = (GT) ? a+1 : a
    mvn     \xspan, \xt                     // INT64_MAX
    ccmp    \xa, \xspan, #0, ne             // GT with a == MAX -> empty set
    csetm   \xinv, eq
    sub     \xspan, \xspan, \xlo            // span = MAX - lo
    b       .Lpred_setup_done\@
.Lpred_setup_bt\@:
    sub     \xspan, \xb, \xa                // BETWEEN: span = b - a
    cmp     \xa, \xb
    csetm   \xinv, gt                       // a > b -> empty set
    csinv   \xspan, \xspan, xzr, le
.Lpred_setup_done\@:
    .endm

/* PRED128_SETUP wop, xpa, xpb, xll, xlh, xsl, xsh, xinv, xt1, xt2, invalid
 *
 * 128-bit version of PRED_SETUP for filter_i128 / count_i128: the same
 * canonical form
 *
 *     pred(x) = ((uint128)(x - lo) <= span) XOR inv
 *
 * with lo/span 128-bit (register pairs) and the same op mapping (MIN/MAX are
 * now INT128_MIN/INT128_MAX). x - MIN and MAX - x need no arithmetic:
 * subtracting / adding 2^127 only flips bit 127, i.e. bit 63 of the high
 * word. The empty-set cases are detected with the V flag of the SBCS/ADCS
 * that forms a -/+ 1 (LT INT128_MIN, GT INT128_MAX) and with the signed
 * flags of b - a (BETWEEN with a > b).
 *
 * In: wop (int op), xpa (-> a), xpb (-> b, dereferenced only for BETWEEN).
 * Out: lo = xlh:xll, span = xsh:xsl, xinv = 0 or -1. Clobbers xt1, xt2 and
 * flags. Branches to `invalid` (before dereferencing anything) for an
 * unknown op; *a is read for every valid op, even when n == 0. All
 * registers must be distinct. */
    .macro PRED128_SETUP wop, xpa, xpb, xll, xlh, xsl, xsh, xinv, xt1, xt2, invalid
    cmp     \wop, #PQK_BETWEEN
    b.hi    \invalid
    ldp     \xll, \xlh, [\xpa]              // lo = a (default)
    mov     \xinv, #0
    cmp     \wop, #PQK_NE
    b.hi    .Lpred128_setup_lt\@
    mov     \xsl, #0                        // EQ / NE: (x - a) <=u 0
    mov     \xsh, #0
    csetm   \xinv, eq                       // NE: inverted
    b       .Lpred128_setup_done\@
.Lpred128_setup_lt\@:
    cmp     \wop, #PQK_LE
    b.hi    .Lpred128_setup_gt\@
    mov     \xsl, \xll                      // hi = a (LE)
    mov     \xsh, \xlh
    b.eq    .Lpred128_setup_le\@
    subs    \xsl, \xll, #1                  // LT: hi = a - 1
    sbcs    \xsh, \xlh, xzr                 // V iff a == INT128_MIN
    csetm   \xinv, vs                       // LT MIN: empty set
.Lpred128_setup_le\@:
    eor     \xsh, \xsh, #PQ_INT64_MIN       // span = hi - MIN
    mov     \xll, #0                        // lo = INT128_MIN
    mov     \xlh, #PQ_INT64_MIN
    b       .Lpred128_setup_done\@
.Lpred128_setup_gt\@:
    cmp     \wop, #PQK_GE
    b.hi    .Lpred128_setup_bt\@
    b.eq    .Lpred128_setup_ge\@
    adds    \xll, \xll, #1                  // GT: lo = a + 1
    adcs    \xlh, \xlh, xzr                 // V iff a == INT128_MAX
    csetm   \xinv, vs                       // GT MAX: empty set
.Lpred128_setup_ge\@:
    mvn     \xsl, \xll                      // span = MAX - lo
    eor     \xsh, \xlh, #PQ_INT64_MAX
    b       .Lpred128_setup_done\@
.Lpred128_setup_bt\@:
    ldp     \xt1, \xt2, [\xpb]              // BETWEEN: b
    subs    \xsl, \xt1, \xll                // span = b - a; the flags of the
    sbcs    \xsh, \xt2, \xlh                // chain give b <s a (128-bit)
    csetm   \xinv, lt                       // a > b: empty set
    csinv   \xsl, \xsl, xzr, ge
    csinv   \xsh, \xsh, xzr, ge
.Lpred128_setup_done\@:
    .endm

/* CMPOP_CHECK wop, winv, invalid
 * compare_i64 operator validation: branches to `invalid` unless op is in
 * EQ..GE (BETWEEN and anything else are invalid; unsigned 32-bit compare as
 * in PRED_SETUP). Every op is reduced to EQ or GT plus an inversion bit:
 *   EQ = eq, NE = !eq, GT = gt, LE = !gt, LT = gt(swapped), GE = !gt(swapped)
 * so winv = op & 1 (NE, LE, GE are the inverted ops).
 * Out: winv (0/1). Clobbers flags. */
    .macro CMPOP_CHECK wop, winv, invalid
    cmp     \wop, #PQK_GE
    b.hi    \invalid
    and     \winv, \wop, #1                 // NE, LE, GE are inverted ops
    .endm

/* CMPOP_SWAP wop, xa, xb, xt
 * compare_i64 operand dispatch: swaps the column pointers xa/xb for LT and
 * GE, which turns them into GT and LE (see CMPOP_CHECK). Clobbers xt and
 * flags. */
    .macro CMPOP_SWAP wop, xa, xb, xt
    cmp     \wop, #PQK_LT
    b.eq    .Lcmpop_swap_do\@
    cmp     \wop, #PQK_GE
    b.ne    .Lcmpop_swap_done\@
.Lcmpop_swap_do\@:
    mov     \xt, \xa                        // LT / GE: swap -> GT / LE
    mov     \xa, \xb
    mov     \xb, \xt
.Lcmpop_swap_done\@:
    .endm

/* ======================================================================
 * 4. Scalar predicate evaluation and validity bits
 * ====================================================================== */

/* SPRED v, lo, span, inv : w<v> = pred(x<v>) in bit 0 (x<v> is clobbered).
 * Bits above bit 0 are garbage unless w<inv> is 0 or 1. */
    .macro SPRED v, lo, span, inv
    sub     x\v, x\v, x\lo
    cmp     x\v, x\span
    cset    w\v, ls
    eor     w\v, w\v, w\inv
    .endm

/* SPRED128 xl, xh, ll, lh, sl, sh, inv : w<xl> = pred(x<xh>:x<xl>), 0 or 1
 * when w<inv> is 0 or 1 (x<xl>, x<xh> are clobbered). The flags of
 * CMP span_lo, d_lo ; SBCS xzr, span_hi, d_hi are those of the 128-bit
 * subtraction span - d: no borrow (hs) <=> d <=u span. */
    .macro SPRED128 xl, xh, ll, lh, sl, sh, inv
    subs    x\xl, x\xl, x\ll                // d = x - lo (128-bit)
    sbc     x\xh, x\xh, x\lh
    cmp     x\sl, x\xl                      // span - d: no borrow <=> d <=u span
    sbcs    xzr, x\sh, x\xh
    cset    w\xl, hs
    eor     w\xl, w\xl, w\inv
    .endm

/* VBIT d, vp, i, t : w<d> bit 0 = validity bit of row x<i> (LSB-first bitmap
 * at x<vp>: byte i >> 3, bit i & 7). Upper bits of w<d> are garbage.
 * Clobbers x<t>. Reads exactly one byte, inside ceil(n/8) for i < n. */
    .macro VBIT d, vp, i, t
    lsr     x\d, x\i, #3
    ldrb    w\d, [x\vp, x\d]
    and     x\t, x\i, #7
    lsr     w\d, w\d, w\t
    .endm

/* AND_VBIT p, vp, i, d, t : w<p> &= validity bit of row x<i> when the
 * validity pointer x<vp> is not NULL (the NULL test is a perfectly predicted
 * branch). Clobbers x<d>, x<t>. */
    .macro AND_VBIT p, vp, i, d, t
    cbz     x\vp, .Land_vbit_done\@
    VBIT    \d, \vp, \i, \t
    and     w\p, w\p, w\d
.Land_vbit_done\@:
    .endm

/* ======================================================================
 * 5. Exact integer accumulation (sum_i64 / sum_i128)
 * ====================================================================== */

/* ADD128S lo, hi, x, t : (x<hi>:x<lo>) += sign-extended x<x>.
 * Clobbers x<t>. */
    .macro ADD128S lo, hi, x, t
    asr     x\t, x\x, #63
    adds    x\lo, x\lo, x\x
    adc     x\hi, x\hi, x\t
    .endm

/* ADD192S a0, a1, a2, xl, xh, t : (x<a2>:x<a1>:x<a0>) += sign-extended
 * 128-bit value x<xh>:x<xl>. Clobbers x<t>. */
    .macro ADD192S a0, a1, a2, xl, xh, t
    asr     x\t, x\xh, #63
    adds    x\a0, x\a0, x\xl
    adcs    x\a1, x\a1, x\xh
    adc     x\a2, x\a2, x\t
    .endm

/* FOLD_SUM64 alo, ahi, ulo, shi, t1, t2
 * sum_i64 block fold: (ahi:alo) += ulo + shi * 2^32 (128-bit), where ulo is
 * the unsigned sum of the low 32-bit halves and shi the signed sum of the
 * high halves of a block of int64 values. Clobbers t1, t2. */
    .macro FOLD_SUM64 alo, ahi, ulo, shi, t1, t2
    adds    \alo, \alo, \ulo
    adc     \ahi, \ahi, xzr
    lsl     \t1, \shi, #32                  // + hi * 2^32 (128-bit)
    asr     \t2, \shi, #32
    adds    \alo, \alo, \t1
    adc     \ahi, \ahi, \t2
    .endm

/* FOLD_LIMBS192 a0, a1, a2, l0, l1, l2, l3, t1, t2
 * sum_i128 block fold (NEON and SVE): (a2:a1:a0) += L0 + L1 * 2^32 +
 * L2 * 2^64 + L3 * 2^96 (192-bit), where the limb sums L0..L2 (unsigned)
 * and L3 (signed) are the 64-bit values in d16..d19; they are first moved
 * to the GPRs l0..l3. Clobbers l0-l3, t1, t2. */
    .macro FOLD_LIMBS192 a0, a1, a2, l0, l1, l2, l3, t1, t2
    fmov    \l0, d16                        // L0 (unsigned)
    fmov    \l1, d17                        // L1 (unsigned)
    fmov    \l2, d18                        // L2 (unsigned)
    fmov    \l3, d19                        // L3 (signed)
    adds    \a0, \a0, \l0                   // += L0
    adcs    \a1, \a1, xzr
    adc     \a2, \a2, xzr
    lsl     \t1, \l1, #32                   // += L1 << 32
    lsr     \t2, \l1, #32
    adds    \a0, \a0, \t1
    adcs    \a1, \a1, \t2
    adc     \a2, \a2, xzr
    adds    \a1, \a1, \l2                   // += L2 << 64
    adc     \a2, \a2, xzr
    lsl     \t1, \l3, #32                   // += L3 << 96 (sign-extended)
    asr     \t2, \l3, #32
    adds    \a1, \a1, \t1
    adc     \a2, \a2, \t2
    .endm

/* BLOCK_END xend, xi, xlimit, size : xend = min(xi + size, xlimit), the
 * end row of the next bounded accumulation block (size: an immediate
 * encodable by MOV, e.g. (1<<24)). Clobbers flags. */
    .macro BLOCK_END xend, xi, xlimit, size
    mov     \xend, #\size
    add     \xend, \xend, \xi
    cmp     \xend, \xlimit
    csel    \xend, \xend, \xlimit, lo
    .endm

/* SUM64_RESULT xlo, xhi, xout : result section of sum_i64. The exact sum is
 * the 128-bit value xhi:xlo; it fits in int64 iff xhi == sign(xlo). Then
 * *xout = xlo and PQK_OK is returned, else PQK_OVERFLOW (*xout untouched). */
    .macro SUM64_RESULT xlo, xhi, xout
    cmp     \xhi, \xlo, asr #63             // fits in int64 <=> hi == sign(lo)
    b.ne    .Lsum64_result_ovf\@
    str     \xlo, [\xout]
    RET_STATUS PQK_OK
.Lsum64_result_ovf\@:
    RET_STATUS PQK_OVERFLOW
    .endm

/* SUM128_RESULT xlo, xmid, xtop, xout : result section of sum_i128. The
 * exact sum is the 192-bit value xtop:xmid:xlo; it fits in int128 iff
 * xtop == sign(xmid). Then *xout = xmid:xlo and PQK_OK is returned, else
 * PQK_OVERFLOW (*xout untouched). */
    .macro SUM128_RESULT xlo, xmid, xtop, xout
    cmp     \xtop, \xmid, asr #63           // fits in int128 <=> top == sign(mid)
    b.ne    .Lsum128_result_ovf\@
    stp     \xlo, \xmid, [\xout]
    RET_STATUS PQK_OK
.Lsum128_result_ovf\@:
    RET_STATUS PQK_OVERFLOW
    .endm

/* ======================================================================
 * 6. Min / max
 * ====================================================================== */

/* A signed 128-bit value lives in a GPR pair (lo, hi). Comparisons use the
 * multi-word subtract chain  CMP lo ; SBCS xzr, hi  whose final flags are
 * those of the full 128-bit subtraction: C (hs/lo) is the unsigned and N^V
 * (ge/lt) the signed 128-bit ordering. Z only reflects the high word, so
 * eq/ne/gt/le are never used on such a chain.
 *
 * MIN128 ml, mh, xl, xh : (m) = min(m, x), signed 128-bit.
 * MAX128 ml, mh, xl, xh : (m) = max(m, x). */
    .macro MIN128 ml, mh, xl, xh
    cmp     x\xl, x\ml                      // x <s m ?
    sbcs    xzr, x\xh, x\mh
    csel    x\ml, x\xl, x\ml, lt
    csel    x\mh, x\xh, x\mh, lt
    .endm

    .macro MAX128 ml, mh, xl, xh
    cmp     x\ml, x\xl                      // m <s x ?
    sbcs    xzr, x\mh, x\xh
    csel    x\ml, x\xl, x\ml, lt
    csel    x\mh, x\xh, x\mh, lt
    .endm

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

/* MINMAX64_STEP mn, mx, cmin, cmax : signed int64 update
 * mn = min(mn, cmin), mx = max(mx, cmax) with CMP + CSEL lt / gt (X regs).
 * F64_MINMAX_STEP mn, mx, cmin, cmax : the same for doubles with FCMP +
 * FCSEL mi / gt, i.e. the reference's strict "<" / ">" (the first of equal
 * values wins, so signed zeros match the sequential order). */
    .macro MINMAX64_STEP mn, mx, cmin, cmax
    cmp     \cmin, \mn
    csel    \mn, \cmin, \mn, lt
    cmp     \cmax, \mx
    csel    \mx, \cmax, \mx, gt
    .endm

    .macro F64_MINMAX_STEP mn, mx, cmin, cmax
    fcmp    \cmin, \mn
    fcsel   \mn, \cmin, \mn, mi
    fcmp    \cmax, \mx
    fcsel   \mx, \cmax, \mx, gt
    .endm

/* MINMAX_RESULT cnt, rmin, rmax : result section of minmax_i64/minmax_f64:
 * if cnt > 0 store rmin to [x3] (out_min) and rmax to [x4] (out_max)
 * (X or D registers); return cnt. */
    .macro MINMAX_RESULT cnt, rmin, rmax
    cbz     \cnt, .Lminmax_result_ret\@
    str     \rmin, [x3]
    str     \rmax, [x4]
.Lminmax_result_ret\@:
    RET_X   \cnt
    .endm

/* MINMAX128_RESULT cnt, minl, minh, maxl, maxh : the same for minmax_i128
 * (16-byte outputs stored with STP). */
    .macro MINMAX128_RESULT cnt, minl, minh, maxl, maxh
    cbz     \cnt, .Lminmax128_result_ret\@
    stp     \minl, \minh, [x3]
    stp     \maxl, \maxh, [x4]
.Lminmax128_result_ret\@:
    RET_X   \cnt
    .endm

/* F64_FIRST_ZERO data, vp, i
 * Signed-zero fix-up of the SIMD minmax_f64 kernels. Lane-parallel
 * FMINNM/FMAXNM may return either sign for a zero result, whereas the
 * sequential reference returns the *first valid zero* in row order. If the
 * min (d0) or max (d1) is a zero, rows 0..n-1 (n in x2, data at x<data>,
 * validity at x<vp>, may be NULL) are scanned for the first valid +0.0 or
 * -0.0, which then replaces every zero result. Falls through in all cases.
 * Clobbers x<i>, x8, x12, x13, d4, flags. */
    .macro F64_FIRST_ZERO data, vp, i
    fcmp    d0, #0.0
    b.eq    .Lf64_first_zero_scan\@
    fcmp    d1, #0.0
    b.ne    .Lf64_first_zero_done\@
.Lf64_first_zero_scan\@:                    // reference returns the first valid zero
    mov     x\i, #0
.Lf64_first_zero_row\@:
    cmp     x\i, x2
    b.hs    .Lf64_first_zero_done\@
    ldr     x8, [x\data, x\i, lsl #3]
    lsl     x12, x8, #1                     // zero iff +0.0 or -0.0
    cbnz    x12, .Lf64_first_zero_next\@
    cbz     x\vp, .Lf64_first_zero_found\@
    VBIT    12, \vp, \i, 13
    tbnz    w12, #0, .Lf64_first_zero_found\@
.Lf64_first_zero_next\@:
    add     x\i, x\i, #1
    b       .Lf64_first_zero_row\@
.Lf64_first_zero_found\@:
    fmov    d4, x8
    fcmp    d0, #0.0
    fcsel   d0, d4, d0, eq
    fcmp    d1, #0.0
    fcsel   d1, d4, d1, eq
.Lf64_first_zero_done\@:
    .endm

/* ======================================================================
 * 7. Bitmaps and bit counting
 * ====================================================================== */

/* Scalar bitmap writer (row-at-a-time producers of an output bitmap:
 * scalar filter_i64_bitmap and compare_i64). State: x10 = row i,
 * x11 = count of set bits, w15 = output byte being built, w12 = predicate
 * bit (0/1) of row i.
 *
 * SBITMAP_PUT xout : ORs w12 into w15 at bit (i & 7), adds it to x11,
 * advances x10 to i + 1 and, when that completes a byte, stores w15 to
 * xout[i >> 3] and clears it. Clobbers x13, x14. */
    .macro SBITMAP_PUT xout
    and     x14, x10, #7
    lsl     w13, w12, w14
    orr     w15, w15, w13
    add     x11, x11, x12
    add     x10, x10, #1
    tst     x10, #7
    b.ne    .Lsbitmap_put_done\@
    lsr     x13, x10, #3                    // byte (i-1)/8 is complete
    sub     x13, x13, #1
    strb    w15, [\xout, x13]
    mov     w15, #0
.Lsbitmap_put_done\@:
    .endm

/* SBITMAP_FLUSH xout : after the last row (n in x2) stores the partial last
 * byte (bits above n % 8 are zero), if any. Clobbers x13. */
    .macro SBITMAP_FLUSH xout
    tst     x2, #7                          // partial last byte (zero padded)
    b.eq    .Lsbitmap_flush_done\@
    lsr     x13, x2, #3
    strb    w15, [\xout, x13]
.Lsbitmap_flush_done\@:
    .endm

/* BITOP_STEP8 insn : one 8-byte step of bitmap and/or/andnot
 * (x0 a, x1 b, x2 out post-incremented, x3 bytes left -= 8). Both inputs are
 * loaded before the store, so out may alias a or b. Clobbers x4, x5. */
    .macro BITOP_STEP8 insn
    ldr     x4, [x0], #8
    ldr     x5, [x1], #8
    \insn   x4, x4, x5
    str     x4, [x2], #8
    sub     x3, x3, #8
    .endm

/* BITOP_BYTES insn : byte tail and result section of bitmap
 * and/or/andnot: processes the x3 remaining bytes one at a time, then
 * returns. Clobbers x0-x5. */
    .macro BITOP_BYTES insn
.Lbitop_bytes_loop\@:
    cbz     x3, .Lbitop_bytes_done\@
    ldrb    w4, [x0], #1
    ldrb    w5, [x1], #1
    \insn   w4, w4, w5
    strb    w4, [x2], #1
    sub     x3, x3, #1
    b       .Lbitop_bytes_loop\@
.Lbitop_bytes_done\@:
    ret
    .endm

/* LOWBITS wm, wn : wm = (1 << wn) - 1 (mask of the low wn bits, wn <= 31). */
    .macro LOWBITS wm, wn
    mov     \wm, #1
    lsl     \wm, \wm, \wn
    sub     \wm, \wm, #1
    .endm

/* ADD_CNT8 b, tot : x<tot> += popcount(w<b>) for a zero-extended byte in
 * w<b>, using the Advanced SIMD CNT (NEON and SVE variants only).
 * Clobbers x<b>, v0. */
    .macro ADD_CNT8 b, tot
    fmov    s0, w\b
    cnt     v0.8b, v0.8b
    umov    w\b, v0.b[0]
    add     x\tot, x\tot, x\b
    .endm

/* ADD_POPCNT_LOW b, n, t, tot : x<tot> += popcount(w<b> & ((1 << w<n>) - 1))
 * (partial last byte of bitmap_popcount; NEON and SVE variants only).
 * Clobbers x<b>, x<t>, v0. */
    .macro ADD_POPCNT_LOW b, n, t, tot
    LOWBITS w\t, w\n
    and     w\b, w\b, w\t
    ADD_CNT8 \b, \tot
    .endm

/* ======================================================================
 * 8. Hashing (MurmurHash3 fmix64)
 * ====================================================================== */

/* LOAD_FMIX c1, c2 : x<c1> = PQ_FMIX_C1, x<c2> = PQ_FMIX_C2 (MOVZ/MOVK). */
    .macro LOAD_FMIX c1, c2
    movz    x\c1, #(PQ_FMIX_C1 & 0xffff)
    movk    x\c1, #((PQ_FMIX_C1 >> 16) & 0xffff), lsl #16
    movk    x\c1, #((PQ_FMIX_C1 >> 32) & 0xffff), lsl #32
    movk    x\c1, #((PQ_FMIX_C1 >> 48) & 0xffff), lsl #48
    movz    x\c2, #(PQ_FMIX_C2 & 0xffff)
    movk    x\c2, #((PQ_FMIX_C2 >> 16) & 0xffff), lsl #16
    movk    x\c2, #((PQ_FMIX_C2 >> 32) & 0xffff), lsl #32
    movk    x\c2, #((PQ_FMIX_C2 >> 48) & 0xffff), lsl #48
    .endm

/* FMIX1 k, seed, c1, c2 : x<k> = fmix64(x<k> ^ x<seed>) (one row). */
    .macro FMIX1 k, seed, c1, c2
    eor     x\k, x\k, x\seed
    eor     x\k, x\k, x\k, lsr #33
    mul     x\k, x\k, x\c1
    eor     x\k, x\k, x\k, lsr #33
    mul     x\k, x\k, x\c2
    eor     x\k, x\k, x\k, lsr #33
    .endm

/* ======================================================================
 * 9. Fixed-width comparison (compare_fixed)
 * ====================================================================== */

/* CFX_BYTES wa, wb, tail, eq : byte loop over the x5 bytes left in the
 * current record (x0/x1 post-incremented). Defines label `tail`. Branches to
 * `eq` when the record is equal; falls through with the flags of the first
 * differing byte pair (CMP wa, wb). */
    .macro CFX_BYTES wa, wb, tail, eq
\tail:
    cbz     x5, \eq
    ldrb    \wa, [x0], #1
    ldrb    \wb, [x1], #1
    sub     x5, x5, #1
    cmp     \wa, \wb
    b.eq    \tail
    .endm

/* CFX_RESULT wr, diff, eq, next, rec : per-record result of compare_fixed.
 * Defines labels `diff` (entered with the flags of an unsigned compare of
 * the first difference: stores -1 / 1 and skips the x5 unread bytes of the
 * record), `eq` (stores 0) and `next` (loops to `rec` while records remain
 * in x3). Output cursor x4. Clobbers wr. */
    .macro CFX_RESULT wr, diff, eq, next, rec
\diff:
    mov     \wr, #1
    cneg    \wr, \wr, lo                    // a < b -> -1, a > b -> 1
    strb    \wr, [x4], #1
    add     x0, x0, x5                      // skip rest of the record
    add     x1, x1, x5
    b       \next
\eq:
    strb    wzr, [x4], #1
\next:
    subs    x3, x3, #1
    b.ne    \rec
    .endm

/* ======================================================================
 * 10. Grouped aggregation (group_sum_i64)
 * ====================================================================== */

/* GSUM_ADD skip : scatter-add of one valid row in row order:
 * sums[w11] += x12 with the signed-overflow flag collected in w9 (CSINC on
 * V: w9 = 1 on wrap), counts[w11] += 1 unless counts (x5) is NULL, in which
 * case it branches to `skip`. x4 sums, x5 counts. Clobbers x13. */
    .macro GSUM_ADD skip
    ldr     x13, [x4, x11, lsl #3]
    adds    x13, x13, x12
    csinc   w9, w9, wzr, vc                 // w9 = 1 on signed wrap
    str     x13, [x4, x11, lsl #3]
    cbz     x5, \skip
    ldr     x13, [x5, x11, lsl #3]
    add     x13, x13, #1
    str     x13, [x5, x11, lsl #3]
    .endm

/* GSUM_ROWS : row-order accumulation loop of group_sum_i64 over rows
 * x10 .. x3-1 (x0 ids, x1 values, x2 validity or NULL). Invalid rows are
 * skipped; ids are already validated. Clobbers x10-x13, w9 (flag). */
    .macro GSUM_ROWS
.Lgsum_rows_row\@:
    cbz     x2, .Lgsum_rows_load\@
    VBIT    12, 2, 10, 13
    tbz     w12, #0, .Lgsum_rows_next\@
.Lgsum_rows_load\@:
    ldr     w11, [x0, x10, lsl #2]
    ldr     x12, [x1, x10, lsl #3]
    GSUM_ADD .Lgsum_rows_next\@
.Lgsum_rows_next\@:
    add     x10, x10, #1
    cmp     x10, x3
    b.lo    .Lgsum_rows_row\@
    .endm

/* ======================================================================
 * 11. Addressing
 * ====================================================================== */

/* LOADADDR xr, sym : xr = &sym (PC-relative ADRP + :lo12:, position
 * independent; works in static and shared builds without text relocations). */
    .macro LOADADDR xr, sym
    adrp    \xr, \sym
    add     \xr, \xr, :lo12:\sym
    .endm

#endif /* PQ_A64_COMMON_H */
