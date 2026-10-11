// =============================================================================
// test_values.S — unit tests for values.S, datetime.S, decimal.S, types.S.
//
// Standalone program: prints one line per failed check and a summary;
// exits with status 0 only if every check passed.
// =============================================================================
#include "pq.inc"

    .bss
    .p2align 4
tbuf:    .skip BUF_SIZE             // scratch output buffer
n_pass:  .skip 8
n_fail:  .skip 8

    .section .rodata
fmt_fail_i:   .asciz "FAIL [%s]: got %ld (0x%lx), expected %ld (0x%lx)\n"
fmt_fail_s:   .asciz "FAIL [%s]: got '%.*s', expected '%.*s'\n"
fmt_summary:  .asciz "test_values: %ld passed, %ld failed\n"
    .text

// ------------------------------------------------------------ test macros ---
// LSTR rp, rl, "text": address and length of a string literal.
.macro LSTR rp, rl, s
    .pushsection .rodata.tstr, "a"
.Lts\@: .ascii "\s"
.Lte\@: .byte 0
    .popsection
    ADR_L \rp, .Lts\@
    mov  \rl, #(.Lte\@ - .Lts\@)
.endm

// LCSTR rp, "text": address of a NUL-terminated string literal.
.macro LCSTR rp, s
    .pushsection .rodata.tstr, "a"
.Lcs\@: .asciz "\s"
    .popsection
    ADR_L \rp, .Lcs\@
.endm

// LSTRO rp, "text": address of a static Str object (u64 len, bytes, NUL).
.macro LSTRO rp, s
    .pushsection .rodata.tstro, "a"
    .p2align 3
.Lso\@: .quad .Lse\@ - .Lsd\@
.Lsd\@: .ascii "\s"
.Lse\@: .byte 0
    .popsection
    ADR_L \rp, .Lso\@
.endm

// LDBL reg, value: reg = bit pattern of a double constant.
.macro LDBL reg, val
    .pushsection .rodata.tdbl, "a"
    .p2align 3
.Ld\@: .double \val
    .popsection
    ADR_L \reg, .Ld\@
    ldr  \reg, [\reg]
.endm

// CK reg, expected, "label": integer equality check.
.macro CK reg, exp, label
    mov  x0, \reg
    ldr  x1, =\exp
    LCSTR x2, "\label"
    bl   ck_i64
.endm

// CKBUF "expected", "label": compare tbuf with the text, then clear tbuf.
.macro CKBUF exp, label
    LSTR x0, x1, "\exp"
    LCSTR x2, "\label"
    bl   ck_buf
.endm

.macro C_INT s, expv, expst
    LSTR x0, x1, "\s"
    bl   parse_int64
    mov  x19, x0
    mov  w20, w1
    CK   x20, \expst, "parse_int64 status: \s"
.if \expst == 0
    CK   x19, \expv, "parse_int64 value: \s"
.endif
.endm

.macro C_BOOL s, expv, expst
    LSTR x0, x1, "\s"
    bl   parse_bool
    mov  x19, x0
    mov  w20, w1
    CK   x20, \expst, "parse_bool status: \s"
.if \expst == 0
    CK   x19, \expv, "parse_bool value: \s"
.endif
.endm

.macro C_FLT s, expd, expst
    LSTR x0, x1, "\s"
    bl   parse_float
    fmov x19, d0
    mov  w20, w1
    CK   x20, \expst, "parse_float status: \s"
.if \expst == 0
    LDBL x1, \expd
    mov  x0, x19
    LCSTR x2, "parse_float value: \s"
    bl   ck_i64
.endif
.endm

// C_DATE "text", days, status: parse, and (if valid) format back to the text.
.macro C_DATE s, expv, expst
    LSTR x0, x1, "\s"
    bl   parse_date
    mov  x19, x0
    mov  w20, w1
    CK   x20, \expst, "parse_date status: \s"
.if \expst == 0
    CK   x19, \expv, "parse_date value: \s"
    ADR_L x0, tbuf
    mov  x1, x19
    bl   fmt_date
    CKBUF "\s", "fmt_date: \s"
.endif
.endm

// C_TS "text", allow_date, status, "formatted"
.macro C_TS s, allow, expst, expfmt
    LSTR x0, x1, "\s"
    mov  w2, #\allow
    bl   parse_timestamp
    mov  x19, x0
    mov  w20, w1
    CK   x20, \expst, "parse_timestamp status: \s"
.if \expst == 0
    ADR_L x0, tbuf
    mov  x1, x19
    bl   fmt_timestamp
    CKBUF "\expfmt", "fmt_timestamp of parsed: \s"
.endif
.endm

// C_TSV micros, "formatted"
.macro C_TSV v, expfmt
    ADR_L x0, tbuf
    ldr  x1, =\v
    bl   fmt_timestamp
    CKBUF "\expfmt", "fmt_timestamp: \expfmt"
.endm

// C_TSP "text", micros: parse_timestamp(allow_date=1) value check
.macro C_TSP s, expv
    LSTR x0, x1, "\s"
    mov  w2, #1
    bl   parse_timestamp
    mov  x19, x0
    mov  w20, w1
    CK   x20, 0, "parse_timestamp status: \s"
    CK   x19, \expv, "parse_timestamp value: \s"
