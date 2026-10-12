// =============================================================================
// wdec.S — wide DECIMAL support (CR-2, decimal38.md): DECIMAL(p,s) with
// 18 < p <= 38. A wide payload is a pointer to a boxed i128 (two's
// complement, little-endian: [0] low word, [8] high word); narrow decimals
// and INT64 stay i64 payloads (pq.inc).
//
// Exact intermediates use a 256-bit two's-complement integer kept in memory
// (4 u64 limbs, least significant first; "I256" below). 256 bits hold every
// intermediate the engine needs: a product of two 38-digit values (76
// digits), a 38-digit value rescaled by 10^38, sums of 2^64 values.
//
// Value-level API (types are full type words; INT64 counts as scale 0):
//   dec_get128(x0 payload, w1 type)          -> x0 lo, x1 hi      (leaf)
//   dec_put128(x0 lo, x1 hi, w2 type)        -> x0 payload (boxes if wide)
//   dec_box(x0 lo, x1 hi)                    -> x0 i128* (request arena)
//   dec_box_in(x0 Arena*, x1 lo, x2 hi)      -> x0 i128*
//   dec_cmp(x0 a, w1 ta, x2 b, w3 tb)        -> w0 -1/0/1 exact
//   dec_arith(x0 a, x1 b, w2 op, w3 ta, w4 tb, w5 result type) -> x0
//       + - * with a wide result type; raises NUMERIC_OVERFLOW
//   dec_convert(x0 payload, w1 from, w2 to, w3 mode) -> x0, w1 status
//       INT64 / DECIMAL -> DECIMAL. mode 0 rounds half away from zero (CAST),
//       mode 1 requires an exact result (status 3 otherwise). status 2: does
//       not fit the target precision (with T_SATF in `to`: saturates, 0)
//   dec_to_int(x0 payload, w1 type)          -> x0, w1 status (2 overflow)
//   dec_to_double(x0 payload, w1 type)       -> d0 nearest binary64
//   dec_from_f64(d0 x, w1 type)              -> x0 payload, w1 status
//   dec_neg(x0 payload, w1 type) / dec_abs   -> x0 payload (wide only)
//   dec_round(x0 payload, w1 type, x2 n, w3 result type) -> x0
//   dec_floorceil(x0 payload, w1 type, w2 ceil, w3 result type) -> x0
//   dec_hash(x0 i128*)                       -> x0 64-bit hash
//   parse_dec128(x0 ptr, x1 len, w2 p, w3 s, w4 mode) -> x0 lo, x1 hi,
//       w2 status — the parse_decimal rules (decimal.S) for p <= 38
//   fmt_dec128(x0 Buf*, x1 lo, x2 hi, w3 s)   canonical text
//   i256 helpers (pointer arguments): i256_from128, i256_neg, i256_add,
//   i256_mul_pow10, i256_div_pow10, i256_cmp, i256_to128, i256_to_f64,
//   i256_mul128, i256_fmt
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .section .rodata
    .p2align 4
// 10^0 .. 10^38 as u128 (lo, hi)
    .global p10_128
p10_128:
    .quad 0x0000000000000001, 0x0000000000000000   // 10^0
    .quad 0x000000000000000a, 0x0000000000000000   // 10^1
    .quad 0x0000000000000064, 0x0000000000000000   // 10^2
    .quad 0x00000000000003e8, 0x0000000000000000   // 10^3
    .quad 0x0000000000002710, 0x0000000000000000   // 10^4
    .quad 0x00000000000186a0, 0x0000000000000000   // 10^5
    .quad 0x00000000000f4240, 0x0000000000000000   // 10^6
    .quad 0x0000000000989680, 0x0000000000000000   // 10^7
    .quad 0x0000000005f5e100, 0x0000000000000000   // 10^8
    .quad 0x000000003b9aca00, 0x0000000000000000   // 10^9
    .quad 0x00000002540be400, 0x0000000000000000   // 10^10
    .quad 0x000000174876e800, 0x0000000000000000   // 10^11
    .quad 0x000000e8d4a51000, 0x0000000000000000   // 10^12
    .quad 0x000009184e72a000, 0x0000000000000000   // 10^13
    .quad 0x00005af3107a4000, 0x0000000000000000   // 10^14
    .quad 0x00038d7ea4c68000, 0x0000000000000000   // 10^15
    .quad 0x002386f26fc10000, 0x0000000000000000   // 10^16
    .quad 0x016345785d8a0000, 0x0000000000000000   // 10^17
    .quad 0x0de0b6b3a7640000, 0x0000000000000000   // 10^18
    .quad 0x8ac7230489e80000, 0x0000000000000000   // 10^19
    .quad 0x6bc75e2d63100000, 0x0000000000000005   // 10^20
    .quad 0x35c9adc5dea00000, 0x0000000000000036   // 10^21
    .quad 0x19e0c9bab2400000, 0x000000000000021e   // 10^22
    .quad 0x02c7e14af6800000, 0x000000000000152d   // 10^23
    .quad 0x1bcecceda1000000, 0x000000000000d3c2   // 10^24
    .quad 0x161401484a000000, 0x0000000000084595   // 10^25
    .quad 0xdcc80cd2e4000000, 0x000000000052b7d2   // 10^26
    .quad 0x9fd0803ce8000000, 0x00000000033b2e3c   // 10^27
    .quad 0x3e25026110000000, 0x00000000204fce5e   // 10^28
    .quad 0x6d7217caa0000000, 0x00000001431e0fae   // 10^29
    .quad 0x4674edea40000000, 0x0000000c9f2c9cd0   // 10^30
    .quad 0xc0914b2680000000, 0x0000007e37be2022   // 10^31
    .quad 0x85acef8100000000, 0x000004ee2d6d415b   // 10^32
    .quad 0x38c15b0a00000000, 0x0000314dc6448d93   // 10^33
    .quad 0x378d8e6400000000, 0x0001ed09bead87c0   // 10^34
    .quad 0x2b878fe800000000, 0x0013426172c74d82   // 10^35
    .quad 0xb34b9f1000000000, 0x00c097ce7bc90715   // 10^36
    .quad 0x00f436a000000000, 0x0785ee10d5da46d9   // 10^37
    .quad 0x098a224000000000, 0x4b3b4ca85a86c47a   // 10^38
