/*
 * par.S - data-parallel execution support (option `threads`).
 *
 *   par_for(n rdi, fn rsi, arg rdx) -> rax number of parts P
 *       splits [0, n) into P = min(threads, ceil(n / g_par_min)) contiguous
 *       ranges, part p = [n*p/P, n*(p+1)/P), and runs fn(arg, p, lo, hi) for
 *       every part: part 0 on the calling thread, the others on new
 *       threads.  Returns after all parts finished.  If parts raised errors,
 *       the error of the lowest failing part is re-raised (the one a serial
 *       execution would have hit first).  With P = 1 fn simply runs inline.
 *   par_run(n rdi, P rsi, fn rdx, arg rcx) -> rax P: the same with P given
 *   par_reset()  frees the worker arenas (start of every request)
 *   par_parts(n rdi) -> rax the P par_for would use for n items
 *
 * Workers allocate from their own arenas (thread-local t_arena, kept until
 * the request ends because results may point into them) and report errors
 * through a thread-local handler (t_jmpbuf, util.S), so the evaluator and
 * the operators need no other changes to run concurrently.  Callers must
 * only hand work to par_for that does not mutate shared state: lazily
 * decoded columns are decoded beforehand (par_prepare_tables) and plans
 * containing subqueries (which cache their results in the AST) run serially.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define PW_FN    0
#define PW_ARG   8
#define PW_PART  16
#define PW_LO    24
#define PW_HI    32
#define PW_ARENA 40
#define PW_ERR   48     /* error code raised by the part (0 = none) */
#define PW_TID   56     /* pthread_t, or 0 when it ran inline */
#define PW_MSG   64     /* 512 bytes */
#define PW_JB    576    /* jmp_buf (glibc: 200 bytes) */
#define PW_SIZE  832

#define DEFAULT_PAR_MIN 4096

    .bss
    .p2align 6
par_slots:  .zero PW_SIZE * MAX_THREADS
par_arenas: .zero 8 * MAX_THREADS
    .data
    .p2align 3
    .globl g_par_min
g_par_min:  .quad 0             /* minimum items per part (env PQ_PAR_MIN) */

    .text

/* par_body(slot rdi): runs one part with the worker's arena and handler */
FUNC par_body
    ENTER 0
    mov %rdi, %rbx
    mov PW_ARENA(%rbx), %rax
    mov %rax, %fs:t_arena@tpoff
    lea PW_JB(%rbx), %rdi
    mov %rdi, %fs:t_jmpbuf@tpoff
    call _setjmp
    test %eax, %eax
    jnz 1f
    mov PW_ARG(%rbx), %rdi
    mov PW_PART(%rbx), %rsi
    mov PW_LO(%rbx), %rdx
    mov PW_HI(%rbx), %rcx
    call *PW_FN(%rbx)
    jmp 2f
1:  mov %fs:t_err_code@tpoff, %rax  /* the part raised an error */
    mov %rax, PW_ERR(%rbx)
    mov %fs:0, %rsi
    lea t_err_msg@tpoff(%rsi), %rsi
    lea PW_MSG(%rbx), %rdi
    mov $512, %edx
    call memcpy
2:  movq $0, %fs:t_jmpbuf@tpoff
    movq $0, %fs:t_arena@tpoff
    xor %eax, %eax
    LEAVE
ENDF par_body

/* par_thread(slot rdi) -> rax 0: pthread entry point */
FUNC par_thread
    sub $8, %rsp
    call par_body
    call eval_thread_exit           /* thread-local buffers */
    call vs_thread_exit
    xor %eax, %eax
    add $8, %rsp
    ret
ENDF par_thread

/* par_parts(n rdi) -> rax */
FUNC par_parts
    push %rbx
    mov %rdi, %rbx
    mov g_par_min(%rip), %rcx
    test %rcx, %rcx
    jnz 1f
    CSTR %rdi, "PQ_PAR_MIN"
    call getenv
    mov $DEFAULT_PAR_MIN, %ecx
    test %rax, %rax
    jz 0f
    mov %rax, %rdi
    xor %esi, %esi
    mov $10, %edx
    call strtol
    mov %rax, %rcx
    cmp $1, %rcx
    jge 0f
    mov $DEFAULT_PAR_MIN, %ecx
0:  mov %rcx, g_par_min(%rip)
1:  mov %rbx, %rax                  /* ceil(n / min) */
    add %rcx, %rax
    dec %rax
    xor %edx, %edx
    div %rcx
    mov g_par_threads(%rip), %rcx   /* set per operator by pexec_threads */
    cmp %rcx, %rax
    cmova %rcx, %rax
    mov $1, %ecx
    test %rax, %rax
    cmovz %rcx, %rax
    pop %rbx
    ret
ENDF par_parts

/* par_for(n rdi, fn rsi, arg rdx) -> rax parts */
FUNC par_for
    push %rbx
    push %r12
    push %r13
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rdi, %rbx
    call par_parts
    mov %rbx, %rdi
    mov %rax, %rsi
    mov %r12, %rdx
    mov %r13, %rcx
    call par_run
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF par_for

/* par_run(n rdi, P rsi, fn rdx, arg rcx) -> rax P: par_for with a given
 * number of parts (1 <= P <= MAX_THREADS) */