.endm

.macro C_FMTDEC v, s, exp
    ADR_L x0, tbuf
    ldr  x1, =\v
    mov  w2, #\s
    bl   fmt_decimal
    CKBUF "\exp", "fmt_decimal \v scale \s"
.endm

.macro C_PDEC s, p, sc, mode, expv, expst
    LSTR x0, x1, "\s"
    mov  w2, #\p
    mov  w3, #\sc
    mov  w4, #\mode
    bl   parse_decimal
    mov  x19, x0
    mov  w20, w1
    CK   x20, \expst, "parse_decimal status: \s (\p,\sc) mode \mode"
.if \expst == 0
    CK   x19, \expv, "parse_decimal value: \s (\p,\sc) mode \mode"
.endif
.endm

.macro C_RESC v, from, to, expv, expst
    ldr  x0, =\v
    mov  w1, #\from
    mov  w2, #\to
    bl   dec_rescale
    mov  x19, x0
    mov  w20, w1
    CK   x20, \expst, "dec_rescale status: \v \from->\to"
.if \expst == 0
    CK   x19, \expv, "dec_rescale value: \v \from->\to"
.endif
.endm

.macro C_F2D d, p, s, expv, expst
    LDBL x9, \d
    fmov d0, x9
    mov  w1, #\p
    mov  w2, #\s
    bl   f64_to_dec
    mov  x19, x0
    mov  w20, w1
    CK   x20, \expst, "f64_to_dec status: \d (\p,\s)"
.if \expst == 0
    CK   x19, \expv, "f64_to_dec value: \d (\p,\s)"
.endif
.endm

.macro C_D2F v, s, expd
    ldr  x0, =\v
    mov  w1, #\s
    bl   dec_to_f64
    fmov x0, d0
    LDBL x1, \expd
    LCSTR x2, "dec_to_f64: \v scale \s"
    bl   ck_i64
.endm

.macro C_TYPE s, exp
    LSTR x0, x1, "\s"
    bl   type_parse
    sxtw x0, w0
    ldr  x1, =\exp
    LCSTR x2, "type_parse: \s"
    bl   ck_i64
.endm

.macro C_TWRITE t, exp
    ADR_L x0, tbuf
    ldr  x1, =\t
    bl   type_write
    CKBUF "\exp", "type_write: \exp"
.endm

// C_JSONV isnull, type, "expected": write_value_json of the payload in x19
.macro C_JSONV isnull, type, exp
    ADR_L x0, tbuf
    mov  x1, x19
    mov  x2, #\isnull
    ldr  x3, =\type
    bl   write_value_json
    CKBUF "\exp", "write_value_json: \exp"
.endm

