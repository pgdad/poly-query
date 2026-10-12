// =============================================================================
// values.S — value library: text parsing of scalars, value formatting
// (JSON and CAST-to-STRING), comparison and the CAST matrix (types.md §8).
//
// Functions:
//   trim_ws(x0 ptr, x1 len)          -> x0 ptr, x1 len  (space/tab)
//   trim_all_ws(x0 ptr, x1 len)      -> x0 ptr, x1 len  (space/tab/CR/LF)
//   parse_bool(x0 ptr, x1 len)       -> x0 0/1, w1 status
//   parse_int64(x0 ptr, x1 len)      -> x0 value, w1 status (1 syntax, 2 ovf)
//   parse_float(x0 ptr, x1 len)      -> d0 value, w1 status (1 syntax, 2 inf)
//   write_value_json(x0 Buf*, x1 payload, x2 isnull, w3 type)
//   value_to_str(x0 payload, w1 type) -> x0 Str*
//   value_cmp(x0 a, x1 b, w2 type)    -> w0 -1/0/1
//   cast_allowed(w0 from, w1 to)      -> w0 1/0
//   cast_value(x0 payload, w1 from, w2 to) -> x0 payload (raises)
// =============================================================================
#include "pq.inc"

#define US_PER_DAY 86400000000

    .section .rodata
s_true:     .asciz "true"
s_false:    .asciz "false"
s_null:     .asciz "null"

// CAST matrix: for each source kind (index T_*), a bit mask of allowed target
// kinds (bit T_*). T_NULL converts to everything.
cast_mask:
    .byte 0xff                                              // NULL
    .byte (1<<T_BOOL)|(1<<T_INT)|(1<<T_STR)                 // BOOLEAN
    .byte (1<<T_BOOL)|(1<<T_INT)|(1<<T_DEC)|(1<<T_FLOAT)|(1<<T_STR) // INT64
    .byte (1<<T_INT)|(1<<T_DEC)|(1<<T_FLOAT)|(1<<T_STR)     // DECIMAL
    .byte (1<<T_INT)|(1<<T_DEC)|(1<<T_FLOAT)|(1<<T_STR)     // FLOAT64
    .byte 0xfe                                              // STRING
    .byte (1<<T_STR)|(1<<T_DATE)|(1<<T_TS)                  // DATE
    .byte (1<<T_STR)|(1<<T_DATE)|(1<<T_TS)                  // TIMESTAMP

// error message prefixes / messages indexed by target kind
    .p2align 3
conv_msgs:
    .quad m_conv_gen, m_conv_bool, m_conv_int, m_conv_dec
    .quad m_conv_flt, m_conv_gen, m_conv_date, m_conv_ts
ovf_msgs:
    .quad m_ovf_gen, m_ovf_gen, m_ovf_int, m_ovf_dec
    .quad m_ovf_flt, m_ovf_gen, m_ovf_gen, m_ovf_gen
m_conv_gen:  .asciz "invalid value for cast: "
m_conv_bool: .asciz "invalid BOOLEAN value: "
m_conv_int:  .asciz "invalid INT64 value: "
m_conv_dec:  .asciz "invalid DECIMAL value: "
m_conv_flt:  .asciz "invalid FLOAT64 value: "
m_conv_date: .asciz "invalid DATE value: "
m_conv_ts:   .asciz "invalid TIMESTAMP value: "
m_ovf_gen:   .asciz "numeric overflow in cast"
m_ovf_int:   .asciz "value out of range for INT64"
m_ovf_dec:   .asciz "value does not fit the DECIMAL precision"
m_ovf_flt:   .asciz "value out of range for FLOAT64"
    .text

// IS_SPTAB w, yes: branch to `yes` if byte w is ' ' or '\t'.
.macro IS_SPTAB w, yes
    cmp  \w, #' '
    b.eq \yes
    cmp  \w, #'\t'
    b.eq \yes
.endm
// IS_ANYWS w, yes: branch to `yes` if byte w is ' ', '\t', '\n' or '\r'.
.macro IS_ANYWS w, yes
    IS_SPTAB \w, \yes
    cmp  \w, #'\n'
    b.eq \yes
    cmp  \w, #'\r'
    b.eq \yes
