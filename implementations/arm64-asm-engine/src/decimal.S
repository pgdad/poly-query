// =============================================================================
// decimal.S — fixed-point DECIMAL(p,s) support.
//
// A DECIMAL payload is the unscaled i64 value v; the number is v / 10^s.
// Valid values satisfy |v| <= 10^18 - 1 and |v| < 10^p.
//
// Functions:
//   pow10_i64(w0 n)                              -> x0 10^n (n = 0..18)
//   dec_fits(x0 v, w1 p)                         -> w0 1 if |v| < 10^p
//   dec_rescale(x0 v, w1 from, w2 to)            -> x0, w1 status (2 overflow)
//   dec_to_f64(x0 v, w1 s)                       -> d0 (correctly rounded)
//   f64_to_dec(d0 x, w1 p, w2 s)                 -> x0, w1 status (2 overflow)
//   fmt_decimal(x0 Buf*, x1 v, w2 s)             -> canonical text
//   parse_decimal(x0 ptr, x1 len, w2 p, w3 s, w4 mode) -> x0, w1 status
// =============================================================================
#include "pq.inc"

#define POW10_17 100000000000000000

    .section .rodata
    .p2align 3
// 10^0 .. 10^18 as integers
    .global pow10_tab
pow10_tab:
    .quad 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000
    .quad 1000000000, 10000000000, 100000000000, 1000000000000
    .quad 10000000000000, 100000000000000, 1000000000000000
    .quad 10000000000000000, 100000000000000000, 1000000000000000000
// 10^0 .. 10^18 as doubles (all exactly representable)
f64_pow10_tab:
    .double 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10
    .double 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18
f64_1e19:
    .double 1e19
fmt_dec_exp:    .asciz "%lde-%u"     // v e-s  : exact decimal for strtod
fmt_fixed:      .asciz "%.*f"
    .text

