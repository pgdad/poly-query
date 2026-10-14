/*
 * test_import.S - unit tests of pqledger's pure import helpers (import.S)
 * and of the result renderer (output.S).
 *
 * Linked with every app object except main.o, plus the library.  Tests:
 *   - imp_normalize_merchant: the §6.3 examples and edge cases
 *   - imp_parse_date: every date format, invalid dates and syntax
 *   - imp_days_from_ymd: days since 1970-01-01
 *   - imp_parse_amount: signs, parentheses, currency symbols, separators,
 *     digit limits, empty fields
 *   - out_result: table / csv / json of a hand-built pq_result
 * Prints one line per failure and a summary; exit status 1 on failure.
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

/* ====================================================================== */
/* main.S's globals, referenced by other modules (main.o is not linked).
 * Weak, so that a link that does include main.o is not affected. */
    .bss
    .p2align 3
    .weak g_format, g_opt_month, g_opt_from, g_opt_to, g_opt_account
    .weak g_opt_category, g_opt_uncat, g_opt_top, g_opt_clear
    .weak g_pos, g_npos, g_report_kind, g_setcat_id
g_format:       .quad 0
g_opt_month:    .quad 0
g_opt_from:     .quad 0
g_opt_to:       .quad 0
g_opt_account:  .quad 0
g_opt_category: .quad 0
g_opt_uncat:    .quad 0
g_opt_top:      .quad 0
g_opt_clear:    .quad 0
g_pos:          .zero 16
g_npos:         .quad 0
g_report_kind:  .quad 0
g_setcat_id:    .quad 0

t_buf:          .zero 512
t_run:          .quad 0
t_failed:       .quad 0

/* ====================================================================== */
/* T "text": a constant C string, its address assembled in place (.quad) */
.macro T text
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
9872:
    .asciz "\text"
    .popsection
    .quad 9872b
.endm

/* ACCDEF name, decimal separator, thousands separator, currency string */
.macro ACCDEF name, dec, thou, cur
\name:
    .zero ACC_DEC_SEP
    .quad \dec, \thou, \cur
    .zero ACC_SIZE - ACC_DEC_SEP - 24
.endm

    .section .rodata
s_empty:    .asciz ""
s_dollar:   .asciz "$"
s_euro:     .asciz "\342\202\254"

    .data
    .p2align 3
/* separators as character codes: 46 '.', 44 ',', 32 space, 39 apostrophe */
ACCDEF acc_plain, 46, 0, s_empty
ACCDEF acc_card, 46, 44, s_dollar
ACCDEF acc_giro, 44, 46, s_empty
ACCDEF acc_space, 46, 32, s_euro
ACCDEF acc_apos, 44, 39, s_empty

/* merchant normalization: input, expected */
t_merchants:
    T "Whole Foods Market #10234"
    T "WHOLE FOODS MARKET"
    T "SQ *Blue  Bottle 4421"
    T "SQ *BLUE BOTTLE"
    T "Rent 2026"
    T "RENT"
    T "7-Eleven 12"
    T "7-ELEVEN 12"
    T "#123"
    T "#123"
    T "  SQ *Blue \t Bottle 4421 \t"
    T "SQ *BLUE BOTTLE"
    T "Caf\303\251\tM\303\251lange  #9"
    T "CAF\303\251 M\303\251LANGE"
    T "AMAZON.COM*X2 AMZN.COM/BILL"
    T "AMAZON.COM*X2 AMZN.COM/BILL"
    T "Shop 12 345"
    T "SHOP 12"
    T ""
    T ""
    T "   "
    T ""
    T "REI #"
    T "REI #"
    T "a #12x"
    T "A #12X"
    T "Line\nbreak 99"
    T "LINE\nBREAK 99"
    T "x 007"
    T "X"
    T "abc 1234 #5"
    T "ABC 1234"
    .quad 0

