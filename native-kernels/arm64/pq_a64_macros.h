/*
 * pq_a64_macros.h — shared GNU as macros for the AArch64 PolyQuery kernels.
 *
 * Included (via the C preprocessor) by pq_a64_scalar.S and pq_a64_neon.S.
 * Contains no code by itself, only assembler macros:
 *
 *   FUNC / ENDF     global function prologue/epilogue directives
 *                   (.globl, .type %function, .p2align, .size).
 *   PRED_SETUP      converts a predicate (op, a, b) into the canonical
 *                   unsigned range form used by every predicate kernel:
 *
 *                       pred(x) = ((uint64)(x - lo) <= span) XOR inv
 *
 *                   lo/span are 64-bit, inv is 0 or all-ones. Mapping:
 *                     EQ      lo=a      span=0          inv=0
 *                     NE      lo=a      span=0          inv=-1
 *                     LT      lo=MIN    span=(a-1)-MIN  inv=(a==MIN ? -1 : 0)
 *                     LE      lo=MIN    span=a-MIN      inv=0
 *                     GT      lo=a+1    span=MAX-lo     inv=(a==MAX ? -1 : 0)
 *                     GE      lo=a      span=MAX-a      inv=0
 *                     BETWEEN lo=a      span=b-a        inv=0     (a <= b)
 *                             lo=a      span=~0         inv=-1    (a >  b: empty)
 *                   An "empty" predicate is encoded as span=~0 (always
 *                   true) inverted. Signed range membership x in [lo,hi]
 *                   is equivalent to (x-lo) <=u (hi-lo) when lo <= hi.
 *                   Branches to `invalid` when op is not in 0..6 (the op is
 *                   compared as an unsigned 32-bit value, so negative ints
 *                   are rejected too; the upper half of the X register is
 *                   ignored as AAPCS64 leaves it unspecified for `int`).
 *   SPRED           scalar evaluation of that predicate (register numbers).
 *   VBIT            scalar fetch of validity bit i (register numbers).
 *   LOAD_FMIX       materializes the two MurmurHash3 fmix64 multipliers.
 *   FMIX1           one scalar fmix64 round on a register.
 *
 * Register-number macros take bare numbers (e.g. `SPRED 12, 7, 8, 9`) so that
 * both the W and X views of a register can be named inside the macro.
 */

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

/* PRED_SETUP wop, xa, xb, xlo, xspan, xinv, xt, invalid
 * In: wop (int op), xa, xb. Out: xlo, xspan, xinv. Clobbers xt and flags.
 * All registers must be distinct. */
    .macro PRED_SETUP wop, xa, xb, xlo, xspan, xinv, xt, invalid
    cmp     \wop, #6
    b.hi    \invalid
    mov     \xlo, \xa
    mov     \xinv, #0
    mov     \xt, #0x8000000000000000        // INT64_MIN
    cmp     \wop, #1
    b.hi    .Lps_lt\@
    mov     \xspan, #0                      // EQ / NE: (x - a) <=u 0
    csetm   \xinv, eq                       // NE: inverted
    b       .Lps_done\@
.Lps_lt\@:
    cmp     \wop, #3
    b.hi    .Lps_gt\@
    sub     \xspan, \xa, #1
    csel    \xspan, \xspan, \xa, ne         // hi = (LT) ? a-1 : a
    ccmp    \xa, \xt, #0, ne                // LT with a == MIN -> empty set
    csetm   \xinv, eq
    eor     \xspan, \xspan, \xt             // span = hi - MIN
    mov     \xlo, \xt
    b       .Lps_done\@
.Lps_gt\@:
    cmp     \wop, #5
    b.hi    .Lps_bt\@
    add     \xlo, \xa, #1
    csel    \xlo, \xlo, \xa, ne             // lo = (GT) ? a+1 : a
    mvn     \xspan, \xt                     // INT64_MAX
    ccmp    \xa, \xspan, #0, ne             // GT with a == MAX -> empty set
    csetm   \xinv, eq
    sub     \xspan, \xspan, \xlo            // span = MAX - lo
    b       .Lps_done\@
.Lps_bt\@:
    sub     \xspan, \xb, \xa                // BETWEEN: span = b - a
    cmp     \xa, \xb
    csetm   \xinv, gt                       // a > b -> empty set
    csinv   \xspan, \xspan, xzr, le
.Lps_done\@:
    .endm

/* SPRED v, lo, span, inv : w<v> = pred(x<v>) in bit 0 (x<v> is clobbered).
 * Bits above bit 0 are garbage unless w<inv> is 0 or 1. */
    .macro SPRED v, lo, span, inv
    sub     x\v, x\v, x\lo
    cmp     x\v, x\span
    cset    w\v, ls
    eor     w\v, w\v, w\inv
    .endm

/* VBIT d, vp, i, t : w<d> bit 0 = validity bit of row x<i> (bitmap at x<vp>).
 * Upper bits of w<d> are garbage. Clobbers x<t>. */
    .macro VBIT d, vp, i, t
    lsr     x\d, x\i, #3
    ldrb    w\d, [x\vp, x\d]
    and     x\t, x\i, #7
    lsr     w\d, w\d, w\t
    .endm

/* LOAD_FMIX c1, c2 : x<c1> = 0xff51afd7ed558ccd, x<c2> = 0xc4ceb9fe1a85ec53 */
    .macro LOAD_FMIX c1, c2
    movz    x\c1, #0x8ccd
    movk    x\c1, #0xed55, lsl #16
    movk    x\c1, #0xafd7, lsl #32
    movk    x\c1, #0xff51, lsl #48
    movz    x\c2, #0xec53
    movk    x\c2, #0x1a85, lsl #16
    movk    x\c2, #0xb9fe, lsl #32
    movk    x\c2, #0xc4ce, lsl #48
    .endm

/* FMIX1 k, seed, c1, c2 : x<k> = fmix64(x<k> ^ x<seed>) */
    .macro FMIX1 k, seed, c1, c2
    eor     x\k, x\k, x\seed
    eor     x\k, x\k, x\k, lsr #33
    mul     x\k, x\k, x\c1
    eor     x\k, x\k, x\k, lsr #33
    mul     x\k, x\k, x\c2
    eor     x\k, x\k, x\k, lsr #33
    .endm
