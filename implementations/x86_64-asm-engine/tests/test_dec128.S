/*
 * test_dec128.S - unit tests for src/dec128.S (wide DECIMAL arithmetic):
 * parsing and formatting, rescaling and rounding, exact comparisons,
 * + - *, FLOAT64 conversions and the AVG quotient.  Prints "FAIL: ..." per
 * failing case and a summary line; exit status 1 on any failure.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .bss
    .p2align 4
tbuf:       .zero BUF_SIZE
npass:      .zero 8
nfail:      .zero 8
g_expect:   .zero 8          /* expected text (C string) */
g_name:     .zero 8          /* case name (C string) */

    .section .rodata
fmt_fail:   .asciz "FAIL: %s: got '%.*s', want '%s'\n"
fmt_done:   .asciz "test_dec128: %ld passed, %ld failed\n"
    .text

/* ======================================================== macros */

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

/* EXPECT "name", "expected text": sets g_name / g_expect */
.macro EXPECT name, want
    CSTR %rax, "\name"
    mov %rax, g_name(%rip)
    CSTR %rax, "\want"
    mov %rax, g_expect(%rip)
.endm

/* PF "text", prec, scale, mode, "expected": dec_parse, then fmt_dec128
 * ("ERRn" for status n) */
.macro PF str, prec, scale, mode, want
    EXPECT "parse \str", "\want"
    LSTR %rdi, %rsi, "\str"
    mov $\prec, %edx
    mov $\scale, %ecx
    mov $\mode, %r8d
    call t_pf
.endm

/* RS "text", from, to, p, "expected": dec_rescale128 of DECIMAL(38,from) */
.macro RS str, from, to, p, want
    EXPECT "rescale \str", "\want"
    LSTR %rdi, %rsi, "\str"
    mov $\from, %edx
    mov $\to, %ecx
    mov $\p, %r8d
    call t_rs
.endm

/* CMPT type_a, "a", type_b, "b", "expected -1/0/1": dec_cmp_any */
.macro CMPT ta, a, tb, b, want
    EXPECT "cmp \a \b", "\want"
    mov $\ta, %edi
    LSTR %rsi, %rdx, "\a"
    call t_val
    mov %rax, %rbx
    mov $\tb, %edi
    LSTR %rsi, %rdx, "\b"
    call t_val
    mov $\ta, %edi
    mov %rbx, %rsi
    mov $\tb, %edx
    mov %rax, %rcx
    call dec_cmp_any
    call t_int_result
.endm

/* AR op, type_a, "a", type_b, "b", type_r, "expected": dec_arith */
.macro AR op, ta, a, tb, b, tr, want
    EXPECT "arith \a \b", "\want"
    mov $\ta, %edi
    LSTR %rsi, %rdx, "\a"
    call t_val
    mov %rax, %rbx
    mov $\tb, %edi
    LSTR %rsi, %rdx, "\b"
    call t_val
    mov $\op, %edi
    mov $\ta, %esi
    mov %rbx, %rdx
    mov $\tb, %ecx
    mov %rax, %r8
    mov $\tr, %r9d
    call dec_arith
    mov $\tr, %edi
    mov %rax, %rsi
    call t_value_result
.endm

/* F2D double, prec, scale, "expected": double_to_dec128 */
.macro F2D dval, prec, scale, want
    .pushsection .rodata.tnum, "a"
    .p2align 3
8003:
    .double \dval
    .popsection
    EXPECT "f2d \dval", "\want"
    movsd 8003b(%rip), %xmm0
    mov $\prec, %edi
    mov $\scale, %esi
    call t_f2d
.endm

/* D2F "text", scale, "expected": dec128_to_double, printed by fmt_float */
.macro D2F str, scale, want
    EXPECT "d2f \str", "\want"
    LSTR %rdi, %rsi, "\str"
    mov $\scale, %edx
    xor %ecx, %ecx
    call t_d2f
.endm

/* AVG "sum", scale, count, "expected": avg192_to_double */
.macro AVG str, scale, count, want
    EXPECT "avg \str", "\want"
    LSTR %rdi, %rsi, "\str"
    mov $\scale, %edx
    mov $\count, %ecx
    call t_d2f