/* dates: text, format, expected y*10000+m*100+d (or -1) */
t_dates:
    T "2026-01-05"
    .quad DF_ISO, 20260105
    T " 2024-02-29\t"
    .quad DF_ISO, 20240229
    T "2023-02-29"
    .quad DF_ISO, -1
    T "2000-02-29"
    .quad DF_ISO, 20000229
    T "1900-02-29"
    .quad DF_ISO, -1
    T "2026-02-30"
    .quad DF_ISO, -1
    T "2026-13-01"
    .quad DF_ISO, -1
    T "2026-00-10"
    .quad DF_ISO, -1
    T "2026-04-31"
    .quad DF_ISO, -1
    T "2026-1-05"
    .quad DF_ISO, -1
    T "0000-01-01"
    .quad DF_ISO, -1
    T "0001-01-01"
    .quad DF_ISO, 10101
    T "9999-12-31"
    .quad DF_ISO, 99991231
    T "2026/01/05"
    .quad DF_ISO, -1
    T ""
    .quad DF_ISO, -1
    T "20260105"
    .quad DF_COMPACT, 20260105
    T "2026015"
    .quad DF_COMPACT, -1
    T "20261232"
    .quad DF_COMPACT, -1
    T "2026-01-05"
    .quad DF_COMPACT, -1
    T "01/03/2026"
    .quad DF_US, 20260103
    T "1/3/2026"
    .quad DF_US, 20260103
    T "12/31/2026"
    .quad DF_US, 20261231
    T "13/01/2026"
    .quad DF_US, -1
    T "01/03/26"
    .quad DF_US, -1
    T "001/03/2026"
    .quad DF_US, -1
    T "1/3/20261"
    .quad DF_US, -1
    T "31/12/2026"
    .quad DF_EU, 20261231
    T "3/1/2026"
    .quad DF_EU, 20260103
    T "12/31/2026"
    .quad DF_EU, -1
    T "01.01.2026"
    .quad DF_DOT, 20260101
    T "29.2.2024"
    .quad DF_DOT, 20240229
    T "29.02.2023"
    .quad DF_DOT, -1
    T "01/01/2026"
    .quad DF_DOT, -1
    T "1..2026"
    .quad DF_DOT, -1
    .quad 0

/* days since 1970-01-01: ymd, days */
t_days:
    .quad 19700101, 0
    .quad 20000301, 11017
    .quad 10101, -719162
    .quad 20261014, 20740
    .quad 99991231, 2932896
    .quad 19691231, -1
    .quad 20240229, 19782
    .quad 0

/* amounts: text, settings, expected cents, expected status */
t_amounts:
    T "-12.00"
    .quad acc_plain, -1200, 0
    T "12.005"
    .quad acc_plain, 0, 2
    T "  +3.5 "
    .quad acc_plain, 350, 0
    T "(4.25)"
    .quad acc_plain, -425, 0
    T ""
    .quad acc_plain, 0, 1
    T " \t "
    .quad acc_plain, 0, 1
    T "1,234.56"
    .quad acc_plain, 0, 2
    T "12."
    .quad acc_plain, 0, 2
    T ".5"
    .quad acc_plain, 0, 2
    T "-0.00"
    .quad acc_plain, 0, 0
    T "0"
    .quad acc_plain, 0, 0
    T "1234567890123456"
    .quad acc_plain, 123456789012345600, 0
    T "9999999999999999.99"
    .quad acc_plain, 999999999999999999, 0
    T "12345678901234567"
    .quad acc_plain, 0, 2
    T "--5"
    .quad acc_plain, 0, 2
    T "-"
    .quad acc_plain, 0, 2
    T "()"
    .quad acc_plain, 0, 2
    T "abc"
    .quad acc_plain, 0, 2
    T "1.2.3"
    .quad acc_plain, 0, 2
    T "$31.06"
    .quad acc_card, 3106, 0
    T "($31.06)"
    .quad acc_card, -3106, 0
    T "$1,248.23"
    .quad acc_card, 124823, 0
    T "-$5"
    .quad acc_card, -500, 0
    T "5.00$"
    .quad acc_card, 500, 0
    T "$ 7.10"
    .quad acc_card, 710, 0
    T "$-5"
    .quad acc_card, 0, 2
    T "1.120,00"
    .quad acc_giro, 112000, 0
    T "71,83"
    .quad acc_giro, 7183, 0
    T "3.810,55"
    .quad acc_giro, 381055, 0
    T "1,5"
    .quad acc_giro, 150, 0
    T "1,555"
    .quad acc_giro, 0, 2
    T "1 234.50 \342\202\254"
    .quad acc_space, 123450, 0
    T "\342\202\254-5"
    .quad acc_space, 0, 2
    T "-\342\202\254 12"
    .quad acc_space, -1200, 0
    T "1'000,25"
    .quad acc_apos, 100025, 0
    .quad 0

/* ---------------------------------------------------------------------
 * a hand-built pq_result for out_result: 6 columns, 4 rows */
t_cols:
    .quad n_name, tn_string
    .long PQ_TYPE_STRING, 0, 0, 0
    .quad n_n, tn_int64
    .long PQ_TYPE_INT64, 0, 0, 0
    .quad n_amt, tn_dec
    .long PQ_TYPE_DECIMAL, 18, 2, 0
    .quad n_f, tn_float
    .long PQ_TYPE_FLOAT64, 0, 0, 0
    .quad n_ok, tn_bool
    .long PQ_TYPE_BOOLEAN, 0, 0, 0
    .quad n_d, tn_date
    .long PQ_TYPE_DATE, 0, 0, 0
