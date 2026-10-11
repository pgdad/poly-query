// =============================================================================
// functions.S — scalar functions (functions.md §1), CASE, LIKE, BETWEEN and
// IN lists (semantics.md §11-13): binding (typing) and evaluation.
//
// Binding entry points (called from binder.S bind_expr / bind_func), all
//   (x0 BindCtx*, x1 Node*) -> x0 bound Node*:
//     bind_scalar_func  NK_FUNC that is not an aggregate
//     bind_case         NK_CASE
//     bind_between      NK_BETWEEN (rewritten to AND / NOT comparisons)
//     bind_inlist       NK_IN
//     bind_like         NK_LIKE
// Evaluation entry points (called from eval.S eval), all
//   (x0 Node*, x1 EvalCtx*) -> x0 payload, x1 isnull:
//     ev_func, ev_case, ev_inlist, ev_like
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define FN_PQ_SLEEP 1

    .text

// =============================================================================
// bind_scalar_func(x0 ctx, x1 Node*) -> x0 Node*
//   x19 ctx, x20 node
// =============================================================================
FUNC bind_scalar_func
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x20, #N_NAME]
    adr  x1, s_pq_sleep
    bl   str_ieq_c
    cbz  w0, .Lbsf_unknown

    // ---- PQ_SLEEP(ms INT64) -> INT64 (only with test functions enabled) ----
    adrp x9, g_test_functions
    ldr  w9, [x9, :lo12:g_test_functions]
    cbz  w9, .Lbsf_unknown
    ldr  w9, [x20, #N_FLAGS]
    tst  w9, #(NF_STAR | NF_DISTINCT)
    b.ne .Lbsf_badargs
    ldr  x9, [x20, #N_VAL]
    cmp  x9, #1
    b.ne .Lbsf_arity
    mov  x0, x19
    ldr  x9, [x20, #N_C]
    ldr  x1, [x9]
    bl   bind_expr
    ldr  x9, [x20, #N_C]
    str  x0, [x9]
    ldrb w9, [x0, #N_TYPE]
    cmp  w9, #T_NULL
    ccmp w9, #T_INT, #4, ne
    b.ne .Lbsf_argtype
    mov  w9, #FN_PQ_SLEEP
    str  w9, [x20, #N_OP]
    mov  w9, #T_INT
    str  w9, [x20, #N_TYPE]
    ldr  w9, [x20, #N_FLAGS]            // side effect: never constant
    bic  w9, w9, #NF_CONST
    str  w9, [x20, #N_FLAGS]
    mov  x0, x20
    LEAVE 2
.Lbsf_unknown:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "unknown function ", x9
.Lbsf_badargs:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "invalid arguments for ", x9
.Lbsf_arity:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "wrong number of arguments for ", x9
.Lbsf_argtype:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_TYPE, "invalid argument type for ", x9
s_pq_sleep: .asciz "PQ_SLEEP"
    .p2align 2
ENDF bind_scalar_func

FUNC bind_case
    RAISE ERR_UNSUPPORTED, "CASE is not supported"
ENDF bind_case

FUNC bind_between
    RAISE ERR_UNSUPPORTED, "BETWEEN is not supported"
ENDF bind_between

FUNC bind_inlist
    RAISE ERR_UNSUPPORTED, "IN is not supported"
ENDF bind_inlist

FUNC bind_like
    RAISE ERR_UNSUPPORTED, "LIKE is not supported"
ENDF bind_like

// =============================================================================
// ev_func: scalar functions.
// PQ_SLEEP(ms) — sleeps ms milliseconds in slices of at most 10 ms, calling
// check_deadline between slices, and returns ms. NULL => NULL (no sleep).
//   x19 node, x20 ms, x21 target time (µs)
// =============================================================================
FUNC ev_func
    ENTER 2
    sub  sp, sp, #16                    // struct timespec
    mov  x19, x0
    ldr  w9, [x19, #N_OP]
    cmp  w9, #FN_PQ_SLEEP
    b.ne .Lfn_bad
    ldr  x9, [x19, #N_C]
    ldr  x0, [x9]
    bl   eval
    cbnz x1, .Lfn_null
    mov  x20, x0
    cmp  x20, #0
    b.le .Lfn_done
    ldr  x9, =1000000000000             // clamp to ~31 years (no overflow)
    cmp  x20, x9
    csel x21, x20, x9, lt
    mov  x9, #1000
    mul  x21, x21, x9                   // duration in µs
    bl   now_us
    add  x21, x21, x0                   // target
1:  bl   check_deadline                 // raises TIMEOUT
    bl   now_us
    cmp  x0, x21
    b.hs .Lfn_done
    sub  x9, x21, x0                    // remaining µs, at most 10 000 per slice
    mov  x10, #10000
    cmp  x9, x10
    csel x9, x9, x10, lo
    mov  x10, #1000
    mul  x9, x9, x10                    // ns
    stp  xzr, x9, [sp]                  // tv_sec = 0, tv_nsec
    mov  x0, sp
    mov  x1, #0
    bl   nanosleep
    b    1b
.Lfn_done:
    mov  x0, x20
    mov  x1, #0
    add  sp, sp, #16
    LEAVE 2
.Lfn_null:
    mov  x0, #0
    mov  x1, #1
    add  sp, sp, #16
    LEAVE 2
.Lfn_bad:
    RAISE ERR_INTERNAL, "eval: unknown function"
ENDF ev_func

FUNC ev_case
    RAISE ERR_INTERNAL, "eval: CASE"
ENDF ev_case

FUNC ev_inlist
    RAISE ERR_INTERNAL, "eval: IN"
ENDF ev_inlist

FUNC ev_like
    RAISE ERR_INTERNAL, "eval: LIKE"
ENDF ev_like

    .ltorg
    NOTE_GNU_STACK