.endm

/* ======================================================== helpers */

/* t_compare(): tbuf vs g_expect, counts the result */
FUNC t_compare
    push %rbx
    mov g_expect(%rip), %rdi
    call strlen
    mov %rax, %rbx
    cmp tbuf+BUF_LEN(%rip), %rax
    jne 1f
    mov tbuf+BUF_DATA(%rip), %rdi
    mov g_expect(%rip), %rsi
    mov %rbx, %rdx
    call memcmp
    test %eax, %eax
    jnz 1f
    incq npass(%rip)
    pop %rbx
    ret
1:  incq nfail(%rip)
    lea fmt_fail(%rip), %rdi
    mov g_name(%rip), %rsi
    mov tbuf+BUF_LEN(%rip), %rdx
    mov tbuf+BUF_DATA(%rip), %rcx
    mov g_expect(%rip), %r8
    xor %eax, %eax
    call printf
    pop %rbx
    ret
ENDF t_compare

/* t_reset(): empties tbuf */
FUNC t_reset
    movq $0, tbuf+BUF_LEN(%rip)
    ret
ENDF t_reset

/* t_err(status edi): tbuf = "ERR<status>" */
FUNC t_err
    push %rbx
    mov %edi, %ebx
    lea tbuf(%rip), %rdi
    CSTR %rsi, "ERR"
    call buf_puts
    lea tbuf(%rip), %rdi
    mov %rbx, %rsi
    call buf_put_u64
    pop %rbx
    ret
ENDF t_err

/* t_pf(ptr rdi, len rsi, prec edx, scale ecx, mode r8d) */
FUNC t_pf
    ENTER 32
    mov %ecx, %ebx
    mov %rsp, %r9
    call dec_parse
    mov %eax, %r12d
    call t_reset
    test %r12d, %r12d
    jz 1f
    mov %r12d, %edi
    call t_err
    jmp 9f
1:  lea tbuf(%rip), %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov %ebx, %ecx
    call fmt_dec128
9:  call t_compare
    LEAVE
ENDF t_pf

/* t_rs(ptr rdi, len rsi, from edx, to ecx, p r8d) */
FUNC t_rs
    ENTER 32
    mov %edx, %r12d
    mov %ecx, %r13d
    mov %r8d, %r14d
    mov $38, %edx
    mov %r12d, %ecx
    xor %r8d, %r8d
    mov %rsp, %r9
    call dec_parse
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov %r12d, %edx
    mov %r13d, %ecx
    mov %r14d, %r8d
    call dec_rescale128
    mov %rax, 0(%rsp)
    mov %rdx, 8(%rsp)
    mov %ecx, %ebx
    call t_reset
    test %ebx, %ebx
    jz 1f
    mov %ebx, %edi
    call t_err
    jmp 9f
1:  lea tbuf(%rip), %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov %r13d, %ecx
    call fmt_dec128
9:  call t_compare
    LEAVE
ENDF t_rs

/* t_val(type edi, ptr rsi, len rdx) -> rax payload of the text as a value of
 * the type (INT64 or DECIMAL; wide values boxed) */
FUNC t_val
    ENTER 32
    mov %edi, %ebx
    mov %rsi, %rdi
    mov %rdx, %rsi
    cmp $T_INT, %bl
    jne 1f
    call text_parse_int64
    LEAVE
1:  mov %ebx, %edx
    shr $8, %edx
    movzbl %dl, %edx
    mov %ebx, %ecx
    shr $16, %ecx
    movzbl %cl, %ecx
    xor %r8d, %r8d
    mov %rsp, %r9
    call dec_parse
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov %ebx, %edx
    call dec_put
    LEAVE
ENDF t_val

/* t_int_result(value eax): tbuf = decimal text of the signed int */
FUNC t_int_result
    push %rbx
    movslq %eax, %rbx
    call t_reset
    lea tbuf(%rip), %rdi
    mov %rbx, %rsi
    call buf_put_i64
    call t_compare
    pop %rbx
    ret
ENDF t_int_result

