/*
 * test_hash.S - unit tests for hash.S: insertion / lookup of single and
 * composite keys, NULL = NULL key equality, string keys, -0.0 = +0.0 for
 * FLOAT64 keys and growth past many rehashes.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .data
    .p2align 3
passed:  .quad 0
failed:  .quad 0
types_int:  .quad T_INT, T_STR
types_flt:  .quad T_FLOAT
    .p2align 3
s_abc:   .quad 3
         .asciz "abc"
    .p2align 3
s_abc2:  .quad 3
         .asciz "abc"
    .p2align 3
s_abd:   .quad 3
         .asciz "abd"

    .section .rodata
fmt_fail: .asciz "FAIL: %s\n"
fmt_done: .asciz "test_hash: %ld passed, %ld failed\n"
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

/* mkcell2(i rdi, inull rsi, s rdx, snull rcx) -> rax 2 cells */
FUNC mkcell2
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov $32, %edi
    call tmp_zalloc
    mov %rbx, 0(%rax)
    mov %r12, 8(%rax)
    mov %r13, 16(%rax)
    mov %r14, 24(%rax)
    LEAVE
ENDF mkcell2

FUNC main
    ENTER 16
    call arena_new
    mov %rax, g_arena(%rip)
    /* composite (INT, STRING) keys */
    mov $2, %edi
    lea types_int(%rip), %rsi
    call ht_new
    mov %rax, %rbx
    mov $1, %edi
    xor %esi, %esi
    lea s_abc(%rip), %rdx
    xor %ecx, %ecx
    call mkcell2
    mov %rbx, %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    mov %edx, %edi
    CSTR %rsi, "first insert is new"
    call check
    mov $1, %edi                    /* equal key with a different string object */
    xor %esi, %esi
    lea s_abc2(%rip), %rdx
    xor %ecx, %ecx
    call mkcell2
    mov %rbx, %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    xor %edi, %edi
    test %edx, %edx
    sete %dil
    CSTR %rsi, "equal composite key found"
    call check
    mov $1, %edi
    xor %esi, %esi
    lea s_abd(%rip), %rdx
    xor %ecx, %ecx
    call mkcell2
    mov %rbx, %rdi
    mov %rax, %rsi
    xor %edx, %edx
    call ht_lookup
    xor %edi, %edi
    test %rax, %rax
    sete %dil
    CSTR %rsi, "different string not found"
    call check
    /* NULL keys are equal to each other, payload ignored */
    mov $5, %edi
    mov $1, %esi
    xor %edx, %edx
    mov $1, %ecx
    call mkcell2
    mov %rbx, %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    xor %edi, %edi
    mov $7, %edi
    mov $1, %esi
    xor %edx, %edx
    mov $1, %ecx
    call mkcell2
    mov %rbx, %rdi
    mov %rax, %rsi
    xor %edx, %edx
    call ht_lookup
    xor %edi, %edi
    test %rax, %rax
    setne %dil
    CSTR %rsi, "NULL equals NULL"
    call check
    /* growth: 5000 distinct integer keys, all found afterwards */
    xor %r12d, %r12d
1:  cmp $5000, %r12
    jae 2f
    mov %r12, %rdi
    xor %esi, %esi
    lea s_abc(%rip), %rdx
    xor %ecx, %ecx
    call mkcell2
    mov %rbx, %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    mov %r12, EN_D0(%rax)
    inc %r12
    jmp 1b
2:  mov HT_N(%rbx), %rax
    xor %edi, %edi
    cmp $5001, %rax                 /* + the NULL key; key 1 existed */
    sete %dil
    CSTR %rsi, "entry count after growth"
    call check
    xor %r12d, %r12d
    xor %r13d, %r13d                /* mismatches */
3:  cmp $5000, %r12
    jae 4f
    mov %r12, %rdi
    xor %esi, %esi
    lea s_abc(%rip), %rdx
    xor %ecx, %ecx
    call mkcell2
    mov %rbx, %rdi
    mov %rax, %rsi
    xor %edx, %edx
    call ht_lookup
    test %rax, %rax
    jz 31f
    cmp EN_D0(%rax), %r12
    je 32f
31: inc %r13
32: inc %r12
    jmp 3b
4:  xor %edi, %edi
    test %r13, %r13
    sete %dil
    CSTR %rsi, "all keys found after growth"
    call check
    /* FLOAT64: -0.0 and +0.0 are one key */
    mov $1, %edi
    lea types_flt(%rip), %rsi
    call ht_new
    mov %rax, %rbx
    mov $0x8000000000000000, %rax
    mov %rax, 0(%rsp)
    movq $0, 8(%rsp)
    mov %rbx, %rdi
    lea 0(%rsp), %rsi
    mov $1, %edx
    call ht_lookup
    mov $16, %edi
    call tmp_zalloc
    mov %rbx, %rdi
    mov %rax, %rsi
    xor %edx, %edx
    call ht_lookup
    xor %edi, %edi
    test %rax, %rax
    setne %dil
    CSTR %rsi, "-0.0 equals +0.0"
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
