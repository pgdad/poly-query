/*
 * test_text.S - unit tests for src/text.S (parsing, formatting, calendar,
 * decimal and float helpers).  Prints "FAIL: ..." per failing case and
 * "test_text: N passed" when everything succeeds.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

    .bss
    .p2align 4
tbuf:       .zero BUF_SIZE
npass:      .zero 8
nfail:      .zero 8
rng_state:  .zero 8

    .text

/* ======================================================== test macros */

/* LSTR ptrreg, lenreg, "text": pointer + length of an inline string */
.macro LSTR rp, rl, str
    .pushsection .rodata.tstr, "a"
8001:
    .ascii "\str"
8002:
    .popsection
    lea 8001b(%rip), \rp
    mov $(8002b-8001b), \rl
.endm

/* CHKI "name", expected value, expected status (uses rax/edx of the last call) */
.macro CHKI name, val, sta
    mov %rax, %rsi
    mov %edx, %edx
    movabs $\val, %rcx
    mov $\sta, %r8d
    CSTR %rdi, "\name"
    call chk_i64
.endm

.macro TINT str, val, sta
    LSTR %rdi, %rsi, "\str"
    call text_parse_int64
    CHKI "int64 '\str'", \val, \sta
.endm

.macro TBOOL str, val, sta
    LSTR %rdi, %rsi, "\str"
    call text_parse_bool
    CHKI "bool '\str'", \val, \sta
.endm

.macro TDATE str, val, sta
    LSTR %rdi, %rsi, "\str"
    call text_parse_date
    CHKI "date '\str'", \val, \sta
.endm

.macro TTS str, allow, val, sta
    LSTR %rdi, %rsi, "\str"
    mov $\allow, %edx
    call text_parse_timestamp
    CHKI "timestamp '\str' allow=\allow", \val, \sta
.endm

.macro TDEC str, prec, scale, mode, val, sta
    LSTR %rdi, %rsi, "\str"
    mov $\prec, %edx
    mov $\scale, %ecx
    mov $\mode, %r8d
    call text_parse_decimal
    CHKI "decimal '\str' p=\prec s=\scale mode=\mode", \val, \sta
.endm

.macro TTYPE str, val, sta
    LSTR %rdi, %rsi, "\str"
    call type_parse
    CHKI "type_parse '\str'", \val, \sta
.endm

/* TFLT "text", expected double literal, status */
.macro TFLT str, dval, sta
    .pushsection .rodata.tnum, "a"
    .p2align 3
8003:
    .double \dval
    .popsection
    LSTR %rdi, %rsi, "\str"
    call text_parse_float
    movq %xmm0, %rsi
    mov %eax, %edx
    mov 8003b(%rip), %rcx
    mov $\sta, %r8d
    CSTR %rdi, "float '\str'"
    call chk_i64
.endm

/* plain 64-bit value check of rax */
.macro CHKV name, val
    xor %edx, %edx
    CHKI "\name", \val, 0
.endm

/* reset the test buffer and load its address into rdi */
.macro FMT_BEGIN
    movq $0, tbuf+BUF_LEN(%rip)
    lea tbuf(%rip), %rdi
.endm

/* compare tbuf with "expected" */
.macro CHKB name, exp
    LSTR %rsi, %rdx, "\exp"
    CSTR %rdi, "\name"
    call chk_buf
.endm

/* compare tbuf with bytes at label .. label_e */
.macro CHKL name, lbl
    lea \lbl(%rip), %rsi
    mov $(\lbl\()_e - \lbl), %edx
    CSTR %rdi, "\name"
    call chk_buf
.endm

.macro TFDATE days, exp
    FMT_BEGIN
    movabs $\days, %rsi
    call fmt_date
    CHKB "fmt_date \days", "\exp"
.endm

.macro TFTS micros, exp
    FMT_BEGIN
    movabs $\micros, %rsi
    call fmt_timestamp
    CHKB "fmt_timestamp \micros", "\exp"
.endm

.macro TFDEC val, scale, exp
    FMT_BEGIN
    movabs $\val, %rsi
    mov $\scale, %edx
    call fmt_decimal
    CHKB "fmt_decimal \val scale \scale", "\exp"
.endm

.macro TFFLT dval, exp
    .pushsection .rodata.tnum, "a"
    .p2align 3
8004:
    .double \dval
    .popsection
    FMT_BEGIN
    movsd 8004b(%rip), %xmm0
    call fmt_float
    CHKB "fmt_float \dval", "\exp"
.endm

.macro TFFLTB bits, exp
    FMT_BEGIN
    movabs $\bits, %rax
    movq %rax, %xmm0
    call fmt_float
    CHKB "fmt_float bits \bits", "\exp"
.endm

.macro TFTYPE type, exp
    FMT_BEGIN
    mov $\type, %esi
    call fmt_type
    CHKB "fmt_type \type", "\exp"
.endm

/* ======================================================== check helpers */

/* chk_i64(name rdi, got rsi, got_status edx, want rcx, want_status r8d)
 * value is only compared when the expected status is 0 */
chk_i64:
    ENTER 16
    cmp %r8d, %edx
    jne 1f
    test %r8d, %r8d
    jnz 2f
    cmp %rcx, %rsi
    jne 1f
2:  incq npass(%rip)
    LEAVE
1:  incq nfail(%rip)
    mov %r8d, %r9d
    mov %rcx, %r8
    mov %edx, %ecx
    mov %rsi, %rdx
    mov %rdi, %rsi
    CSTR %rdi, "FAIL: %s: got %ld (status %d), want %ld (status %d)\n"
    xor %eax, %eax
    call printf
    LEAVE

