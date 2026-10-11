/*
 * ast.S - generic access to the children of expression nodes, shared by
 * every tree walker (binder checks, structural equality, constant folding,
 * EXPLAIN printing).
 *
 *   expr_nchild(node rdi) -> rax number of child slots
 *   expr_child_ptr(node rdi, i rsi) -> rax address of child slot i
 *                                      (the slot may hold 0 = absent child)
 *
 * Slot layout per kind (see sql.inc):
 *   LIT, COL, OUTER, SUBQ, EXISTS: none
 *   UNARY, ISNULL, CAST, INSUBQ, AGG: A
 *   BINARY, LIKE: A, B
 *   BETWEEN: A, B, V1
 *   FUNC: A[0 .. V1-1]
 *   INLIST: A, B[0 .. V1-1]
 *   CASE: A, B[0 .. 2*V1-1], V2
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits
    .text

FUNC expr_nchild
    mov N_KIND(%rdi), %ecx
    xor %eax, %eax
    cmp $EK_UNARY, %ecx
    je 1f
    cmp $EK_ISNULL, %ecx
    je 1f
    cmp $EK_CAST, %ecx
    je 1f
    cmp $EK_INSUBQ, %ecx
    je 1f
    cmp $EK_AGG, %ecx
    je 1f
    cmp $EK_BINARY, %ecx
    je 2f
    cmp $EK_LIKE, %ecx
    je 2f
    cmp $EK_BETWEEN, %ecx
    je 3f
    cmp $EK_FUNC, %ecx
    je 4f
    cmp $EK_INLIST, %ecx
    je 5f
    cmp $EK_CASE, %ecx
    je 6f
    ret
1:  mov $1, %eax
    ret
2:  mov $2, %eax
    ret
3:  mov $3, %eax
    ret
4:  mov N_V1(%rdi), %rax
    cmpq $0, N_A(%rdi)
    jne 9f
    xor %eax, %eax
9:  ret
5:  mov N_V1(%rdi), %rax
    inc %rax
    ret
6:  mov N_V1(%rdi), %rax
    lea 2(%rax, %rax), %rax
    ret
ENDF expr_nchild

FUNC expr_child_ptr
    mov N_KIND(%rdi), %ecx
    cmp $EK_FUNC, %ecx
    je 4f
    cmp $EK_INLIST, %ecx
    je 5f
    cmp $EK_CASE, %ecx
    je 6f
    /* fixed slots A, B, V1 */
    lea N_A(%rdi), %rax
    test %rsi, %rsi
    jz 9f
    lea N_B(%rdi), %rax
    cmp $1, %rsi
    je 9f
    lea N_V1(%rdi), %rax
9:  ret
4:  mov N_A(%rdi), %rax
    lea (%rax, %rsi, 8), %rax
    ret
5:  lea N_A(%rdi), %rax
    test %rsi, %rsi
    jz 9b
    mov N_B(%rdi), %rax
    lea -8(%rax, %rsi, 8), %rax
    ret
6:  lea N_A(%rdi), %rax
    test %rsi, %rsi
    jz 9b
    mov N_V1(%rdi), %rcx
    add %rcx, %rcx                  /* 2*npairs */
    cmp %rcx, %rsi
    ja 7f
    mov N_B(%rdi), %rax
    lea -8(%rax, %rsi, 8), %rax
    ret
7:  lea N_V2(%rdi), %rax
    ret
ENDF expr_child_ptr