FUNC par_run
    ENTER 16
    mov %rdi, %rbx                  /* n */
    mov %rdx, %r12                  /* fn */
    mov %rcx, %r13                  /* arg */
    mov %rsi, %r14                  /* P */
    cmp $1, %r14
    jne 1f
    mov %r13, %rdi                  /* serial: inline */
    xor %esi, %esi
    xor %edx, %edx
    mov %rbx, %rcx
    call *%r12
    mov $1, %eax
    LEAVE
1:  /* set up the slots */
    xor %r15d, %r15d
2:  cmp %r14, %r15
    jae 5f
    imul $PW_SIZE, %r15, %rax
    lea par_slots(%rip), %rcx
    add %rcx, %rax
    mov %rax, 0(%rsp)
    mov %r12, PW_FN(%rax)
    mov %r13, PW_ARG(%rax)
    mov %r15, PW_PART(%rax)
    movq $0, PW_ERR(%rax)
    movq $0, PW_TID(%rax)
    movq $0, PW_ARENA(%rax)
    mov %rbx, %rax                  /* lo = n * p / P */
    mul %r15
    div %r14
    mov 0(%rsp), %rcx
    mov %rax, PW_LO(%rcx)
    lea 1(%r15), %rax
    mul %rbx
    div %r14
    mov 0(%rsp), %rcx
    mov %rax, PW_HI(%rcx)
    test %r15, %r15                 /* part 0 runs on this thread: g_arena */
    jz 4f
    lea par_arenas(%rip), %rax
    mov (%rax, %r15, 8), %rax
    test %rax, %rax
    jnz 3f
    call arena_new
    lea par_arenas(%rip), %rcx
    mov %rax, (%rcx, %r15, 8)
3:  mov g_arena(%rip), %rcx         /* same memory budget as the request */
    mov AR_LIMIT(%rcx), %rcx
    mov %rcx, AR_LIMIT(%rax)
    mov 0(%rsp), %rcx
    mov %rax, PW_ARENA(%rcx)
4:  inc %r15
    jmp 2b
5:  /* start parts 1..P-1 */
    mov $1, %r15d
6:  cmp %r14, %r15
    jae 7f
    imul $PW_SIZE, %r15, %rcx
    lea par_slots(%rip), %rax
    add %rax, %rcx
    lea PW_TID(%rcx), %rdi
    xor %esi, %esi
    lea par_thread(%rip), %rdx
    call pthread_create
    test %eax, %eax
    jz 61f
    imul $PW_SIZE, %r15, %rcx       /* no thread: run it inline later */
    lea par_slots(%rip), %rax
    movq $0, PW_TID(%rax, %rcx)
61: inc %r15
    jmp 6b
7:  lea par_slots(%rip), %rdi       /* part 0 */
    call par_body
    mov $1, %r15d
8:  cmp %r14, %r15
    jae 10f
    imul $PW_SIZE, %r15, %rcx
    lea par_slots(%rip), %rax
    add %rax, %rcx
    mov PW_TID(%rcx), %rdi
    test %rdi, %rdi
    jnz 9f
    mov %rcx, %rdi
    call par_body
    jmp 91f
9:  xor %esi, %esi
    call pthread_join
91: inc %r15
    jmp 8b
10: /* re-raise the first error */
    xor %r15d, %r15d
11: cmp %r14, %r15
    jae 12f
    imul $PW_SIZE, %r15, %rcx
    lea par_slots(%rip), %rax
    add %rax, %rcx
    mov PW_ERR(%rcx), %rdi
    test %rdi, %rdi
    jz 111f
    lea PW_MSG(%rcx), %rsi
    call pq_raise
111: inc %r15
    jmp 11b
12: mov %r14, %rax
    LEAVE
ENDF par_run

/* par_reset(): releases the memory of the previous request's workers */
FUNC par_reset
    push %rbx
    xor %ebx, %ebx
1:  cmp $MAX_THREADS, %rbx
    jae 9f
    lea par_arenas(%rip), %rax
    mov (%rax, %rbx, 8), %rdi
    test %rdi, %rdi
    jz 2f
    call arena_reset
2:  inc %rbx
    jmp 1b
9:  pop %rbx
    ret
ENDF par_reset

/* par_prepare(plan rdi, tables rsi): decodes the referenced, still lazily
 * decoded PQCF columns of the plan's range variables, so that workers only
 * ever read them */
FUNC par_prepare
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d                /* range variable */
1:  cmp QP_NRV(%rbx), %r13
    jae 9f
    mov QP_RVS(%rbx), %rax
    mov (%rax, %r13, 8), %r14       /* rv */
    mov (%r12, %r13, 8), %rax
    mov %rax, %rsi                  /* table */
    inc %r13
    test %rsi, %rsi
    jz 1b
    cmpq $0, TB_MAP(%rsi)
    je 1b
    xor %r15d, %r15d
2:  cmp RV_NCOLS(%r14), %r15
    jae 1b
    mov RV_USED(%r14), %rax
    cmpb $0, (%rax, %r15)
    je 3f
    mov -8(%r12, %r13, 8), %rdi
    mov %r15, %rax
    shl $COL_SHIFT, %rax
    add TB_COLS(%rdi), %rax
    mov %rax, %rdi
    cmpb $0, COL_LAZY(%rdi)
    je 3f
    call pqcf_load_col
3:  inc %r15
    jmp 2b
9:  LEAVE
ENDF par_prepare
