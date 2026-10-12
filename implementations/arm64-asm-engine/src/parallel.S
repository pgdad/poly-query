// =============================================================================
// parallel.S — intra-query parallelism (Phase 5, option "threads").
//
//   par_run(x0 fn, x1 args, x2 arg stride, x3 n)
//       runs fn(args + i * stride) for i < n on the worker pool and the
//       calling thread, and waits for all of them. Raises the first error
//       (lowest i) a task raised, after every task has finished.
//   expr_par_safe(x0 Node* or 0) -> w0 1 if the expression may be evaluated
//       on a worker thread (no subquery: their results are cached in shared
//       SubPlans on first use).
//
// A pool thread runs a task with a copy of the caller's request state (deadline,
// cancellation flag, memory budget, execution settings, catalog version) and
// its own error handler (setjmp) and request arena. When it finishes, its
// arena chunks are moved into the caller's arena (arena_adopt), so memory a
// task allocated (tuple sets, strings) lives until the request ends exactly
// like memory of the calling thread. Pool threads never touch the caller's
// arena, so tasks need no locking as long as they write only their own
// argument records. Tasks the caller runs itself (wk_inline) allocate from
// its arena directly. Pool threads are created on demand (pool_grow) and
// live until the process exits.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// Worker record (one per task, caller's arena)
#define WK_FN       0               // task function
#define WK_ARG      8               // its argument
#define WK_DEADLINE 16              // copies of the caller's TLS state
#define WK_CANCEL   24
#define WK_LIMIT    32
#define WK_THREADS  40
#define WK_MODE     48              // u32
#define WK_CAT      64
#define WK_US       72              // task run time (PQ_TRACE_PAR)
#define WK_ERR      88              // u32 error code (0 = none)
#define WK_ARENA    96              // Arena handed back (AR_SIZE)
#define WK_MSG      128             // error message (WK_MSGMAX bytes, NUL)
#define WK_MSGMAX   256
#define WK_SIZE     (128 + WK_MSGMAX)

    .text

// Job: one par_run call, queued for the pool (caller's arena)
#define JB_NEXT     0               // next job in the queue
#define JB_RECS     8               // worker records
#define JB_N        16              // tasks
#define JB_CLAIMED  24              // tasks handed out
#define JB_DONE     32              // tasks finished
#define JB_SIZE     48

#define POOL_MAX    64              // pool threads at most

    .section .rodata
s_trace:        .asciz "par %p tasks=%ld us=%ld max=%ld sum=%ld\n"

    .bss
    .p2align 4
g_pool_lock:    .skip 64            // pthread_mutex_t: guards the pool state
g_pool_work:    .skip 64            // pthread_cond_t: a job was queued
g_pool_done:    .skip 64            // pthread_cond_t: a job's last task ended
g_pool_head:    .skip 8             // Job* queue (FIFO)
g_pool_tail:    .skip 8
g_pool_threads: .skip 8             // pool threads started

    .data
    .p2align 3
    .global g_pool_spin, g_par_trace
g_par_trace:    .quad 0             // 1: trace par_run calls on stderr
g_pool_spin:    .quad 1000          // µs of polling before a thread sleeps

    .text

// =============================================================================
// par_run(x0 fn, x1 args, x2 stride, x3 n)
// The tasks are queued as one job for the worker pool (persistent threads,
// started on demand: at most n - 1 are needed); the calling thread claims
// tasks of its own job too and then waits for the ones still running.
// Because the caller works on its own job instead of waiting for a free
// thread, nested and concurrent par_run calls cannot deadlock.
//   x19 fn, x20 args, x21 stride, x22 n, x23 workers, x24 i, x25 record,
//   x26 job
// =============================================================================
FUNC par_run
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x0, #WK_SIZE
    mul  x0, x0, x22
    bl   arena_zalloc
    mov  x23, x0
    mov  x24, #0