// C_TOSTR type, "expected": value_to_str of x19
.macro C_TOSTR type, exp
    mov  x0, x19
    ldr  x1, =\type
    bl   value_to_str
    ldr  x2, [x0, #STR_LEN]
    add  x1, x0, #STR_DATA
    ADR_L x0, tbuf
    bl   buf_put
    CKBUF "\exp", "value_to_str: \exp"
.endm

// C_CMP type, expected: value_cmp(x19, x20)
.macro C_CMP type, exp, label
    mov  x0, x19
    mov  x1, x20
    ldr  x2, =\type
    bl   value_cmp
    sxtw x0, w0
    ldr  x1, =\exp
    LCSTR x2, "value_cmp: \label"
    bl   ck_i64
.endm

.macro C_ALLOWED from, to, exp
    ldr  x0, =\from
    ldr  x1, =\to
    bl   cast_allowed
    mov  w0, w0
    ldr  x1, =\exp
    LCSTR x2, "cast_allowed \from -> \to"
    bl   ck_i64
.endm

// C_CAST from, to, expv, experr, "label": cast_value(x19)
.macro C_CAST from, to, expv, experr, label
    mov  x0, x19
    ldr  x1, =\from
    ldr  x2, =\to
    bl   try_cast
    mov  x20, x0
    mov  x21, x1
    CK   x21, \experr, "cast error code: \label"
.if \experr == 0
    CK   x20, \expv, "cast value: \label"
.endif
.endm

// C_CASTS from, "expected text": cast_value(x19) to STRING
.macro C_CASTS from, exp
    mov  x0, x19
    ldr  x1, =\from
    mov  x2, #T_STR
    bl   try_cast
    mov  x20, x0
    CK   x1, 0, "cast to string error: \exp"
    ldr  x2, [x20, #STR_LEN]
    add  x1, x20, #STR_DATA
    ADR_L x0, tbuf
    bl   buf_put
    CKBUF "\exp", "cast to string: \exp"
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

// try_cast(x0 payload, w1 from, w2 to) -> x0 result, x1 error code (0 = ok)
// Catches pq_raise via setjmp on g_jmpbuf (as the request dispatcher does).
LFUNC try_cast
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
    mov  w20, w1
    mov  w21, w2
    TLS_ADDR x0, g_jmpbuf
    bl   _setjmp
    cbnz w0, 1f
    mov  x0, x19
    mov  w1, w20
    mov  w2, w21
    bl   cast_value
    mov  x1, #0
    b    2f
1:  TLS_ADDR x9, g_err_code
    ldr  w1, [x9]
    mov  x0, #0
2:  ldp  x19, x20, [sp, #16]
    ldr  x21, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF try_cast

// ------------------------------------------------------------- the tests ---

// test_calendar: every day 0001-01-01 .. 9999-12-31 round-trips through
// civil_from_days/days_from_civil and consecutive days are consecutive dates.
// Registers: x19 day, x20 last day, x21 prev y, x22 prev m, x23 prev d,
//            x24 error count.
LFUNC test_calendar
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    ldr  x19, =-719162              // 0001-01-01
    ldr  x20, =2932896              // 9999-12-31
    mov  x21, #0
    mov  x22, #12
    mov  x23, #31                   // "0000-12-31"
    mov  x24, #0
1:  mov  x0, x19
    bl   civil_from_days
    mov  x9, x0
    mov  x10, x1
    mov  x11, x2
    // successor check: same month d+1, or next month day 1, or next year 01-01
    add  x12, x23, #1
    cmp  x9, x21
    b.ne 3f
    cmp  x10, x22
    b.ne 2f
    cmp  x11, x12
    b.eq 5f
    b    4f
2:  add  x12, x22, #1
    cmp  x10, x12
    b.ne 4f
    cmp  x11, #1
    b.eq 5f
    b    4f
3:  add  x12, x21, #1
    cmp  x9, x12
    b.ne 4f
    cmp  x10, #1
    b.ne 4f
    cmp  x11, #1
    b.ne 4f
    cmp  x23, #31
    b.ne 4f
    cmp  x22, #12
    b.eq 5f
4:  add  x24, x24, #1
5:  mov  x21, x9
    mov  x22, x10
    mov  x23, x11
    mov  x0, x9
    mov  x1, x10
    mov  x2, x11
    bl   days_from_civil
    cmp  x0, x19
    cinc x24, x24, ne
    add  x19, x19, #1
    cmp  x19, x20
    b.le 1b
    CK   x24, 0, "calendar round trip errors"
    CK   x21, 9999, "calendar last year"
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF test_calendar

LFUNC test_datetime
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    C_DATE "1970-01-01", 0, 0
    C_DATE "1969-12-31", -1, 0
    C_DATE "2000-03-01", 11017, 0
    C_DATE "0001-01-01", -719162, 0
    C_DATE "9999-12-31", 2932896, 0
    C_DATE "2000-02-29", 11016, 0
    C_DATE "2024-02-29", 19782, 0
    C_DATE "1600-02-29", -135081, 0
    C_DATE "1900-02-29", 0, 1
    C_DATE "2023-02-29", 0, 1
    C_DATE "2100-02-29", 0, 1
    C_DATE "0000-01-01", 0, 1
    C_DATE "2024-13-01", 0, 1
    C_DATE "2024-00-10", 0, 1
    C_DATE "2024-04-31", 0, 1
    C_DATE "2024-01-00", 0, 1
    C_DATE "2024-1-01", 0, 1
    C_DATE "2024-01-01x", 0, 1
    C_DATE " 2024-01-01", 0, 1
    C_DATE "2024/01/01", 0, 1
    C_DATE "", 0, 1
    C_DATE "20a4-01-01", 0, 1

    C_TS "1970-01-01 00:00:00", 0, 0, "1970-01-01 00:00:00"
    C_TS "1969-12-31 23:59:59.999999", 0, 0, "1969-12-31 23:59:59.999999"
    C_TS "2024-02-29T12:34:56.5", 0, 0, "2024-02-29 12:34:56.500000"
    C_TS "2024-02-29 12:34:56.000000", 0, 0, "2024-02-29 12:34:56"
    C_TS "0001-01-01 00:00:00", 0, 0, "0001-01-01 00:00:00"
    C_TS "9999-12-31 23:59:59.999999", 0, 0, "9999-12-31 23:59:59.999999"
    C_TS "1900-03-01 01:02:03.000004", 0, 0, "1900-03-01 01:02:03.000004"
    C_TS "2024-01-01", 1, 0, "2024-01-01 00:00:00"
    C_TS "2024-01-01", 0, 1, ""
    C_TS "2024-01-01 24:00:00", 1, 1, ""
    C_TS "2024-01-01 12:60:00", 1, 1, ""
    C_TS "2024-01-01 12:00:60", 1, 1, ""
    C_TS "2024-01-01 12:00:00.", 1, 1, ""
    C_TS "2024-01-01 12:00:00.1234567", 1, 1, ""
    C_TS "2024-01-01x12:00:00", 1, 1, ""
    C_TS "2024-01-01 12:00", 1, 1, ""
    C_TS "2024-01-01 12:00:0a", 1, 1, ""
    C_TS "2024-01-01 12:00:00.12a", 1, 1, ""
    C_TS "2023-02-29 12:00:00", 1, 1, ""
    C_TSP "1970-01-01 00:00:01", 1000000
    C_TSP "1969-12-31 23:59:59.999999", -1
    C_TSP "1970-01-02", 86400000000
    C_TSP "0001-01-01 00:00:00", -62135596800000000
    C_TSV 0, "1970-01-01 00:00:00"
    C_TSV -1, "1969-12-31 23:59:59.999999"
    C_TSV -86400000000, "1969-12-31 00:00:00"
    C_TSV -86400000001, "1969-12-30 23:59:59.999999"
    C_TSV 1, "1970-01-01 00:00:00.000001"
    C_TSV 253402300799999999, "9999-12-31 23:59:59.999999"
    C_TSV 951782400000000, "2000-02-29 00:00:00"
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF test_datetime

LFUNC test_scalars
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    C_INT "0", 0, 0
    C_INT "42", 42, 0
    C_INT "+42", 42, 0
    C_INT "-42", -42, 0
    C_INT "0001", 1, 0
    C_INT "9223372036854775807", 9223372036854775807, 0
    C_INT "-9223372036854775808", -9223372036854775808, 0
    C_INT "9223372036854775808", 0, 2
    C_INT "-9223372036854775809", 0, 2
    C_INT "18446744073709551616", 0, 2
    C_INT "99999999999999999999999", 0, 2
    C_INT "99999999999999999999x", 0, 1
    C_INT "", 0, 1
    C_INT "-", 0, 1
    C_INT "+", 0, 1
    C_INT "12a", 0, 1
    C_INT " 12", 0, 1
    C_INT "1.0", 0, 1
    C_INT "--1", 0, 1

    C_BOOL "true", 1, 0
    C_BOOL "TRUE", 1, 0
    C_BOOL "tRuE", 1, 0
    C_BOOL "false", 0, 0
    C_BOOL "False", 0, 0
    C_BOOL "yes", 0, 1
    C_BOOL "true ", 0, 1
    C_BOOL "t", 0, 1
    C_BOOL "", 0, 1
    C_BOOL "fals3", 0, 1

    C_FLT "1.5", 1.5, 0
    C_FLT "-.5e1", -5.0, 0
    C_FLT "+3.", 3.0, 0
    C_FLT "0.1", 0.1, 0
    C_FLT "1E3", 1000.0, 0
    C_FLT "2.5e-3", 0.0025, 0
    C_FLT "123", 123.0, 0
    C_FLT "1e-400", 0.0, 0
    C_FLT "1.7976931348623157e308", 1.7976931348623157e308, 0
    C_FLT "1e400", 0, 2
    C_FLT "-1e400", 0, 2
    C_FLT "inf", 0, 1
    C_FLT "nan", 0, 1
    C_FLT "Infinity", 0, 1
    C_FLT "1e", 0, 1
    C_FLT "1e+", 0, 1
    C_FLT ".", 0, 1
    C_FLT "", 0, 1
    C_FLT "+", 0, 1
    C_FLT ".e1", 0, 1
    C_FLT "0x10", 0, 1
    C_FLT " 1", 0, 1
    C_FLT "1 ", 0, 1
    C_FLT "1.2.3", 0, 1
    C_FLT "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.5", 0.5, 0

    // trimming
    LSTR x0, x1, " \t\r\nab c \n\r"
    bl   trim_all_ws
    mov  x2, x1
    mov  x1, x0
    ADR_L x0, tbuf
    bl   buf_put
    CKBUF "ab c", "trim_all_ws"
    LSTR x0, x1, "\t\n a \t"
    bl   trim_ws
    mov  x2, x1
    mov  x1, x0
    ADR_L x0, tbuf
    bl   buf_put
    CKBUF "\n a", "trim_ws"
    LSTR x0, x1, "   "
    bl   trim_all_ws
    CK   x1, 0, "trim_all_ws blank"
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF test_scalars

LFUNC test_decimal
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  w0, #18
    bl   pow10_i64
    mov  x19, x0
    CK   x19, 1000000000000000000, "pow10_i64(18)"
    mov  w0, #0
    bl   pow10_i64
    mov  x19, x0
    CK   x19, 1, "pow10_i64(0)"
    ldr  x0, =999
    mov  w1, #3
    bl   dec_fits
    mov  w19, w0
    CK   x19, 1, "dec_fits 999 p3"
    ldr  x0, =-1000
    mov  w1, #3
    bl   dec_fits
    mov  w19, w0
    CK   x19, 0, "dec_fits -1000 p3"
    ldr  x0, =-9223372036854775808
    mov  w1, #18
    bl   dec_fits
    mov  w19, w0
    CK   x19, 0, "dec_fits INT64_MIN"

    C_FMTDEC -50, 2, "-0.50"
    C_FMTDEC 12, 0, "12"
    C_FMTDEC 0, 3, "0.000"
    C_FMTDEC 123456, 3, "123.456"
    C_FMTDEC -5, 1, "-0.5"
    C_FMTDEC 5, 4, "0.0005"
    C_FMTDEC -123, 0, "-123"
    C_FMTDEC 999999999999999999, 18, "0.999999999999999999"
    C_FMTDEC -999999999999999999, 2, "-9999999999999999.99"
    C_FMTDEC -9223372036854775808, 0, "-9223372036854775808"

    C_PDEC "2.345", 18, 2, 1, 235, 0
    C_PDEC "-2.345", 18, 2, 1, -235, 0
    C_PDEC "1.005", 18, 2, 1, 101, 0
    C_PDEC "1.004", 18, 2, 1, 100, 0
    C_PDEC "1.0049999", 18, 2, 1, 100, 0
    C_PDEC "+.5", 1, 0, 1, 1, 0
    C_PDEC "-0.5", 1, 0, 1, -1, 0
    C_PDEC "-0.4", 1, 0, 1, 0, 0
    C_PDEC "5.", 1, 0, 1, 5, 0
    C_PDEC ".5", 1, 1, 0, 5, 0
    C_PDEC "0012.50", 4, 2, 0, 1250, 0
    C_PDEC "12", 4, 2, 0, 1200, 0
    C_PDEC "999.995", 5, 2, 1, 0, 2
    C_PDEC "999.994", 5, 2, 1, 99999, 0
    C_PDEC "12345678901234567890", 18, 0, 1, 0, 2
    C_PDEC "999999999999999999", 18, 0, 0, 999999999999999999, 0
    C_PDEC "-999999999999999999", 18, 0, 0, -999999999999999999, 0
    C_PDEC "1000000000000000000", 18, 0, 0, 0, 2
    C_PDEC "0.000000000000000001", 18, 18, 0, 1, 0
    C_PDEC "0000000000000000000000000000001.5", 2, 1, 0, 15, 0
    C_PDEC "1.50", 2, 1, 0, 0, 3
    C_PDEC "1.5", 3, 2, 0, 150, 0
    C_PDEC "123.4", 3, 1, 0, 0, 2
    C_PDEC "123.45", 3, 1, 0, 0, 3
    C_PDEC "  1", 3, 0, 1, 0, 1
    C_PDEC "1e5", 9, 0, 1, 0, 1
    C_PDEC ".", 3, 0, 1, 0, 1
    C_PDEC "", 3, 0, 1, 0, 1
    C_PDEC "-", 3, 0, 1, 0, 1
    C_PDEC "1.2.3", 3, 0, 1, 0, 1
    C_PDEC "99999999999999999999999x", 18, 0, 1, 0, 1

    C_RESC 2345, 3, 2, 235, 0
    C_RESC -2345, 3, 2, -235, 0
    C_RESC 2344, 3, 2, 234, 0
    C_RESC 5, 0, 18, 0, 2
    C_RESC 1, 0, 17, 100000000000000000, 0
    C_RESC -999999999999999999, 18, 0, -1, 0
    C_RESC 499999999999999999, 18, 0, 0, 0
    C_RESC 123, 2, 2, 123, 0
    C_RESC 999999999999999999, 0, 1, 0, 2

    C_D2F 12345, 2, 123.45
    C_D2F -5, 1, -0.5
    C_D2F 7, 0, 7.0
    C_D2F 123456789012345678, 18, 0.123456789012345678
    C_D2F 999999999999999999, 2, 9999999999999999.99
    C_D2F -999999999999999999, 17, -9.99999999999999999
    C_D2F 9007199254740993, 0, 9007199254740992.0

    C_F2D 0.125, 3, 2, 13, 0
    C_F2D -0.125, 3, 2, -13, 0
    C_F2D 2.5, 2, 0, 3, 0
    C_F2D -2.5, 2, 0, -3, 0
    C_F2D 1.005, 3, 2, 100, 0
    C_F2D 2.675, 3, 2, 267, 0
    C_F2D 1.5, 18, 17, 150000000000000000, 0
    C_F2D 0.0, 5, 2, 0, 0
    C_F2D -0.001, 5, 2, 0, 0
    C_F2D 1e17, 18, 0, 100000000000000000, 0
    C_F2D 1e18, 18, 0, 0, 2
    C_F2D 1e300, 18, 0, 0, 2
    C_F2D 99.995, 4, 2, 0, 2
    C_F2D 123.456, 6, 3, 123456, 0
    C_F2D 0.1, 18, 18, 100000000000000006, 0
    // NaN / infinity
    mov  x9, #0x7ff8000000000000
    fmov d0, x9
    mov  w1, #10
    mov  w2, #2
    bl   f64_to_dec
    mov  w19, w1
    CK   x19, 2, "f64_to_dec NaN"
    mov  x9, #0xfff0000000000000
    fmov d0, x9
    mov  w1, #10
    mov  w2, #2
    bl   f64_to_dec
    mov  w19, w1
    CK   x19, 2, "f64_to_dec -inf"
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF test_decimal

LFUNC test_types
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    C_TYPE "NUMERIC(4,2)", DEC_TYPE(4,2)
    C_TYPE "decimal( 10 , 2 )", DEC_TYPE(10,2)
    C_TYPE "  Decimal ( 18 )  ", DEC_TYPE(18,0)
    C_TYPE "DECIMAL", DEC_TYPE(18,0)
    C_TYPE "numeric", DEC_TYPE(18,0)
    C_TYPE "decimal(1,1)", DEC_TYPE(1,1)
    C_TYPE "int", T_INT
    C_TYPE "INTEGER", T_INT
    C_TYPE "BigInt", T_INT
    C_TYPE "int64", T_INT
    C_TYPE "bool", T_BOOL
    C_TYPE "BOOLEAN", T_BOOL
    C_TYPE "double", T_FLOAT
    C_TYPE "FLOAT", T_FLOAT
    C_TYPE " real ", T_FLOAT
    C_TYPE "float64", T_FLOAT
    C_TYPE "VARCHAR", T_STR
    C_TYPE "text", T_STR
    C_TYPE "String", T_STR
    C_TYPE "date", T_DATE
    C_TYPE "Timestamp", T_TS
    C_TYPE "DECIMAL(19,2)", -2
    C_TYPE "DECIMAL(5,6)", -2
    C_TYPE "decimal(0)", -2
    C_TYPE "decimal(99999999999999999999,1)", -2
    C_TYPE "INT(3)", -2
    C_TYPE "date(1,2)", -2
    C_TYPE "foo", -1
    C_TYPE "", -1
    C_TYPE "   ", -1
    C_TYPE "DECIMAL(5,2) x", -1
    C_TYPE "DECIMAL(", -1
    C_TYPE "DECIMAL()", -1
    C_TYPE "DECIMAL(5,)", -1
    C_TYPE "DECIMAL(5", -1
    C_TYPE "DECIMAL(-1)", -1
    C_TYPE "int4", -1
    C_TYPE "integers", -1

    // type_from_name with explicit parameters
    LSTR x0, x1, "Numeric"
    mov  w2, #2
    mov  x3, #18
    mov  x4, #18
    bl   type_from_name
    sxtw x19, w0
    CK   x19, DEC_TYPE(18,18), "type_from_name numeric(18,18)"
    LSTR x0, x1, "Numeric"
    mov  w2, #2
    mov  x3, #5
    mov  x4, #-1
    bl   type_from_name
    sxtw x19, w0
    CK   x19, -2, "type_from_name numeric(5,-1)"

    C_TWRITE DEC_TYPE(18,2), "DECIMAL(18,2)"
    C_TWRITE DEC_TYPE(5,0), "DECIMAL(5,0)"
    C_TWRITE T_NULL, "STRING"
    C_TWRITE T_BOOL, "BOOLEAN"
    C_TWRITE T_INT, "INT64"
    C_TWRITE T_FLOAT, "FLOAT64"
    C_TWRITE T_STR, "STRING"
    C_TWRITE T_DATE, "DATE"
    C_TWRITE T_TS, "TIMESTAMP"
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF test_types

LFUNC test_values
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    // write_value_json
    mov  x19, #0
    C_JSONV 1, T_INT, "null"
    C_JSONV 0, T_NULL, "null"
    mov  x19, #1
    C_JSONV 0, T_BOOL, "true"
    mov  x19, #0
    C_JSONV 0, T_BOOL, "false"
    ldr  x19, =-42
    C_JSONV 0, T_INT, "-42"
    ldr  x19, =-9223372036854775808
    C_JSONV 0, T_INT, "-9223372036854775808"
    LDBL x19, 0.1
    C_JSONV 0, T_FLOAT, "0.1"
    LDBL x19, -0.0
    C_JSONV 0, T_FLOAT, "0"
    ldr  x19, =-50
    C_JSONV 0, DEC_TYPE(5,2), "\"-0.50\""
    ldr  x19, =11016
    C_JSONV 0, T_DATE, "\"2000-02-29\""
    ldr  x19, =-1
    C_JSONV 0, T_TS, "\"1969-12-31 23:59:59.999999\""
    LSTRO x19, "a\"b\\\n\001"
    C_JSONV 0, T_STR, "\"a\\\"b\\\\\\n\\u0001\""

    // value_to_str
    mov  x19, #1
    C_TOSTR T_BOOL, "true"
    mov  x19, #0
    C_TOSTR T_BOOL, "false"
    ldr  x19, =-1234
    C_TOSTR T_INT, "-1234"
    C_TOSTR DEC_TYPE(6,3), "-1.234"
    ldr  x19, =0
    C_TOSTR T_DATE, "1970-01-01"
    ldr  x19, =1500000
    C_TOSTR T_TS, "1970-01-01 00:00:01.500000"
    LDBL x19, 2.5
    C_TOSTR T_FLOAT, "2.5"
    LSTRO x19, "same"
    C_TOSTR T_STR, "same"

    // value_cmp
    mov  x19, #1
    mov  x20, #2
    C_CMP T_INT, -1, "1 < 2"
    C_CMP T_BOOL, -1, "false < true"
    ldr  x19, =-9223372036854775808
    ldr  x20, =9223372036854775807
    C_CMP T_INT, -1, "min < max"
    C_CMP T_TS, -1, "ts min < max"
    mov  x19, #5
    mov  x20, #5
    C_CMP DEC_TYPE(3,1), 0, "5 = 5"
    ldr  x19, =3
    ldr  x20, =-3
    C_CMP T_DATE, 1, "3 > -3"
    LDBL x19, 0.0
    LDBL x20, -0.0
    C_CMP T_FLOAT, 0, "0.0 = -0.0"
    LDBL x19, -1.5
    LDBL x20, 0.5
    C_CMP T_FLOAT, -1, "-1.5 < 0.5"
    LDBL x19, 1e300
    LDBL x20, -1e300
    C_CMP T_FLOAT, 1, "1e300 > -1e300"
    LSTRO x19, "abc"
    LSTRO x20, "abd"
    C_CMP T_STR, -1, "abc < abd"
    LSTRO x19, "abc"
    LSTRO x20, "ab"
    C_CMP T_STR, 1, "abc > ab"
    LSTRO x19, "abc"
    LSTRO x20, "abc"
    C_CMP T_STR, 0, "abc = abc"
    LSTRO x19, "\303\251"
    LSTRO x20, "z"
    C_CMP T_STR, 1, "e-acute > z"
    LSTRO x19, ""
    LSTRO x20, "a"
    C_CMP T_STR, -1, "empty < a"

    // cast_allowed (types.md 8 matrix)
    C_ALLOWED T_BOOL, T_BOOL, 1
    C_ALLOWED T_BOOL, T_INT, 1
    C_ALLOWED T_BOOL, DEC_TYPE(5,2), 0
    C_ALLOWED T_BOOL, T_FLOAT, 0
    C_ALLOWED T_BOOL, T_STR, 1
    C_ALLOWED T_BOOL, T_DATE, 0
    C_ALLOWED T_INT, T_BOOL, 1
    C_ALLOWED T_INT, DEC_TYPE(5,2), 1
    C_ALLOWED T_INT, T_FLOAT, 1
    C_ALLOWED T_INT, T_DATE, 0
    C_ALLOWED T_INT, T_TS, 0
    C_ALLOWED DEC_TYPE(5,2), T_BOOL, 0
    C_ALLOWED DEC_TYPE(5,2), T_INT, 1
    C_ALLOWED DEC_TYPE(5,2), DEC_TYPE(7,1), 1
    C_ALLOWED DEC_TYPE(5,2), T_FLOAT, 1
    C_ALLOWED DEC_TYPE(5,2), T_STR, 1
    C_ALLOWED DEC_TYPE(5,2), T_DATE, 0
    C_ALLOWED T_FLOAT, T_BOOL, 0
    C_ALLOWED T_FLOAT, T_INT, 1
    C_ALLOWED T_FLOAT, DEC_TYPE(5,2), 1
    C_ALLOWED T_FLOAT, T_STR, 1
    C_ALLOWED T_FLOAT, T_TS, 0
    C_ALLOWED T_STR, T_BOOL, 1
    C_ALLOWED T_STR, T_INT, 1
    C_ALLOWED T_STR, DEC_TYPE(5,2), 1
    C_ALLOWED T_STR, T_FLOAT, 1
    C_ALLOWED T_STR, T_STR, 1
    C_ALLOWED T_STR, T_DATE, 1
    C_ALLOWED T_STR, T_TS, 1
    C_ALLOWED T_DATE, T_STR, 1
    C_ALLOWED T_DATE, T_DATE, 1
    C_ALLOWED T_DATE, T_TS, 1
    C_ALLOWED T_DATE, T_INT, 0
    C_ALLOWED T_DATE, T_BOOL, 0
    C_ALLOWED T_TS, T_DATE, 1
    C_ALLOWED T_TS, T_STR, 1
    C_ALLOWED T_TS, T_FLOAT, 0
    C_ALLOWED T_NULL, T_DATE, 1
    C_ALLOWED T_NULL, DEC_TYPE(3,1), 1

    // cast_value
    LSTRO x19, " 42 "
    C_CAST T_STR, T_INT, 42, 0, "string ' 42 ' -> int"
    LSTRO x19, "abc"
    C_CAST T_STR, T_INT, 0, ERR_CONVERSION, "string abc -> int"
    LSTRO x19, "99999999999999999999"
    C_CAST T_STR, T_INT, 0, ERR_NUMERIC_OVERFLOW, "string huge -> int"
    LSTRO x19, "\t-9223372036854775808\r\n"
    C_CAST T_STR, T_INT, -9223372036854775808, 0, "string int64 min -> int"
    LSTRO x19, "1.005"
    C_CAST T_STR, DEC_TYPE(3,2), 101, 0, "string 1.005 -> dec(3,2)"
    LSTRO x19, "-2.345"
    C_CAST T_STR, DEC_TYPE(5,2), -235, 0, "string -2.345 -> dec(5,2)"
    LSTRO x19, "12.5"
    C_CAST T_STR, DEC_TYPE(2,1), 0, ERR_NUMERIC_OVERFLOW, "string 12.5 -> dec(2,1)"
    LSTRO x19, "1e2"
    C_CAST T_STR, DEC_TYPE(5,1), 0, ERR_CONVERSION, "string 1e2 -> dec"
    LSTRO x19, " true "
    C_CAST T_STR, T_BOOL, 1, 0, "string true -> bool"
    LSTRO x19, "FALSE"
    C_CAST T_STR, T_BOOL, 0, 0, "string FALSE -> bool"
    LSTRO x19, "1"
    C_CAST T_STR, T_BOOL, 0, ERR_CONVERSION, "string 1 -> bool"
    LSTRO x19, "1e400"
    C_CAST T_STR, T_FLOAT, 0, ERR_NUMERIC_OVERFLOW, "string 1e400 -> float"
    LSTRO x19, "inf"
    C_CAST T_STR, T_FLOAT, 0, ERR_CONVERSION, "string inf -> float"
    LSTRO x19, " 2.5e1 "
    C_CAST T_STR, T_FLOAT, 0x4039000000000000, 0, "string 2.5e1 -> float"
    LSTRO x19, "2024-01-01"
    C_CAST T_STR, T_TS, 0, ERR_CONVERSION, "string date -> ts (timestamp syntax required)"
    LSTRO x19, " 2024-01-01 00:00:01 "
    C_CAST T_STR, T_TS, 1704067201000000, 0, "string ts -> ts"
    LSTRO x19, "2024-01-01 00:00:01"
    C_CAST T_STR, T_DATE, 0, ERR_CONVERSION, "string ts -> date"
    LSTRO x19, "2024-02-30"
    C_CAST T_STR, T_DATE, 0, ERR_CONVERSION, "string bad date -> date"
    LSTRO x19, "1969-12-31"
    C_CAST T_STR, T_DATE, -1, 0, "string date -> date"
    LSTRO x19, "xyz"
    C_CASTS T_STR, "xyz"
    LDBL x19, 1e19
    C_CAST T_FLOAT, T_INT, 0, ERR_NUMERIC_OVERFLOW, "float 1e19 -> int"
    LDBL x19, -9223372036854775808.0
    C_CAST T_FLOAT, T_INT, -9223372036854775808, 0, "float -2^63 -> int"
    LDBL x19, 9223372036854775808.0
    C_CAST T_FLOAT, T_INT, 0, ERR_NUMERIC_OVERFLOW, "float 2^63 -> int"
    LDBL x19, -3.9
    C_CAST T_FLOAT, T_INT, -3, 0, "float -3.9 -> int"
    LDBL x19, 3.9
    C_CAST T_FLOAT, T_INT, 3, 0, "float 3.9 -> int"
    LDBL x19, 0.125
    C_CAST T_FLOAT, DEC_TYPE(3,2), 13, 0, "float 0.125 -> dec(3,2)"
    LDBL x19, 9.996
    C_CAST T_FLOAT, DEC_TYPE(3,2), 0, ERR_NUMERIC_OVERFLOW, "float 9.996 -> dec(3,2)"
    ldr  x19, =1234
    C_CAST DEC_TYPE(6,2), T_INT, 12, 0, "dec 12.34 -> int"
    ldr  x19, =-1299
    C_CAST DEC_TYPE(6,2), T_INT, -12, 0, "dec -12.99 -> int"
    ldr  x19, =12345
    C_CAST DEC_TYPE(5,3), DEC_TYPE(4,2), 1235, 0, "dec 12.345 -> dec(4,2)"
    ldr  x19, =-12345
    C_CAST DEC_TYPE(5,3), DEC_TYPE(4,2), -1235, 0, "dec -12.345 -> dec(4,2)"
    ldr  x19, =99999
    C_CAST DEC_TYPE(5,3), DEC_TYPE(4,2), 0, ERR_NUMERIC_OVERFLOW, "dec 99.999 -> dec(4,2)"
    ldr  x19, =100000000000000000
    C_CAST DEC_TYPE(18,0), DEC_TYPE(18,2), 0, ERR_NUMERIC_OVERFLOW, "dec 1e17 -> dec(18,2)"
    ldr  x19, =12345
    C_CAST DEC_TYPE(5,3), DEC_TYPE(10,5), 1234500, 0, "dec 12.345 -> dec(10,5)"
    ldr  x19, =12345
    C_CAST DEC_TYPE(5,2), T_FLOAT, 0x405edccccccccccd, 0, "dec 123.45 -> float"
    ldr  x19, =5
    C_CAST T_INT, DEC_TYPE(3,2), 500, 0, "int 5 -> dec(3,2)"
    ldr  x19, =10
    C_CAST T_INT, DEC_TYPE(3,2), 0, ERR_NUMERIC_OVERFLOW, "int 10 -> dec(3,2)"
    ldr  x19, =9223372036854775807
    C_CAST T_INT, DEC_TYPE(18,0), 0, ERR_NUMERIC_OVERFLOW, "int max -> dec(18,0)"
    ldr  x19, =0
    C_CAST T_INT, T_BOOL, 0, 0, "int 0 -> bool"
    ldr  x19, =-3
    C_CAST T_INT, T_BOOL, 1, 0, "int -3 -> bool"
    ldr  x19, =-3
    C_CAST T_INT, T_FLOAT, 0xc008000000000000, 0, "int -3 -> float"
    mov  x19, #1
    C_CAST T_BOOL, T_INT, 1, 0, "bool true -> int"
    ldr  x19, =-1
    C_CAST T_TS, T_DATE, -1, 0, "ts -1us -> date"
    ldr  x19, =86399999999
    C_CAST T_TS, T_DATE, 0, 0, "ts end of day -> date"
    ldr  x19, =1
    C_CAST T_DATE, T_TS, 86400000000, 0, "date 1 -> ts"
    ldr  x19, =1
    C_CAST T_DATE, T_INT, 0, ERR_TYPE, "date -> int (not allowed)"

    mov  x19, #1
    C_CASTS T_BOOL, "true"
    ldr  x19, =-7
    C_CASTS T_INT, "-7"
    ldr  x19, =-50
    C_CASTS DEC_TYPE(4,2), "-0.50"
    LDBL x19, 0.1
    C_CASTS T_FLOAT, "0.1"
    ldr  x19, =19782
    C_CASTS T_DATE, "2024-02-29"
    ldr  x19, =0
    C_CASTS T_TS, "1970-01-01 00:00:00"
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF test_values

// ------------------------------------------------------------------ main ---
FUNC main
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   test_scalars
    bl   test_datetime
    bl   test_calendar
    bl   test_decimal
    bl   test_types
    bl   test_values
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
