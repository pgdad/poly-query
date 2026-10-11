/*
 * test_storage.S - unit tests for the Phase 3 storage layer:
 *   - crc32 check value (CRC-32 of "123456789" = 0xCBF43926) and empty input
 *   - utf8_valid on well-formed, overlong, surrogate and truncated input
 *   - table_finalize: identical values / NULLs through col_get in the
 *     column layout, the row layout and with a dictionary-encoded string
 *   - table_col_stats: null count, distinct count, min, max
 *   - idx_build / idx_eq / idx_range for HASH and BTREE indexes
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define NROWS 40

    .data
    .p2align 3
passed:  .quad 0
failed:  .quad 0
    .p2align 3
s_name:  .quad 1
         .asciz "t"
    .p2align 3
s_a:     .quad 1
         .asciz "a"
    .p2align 3
s_b:     .quad 1
         .asciz "b"
    .p2align 3
s_ix:    .quad 2
         .asciz "ix"
    .p2align 3
s_x:     .quad 1
         .asciz "x"
    .p2align 3
s_y:     .quad 1
         .asciz "y"

    .section .rodata
digits:   .ascii "123456789"
utf_ok:   .ascii "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80"   /* a é € 😀 */
utf_over: .ascii "\xc0\xaf"                               /* overlong '/' */
utf_surr: .ascii "\xed\xa0\x80"                           /* U+D800 */
utf_trunc: .ascii "\xe2\x82"
fmt_fail: .asciz "FAIL: %s\n"
fmt_done: .asciz "test_storage: %ld passed, %ld failed\n"
    .text

/* check(cond edi, name rsi) */
FUNC check
    sub $8, %rsp
    test %edi, %edi
    jz 1f
    incq passed(%rip)
    add $8, %rsp
    ret
1:  incq failed(%rip)
    lea fmt_fail(%rip), %rdi
    xor %eax, %eax
    call printf
    add $8, %rsp
    ret
ENDF check

/* mk_table(layout rdi, dict rsi) -> rax finalized table with columns
 * a INT64 = i % 7 (NULL when i % 5 = 0) and b STRING = "x"/"y" alternating */
FUNC mk_table
    ENTER 16
    mov %rdi, 0(%rsp)
    mov %rsi, 8(%rsp)
    call arena_new
    mov %rax, %r15
    mov %r15, %rdi
    lea s_name(%rip), %rsi
    mov $2, %edx
    mov $NROWS, %ecx
    call table_new
    mov %rax, %rbx
    mov %r15, %rdi
    mov TB_COLS(%rbx), %rsi
    lea s_a(%rip), %rdx
    mov $T_INT, %ecx
    mov $NROWS, %r8d
    call col_stage
    mov %r15, %rdi
    mov TB_COLS(%rbx), %rsi
    add $COL_SIZE, %rsi
    lea s_b(%rip), %rdx
    mov $T_STR, %ecx
    mov $NROWS, %r8d
    call col_stage
    mov TB_COLS(%rbx), %r12         /* column a */
    lea COL_SIZE(%r12), %r13        /* column b */
    xor %r14d, %r14d
1:  cmp $NROWS, %r14
    jae 3f
    mov %r14, %rax
    xor %edx, %edx
    mov $7, %ecx
    div %rcx
    mov COL_DATA(%r12), %rax
    mov %rdx, (%rax, %r14, 8)
    mov %r14, %rax
    xor %edx, %edx
    mov $5, %ecx
    div %rcx
    test %rdx, %rdx
    jnz 2f
    mov COL_NULLS(%r12), %rax
    movb $1, (%rax, %r14)
    mov COL_DATA(%r12), %rax
    movq $0, (%rax, %r14, 8)
2:  lea s_x(%rip), %rax
    lea s_y(%rip), %rcx
    test $1, %r14
    cmovnz %rcx, %rax
    mov COL_DATA(%r13), %rcx
    mov %rax, (%rcx, %r14, 8)
    inc %r14
    jmp 1b
3:  mov %rbx, %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    call table_finalize
    mov %rbx, %rax
    LEAVE
ENDF mk_table

/* verify_table(t rdi) -> eax 1 if every value reads back as generated */
FUNC verify_table
    ENTER 0
    mov %rdi, %rbx
    xor %r14d, %r14d
1:  cmp $NROWS, %r14
    jae 8f
    mov TB_COLS(%rbx), %rdi
    mov %r14, %rsi
    call col_get
    mov %rax, %r12
    mov %edx, %r13d
    mov %r14, %rax
    xor %edx, %edx
    mov $5, %ecx
    div %rcx
    test %rdx, %rdx
    jnz 2f
    test %r13d, %r13d               /* expected NULL */
    jz 9f
    jmp 3f
2:  test %r13d, %r13d
    jnz 9f
    mov %r14, %rax
    xor %edx, %edx
    mov $7, %ecx
    div %rcx
    cmp %rdx, %r12
    jne 9f
3:  mov TB_COLS(%rbx), %rdi
    add $COL_SIZE, %rdi
    mov %r14, %rsi
    call col_get
    test %edx, %edx
    jnz 9f
    movzbl 8(%rax), %eax
    mov $'x', %ecx
    mov $'y', %edx
    test $1, %r14
    cmovnz %edx, %ecx
    cmp %ecx, %eax
    jne 9f
    inc %r14
    jmp 1b
8:  mov $1, %eax
    LEAVE
9:  xor %eax, %eax
    LEAVE