/* pq_value: 16 bytes payload, is_null */
t_vals:
    .quad v_s0, 4, 0
    .quad 5, 0, 0
    .quad -1250, -1, 0
    .double -0.0000001
    .quad 0, 0
    .quad 1, 0, 0
    .quad 0, 0, 0

    .quad v_s1, 5, 0
    .quad -42, 0, 0
    .quad 5, 0, 0
    .double 1.5
    .quad 0, 0
    .quad 0, 0, 0
    .quad 0, 0, 1

    .quad v_s2, 4, 0
    .quad 0, 0, 1
    .quad 0, 0, 1
    .quad 0, 0, 1
    .quad 0, 0, 1
    .quad 1, 0, 0

    .quad v_s3, 5, 0
    .quad 0, 0, 1
    .quad 0, 0, 1
    .quad 0, 0, 1
    .quad 0, 0, 1
    .quad 0, 0, 1
t_res:
    .quad 6, t_cols, 4, t_vals

    .section .rodata
n_name:     .asciz "name"
n_n:        .asciz "n"
n_amt:      .asciz "amt"
n_f:        .asciz "f"
n_ok:       .asciz "ok"
n_d:        .asciz "d"
tn_string:  .asciz "STRING"
tn_int64:   .asciz "INT64"
tn_dec:     .asciz "DECIMAL(18,2)"
tn_float:   .asciz "FLOAT64"
tn_bool:    .asciz "BOOLEAN"
tn_date:    .asciz "DATE"
v_s0:       .asciz "a, b"
v_s1:       .asciz "\303\234\042q\042"
v_s2:       .asciz "t\tx\001"
v_s3:       .asciz " lead"

t_exp_table:
    .ascii "name     n     amt         f  ok     d\012-----  ---  ------ "
    .ascii " --------  -----  ----------\012a, b     5  -12.50  0.000000 "
    .ascii " true   1970-01-01\012\303\234\042q\042   -42    0.05  1.5000"
    .ascii "00  false\012t\011x\001                                 1970-"
    .asciz "01-02\012 lead\012(4 rows)\012"
t_exp_csv:
    .ascii "name,n,amt,f,ok,d\012\042a, b\042,5,-12.50,0.000000,true,1970"
    .ascii "-01-01\012\042\303\234\042\042q\042\042\042,-42,0.05,1.500000"
    .ascii ",false,\012t\011x\001,,,,,1970-01-02\012\042 lead\042,,,,,\012"
    .asciz ""
t_exp_json:
    .ascii "{\042name\042:\042a, b\042,\042n\042:5,\042amt\042:\042-12.50"
    .ascii "\042,\042f\042:0.000000,\042ok\042:true,\042d\042:\0421970-01"
    .ascii "-01\042}\012{\042name\042:\042\303\234\134\042q\134\042\042,\042"
    .ascii "n\042:-42,\042amt\042:\0420.05\042,\042f\042:1.500000,\042ok\042"
    .ascii ":false,\042d\042:null}\012{\042name\042:\042t\134tx\134u0001\042"
    .ascii ",\042n\042:null,\042amt\042:null,\042f\042:null,\042ok\042:nu"
    .ascii "ll,\042d\042:\0421970-01-02\042}\012{\042name\042:\042 lead\042"
    .ascii ",\042n\042:null,\042amt\042:null,\042f\042:null,\042ok\042:nu"
    .asciz "ll,\042d\042:null}\012"
t_exp_empty:
    .asciz "name  n  amt  f  ok  d\n----  -  ---  -  --  -\n(0 rows)\n"

    .text

/* t_fail(): counts a failed check */
t_fail:
    incq t_failed(%rip)
    ret

/* ---------------------------------------------------------------------
 * test_merchants(): every (input, expected) pair of t_merchants */
test_merchants:
    ENTER
    lea t_merchants(%rip), %rbx
1:  mov (%rbx), %r12            /* input */
    test %r12, %r12
    jz 9f
    incq t_run(%rip)
    mov %r12, %rdi
    call strlen
    mov %r12, %rdi
    mov %rax, %rsi
    lea t_buf(%rip), %rdx
    call imp_normalize_merchant
    mov %rax, %r13
    lea t_buf(%rip), %rcx
    movb $0, (%rcx,%rax)
    mov 8(%rbx), %rdi
    mov %rcx, %rsi
    call strcmp
    test %eax, %eax
    jz 2f
    call t_fail
    CSTR %rdi, "FAIL imp_normalize_merchant(\"%s\") = \"%s\", expected \"%s\"\n"
    mov %r12, %rsi
    lea t_buf(%rip), %rdx
    mov 8(%rbx), %rcx
    xor %eax, %eax
    call printf
2:  add $16, %rbx
    jmp 1b
9:  LEAVE

/* test_dates(): t_dates */
test_dates:
    ENTER
    lea t_dates(%rip), %rbx
