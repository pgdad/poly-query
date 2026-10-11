/*
 * test_par.S - unit tests for par.S (parallel parts) and the vector
 * scratch stack of vec.S:
 *   - par_parts: P = min(threads, ceil(n / min)), at least 1
 *   - par_run covers [0, n) with contiguous parts in order, each exactly once
 *   - parts > 0 allocate from their own arenas, part 0 from g_arena
 *   - errors: the error of the lowest failing part is re-raised
 *   - vs_alloc / vs_mark / vs_release behave as a stack
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define N 10000

    .data
    .p2align 3
passed:   .quad 0
failed:   .quad 0
    .bss
    .p2align 4
owner:    .zero 8 * N           /* part that visited item i (+1) */
lo_of:    .zero 8 * 64
hi_of:    .zero 8 * 64
arena_of: .zero 8 * 64
jb:       .zero 256

    .section .rodata
fmt_fail: .asciz "FAIL: %s\n"
fmt_done: .asciz "test_par: %ld passed, %ld failed\n"
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

/* visit(arg, part, lo, hi): marks the items of the part */
FUNC visit
    ENTER 0
    mov %rsi, %rbx
    lea lo_of(%rip), %rax
    mov %rdx, (%rax, %rbx, 8)
    lea hi_of(%rip), %rax
    mov %rcx, (%rax, %rbx, 8)
    lea owner(%rip), %rax
    lea 1(%rbx), %r8
1:  cmp %rcx, %rdx
    jae 2f
    add %r8, (%rax, %rdx, 8)        /* += so double visits show */
    inc %rdx
    jmp 1b
2:  call cur_arena
    lea arena_of(%rip), %rcx
    mov %rax, (%rcx, %rbx, 8)
    mov $64, %edi                   /* allocation in a worker */
    call tmp_alloc
    LEAVE
ENDF visit

/* fail_parts(arg, part, lo, hi): parts 2 and 3 raise different errors */
FUNC fail_parts
    sub $8, %rsp
    cmp $3, %rsi
    je 3f
    cmp $2, %rsi
    je 2f
    add $8, %rsp
    ret
2:  RAISE E_DIVISION_BY_ZERO, "part 2"
3:  RAISE E_NUMERIC_OVERFLOW, "part 3"
ENDF fail_parts

FUNC main
    ENTER 32
    call arena_new
    mov %rax, g_arena(%rip)

    /* ---- par_parts */
    movq $100, g_par_min(%rip)
    movq $8, g_par_threads(%rip)
    mov $250, %edi
    call par_parts
    xor %edi, %edi
    cmp $3, %rax
    sete %dil
    CSTR %rsi, "par_parts: 250 items, 100 per part -> 3"
    call check
    mov $100000, %edi
    call par_parts
    xor %edi, %edi
    cmp $8, %rax
    sete %dil
    CSTR %rsi, "par_parts: capped by threads"
    call check
    xor %edi, %edi
    call par_parts
    xor %edi, %edi
    cmp $1, %rax
    sete %dil
    CSTR %rsi, "par_parts: empty input -> 1 part"
    call check

    /* ---- par_run: coverage, order, arenas */
    mov $N, %edi
    mov $7, %esi
    lea visit(%rip), %rdx
    xor %ecx, %ecx
    call par_run
    xor %edi, %edi
    cmp $7, %rax
    sete %dil
    CSTR %rsi, "par_run: returns P"
    call check
    xor %ecx, %ecx                  /* every item exactly once */
    mov $1, %edi
1:  cmp $N, %rcx
    jae 2f
    lea owner(%rip), %rax
    mov (%rax, %rcx, 8), %rdx
    dec %rdx                        /* part */
    lea lo_of(%rip), %rax
    cmp (%rax, %rdx, 8), %rcx
    jb 11f
    lea hi_of(%rip), %rax
    cmp (%rax, %rdx, 8), %rcx
    jb 12f
11: xor %edi, %edi
12: inc %rcx
    jmp 1b
2:  CSTR %rsi, "par_run: each item visited once, by the part owning it"
    call check
    mov $1, %edi                    /* contiguous, ordered parts */
    lea lo_of(%rip), %rax
    cmpq $0, (%rax)
    je 3f
    xor %edi, %edi
3:  mov $1, %ecx
4:  cmp $7, %rcx
    jae 5f
    lea lo_of(%rip), %rax
    mov (%rax, %rcx, 8), %rdx
    lea hi_of(%rip), %rax
    cmp -8(%rax, %rcx, 8), %rdx
    je 41f
    xor %edi, %edi
41: inc %rcx
    jmp 4b
5:  lea hi_of(%rip), %rax
    cmpq $N, 48(%rax)
    je 51f
    xor %edi, %edi
51: CSTR %rsi, "par_run: parts are contiguous and in order"
    call check
    xor %edi, %edi
    lea arena_of(%rip), %rax
    mov (%rax), %rcx
    cmp g_arena(%rip), %rcx
    jne 6f
    mov 8(%rax), %rcx
    cmp g_arena(%rip), %rcx
    je 6f
    cmp 16(%rax), %rcx
    setne %dil
6:  CSTR %rsi, "par_run: part 0 uses g_arena, others their own arenas"
    call check

    /* ---- errors: the lowest failing part wins */
    lea jb(%rip), %rdi
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz 7f
    mov $N, %edi
    mov $5, %esi
    lea fail_parts(%rip), %rdx
    xor %ecx, %ecx
    call par_run
    xor %edi, %edi                  /* no error raised: failure */
    jmp 8f
7:  xor %edi, %edi
    cmpq $E_DIVISION_BY_ZERO, g_err_code(%rip)
    sete %dil
8:  CSTR %rsi, "par_run: re-raises the error of the lowest failing part"
    call check
    movq $0, g_jmpbuf(%rip)

    /* ---- vector scratch stack */
    call vs_mark
    mov %rax, 0(%rsp)
    mov $100, %edi
    call vs_alloc
    mov %rax, 8(%rsp)
    mov $100, %edi
    call vs_alloc
    mov 8(%rsp), %rcx
    sub %rcx, %rax
    xor %edi, %edi
    cmp $128, %rax                  /* 64-byte granules */
    sete %dil
    test $63, %rcx
    jz 9f
    xor %edi, %edi
9:  CSTR %rsi, "vs_alloc: aligned bump allocation"
    call check
    mov 0(%rsp), %rdi
    call vs_release
    mov $100, %edi
    call vs_alloc
    xor %edi, %edi
    cmp 8(%rsp), %rax
    sete %dil
    CSTR %rsi, "vs_release: pops back to the mark"
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
