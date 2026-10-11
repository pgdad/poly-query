// =============================================================================
// json.S — strict RFC 8259 JSON parser (DOM of JNode, see pq.inc) and writer.
//
// Functions:
//   json_parse(x0 ptr, x1 len)        -> x0 JNode* or 0
//   json_parse_prefix(x0 ptr, x1 len) -> x0 JNode* or 0, x1 bytes consumed
//   json_get(x0 JNode* obj, x1 key)   -> x0 value JNode* or 0
//   json_write(x0 Buf*, x1 JNode*)
//
// All nodes and strings live in the request arena. Parsing is a recursive
// descent in linear time. Rejected: trailing commas, comments, NaN/Infinity,
// leading zeros, control characters (< 0x20) in strings, invalid escapes,
// lone surrogate escapes, invalid UTF-8, nesting deeper than JSON_MAX_DEPTH,
// and (json_parse only) trailing garbage. Duplicate keys are kept.
//
// Parser-internal convention (jp_* functions): the parse state lives in
// callee-saved registers shared by all jp_* routines:
//   x19 cursor, x20 end, x21 current line (1-based), x22 nesting depth,
//   x23 sp of json_parse_prefix's frame (error unwind target),
//   x24 child scratch stack (u64 array), x25 its top index, x26 its capacity.
// jp_* routines may use x27/x28 after saving them. On any syntax error they
// branch to .Ljp_fail, which resets sp to x23 and returns 0 from
// json_parse_prefix (whose epilogue restores the caller's registers).
// Children of arrays/objects are pushed on the scratch stack and copied into
// an exact-size array when the container closes.
// =============================================================================
#include "pq.inc"

#define JSON_MAX_DEPTH  1000
#define SCRATCH_INIT    64          // initial scratch capacity (entries)

    .section .rodata
s_jnull:  .asciz "null"
s_jtrue:  .asciz "true"
s_jfalse: .asciz "false"
    .text

// -----------------------------------------------------------------------------
// json_parse_prefix(x0 ptr, x1 len) -> x0 JNode* or 0, x1 bytes consumed
// Leading and trailing whitespace are consumed. On error x0 = x1 = 0.
// Registers: shared parse state (see header), x27 start pointer.
// -----------------------------------------------------------------------------
FUNC json_parse_prefix
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    mov  x27, x0
    mov  x19, x0
    add  x20, x0, x1
    mov  x21, #1
    mov  x22, #0
    mov  x23, sp
    mov  x0, #(SCRATCH_INIT * 8)
    bl   arena_alloc
    mov  x24, x0
    mov  x25, #0
    mov  x26, #SCRATCH_INIT
    bl   jp_ws
    bl   jp_value
    mov  x28, x0
    bl   jp_ws
    mov  x0, x28
    sub  x1, x19, x27
    b    1f
.Ljp_fail:
    mov  sp, x23
    mov  x0, #0
    mov  x1, #0
1:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #96
    ret
ENDF json_parse_prefix

// -----------------------------------------------------------------------------
// json_parse(x0 ptr, x1 len) -> x0 JNode* or 0 (the whole input must be one
// value, surrounded by optional whitespace).
// Registers: x19 len.
// -----------------------------------------------------------------------------
FUNC json_parse
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x19, x1
    bl   json_parse_prefix
    cmp  x1, x19
    csel x0, x0, xzr, eq            // trailing garbage => 0
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF json_parse

// -----------------------------------------------------------------------------
// jp_ws: skip JSON whitespace (space, tab, CR, LF), counting lines. (leaf)
// -----------------------------------------------------------------------------
LFUNC jp_ws
1:  cmp  x19, x20
    b.hs 9f
    ldrb w9, [x19]
    cmp  w9, #' '
    b.eq 2f
    cmp  w9, #'\n'
    b.eq 3f
    cmp  w9, #'\t'
    b.eq 2f
    cmp  w9, #'\r'
    b.eq 2f
9:  ret
2:  add  x19, x19, #1
    b    1b
3:  add  x19, x19, #1
    add  x21, x21, #1
    b    1b
ENDF jp_ws

