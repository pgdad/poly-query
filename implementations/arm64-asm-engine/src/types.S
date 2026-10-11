// =============================================================================
// types.S — SQL type names: alias resolution, parsing and canonical output.
//
// A type is a u32: kind | (precision << 8) | (scale << 16) (see pq.inc).
//
// Functions:
//   type_from_name(x0 ptr, x1 len, w2 nparams, x3 p, x4 s) -> w0 type/-1/-2
//   type_parse(x0 ptr, x1 len)                             -> w0 type/-1/-2
//   type_write(x0 Buf*, w1 type)
// =============================================================================
#include "pq.inc"

#define PARAM_SATURATE 1000000      // numeric parameters are clamped to this

    .section .rodata
// Alias table: .byte kind, .byte length, lowercase name. Terminated by kind 0.
type_names:
    .byte T_BOOL, 4
    .ascii "bool"
    .byte T_BOOL, 7
    .ascii "boolean"
    .byte T_INT, 3
    .ascii "int"
    .byte T_INT, 7
    .ascii "integer"
    .byte T_INT, 6
    .ascii "bigint"
    .byte T_INT, 5
    .ascii "int64"
    .byte T_FLOAT, 6
    .ascii "double"
    .byte T_FLOAT, 5
    .ascii "float"
    .byte T_FLOAT, 4
    .ascii "real"
    .byte T_FLOAT, 7
    .ascii "float64"
    .byte T_STR, 7
    .ascii "varchar"
    .byte T_STR, 4
    .ascii "text"
    .byte T_STR, 6
    .ascii "string"
    .byte T_DATE, 4
    .ascii "date"
    .byte T_TS, 9
    .ascii "timestamp"
    .byte T_DEC, 7
    .ascii "decimal"
    .byte T_DEC, 7
    .ascii "numeric"
    .byte 0, 0

// canonical names indexed by kind (T_NULL is reported as STRING)
    .p2align 3
canon_names:
    .quad n_string, n_boolean, n_int64, n_decimal, n_float64, n_string
    .quad n_date, n_timestamp
n_string:    .asciz "STRING"
n_boolean:   .asciz "BOOLEAN"
n_int64:     .asciz "INT64"
n_decimal:   .asciz "DECIMAL("
n_float64:   .asciz "FLOAT64"
n_date:      .asciz "DATE"
n_timestamp: .asciz "TIMESTAMP"
    .text

// -----------------------------------------------------------------------------
// type_from_name(x0 ptr, x1 len, w2 nparams, x3 p, x4 s) -> w0 type,
//   -1 unknown name, -2 invalid parameters                             (leaf)
// DECIMAL/NUMERIC: 0 params => (18,0), 1 => (p,0), 2 => (p,s) with
// 1 <= p <= 18, 0 <= s <= p. Parameters on any other type => -2.
// Registers: x5 table cursor, w6 entry kind, x7 entry length, x8 index,
//            w9/w10 bytes, w11 scratch.
// -----------------------------------------------------------------------------
FUNC type_from_name
    ADR_L x5, type_names
