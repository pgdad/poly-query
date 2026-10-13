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

#define WORKER_STACK_SIZE (256*1024*1024) /* reserved per pool thread (CR-6) */
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
#define PW_STATE 784    /* pool: 1 = part posted to the slot's worker */
#define PW_SIZE  832

#define DEFAULT_PAR_MIN 4096

    .bss
    .p2align 6
par_slots:  .zero PW_SIZE * MAX_THREADS
par_arenas: .zero 8 * MAX_THREADS
/* pool synchronisation (zero = PTHREAD_*_INITIALIZER in glibc):
 * mutex 40 bytes, two condition variables 48 bytes each */
#define POOL_SYNC_SIZE 192
#define POOL_SPIN 20000             /* pause iterations before sleeping */
    .p2align 6
pool_mutex:   .zero 64
pool_cv_work: .zero 64
pool_cv_done: .zero 64
pool_started: .zero MAX_THREADS     /* worker i is running */
#define CPUSET_BYTES 128            /* cpu_set_t: 1024 CPUs */
    .p2align 3
pool_cpumask: .zero CPUSET_BYTES    /* allowed CPUs (pool_pin) */
pool_cpus:    .zero 2 * CPUSET_BYTES * 8
pool_ncpu:    .quad 0               /* listed CPUs, 0 = not yet read */
pool_caller_pinned: .quad 0
    .data
    .p2align 3
pool_pending: .quad 0               /* posted parts not finished yet */
pool_pin_on:  .quad 1               /* pin the pool's threads to CPUs */
    .globl g_par_min
g_par_min:  .quad 0             /* minimum items per part (env PQ_PAR_MIN) */

    .text

/* par_body(slot rdi): runs one part with the worker's arena and handler */
FUNC par_body
    ENTER 16
    mov %rdi, %rbx
    mov %fs:t_vs_cur@tpoff, %rax    /* scratch stack top (restored: an */
    mov %rax, 0(%rsp)               /* error may leave marks behind) */
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
    mov 0(%rsp), %rax
    mov %rax, %fs:t_vs_cur@tpoff
    xor %eax, %eax
    LEAVE
ENDF par_body

/* ---------------------------------------------------------------- pool
 * Worker i (1 <= i < MAX_THREADS) is a thread that lives as long as the
 * process and runs the parts posted to slot i (PW_STATE = 1).  par_run
 * posts its parts under pool_mutex, wakes the workers (pool_cv_work) and
 * waits until pool_pending drops to 0 (pool_cv_done).  Both sides poll for
 * POOL_SPIN pause iterations (~0.1-0.3 ms) before sleeping, since the
 * operators of a query post parts in quick succession.  Workers are started
 * on first use; a forked child starts without any (par_after_fork). */

/* par_worker(slot rdi): pthread entry point of a pool worker */
FUNC par_worker
    push %rbx
    mov %rdi, %rbx
    call thread_stack_init          /* STACK_CHECK limit, signal stack */
0:  mov $POOL_SPIN, %ecx            /* poll a while: operators of a query */
1:  cmpq $1, PW_STATE(%rbx)         /* follow each other closely */
    je 2f
    pause
    dec %ecx
    jnz 1b
2:  lea pool_mutex(%rip), %rdi
    call pthread_mutex_lock
3:  cmpq $1, PW_STATE(%rbx)
    je 4f
    lea pool_cv_work(%rip), %rdi
    lea pool_mutex(%rip), %rsi
    call pthread_cond_wait
    jmp 3b
4:  lea pool_mutex(%rip), %rdi
    call pthread_mutex_unlock
    mov %rbx, %rdi
    call par_body
    lea pool_mutex(%rip), %rdi
    call pthread_mutex_lock
    movq $0, PW_STATE(%rbx)
    decq pool_pending(%rip)
    jnz 5f
    lea pool_cv_done(%rip), %rdi
    call pthread_cond_signal
5:  lea pool_mutex(%rip), %rdi
    call pthread_mutex_unlock
    jmp 0b
ENDF par_worker

/* pool_worker(i rdi) -> eax 1 if worker i runs (started now if needed);
 * called with pool_mutex held */
FUNC pool_worker
    push %rbx
    sub $16, %rsp
    mov %rdi, %rbx
    lea pool_started(%rip), %rax
    mov $1, %ecx
    cmpb $0, (%rax, %rbx)
    jne 9f
    cmpq $0, pool_caller_pinned(%rip)
    jne 1f
    movq $1, pool_caller_pinned(%rip)
    call pthread_self               /* the caller of par_run: CPU 0 */
    mov %rax, %rdi
    xor %esi, %esi
    call pool_pin
1:
    imul $PW_SIZE, %rbx, %rcx
    lea par_slots(%rip), %rax
    add %rax, %rcx                  /* the worker's slot */
    movq $0, PW_STATE(%rcx)
    sub $64, %rsp                   /* pthread_attr_t: a large stack, so */
    lea 0(%rsp), %rdi               /* workers evaluate any expression */
    call pthread_attr_init          /* the engine accepts (CR-6) */
    lea 0(%rsp), %rdi
    mov $WORKER_STACK_SIZE, %esi
    call pthread_attr_setstacksize
    imul $PW_SIZE, %rbx, %rcx
    lea par_slots(%rip), %rax
    add %rax, %rcx
    lea 64(%rsp), %rdi
    lea 0(%rsp), %rsi
    lea par_worker(%rip), %rdx
    call pthread_create
    mov %eax, 8(%rsp)               /* (attr no longer needed) */
    lea 0(%rsp), %rdi
    call pthread_attr_destroy
    mov 8(%rsp), %eax
    add $64, %rsp
    xor %ecx, %ecx
    test %eax, %eax
    jnz 9f
    mov 0(%rsp), %rdi
    call pthread_detach
    mov 0(%rsp), %rdi               /* worker i on the i-th allowed CPU */
    mov %rbx, %rsi
    call pool_pin
    lea pool_started(%rip), %rax
    movb $1, (%rax, %rbx)
    mov $1, %ecx
