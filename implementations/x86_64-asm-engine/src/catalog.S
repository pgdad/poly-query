/*
 * catalog.S - the table catalog: name -> Table*, case-insensitive lookup.
 * Tables are immutable; replacing/dropping a table destroys its arena.
 *
 *   cat_find(ptr, len) -> rax Table* or 0
 *   cat_put(table)     -> adds, or replaces the table with the same name
 *   cat_drop(ptr, len) -> eax 1 if dropped, 0 if unknown
 *   cat_reset()
 *   cat_count() -> rax ; cat_at(i) -> rax Table* ; cat_sorted() -> rax Table*[] sorted by name (request arena)
 *   cat_swap(state)    exchanges the catalog with a saved one (3 words:
 *                      table array, length, capacity; embedding API instances)
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

    .data
    .p2align 3
cat_tables: .quad 0         /* Table*[] (malloc) */
cat_len:    .quad 0
cat_cap:    .quad 0

    .text

/* cat_index(ptr, len) -> rax index or -1 */
FUNC cat_index
    ENTER 0
    mov %rdi, %r12
    mov %rsi, %r13
    xor %ebx, %ebx
1:  cmp cat_len(%rip), %rbx
    jae 8f
    mov cat_tables(%rip), %rax
    mov (%rax, %rbx, 8), %rax
    mov TB_NAME(%rax), %rax
    lea 8(%rax), %rdx
    mov (%rax), %rcx
    mov %r12, %rdi
    mov %r13, %rsi
    call mem_ieq
    test %eax, %eax
    jnz 9f
    inc %rbx
    jmp 1b
8:  mov $-1, %rbx
9:  mov %rbx, %rax
    LEAVE
ENDF cat_index

FUNC cat_find
    sub $8, %rsp
    call cat_index
    add $8, %rsp
    cmp $-1, %rax
    je 1f
    mov cat_tables(%rip), %rcx
    mov (%rcx, %rax, 8), %rax
    ret
1:  xor %eax, %eax
    ret
ENDF cat_find

/* cat_put(table) */
FUNC cat_put
    ENTER 0
    mov %rdi, %rbx
    mov TB_NAME(%rbx), %rax
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call cat_index
    cmp $-1, %rax
    je 1f
    mov cat_tables(%rip), %rcx
    lea (%rcx, %rax, 8), %r12
    mov (%r12), %rax
    mov %rbx, (%r12)
    mov %rax, %rdi
    call table_free
    LEAVE
1:  mov cat_len(%rip), %rax
    cmp cat_cap(%rip), %rax
    jb 2f
    mov cat_cap(%rip), %rsi
    add %rsi, %rsi
    add $16, %rsi
    mov %rsi, cat_cap(%rip)
    shl $3, %rsi
    mov cat_tables(%rip), %rdi
    call xrealloc
    mov %rax, cat_tables(%rip)
2:  mov cat_tables(%rip), %rcx
    mov cat_len(%rip), %rax
    mov %rbx, (%rcx, %rax, 8)
    incq cat_len(%rip)
    LEAVE
ENDF cat_put

/* cat_drop(ptr, len) -> eax */
FUNC cat_drop
    ENTER 0
    call cat_index
    cmp $-1, %rax
    je 8f
    mov cat_tables(%rip), %rcx
    mov (%rcx, %rax, 8), %rdx
    mov cat_len(%rip), %rsi
    dec %rsi
    mov (%rcx, %rsi, 8), %rdi       /* move last into the hole */
    mov %rdi, (%rcx, %rax, 8)
    mov %rsi, cat_len(%rip)
    mov %rdx, %rdi
    call table_free
    mov $1, %eax
    LEAVE
8:  xor %eax, %eax
    LEAVE
ENDF cat_drop

FUNC cat_reset
    ENTER 0
1:  mov cat_len(%rip), %rax
    test %rax, %rax
    jz 2f
    dec %rax
    mov %rax, cat_len(%rip)
    mov cat_tables(%rip), %rcx
    mov (%rcx, %rax, 8), %rdi
    call table_free
    jmp 1b
2:  LEAVE
ENDF cat_reset

/* cat_swap(state rdi): exchanges the catalog state (tables, len, cap) with
 * the 3 words at rdi (api.S: each instance owns a catalog) */
FUNC cat_swap
    mov cat_tables(%rip), %rax
    xchg %rax, 0(%rdi)
    mov %rax, cat_tables(%rip)
    mov cat_len(%rip), %rax
    xchg %rax, 8(%rdi)
    mov %rax, cat_len(%rip)
    mov cat_cap(%rip), %rax
    xchg %rax, 16(%rdi)
    mov %rax, cat_cap(%rip)
    ret
ENDF cat_swap

FUNC cat_count
    mov cat_len(%rip), %rax
    ret
ENDF cat_count

/* cat_at(i) -> rax Table* (0 <= i < cat_count) */
FUNC cat_at
    mov cat_tables(%rip), %rax
    mov (%rax, %rdi, 8), %rax
    ret
ENDF cat_at

/* qsort comparator on Table** by name, case-insensitive */
FUNC cat_name_cmp
    mov (%rdi), %rax
    mov (%rsi), %rcx
    mov TB_NAME(%rax), %rax
    mov TB_NAME(%rcx), %rcx
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    lea 8(%rcx), %rdx
    mov (%rcx), %rcx
    jmp mem_icmp
ENDF cat_name_cmp

/* cat_sorted() -> rax Table*[] copy sorted by name */
FUNC cat_sorted
    ENTER 0
    mov cat_len(%rip), %rdi
    shl $3, %rdi
    add $8, %rdi
    call tmp_alloc
    mov %rax, %rbx
    mov %rax, %rdi
    mov cat_tables(%rip), %rsi
    mov cat_len(%rip), %rdx
    shl $3, %rdx
    test %rdx, %rdx
    jz 1f
    call memcpy
    mov %rbx, %rdi
    mov cat_len(%rip), %rsi
    mov $8, %edx
    lea cat_name_cmp(%rip), %rcx
    call qsort
1:  mov %rbx, %rax
    LEAVE
ENDF cat_sorted