// -----------------------------------------------------------------------------
// jp_node(w0 type, x1 extra bytes) -> x0 JNode* with type, line = x21,
// count 0, ptr = 0, followed by `extra` bytes of storage (children array).
// -----------------------------------------------------------------------------
LFUNC jp_node
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  w0, [sp, #16]
    add  x0, x1, #JN_SIZE
    bl   arena_alloc
    ldr  w9, [sp, #16]
    str  w9, [x0, #JN_TYPE]
    str  wzr, [x0, #JN_COUNT]
    str  xzr, [x0, #JN_PTR]
    str  w21, [x0, #JN_LINE]
    str  wzr, [x0, #JN_LINE + 4]
    str  xzr, [x0, #JN_LINE + 8]
    ldp  x29, x30, [sp], #32
    ret
ENDF jp_node

// -----------------------------------------------------------------------------
// jp_push(x0 value): push onto the scratch stack, doubling it (in the arena)
// when full. Preserves nothing but the parse state.
// -----------------------------------------------------------------------------
LFUNC jp_push
    cmp  x25, x26
    b.hs 1f
    str  x0, [x24, x25, lsl #3]
    add  x25, x25, #1
    ret
1:  stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x27, x28, [sp, #16]
    mov  x27, x0
    lsl  x0, x26, #4                // new capacity 2*cap entries (bytes)
    bl   arena_alloc
    mov  x28, x0
    mov  x1, x24
    lsl  x2, x25, #3
    bl   memcpy
    mov  x24, x28
    lsl  x26, x26, #1
    str  x27, [x24, x25, lsl #3]
    add  x25, x25, #1
    ldp  x27, x28, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF jp_push

// -----------------------------------------------------------------------------
// jp_hex4(x0 ptr) -> w0 value of 4 hex digits, or -1.            (leaf)
// Clobbers x9, x10, x14.
// -----------------------------------------------------------------------------
LFUNC jp_hex4
    mov  w14, #0
    mov  x10, #4
1:  ldrb w9, [x0], #1
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.ls 2f
    orr  w9, w9, #0x20              // 'A'-'0' | 0x20 == 'a'-'0'
    sub  w9, w9, #('a' - '0')
    cmp  w9, #5
    b.hi 9f
    add  w9, w9, #10
2:  add  w14, w9, w14, lsl #4
    subs x10, x10, #1
    b.ne 1b
    mov  w0, w14
    ret
9:  mov  w0, #-1
    ret
ENDF jp_hex4

// -----------------------------------------------------------------------------
// jp_string -> x0 Str*: parse a string literal; x19 points at the opening
// quote. Pass 1 scans to the closing quote (rejecting control characters
// and invalid UTF-8, noting escapes); if there were no escapes the bytes are
// copied directly, otherwise pass 2 decodes into an arena buffer of the raw
// length (decoding never grows the text).
// Registers: x27 first content byte, x28 escape flag;
//   pass 2: x11 src, x12 src end, x13 dst, w9/w10 bytes, x15 Str*.
// -----------------------------------------------------------------------------
LFUNC jp_string
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x27, x28, [sp, #16]
    add  x19, x19, #1
    mov  x27, x19
    mov  x28, #0
1:  cmp  x19, x20
    b.hs .Ljp_fail                  // unterminated
    ldrb w9, [x19]
    cmp  w9, #'"'
    b.eq 5f
    cmp  w9, #'\\'
    b.eq 2f
    cmp  w9, #0x20
    b.lo .Ljp_fail                  // raw control character
    cmp  w9, #0x80
    b.hs 3f
    add  x19, x19, #1
    b    1b
2:  mov  x28, #1                    // escape: skip the escaped byte too
    add  x19, x19, #2
    b    1b
3:  // UTF-8 multi-byte sequence: w10 = continuation count, w11..w12 = valid
    // range of the first continuation byte.
    mov  w11, #0x80
    mov  w12, #0xbf
    cmp  w9, #0xc2
    b.lo .Ljp_fail
    cmp  w9, #0xdf
    b.hi 31f
    mov  w10, #1
    b    34f
31: cmp  w9, #0xef
    b.hi 32f
    mov  w10, #2
    cmp  w9, #0xe0
    b.ne 311f
    mov  w11, #0xa0                 // no overlong 3-byte forms
311: cmp w9, #0xed
    b.ne 34f
    mov  w12, #0x9f                 // no UTF-16 surrogates
    b    34f
32: cmp  w9, #0xf4
    b.hi .Ljp_fail
    mov  w10, #3
    cmp  w9, #0xf0
    b.ne 321f
    mov  w11, #0x90                 // no overlong 4-byte forms
321: cmp w9, #0xf4
    b.ne 34f
    mov  w12, #0x8f                 // <= U+10FFFF
34: add  x13, x19, x10              // last continuation byte must be < end
    cmp  x13, x20
    b.hs .Ljp_fail
    ldrb w9, [x19, #1]
    cmp  w9, w11
    b.lo .Ljp_fail
    cmp  w9, w12
    b.hi .Ljp_fail
    add  x19, x19, #2
    subs w10, w10, #1
35: cbz  w10, 1b
    ldrb w9, [x19], #1
    and  w9, w9, #0xc0
    cmp  w9, #0x80
    b.ne .Ljp_fail
    sub  w10, w10, #1
    b    35b

5:  // x19 at the closing quote
    sub  x1, x19, x27               // raw length
    add  x19, x19, #1
    cbnz x28, 6f
    mov  x0, x27
    bl   str_new
    b    9f
6:  stp  x1, xzr, [sp, #-16]!       // keep the raw length across the call
    add  x0, x1, #(STR_DATA + 1)
    bl   arena_alloc
    ldp  x1, xzr, [sp], #16
    mov  x15, x0
    mov  x11, x27                   // src
    add  x12, x27, x1               // src end (closing quote)
    add  x13, x0, #STR_DATA         // dst
7:  cmp  x11, x12
    b.hs 8f
    ldrb w9, [x11], #1
    cmp  w9, #'\\'
    b.eq 71f
    strb w9, [x13], #1
    b    7b
71: ldrb w9, [x11], #1              // escape letter (exists: scan checked)
    cmp  w9, #'"'
    b.eq 72f
    cmp  w9, #'\\'
    b.eq 72f
    cmp  w9, #'/'
    b.eq 72f
    cmp  w9, #'n'
    mov  w10, #'\n'
    b.eq 73f
    cmp  w9, #'t'
    mov  w10, #'\t'
    b.eq 73f
    cmp  w9, #'r'
    mov  w10, #'\r'
    b.eq 73f
    cmp  w9, #'b'
    mov  w10, #8
    b.eq 73f
    cmp  w9, #'f'
    mov  w10, #12
    b.eq 73f
    cmp  w9, #'u'
    b.ne .Ljp_fail
    b    74f
72: strb w9, [x13], #1
    b    7b
73: strb w10, [x13], #1
    b    7b
74: // \uXXXX (with surrogate pairs)
    add  x9, x11, #4
    cmp  x9, x12
    b.hi .Ljp_fail
    mov  x0, x11
    bl   jp_hex4
    tbnz w0, #31, .Ljp_fail
    add  x11, x11, #4
    mov  w16, w0                    // code point
    lsr  w9, w16, #10               // 0x36: D800-DBFF, 0x37: DC00-DFFF
    cmp  w9, #0x37
    b.eq .Ljp_fail                  // lone low surrogate
    cmp  w9, #0x36
    b.ne 76f
    add  x9, x11, #6                // high surrogate: need "\uDC00-DFFF"
    cmp  x9, x12
    b.hi .Ljp_fail
    ldrb w9, [x11]
    cmp  w9, #'\\'
    b.ne .Ljp_fail
    ldrb w9, [x11, #1]
    cmp  w9, #'u'
    b.ne .Ljp_fail
    add  x0, x11, #2
    bl   jp_hex4
    tbnz w0, #31, .Ljp_fail
    lsr  w9, w0, #10
    cmp  w9, #0x37
    b.ne .Ljp_fail
    add  x11, x11, #6
    and  w16, w16, #0x3ff           // cp = 0x10000 + (hi & 0x3ff) << 10
    and  w0, w0, #0x3ff             //                + (lo & 0x3ff)
    add  w16, w0, w16, lsl #10
    add  w16, w16, #0x10000
76: // UTF-8 encode w16
    cmp  w16, #0x80
    b.hs 77f
    strb w16, [x13], #1
    b    7b
77: cmp  w16, #0x800
    b.hs 78f
    lsr  w9, w16, #6
    orr  w9, w9, #0xc0
    strb w9, [x13], #1
    b    791f
78: cmp  w16, #0x10000
    b.hs 79f
    lsr  w9, w16, #12
    orr  w9, w9, #0xe0
    strb w9, [x13], #1
    b    792f
79: lsr  w9, w16, #18
    orr  w9, w9, #0xf0
    strb w9, [x13], #1
    ubfx w9, w16, #12, #6
    orr  w9, w9, #0x80
    strb w9, [x13], #1
792: ubfx w9, w16, #6, #6
    orr  w9, w9, #0x80
    strb w9, [x13], #1
791: and w9, w16, #0x3f
    orr  w9, w9, #0x80
    strb w9, [x13], #1
    b    7b
8:  strb wzr, [x13]
    add  x9, x15, #STR_DATA
    sub  x9, x13, x9
    str  x9, [x15, #STR_LEN]
    mov  x0, x15
9:  ldp  x27, x28, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF jp_string

// -----------------------------------------------------------------------------
// jp_number -> x0 Str* raw literal text. Grammar:
//   -? (0 | [1-9][0-9]*) (\.[0-9]+)? ([eE][+-]?[0-9]+)?
// A digit directly after a leading 0 is rejected (no "01").
// Registers: x27 start, w9 byte.
// -----------------------------------------------------------------------------
// DIGITS fail_if_none: consume [0-9]* ; with fail_if_none=1 require one.
.macro JDIGITS need
    mov  x10, x19
7781:
    cmp  x19, x20
    b.hs 7782f
    ldrb w9, [x19]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi 7782f
    add  x19, x19, #1
    b    7781b
7782:
.if \need
    cmp  x19, x10
    b.eq .Ljp_fail
.endif
.endm

LFUNC jp_number
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x27, x28, [sp, #16]
    mov  x27, x19
    ldrb w9, [x19]
    cmp  w9, #'-'
    b.ne 1f
    add  x19, x19, #1
    cmp  x19, x20
    b.hs .Ljp_fail
    ldrb w9, [x19]
1:  cmp  w9, #'0'
    b.ne 2f
    add  x19, x19, #1               // a lone leading zero
    cmp  x19, x20
    b.hs 5f
    ldrb w9, [x19]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.ls .Ljp_fail                  // "01"
    b    3f
2:  sub  w9, w9, #'1'
    cmp  w9, #8
    b.hi .Ljp_fail
    JDIGITS 0
3:  cmp  x19, x20                   // fraction
    b.hs 5f
    ldrb w9, [x19]
    cmp  w9, #'.'
    b.ne 4f
    add  x19, x19, #1
    JDIGITS 1
    cmp  x19, x20
    b.hs 5f
    ldrb w9, [x19]
4:  orr  w9, w9, #0x20              // exponent
    cmp  w9, #'e'
    b.ne 5f
    add  x19, x19, #1
    cmp  x19, x20
    b.hs .Ljp_fail
    ldrb w9, [x19]
    cmp  w9, #'+'
    b.eq 41f
    cmp  w9, #'-'
    b.ne 42f
41: add  x19, x19, #1
42: JDIGITS 1
5:  mov  x0, x27
    sub  x1, x19, x27
    bl   str_new
    ldp  x27, x28, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF jp_number

// -----------------------------------------------------------------------------
// jp_value -> x0 JNode*: parse one value at x19 (no leading whitespace).
// Registers: x27 scratch base index (containers), x28 line of the value.
// -----------------------------------------------------------------------------
LFUNC jp_value
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x27, x28, [sp, #16]
    cmp  x19, x20
    b.hs .Ljp_fail
    mov  x28, x21
    ldrb w9, [x19]
    cmp  w9, #'"'
    b.eq 10f
    cmp  w9, #'{'
    b.eq 40f
    cmp  w9, #'['
    b.eq 30f
    cmp  w9, #'t'
    b.eq 20f
    cmp  w9, #'f'
    b.eq 21f
    cmp  w9, #'n'
    b.eq 22f
    cmp  w9, #'-'
    b.eq 15f
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.ls 15f
    b    .Ljp_fail

10: bl   jp_string                  // ---- string
    mov  x1, x0
    mov  w0, #J_STR
    b    90f
15: bl   jp_number                  // ---- number
    mov  x1, x0
    mov  w0, #J_NUM
    b    90f

20: sub  x9, x20, x19               // ---- true
    cmp  x9, #4
    b.lo .Ljp_fail
    ldr  w9, [x19]
    movz w10, #0x7274               // "tr"
    movk w10, #0x6575, lsl #16      // "ue"
    cmp  w9, w10
    b.ne .Ljp_fail
    add  x19, x19, #4
    mov  w0, #J_TRUE
    b    80f
21: sub  x9, x20, x19               // ---- false
    cmp  x9, #5
    b.lo .Ljp_fail
    ldr  w9, [x19, #1]
    movz w10, #0x6c61               // "al"
    movk w10, #0x6573, lsl #16      // "se"
    cmp  w9, w10
    b.ne .Ljp_fail
    add  x19, x19, #5
    mov  w0, #J_FALSE
    b    80f
22: sub  x9, x20, x19               // ---- null
    cmp  x9, #4
    b.lo .Ljp_fail
    ldr  w9, [x19]
    movz w10, #0x756e               // "nu"
    movk w10, #0x6c6c, lsl #16      // "ll"
    cmp  w9, w10
    b.ne .Ljp_fail
    add  x19, x19, #4
    mov  w0, #J_NULL
    b    80f

30: // ---- array: '[' ws ( ']' | value (ws ',' ws value)* ws ']' )
    add  x19, x19, #1
    add  x22, x22, #1
    cmp  x22, #JSON_MAX_DEPTH
    b.hi .Ljp_fail
    mov  x27, x25
    bl   jp_ws
    cmp  x19, x20
    b.hs .Ljp_fail
    ldrb w9, [x19]
    cmp  w9, #']'
    b.eq 34f
31: bl   jp_value
    bl   jp_push
    bl   jp_ws
    cmp  x19, x20
    b.hs .Ljp_fail
    ldrb w9, [x19]
    cmp  w9, #','
    b.ne 33f
    add  x19, x19, #1
    bl   jp_ws
    b    31b
33: cmp  w9, #']'
    b.ne .Ljp_fail
34: add  x19, x19, #1
    mov  w0, #J_ARR
    b    50f

40: // ---- object: '{' ws ( '}' | pair (ws ',' ws pair)* ws '}' )
    add  x19, x19, #1
    add  x22, x22, #1
    cmp  x22, #JSON_MAX_DEPTH
    b.hi .Ljp_fail
    mov  x27, x25
    bl   jp_ws
    cmp  x19, x20
    b.hs .Ljp_fail
    ldrb w9, [x19]
    cmp  w9, #'}'
    b.eq 44f
41: cmp  x19, x20                   // key
    b.hs .Ljp_fail
    ldrb w9, [x19]
    cmp  w9, #'"'
    b.ne .Ljp_fail
    mov  x0, x21                    // line of the key (kept on the stack)
    stp  x0, xzr, [sp, #-16]!
    bl   jp_string
    ldp  x9, xzr, [sp], #16
    stp  x0, x9, [sp, #-16]!        // Str*, line
    mov  w0, #J_STR
    mov  x1, #0
    bl   jp_node
    ldp  x9, x10, [sp], #16
    str  x9, [x0, #JN_PTR]
    str  w10, [x0, #JN_LINE]
    bl   jp_push
    bl   jp_ws                      // ':'
    cmp  x19, x20
    b.hs .Ljp_fail
    ldrb w9, [x19]
    cmp  w9, #':'
    b.ne .Ljp_fail
    add  x19, x19, #1
    bl   jp_ws
    bl   jp_value                   // value
    bl   jp_push
    bl   jp_ws
    cmp  x19, x20
    b.hs .Ljp_fail
    ldrb w9, [x19]
    cmp  w9, #','
    b.ne 43f
    add  x19, x19, #1
    bl   jp_ws
    b    41b
43: cmp  w9, #'}'
    b.ne .Ljp_fail
44: add  x19, x19, #1
    mov  w0, #J_OBJ

50: // ---- close container: node + exact-size child array in one block
    sub  x22, x22, #1
    sub  x9, x25, x27               // number of pushed entries
    stp  x9, xzr, [sp, #-16]!
    lsl  x1, x9, #3
    mov  w10, w0
    stp  x10, xzr, [sp, #-16]!
    bl   jp_node
    ldp  x10, xzr, [sp], #16        // type
    ldp  x9, xzr, [sp], #16         // entries
    str  w28, [x0, #JN_LINE]
    cmp  w10, #J_OBJ
    lsr  x11, x9, #1
    csel x11, x11, x9, eq           // OBJ count = pairs
    str  w11, [x0, #JN_COUNT]
    cbz  x9, 52f
    add  x11, x0, #JN_SIZE
    str  x11, [x0, #JN_PTR]
    mov  x12, x0
    stp  x12, xzr, [sp, #-16]!
    mov  x0, x11
    add  x1, x24, x27, lsl #3
    lsl  x2, x9, #3
    bl   memcpy
    ldp  x0, xzr, [sp], #16
52: mov  x25, x27                   // pop the children
    b    99f

80: mov  x1, #0                     // literal without payload
90: // scalar node: w0 type, x1 Str*
    stp  x1, xzr, [sp, #-16]!
    mov  x1, #0
    bl   jp_node
    ldp  x1, xzr, [sp], #16
    str  x1, [x0, #JN_PTR]
    str  w28, [x0, #JN_LINE]
99: ldp  x27, x28, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF jp_value

// -----------------------------------------------------------------------------
// json_get(x0 JNode* obj, x1 key cstr) -> x0 value JNode* or 0
// Exact (case-sensitive) match; returns the first matching pair.
// Registers: x19 key, x20 key length, x21 pair cursor, x22 pairs left.
// -----------------------------------------------------------------------------
FUNC json_get
    cbz  x0, 8f
    ldr  w9, [x0, #JN_TYPE]
    cmp  w9, #J_OBJ
    b.ne 8f
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    ldr  w22, [x0, #JN_COUNT]
    ldr  x21, [x0, #JN_PTR]
    mov  x19, x1
    mov  x0, x1
    bl   strlen
    mov  x20, x0
1:  cbz  x22, 6f
    ldr  x9, [x21]                  // key node
    ldr  x9, [x9, #JN_PTR]          // Str*
    ldr  x10, [x9, #STR_LEN]
    cmp  x10, x20
    b.ne 2f
    add  x0, x9, #STR_DATA
    mov  x1, x19
    mov  x2, x20
    bl   memcmp
    cbz  w0, 5f
2:  add  x21, x21, #16
    sub  x22, x22, #1
    b    1b
5:  ldr  x0, [x21, #8]
    b    7f
6:  mov  x0, #0
7:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
8:  mov  x0, #0
    ret
ENDF json_get

// -----------------------------------------------------------------------------
// json_write(x0 Buf*, x1 JNode*): compact serialization (numbers as their raw
// text, strings re-escaped with buf_put_jstr).
// Registers: x19 Buf*, x20 node, x21 child cursor, x22 children left,
//            x23 object flag.
// -----------------------------------------------------------------------------
FUNC json_write
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    str  x23, [sp, #48]
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x1, #JN_TYPE]
    cmp  w9, #J_NUM
    b.ne 1f
    ldr  x9, [x1, #JN_PTR]
    ldr  x2, [x9, #STR_LEN]
    add  x1, x9, #STR_DATA
    bl   buf_put
    b    9f
1:  cmp  w9, #J_STR
    b.ne 2f
    ldr  x9, [x1, #JN_PTR]
    ldr  x2, [x9, #STR_LEN]
    add  x1, x9, #STR_DATA
    bl   buf_put_jstr
    b    9f
2:  cmp  w9, #J_ARR
    b.eq 3f
    cmp  w9, #J_OBJ
    b.eq 3f
    ADR_L x1, s_jnull               // null / false / true
    cmp  w9, #J_TRUE
    b.ne 21f
    ADR_L x1, s_jtrue
21: cmp  w9, #J_FALSE
    b.ne 22f
    ADR_L x1, s_jfalse
22: bl   buf_puts
    b    9f
3:  // containers
    cmp  w9, #J_OBJ
    cset x23, eq
    mov  w1, #'['
    mov  w10, #'{'
    csel w1, w10, w1, eq
    bl   buf_putc
    ldr  x21, [x20, #JN_PTR]
    ldr  w22, [x20, #JN_COUNT]
    cbz  x22, 6f
    b    5f
4:  mov  x0, x19                    // separator between elements
    mov  w1, #','
    bl   buf_putc
5:  mov  x0, x19
    ldr  x1, [x21], #8
    bl   json_write
    cbz  x23, 51f
    mov  x0, x19                    // object: ':' value
    mov  w1, #':'
    bl   buf_putc
    mov  x0, x19
    ldr  x1, [x21], #8
    bl   json_write
51: subs x22, x22, #1
    b.ne 4b
6:  mov  x0, x19
    mov  w1, #']'
    mov  w10, #'}'
    cmp  x23, #0
    csel w1, w10, w1, ne
    bl   buf_putc
9:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldr  x23, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF json_write

    NOTE_GNU_STACK
