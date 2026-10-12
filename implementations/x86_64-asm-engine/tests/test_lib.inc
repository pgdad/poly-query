/*
 * test_lib.inc - helpers shared by the planner / optimizer unit tests
 * (included once per test program, after pq.inc and sql.inc):
 *
 *   check(cond edi, name rsi)          counts a passed / failed check
 *   test_done(name cstr rdi) -> eax    prints the summary, exit status
 *   mk_int_table(name pstr rdi, ncols rsi, nrows rdx) -> rax Table*
 *                                      column 0 "a" = row, column 1 "b" =
 *                                      row % 10 (ncols = 2); in the catalog
 *   plan_of(sql cstr rdi) -> rax       bound and planned query block
 */

    .data
    .p2align 3
passed:  .quad 0
failed:  .quad 0
    .p2align 3
s_a:     .quad 1
         .asciz "a"
    .p2align 3
s_b:     .quad 1
         .asciz "b"

    .section .rodata
fmt_fail: .asciz "FAIL: %s\n"
fmt_done: .asciz "%s: %ld passed, %ld failed\n"
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

/* test_done(name cstr rdi) -> eax 0 when every check passed, else 1 */
FUNC test_done
    sub $8, %rsp
    mov %rdi, %rsi
    lea fmt_done(%rip), %rdi
    mov passed(%rip), %rdx
    mov failed(%rip), %rcx
    xor %eax, %eax
    call printf
    xor %eax, %eax
    cmpq $0, failed(%rip)
    setne %al
    add $8, %rsp
    ret
ENDF test_done

/* mk_int_table(name pstr rdi, ncols rsi, nrows rdx): column 0 "a" = row,
 * column 1 "b" = row % 10 (when ncols = 2); finalized and in the catalog */
FUNC mk_int_table
    ENTER 16
    mov %rdi, %r12
    mov %rsi, %r13
    mov %rdx, %r14
    call arena_new
    mov %rax, %r15
    mov %r15, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    mov %r14, %rcx
    call table_new
    mov %rax, %rbx
    mov %r15, %rdi
    mov TB_COLS(%rbx), %rsi
    lea s_a(%rip), %rdx
    mov $T_INT, %ecx
    mov %r14, %r8
    call col_stage
    cmp $2, %r13
    jb 1f
    mov %r15, %rdi
    mov TB_COLS(%rbx), %rsi
    add $COL_SIZE, %rsi
    lea s_b(%rip), %rdx
    mov $T_INT, %ecx
    mov %r14, %r8
    call col_stage
1:  xor %ecx, %ecx
2:  cmp %r14, %rcx
    jae 4f
    mov TB_COLS(%rbx), %rsi
    mov COL_DATA(%rsi), %rax
    mov %rcx, (%rax, %rcx, 8)
    cmp $2, %r13
    jb 3f
    mov %rcx, %rax
    xor %edx, %edx
    mov $10, %edi
    div %rdi
    mov COL_SIZE+COL_DATA(%rsi), %rax
    mov %rdx, (%rax, %rcx, 8)
3:  inc %rcx
    jmp 2b
4:  mov %rbx, %rdi
    mov $LAYOUT_COLUMN, %esi
    mov $DICT_OFF, %edx
    call table_finalize
    mov %rbx, %rdi
    call cat_put
    mov %rbx, %rax
    LEAVE
ENDF mk_int_table

/* plan_of(sql cstr rdi) -> rax bound and planned query block */
FUNC plan_of
    ENTER 0
    mov %rdi, %rbx
    call strlen
    mov %rbx, %rdi
    mov %rax, %rsi
    call sql_parse
    mov ST_QUERY(%rax), %rdi
    call bind_statement
    LEAVE
ENDF plan_of