fmt_exp:    .asciz "e-%u"
fmt_fixed:  .asciz "%.*f"
    .p2align 3
f64_1e39:   .double 1e39
    .text

// SCALE_OF wdst, wtype: scale of a DECIMAL type, 0 for any other kind
.macro SCALE_OF d, t
    and  \d, \t, #T_KIND_MASK
    cmp  \d, #T_DEC
    ubfx \d, \t, #T_SCALE_SHIFT, #8
    csel \d, \d, wzr, eq
.endm

// =============================================================================
// Boxing
// =============================================================================

// dec_get128(x0 payload, w1 type) -> x0 lo, x1 hi   (leaf)
FUNC dec_get128
    BR_WIDE w1, w9, 1f
    asr  x1, x0, #63
    ret
1:  ldp  x0, x1, [x0]
    ret
ENDF dec_get128

// dec_box(x0 lo, x1 hi) -> x0 pointer to a fresh i128 in the request arena
FUNC dec_box
    ENTER 1
    stp  x0, x1, [sp, #-16]!
    mov  x0, #16
    bl   arena_alloc
    ldp  x9, x10, [sp], #16
    stp  x9, x10, [x0]
    LEAVE 1
ENDF dec_box

// dec_box_in(x0 Arena*, x1 lo, x2 hi) -> x0 i128* in that arena
FUNC dec_box_in
    ENTER 1
    stp  x1, x2, [sp, #-16]!
    mov  x1, #16
    bl   arena_alloc_in
    ldp  x9, x10, [sp], #16
    stp  x9, x10, [x0]
    LEAVE 1
ENDF dec_box_in

// dec_put128(x0 lo, x1 hi, w2 type) -> x0 payload: boxed if the type is wide
FUNC dec_put128
    BR_WIDE w2, w9, dec_box
    ret
ENDF dec_put128

// dec_hash(x0 i128*) -> x0 hash of the 16 bytes   (leaf-like: tail call)
FUNC dec_hash
    ldp  x9, x10, [x0]
    ldr  x11, =0x9e3779b97f4a7c15
    mul  x10, x10, x11
    eor  x0, x9, x10, ror #29
    b    mix64
ENDF dec_hash

// =============================================================================
// 256-bit integer primitives (x0 = I256*)
// =============================================================================

// i256_from128(x0 dst, x1 lo, x2 hi)   (leaf)
FUNC i256_from128
    asr  x3, x2, #63
    stp  x1, x2, [x0]
    stp  x3, x3, [x0, #16]
    ret
ENDF i256_from128

// i256_neg(x0 p)   (leaf)
FUNC i256_neg
    ldp  x1, x2, [x0]
    ldp  x3, x4, [x0, #16]
    negs x1, x1
    ngcs x2, x2
    ngcs x3, x3
    ngc  x4, x4
    stp  x1, x2, [x0]
    stp  x3, x4, [x0, #16]
    ret
ENDF i256_neg

// i256_add(x0 dst, x1 src): dst += src   (leaf)
FUNC i256_add
    ldp  x2, x3, [x0]
    ldp  x4, x5, [x0, #16]
    ldp  x6, x7, [x1]
    ldp  x8, x9, [x1, #16]
    adds x2, x2, x6
    adcs x3, x3, x7
    adcs x4, x4, x8
    adc  x5, x5, x9
    stp  x2, x3, [x0]
    stp  x4, x5, [x0, #16]
    ret
ENDF i256_add

// i256_sub(x0 dst, x1 src): dst -= src   (leaf)
FUNC i256_sub
    ldp  x2, x3, [x0]
    ldp  x4, x5, [x0, #16]
    ldp  x6, x7, [x1]
    ldp  x8, x9, [x1, #16]
    subs x2, x2, x6
    sbcs x3, x3, x7
    sbcs x4, x4, x8
    sbc  x5, x5, x9
    stp  x2, x3, [x0]
    stp  x4, x5, [x0, #16]
    ret
ENDF i256_sub

// i256_cmp(x0 a, x1 b) -> w0 -1/0/1 (signed)   (leaf)
FUNC i256_cmp
    ldr  x2, [x0, #24]
    ldr  x3, [x1, #24]
    cmp  x2, x3
    b.ne 2f
    ldr  x2, [x0, #16]
    ldr  x3, [x1, #16]
    cmp  x2, x3
    b.ne 1f
    ldr  x2, [x0, #8]
    ldr  x3, [x1, #8]
    cmp  x2, x3
    b.ne 1f
    ldr  x2, [x0]
    ldr  x3, [x1]
    cmp  x2, x3
1:  cset w0, hi                         // unsigned lower limbs
    csinv w0, w0, wzr, hs
    ret
2:  cset w0, gt                         // signed top limb
    csinv w0, w0, wzr, ge
    ret
ENDF i256_cmp

// u256_mul_u64(x0 p, x1 m): p *= m modulo 2^256 (unsigned)   (leaf)
LFUNC u256_mul_u64
    ldp  x2, x3, [x0]
    ldp  x4, x5, [x0, #16]
    mul  x6, x2, x1
    umulh x7, x2, x1
    mul  x8, x3, x1
    umulh x9, x3, x1
    mul  x10, x4, x1
    umulh x11, x4, x1
    mul  x12, x5, x1
    adds x8, x8, x7
    adcs x10, x10, x9
    adc  x12, x12, x11
    stp  x6, x8, [x0]
    stp  x10, x12, [x0, #16]
    ret
ENDF u256_mul_u64

// u256_divmod_u32(x0 p, w1 d) -> x0 remainder; p = p / d (unsigned, d < 2^32)
// (leaf) Long division over the eight 32-bit limbs, most significant first.
LFUNC u256_divmod_u32
    mov  w1, w1
    mov  x2, #0                         // remainder
    mov  x3, #28                        // byte offset of the limb
1:  ldr  w4, [x0, x3]
    orr  x4, x4, x2, lsl #32
    udiv x5, x4, x1
    msub x2, x5, x1, x4
    str  w5, [x0, x3]
    subs x3, x3, #4
    b.pl 1b
    mov  x0, x2
    ret
ENDF u256_divmod_u32

// i256_mul_pow10(x0 p, w1 k): p *= 10^k (signed; the caller guarantees the
// product fits 256 bits)
//   x19 p, w20 k left, x21 sign
FUNC i256_mul_pow10
    cbz  w1, 9f
    ENTER 2
    mov  x19, x0
    mov  w20, w1
    ldr  x21, [x19, #24]
    lsr  x21, x21, #63
    cbz  x21, 1f
    bl   i256_neg
1:  cmp  w20, #19
    b.lo 2f
    mov  x0, x19
    ADR_L x9, p10_128
    ldr  x1, [x9, #(19 * 16)]
    bl   u256_mul_u64
    sub  w20, w20, #19
    b    1b
2:  cbz  w20, 3f
    mov  x0, x19
    ADR_L x9, p10_128
    lsl  w10, w20, #4
    ldr  x1, [x9, w10, uxtw]
    bl   u256_mul_u64
3:  cbz  x21, 4f
    mov  x0, x19
    bl   i256_neg
4:  LEAVE 2
9:  ret
ENDF i256_mul_pow10

// i256_div_pow10(x0 p, w1 k, w2 mode) -> w0 1 if the dropped digits were not
// all zero. p = p / 10^k rounded per mode: 0 toward zero, 1 half away from
// zero, 2 floor, 3 ceiling.
//   x19 p, w20 digits left, w21 mode, x22 sign, x23 nonzero flag, x24 last
//   dropped digit
FUNC i256_div_pow10
    cbnz w1, 1f
    mov  w0, #0
    ret
1:  ENTER 3
    mov  x19, x0
    sub  w20, w1, #1                    // all but the last dropped digit
    mov  w21, w2
    ldr  x22, [x19, #24]
    lsr  x22, x22, #63
    mov  x23, #0
    cbz  x22, 2f
    bl   i256_neg                       // magnitude
2:  cmp  w20, #9
    b.lo 3f
    mov  x0, x19
    ldr  w1, =1000000000
    bl   u256_divmod_u32
    orr  x23, x23, x0
    sub  w20, w20, #9
    b    2b
3:  cbz  w20, 4f
    mov  x0, x19
    ADR_L x9, p10_128
    lsl  w10, w20, #4
    ldr  x1, [x9, w10, uxtw]
    bl   u256_divmod_u32
    orr  x23, x23, x0
4:  mov  x0, x19
    mov  w1, #10
    bl   u256_divmod_u32
    mov  x24, x0
    orr  x23, x23, x24                  // any dropped digit non-zero
    mov  w9, #0                         // increment the magnitude?
    cmp  w21, #1
    b.ne 5f
    cmp  x24, #5
    cset w9, hs
    b    7f
5:  cmp  w21, #2
    b.ne 6f
    cmp  x23, #0                        // floor: negative and inexact
    cset w9, ne
    and  w9, w9, w22
    b    7f
6:  cmp  w21, #3
    b.ne 7f
    cmp  x23, #0                        // ceiling: positive and inexact
    cset w9, ne
    bic  w9, w9, w22
7:  cbz  w9, 8f
    ldp  x1, x2, [x19]
    ldp  x3, x4, [x19, #16]
    adds x1, x1, #1
    adcs x2, x2, xzr
    adcs x3, x3, xzr
    adc  x4, x4, xzr
    stp  x1, x2, [x19]
    stp  x3, x4, [x19, #16]
8:  cbz  x22, 9f
    mov  x0, x19
    bl   i256_neg
9:  cmp  x23, #0
    cset w0, ne
    LEAVE 3
ENDF i256_div_pow10

// i256_to128(x0 p, w1 prec) -> x0 lo, x1 hi, w2 1 if |p| < 10^prec (and
// therefore fits i128; prec <= 38)   (leaf)
FUNC i256_to128
    ldp  x3, x4, [x0]
    ldp  x5, x6, [x0, #16]
    asr  x7, x4, #63                    // upper limbs = sign extension?
    cmp  x5, x7
    ccmp x6, x7, #0, eq
    b.ne 8f
    mov  x8, x3                         // magnitude (x8, x9)
    mov  x9, x4
    tbz  x4, #63, 1f
    negs x8, x8
    ngc  x9, x9
1:  ADR_L x10, p10_128
    add  x10, x10, w1, uxtw #4
    ldp  x11, x12, [x10]
    cmp  x9, x12
    b.hi 8f
    b.lo 2f
    cmp  x8, x11
    b.hs 8f
2:  mov  x0, x3
    mov  x1, x4
    mov  w2, #1
    ret
8:  mov  x0, x3
    mov  x1, x4
    mov  w2, #0
    ret
ENDF i256_to128

// i256_mul128(x0 dst, x1 a lo, x2 a hi, x3 b lo, x4 b hi): dst = a * b
// (signed i128 x i128 -> I256, exact)   (leaf)
FUNC i256_mul128
    eor  x15, x2, x4                    // sign of the product (bit 63)
    tbz  x2, #63, 1f
    negs x1, x1
    ngc  x2, x2
1:  tbz  x4, #63, 2f
    negs x3, x3
    ngc  x4, x4
2:  mul  x5, x1, x3                     // r0
    umulh x6, x1, x3                    // r1
    mul  x9, x1, x4
    umulh x10, x1, x4
    adds x6, x6, x9
    adcs x7, x10, xzr                   // r2
    adc  x8, xzr, xzr                   // r3
    mul  x9, x2, x3
    umulh x10, x2, x3
    adds x6, x6, x9
    adcs x7, x7, x10
    adc  x8, x8, xzr
    mul  x9, x2, x4
    umulh x10, x2, x4
    adds x7, x7, x9
    adc  x8, x8, x10
    tbz  x15, #63, 3f
    negs x5, x5
    ngcs x6, x6
    ngcs x7, x7
    ngc  x8, x8
3:  stp  x5, x6, [x0]
    stp  x7, x8, [x0, #16]
    ret
ENDF i256_mul128

// =============================================================================
// Text
// =============================================================================

// i256_digits(x0 p, x1 end of a >= 80 byte scratch area, w2 min digits)
//   -> x0 first digit, x1 digit count, x2 1 if negative
// Writes the decimal digits of |p| backwards ending at x1 (p is clobbered).
//   x19 p, x20 cursor, x21 count, x22 sign, w23 min digits
LFUNC i256_digits
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  w23, w2
    mov  x21, #0
    ldr  x22, [x19, #24]
    lsr  x22, x22, #63
    cbz  x22, 1f
    bl   i256_neg
1:  mov  x0, x19                        // 9 digits per division
    ldr  w1, =1000000000
    bl   u256_divmod_u32
    mov  x9, #9
    mov  x10, #10
2:  udiv x11, x0, x10
    msub x12, x11, x10, x0
    add  w12, w12, #'0'
    strb w12, [x20, #-1]!
    add  x21, x21, #1
    mov  x0, x11
    subs x9, x9, #1
    b.ne 2b
    ldp  x9, x10, [x19]
    ldp  x11, x12, [x19, #16]
    orr  x9, x9, x10
    orr  x11, x11, x12
    orr  x9, x9, x11
    cbnz x9, 1b
3:  cmp  x21, #1                        // strip leading zeros
    b.ls 4f
    ldrb w9, [x20]
    cmp  w9, #'0'
    b.ne 4f
    cmp  x21, x23
    b.ls 4f
    add  x20, x20, #1
    sub  x21, x21, #1
    b    3b
4:  cmp  x21, x23                       // zero padding up to min digits
    b.hs 5f
    mov  w9, #'0'
    strb w9, [x20, #-1]!
    add  x21, x21, #1
    b    4b
5:  mov  x0, x20
    mov  x1, x21
    mov  x2, x22
    LEAVE 3
ENDF i256_digits

// i256_fmt(x0 Buf*, x1 I256* (clobbered), w2 s): canonical decimal text of
// p / 10^s ("-0.50", "12"): exactly s fractional digits.
//   x19 Buf*, w20 s, x21 first digit, x22 digit count, x23 negative
//   Scratch: 96 bytes at sp+16
FUNC i256_fmt
    ENTER 3
    sub  sp, sp, #112
    mov  x19, x0
    mov  w20, w2
    mov  x0, x1
    add  x1, sp, #112
    add  w2, w20, #1
    bl   i256_digits
    mov  x21, x0
    mov  x22, x1
    mov  x23, x2
    add  x1, x22, x23                   // total = neg + digits + (s > 0)
    cmp  w20, #0
    cinc x1, x1, ne
    str  x1, [sp]
    mov  x0, x19
    bl   buf_reserve
    ldr  x1, [sp]
    cbz  x23, 1f
    mov  w9, #'-'
    strb w9, [x0], #1
1:  sub  x12, x22, x20, uxtw            // integer digits (>= 1)
2:  ldrb w9, [x21], #1
    strb w9, [x0], #1
    subs x12, x12, #1
    b.ne 2b
    cbz  w20, 4f
    mov  w9, #'.'
    strb w9, [x0], #1
    mov  w12, w20
3:  ldrb w9, [x21], #1
    strb w9, [x0], #1
    subs w12, w12, #1
    b.ne 3b
4:  ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, x1
    str  x9, [x19, #BUF_LEN]
    add  sp, sp, #112
    LEAVE 3
ENDF i256_fmt

// fmt_dec128(x0 Buf*, x1 lo, x2 hi, w3 s)
FUNC fmt_dec128
    ENTER 1
    sub  sp, sp, #32
    mov  x19, x0
    mov  w20, w3
    mov  x0, sp
    bl   i256_from128                   // x1 lo, x2 hi
    mov  x0, x19
    mov  x1, sp
    mov  w2, w20
    bl   i256_fmt
    add  sp, sp, #32
    LEAVE 1
ENDF fmt_dec128

// i256_to_f64(x0 I256* (clobbered), w1 s) -> d0 nearest binary64 of p/10^s
// The exact text "<digits>e-<s>" is converted by strtod (correct rounding).
//   x19 p, w20 s; text buffer 160 bytes at sp
FUNC i256_to_f64
    ENTER 2
    sub  sp, sp, #160
    mov  x19, x0
    mov  w20, w1
    add  x1, sp, #96                    // digits end before sp+96
    mov  w2, #1
    bl   i256_digits                    // x0 first, x1 count, x2 negative
    mov  x9, sp                         // copy "[-]digits" to sp
    cbz  x2, 1f
    mov  w10, #'-'
    strb w10, [x9], #1
1:  ldrb w10, [x0], #1
    strb w10, [x9], #1
    subs x1, x1, #1
    b.ne 1b
    mov  x0, x9                         // "e-<s>"
    mov  x1, #24
    ADR_L x2, fmt_exp
    mov  w3, w20
    bl   snprintf
    mov  x0, sp
    mov  x1, #0
    bl   strtod
    add  sp, sp, #160
    LEAVE 2
ENDF i256_to_f64

// parse_dec128(x0 ptr, x1 len, w2 p, w3 s, w4 mode) -> x0 lo, x1 hi, w2 status
// Syntax ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ (no trimming). status: 1 syntax,
// 2 does not fit precision p (<= 38), 3 more than s fractional digits (mode 0,
// exact). mode 1 rounds half away from zero. Precedence: 1, then 3, then 2.
//   x19 cursor, x20 end, w21 p, w22 s, w23 mode, x24 negative,
//   x25 integer digits start, x26 integer digits end / scratch,
//   x27 fraction start, x28 fraction end. I256 accumulator at sp,
//   [sp+32] overflow flag, [sp+40] significant digits so far
FUNC parse_dec128
    ENTER 5
    sub  sp, sp, #48
    mov  x19, x0
    add  x20, x0, x1
    mov  w21, w2
    mov  w22, w3
    mov  w23, w4
    mov  x24, #0
    cmp  x19, x20
    b.eq .Lpd_syntax
    ldrb w9, [x19]
    cmp  w9, #'-'
    b.ne 1f
    mov  x24, #1
    add  x19, x19, #1
    b    2f
1:  cmp  w9, #'+'
    b.ne 2f
    add  x19, x19, #1
2:  mov  x25, x19
3:  cmp  x19, x20                       // integer digits
    b.eq 4f
    ldrb w9, [x19]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi 4f
    add  x19, x19, #1
    b    3b
4:  mov  x26, x19
    mov  x27, x19
    mov  x28, x19
    cmp  x19, x20
    b.eq 6f
    ldrb w9, [x19]
    cmp  w9, #'.'
    b.ne .Lpd_syntax
    add  x19, x19, #1
    mov  x27, x19
5:  cmp  x19, x20
    b.eq 51f
    ldrb w9, [x19]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi .Lpd_syntax
    add  x19, x19, #1
    b    5b
51: mov  x28, x19
6:  cmp  x25, x26                       // at least one digit
    b.ne 7f
    cmp  x27, x28
    b.eq .Lpd_syntax
7:  sub  x9, x28, x27                   // fraction digits
    cmp  x9, x22
    b.ls 8f
    cbnz w23, 8f
    mov  w2, #3
    b    .Lpd_ret0
8:  stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    stp  xzr, xzr, [sp, #32]
10: cmp  x25, x26                       // integer part
    b.eq 11f
    ldrb w0, [x25], #1
    bl   .Lpd_digit
    b    10b
11: sub  x9, x28, x27                   // first min(nf, s) fraction digits
    cmp  x9, x22
    csel x9, x9, x22, ls
    sub  x26, x22, x9                   // zeros to append: s - taken
    add  x25, x27, x9                   // end of the taken digits
12: cmp  x27, x25
    b.eq 13f
    ldrb w0, [x27], #1
    bl   .Lpd_digit
    b    12b
13: cbz  x26, 14f
    mov  w0, #'0'
    bl   .Lpd_digit
    sub  x26, x26, #1
    b    13b
14: cmp  x27, x28                       // mode 1: round on the first dropped
    b.hs 15f                            // digit
    ldrb w9, [x27]
    cmp  w9, #'5'
    b.lo 15f
    ldp  x1, x2, [sp]
    ldp  x3, x4, [sp, #16]
    adds x1, x1, #1
    adcs x2, x2, xzr
    adcs x3, x3, xzr
    adc  x4, x4, xzr
    stp  x1, x2, [sp]
    stp  x3, x4, [sp, #16]
15: ldr  x9, [sp, #32]
    cbnz x9, .Lpd_ovf
    cbz  x24, 16f
    mov  x0, sp
    bl   i256_neg
16: mov  x0, sp
    mov  w1, w21
    bl   i256_to128
    cbz  w2, .Lpd_ovf
    mov  w2, #0
    b    .Lpd_ret
.Lpd_syntax:
    mov  w2, #1
    b    .Lpd_ret0
.Lpd_ovf:
    mov  w2, #2
.Lpd_ret0:
    mov  x0, #0
    mov  x1, #0
.Lpd_ret:
    add  sp, sp, #48
    LEAVE 5

    // local helper: append digit byte w0 to the accumulator; after 40
    // significant digits only the overflow flag is set (never fits)
.Lpd_digit:
    stp  x29, x30, [sp, #-16]!
    sub  w9, w0, #'0'
    ldr  x10, [sp, #(16 + 40)]          // significant digits so far
    cbnz x10, 1f
    cbz  w9, 3f                         // leading zero: value stays 0
1:  cmp  x10, #40
    b.lo 2f
    mov  x10, #1
    str  x10, [sp, #(16 + 32)]
    b    3f
2:  add  x10, x10, #1
    str  x10, [sp, #(16 + 40)]
    str  w9, [sp, #-16]!
    add  x0, sp, #32                    // accumulator (sp + 16 + 16)
    mov  x1, #10
    bl   u256_mul_u64
    ldr  w9, [sp], #16
    ldp  x1, x2, [sp, #16]
    ldp  x3, x4, [sp, #32]
    adds x1, x1, x9
    adcs x2, x2, xzr
    adcs x3, x3, xzr
    adc  x4, x4, xzr
    stp  x1, x2, [sp, #16]
    stp  x3, x4, [sp, #32]
3:  ldp  x29, x30, [sp], #16
    ret
ENDF parse_dec128

// =============================================================================
// Value-level operations
// =============================================================================

// dec_load256(x0 dst, x1 payload, w2 type): I256 of an INT64 / DECIMAL value
LFUNC dec_load256
    ENTER 1
    mov  x19, x0
    mov  x0, x1
    mov  w1, w2
    bl   dec_get128
    mov  x2, x1
    mov  x1, x0
    mov  x0, x19
    bl   i256_from128
    LEAVE 1
ENDF dec_load256

// dec_cmp(x0 a, w1 ta, x2 b, w3 tb) -> w0 -1/0/1: exact comparison of two
// INT64 / DECIMAL values of any precision and scale.
//   x19 b, w20 ta, w21 tb, w22 scale a, w23 scale b. Two I256 at sp, sp+32.
FUNC dec_cmp
    ENTER 3
    sub  sp, sp, #64
    mov  x19, x2
    mov  w20, w1
    mov  w21, w3
    SCALE_OF w22, w20
    SCALE_OF w23, w21
    mov  x1, x0
    mov  x0, sp
    mov  w2, w20
    bl   dec_load256
    add  x0, sp, #32
    mov  x1, x19
    mov  w2, w21
    bl   dec_load256
    cmp  w22, w23
    b.eq 2f
    b.hi 1f
    mov  x0, sp                         // a has the smaller scale
    sub  w1, w23, w22
    bl   i256_mul_pow10
    b    2f
1:  add  x0, sp, #32
    sub  w1, w22, w23
    bl   i256_mul_pow10
2:  mov  x0, sp
    add  x1, sp, #32
    bl   i256_cmp
    add  sp, sp, #64
    LEAVE 3
ENDF dec_cmp

// dec_arith(x0 a, x1 b, w2 op, w3 ta, w4 tb, w5 tr) -> x0 payload of type tr
// + - (operands aligned to the result scale) and * (scales add up). Raises
// NUMERIC_OVERFLOW if the exact result needs more than p(tr) digits.
//   x19 b, w20 op, w21 ta, w22 tb, w23 tr. I256 a at sp, b at sp+32.
FUNC dec_arith
    ENTER 3
    sub  sp, sp, #64
    mov  x19, x1
    mov  w20, w2
    mov  w21, w3
    mov  w22, w4
    mov  w23, w5
    cmp  w20, #OP_MUL
    b.ne 1f
    mov  w1, w21                        // product of the unscaled values
    bl   dec_get128
    stp  x0, x1, [sp, #32]
    mov  x0, x19
    mov  w1, w22
    bl   dec_get128
    mov  x3, x0
    mov  x4, x1
    ldp  x1, x2, [sp, #32]
    mov  x0, sp
    bl   i256_mul128
    b    5f
1:  mov  x1, x0
    mov  x0, sp
    mov  w2, w21
    bl   dec_load256
    add  x0, sp, #32
    mov  x1, x19
    mov  w2, w22
    bl   dec_load256
    ubfx w9, w23, #T_SCALE_SHIFT, #8    // result scale
    SCALE_OF w10, w21
    mov  x0, sp
    sub  w1, w9, w10
    bl   i256_mul_pow10
    ubfx w9, w23, #T_SCALE_SHIFT, #8
    SCALE_OF w10, w22
    add  x0, sp, #32
    sub  w1, w9, w10
    bl   i256_mul_pow10
    mov  x0, sp
    add  x1, sp, #32
    cmp  w20, #OP_SUB
    b.eq 2f
    bl   i256_add
    b    5f
2:  bl   i256_sub
5:  mov  x0, sp
    ubfx w1, w23, #T_PREC_SHIFT, #8
    bl   i256_to128
    cbz  w2, raise_overflow
    mov  w2, w23
    bl   dec_put128
    add  sp, sp, #64
    LEAVE 3
ENDF dec_arith

// dec_convert(x0 payload, w1 from, w2 to, w3 mode) -> x0 payload, w1 status
// INT64 / DECIMAL -> DECIMAL `to`. mode 0: round half away from zero; mode 1:
// exact (status 3 if digits would be lost). status 2: does not fit p(to),
// unless `to` carries T_SATF (then saturated to +-INT64_MAX narrow /
// +-10^38 wide, status 0).
//   w19 from, w20 to, w21 mode. I256 at sp.
FUNC dec_convert
    ENTER 2
    sub  sp, sp, #32
    mov  w19, w1
    mov  w20, w2
    mov  w21, w3
    mov  x1, x0
    mov  x0, sp
    mov  w2, w19
    bl   dec_load256
    SCALE_OF w9, w19
    ubfx w10, w20, #T_SCALE_SHIFT, #8
    cmp  w10, w9
    b.lo 1f
    mov  x0, sp                         // scale up (exact)
    sub  w1, w10, w9
    bl   i256_mul_pow10
    b    3f
1:  mov  x0, sp                         // scale down
    sub  w1, w9, w10
    mov  w2, #1                         // half away from zero
    cbz  w21, 2f
    mov  w2, #0
2:  bl   i256_div_pow10
    cbz  w21, 3f
    cbnz w0, .Ldc_inexact
3:  mov  x0, sp
    ubfx w1, w20, #T_PREC_SHIFT, #8
    bl   i256_to128
    cbz  w2, .Ldc_nofit
4:  mov  w2, w20
    bl   dec_put128
    mov  w1, #0
.Ldc_ret:
    add  sp, sp, #32
    LEAVE 2
.Ldc_inexact:
    mov  x0, #0
    mov  w1, #3
    b    .Ldc_ret
.Ldc_nofit:
    tst  w20, #T_SATF
    b.ne 5f
    mov  x0, #0
    mov  w1, #2
    b    .Ldc_ret
5:  ldr  x9, [sp, #24]                  // saturate by sign
    ubfx w10, w20, #T_PREC_SHIFT, #8
    cmp  w10, #DEC_NARROW_MAX
    b.hi 6f
    mov  x0, #0x7fffffffffffffff
    tbz  x9, #63, 4b
    neg  x0, x0
    b    4b
6:  ADR_L x10, p10_128
    add  x10, x10, #(38 * 16)
    ldp  x0, x1, [x10]
    tbz  x9, #63, 4b
    negs x0, x0
    ngc  x1, x1
    b    4b
ENDF dec_convert

// dec_to_int(x0 payload, w1 type) -> x0 INT64, w1 status (2 out of range)
// DECIMAL -> INT64 truncates toward zero.
//   I256 at sp
FUNC dec_to_int
    ENTER 1
    sub  sp, sp, #32
    mov  w19, w1
    mov  x1, x0
    mov  x0, sp
    mov  w2, w19
    bl   dec_load256
    mov  x0, sp
    SCALE_OF w1, w19
    mov  w2, #0
    bl   i256_div_pow10
    mov  x0, sp
    mov  w1, #DEC_MAX_PREC
    bl   i256_to128
    mov  w9, #2
    cbz  w2, 1f
    cmp  x1, x0, asr #63
    cset w9, ne
    lsl  w9, w9, #1
1:  mov  w1, w9
    add  sp, sp, #32
    LEAVE 1
ENDF dec_to_int

// dec_to_double(x0 payload, w1 type) -> d0 nearest binary64
FUNC dec_to_double
    ENTER 1
    sub  sp, sp, #32
    mov  w19, w1
    mov  x1, x0
    mov  x0, sp
    mov  w2, w19
    bl   dec_load256
    mov  x0, sp
    SCALE_OF w1, w19
    bl   i256_to_f64
    add  sp, sp, #32
    LEAVE 1
ENDF dec_to_double

// dec_from_f64(d0 x, w1 type) -> x0 payload, w1 status (2 overflow / not
// finite). Rounds half away from zero on the exact binary value: the double
// is printed with s + 40 fractional digits (exact expansion, see decimal.S
// f64_to_dec) and parsed with rounding.
//   w19 type; text buffer 176 bytes at sp
FUNC dec_from_f64
    ENTER 1
    sub  sp, sp, #176
    mov  w19, w1
    fabs d1, d0
    ADR_L x9, f64_1e39
    ldr  d2, [x9]
    fcmp d1, d2
    b.hs 8f                             // >= 1e39 or NaN: never fits
    mov  x0, sp
    mov  x1, #176
    ADR_L x2, fmt_fixed
    ubfx w3, w19, #T_SCALE_SHIFT, #8
    add  w3, w3, #40
    bl   snprintf
    mov  x1, x0                         // length
    mov  x0, sp
    ubfx w2, w19, #T_PREC_SHIFT, #8
    ubfx w3, w19, #T_SCALE_SHIFT, #8
    mov  w4, #1
    bl   parse_dec128
    cbnz w2, 8f
    mov  w2, w19
    bl   dec_put128
    mov  w1, #0
    b    9f
8:  mov  x0, #0
    mov  w1, #2
9:  add  sp, sp, #176
    LEAVE 1
ENDF dec_from_f64

// dec_neg(x0 payload, w1 wide type) -> x0 boxed -v (|v| < 10^38: no overflow)
FUNC dec_neg
    ENTER 0
    ldp  x0, x1, [x0]
    negs x0, x0
    ngc  x1, x1
    bl   dec_box
    LEAVE 0
ENDF dec_neg

// dec_abs(x0 payload, w1 wide type) -> x0 boxed |v|
FUNC dec_abs
    ldr  x9, [x0, #8]
    tbnz x9, #63, dec_neg
    ret
ENDF dec_abs

// dec_round(x0 payload, w1 type, x2 n, w3 result type) -> x0
// ROUND(DECIMAL(p,s), n): half away from zero to scale max(0, min(n, s));
// n < 0 rounds to a multiple of 10^-n (raises NUMERIC_OVERFLOW if the
// result needs more than p(result) digits).
//   w19 type, x20 n, w21 result type. I256 at sp.
FUNC dec_round
    ENTER 2
    sub  sp, sp, #32
    mov  w19, w1
    mov  x20, x2
    mov  w21, w3
    mov  x1, x0
    mov  x0, sp
    mov  w2, w19
    bl   dec_load256
    ubfx w9, w19, #T_SCALE_SHIFT, #8    // s
    sxtw x9, w9
    cmp  x20, x9
    b.ge 5f                             // n >= s: unchanged
    tbnz x20, #63, 1f
    mov  x0, sp                         // 0 <= n < s
    sub  w1, w9, w20
    mov  w2, #1
    bl   i256_div_pow10
    b    5f
1:  neg  x10, x20                       // m = -n
    cmp  x10, #80
    b.hi 3f
    add  x11, x9, x10                   // divide by 10^(s+m), round
    cmp  x11, #78
    b.hi 3f
    mov  x0, sp
    mov  w1, w11
    mov  w2, #1
    bl   i256_div_pow10
    mov  x0, sp
    neg  x1, x20
    bl   i256_mul_pow10
    b    5f
3:  stp  xzr, xzr, [sp]                 // |v| < 0.5 * 10^k: zero
    stp  xzr, xzr, [sp, #16]
5:  mov  x0, sp
    ubfx w1, w21, #T_PREC_SHIFT, #8
    bl   i256_to128
    cbz  w2, raise_overflow
    mov  w2, w21
    bl   dec_put128
    add  sp, sp, #32
    LEAVE 2
ENDF dec_round

// dec_floorceil(x0 payload, w1 type, w2 1 = CEIL, w3 result type) -> x0
//   w19 type, w20 ceil, w21 result type. I256 at sp.
FUNC dec_floorceil
    ENTER 2
    sub  sp, sp, #32
    mov  w19, w1
    mov  w20, w2
    mov  w21, w3
    mov  x1, x0
    mov  x0, sp
    mov  w2, w19
    bl   dec_load256
    mov  x0, sp
    ubfx w1, w19, #T_SCALE_SHIFT, #8
    add  w2, w20, #2                    // 2 floor, 3 ceiling
    bl   i256_div_pow10
    mov  x0, sp
    ubfx w1, w21, #T_PREC_SHIFT, #8
    bl   i256_to128
    cbz  w2, raise_overflow
    mov  w2, w21
    bl   dec_put128
    add  sp, sp, #32
    LEAVE 2
ENDF dec_floorceil

    .ltorg
    NOTE_GNU_STACK
