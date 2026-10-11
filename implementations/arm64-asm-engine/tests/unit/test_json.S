// =============================================================================
// test_json.S — unit tests for json.S (parser, json_get, writer).
//
// Standalone program: prints one line per failed check and a summary;
// exits with status 0 only if every check passed.
// =============================================================================
#include "pq.inc"

    .bss
    .p2align 4
tbuf:    .skip BUF_SIZE             // scratch output buffer
bigbuf:  .skip BUF_SIZE             // large generated documents
n_pass:  .skip 8
n_fail:  .skip 8

    .section .rodata
fmt_fail_i:   .asciz "FAIL [%s]: got %ld (0x%lx), expected %ld (0x%lx)\n"
fmt_fail_s:   .asciz "FAIL [%s]: got '%.*s', expected '%.*s'\n"
fmt_summary:  .asciz "test_json: %ld passed, %ld failed\n"
key_a:        .asciz "a"
key_b:        .asciz "b"
key_bb:       .asciz "bb"
key_c:        .asciz "c"
key_k:        .asciz "k"
    .text

// ------------------------------------------------------------ test macros ---
.macro LSTR rp, rl, s
    .pushsection .rodata.tstr, "a"
.Lts\@: .ascii "\s"
.Lte\@: .byte 0
    .popsection
    ADR_L \rp, .Lts\@
    mov  \rl, #(.Lte\@ - .Lts\@)
.endm

.macro LCSTR rp, s
    .pushsection .rodata.tstr, "a"
.Lcs\@: .asciz "\s"
    .popsection
    ADR_L \rp, .Lcs\@
.endm

.macro CK reg, exp, label
    mov  x0, \reg
    ldr  x1, =\exp
    LCSTR x2, "\label"
    bl   ck_i64
.endm

.macro CKBUF exp, label
    LSTR x0, x1, "\exp"
    LCSTR x2, "\label"
    bl   ck_buf
.endm

// JX_RT "json", "expected compact output"
.macro JX_RT s, exp
    LSTR x0, x1, "\s"
    bl   json_parse
    mov  x19, x0
    cmp  x19, #0
    cset x20, ne
    CK   x20, 1, "json_parse accepts: \s"
    cbz  x19, .Ljx\@
    ADR_L x0, tbuf
    mov  x1, x19
    bl   json_write
    CKBUF "\exp", "json_write: \s"
.Ljx\@:
.endm

// JX_BAD "json": must be rejected
.macro JX_BAD s
    LSTR x0, x1, "\s"
    bl   json_parse
    CK   x0, 0, "json_parse rejects: \s"
.endm