/* t_value_result(type edi, payload rsi): tbuf = text form of the value */
FUNC t_value_result
    push %rbx
    push %r12
    sub $8, %rsp
    mov %edi, %ebx
    mov %rsi, %r12
    call t_reset
    lea tbuf(%rip), %rdi
    mov %ebx, %esi
    mov %r12, %rdx
    call fmt_value_text
    call t_compare
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF t_value_result

/* t_f2d(x xmm0, prec edi, scale esi) */
FUNC t_f2d
    ENTER 32
    mov %esi, %ebx
    mov %rsp, %rdx
    call double_to_dec128
    mov %eax, %r12d
    call t_reset
    test %r12d, %r12d
    jz 1f
    mov %r12d, %edi
    call t_err
    jmp 9f
1:  lea tbuf(%rip), %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov %ebx, %ecx
    call fmt_dec128
9:  call t_compare
    LEAVE
ENDF t_f2d

/* t_d2f(ptr rdi, len rsi, scale edx, count ecx): the DECIMAL(38,scale)
 * value as FLOAT64 (count 0: dec128_to_double), or the average of a sum of
 * that value over count rows (avg192_to_double) */
FUNC t_d2f
    ENTER 48
    mov %edx, %ebx
    mov %ecx, %r12d
    mov $38, %edx
    mov %ebx, %ecx
    xor %r8d, %r8d
    mov %rsp, %r9
    call dec_parse
    test %r12d, %r12d
    jnz 1f
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov %ebx, %edx
    call dec128_to_double
    jmp 2f
1:  mov 8(%rsp), %rax               /* sign-extend to 192 bits */
    sar $63, %rax
    mov %rax, 16(%rsp)
    mov %rsp, %rdi
    mov %r12, %rsi
    mov %ebx, %edx
    call avg192_to_double
2:  movsd %xmm0, 32(%rsp)
    call t_reset
    lea tbuf(%rip), %rdi
    movsd 32(%rsp), %xmm0
    call fmt_float
    call t_compare
    LEAVE
ENDF t_d2f

/* ======================================================== cases */

