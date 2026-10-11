// =============================================================================
// parallel.S — intra-query parallelism (Phase 5, option "threads").
//
//   par_run(x0 fn, x1 args, x2 arg stride, x3 n)
//       runs fn(args + i * stride) for i < n, each on its own thread, and
//       waits for all of them. Raises the first error (lowest i) a task
//       raised, after every task has finished.
//   expr_par_safe(x0 Node* or 0) -> w0 1 if the expression may be evaluated
//       on a worker thread (no subquery: their results are cached in shared
//       SubPlans on first use).
//
// A worker thread runs with a copy of the caller's request state (deadline,
// cancellation flag, memory budget, execution settings, catalog version) and
// its own error handler (setjmp) and request arena. When it finishes, its
// arena chunks are moved into the caller's arena (arena_adopt), so memory a
// task allocated (tuple sets, strings) lives until the request ends exactly
// like memory of the calling thread. Workers never touch the caller's
// arena, so tasks need no locking as long as they write only their own
// argument records.
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
#define WK_JOIN     52              // u32
#define WK_OPT      56              // u32
#define WK_USEIDX   60              // u32
#define WK_CAT      64
#define WK_TID      72              // pthread_t
#define WK_STARTED  80              // u64 1 = thread created
#define WK_ERR      88              // u32 error code (0 = none)
#define WK_ARENA    96              // Arena handed back (AR_SIZE)
#define WK_MSG      128             // error message (WK_MSGMAX bytes, NUL)
#define WK_MSGMAX   256
#define WK_SIZE     (128 + WK_MSGMAX)

    .text

// =============================================================================
// par_run(x0 fn, x1 args, x2 stride, x3 n)
//   x19 fn, x20 args, x21 stride, x22 n, x23 workers, x24 i, x25 record
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
1:  cmp  x24, x22                       // start every task
    b.hs 3f
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
    TLS_ADDR x9, g_x_join
    ldr  w9, [x9]
    str  w9, [x25, #WK_JOIN]
    TLS_ADDR x9, g_x_optimize
    ldr  w9, [x9]
    str  w9, [x25, #WK_OPT]
    TLS_ADDR x9, g_use_indexes
    ldr  w9, [x9]
    str  w9, [x25, #WK_USEIDX]
    TLS_LDR x9, g_cat
    str  x9, [x25, #WK_CAT]
    add  x0, x25, #WK_TID
    mov  x1, #0
    ADR_L x2, wk_main
    mov  x3, x25
    bl   pthread_create
    cbnz w0, 2f
    mov  x9, #1
    str  x9, [x25, #WK_STARTED]
    add  x24, x24, #1
    b    1b
2:  mov  x0, x25                        // no thread: run it here
    bl   wk_inline
    add  x24, x24, #1
    b    1b
3:  mov  x24, #0                        // wait, adopt the arenas
4:  cmp  x24, x22
    b.hs 6f
    mov  x9, #WK_SIZE
    madd x25, x24, x9, x23
    ldr  x9, [x25, #WK_STARTED]
    cbz  x9, 5f
    ldr  x0, [x25, #WK_TID]
    mov  x1, #0
    bl   pthread_join
5:  TLS_ADDR x0, g_arena
    add  x1, x25, #WK_ARENA
    bl   arena_adopt
    add  x24, x24, #1
    b    4b
6:  mov  x24, #0                        // first error, in task order
7:  cmp  x24, x22
    b.hs 8f
    mov  x9, #WK_SIZE
    madd x25, x24, x9, x23
    ldr  w9, [x25, #WK_ERR]
    cbnz w9, 9f
    add  x24, x24, #1
    b    7b
8:  LEAVE 5
9:  add  x0, x25, #WK_MSG
    bl   strlen
    mov  x2, x0
    add  x1, x25, #WK_MSG
    ldr  w0, [x25, #WK_ERR]
    bl   pq_raise_n
ENDF par_run

// =============================================================================
// wk_main(x0 worker record) -> x0 0   thread entry
//   x19 record
// =============================================================================
LFUNC wk_main
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
    ldr  w9, [x19, #WK_JOIN]
    TLS_ADDR x10, g_x_join
    str  w9, [x10]
    ldr  w9, [x19, #WK_OPT]
    TLS_ADDR x10, g_x_optimize
    str  w9, [x10]
    ldr  w9, [x19, #WK_USEIDX]
    TLS_ADDR x10, g_use_indexes
    str  w9, [x10]
    ldr  x9, [x19, #WK_CAT]
    TLS_ADDR x10, g_cat
    str  x9, [x10]
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    ldr  x0, [x19, #WK_ARG]
    ldr  x9, [x19, #WK_FN]
    blr  x9
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
    mov  x0, #0
    LEAVE 2
ENDF wk_main

// =============================================================================
// wk_inline(x0 worker record) — runs the task on the calling thread (when no
// thread could be created) under a nested error handler: the request's jump
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
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    ldr  x0, [x19, #WK_ARG]
    ldr  x9, [x19, #WK_FN]
    blr  x9
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
