/*
 * demo.S - pq-embed-demo: the minimal embedding example
 * (spec/apps/embedding.md §5).  Uses only the public API (polyquery.inc,
 * lib/libpolyquery.a) and glibc.
 *
 *   pq-embed-demo DATA_DIR CSV_FILE SQL
 *
 * Creates an engine instance on DATA_DIR, loads CSV_FILE (relative to
 * DATA_DIR, header row, inferred schema) as table t, runs SQL and prints the
 * result as CSV (pqledger.md §7).  Engine error: `error: CODE: MESSAGE` on
 * stderr, exit 1.  Bad usage: exit 2.
 *
 * AT&T syntax, System V AMD64 ABI.
 */
#include "polyquery.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
usage_msg:  .asciz "usage: pq-embed-demo DATA_DIR CSV_FILE SQL\n"
error_fmt:  .asciz "error: %s: %s\n"
table_t:    .asciz "t"
float_fmt:  .asciz "%.6f"
neg_zero:   .asciz "-0.000000"

    .text

/* fail(db rdi) -> does not return: prints the instance's last error */
fail:
    push %rbx
    mov %rdi, %rbx
    call pq_errcode
    mov %eax, %edi
    call pq_error_name
    mov %rax, %r12
    mov %rbx, %rdi
    call pq_errmsg
    mov stderr(%rip), %rdi
    lea error_fmt(%rip), %rsi
    mov %r12, %rdx
    mov %rax, %rcx
    xor %eax, %eax
    call fprintf
    mov $1, %edi
    call exit

/* put_csv_field(ptr rdi, len rsi): writes one CSV field, quoted when it is
 * empty, contains , " CR or LF, or starts or ends with a space */
put_csv_field:
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r12
    test %r12, %r12
    jz 3f                           /* empty (non-NULL) string */
    cmpb $' ', (%rbx)
    je 3f
    cmpb $' ', -1(%rbx, %r12)
    je 3f
    xor %ecx, %ecx
1:  cmp %r12, %rcx
    jae 2f
    movzbl (%rbx, %rcx), %eax
    inc %rcx
    cmp $',', %al
    je 3f
    cmp $'"', %al
    je 3f
    cmp $'\r', %al
    je 3f
    cmp $'\n', %al
    je 3f
    jmp 1b
2:  mov %rbx, %rdi                  /* as is */
    mov $1, %esi
    mov %r12, %rdx
    mov stdout(%rip), %rcx
    call fwrite
    jmp 9f
3:  mov $'"', %edi                  /* quoted, " doubled */
    mov stdout(%rip), %rsi
    call fputc
    xor %r13d, %r13d
4:  cmp %r12, %r13
    jae 6f
    movzbl (%rbx, %r13), %edi
    cmp $'"', %edi
    jne 5f
    mov stdout(%rip), %rsi
    call fputc
    mov $'"', %edi
5:  mov stdout(%rip), %rsi
    call fputc
    inc %r13
    jmp 4b
6:  mov $'"', %edi
    mov stdout(%rip), %rsi
    call fputc
9:  pop %r13
    pop %r12
    pop %rbx
    ret

/* put_value(result rdi, row rsi, col rdx): one value as a CSV field */
put_value:
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $96, %rsp                   /* text buffer at 0..95 */
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov PQ_RES_NCOLS(%rbx), %rax    /* value = values + (row * ncols + col) * 24 */
    imul %r12, %rax
    add %r13, %rax
    imul $PQ_VAL_SIZE, %rax, %r14
    add PQ_RES_VALUES(%rbx), %r14
    cmpq $0, PQ_VAL_IS_NULL(%r14)
    jne 9f                          /* NULL: empty unquoted field */
    mov %r13, %rax
    shl $PQ_COL_SHIFT, %rax
    add PQ_RES_COLUMNS(%rbx), %rax
    mov PQ_COL_TYPE(%rax), %eax
    cmp $PQ_TYPE_STRING, %eax
    jne 1f
    mov PQ_VAL_STR_PTR(%r14), %rdi
    mov PQ_VAL_STR_LEN(%r14), %rsi
    call put_csv_field
    jmp 9f