1:  cmp  x24, x22                       // worker records
    b.hs 2f
    mov  x9, #WK_SIZE
    madd x25, x24, x9, x23
    str  x19, [x25, #WK_FN]
    madd x9, x24, x21, x20
    str  x9, [x25, #WK_ARG]
    TLS_LDR x9, g_deadline
    str  x9, [x25, #WK_DEADLINE]
    TLS_LDR x9, g_cancel_flag
    str  x9, [x25, #WK_CANCEL]
    TLS_LDR x9, g_arena_limit
    str  x9, [x25, #WK_LIMIT]
    TLS_LDR x9, g_x_threads
    str  x9, [x25, #WK_THREADS]
    TLS_ADDR x9, g_x_mode
    ldr  w9, [x9]
    str  w9, [x25, #WK_MODE]
    TLS_LDR x9, g_cat
    str  x9, [x25, #WK_CAT]
    add  x24, x24, #1
    b    1b
2:  mov  x27, #0                        // PQ_TRACE_PAR: start time
    LDR_G x9, g_par_trace
    cbz  x9, 21f
    bl   now_us
    mov  x27, x0
21: mov  x0, #JB_SIZE
    bl   arena_zalloc
    mov  x26, x0
    str  x23, [x26, #JB_RECS]
    str  x22, [x26, #JB_N]
    cmp  x22, #1
    b.ls .Lpr_claim                     // one task: no queueing
    sub  x0, x22, #1
    bl   pool_grow
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
    ADR_L x9, g_pool_tail               // append the job
    ldr  x10, [x9]
    ADR_L x11, g_pool_head
    cbz  x10, 3f
    str  x26, [x10, #JB_NEXT]
    b    4f
3:  str  x26, [x11]
4:  str  x26, [x9]
    ADR_L x0, g_pool_work
    bl   pthread_cond_broadcast
    b    .Lpr_claim_locked
.Lpr_claim:
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
.Lpr_claim_locked:                      // run tasks of this job here
    ldr  x24, [x26, #JB_CLAIMED]
    cmp  x24, x22
    mov  x9, #0
    csel x24, x9, x24, hs               // (x24 = 0: not spun yet)
    b.hs .Lpr_wait
    mov  x0, x26
    bl   job_claim
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_unlock
    mov  x9, #WK_SIZE
    madd x0, x24, x9, x23
    bl   wk_inline
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
    mov  x0, x26
    bl   job_finish
    b    .Lpr_claim_locked
.Lpr_wait:                              // the rest runs on pool threads
    ldr  x9, [x26, #JB_DONE]
    cmp  x9, x22
    b.hs 5f
    cbnz x24, 52f                       // spun already: sleep
    ADR_L x0, g_pool_lock               // poll for a while first (a
    bl   pthread_mutex_unlock           // futex wake-up costs more than
    bl   now_us                         // the tail of a short phase)
    mov  x24, x0
51: add  x9, x26, #JB_DONE
    ldar x9, [x9]
    cmp  x9, x22
    b.hs 53f
    bl   sched_yield
    bl   now_us
    sub  x0, x0, x24
    LDR_G x9, g_pool_spin
    cmp  x0, x9
    b.lo 51b
53: ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
    mov  x24, #1
    b    .Lpr_wait
52: ADR_L x0, g_pool_done
    ADR_L x1, g_pool_lock
    bl   pthread_cond_wait
    b    .Lpr_wait
5:  ADR_L x0, g_pool_lock
    bl   pthread_mutex_unlock
    cbz  x27, 51f
    bl   now_us                         // PQ_TRACE_PAR: "par <fn> <n> <us>
    sub  x4, x0, x27                    // <longest task> <sum of tasks>"
    mov  x5, #0
    mov  x6, #0
    mov  x9, #0
52: cmp  x9, x22
    b.hs 53f
    mov  x10, #WK_SIZE
    madd x10, x9, x10, x23
    ldr  x10, [x10, #WK_US]
    cmp  x10, x5
    csel x5, x10, x5, hi
    add  x6, x6, x10
    add  x9, x9, #1
    b    52b
53: GOT_LOAD x0, stderr
    ADR_L x1, s_trace
    mov  x2, x19
    mov  x3, x22
    bl   fprintf
51: mov  x24, #0                        // adopt the arenas
6:  cmp  x24, x22
    b.hs 7f
    mov  x9, #WK_SIZE
    madd x25, x24, x9, x23
    TLS_ADDR x0, g_arena
    add  x1, x25, #WK_ARENA
    bl   arena_adopt
    add  x24, x24, #1
    b    6b
7:  mov  x24, #0                        // first error, in task order
8:  cmp  x24, x22
    b.hs 9f
    mov  x9, #WK_SIZE
    madd x25, x24, x9, x23
    ldr  w9, [x25, #WK_ERR]
    cbnz w9, 10f
    add  x24, x24, #1
    b    8b
9:  LEAVE 5
10: add  x0, x25, #WK_MSG
    bl   strlen
    mov  x2, x0
    add  x1, x25, #WK_MSG
    ldr  w0, [x25, #WK_ERR]
    bl   pq_raise_n
ENDF par_run

// job_claim(x0 job) — takes the next task (JB_CLAIMED++); a job with every
// task handed out leaves the queue. Pool lock held.   (leaf)
LFUNC job_claim
    ldr  x9, [x0, #JB_CLAIMED]
    add  x9, x9, #1
    str  x9, [x0, #JB_CLAIMED]
    ldr  x10, [x0, #JB_N]
    cmp  x9, x10
    b.lo 3f
    ADR_L x11, g_pool_head              // unlink it (it is queued unless
    mov  x12, #0                        // it has a single task)
1:  ldr  x13, [x11]
    cbz  x13, 3f
    cmp  x13, x0
    b.eq 2f
    add  x11, x13, #JB_NEXT
    mov  x12, x13
    b    1b
2:  ldr  x14, [x0, #JB_NEXT]
    str  x14, [x11]
    str  xzr, [x0, #JB_NEXT]
    cbnz x14, 3f
    ADR_L x11, g_pool_tail              // it was the last one
    str  x12, [x11]
3:  ret
ENDF job_claim

// job_finish(x0 job) — JB_DONE++, wakes the waiting callers when it was the
// job's last task. Pool lock held.
LFUNC job_finish
    ldr  x9, [x0, #JB_DONE]
    add  x9, x9, #1
    str  x9, [x0, #JB_DONE]
    ldr  x10, [x0, #JB_N]
    cmp  x9, x10
    b.lo 1f
    ADR_L x0, g_pool_done
    b    pthread_cond_broadcast         // tail call
1:  ret
ENDF job_finish

// pool_grow(x0 wanted) — starts pool threads until min(wanted, POOL_MAX)
// exist (a thread that cannot be created is simply missing: callers run
// the tasks themselves)
//   x19 wanted; stack: pthread_t
LFUNC pool_grow
    ENTER 1
    sub  sp, sp, #16
    cmp  x0, #POOL_MAX
    mov  x9, #POOL_MAX
    csel x19, x0, x9, lo
    ADR_L x9, g_pool_threads            // racy read: only a hint
    ldr  x9, [x9]
    cmp  x9, x19
    b.hs 9f
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
1:  ADR_L x9, g_pool_threads
    ldr  x10, [x9]
    cmp  x10, x19
    b.hs 8f
    mov  x0, sp
    mov  x1, #0
    ADR_L x2, pool_main
    mov  x3, #0
    bl   pthread_create
    cbnz w0, 8f
    ldr  x0, [sp]
    bl   pthread_detach
    ADR_L x9, g_pool_threads
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    b    1b
8:  ADR_L x0, g_pool_lock
    bl   pthread_mutex_unlock
9:  add  sp, sp, #16
    LEAVE 1
ENDF pool_grow

// =============================================================================
// thread_boost() — asks the scheduler to treat the calling thread as one
// that needs a full-performance CPU (sched_setattr: utilization clamp min =
// max = 1024; errors are ignored). Query threads and pool threads sleep
// between short bursts of work, so their tracked utilization stays low and
// energy-aware scheduling packs several of them onto one CPU (or onto slow
// cores) for the first queries: parallel phases then take up to twice as
// long until the history catches up. The clamp makes placement right from
// the first burst.
// =============================================================================
#define SYS_SCHED_SETATTR       274
#define SCHED_FLAG_KEEP_ALL     0x18    // keep policy and parameters
#define SCHED_FLAG_UTIL_MIN     0x20
#define SCHED_FLAG_UTIL_MAX     0x40
FUNC thread_boost
    ENTER 0
    sub  sp, sp, #64                    // struct sched_attr (56 bytes)
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    stp  xzr, xzr, [sp, #32]
    stp  xzr, xzr, [sp, #48]
    mov  w9, #56
    str  w9, [sp]                       // size
    mov  x9, #(SCHED_FLAG_KEEP_ALL | SCHED_FLAG_UTIL_MIN | SCHED_FLAG_UTIL_MAX)
    str  x9, [sp, #8]                   // sched_flags
    mov  w9, #1024
    str  w9, [sp, #48]                  // sched_util_min
    str  w9, [sp, #52]                  // sched_util_max
    mov  x0, #SYS_SCHED_SETATTR
    mov  x1, #0                         // this thread
    mov  x2, sp
    mov  x3, #0
    bl   syscall
    add  sp, sp, #64
    LEAVE 0
ENDF thread_boost

// =============================================================================
// pool_wake() — called when a request starts: idle pool threads wake up and
// poll the queue (g_pool_spin) instead of sleeping, so the request's first
// parallel phase does not pay for their wake-up (cheap when there is no
// pool yet)
// =============================================================================
FUNC pool_wake
    ADR_L x9, g_pool_threads
    ldr  x9, [x9]
    cbnz x9, 1f
    ret
1:  stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
    ADR_L x0, g_pool_work
    bl   pthread_cond_broadcast
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_unlock
    ldp  x29, x30, [sp], #16
    ret
ENDF pool_wake

// =============================================================================
// pool_main(x0 unused) — pool thread: forever takes a task of the first
// queued job and runs it (wk_run)
//   x19 job, x20 task index
// =============================================================================
LFUNC pool_main
    ENTER 2
    bl   thread_boost
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
1:  ADR_L x9, g_pool_head
    ldr  x19, [x9]
    cbnz x19, 2f
    ADR_L x0, g_pool_lock               // idle: poll the queue for a while
    bl   pthread_mutex_unlock           // before sleeping (queries run
    bl   now_us                         // several parallel phases in a row)
    mov  x20, x0
11: ADR_L x9, g_pool_head
    ldar x10, [x9]
    cbnz x10, 12f
    bl   sched_yield
    bl   now_us
    sub  x0, x0, x20
    LDR_G x9, g_pool_spin
    cmp  x0, x9
    b.lo 11b
12: ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
    ADR_L x9, g_pool_head
    ldr  x19, [x9]
    cbnz x19, 2f
    ADR_L x0, g_pool_work
    ADR_L x1, g_pool_lock
    bl   pthread_cond_wait
    b    1b
2:  ldr  x20, [x19, #JB_CLAIMED]
    mov  x0, x19
    bl   job_claim
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_unlock
    ldr  x9, [x19, #JB_RECS]
    mov  x10, #WK_SIZE
    madd x0, x20, x10, x9
    bl   wk_run
    ADR_L x0, g_pool_lock
    bl   pthread_mutex_lock
    mov  x0, x19
    bl   job_finish
    b    1b
ENDF pool_main

// =============================================================================
// wk_run(x0 worker record) — runs the task on a pool thread with a copy of
// the caller's request state and its own error handler; the arena it
// allocated from is handed to the record (adopted by the caller)
//   x19 record
// =============================================================================
LFUNC wk_run
    ENTER 2
    mov  x19, x0
    ldr  x9, [x19, #WK_DEADLINE]
    TLS_ADDR x10, g_deadline
    str  x9, [x10]
    ldr  x9, [x19, #WK_CANCEL]
    TLS_ADDR x10, g_cancel_flag
    str  x9, [x10]
    ldr  x9, [x19, #WK_LIMIT]
    TLS_ADDR x10, g_arena_limit
    str  x9, [x10]
    ldr  x9, [x19, #WK_THREADS]
    TLS_ADDR x10, g_x_threads
    str  x9, [x10]
    ldr  w9, [x19, #WK_MODE]
    TLS_ADDR x10, g_x_mode
    str  w9, [x10]
    ldr  x9, [x19, #WK_CAT]
    TLS_ADDR x10, g_cat
    str  x9, [x10]
    bl   trace_start
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    ldr  x0, [x19, #WK_ARG]
    ldr  x9, [x19, #WK_FN]
    blr  x9
    mov  x0, x19
    bl   trace_end
    b    2f
1:  TLS_ADDR x9, g_err_code             // the task raised: record the error
    ldr  w9, [x9]
    str  w9, [x19, #WK_ERR]
    add  x0, x19, #WK_MSG
    TLS_ADDR x1, g_err_msg
    mov  x2, #(WK_MSGMAX - 1)
    bl   strncpy
    strb wzr, [x19, #(WK_MSG + WK_MSGMAX - 1)]
2:  TLS_ADDR x9, g_arena                // hand the arena to the caller
    ldp  x10, x11, [x9]
    stp  x10, x11, [x19, #WK_ARENA]
    ldp  x10, x11, [x9, #16]
    stp  x10, x11, [x19, #(WK_ARENA + 16)]
    stp  xzr, xzr, [x9]
    stp  xzr, xzr, [x9, #16]
    LEAVE 2
ENDF wk_run

// trace_start(x19 = worker record of the caller): with PQ_TRACE_PAR, the
// task's start time in WK_US (x19 is the callers' record register)
LFUNC trace_start
    LDR_G x9, g_par_trace
    cbz  x9, 1f
    stp  x29, x30, [sp, #-16]!
    bl   now_us
    str  x0, [x19, #WK_US]
    ldp  x29, x30, [sp], #16
1:  ret
ENDF trace_start

// trace_end(x0 worker record): WK_US = run time of the task
LFUNC trace_end
    LDR_G x9, g_par_trace
    cbz  x9, 1f
    stp  x29, x30, [sp, #-16]!
    str  x0, [sp, #-16]!
    bl   now_us
    ldr  x1, [sp], #16
    ldr  x2, [x1, #WK_US]
    sub  x0, x0, x2
    str  x0, [x1, #WK_US]
    ldp  x29, x30, [sp], #16
1:  ret
ENDF trace_end

// =============================================================================
// wk_inline(x0 worker record) — runs a task the caller of par_run claimed
// on the calling thread under a nested error handler: the request's jump
// buffer is saved and restored, an error is recorded like a worker's. The
// task allocates from the caller's arena directly (WK_ARENA stays empty).
//   x19 record; stack: saved g_jmpbuf (512 bytes)
// =============================================================================
LFUNC wk_inline
    ENTER 1
    sub  sp, sp, #512
    mov  x19, x0
    mov  x0, sp
    TLS_ADDR x1, g_jmpbuf
    mov  x2, #512
    bl   memcpy
    bl   trace_start
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    ldr  x0, [x19, #WK_ARG]
    ldr  x9, [x19, #WK_FN]
    blr  x9
    mov  x0, x19
    bl   trace_end
    b    2f
1:  TLS_ADDR x9, g_err_code
    ldr  w9, [x9]
    str  w9, [x19, #WK_ERR]
    add  x0, x19, #WK_MSG
    TLS_ADDR x1, g_err_msg
    mov  x2, #(WK_MSGMAX - 1)
    bl   strncpy
    strb wzr, [x19, #(WK_MSG + WK_MSGMAX - 1)]
2:  TLS_ADDR x0, g_jmpbuf
    mov  x1, sp
    mov  x2, #512
    bl   memcpy
    add  sp, sp, #512
    LEAVE 1
ENDF wk_inline

// =============================================================================
// expr_par_safe(x0 Node* or 0) -> w0 1/0
//   x19 node, x20 index, x21 count
// =============================================================================
FUNC expr_par_safe
    cbnz x0, 1f
    mov  w0, #1
    ret
1:  ENTER 3
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_SUBQ
    b.eq 4f
    cmp  w9, #NK_EXISTS
    b.eq 4f
    cmp  w9, #NK_INSUB
    b.eq 4f
    mov  x0, x19
    bl   expr_nchildren
    mov  x21, x0
    mov  x20, #0
2:  cmp  x20, x21
    b.hs 3f
    mov  x0, x19
    mov  x1, x20
    bl   expr_child_slot
    ldr  x0, [x0]
    bl   expr_par_safe
    cbz  w0, 5f
    add  x20, x20, #1
    b    2b
3:  mov  w0, #1
    LEAVE 3
4:  mov  w0, #0
5:  LEAVE 3
ENDF expr_par_safe

    NOTE_GNU_STACK