/* chk_buf(name rdi, exp ptr rsi, exp len rdx): compares tbuf contents */
chk_buf:
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    cmp tbuf+BUF_LEN(%rip), %r13
    jne 1f
    test %r13, %r13
    jz 2f
    mov tbuf+BUF_DATA(%rip), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call memcmp
    test %eax, %eax
    jnz 1f
2:  incq npass(%rip)
    LEAVE
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: got '%.*s' want '%.*s'\n"
    mov %rbx, %rsi
    mov tbuf+BUF_LEN(%rip), %edx
    mov tbuf+BUF_DATA(%rip), %rcx
    mov %r13d, %r8d
    mov %r12, %r9
    xor %eax, %eax
    call printf
    LEAVE

/* report(ok edi, name rsi) */
report:
    sub $8, %rsp
    test %edi, %edi
    jz 1f
    incq npass(%rip)
    add $8, %rsp
    ret
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s\n"
    xor %eax, %eax
    call printf
    add $8, %rsp
    ret

/* rng_next() -> rax (xorshift64) */
rng_next:
    mov rng_state(%rip), %rax
    mov %rax, %rcx
    shl $13, %rcx
    xor %rcx, %rax
    mov %rax, %rcx
    shr $7, %rcx
    xor %rcx, %rax
    mov %rax, %rcx
    shl $17, %rcx
    xor %rcx, %rax
    mov %rax, rng_state(%rip)
    ret

/* ======================================================== loop tests */

/* every day 0001-01-01..9999-12-31: civil_from_days / days_from_civil inverse,
 * fmt_date -> text_parse_date round trip, consecutive days are consecutive dates */
test_calendar:
    ENTER 32
    mov $-719162, %r12
    movq $0, 0(%rsp)                /* previous y */
    movq $12, 8(%rsp)               /* previous m */
    movq $31, 16(%rsp)              /* previous d */
1:  mov %r12, %rdi
    call civil_from_days
    mov %rax, %rbx
    mov %rdx, %r13
    mov %rcx, %r14
    cmp $1, %rbx
    jl 8f
    cmp $9999, %rbx
    jg 8f
    cmp $1, %r13
    jl 8f
    cmp $12, %r13
    jg 8f
    cmp $1, %r14
    jl 8f
    cmp $31, %r14
    jg 8f
    /* successor check */
    cmp $1, %r14
    je 2f
    mov 16(%rsp), %rax
    inc %rax
    cmp %rax, %r14
    jne 8f
    cmp 8(%rsp), %r13
    jne 8f
    cmp 0(%rsp), %rbx
    jne 8f
    jmp 4f
2:  cmp $1, %r13
    je 3f
    mov 8(%rsp), %rax
    inc %rax
    cmp %rax, %r13
    jne 8f
    cmp 0(%rsp), %rbx
    jne 8f
    jmp 4f
3:  mov 0(%rsp), %rax
    inc %rax
    cmp %rax, %rbx
    jne 8f
    cmpq $12, 8(%rsp)
    jne 8f
    cmpq $31, 16(%rsp)
    jne 8f
4:  mov %rbx, 0(%rsp)
    mov %r13, 8(%rsp)
    mov %r14, 16(%rsp)
    mov %ebx, %edi
    mov %r13d, %esi
    mov %r14d, %edx
    call days_from_civil
    cmp %r12, %rax
    jne 8f
    FMT_BEGIN
    mov %r12, %rsi
    call fmt_date
    cmpq $10, tbuf+BUF_LEN(%rip)
    jne 8f
    mov tbuf+BUF_DATA(%rip), %rdi
    mov $10, %esi
    call text_parse_date
    test %edx, %edx
    jnz 8f
    cmp %r12, %rax
    jne 8f
    inc %r12
    cmp $2932896, %r12
    jle 1b
    /* last date must be 9999-12-31 */
    cmp $9999, %rbx
    jne 8f
    cmp $12, %r13
    jne 8f
    cmp $31, %r14
    jne 8f
    mov $1, %edi
    CSTR %rsi, "calendar loop"
    call report
    LEAVE
8:  incq nfail(%rip)
    CSTR %rdi, "FAIL: calendar loop at day %ld (y=%ld m=%ld d=%ld)\n"
    mov %r12, %rsi
    mov %rbx, %rdx
    mov %r13, %rcx
    mov %r14, %r8
    xor %eax, %eax
    call printf
    LEAVE

/* random doubles: fmt_float output parses back (text_parse_float) to identical bits */
test_float_rt:
    ENTER 32
    xor %r12d, %r12d
1:  call rng_next
    mov %rax, %rbx
    test $1, %r12d
    jz 2f
    /* odd iterations: "human" numbers: (double)(int32) / 10^(0..6) */
    movslq %ebx, %rax
    cvtsi2sdq %rax, %xmm0
    shr $32, %rbx
    and $7, %ebx
    cmp $6, %ebx
    jbe 11f
    mov $6, %ebx
11: lea pow10_u64(%rip), %rax
    cvtsi2sdq (%rax, %rbx, 8), %xmm1
    divsd %xmm1, %xmm0
    movq %xmm0, %rbx
2:  mov %rbx, %rax
    shl $1, %rax
    shr $53, %rax
    cmp $0x7ff, %eax
    je 5f                           /* skip inf/nan */
    mov %rbx, %rax
    shl $1, %rax
    jz 5f                           /* skip +-0 */
    FMT_BEGIN
    movq %rbx, %xmm0
    call fmt_float
    mov tbuf+BUF_DATA(%rip), %rdi
    mov tbuf+BUF_LEN(%rip), %rsi
    call text_parse_float
    test %eax, %eax
    jnz 8f
    movq %xmm0, %rax
    cmp %rbx, %rax
    jne 8f