1:  cmp $PQ_TYPE_FLOAT64, %eax
    jne 3f
    lea 0(%rsp), %rdi               /* FLOAT64: %.6f, -0.000000 => 0.000000 */
    mov $96, %esi
    lea float_fmt(%rip), %rdx
    movsd PQ_VAL_F64(%r14), %xmm0
    mov $1, %eax
    call snprintf
    lea 0(%rsp), %rdi
    lea neg_zero(%rip), %rsi
    call strcmp
    lea 0(%rsp), %rdi
    test %eax, %eax
    jnz 2f
    inc %rdi                        /* skip the '-' */
2:  mov %rdi, %r15
    call strlen
    mov %r15, %rdi
    mov %rax, %rsi
    call put_csv_field
    jmp 9f
3:  mov %rbx, %rdi                  /* everything else: canonical text */
    mov %r12, %rsi
    mov %r13, %rdx
    lea 0(%rsp), %rcx
    mov $96, %r8d
    call pq_value_text
    lea 0(%rsp), %rdi
    mov %rax, %rsi
    call put_csv_field
9:  add $96, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    ret

/* print_csv(result rdi): header record, then one record per row */
print_csv:
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    xor %r12d, %r12d                /* header */
1:  cmp PQ_RES_NCOLS(%rbx), %r12
    jae 3f
    test %r12, %r12
    jz 2f
    mov $',', %edi
    mov stdout(%rip), %rsi
    call fputc
2:  mov %r12, %rax
    shl $PQ_COL_SHIFT, %rax
    add PQ_RES_COLUMNS(%rbx), %rax
    mov PQ_COL_NAME(%rax), %r13
    mov %r13, %rdi
    call strlen
    mov %r13, %rdi
    mov %rax, %rsi
    call put_csv_field
    inc %r12
    jmp 1b
3:  mov $'\n', %edi
    mov stdout(%rip), %rsi
    call fputc
    xor %r12d, %r12d                /* rows */
4:  cmp PQ_RES_NROWS(%rbx), %r12
    jae 9f
    xor %r13d, %r13d
5:  cmp PQ_RES_NCOLS(%rbx), %r13
    jae 7f
    test %r13, %r13
    jz 6f
    mov $',', %edi
    mov stdout(%rip), %rsi
    call fputc
6:  mov %rbx, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call put_value
    inc %r13
    jmp 5b
7:  mov $'\n', %edi
    mov stdout(%rip), %rsi
    call fputc
    inc %r12
    jmp 4b
9:  pop %r13
    pop %r12
    pop %rbx
    ret

/* main(argc, argv) */
    .globl main
    .type main, @function
main:
    push %rbx
    push %r12
    push %r13
    sub $(PQ_CONFIG_SIZE + 16), %rsp   /* pq_config at 0, db at 64, result at 72 */
    mov %rsi, %r12
    cmp $4, %edi
    je 1f
    lea usage_msg(%rip), %rdi
    mov stderr(%rip), %rsi
    call fputs
    mov $2, %eax
    jmp 9f
1:  lea 0(%rsp), %rdi               /* configuration: data dir, defaults */
    xor %esi, %esi
    mov $PQ_CONFIG_SIZE, %edx
    call memset
    mov 8(%r12), %rax
    mov %rax, PQ_CONFIG_DATA_DIR(%rsp)
    lea 0(%rsp), %rdi
    lea PQ_CONFIG_SIZE(%rsp), %rsi
    call pq_create
    test %eax, %eax
    jz 2f
    xor %edi, %edi
    call fail
2:  mov PQ_CONFIG_SIZE(%rsp), %rbx  /* db */
    mov %rbx, %rdi                  /* load CSV_FILE as t: header, inferred */
    lea table_t(%rip), %rsi
    mov 16(%r12), %rdx
    xor %ecx, %ecx
    xor %r8d, %r8d
    call pq_load_file
    test %eax, %eax
    jz 3f
    mov %rbx, %rdi
    call fail
3:  mov %rbx, %rdi                  /* run SQL */
    mov 24(%r12), %rsi
    xor %edx, %edx
    lea PQ_CONFIG_SIZE+8(%rsp), %rcx
    call pq_query
    test %eax, %eax
    jz 4f
    mov %rbx, %rdi
    call fail
4:  mov PQ_CONFIG_SIZE+8(%rsp), %r13
    mov %r13, %rdi
    call print_csv
    mov %r13, %rdi
    call pq_result_free
    mov %rbx, %rdi
    call pq_close
    xor %eax, %eax
9:  add $(PQ_CONFIG_SIZE + 16), %rsp
    pop %r13
    pop %r12
    pop %rbx
    ret
    .size main, .-main