FUNC main
    ENTER 16
    call arena_new
    mov %rax, g_arena(%rip)

    /* parsing (exact mode 0, rounding mode 1) and canonical text */
    PF "12345678901234567890.1234567890", 38, 10, 0, "12345678901234567890.1234567890"
    PF "-0.0000000001", 38, 10, 0, "-0.0000000001"
    PF "99999999999999999999999999999999999999", 38, 0, 0, "99999999999999999999999999999999999999"
    PF "-99999999999999999999999999999999999999", 38, 0, 0, "-99999999999999999999999999999999999999"
    PF "100000000000000000000000000000000000000", 38, 0, 0, "ERR2"
    PF "00000000000000000000000000000000000000000001.5", 38, 1, 0, "1.5"
    PF "123456789012345678901", 20, 0, 0, "ERR2"
    PF "1.25", 38, 1, 1, "1.3"
    PF "-1.25", 38, 1, 1, "-1.3"
    PF "1.25", 38, 1, 0, "ERR3"
    PF "abc", 38, 1, 0, "ERR1"
    PF "1.2.3", 38, 1, 0, "ERR1"
    PF "", 38, 1, 0, "ERR1"
    PF "-", 38, 1, 0, "ERR1"
    PF ".5", 20, 2, 0, "0.50"
    PF "+7.", 20, 0, 0, "7"
    PF "0.12345678901234567890123456789012345678", 38, 38, 0, "0.12345678901234567890123456789012345678"
    PF "9999999999999999999999999999.99999999995", 38, 10, 1, "ERR2"
    PF "-0.00000000000000000000000000000000000001", 38, 38, 0, "-0.00000000000000000000000000000000000001"

    /* rescaling: exact upwards, half away from zero downwards */
    RS "1.25", 2, 1, 38, "1.3"
    RS "-1.25", 2, 1, 38, "-1.3"
    RS "0.5", 1, 0, 38, "1"
    RS "-0.5", 1, 0, 38, "-1"
    RS "0.4", 1, 0, 38, "0"
    RS "1", 0, 37, 38, "1.0000000000000000000000000000000000000"
    RS "10", 0, 37, 38, "ERR2"
    RS "-12345678901234567890", 0, 18, 38, "-12345678901234567890.000000000000000000"
    RS "12345678901234567890", 0, 19, 38, "ERR2"
    RS "99999999999999999999.5", 1, 0, 20, "ERR2"
    RS "99999999999999999999.4", 1, 0, 20, "99999999999999999999"
    RS "0.99999999999999999999999999999999999999", 38, 0, 38, "1"
    RS "0.49999999999999999999999999999999999999", 38, 0, 38, "0"
    RS "0", 0, 38, 1, "0.00000000000000000000000000000000000000"

    /* exact comparisons, any precision / scale, INT64 included */
    CMPT MKDEC(38,0), "9223372036854775808", T_INT, "9223372036854775807", "1"
    CMPT T_INT, "-9223372036854775808", MKDEC(19,0), "-9223372036854775808", "0"
    CMPT MKDEC(38,37), "0.1", MKDEC(1,1), "0.1", "0"
    CMPT MKDEC(38,0), "99999999999999999999999999999999999999", MKDEC(38,38), "0.99999999999999999999999999999999999999", "1"
    CMPT MKDEC(38,38), "-0.00000000000000000000000000000000000001", MKDEC(38,0), "0", "-1"
    CMPT MKDEC(18,2), "1.50", T_INT, "2", "-1"
    CMPT MKDEC(30,10), "-5", MKDEC(20,1), "-5.0", "0"
    CMPT MKDEC(30,0), "-99999999999999999999999999999", MKDEC(30,0), "-99999999999999999999999999998", "-1"

    /* + - * into DECIMAL(38, s) */
    AR B_ADD, MKDEC(38,0), "99999999999999999999999999999999999998", MKDEC(19,0), "1", MKDEC(38,0), "99999999999999999999999999999999999999"
    AR B_MUL, MKDEC(20,0), "12345678901234567890", MKDEC(20,0), "12345678901234567", MKDEC(38,0), "152415787532388356514250977776253630"
    AR B_SUB, MKDEC(38,10), "-0.0000000001", MKDEC(10,2), "2.50", MKDEC(38,10), "-2.5000000001"
    AR B_MUL, MKDEC(38,10), "-12345678901234567890.1234567890", MKDEC(10,2), "-1.25", MKDEC(38,12), "15432098626543209862.654320986250"
    AR B_MUL, MKDEC(38,0), "-9999999999999999999", MKDEC(38,0), "9999999999999999999", MKDEC(38,0), "-99999999999999999980000000000000000001"
    AR B_ADD, MKDEC(38,2), "-99999999999999999999999999999999999.99", MKDEC(38,0), "99999999999999999999999999999999999", MKDEC(38,2), "-0.99"

    /* FLOAT64 -> DECIMAL uses the exact binary value */
    F2D 0.1, 38, 30, "0.100000000000000005551115123126"
    F2D -2.5, 38, 0, "-3"
    F2D 1.5, 38, 0, "2"
    F2D 1e20, 38, 2, "100000000000000000000.00"
    F2D 1e38, 38, 0, "99999999999999997748809823456034029568"
    F2D 1e38, 37, 0, "ERR2"
    F2D 2e38, 38, 0, "ERR2"
    F2D 5e-324, 38, 38, "0.00000000000000000000000000000000000000"
    F2D -0.0, 38, 2, "0.00"

    /* DECIMAL -> FLOAT64 (nearest) and AVG of an exact sum */
    D2F "12345678901234567890123456789", 0, "1.2345678901234568e+28"
    D2F "0.1000000000000000000000000000000000001", 37, "0.1"
    D2F "-9999999999999999999999999999.9999999999", 10, "-1e+28"
    AVG "24691357802469135780.7469135779", 10, 4, "6.172839450617284e+18"
    AVG "-0.0000000001", 10, 3, "-3.3333333333333335e-11"
    AVG "0", 10, 7, "0"

    lea fmt_done(%rip), %rdi
    mov npass(%rip), %rsi
    mov nfail(%rip), %rdx
    xor %eax, %eax
    call printf
    xor %eax, %eax
    cmpq $0, nfail(%rip)
    setne %al
    LEAVE
ENDF main