// -----------------------------------------------------------------------------
// pow10_i64(w0 n) -> x0 10^n     (leaf; n must be 0..18)
// -----------------------------------------------------------------------------
FUNC pow10_i64
    ADR_L x9, pow10_tab
    ldr  x0, [x9, w0, uxtw #3]
    ret
ENDF pow10_i64

// -----------------------------------------------------------------------------
// dec_fits(x0 v, w1 p) -> w0 1 if |v| < 10^p else 0     (leaf)
// p > 18 is treated as "always fits" (any i64 decimal has <= 19 digits but
// valid precisions never exceed 18). INT64_MIN negates to 2^63 (unsigned),
// which never fits.
// -----------------------------------------------------------------------------
FUNC dec_fits
    cmp  w1, #18
    b.hi 1f
    ADR_L x9, pow10_tab
    ldr  x9, [x9, w1, uxtw #3]
    cmp  x0, #0
    cneg x0, x0, lt                 // |v| as unsigned
    cmp  x0, x9
    cset w0, lo
    ret
1:  mov  w0, #1
    ret
ENDF dec_fits

// -----------------------------------------------------------------------------
// dec_rescale(x0 v, w1 from_scale, w2 to_scale) -> x0 v', w1 status   (leaf)
// Scaling up multiplies by 10^(to-from) (status 2 if the result needs more
// than 18 digits); scaling down divides and rounds half away from zero.
// Registers: x9 10^diff, x10 result, x11/x12 scratch.
// -----------------------------------------------------------------------------
FUNC dec_rescale
    cmp  w2, w1
    b.eq 8f
    b.lt 3f
    // ---- scale up
    sub  w9, w2, w1
    cmp  w9, #18
    b.hi 2f
    ADR_L x10, pow10_tab
    ldr  x9, [x10, w9, uxtw #3]
    mul  x10, x0, x9
    smulh x11, x0, x9
    cmp  x11, x10, asr #63          // 128-bit product fits in 64 bits?
    b.ne 2f
    cmp  x10, #0
    cneg x11, x10, lt
    ldr  x12, =MAX_DEC_UNSCALED
    cmp  x11, x12
    b.hi 2f
    mov  x0, x10
    b    8f
2:  mov  x0, #0                     // overflow
    mov  w1, #2
    ret
    // ---- scale down (round half away from zero)
3:  sub  w9, w1, w2
    cmp  w9, #18
    b.hi 5f
    ADR_L x10, pow10_tab
    ldr  x9, [x10, w9, uxtw #3]
    sdiv x10, x0, x9                // truncated quotient
    msub x11, x10, x9, x0           // remainder (sign of v)
    cmp  x11, #0
    cneg x11, x11, lt
    lsl  x11, x11, #1               // 2*|r| (|r| < 10^18, no overflow)
    cmp  x11, x9
    b.lo 4f
    mov  x12, #1
    cmp  x0, #0
    cneg x12, x12, lt
    add  x10, x10, x12              // away from zero
4:  mov  x0, x10
    b    8f
5:  mov  x0, #0                     // dividing by >= 10^19: |v| / 10^d < 1/2
8:  mov  w1, #0
    ret
ENDF dec_rescale

// -----------------------------------------------------------------------------
// dec_to_f64(x0 v, w1 s) -> d0 nearest binary64 of v / 10^s
// Fast path (exact operands, single correctly-rounded IEEE operation):
//   s == 0, or |v| <= 2^53 (then v and 10^s <= 10^18 are exact doubles and one
//   division is correctly rounded). Otherwise the value is printed as
//   "<v>e-<s>" and converted with strtod, which rounds correctly.
// -----------------------------------------------------------------------------
FUNC dec_to_f64
    scvtf d0, x0
    cbz  w1, 1f
    cmp  x0, #0
    cneg x9, x0, lt
    mov  x10, #(1 << 53)
    cmp  x9, x10
    b.hi 2f
    cmp  w1, #18
    b.hi 2f
    ADR_L x9, f64_pow10_tab
    ldr  d1, [x9, w1, uxtw #3]
    fdiv d0, d0, d1
1:  ret
2:  stp  x29, x30, [sp, #-64]!      // slow path: char buf[48] at sp+16
    mov  x29, sp
    mov  x3, x0
    mov  w4, w1
    add  x0, sp, #16
    mov  x1, #48
    ADR_L x2, fmt_dec_exp
    bl   snprintf
    add  x0, sp, #16
    mov  x1, #0
    bl   strtod
    ldp  x29, x30, [sp], #64
    ret
ENDF dec_to_f64

// -----------------------------------------------------------------------------
// f64_to_dec(d0 x, w1 p, w2 s) -> x0 unscaled, w1 status (2 overflow/non-finite)
// Rounds half away from zero on the *exact* binary value of x.
//
// Method: print x with "%.*f" and s+40 fractional digits (glibc prints the
// exact expansion, correctly rounded at the last digit). For |x| >= 10^-s/2
// a double differs from a rounding tie (k+1/2)*10^-s by at least ~2^-114 *
// 10^-s unless it *is* the tie, so 40 extra digits always classify the tail
// correctly: round away iff the first dropped digit is >= 5.
// Registers: x19 p, x20 s, x21 cursor, x22 accumulator, x23 overflow flag,
//            x24 negative flag. Text buffer: 128 bytes at sp+64.
// -----------------------------------------------------------------------------
FUNC f64_to_dec
    stp  x29, x30, [sp, #-192]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  w19, w1
    mov  w20, w2
    // reject non-finite and |x| >= 1e19 (can never fit 18 digits)
    fabs d1, d0
    ADR_L x9, f64_1e19
    ldr  d2, [x9]
    fcmp d1, d2
    b.hs 9f                         // >=, or unordered (NaN)
    add  x0, sp, #64
    mov  x1, #128
    ADR_L x2, fmt_fixed
    add  w3, w20, #40               // precision (int vararg)
    bl   snprintf                   // d0 still holds x
    add  x21, sp, #64
    mov  x22, #0
    mov  x23, #0
    mov  x24, #0
    ldrb w9, [x21]
    cmp  w9, #'-'
    b.ne 1f
    mov  x24, #1
    add  x21, x21, #1
1:  ldr  x10, =POW10_17
    mov  x11, #10
    // integer digits up to '.'
2:  ldrb w9, [x21], #1
    cmp  w9, #'.'
    b.eq 4f
    sub  w9, w9, #'0'
    cmp  x22, x10                   // acc >= 10^17 => next digit overflows
    b.lo 3f
    mov  x23, #1
    b    2b
3:  madd x22, x22, x11, x9
    b    2b
    // s fractional digits
4:  mov  w12, w20
5:  cbz  w12, 7f
    ldrb w9, [x21], #1
    sub  w9, w9, #'0'
    sub  w12, w12, #1
    cmp  x22, x10
    b.lo 6f
    mov  x23, #1
    b    5b
6:  madd x22, x22, x11, x9
    b    5b
    // round on the first dropped digit
7:  ldrb w9, [x21]
    cmp  w9, #'5'
    cinc x22, x22, hs
    cbnz x23, 9f
    mov  x0, x22
    mov  w1, w19
    bl   dec_fits
    cbz  w0, 9f
    mov  x0, x22
    cmp  x24, #0
    cneg x0, x0, ne
    mov  w1, #0
    b    10f
9:  mov  x0, #0
    mov  w1, #2
10: ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #192
    ret
ENDF f64_to_dec

// -----------------------------------------------------------------------------
// fmt_decimal(x0 Buf*, x1 v, w2 s): canonical text — exactly s fractional
// digits, '-' for negatives, at least one integer digit ("-0.50", "12").
// Registers: x19 Buf*, x20 v, x21 s, x22 digit count. Digits are produced
// backwards into a 32-byte scratch area at [sp+64, sp+96); [sp+48] holds
// the total output length across the buf_reserve call.
// -----------------------------------------------------------------------------
FUNC fmt_decimal
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    cmp  x1, #0
    cneg x9, x1, lt                 // |v| (unsigned; handles INT64_MIN)
    add  x10, sp, #96               // write cursor (backwards)
    mov  x22, #0
    mov  x11, #10
    add  w12, w21, #1               // minimum number of digits
1:  udiv x13, x9, x11
    msub x14, x13, x11, x9
    add  w14, w14, #'0'
    strb w14, [x10, #-1]!
    add  x22, x22, #1
    mov  x9, x13
    cbnz x9, 1b
    cmp  x22, x12
    b.lo 1b                         // zero padding (x9 is 0 => '0')
    // total = neg + digits + (s > 0)
    lsr  x1, x20, #63
    add  x1, x1, x22
    cmp  w21, #0
    cinc x1, x1, ne
    str  x1, [sp, #48]              // total length (spare slot)
    mov  x0, x19
    bl   buf_reserve
    ldr  x1, [sp, #48]
    add  x9, sp, #96
    sub  x10, x9, x22               // first digit
    tbz  x20, #63, 2f
    mov  w13, #'-'
    strb w13, [x0], #1
2:  sub  x12, x22, x21              // integer digits (>= 1)
3:  ldrb w13, [x10], #1
    strb w13, [x0], #1
    subs x12, x12, #1
    b.ne 3b
    cbz  w21, 5f
    mov  w13, #'.'
    strb w13, [x0], #1
    mov  w12, w21
4:  ldrb w13, [x10], #1
    strb w13, [x0], #1
    subs w12, w12, #1
    b.ne 4b
5:  ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, x1
    str  x9, [x19, #BUF_LEN]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #96
    ret
ENDF fmt_decimal

// -----------------------------------------------------------------------------
// parse_decimal(x0 ptr, x1 len, w2 p, w3 s, w4 mode) -> x0 unscaled, w1 status
// Syntax ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ (no trimming).
// status: 1 syntax, 2 does not fit precision p, 3 more than s fractional
// digits (mode 0 = exact/ingestion only). mode 1 rounds half away from zero.
// Precedence: 1, then 3, then 2.                                       (leaf)
// Registers: x0 cursor, x1 end, x5 negative, x6/x7 integer digits [x6,x7),
//   x8/x10 fraction digits [x8,x10), x11 accumulator, x12 overflow flag,
//   x13 10^17, x14 10, x15 frac digits to take, w9 current byte.
// -----------------------------------------------------------------------------
// APPEND_DIGIT d: acc = acc*10 + d, or set the overflow flag when the result
// would reach 10^18 (never representable in DECIMAL).
.macro APPEND_DIGIT d
    cmp  x11, x13
    b.lo 7771f
    mov  x12, #1
    b    7772f
7771: madd x11, x11, x14, \d
7772:
.endm

FUNC parse_decimal
    mov  w3, w3                     // zero-extend s
    add  x1, x0, x1
    mov  x5, #0
    cmp  x0, x1
    b.eq 90f
    ldrb w9, [x0]
    cmp  w9, #'-'
    b.ne 1f
    mov  x5, #1
    add  x0, x0, #1
    b    2f
1:  cmp  w9, #'+'
    b.ne 2f
    add  x0, x0, #1
2:  mov  x6, x0                     // integer digits
3:  cmp  x0, x1
    b.eq 4f
    ldrb w9, [x0]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi 4f
    add  x0, x0, #1
    b    3b
4:  mov  x7, x0
    mov  x8, x0                     // empty fraction by default
    mov  x10, x0
    cmp  x0, x1
    b.eq 6f
    ldrb w9, [x0]
    cmp  w9, #'.'
    b.ne 90f
    add  x0, x0, #1
    mov  x8, x0
5:  cmp  x0, x1
    b.eq 51f
    ldrb w9, [x0]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi 90f                        // trailing garbage
    add  x0, x0, #1
    b    5b
51: mov  x10, x0
6:  cmp  x6, x7                     // at least one digit overall
    b.ne 7f
    cmp  x8, x10
    b.eq 90f
7:  // syntax ok. mode 0: too many fractional digits?
    sub  x15, x10, x8               // nf
    cmp  x15, x3
    b.ls 8f
    cbnz w4, 8f
    mov  x0, #0
    mov  w1, #3
    ret
8:  ldr  x13, =POW10_17
    mov  x14, #10
    mov  x11, #0
    mov  x12, #0
    // integer part
10: cmp  x6, x7
    b.eq 11f
    ldrb w9, [x6], #1
    sub  w9, w9, #'0'
    APPEND_DIGIT x9
    b    10b
11: // first min(nf, s) fraction digits
    cmp  x15, x3
    csel x15, x15, x3, ls
    sub  x16, x3, x15               // zero digits to append (s - taken)
12: cbz  x15, 13f
    ldrb w9, [x8], #1
    sub  w9, w9, #'0'
    APPEND_DIGIT x9
    sub  x15, x15, #1
    b    12b
13: cbz  x16, 14f
    APPEND_DIGIT xzr
    sub  x16, x16, #1
    b    13b
14: // mode 1: round on the first dropped digit (x8 now points at it)
    cmp  x8, x10
    b.hs 15f
    ldrb w9, [x8]
    cmp  w9, #'5'
    cinc x11, x11, hs
15: cbnz x12, 91f
    cmp  w2, #18
    b.hi 16f
    ADR_L x9, pow10_tab
    ldr  x9, [x9, w2, uxtw #3]
    cmp  x11, x9
    b.hs 91f
16: cmp  x5, #0
    cneg x0, x11, ne
    mov  w1, #0
    ret
90: mov  x0, #0
    mov  w1, #1
    ret
91: mov  x0, #0
    mov  w1, #2
    ret
ENDF parse_decimal

    NOTE_GNU_STACK