5:  inc %r12d
    cmp $200000, %r12d
    jb 1b
    mov $1, %edi
    CSTR %rsi, "fmt_float round trip"
    call report
    LEAVE
8:  incq nfail(%rip)
    CSTR %rdi, "FAIL: fmt_float round trip bits %lx -> '%.*s'\n"
    mov %rbx, %rsi
    mov tbuf+BUF_LEN(%rip), %edx
    mov tbuf+BUF_DATA(%rip), %rcx
    xor %eax, %eax
    call printf
    LEAVE

/* random timestamps in range: fmt_timestamp -> text_parse_timestamp round trip */
test_ts_rt:
    ENTER 32
    xor %r12d, %r12d
1:  call rng_next
    shr $1, %rax
    movabs $315537897600000000, %rcx  /* max - min + 1 */
    xor %edx, %edx
    div %rcx
    movabs $-62135596800000000, %rbx
    add %rdx, %rbx
    test $1, %r12d
    jz 2f
    /* odd iterations: whole seconds */
    mov %rbx, %rax
    mov $1000000, %ecx
    cqo
    idiv %rcx
    imul $1000000, %rax, %rbx
2:  FMT_BEGIN
    mov %rbx, %rsi
    call fmt_timestamp
    mov tbuf+BUF_DATA(%rip), %rdi
    mov tbuf+BUF_LEN(%rip), %rsi
    xor %edx, %edx
    call text_parse_timestamp
    test %edx, %edx
    jnz 8f
    cmp %rbx, %rax
    jne 8f
    inc %r12d
    cmp $200000, %r12d
    jb 1b
    mov $1, %edi
    CSTR %rsi, "timestamp round trip"
    call report
    LEAVE
8:  incq nfail(%rip)
    CSTR %rdi, "FAIL: timestamp round trip %ld -> '%.*s'\n"
    mov %rbx, %rsi
    mov tbuf+BUF_LEN(%rip), %edx
    mov tbuf+BUF_DATA(%rip), %rcx
    xor %eax, %eax
    call printf
    LEAVE

/* random decimals: fmt_decimal -> text_parse_decimal (exact) round trip */
test_dec_rt:
    ENTER 32
    xor %r12d, %r12d
1:  call rng_next
    mov %rax, %r13
    and $31, %r13d
    cmp $18, %r13d
    jbe 2f
    sub $13, %r13d                  /* scale 0..18 */
2:  call rng_next
    mov %rax, %rbx
    shr $8, %rbx
    mov %rbx, %rax
    movabs $1000000000000000000, %rcx
    xor %edx, %edx
    div %rcx
    mov %rdx, %rbx                  /* 0 .. 10^18-1 */
    mov %r12d, %ecx
    and $7, %ecx
    shl $3, %ecx                    /* vary magnitude: shift right 0..56 */
    shr %cl, %rbx
    test $8, %r12d
    jz 3f
    neg %rbx
3:  FMT_BEGIN
    mov %rbx, %rsi
    mov %r13d, %edx
    call fmt_decimal
    mov tbuf+BUF_DATA(%rip), %rdi
    mov tbuf+BUF_LEN(%rip), %rsi
    mov $18, %edx
    mov %r13d, %ecx
    xor %r8d, %r8d
    call text_parse_decimal
    test %edx, %edx
    jnz 8f
    cmp %rbx, %rax
    jne 8f
    inc %r12d
    cmp $200000, %r12d
    jb 1b
    mov $1, %edi
    CSTR %rsi, "decimal round trip"
    call report
    LEAVE
8:  incq nfail(%rip)
    CSTR %rdi, "FAIL: decimal round trip %ld scale %d -> '%.*s'\n"
    mov %rbx, %rsi
    mov %r13d, %edx
    mov tbuf+BUF_LEN(%rip), %ecx
    mov tbuf+BUF_DATA(%rip), %r8
    xor %eax, %eax
    call printf
    LEAVE

/* ======================================================== fixed data */
    .section .rodata
    .p2align 3
ps_q:       .quad 5
            .ascii "a\"b\\c"
            .byte 0
ps_nl:      .quad 3
            .ascii "x\ny"
            .byte 0
jx_q:       .ascii "\"a\\\"b\\\\c\""
jx_q_e:
tx_q:       .ascii "a\"b\\c"
tx_q_e:
jx_nl:      .ascii "\"x\\ny\""
jx_nl_e:
jx_dec:     .ascii "\"-0.50\""
jx_dec_e:
jx_date:    .ascii "\"2024-02-29\""
jx_date_e:
jx_ts:      .ascii "\"1969-12-31 23:59:59.999999\""
jx_ts_e:
/* 300-character float literal: "1" followed by 299 zeros = 1e299 */
long_num:   .ascii "1"
            .rept 299
            .ascii "0"
            .endr
long_num_e:
            .p2align 3
d_1e299:    .double 1e299
    .text

