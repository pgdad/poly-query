/*
 * hash.S - chained hash table keyed on tuples of value cells (VAL_SIZE each,
 * payload + null flag).  Key equality treats NULL as equal to NULL (grouping,
 * DISTINCT); callers that need SQL equality (joins, IN) skip NULL keys.
 * Used by GROUP BY, DISTINCT, DISTINCT aggregates, hash joins and IN (subquery).
 *
 *   ht_new(nk rdi, types rsi) -> rax HashTable*
 *   ht_lookup(ht rdi, cells rsi, insert edx) -> rax Entry* or 0, rdx 1 if inserted
 *   hash_cells(cells rdi, nk rsi, types rdx) -> rax
 *   cells_eq(a rdi, b rsi, nk rdx, types rcx) -> eax
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits
    .text

#define HASH_MUL 0x9E3779B97F4A7C15

/* ht_new(nk, types) -> HashTable* with 64 buckets */
FUNC ht_new
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $HT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, HT_NK(%r13)
    mov %r12, HT_TYPES(%r13)
    movq $64, HT_NB(%r13)
    mov $64*8, %edi
    call tmp_zalloc
    mov %rax, HT_BKT(%r13)
    mov %r13, %rax
    LEAVE
ENDF ht_new

/* hash_cells(cells, nk, types) -> rax */
FUNC hash_cells
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov $0x6a09e667f3bcc908, %r14   /* running hash */
    xor %r15d, %r15d
1:  cmp %r12, %r15
    jae 9f
    mov %r15, %rax
    shl $4, %rax
    mov $0x5bd1e995, %rcx           /* NULL marker */
    cmpq $0, VAL_NULL(%rbx, %rax)
    jne 5f
    mov VAL_P(%rbx, %rax), %rcx
    mov (%r13, %r15, 8), %edx
    movzbl %dl, %edx
    cmp $T_STR, %edx
    je 3f
    cmp $T_FLOAT, %edx
    jne 5f
    mov %rcx, %rdx                  /* +0.0 and -0.0 hash alike */
    shl $1, %rdx
    jnz 5f
    xor %ecx, %ecx
    jmp 5f
3:  mov (%rcx), %rsi                /* FNV-1a over the string bytes */
    lea 8(%rcx), %rdi
    mov $0xcbf29ce484222325, %rcx
    mov $0x100000001b3, %r8
4:  test %rsi, %rsi
    jz 5f
    movzbl (%rdi), %eax
    xor %rax, %rcx
    imul %r8, %rcx
    inc %rdi
    dec %rsi
    jmp 4b
5:  xor %rcx, %r14
    mov $HASH_MUL, %rax
    imul %rax, %r14
    mov %r14, %rax
    shr $29, %rax
    xor %rax, %r14
    inc %r15
    jmp 1b
9:  mov %r14, %rax
    LEAVE
ENDF hash_cells

/* cells_eq(a, b, nk, types) -> eax 1 if all cells equal (NULL = NULL) */
FUNC cells_eq
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    xor %r15d, %r15d
1:  cmp %r13, %r15
    jae 8f
    mov %r15, %rax
    shl $4, %rax
    mov VAL_NULL(%rbx, %rax), %rcx
    mov VAL_NULL(%r12, %rax), %rdx
    test %rcx, %rcx
    jnz 3f
    test %rdx, %rdx
    jnz 7f
    mov VAL_P(%rbx, %rax), %rsi
    mov VAL_P(%r12, %rax), %rdx
    cmp %rsi, %rdx
    je 4f
    mov (%r14, %r15, 8), %edi
    call value_cmp
    test %eax, %eax
    jnz 7f
    jmp 4f
3:  test %rdx, %rdx
    jz 7f
4:  inc %r15
    jmp 1b
7:  xor %eax, %eax
    LEAVE
8:  mov $1, %eax
    LEAVE
ENDF cells_eq

/* ht_grow(ht): quadruples the bucket array and rehashes */
FUNC ht_grow
    ENTER 16
    mov %rdi, %rbx
    mov HT_NB(%rbx), %r12           /* old nb */
    mov HT_BKT(%rbx), %r13          /* old buckets */
    lea (,%r12,4), %r14             /* new nb */
    lea (,%r14,8), %rdi
    call tmp_zalloc
    mov %rax, HT_BKT(%rbx)
    mov %r14, HT_NB(%rbx)
    dec %r14                        /* mask */
    xor %ecx, %ecx
1:  cmp %r12, %rcx
    jae 9f
    mov (%r13, %rcx, 8), %rdx       /* chain */
2:  test %rdx, %rdx
    jz 3f
    mov EN_NEXT(%rdx), %r8
    mov EN_HASH(%rdx), %rax
    and %r14, %rax
    mov HT_BKT(%rbx), %rsi
    mov (%rsi, %rax, 8), %r9
    mov %r9, EN_NEXT(%rdx)
    mov %rdx, (%rsi, %rax, 8)
    mov %r8, %rdx
    jmp 2b
3:  inc %rcx
    jmp 1b
9:  LEAVE
ENDF ht_grow

/* ht_lookup(ht, cells, insert) -> rax Entry* or 0, rdx 1 when newly inserted */
FUNC ht_lookup
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    mov %r12, %rdi
    mov HT_NK(%rbx), %rsi
    mov HT_TYPES(%rbx), %rdx
    call hash_cells
    mov %rax, %r14                  /* hash */
    mov HT_NB(%rbx), %rcx
    dec %rcx
    and %rax, %rcx
    mov HT_BKT(%rbx), %rax
    mov (%rax, %rcx, 8), %r15
1:  test %r15, %r15
    jz 5f
    cmp EN_HASH(%r15), %r14
    jne 2f
    mov EN_KEY(%r15), %rdi
    mov %r12, %rsi
    mov HT_NK(%rbx), %rdx
    mov HT_TYPES(%rbx), %rcx
    call cells_eq
    test %eax, %eax
    jnz 8f
2:  mov EN_NEXT(%r15), %r15
    jmp 1b
5:  xor %eax, %eax
    xor %edx, %edx
    test %r13d, %r13d
    jz 9f
    mov $EN_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r15
    mov %r14, EN_HASH(%r15)
    mov %r12, EN_KEY(%r15)
    mov HT_NB(%rbx), %rcx
    dec %rcx
    and %r14, %rcx
    mov HT_BKT(%rbx), %rax
    mov (%rax, %rcx, 8), %rdx
    mov %rdx, EN_NEXT(%r15)
    mov %r15, (%rax, %rcx, 8)
    incq HT_N(%rbx)
    mov HT_N(%rbx), %rax
    shr $1, %rax
    cmp HT_NB(%rbx), %rax
    jbe 6f
    mov %rbx, %rdi
    call ht_grow
6:  mov %r15, %rax
    mov $1, %edx
    jmp 9f
8:  mov %r15, %rax
    xor %edx, %edx
9:  LEAVE
ENDF ht_lookup