.endm

// -----------------------------------------------------------------------------
// trim_ws(x0 ptr, x1 len) -> x0 ptr, x1 len: strip ASCII space/tab.  (leaf)
// Registers: x2 end, w3 byte.
// -----------------------------------------------------------------------------
FUNC trim_ws
    add  x2, x0, x1
1:  cmp  x0, x2
    b.hs 3f
    ldrb w3, [x0]
    IS_SPTAB w3, 2f
    b    3f
2:  add  x0, x0, #1
    b    1b
3:  cmp  x2, x0
    b.ls 5f
    ldrb w3, [x2, #-1]
    IS_SPTAB w3, 4f
    b    5f
4:  sub  x2, x2, #1
    b    3b
5:  sub  x1, x2, x0
    ret
ENDF trim_ws

// -----------------------------------------------------------------------------
// trim_all_ws(x0 ptr, x1 len) -> x0 ptr, x1 len: strip space/tab/CR/LF. (leaf)
// -----------------------------------------------------------------------------
FUNC trim_all_ws
    add  x2, x0, x1
1:  cmp  x0, x2
    b.hs 3f
    ldrb w3, [x0]
    IS_ANYWS w3, 2f
    b    3f
2:  add  x0, x0, #1
    b    1b
3:  cmp  x2, x0
    b.ls 5f
    ldrb w3, [x2, #-1]
    IS_ANYWS w3, 4f
    b    5f
4:  sub  x2, x2, #1
    b    3b
5:  sub  x1, x2, x0
    ret
ENDF trim_all_ws

// -----------------------------------------------------------------------------
// parse_bool(x0 ptr, x1 len) -> x0 0/1, w1 status (1 invalid)          (leaf)
// `true` / `false`, ASCII case-insensitive, no trimming. Bytes are OR-ed
// with 0x20 (folds A-Z onto a-z; no other byte maps onto these letters).
// -----------------------------------------------------------------------------
FUNC parse_bool
    cmp  x1, #4
    b.eq 1f
    cmp  x1, #5
    b.ne 9f
    ldrb w2, [x0]                   // "false"
    ldrb w3, [x0, #1]
    ldrb w4, [x0, #2]
    ldrb w5, [x0, #3]
    ldrb w6, [x0, #4]
    orr  w2, w2, w3, lsl #8
    orr  w2, w2, w4, lsl #16
    orr  w2, w2, w5, lsl #24
    orr  w2, w2, #0x20202020
    orr  w6, w6, #0x20
    movz w3, #0x6166                // 'f','a'
    movk w3, #0x736c, lsl #16       // 'l','s'
    cmp  w2, w3
    b.ne 9f
    cmp  w6, #'e'
    b.ne 9f
    mov  x0, #0
    mov  w1, #0
    ret
1:  ldrb w2, [x0]                   // "true"
    ldrb w3, [x0, #1]
    ldrb w4, [x0, #2]
    ldrb w5, [x0, #3]
    orr  w2, w2, w3, lsl #8
    orr  w2, w2, w4, lsl #16
    orr  w2, w2, w5, lsl #24
    orr  w2, w2, #0x20202020
    movz w3, #0x7274                // 't','r'
    movk w3, #0x6575, lsl #16       // 'u','e'
    cmp  w2, w3
    b.ne 9f
    mov  x0, #1
    mov  w1, #0
    ret
9:  mov  x0, #0
    mov  w1, #1
    ret
ENDF parse_bool

// -----------------------------------------------------------------------------
// parse_int64(x0 ptr, x1 len) -> x0 value, w1 status                   (leaf)
// ^[+-]?[0-9]+$ ; status 1 syntax, 2 out of the i64 range. The magnitude is
// accumulated as u64 with exact overflow detection (umulh / carry); the
// final range check allows 2^63 only for negative numbers.
// Syntax errors take precedence over overflow.
// Registers: x2 end, x3 negative, x4 digit, x5 magnitude, x6 overflow flag,
//            x7 10, x8 high product.
// -----------------------------------------------------------------------------
FUNC parse_int64
    add  x2, x0, x1
    mov  x3, #0
    cmp  x0, x2
    b.eq 9f
    ldrb w4, [x0]
    cmp  w4, #'-'
    b.ne 1f
    mov  x3, #1
    add  x0, x0, #1
    b    2f
1:  cmp  w4, #'+'
    b.ne 2f
    add  x0, x0, #1
2:  cmp  x0, x2
    b.eq 9f                         // sign without digits
    mov  x5, #0
    mov  x6, #0
    mov  x7, #10
3:  ldrb w4, [x0], #1
    sub  w4, w4, #'0'
    cmp  w4, #9
    b.hi 9f
    cbnz x6, 4f
    umulh x8, x5, x7
    mul  x5, x5, x7
    adds x5, x5, x4
    b.cs 31f
    cbz  x8, 4f
31: mov  x6, #1
4:  cmp  x0, x2
    b.lo 3b
    cbnz x6, 8f
    cbz  x3, 5f
    mov  x8, #(1 << 63)             // negative: magnitude <= 2^63
    cmp  x5, x8
    b.hi 8f
    neg  x0, x5
    mov  w1, #0
    ret
5:  tbnz x5, #63, 8f                // positive: magnitude <= 2^63-1
    mov  x0, x5
    mov  w1, #0
    ret
8:  mov  x0, #0
    mov  w1, #2
    ret
9:  mov  x0, #0
    mov  w1, #1
    ret
ENDF parse_int64

// -----------------------------------------------------------------------------
// parse_float(x0 ptr, x1 len) -> d0 value, w1 status (1 syntax, 2 not finite)
// Validates ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$ by hand
// (so strtod never sees hex, inf, nan, whitespace...), copies the text into a
// NUL-terminated buffer (stack, or request arena for long inputs) and calls
// strtod, which rounds correctly.
// Registers (validation): x2 end, x3 cursor, x5 int digits, x6 frac digits,
//   w4 byte. Then x19 ptr, x20 len. Stack buffer: 128 bytes at sp+32.
// -----------------------------------------------------------------------------
FUNC parse_float
    add  x2, x0, x1
    mov  x3, x0
    cmp  x3, x2
    b.hs 90f
    ldrb w4, [x3]
    cmp  w4, #'+'
    b.eq 1f
    cmp  w4, #'-'
    b.ne 2f
1:  add  x3, x3, #1
2:  mov  x5, #0                     // integer digits
3:  cmp  x3, x2
    b.hs 4f
    ldrb w4, [x3]
    sub  w4, w4, #'0'
    cmp  w4, #9
    b.hi 4f
    add  x3, x3, #1
    add  x5, x5, #1
    b    3b
4:  mov  x6, #0                     // fraction digits
    cmp  x3, x2
    b.hs 6f
    ldrb w4, [x3]
    cmp  w4, #'.'
    b.ne 6f
    add  x3, x3, #1
5:  cmp  x3, x2
    b.hs 6f
    ldrb w4, [x3]
    sub  w4, w4, #'0'
    cmp  w4, #9
    b.hi 6f
    add  x3, x3, #1
    add  x6, x6, #1
    b    5b
6:  orr  x7, x5, x6                 // mantissa needs at least one digit
    cbz  x7, 90f
    cmp  x3, x2
    b.hs 20f
    ldrb w4, [x3]                   // exponent
    orr  w4, w4, #0x20
    cmp  w4, #'e'
    b.ne 90f
    add  x3, x3, #1
    cmp  x3, x2
    b.hs 90f
    ldrb w4, [x3]
    cmp  w4, #'+'
    b.eq 7f
    cmp  w4, #'-'
    b.ne 8f
7:  add  x3, x3, #1
8:  mov  x7, #0                     // exponent digits
81: cmp  x3, x2
    b.hs 82f
    ldrb w4, [x3]
    sub  w4, w4, #'0'
    cmp  w4, #9
    b.hi 90f
    add  x3, x3, #1
    add  x7, x7, #1
    b    81b
82: cbz  x7, 90f
20: // syntax ok: NUL-terminate a copy and convert
    stp  x29, x30, [sp, #-160]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
    add  x0, sp, #32
    cmp  x1, #127
    b.ls 21f
    add  x0, x1, #1
    bl   arena_alloc
21: mov  x1, x19
    mov  x2, x20
    bl   memcpy                     // returns dst
    strb wzr, [x0, x20]
    mov  x1, #0
    bl   strtod
    fabs d1, d0
    mov  x9, #0x7ff0000000000000    // +infinity
    fmov d2, x9
    fcmp d1, d2
    cset w1, eq
    lsl  w1, w1, #1                 // 2 if infinite
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #160
    ret
90: movi d0, #0
    mov  w1, #1
    ret
ENDF parse_float

// -----------------------------------------------------------------------------
// val_write_text(x0 Buf*, x1 payload, w2 type): append the plain (unquoted)
// text of a non-null value: BOOL true/false, INT digits, DEC canonical,
// FLOAT shortest round-trip, DATE, TIMESTAMP, STRING raw bytes.
// Tail-calls the formatter, so it needs no frame.
// -----------------------------------------------------------------------------
LFUNC val_write_text
    and  w9, w2, #T_KIND_MASK
    cmp  w9, #T_BOOL
    b.ne 1f
    ADR_L x9, s_false
    ADR_L x10, s_true
    cmp  x1, #0
    csel x1, x9, x10, eq
    b    buf_puts
1:  cmp  w9, #T_INT
    b.eq buf_put_i64
    cmp  w9, #T_FLOAT
    b.ne 2f
    fmov d0, x1
    b    buf_put_f64
2:  cmp  w9, #T_DEC
    b.ne 3f
    ubfx w3, w2, #T_PREC_SHIFT, #8
    cmp  w3, #DEC_NARROW_MAX
    ubfx w3, w2, #T_SCALE_SHIFT, #8
    b.hi 21f
    mov  w2, w3
    b    fmt_decimal
21: ldp  x1, x2, [x1]                   // wide: boxed i128
    b    fmt_dec128
3:  cmp  w9, #T_DATE
    b.eq fmt_date
    cmp  w9, #T_TS
    b.eq fmt_timestamp
    cmp  w9, #T_STR
    b.ne 4f
    ldr  x2, [x1, #STR_LEN]
    add  x1, x1, #STR_DATA
    b    buf_put
4:  ret                             // T_NULL / unknown: nothing
ENDF val_write_text

// -----------------------------------------------------------------------------
// write_value_json(x0 Buf*, x1 payload, x2 isnull, w3 type)   (types.md §9)
// NULL => null; BOOL/INT/FLOAT bare; DECIMAL/DATE/TIMESTAMP quoted text;
// STRING escaped JSON string.
// Registers: x19 Buf*, x20 payload, w21 type.
// -----------------------------------------------------------------------------
FUNC write_value_json
    and  w9, w3, #T_KIND_MASK
    cbnz x2, 8f
    cbz  w9, 8f                     // null type
    cmp  w9, #T_STR
    b.ne 1f
    ldr  x2, [x1, #STR_LEN]
    add  x1, x1, #STR_DATA
    b    buf_put_jstr
1:  cmp  w9, #T_DEC
    b.eq 2f
    cmp  w9, #T_DATE
    b.eq 2f
    cmp  w9, #T_TS
    b.eq 2f
    mov  w2, w3                     // BOOL / INT / FLOAT: bare text
    b    val_write_text
2:  stp  x29, x30, [sp, #-48]!      // quoted text
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    mov  w21, w3
    mov  w1, #'"'
    bl   buf_putc
    mov  x0, x19
    mov  x1, x20
    mov  w2, w21
    bl   val_write_text
    mov  x0, x19
    mov  w1, #'"'
    bl   buf_putc
    ldp  x19, x20, [sp, #16]
    ldr  x21, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
8:  ADR_L x1, s_null
    b    buf_puts
ENDF write_value_json

// -----------------------------------------------------------------------------
// value_to_str(x0 payload, w1 type) -> x0 Str* (request arena)
// CAST(x AS STRING) text. STRING returns the payload itself. Other types are
// rendered into a temporary malloc-backed Buf on the stack, copied with
// str_new and the temporary freed.
// Registers: x19 result. Temporary Buf at sp+32 (BUF_SIZE bytes).
// -----------------------------------------------------------------------------
FUNC value_to_str
    and  w9, w1, #T_KIND_MASK
    cmp  w9, #T_STR
    b.ne 1f
    ret
1:  stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    str  x19, [sp, #16]
    cmp  w9, #T_BOOL
    b.ne 2f
    cmp  x0, #0
    ADR_L x9, s_false
    ADR_L x10, s_true
    csel x0, x9, x10, eq
    mov  x1, #5
    mov  x2, #4
    csel x1, x1, x2, eq
    bl   str_new
    b    9f
2:  stp  xzr, xzr, [sp, #32]
    stp  xzr, xzr, [sp, #48]
    mov  w2, w1
    mov  x1, x0
    add  x0, sp, #32
    bl   val_write_text
    ldr  x0, [sp, #32 + BUF_PTR]
    ldr  x1, [sp, #32 + BUF_LEN]
    bl   str_new
    mov  x19, x0
    ldr  x0, [sp, #32 + BUF_PTR]
    bl   free
    mov  x0, x19
9:  ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret
ENDF value_to_str

// -----------------------------------------------------------------------------
// value_cmp(x0 a, x1 b, w2 type) -> w0 -1/0/1 for two non-null values of the
// same type. BOOL/INT/DEC(same scale)/DATE/TS: signed compare; FLOAT: IEEE
// compare (0.0 == -0.0); STRING: bytewise, then length.
// -----------------------------------------------------------------------------
FUNC value_cmp
    and  w9, w2, #T_KIND_MASK
    cmp  w9, #T_FLOAT
    b.eq 1f
    BR_WIDE w2, w10, 3f
    cmp  w9, #T_STR
    b.eq 2f
    cmp  x0, x1
    cset w0, gt
    csinv w0, w0, wzr, ge           // less => -1
    ret
1:  fmov d0, x0
    fmov d1, x1
    fcmp d0, d1
    cset w0, gt
    csinv w0, w0, wzr, pl           // N set only for "less"
    ret
2:  ldr  x3, [x1, #STR_LEN]
    add  x2, x1, #STR_DATA
    ldr  x1, [x0, #STR_LEN]
    add  x0, x0, #STR_DATA
    b    bytes_cmp
3:  mov  w3, w2                         // wide DECIMAL
    b    cmp_typed
ENDF value_cmp

// -----------------------------------------------------------------------------
// cast_allowed(w0 from_type, w1 to_type) -> w0 1/0    (leaf; types.md §8)
// -----------------------------------------------------------------------------
FUNC cast_allowed
    and  w0, w0, #T_KIND_MASK
    and  w1, w1, #T_KIND_MASK
    cmp  w0, #T_TS
    b.hi 9f
    cmp  w1, #T_TS
    b.hi 9f
    ADR_L x9, cast_mask
    ldrb w9, [x9, w0, uxtw]
    lsr  w9, w9, w1
    and  w0, w9, #1
    ret
9:  mov  w0, #0
    ret
ENDF cast_allowed

// -----------------------------------------------------------------------------
// cv_conv_error(w0 to_kind, x1 ptr, x2 len): raise CONVERSION_ERROR with the
// offending (trimmed) text. cv_ovf_error(w0 to_kind): raise NUMERIC_OVERFLOW.
// Both never return.
// -----------------------------------------------------------------------------
LFUNC cv_conv_error
    mov  x3, x2
    mov  x2, x1
    ADR_L x9, conv_msgs
    ldr  x1, [x9, w0, uxtw #3]
    mov  w0, #ERR_CONVERSION
    b    pq_raise_s
ENDF cv_conv_error

LFUNC cv_ovf_error
    ADR_L x9, ovf_msgs
    ldr  x1, [x9, w0, uxtw #3]
    mov  w0, #ERR_NUMERIC_OVERFLOW
    b    pq_raise
ENDF cv_ovf_error

// -----------------------------------------------------------------------------
// cast_value(x0 payload, w1 from_type, w2 to_type) -> x0 payload
// Implements every allowed conversion of types.md §8. The caller handles
// NULL (and from == T_NULL is never passed). Raises CONVERSION_ERROR for
// unparsable strings and NUMERIC_OVERFLOW for values that do not fit.
// Registers: x19 payload / text ptr, w20 from type, w21 to type,
//            w22 to kind, x23 text len (STRING sources).
// -----------------------------------------------------------------------------
FUNC cast_value
    cmp  w1, w2
    b.ne 1f
    ret                             // identical type: identity
1:  stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    str  x23, [sp, #48]
    mov  x19, x0
    mov  w20, w1
    mov  w21, w2
    and  w22, w2, #T_KIND_MASK
    and  w9, w1, #T_KIND_MASK
    // any (non-string) -> STRING
    cmp  w22, #T_STR
    b.ne 2f
    mov  w1, w20
    bl   value_to_str
    b    99f
2:  cmp  w9, #T_BOOL
    b.eq 10f
    cmp  w9, #T_INT
    b.eq 20f
    cmp  w9, #T_DEC
    b.eq 30f
    cmp  w9, #T_FLOAT
    b.eq 40f
    cmp  w9, #T_STR
    b.eq 50f
    cmp  w9, #T_DATE
    b.eq 60f
    cmp  w9, #T_TS
    b.eq 70f
    b    98f

    // ---------------------------------------------------------- BOOLEAN ->
10: cmp  w22, #T_BOOL
    b.eq 97f
    cmp  w22, #T_INT
    b.eq 97f                        // 0/1
    b    98f

    // ------------------------------------------------------------ INT64 ->
20: cmp  w22, #T_INT
    b.eq 97f
    cmp  w22, #T_BOOL
    b.ne 21f
    cmp  x19, #0
    cset x0, ne
    b    99f
21: cmp  w22, #T_FLOAT
    b.ne 22f
    scvtf d0, x19
    fmov x0, d0
    b    99f
22: cmp  w22, #T_DEC
    b.ne 98f
    BR_WIDE w21, w9, 33f
    tst  w21, #T_SATF
    b.ne 33f
    mov  x0, x19                    // v * 10^s, must fit p
    mov  w1, #0
    ubfx w2, w21, #T_SCALE_SHIFT, #8
    bl   dec_rescale
    cbnz w1, 96f
    b    80f

    // ---------------------------------------------------------- DECIMAL ->
30: ubfx w10, w20, #T_SCALE_SHIFT, #8    // source scale
    BR_WIDE w20, w11, 34f
    cmp  w22, #T_INT
    b.ne 31f
    ADR_L x9, pow10_tab
    ldr  x9, [x9, w10, uxtw #3]
    sdiv x0, x19, x9                // truncate toward zero
    b    99f
31: cmp  w22, #T_FLOAT
    b.ne 32f
    mov  x0, x19
    mov  w1, w10
    bl   dec_to_f64
    fmov x0, d0
    b    99f
32: cmp  w22, #T_DEC
    b.ne 98f
    BR_WIDE w21, w9, 33f
    tst  w21, #T_SATF
    b.ne 33f
    mov  x0, x19                    // narrow -> narrow
    mov  w1, w10
    ubfx w2, w21, #T_SCALE_SHIFT, #8
    bl   dec_rescale
    cbnz w1, 96f
    b    80f
33: mov  x0, x19                    // INT64 / DECIMAL -> DECIMAL (exact
    mov  w1, w20                    // 256-bit rescale, any precision)
    mov  w2, w21
    mov  w3, #0
    bl   dec_convert
    cbnz w1, 96f
    b    99f
34: cmp  w22, #T_INT                // wide DECIMAL -> INT64 / FLOAT64
    b.ne 35f
    mov  x0, x19
    mov  w1, w20
    bl   dec_to_int
    cbnz w1, 96f
    b    99f
35: cmp  w22, #T_FLOAT
    b.eq 36f
    cmp  w22, #T_DEC
    b.ne 98f
    b    33b
36:
    mov  x0, x19
    mov  w1, w20
    bl   dec_to_double
    fmov x0, d0
    b    99f

    // ---------------------------------------------------------- FLOAT64 ->
40: fmov d0, x19
    cmp  w22, #T_FLOAT
    b.eq 97f
    cmp  w22, #T_INT
    b.ne 41f
    mov  x9, #0xc3e0000000000000    // -2^63
    fmov d1, x9
    fcmp d0, d1
    b.lt 96f                        // also NaN (unordered)
    mov  x9, #0x43e0000000000000    // 2^63
    fmov d1, x9
    fcmp d0, d1
    b.ge 96f
    fcvtzs x0, d0                   // truncate toward zero
    b    99f
41: cmp  w22, #T_DEC
    b.ne 98f
    BR_WIDE w21, w9, 42f
    ubfx w1, w21, #T_PREC_SHIFT, #8
    ubfx w2, w21, #T_SCALE_SHIFT, #8
    bl   f64_to_dec
    cbnz w1, 96f
    b    99f
42: mov  w1, w21
    bl   dec_from_f64
    cbnz w1, 96f
    b    99f

    // ----------------------------------------------------------- STRING ->
50: ldr  x1, [x19, #STR_LEN]
    add  x0, x19, #STR_DATA
    bl   trim_all_ws
    mov  x19, x0
    mov  x23, x1
    cmp  w22, #T_BOOL
    b.ne 51f
    bl   parse_bool
    b    58f
51: cmp  w22, #T_INT
    b.ne 52f
    bl   parse_int64
    b    58f
52: cmp  w22, #T_DEC
    b.ne 53f
    ubfx w2, w21, #T_PREC_SHIFT, #8
    ubfx w3, w21, #T_SCALE_SHIFT, #8
    mov  w4, #1                     // CAST: round half away from zero
    BR_WIDE w21, w9, 521f
    bl   parse_decimal
    b    58f
521: bl  parse_dec128
    cbz  w2, 522f
    mov  w1, w2
    b    58f
522: bl  dec_box
    mov  w1, #0
    b    58f
53: cmp  w22, #T_FLOAT
    b.ne 54f
    bl   parse_float
    fmov x0, d0
    b    58f
54: cmp  w22, #T_DATE
    b.ne 55f
    bl   parse_date
    b    58f
55: cmp  w22, #T_TS
    b.ne 98f
    mov  w2, #0                     // timestamp syntax only (types.md §8)
    bl   parse_timestamp
58: cbz  w1, 99f
    cmp  w1, #1
    b.ne 96f                        // valid syntax, does not fit
    mov  w0, w22
    mov  x1, x19
    mov  x2, x23
    bl   cv_conv_error

    // ------------------------------------------------------------- DATE ->
60: cmp  w22, #T_DATE
    b.eq 97f
    cmp  w22, #T_TS
    b.ne 98f
    ldr  x9, =US_PER_DAY
    mul  x0, x19, x9                // midnight
    b    99f

    // -------------------------------------------------------- TIMESTAMP ->
70: cmp  w22, #T_TS
    b.eq 97f
    cmp  w22, #T_DATE
    b.ne 98f
    ldr  x9, =US_PER_DAY            // floor(micros / day)
    sdiv x0, x19, x9
    msub x10, x0, x9, x19
    cmp  x10, #0
    b.ge 99f
    sub  x0, x0, #1
    b    99f

    // ------------------------------------------------------------ common
80: // x0 = decimal value at the target scale: check the target precision
    mov  x19, x0
    ubfx w1, w21, #T_PREC_SHIFT, #8
    bl   dec_fits
    cbz  w0, 96f
    mov  x0, x19
    b    99f
96: mov  w0, w22
    bl   cv_ovf_error
97: mov  x0, x19                    // identity / same representation
    b    99f
98: RAISE ERR_TYPE, "unsupported CAST"
99: ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldr  x23, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF cast_value

    NOTE_GNU_STACK