/* ======================================================== main */
FUNC main
    ENTER 32
    movabs $88172645463325252, %rax
    mov %rax, rng_state(%rip)
    call arena_new
    mov %rax, g_arena(%rip)
    lea tbuf(%rip), %rdi
    call buf_init

    /* ---------------- text_trim */
    LSTR %rdi, %rsi, "  ab \t"
    mov %rdi, %rbx
    call text_trim
    sub %rbx, %rax
    CHKV "trim offset", 2
    LSTR %rdi, %rsi, "  ab \t"
    call text_trim
    mov %rdx, %rax
    CHKV "trim len", 2
    LSTR %rdi, %rsi, " \t "
    call text_trim
    mov %rdx, %rax
    CHKV "trim blank len", 0
    LSTR %rdi, %rsi, ""
    call text_trim
    mov %rdx, %rax
    CHKV "trim empty len", 0
    LSTR %rdi, %rsi, "x"
    call text_trim
    mov %rdx, %rax
    CHKV "trim x len", 1

    /* ---------------- text_parse_int64 */
    TINT "0", 0, 0
    TINT "123", 123, 0
    TINT "-123", -123, 0
    TINT "+7", 7, 0
    TINT "-0", 0, 0
    TINT "9223372036854775807", 9223372036854775807, 0
    TINT "-9223372036854775808", -9223372036854775808, 0
    TINT "9223372036854775808", 0, 2
    TINT "-9223372036854775809", 0, 2
    TINT "18446744073709551616", 0, 2
    TINT "0000000000000000000000001", 1, 0
    TINT "-0000000000000000000000009223372036854775808", -9223372036854775808, 0
    TINT "99999999999999999999999", 0, 2
    TINT "99999999999999999999x", 0, 1
    TINT "", 0, 1
    TINT "-", 0, 1
    TINT "+", 0, 1
    TINT "12a", 0, 1
    TINT " 1", 0, 1
    TINT "1 ", 0, 1
    TINT "1.0", 0, 1
    TINT "--1", 0, 1
    TINT "1e3", 0, 1

    /* ---------------- text_parse_float */
    TFLT "1.5", 1.5, 0
    TFLT "-2.5e-3", -0.0025, 0
    TFLT ".5", 0.5, 0
    TFLT "5.", 5.0, 0
    TFLT "+1E+2", 100.0, 0
    TFLT "0.1", 0.1, 0
    TFLT "123", 123.0, 0
    TFLT "1e308", 1e308, 0
    TFLT "1e999", 0.0, 2
    TFLT "-1e999", 0.0, 2
    TFLT "1e-999", 0.0, 0
    TFLT "abc", 0.0, 1
    TFLT ".", 0.0, 1
    TFLT "", 0.0, 1
    TFLT "-", 0.0, 1
    TFLT "1e", 0.0, 1
    TFLT "1e+", 0.0, 1
    TFLT "e5", 0.0, 1
    TFLT ".e5", 0.0, 1
    TFLT "inf", 0.0, 1
    TFLT "nan", 0.0, 1
    TFLT "0x10", 0.0, 1
    TFLT "1.2.3", 0.0, 1
    TFLT " 1", 0.0, 1
    TFLT "1 ", 0.0, 1
    TFLT "1e5x", 0.0, 1
    lea long_num(%rip), %rdi
    mov $(long_num_e - long_num), %esi
    call text_parse_float
    movq %xmm0, %rsi
    mov %eax, %edx
    mov d_1e299(%rip), %rcx
    xor %r8d, %r8d
    CSTR %rdi, "float 300-char literal"
    call chk_i64

    /* ---------------- text_parse_decimal */
    TDEC "1.005", 18, 2, 1, 101, 0
    TDEC "-2.345", 18, 2, 1, -235, 0
    TDEC "-2.344", 18, 2, 1, -234, 0
    TDEC "2.345", 18, 2, 0, 0, 3
    TDEC "10.005", 18, 2, 0, 0, 3
    TDEC "0.50", 18, 1, 0, 0, 3
    TDEC "0.50", 18, 2, 0, 50, 0
    TDEC "0.5", 18, 1, 0, 5, 0
    TDEC "12.5", 18, 3, 0, 12500, 0
    TDEC "12", 5, 2, 0, 1200, 0
    TDEC "12345", 4, 0, 0, 0, 2
    TDEC "9999", 4, 0, 0, 9999, 0
    TDEC "-9999", 4, 0, 0, -9999, 0
    TDEC "99.99", 4, 2, 0, 9999, 0
    TDEC "100.00", 4, 2, 0, 0, 2
    TDEC "9.995", 3, 2, 1, 0, 2
    TDEC "9.994", 3, 2, 1, 999, 0
    TDEC "0.995", 3, 2, 1, 100, 0
    TDEC "000000000000000000000000000001.5", 18, 1, 0, 15, 0
    TDEC "1234567890123456789", 18, 0, 0, 0, 2
    TDEC "99999999999999999999999999", 18, 0, 0, 0, 2
    TDEC "999999999999999999", 18, 0, 0, 999999999999999999, 0
    TDEC "-999999999999999999", 18, 0, 0, -999999999999999999, 0
    TDEC "0.123456789012345678", 18, 18, 0, 123456789012345678, 0
    TDEC "-.123456789012345678", 18, 18, 0, -123456789012345678, 0
    TDEC "1.5", 18, 18, 0, 0, 2
    TDEC "99999999999999999.5", 18, 1, 0, 999999999999999995, 0
    TDEC "99999999999999999.95", 18, 1, 1, 0, 2
    TDEC "0.00000000000000000000000000049", 18, 2, 1, 0, 0
    TDEC "0.00000000000000000000000000049", 18, 2, 0, 0, 3
    TDEC "0.005", 18, 2, 1, 1, 0
    TDEC "-0.005", 18, 2, 1, -1, 0
    TDEC "+.5", 2, 1, 0, 5, 0
    TDEC "5.", 3, 0, 0, 5, 0
    TDEC "-0", 3, 0, 0, 0, 0
    TDEC "0", 1, 0, 0, 0, 0
    TDEC "1e5", 18, 0, 0, 0, 1
    TDEC "", 18, 0, 0, 0, 1
    TDEC ".", 18, 0, 0, 0, 1
    TDEC "-", 18, 0, 0, 0, 1
    TDEC "-.", 18, 0, 0, 0, 1
    TDEC "1.2.3", 18, 2, 0, 0, 1
    TDEC " 1", 18, 0, 0, 0, 1
    TDEC "1 ", 18, 0, 0, 0, 1
    TDEC "1.x", 18, 2, 0, 0, 1
    TDEC "99999999999999999999999999x", 18, 0, 0, 0, 1

    /* ---------------- text_parse_bool */
    TBOOL "true", 1, 0
    TBOOL "TRUE", 1, 0
    TBOOL "tRuE", 1, 0
    TBOOL "false", 0, 0
    TBOOL "False", 0, 0
    TBOOL "FALSE", 0, 0
    TBOOL "yes", 0, 1
    TBOOL "tru", 0, 1
    TBOOL "truee", 0, 1
    TBOOL "falsy", 0, 1
    TBOOL "", 0, 1
    TBOOL "1", 0, 1
    TBOOL " true", 0, 1

    /* ---------------- text_parse_date */
    TDATE "1970-01-01", 0, 0
    TDATE "1969-12-31", -1, 0
    TDATE "2024-02-29", 19782, 0
    TDATE "2023-02-29", 0, 1
    TDATE "1900-02-29", 0, 1
    TDATE "2000-02-29", 11016, 0
    TDATE "0001-01-01", -719162, 0
    TDATE "9999-12-31", 2932896, 0
    TDATE "0000-01-01", 0, 1
    TDATE "2024-13-01", 0, 1
    TDATE "2024-00-10", 0, 1
    TDATE "2024-04-31", 0, 1
    TDATE "2024-04-00", 0, 1
    TDATE "2024-04-30", 19843, 0
    TDATE "2024-4-30", 0, 1
    TDATE "2024-04-30x", 0, 1
    TDATE "2024/04/30", 0, 1
    TDATE "2024-04-3a", 0, 1
    TDATE "+024-04-30", 0, 1
    TDATE "", 0, 1
    TDATE "10000-01-01", 0, 1

    /* ---------------- text_parse_timestamp */
    TTS "1970-01-01 00:00:00", 0, 0, 0
    TTS "1970-01-01T00:00:00", 0, 0, 0
    TTS "1969-12-31 23:59:59.999999", 0, -1, 0
    TTS "2024-02-29T12:34:56.5", 0, 1709210096500000, 0
    TTS "2024-02-29 12:34:56.500000", 0, 1709210096500000, 0
    TTS "0001-01-01 00:00:00", 0, -62135596800000000, 0
    TTS "9999-12-31 23:59:59.999999", 0, 253402300799999999, 0
    TTS "1900-03-01 00:00:01.000001", 0, -2203891198999999, 0
    TTS "1970-01-01 00:00:00.000001", 0, 1, 0
    TTS "1970-01-01 00:00:00.12", 0, 120000, 0
    TTS "2024-02-29", 0, 0, 1
    TTS "2024-02-29", 1, 1709164800000000, 0
    TTS "2023-02-29", 1, 0, 1
    TTS "2024-02-29 24:00:00", 0, 0, 1
    TTS "2024-02-29 23:60:00", 0, 0, 1
    TTS "2024-02-29 23:00:60", 0, 0, 1
    TTS "2024-02-29 12:00:00.", 0, 0, 1
    TTS "2024-02-29 12:00:00.1234567", 0, 0, 1
    TTS "2024-02-29t12:00:00", 0, 0, 1
    TTS "2024-02-29  12:00:00", 0, 0, 1
    TTS "2024-02-29 12:00", 0, 0, 1
    TTS "2024-02-29 12-00-00", 0, 0, 1
    TTS "2024-02-29 12:00:00.12a", 0, 0, 1
    TTS "2024-02-30 12:00:00", 0, 0, 1
    TTS "", 1, 0, 1

    /* ---------------- days_from_civil / civil_from_days */
    mov $1, %edi
    mov $1, %esi
    mov $1, %edx
    call days_from_civil
    CHKV "days_from_civil 0001-01-01", -719162
    mov $9999, %edi
    mov $12, %esi
    mov $31, %edx
    call days_from_civil
    CHKV "days_from_civil 9999-12-31", 2932896
    mov $1970, %edi
    mov $1, %esi
    mov $1, %edx
    call days_from_civil
    CHKV "days_from_civil 1970-01-01", 0
    mov $-719162, %rdi
    call civil_from_days
    mov %rdx, %rbx
    mov %rcx, %r12
    CHKV "civil_from_days year", 1
    mov %rbx, %rax
    CHKV "civil_from_days month", 1
    mov %r12, %rax
    CHKV "civil_from_days day", 1
    mov $19782, %rdi
    call civil_from_days
    imul $10000, %rax, %rax
    imul $100, %rdx, %rdx
    add %rdx, %rax
    add %rcx, %rax
    CHKV "civil_from_days 19782", 20240229
    call test_calendar

    /* ---------------- type_parse / type_lookup_name */
    TTYPE "decimal( 10 , 2 )", 0x20A04, 0
    TTYPE "NUMERIC(4,2)", 0x20404, 0
    TTYPE "Decimal", 0x1204, 0
    TTYPE "numeric", 0x1204, 0
    TTYPE "decimal(5)", 0x504, 0
    TTYPE " DECIMAL (18,18) ", 0x121204, 0
    TTYPE "decimal(1,0)", 0x104, 0
    TTYPE "decimal(19,2)", 0, 2
    TTYPE "decimal(3,4)", 0, 2
    TTYPE "decimal(0)", 0, 2
    TTYPE "decimal(99999999999999999999,2)", 0, 2
    TTYPE "decimal(", 0, 1
    TTYPE "decimal(5,)", 0, 1
    TTYPE "decimal(,5)", 0, 1
    TTYPE "decimal(5,2", 0, 1
    TTYPE "decimal(5,2)x", 0, 1
    TTYPE "decimal(-1)", 0, 1
    TTYPE "decimal 5", 0, 1
    TTYPE "WIDGET", 0, 1
    TTYPE "", 0, 1
    TTYPE "   ", 0, 1
    TTYPE "int(5)", 0, 1
    TTYPE "int 64", 0, 1
    TTYPE "BOOLEAN", 1, 0
    TTYPE "bool", 1, 0
    TTYPE "  int  ", 2, 0
    TTYPE "INT64", 2, 0
    TTYPE "Integer", 2, 0
    TTYPE "bigint", 2, 0
    TTYPE "FLOAT64", 3, 0
    TTYPE "double", 3, 0
    TTYPE "Float", 3, 0
    TTYPE "real", 3, 0
    TTYPE "STRING", 5, 0
    TTYPE "varchar", 5, 0
    TTYPE "text", 5, 0
    TTYPE "date", 6, 0
    TTYPE "TimeStamp", 7, 0
    TTYPE "\tdate\n", 6, 0
    LSTR %rdi, %rsi, "Numeric"
    call type_lookup_name
    mov %edx, %ebx
    cltq
    CHKV "type_lookup_name numeric kind", 4
    mov %rbx, %rax
    CHKV "type_lookup_name numeric params", 1
    LSTR %rdi, %rsi, "VARCHAR"
    call type_lookup_name
    mov %edx, %ebx
    cltq
    CHKV "type_lookup_name varchar kind", 5
    mov %rbx, %rax
    CHKV "type_lookup_name varchar params", 0
    LSTR %rdi, %rsi, "widget"
    call type_lookup_name
    cltq
    CHKV "type_lookup_name widget", -1
    LSTR %rdi, %rsi, "dat"
    call type_lookup_name
    cltq
    CHKV "type_lookup_name dat", -1

    /* ---------------- fmt_type */
    TFTYPE T_BOOL, "BOOLEAN"
    TFTYPE T_INT, "INT64"
    TFTYPE T_FLOAT, "FLOAT64"
    TFTYPE 0x20A04, "DECIMAL(10,2)"
    TFTYPE 0x1204, "DECIMAL(18,0)"
    TFTYPE 0x121204, "DECIMAL(18,18)"
    TFTYPE T_STR, "STRING"
    TFTYPE T_NULL, "STRING"
    TFTYPE T_DATE, "DATE"
    TFTYPE T_TS, "TIMESTAMP"

    /* ---------------- fmt_date / fmt_timestamp */
    TFDATE 0, "1970-01-01"
    TFDATE -1, "1969-12-31"
    TFDATE 19782, "2024-02-29"
    TFDATE 11016, "2000-02-29"
    TFDATE -719162, "0001-01-01"
    TFDATE 2932896, "9999-12-31"
    TFDATE -25509, "1900-02-28"
    TFTS 0, "1970-01-01 00:00:00"
    TFTS -1, "1969-12-31 23:59:59.999999"
    TFTS -1000000, "1969-12-31 23:59:59"
    TFTS 1, "1970-01-01 00:00:00.000001"
    TFTS 1709210096500000, "2024-02-29 12:34:56.500000"
    TFTS -62135596800000000, "0001-01-01 00:00:00"
    TFTS 253402300799999999, "9999-12-31 23:59:59.999999"
    TFTS -2203891198999999, "1900-03-01 00:00:01.000001"
    TFTS 86399000000, "1970-01-01 23:59:59"
    TFTS -86400000000, "1969-12-31 00:00:00"
    call test_ts_rt

    /* ---------------- fmt_decimal */
    TFDEC -50, 2, "-0.50"
    TFDEC 12, 0, "12"
    TFDEC 0, 3, "0.000"
    TFDEC 0, 0, "0"
    TFDEC -5, 1, "-0.5"
    TFDEC 100, 2, "1.00"
    TFDEC 123456789012345678, 18, "0.123456789012345678"
    TFDEC -999999999999999999, 18, "-0.999999999999999999"
    TFDEC 999999999999999999, 0, "999999999999999999"
    TFDEC 12345, 3, "12.345"
    TFDEC -9223372036854775808, 2, "-92233720368547758.08"
    TFDEC -9223372036854775808, 0, "-9223372036854775808"
    TFDEC 9223372036854775807, 18, "9.223372036854775807"
    call test_dec_rt

    /* ---------------- fmt_float */
    TFFLT 0.1, "0.1"
    TFFLT 1e300, "1e+300"
    TFFLT 2.5e-300, "2.5e-300"
    TFFLT 1000.0, "1000"
    TFFLT 1.5, "1.5"
    TFFLT -2.5, "-2.5"
    TFFLT 123456789.0, "123456789"
    TFFLT 0.0, "0"
    TFFLTB 0x8000000000000000, "0"
    TFFLTB 0x3FD3333333333334, "0.30000000000000004"
    TFFLTB 0x3FD5555555555555, "0.3333333333333333"
    TFFLTB 0x0000000000000001, "4.94065645841247e-324"
    TFFLTB 0x7FEFFFFFFFFFFFFF, "1.7976931348623157e+308"
    TFFLT 1e21, "1e+21"
    TFFLT 1e-7, "1e-07"
    call test_float_rt

    /* ---------------- fmt_value_text / fmt_value_json */
    FMT_BEGIN
    mov $T_BOOL, %esi
    mov $1, %edx
    call fmt_value_text
    CHKB "text bool true", "true"
    FMT_BEGIN
    mov $T_BOOL, %esi
    xor %edx, %edx
    call fmt_value_json
    CHKB "json bool false", "false"
    FMT_BEGIN
    mov $T_INT, %esi
    mov $-42, %rdx
    call fmt_value_json
    CHKB "json int -42", "-42"
    FMT_BEGIN
    mov $T_INT, %esi
    movabs $-9223372036854775808, %rdx
    call fmt_value_text
    CHKB "text int min", "-9223372036854775808"
    FMT_BEGIN
    mov $T_FLOAT, %esi
    movabs $0x4004000000000000, %rdx     /* 2.5 */
    call fmt_value_json
    CHKB "json float 2.5", "2.5"
    FMT_BEGIN
    mov $T_FLOAT, %esi
    movabs $0x8000000000000000, %rdx     /* -0.0 */
    call fmt_value_text
    CHKB "text float -0.0", "0"
    FMT_BEGIN
    mov $MKDEC(3,2), %esi
    mov $-50, %rdx
    call fmt_value_json
    CHKL "json decimal -0.50", jx_dec
    FMT_BEGIN
    mov $MKDEC(3,2), %esi
    mov $-50, %rdx
    call fmt_value_text
    CHKB "text decimal -0.50", "-0.50"
    FMT_BEGIN
    mov $MKDEC(18,0), %esi
    mov $12, %rdx
    call fmt_value_text
    CHKB "text decimal 12", "12"
    FMT_BEGIN
    mov $T_STR, %esi
    lea ps_q(%rip), %rdx
    call fmt_value_json
    CHKL "json string quote/backslash", jx_q
    FMT_BEGIN
    mov $T_STR, %esi
    lea ps_q(%rip), %rdx
    call fmt_value_text
    CHKL "text string raw", tx_q
    FMT_BEGIN
    mov $T_STR, %esi
    lea ps_nl(%rip), %rdx
    call fmt_value_json
    CHKL "json string newline", jx_nl
    FMT_BEGIN
    mov $T_DATE, %esi
    mov $19782, %rdx
    call fmt_value_json
    CHKL "json date", jx_date
    FMT_BEGIN
    mov $T_DATE, %esi
    mov $19782, %rdx
    call fmt_value_text
    CHKB "text date", "2024-02-29"
    FMT_BEGIN
    mov $T_TS, %esi
    mov $-1, %rdx
    call fmt_value_json
    CHKL "json timestamp", jx_ts
    FMT_BEGIN
    mov $T_TS, %esi
    mov $0, %rdx
    call fmt_value_text
    CHKB "text timestamp", "1970-01-01 00:00:00"
    FMT_BEGIN
    mov $T_NULL, %esi
    xor %edx, %edx
    call fmt_value_json
    CHKB "json null type", "null"

    /* ---------------- pow10_u64 */
    mov pow10_u64(%rip), %rax
    CHKV "pow10[0]", 1
    mov pow10_u64+8*18(%rip), %rax
    CHKV "pow10[18]", 1000000000000000000
    mov pow10_u64+8*7(%rip), %rax
    CHKV "pow10[7]", 10000000

    /* ---------------- dec_rescale */
    mov $12345, %rdi
    mov $2, %esi
    mov $4, %edx
    call dec_rescale
    CHKI "dec_rescale 123.45 -> s4", 1234500, 0
    mov $12345, %rdi
    mov $3, %esi
    mov $1, %edx
    call dec_rescale
    CHKI "dec_rescale 12.345 -> s1", 123, 0
    mov $12355, %rdi
    mov $3, %esi
    mov $1, %edx
    call dec_rescale
    CHKI "dec_rescale 12.355 -> s1", 124, 0
    mov $-12350, %rdi
    mov $3, %esi
    mov $1, %edx
    call dec_rescale
    CHKI "dec_rescale -12.350 -> s1", -124, 0
    mov $-12349, %rdi
    mov $3, %esi
    mov $1, %edx
    call dec_rescale
    CHKI "dec_rescale -12.349 -> s1", -123, 0
    mov $15, %rdi
    mov $1, %esi
    mov $0, %edx
    call dec_rescale
    CHKI "dec_rescale 1.5 -> s0", 2, 0
    mov $-25, %rdi
    mov $1, %esi
    mov $0, %edx
    call dec_rescale
    CHKI "dec_rescale -2.5 -> s0", -3, 0
    movabs $999999999999999999, %rdi
    mov $0, %esi
    mov $1, %edx
    call dec_rescale
    CHKI "dec_rescale 18 nines up", 0, 2
    mov $1, %rdi
    mov $0, %esi
    mov $18, %edx
    call dec_rescale
    CHKI "dec_rescale 1 -> s18", 0, 2
    mov $-9, %rdi
    mov $0, %esi
    mov $17, %edx
    call dec_rescale
    CHKI "dec_rescale -9 -> s17", -900000000000000000, 0
    movabs $9223372036854775807, %rdi
    mov $0, %esi
    mov $1, %edx
    call dec_rescale
    CHKI "dec_rescale int64 max up", 0, 2
    movabs $9223372036854775807, %rdi
    mov $0, %esi
    mov $0, %edx
    call dec_rescale
    CHKI "dec_rescale int64 max same", 0, 2
    movabs $999999999999999999, %rdi
    mov $18, %esi
    mov $0, %edx
    call dec_rescale
    CHKI "dec_rescale 0.99.. -> s0", 1, 0
    movabs $-499999999999999999, %rdi
    mov $18, %esi
    mov $0, %edx
    call dec_rescale
    CHKI "dec_rescale -0.49.. -> s0", 0, 0
    mov $0, %rdi
    mov $0, %esi
    mov $18, %edx
    call dec_rescale
    CHKI "dec_rescale 0 -> s18", 0, 0

    /* ---------------- dec_fits */
    mov $999, %rdi
    mov $3, %esi
    call dec_fits
    CHKV "dec_fits 999 p3", 1
    mov $1000, %rdi
    mov $3, %esi
    call dec_fits
    CHKV "dec_fits 1000 p3", 0
    mov $-999, %rdi
    mov $3, %esi
    call dec_fits
    CHKV "dec_fits -999 p3", 1
    mov $-1000, %rdi
    mov $3, %esi
    call dec_fits
    CHKV "dec_fits -1000 p3", 0
    movabs $-9223372036854775808, %rdi
    mov $18, %esi
    call dec_fits
    CHKV "dec_fits int64 min p18", 0
    movabs $999999999999999999, %rdi
    mov $18, %esi
    call dec_fits
    CHKV "dec_fits 18 nines p18", 1

    /* ---------------- dec_to_float */
    mov $12345, %rdi
    mov $2, %esi
    call dec_to_float
    movq %xmm0, %rax
    CHKV "dec_to_float 123.45", 0x405EDCCCCCCCCCCD
    mov $-5, %rdi
    mov $1, %esi
    call dec_to_float
    movq %xmm0, %rax
    CHKV "dec_to_float -0.5", 0xBFE0000000000000
    mov $7, %rdi
    mov $0, %esi
    call dec_to_float
    movq %xmm0, %rax
    CHKV "dec_to_float 7", 0x401C000000000000

    /* ---------------- float_to_dec */
    movabs $0x3FF8000000000000, %rax     /* 1.5 */
    movq %rax, %xmm0
    mov $18, %edi
    mov $0, %esi
    call float_to_dec
    CHKI "float_to_dec 1.5 s0", 2, 0
    movabs $0xC004000000000000, %rax     /* -2.5 */
    movq %rax, %xmm0
    mov $18, %edi
    mov $0, %esi
    call float_to_dec
    CHKI "float_to_dec -2.5 s0", -3, 0
    movabs $0x405EDD2F1A9FBE77, %rax     /* 123.456 */
    movq %rax, %xmm0
    mov $5, %edi
    mov $2, %esi
    call float_to_dec
    CHKI "float_to_dec 123.456 (5,2)", 12346, 0
    movabs $0x405EDD2F1A9FBE77, %rax
    movq %rax, %xmm0
    mov $4, %edi
    mov $2, %esi
    call float_to_dec
    CHKI "float_to_dec 123.456 (4,2)", 0, 2
    movabs $0x444B1AE4D6E2EF50, %rax     /* 1e21 */
    movq %rax, %xmm0
    mov $18, %edi
    mov $0, %esi
    call float_to_dec
    CHKI "float_to_dec 1e21", 0, 2
    movabs $0x43E0000000000000, %rax     /* 2^63 */
    movq %rax, %xmm0
    mov $18, %edi
    mov $0, %esi
    call float_to_dec
    CHKI "float_to_dec 2^63", 0, 2
    movabs $0x7FEFFFFFFFFFFFFF, %rax     /* max double */
    movq %rax, %xmm0
    mov $18, %edi
    mov $18, %esi
    call float_to_dec
    CHKI "float_to_dec max double", 0, 2
    pxor %xmm0, %xmm0
    mov $1, %edi
    mov $1, %esi
    call float_to_dec
    CHKI "float_to_dec 0 (1,1)", 0, 0

    /* ---------------- float_to_int64 */
    movabs $0x400F333333333333, %rax     /* 3.9 */
    movq %rax, %xmm0
    call float_to_int64
    CHKI "float_to_int64 3.9", 3, 0
    movabs $0xC00F333333333333, %rax     /* -3.9 */
    movq %rax, %xmm0
    call float_to_int64
    CHKI "float_to_int64 -3.9", -3, 0
    movabs $0xC3E0000000000000, %rax     /* -2^63 */
    movq %rax, %xmm0
    call float_to_int64
    CHKI "float_to_int64 -2^63", -9223372036854775808, 0
    movabs $0x43E0000000000000, %rax     /* 2^63 */
    movq %rax, %xmm0
    call float_to_int64
    CHKI "float_to_int64 2^63", 0, 2
    movabs $0xC3E0000000000001, %rax     /* just below -2^63 */
    movq %rax, %xmm0
    call float_to_int64
    CHKI "float_to_int64 < -2^63", 0, 2
    movabs $0x43DFFFFFFFFFFFFF, %rax     /* largest double < 2^63 */
    movq %rax, %xmm0
    call float_to_int64
    CHKI "float_to_int64 max", 9223372036854774784, 0
    movabs $0x7FF8000000000000, %rax     /* NaN */
    movq %rax, %xmm0
    call float_to_int64
    CHKI "float_to_int64 nan", 0, 2

    /* ---------------- summary */
    lea tbuf(%rip), %rdi
    call buf_free
    cmpq $0, nfail(%rip)
    jne 1f
    CSTR %rdi, "test_text: %ld passed\n"
    mov npass(%rip), %rsi
    xor %eax, %eax
    call printf
    xor %eax, %eax
    LEAVE
1:  CSTR %rdi, "test_text: %ld passed, %ld FAILED\n"
    mov npass(%rip), %rsi
    mov nfail(%rip), %rdx
    xor %eax, %eax
    call printf
    mov $1, %eax
    LEAVE
ENDF main