9:  mov %ecx, %eax
    add $16, %rsp
    pop %rbx
    ret
ENDF pool_worker

/* pool_pin(thread rdi, i rsi): binds the thread to the i-th CPU (mod
 * count) of the process's affinity mask, so that the caller of par_run
 * (i = 0) and the workers run on different cores (CPUs are listed in
 * ascending order, which on Linux enumerates all cores before their SMT
 * siblings).  Nothing happens when pinning is off (forked serve children,
 * which run concurrently) or fewer than two CPUs are allowed. */
FUNC pool_pin
    push %rbx
    push %r12
    push %r13
    sub $CPUSET_BYTES, %rsp
    mov %rdi, %r12
    mov %rsi, %r13
    cmpq $0, pool_pin_on(%rip)
    je 9f
    cmpq $0, pool_ncpu(%rip)        /* allowed CPUs, once */
    jne 2f
    movq $1, pool_ncpu(%rip)        /* (1 = none usable) */
    xor %edi, %edi
    mov $CPUSET_BYTES, %esi
    lea pool_cpumask(%rip), %rdx
    call sched_getaffinity
    test %eax, %eax
    jnz 9f
    xor %ecx, %ecx                  /* list the set bits */
    xor %edx, %edx
    lea pool_cpumask(%rip), %rsi
    lea pool_cpus(%rip), %rdi
1:  bt %rcx, (%rsi)
    jnc 11f
    mov %cx, (%rdi, %rdx, 2)
    inc %rdx
11: inc %ecx
    cmp $CPUSET_BYTES * 8, %ecx
    jb 1b
    mov %rdx, pool_ncpu(%rip)
2:  mov pool_ncpu(%rip), %rcx
    cmp $2, %rcx
    jb 9f
    mov %r13, %rax                  /* CPU = cpus[i mod count] */
    xor %edx, %edx
    div %rcx
    lea pool_cpus(%rip), %rax
    movzwl (%rax, %rdx, 2), %ebx
    lea 0(%rsp), %rdi
    xor %esi, %esi
    mov $CPUSET_BYTES, %edx
    call memset
    bts %rbx, 0(%rsp)
    mov %r12, %rdi
    mov $CPUSET_BYTES, %esi
    lea 0(%rsp), %rdx
    call pthread_setaffinity_np     /* (failure: stays unbound) */
9:  add $CPUSET_BYTES, %rsp
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF pool_pin

/* par_after_fork(): a fork()ed child has none of the parent's workers,
 * and does not pin threads (concurrent children would share the cores) */
FUNC par_after_fork
    sub $8, %rsp
    movq $0, pool_pin_on(%rip)
    lea pool_started(%rip), %rdi
    xor %esi, %esi
    mov $MAX_THREADS, %edx
    call memset
    lea pool_mutex(%rip), %rdi
    xor %esi, %esi
    mov $POOL_SYNC_SIZE, %edx
    call memset
    movq $0, pool_pending(%rip)
    add $8, %rsp
    ret
ENDF par_after_fork

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
5:  /* parts 1..P-1 go to the pool's workers (PW_TID = 1) or, when a
     * worker cannot be started, run on this thread after part 0 */
    lea pool_mutex(%rip), %rdi
    call pthread_mutex_lock
    mov $1, %r15d
6:  cmp %r14, %r15
    jae 7f
    mov %r15, %rdi
    call pool_worker
    test %eax, %eax
    jz 61f
    imul $PW_SIZE, %r15, %rcx
    lea par_slots(%rip), %rax
    add %rax, %rcx
    movq $1, PW_TID(%rcx)
    movq $1, PW_STATE(%rcx)
    incq pool_pending(%rip)
61: inc %r15
    jmp 6b
7:  lea pool_cv_work(%rip), %rdi
    call pthread_cond_broadcast
    lea pool_mutex(%rip), %rdi
    call pthread_mutex_unlock
    lea par_slots(%rip), %rdi       /* part 0 */
    call par_body
    mov $1, %r15d
8:  cmp %r14, %r15
    jae 9f
    imul $PW_SIZE, %r15, %rcx
    lea par_slots(%rip), %rax
    add %rax, %rcx
    cmpq $0, PW_TID(%rcx)
    jne 81f
    mov %rcx, %rdi
    call par_body
81: inc %r15
    jmp 8b
9:  mov $POOL_SPIN, %ecx            /* wait for the workers: poll, */
93: cmpq $0, pool_pending(%rip)     /* then sleep */
    je 10f
    pause
    dec %ecx
    jnz 93b
    lea pool_mutex(%rip), %rdi
    call pthread_mutex_lock
91: cmpq $0, pool_pending(%rip)
    je 92f
    lea pool_cv_done(%rip), %rdi
    lea pool_mutex(%rip), %rsi
    call pthread_cond_wait
    jmp 91b
92: lea pool_mutex(%rip), %rdi
    call pthread_mutex_unlock
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