1:  ldrb w6, [x5]
    cbz  w6, 8f                     // end of table: unknown
    ldrb w7, [x5, #1]
    add  x5, x5, #2
    cmp  x7, x1
    b.ne 4f
    mov  x8, #0
2:  cmp  x8, x7
    b.eq 5f                         // all bytes matched
    ldrb w9, [x0, x8]
    sub  w11, w9, #'A'              // ASCII tolower
    cmp  w11, #25
    b.hi 3f
    add  w9, w9, #32
3:  ldrb w10, [x5, x8]
    cmp  w9, w10
    b.ne 4f
    add  x8, x8, #1
    b    2b
4:  add  x5, x5, x7                 // next entry
    b    1b
5:  cmp  w6, #T_DEC
    b.eq 6f
    cbnz w2, 9f                     // parameters on a non-decimal type
    mov  w0, w6
    ret
6:  cbnz w2, 61f
    mov  w0, #DEC_TYPE(18, 0)       // DECIMAL / NUMERIC
    ret
61: cmp  w2, #2
    b.hi 9f
    csel x4, x4, xzr, eq            // one parameter: scale 0
    cmp  x3, #1
    b.lt 9f
    cmp  x3, #18
    b.gt 9f
    cmp  x4, #0
    b.lt 9f
    cmp  x4, x3
    b.gt 9f
    mov  w0, #T_DEC
    orr  w0, w0, w3, lsl #T_PREC_SHIFT
    orr  w0, w0, w4, lsl #T_SCALE_SHIFT
    ret
8:  mov  w0, #-1
    ret
9:  mov  w0, #-2
    ret
ENDF type_from_name

// -----------------------------------------------------------------------------
// type_parse(x0 ptr, x1 len) -> w0 type / -1 / -2                       (leaf)
// Grammar (whitespace = space/tab/CR/LF allowed between tokens):
//   name [ '(' uint [ ',' uint ] ')' ]      name = [A-Za-z0-9_]+
// Malformed text => -1; then type_from_name decides (tail call).
// Registers: x0 cursor, x1 end, x5 name ptr, x6 name len, x2 nparams,
//            x3 p, x4 s, w9 byte, x10/x11 scratch.
// -----------------------------------------------------------------------------
// SKIPWS: advance x0 over whitespace (bounded by x1).
.macro SKIPWS
7771:
    cmp  x0, x1
    b.hs 7772f
    ldrb w9, [x0]
    cmp  w9, #' '
    b.eq 7773f
    sub  w10, w9, #9                // '\t' (9) or '\n' (10)
    cmp  w10, #1
    b.ls 7773f
    cmp  w9, #'\r'
    b.ne 7772f
7773:
    add  x0, x0, #1
    b    7771b
7772:
.endm

// PARSE_UINT reg, fail: read [0-9]+ at x0 into reg (saturating); `fail` if
// there is no digit.
.macro PARSE_UINT reg, fail
    mov  \reg, #0
    mov  x11, x0
7781:
    cmp  x0, x1
    b.hs 7782f
    ldrb w9, [x0]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi 7782f
    mov  x10, #10
    madd \reg, \reg, x10, x9
    ldr  x10, =PARAM_SATURATE
    cmp  \reg, x10
    csel \reg, \reg, x10, ls
    add  x0, x0, #1
    b    7781b
7782:
    cmp  x0, x11
    b.eq \fail
.endm

FUNC type_parse
    add  x1, x0, x1
    SKIPWS
    mov  x5, x0                     // identifier
1:  cmp  x0, x1
    b.hs 2f
    ldrb w9, [x0]
    cmp  w9, #'_'
    b.eq 11f
    sub  w10, w9, #'0'
    cmp  w10, #9
    b.ls 11f
    orr  w10, w9, #0x20
    sub  w10, w10, #'a'
    cmp  w10, #25
    b.hi 2f
11: add  x0, x0, #1
    b    1b
2:  sub  x6, x0, x5
    cbz  x6, 9f
    SKIPWS
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0
    cmp  x0, x1
    b.hs 5f
    ldrb w9, [x0]
    cmp  w9, #'('
    b.ne 9f
    add  x0, x0, #1
    SKIPWS
    PARSE_UINT x3, 9f
    mov  x2, #1
    SKIPWS
    cmp  x0, x1
    b.hs 9f
    ldrb w9, [x0]
    cmp  w9, #','
    b.ne 3f
    add  x0, x0, #1
    SKIPWS
    PARSE_UINT x4, 9f
    mov  x2, #2
    SKIPWS
    cmp  x0, x1
    b.hs 9f
    ldrb w9, [x0]
3:  cmp  w9, #')'
    b.ne 9f
    add  x0, x0, #1
    SKIPWS
5:  cmp  x0, x1
    b.ne 9f                         // trailing garbage
    mov  x0, x5
    mov  x1, x6
    b    type_from_name
9:  mov  w0, #-1
    ret
ENDF type_parse

// -----------------------------------------------------------------------------
// type_write(x0 Buf*, w1 type): canonical name; DECIMAL(p,s) without spaces.
// Registers: x19 Buf*, w20 type.
// -----------------------------------------------------------------------------
FUNC type_write
    and  w9, w1, #T_KIND_MASK
    cmp  w9, #T_TS
    b.ls 1f
    mov  w9, #T_STR                 // unknown kind: report STRING
1:  ADR_L x10, canon_names
    cmp  w9, #T_DEC
    b.eq 2f
    ldr  x1, [x10, w9, uxtw #3]
    b    buf_puts
2:  stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  w20, w1
    ldr  x1, [x10, w9, uxtw #3]     // "DECIMAL("
    bl   buf_puts
    mov  x0, x19
    ubfx w1, w20, #T_PREC_SHIFT, #8
    bl   buf_put_u64
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
    mov  x0, x19
    ubfx w1, w20, #T_SCALE_SHIFT, #8
    bl   buf_put_u64
    mov  x0, x19
    mov  w1, #')'
    bl   buf_putc
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF type_write

    NOTE_GNU_STACK