1:  mov (%rbx), %r12
    test %r12, %r12
    jz 9f
    incq t_run(%rip)
    mov %r12, %rdi
    call strlen
    mov %r12, %rdi
    mov %rax, %rsi
    mov 8(%rbx), %rdx
    call imp_parse_date
    cmp 16(%rbx), %rax
    je 2f
    call t_fail
    CSTR %rdi, "FAIL imp_parse_date(\"%s\", %ld) = %ld, expected %ld\n"
    mov %r12, %rsi
    mov 8(%rbx), %rdx
    mov %rax, %rcx
    mov 16(%rbx), %r8
    xor %eax, %eax
    call printf
2:  add $24, %rbx
    jmp 1b
9:  LEAVE

/* test_days(): t_days */
test_days:
    ENTER
    lea t_days(%rip), %rbx
1:  mov (%rbx), %r12
    test %r12, %r12
    jz 9f
    incq t_run(%rip)
    mov %r12, %rdi
    call imp_days_from_ymd
    cmp 8(%rbx), %rax
    je 2f
    call t_fail
    CSTR %rdi, "FAIL imp_days_from_ymd(%ld) = %ld, expected %ld\n"
    mov %r12, %rsi
    mov %rax, %rdx
    mov 8(%rbx), %rcx
    xor %eax, %eax
    call printf
2:  add $16, %rbx
    jmp 1b
9:  LEAVE

/* test_amounts(): t_amounts */
test_amounts:
    ENTER
    lea t_amounts(%rip), %rbx
1:  mov (%rbx), %r12
    test %r12, %r12
    jz 9f
    incq t_run(%rip)
    mov %r12, %rdi
    call strlen
    mov %r12, %rdi
    mov %rax, %rsi
    mov 8(%rbx), %rdx
    call imp_parse_amount
    movslq %edx, %rdx
    cmp 16(%rbx), %rax
    jne 3f
    cmp 24(%rbx), %rdx
    je 2f
3:  call t_fail
    mov %rdx, %r8
    mov %rax, %rcx
    CSTR %rdi, "FAIL imp_parse_amount(\"%s\") = %ld status %ld, expected %ld status %ld\n"
    mov %r12, %rsi
    mov %rcx, %rdx
    mov %r8, %rcx
    mov 16(%rbx), %r8
    mov 24(%rbx), %r9
    xor %eax, %eax
    call printf
2:  add $32, %rbx
    jmp 1b
9:  LEAVE

/* t_render(format rdi, result rsi, expected rdx): out_result into a
 * cleared g_out, compared with the expected text */
t_render:
    ENTER
    mov %rdi, g_format(%rip)
    mov %rsi, %r12
    mov %rdx, %r13
    incq t_run(%rip)
    lea g_out(%rip), %rdi
    call ab_clear
    mov %r12, %rdi
    call out_result
    mov g_out+AB_DATA(%rip), %rdi
    mov %r13, %rsi
    call strcmp
    test %eax, %eax
    jz 1f
    call t_fail
    CSTR %rdi, "FAIL out_result format %ld:\n--- got\n%s--- expected\n%s---\n"
    mov g_format(%rip), %rsi
    mov g_out+AB_DATA(%rip), %rdx
    mov %r13, %rcx
    xor %eax, %eax
    call printf
1:  LEAVE

/* test_output(): the three formats, and a table without rows */
test_output:
    ENTER 16
    xor %edi, %edi
    lea t_res(%rip), %rsi
    lea t_exp_table(%rip), %rdx
    call t_render
    mov $1, %edi
    lea t_res(%rip), %rsi
    lea t_exp_csv(%rip), %rdx
    call t_render
    mov $2, %edi
    lea t_res(%rip), %rsi
    lea t_exp_json(%rip), %rdx
    call t_render
    /* zero rows */
    lea t_res(%rip), %rax
    movq $0, PQ_RES_NROWS(%rax)
    xor %edi, %edi
    lea t_res(%rip), %rsi
    lea t_exp_empty(%rip), %rdx
    call t_render
    mov $1, %edi
    lea t_res(%rip), %rsi
    CSTR %rdx, "name,n,amt,f,ok,d\n"
    call t_render
    mov $2, %edi
    lea t_res(%rip), %rsi
    lea s_empty(%rip), %rdx
    call t_render
    lea t_res(%rip), %rax
    movq $4, PQ_RES_NROWS(%rax)
    LEAVE

/* ===================================================================== */
FUNC main
    ENTER
    call test_merchants
    call test_dates
    call test_days
    call test_amounts
    call test_output
    CSTR %rdi, "test_import: %ld checks, %ld failed\n"
    mov t_run(%rip), %rsi
    mov t_failed(%rip), %rdx
    xor %eax, %eax
    call printf
    xor %eax, %eax
    cmpq $0, t_failed(%rip)
    setne %al
    LEAVE
ENDF main