ENDF verify_table

FUNC main
    ENTER 48
    call arena_new
    mov %rax, g_arena(%rip)
    /* ---- CRC-32 */
    lea digits(%rip), %rdi
    mov $9, %esi
    call crc32
    xor %edi, %edi
    cmp $0xCBF43926, %eax
    sete %dil
    CSTR %rsi, "crc32 check value"
    call check
    lea digits(%rip), %rdi
    xor %esi, %esi
    call crc32
    xor %edi, %edi
    test %eax, %eax
    sete %dil
    CSTR %rsi, "crc32 of empty input"
    call check
    /* ---- UTF-8 */
    lea utf_ok(%rip), %rdi
    mov $10, %esi
    call utf8_valid
    mov %eax, %edi
    CSTR %rsi, "utf8 well-formed"
    call check
    lea utf_over(%rip), %rdi
    mov $2, %esi
    call utf8_valid
    xor %edi, %edi
    test %eax, %eax
    sete %dil
    CSTR %rsi, "utf8 overlong rejected"
    call check
    lea utf_surr(%rip), %rdi
    mov $3, %esi
    call utf8_valid
    xor %edi, %edi
    test %eax, %eax
    sete %dil
    CSTR %rsi, "utf8 surrogate rejected"
    call check
    lea utf_trunc(%rip), %rdi
    mov $2, %esi
    call utf8_valid
    xor %edi, %edi
    test %eax, %eax
    sete %dil
    CSTR %rsi, "utf8 truncated rejected"
    call check
    /* ---- layouts */
    mov $LAYOUT_COLUMN, %edi
    mov $DICT_OFF, %esi
    call mk_table
    mov %rax, 0(%rsp)
    mov %rax, %rdi
    call verify_table
    mov %eax, %edi
    CSTR %rsi, "column layout values"
    call check
    mov $LAYOUT_ROW, %edi
    mov $DICT_OFF, %esi
    call mk_table
    mov %rax, %rdi
    call verify_table
    mov %eax, %edi
    CSTR %rsi, "row layout values"
    call check
    mov $LAYOUT_COLUMN, %edi
    mov $DICT_ON, %esi
    call mk_table
    mov %rax, %rbx
    xor %edi, %edi
    mov TB_COLS(%rbx), %rax
    cmpq $0, COL_SIZE+COL_DICT(%rax)
    setne %dil
    CSTR %rsi, "string column dictionary encoded"
    call check
    mov %rbx, %rdi
    call verify_table
    mov %eax, %edi
    CSTR %rsi, "dictionary-encoded values"
    call check
    /* ---- statistics of column a: 8 NULLs, values 1..6 (0 only at i%5=0) */
    mov 0(%rsp), %rdi
    xor %esi, %esi
    call table_col_stats
    mov %rax, %rbx
    xor %edi, %edi
    cmpq $8, CST_NULLS(%rbx)
    sete %dil
    CSTR %rsi, "stats null_count"
    call check
    xor %edi, %edi
    cmpq $7, CST_DISTINCT(%rbx)
    sete %dil
    CSTR %rsi, "stats distinct_count"
    call check
    xor %edi, %edi
    cmpq $0, CST_MIN(%rbx)
    jne 1f
    cmpq $6, CST_MAX(%rbx)
    sete %dil
1:  CSTR %rsi, "stats min/max"
    call check
    /* ---- HASH index: a = 3 -> rows 3, 17, 24, 31, 38 (not 10: NULL) */
    mov 0(%rsp), %rdi
    xor %esi, %esi
    mov $IXK_HASH, %edx
    lea s_ix(%rip), %rcx
    call idx_build
    mov %rax, 8(%rsp)
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, %rbx
    mov 8(%rsp), %rdi
    mov $3, %esi
    mov %rbx, %rdx
    call idx_eq
    xor %edi, %edi
    cmpq $5, VEC_LEN(%rbx)
    sete %dil
    CSTR %rsi, "hash index equality count"
    call check
    /* ---- BTREE index: 2 <= a < 4 and a > 5 */
    mov 0(%rsp), %rdi
    xor %esi, %esi
    mov $IXK_BTREE, %edx
    lea s_ix(%rip), %rcx
    call idx_build
    mov %rax, 8(%rsp)
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, %rbx
    mov 8(%rsp), %rdi
    mov $2, %esi
    mov $4, %edx
    mov $RF_LO|RF_LOI|RF_HI, %ecx
    mov %rbx, %r8
    call idx_range
    xor %edi, %edi                  /* a=2: 2,9,16,23,37 (30 NULL); a=3: 5 rows */
    cmpq $10, VEC_LEN(%rbx)
    sete %dil
    CSTR %rsi, "btree range [2, 4)"
    call check
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, %rbx
    mov 8(%rsp), %rdi
    mov $5, %esi
    xor %edx, %edx
    mov $RF_LO, %ecx
    mov %rbx, %r8
    call idx_range
    xor %edi, %edi                  /* a=6: 6,13,27,34 (20 NULL) */
    cmpq $4, VEC_LEN(%rbx)
    sete %dil
    CSTR %rsi, "btree range (5, inf)"
    call check
    lea fmt_done(%rip), %rdi
    mov passed(%rip), %rsi
    mov failed(%rip), %rdx
    xor %eax, %eax
    call printf
    xor %eax, %eax
    cmpq $0, failed(%rip)
    setne %al
    LEAVE
ENDF main