// JX_STR "json string literal", "expected decoded bytes"
.macro JX_STR s, exp
    LSTR x0, x1, "\s"
    bl   json_parse
    mov  x19, x0
    cmp  x19, #0
    cset x20, ne
    CK   x20, 1, "json_parse string: \s"
    cbz  x19, .Ljs\@
    ldr  w20, [x19, #JN_TYPE]
    CK   x20, J_STR, "string node type: \s"
    ldr  x9, [x19, #JN_PTR]
    ldr  x2, [x9, #STR_LEN]
    add  x1, x9, #STR_DATA
    ADR_L x0, tbuf
    bl   buf_put
    CKBUF "\exp", "decoded: \s"
.Ljs\@:
.endm

// --------------------------------------------------------- check helpers ---

// ck_i64(x0 got, x1 expected, x2 label)
LFUNC ck_i64
    cmp  x0, x1
    b.ne 1f
    ADR_L x9, n_pass
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ret
1:  stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x5, x1
    mov  x4, x1
    mov  x3, x0
    mov  x1, x2
    mov  x2, x0
    ADR_L x0, fmt_fail_i
    bl   printf
    ADR_L x9, n_fail
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ldp  x29, x30, [sp], #16
    ret
ENDF ck_i64

// ck_buf(x0 expected ptr, x1 expected len, x2 label): compare tbuf, reset it.
LFUNC ck_buf
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ADR_L x9, tbuf
    ldr  x10, [x9, #BUF_LEN]
    cmp  x10, x20
    b.ne 2f
    cbz  x20, 1f
    ldr  x0, [x9, #BUF_PTR]
    mov  x1, x19
    mov  x2, x20
    bl   memcmp
    cbnz w0, 2f
1:  ADR_L x9, n_pass
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    b    3f
2:  ADR_L x9, tbuf
    ADR_L x0, fmt_fail_s
    mov  x1, x21
    ldr  x2, [x9, #BUF_LEN]
    ldr  x3, [x9, #BUF_PTR]
    mov  x4, x20
    mov  x5, x19
    bl   printf
    ADR_L x9, n_fail
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
3:  ADR_L x9, tbuf
    str  xzr, [x9, #BUF_LEN]
    ldp  x19, x20, [sp, #16]
    ldr  x21, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF ck_buf

// nested(x0 depth) -> x0 JNode* of json_parse("[[[...]]]") with `depth` levels
// (generated in bigbuf).
LFUNC nested
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    ADR_L x20, bigbuf
    str  xzr, [x20, #BUF_LEN]
    mov  x0, x20
    lsl  x1, x19, #1
    bl   buf_reserve
    mov  w1, #'['
    mov  x2, x19
    bl   memset
    mov  x0, x20
    lsl  x1, x19, #1
    bl   buf_reserve
    add  x0, x0, x19
    mov  w1, #']'
    mov  x2, x19
    bl   memset
    ldr  x0, [x20, #BUF_PTR]
    lsl  x1, x19, #1
    bl   json_parse
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF nested

// ------------------------------------------------------------- the tests ---

LFUNC test_syntax
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    JX_RT " { \"a\" : [1, 2.5e3, -0, true, false, null, \"x\\u00e9\\ud83d\\ude00\\n\"] } ", "{\"a\":[1,2.5e3,-0,true,false,null,\"x\303\251\360\237\230\200\\n\"]}"
    JX_RT "[]", "[]"
    JX_RT "{}", "{}"
    JX_RT " [ [ ] , { } ] ", "[[],{}]"
    JX_RT "0", "0"
    JX_RT "-0.0e-0", "-0.0e-0"
    JX_RT "1E+10", "1E+10"
    JX_RT "123.456e-7", "123.456e-7"
    JX_RT "12345678901234567890123", "12345678901234567890123"
    JX_RT "\"\"", "\"\""
    JX_RT "true", "true"
    JX_RT "false", "false"
    JX_RT "null", "null"
    JX_RT "{\"a\":1,\"a\":2}", "{\"a\":1,\"a\":2}"
    JX_RT "\"\303\251\360\237\230\200\"", "\"\303\251\360\237\230\200\""
    JX_RT "\"\\u0041\\u00DF\\uFFFF\"", "\"A\303\237\357\277\277\""
    JX_RT "\"\\/\"", "\"/\""
    JX_RT "\r\n\t 123 \n", "123"
    JX_RT "{\"k\":{\"n\":[{\"x\":null}]}}", "{\"k\":{\"n\":[{\"x\":null}]}}"
    JX_RT "[1,[2,[3,[4]]],{\"a\":{\"b\":{}}}]", "[1,[2,[3,[4]]],{\"a\":{\"b\":{}}}]"
    JX_RT "\"tab\\tquote\\\"bs\\\\ctl\\u001f\"", "\"tab\\tquote\\\"bs\\\\ctl\\u001f\""

    JX_STR "\"\\u0000a\\/\\b\\f\\n\\r\\t\\\"\\\\\"", "\000a/\b\f\n\r\t\"\\"
    JX_STR "\"\\ud834\\udd1e\"", "\360\235\204\236"
    JX_STR "\"\\u07FF\\u0800\"", "\337\277\340\240\200"
    JX_STR "\"plain text\"", "plain text"
    JX_STR "\"\\uDBFF\\uDFFF\"", "\364\217\277\277"

    JX_BAD ""
    JX_BAD " "
    JX_BAD "[1,]"
    JX_BAD "{\"a\":1,}"
    JX_BAD "[,1]"
    JX_BAD "{,}"
    JX_BAD "[1,,2]"
    JX_BAD "01"
    JX_BAD "[01]"
    JX_BAD "-01"
    JX_BAD "00"
    JX_BAD "NaN"
    JX_BAD "Infinity"
    JX_BAD "-Infinity"
    JX_BAD "[1] x"
    JX_BAD "1 2"
    JX_BAD "\"a\"\"b\""
    JX_BAD "{'a':1}"
    JX_BAD "\"\001\""
    JX_BAD "\"a\tb\""
    JX_BAD "\"a\nb\""
    JX_BAD "\"\\x\""
    JX_BAD "\"\\\""
    JX_BAD "\"\\u12\""
    JX_BAD "\"\\u12G4\""
    JX_BAD "\"\\U0041\""
    JX_BAD "\"\\ud800\""
    JX_BAD "\"\\udc00\""
    JX_BAD "\"\\ud800\\u0041\""
    JX_BAD "\"\\ud800x\""
    JX_BAD "\"\\udbff\\udbff\""
    JX_BAD "\"\377\""
    JX_BAD "\"\300\257\""
    JX_BAD "\"\340\200\257\""
    JX_BAD "\"\355\240\200\""
    JX_BAD "\"\364\220\200\200\""
    JX_BAD "\"\303\""
    JX_BAD "\"\303("
    JX_BAD "\"\200\""
    JX_BAD "// c\n1"
    JX_BAD "/* c */ 1"
    JX_BAD "[1 2]"
    JX_BAD "{\"a\" 1}"
    JX_BAD "{\"a\":}"
    JX_BAD "{1:2}"
    JX_BAD "{\"a\":1 \"b\":2}"
    JX_BAD "tru"
    JX_BAD "nulll"
    JX_BAD "True"
    JX_BAD "-"
    JX_BAD "1."
    JX_BAD "1.e5"
    JX_BAD ".5"
    JX_BAD "1e"
    JX_BAD "1e+"
    JX_BAD "+1"
    JX_BAD "--1"
    JX_BAD "0x10"
    JX_BAD "\"abc"
    JX_BAD "["
    JX_BAD "{"
    JX_BAD "]"
    JX_BAD "}"
    JX_BAD "[1"
    JX_BAD "{\"a\":1"
    JX_BAD "\357\273\277{}"
    JX_BAD "\000"
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF test_syntax

LFUNC test_dom
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    // json_get
    LSTR x0, x1, "{\"a\":1,\"bb\":\"x\",\"a\":3}"
    bl   json_parse
    mov  x21, x0
    ldr  w19, [x21, #JN_TYPE]
    CK   x19, J_OBJ, "object type"
    ldr  w19, [x21, #JN_COUNT]
    CK   x19, 3, "object pair count"
    mov  x0, x21
    ADR_L x1, key_bb
    bl   json_get
    ldr  w19, [x0, #JN_TYPE]
    CK   x19, J_STR, "json_get bb type"
    mov  x0, x21
    ADR_L x1, key_a
    bl   json_get
    ldr  x9, [x0, #JN_PTR]
    ldrb w19, [x9, #STR_DATA]
    CK   x19, '1', "json_get a -> first pair"
    mov  x0, x21
    ADR_L x1, key_c
    bl   json_get
    CK   x0, 0, "json_get missing key"
    mov  x0, x21
    ADR_L x1, key_b
    bl   json_get
    CK   x0, 0, "json_get prefix key"
    mov  x0, #0
    ADR_L x1, key_a
    bl   json_get
    CK   x0, 0, "json_get null node"
    LSTR x0, x1, "[1]"
    bl   json_parse
    ADR_L x1, key_a
    bl   json_get
    CK   x0, 0, "json_get on array"

    // line numbers
    LSTR x0, x1, "\n\n[1,\n2,\n{\"k\":\n3}]"
    bl   json_parse
    mov  x21, x0
    ldr  w19, [x21, #JN_LINE]
    CK   x19, 3, "line of root"
    ldr  w19, [x21, #JN_COUNT]
    CK   x19, 3, "array count"
    ldr  x22, [x21, #JN_PTR]
    ldr  x9, [x22, #8]
    ldr  w19, [x9, #JN_LINE]
    CK   x19, 4, "line of element 2"
    ldr  x9, [x22, #16]
    ldr  w19, [x9, #JN_LINE]
    CK   x19, 5, "line of object"
    ldr  x9, [x22, #16]
    ldr  x22, [x9, #JN_PTR]         // pairs of the object
    ldr  x11, [x22]
    ldr  w19, [x11, #JN_LINE]
    CK   x19, 5, "line of key"
    ldr  x11, [x22, #8]
    ldr  w19, [x11, #JN_LINE]
    CK   x19, 6, "line of value"
    ldr  x11, [x22, #8]
    ldr  w19, [x11, #JN_TYPE]
    CK   x19, J_NUM, "value type"

    // json_parse_prefix
    LSTR x0, x1, "  {\"a\":1}  \n{\"b\":2}"
    bl   json_parse_prefix
    mov  x19, x1
    cmp  x0, #0
    cset x20, ne
    CK   x20, 1, "prefix parse ok"
    CK   x19, 12, "prefix consumed"
    LSTR x0, x1, " 7 "
    bl   json_parse_prefix
    mov  x19, x1
    CK   x19, 3, "prefix consumed all"
    LSTR x0, x1, "x"
    bl   json_parse_prefix
    mov  x19, x1
    CK   x0, 0, "prefix rejects"
    CK   x19, 0, "prefix consumed on error"

    // nesting depth
    mov  x0, #1000
    bl   nested
    cmp  x0, #0
    cset x19, ne
    CK   x19, 1, "depth 1000 accepted"
    mov  x0, #1001
    bl   nested
    CK   x0, 0, "depth 1001 rejected"
    ldr  x0, =200000
    bl   nested
    CK   x0, 0, "depth 200000 rejected"
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF test_dom

// test_large: a ~4 MB array of objects and a 4 MB string parse in linear time.
// Registers: x19 counter, x20 Buf*, x21 node.
#define NBIG 200000
LFUNC test_large
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    ADR_L x20, bigbuf
    str  xzr, [x20, #BUF_LEN]
    mov  x0, x20
    mov  w1, #'['
    bl   buf_putc
    mov  x19, #0
1:  cbz  x19, 2f
    mov  x0, x20
    mov  w1, #','
    bl   buf_putc
2:  mov  x0, x20
    LCSTR x1, "{\"id\":"
    bl   buf_puts
    mov  x0, x20
    mov  x1, x19
    bl   buf_put_u64
    mov  x0, x20
    LCSTR x1, ",\"name\":\"item \\u00e9\",\"v\":-1.5e3}"
    bl   buf_puts
    add  x19, x19, #1
    ldr  x9, =NBIG
    cmp  x19, x9
    b.lo 1b
    mov  x0, x20
    mov  w1, #']'
    bl   buf_putc
    ldr  x0, [x20, #BUF_PTR]
    ldr  x1, [x20, #BUF_LEN]
    bl   json_parse
    mov  x21, x0
    ldr  w19, [x21, #JN_COUNT]
    CK   x19, NBIG, "large array count"
    ldr  x9, [x21, #JN_PTR]
    ldr  x10, =(NBIG - 1)
    ldr  x9, [x9, x10, lsl #3]
    ldr  w19, [x9, #JN_COUNT]
    CK   x19, 3, "large array last object pairs"

    // one 4 MB string with an escape every 64 bytes
    str  xzr, [x20, #BUF_LEN]
    mov  x0, x20
    mov  w1, #'"'
    bl   buf_putc
    mov  x19, #0
3:  mov  x0, x20
    LCSTR x1, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\\n"
    bl   buf_puts
    add  x19, x19, #1
    ldr  x9, =65536
    cmp  x19, x9
    b.lo 3b
    mov  x0, x20
    mov  w1, #'"'
    bl   buf_putc
    ldr  x0, [x20, #BUF_PTR]
    ldr  x1, [x20, #BUF_LEN]
    bl   json_parse
    ldr  x9, [x0, #JN_PTR]
    ldr  x19, [x9, #STR_LEN]
    CK   x19, 63 * 65536, "large string decoded length"
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF test_large

// ------------------------------------------------------------------ main ---
FUNC main
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   test_syntax
    bl   test_dom
    bl   test_large
    ADR_L x0, g_arena                // release request memory
    bl   arena_free
    ADR_L x0, fmt_summary
    LDR_G x1, n_pass
    LDR_G x2, n_fail
    bl   printf
    LDR_G x0, n_fail
    cmp  x0, #0
    cset w0, ne
    ldp  x29, x30, [sp], #16
    ret
ENDF main

    NOTE_GNU_STACK
