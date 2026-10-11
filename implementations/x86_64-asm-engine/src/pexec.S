/*
 * pexec.S - batch-at-a-time, parallel operator drivers (Phase 5).
 *
 * Used for every query block unless the options ask for the row baseline
 * (mode "row" with one thread, which runs the original tuple-at-a-time
 * operators of exec.S).  Each operator splits its input into contiguous
 * parts (par.S; one part per thread) and every part runs batches of up to
 * VB tuples through a batch kernel.  The kernels (k_*) dispatch on the
 * execution mode: vectorized kernels (vec.S) evaluate whole column vectors,
 * row kernels evaluate tuple by tuple.  Part results are combined in part
 * order, so the output equals the serial output.
 *
 *   pexec_threads(xs rdi) -> rax parts allowed for this block (sets g_par_threads)
 *   pexec_scan(xs rdi, fp rsi) -> rax TupleSet*   full scan + pushed filter
 *   pexec_filter(xs rdi)          WHERE over XS_TS, in place
 *   pexec_project(xs rdi)         output rows of a non-aggregated block
 *   pexec_aggregate(xs rdi)       grouping and aggregation
 *
 * Aggregation without GROUP BY: every part aggregates its range into its
 * own states, which are merged in part order (exact for INT64 / DECIMAL).
 * With GROUP BY the aggregation is hash-partitioned: phase 1 computes the
 * key cells and their hash for every tuple in parallel; in phase 2 part p
 * owns the groups whose hash falls into partition p and aggregates their
 * tuples in input order, so each group sees exactly the serial sequence of
 * updates (identical results, also for FLOAT64 sums and DISTINCT
 * aggregates).  Groups are finally emitted in order of their first tuple.
 */
#include "pq.inc"
#include "sql.inc"
#include "exec.inc"

    .section .note.GNU-stack, "", @progbits

/* operator task shared by the parts */
#define PT_XS    0
#define PT_FP    8
#define PT_N     16
#define PT_A     24
#define PT_B     32
#define PT_C     40
#define PT_D     48
#define PT_OUT   56                     /* u64 per part */
#define PT_CNT   (56 + 8 * MAX_THREADS)  /* u64 per part */
#define PT_SIZE  (56 + 16 * MAX_THREADS)

#define TOPN_MAX 65536                  /* larger LIMITs sort everything */

    .data
    .p2align 3
    .globl g_par_threads
g_par_threads: .quad 1          /* parts allowed for the current operator */

    .text

/* wctx_init(dst rdi, xs rsi): a worker's private copy of the block's EvalCtx */
FUNC wctx_init
    lea XS_CTX(%rsi), %rsi
    mov $EC_SIZE/8, %ecx
    rep movsq
    ret
ENDF wctx_init

/* ================================================================ checks */

/* expr_has_subq(node rdi) -> eax 1 if the expression contains a subquery */
FUNC expr_has_subq
    ENTER 16
    xor %eax, %eax
    test %rdi, %rdi
    jz 9f
    mov %rdi, %rbx
    mov N_KIND(%rbx), %ecx
    mov $1, %eax
    cmp $EK_SUBQ, %ecx
    je 9f
    cmp $EK_INSUBQ, %ecx
    je 9f
    cmp $EK_EXISTS, %ecx
    je 9f
    mov %rbx, %rdi
    call expr_nchild
    mov %rax, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 8f
    mov %rbx, %rdi
    mov %r13, %rsi
    call expr_child_ptr
    mov (%rax), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    inc %r13
    jmp 1b
8:  xor %eax, %eax
9:  LEAVE
ENDF expr_has_subq

/* fp_has_subq(fp rdi) -> eax */
FUNC fp_has_subq
    ENTER 0
    mov %rdi, %rbx
    mov FP_FILTER(%rbx), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    cmpq $FK_JOIN, FP_KIND(%rbx)
    jne 9f
    mov FP_ON(%rbx), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    mov FP_LEFT(%rbx), %rdi
    call fp_has_subq
    test %eax, %eax
    jnz 9f
    mov FP_RIGHT(%rbx), %rdi
    call fp_has_subq
9:  LEAVE
ENDF fp_has_subq

/* plan_has_subq(plan rdi) -> eax: any expression of the block (WHERE,
 * HAVING, outputs, sort keys, GROUP BY, aggregates, FROM tree) */
FUNC plan_has_subq
    ENTER 0
    mov %rdi, %rbx
    mov QP_WHERE(%rbx), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    mov QP_HAVING(%rbx), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    xor %r12d, %r12d
1:  cmp QP_NOUT(%rbx), %r12
    jae 2f
    imul $OC_SIZE, %r12, %rax
    add QP_OUT(%rbx), %rax
    mov OC_EXPR(%rax), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    inc %r12
    jmp 1b
2:  xor %r12d, %r12d
3:  cmp QP_NKEYS(%rbx), %r12
    jae 4f
    imul $SK_SIZE, %r12, %rax
    add QP_KEYS(%rbx), %rax
    mov SK_EXPR(%rax), %rdi
    cmpq $-1, SK_OUT(%rax)
    je 31f
    xor %edi, %edi
31: call expr_has_subq
    test %eax, %eax
    jnz 9f
    inc %r12
    jmp 3b
4:  xor %r12d, %r12d
5:  cmp QP_NGROUP(%rbx), %r12
    jae 6f
    mov QP_GROUP(%rbx), %rax
    mov (%rax, %r12, 8), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    inc %r12
    jmp 5b
6:  xor %r12d, %r12d
7:  cmp QP_NAGGS(%rbx), %r12
    jae 8f
    mov QP_AGGS(%rbx), %rax
    mov (%rax, %r12, 8), %rdi
    call expr_has_subq
    test %eax, %eax
    jnz 9f
    inc %r12
    jmp 7b
8:  xor %eax, %eax
    mov QP_FROM(%rbx), %rdi
    test %rdi, %rdi
    jz 9f
    call fp_has_subq
9:  LEAVE
ENDF plan_has_subq

/* pexec_threads(xs rdi) -> rax threads usable by this block's operators,
 * also stored in g_par_threads: 1 when the block contains subqueries
 * (their results are cached in the shared AST); otherwise `threads`, after
 * decoding the referenced lazily decoded columns */
FUNC pexec_threads
    ENTER 0
    mov %rdi, %rbx
    mov $1, %r12d
    cmpq $1, g_opt_threads(%rip)
    jbe 9f
    mov XS_PAR(%rbx), %rax
    test %rax, %rax
    jnz 1f
    mov XS_PLAN(%rbx), %rdi
    call plan_has_subq
    inc %eax                        /* 1 = parallel ok, 2 = serial only */
    mov %rax, XS_PAR(%rbx)
    cmp $1, %eax
    jne 1f
    mov XS_PLAN(%rbx), %rdi
    mov XS_TABLES(%rbx), %rsi
    call par_prepare
    mov XS_PAR(%rbx), %rax
1:  cmp $1, %rax
    jne 9f
    mov g_opt_threads(%rip), %r12
9:  mov %r12, g_par_threads(%rip)
    mov %r12, %rax
    LEAVE
ENDF pexec_threads

/* pexec_enabled(xs rdi) -> eax 1 when this module executes the block (every
 * mode except the row baseline with one thread) */
FUNC pexec_enabled
    mov $1, %eax
    cmpq $MODE_ROW, g_opt_mode(%rip)
    jne 1f
    cmpq $1, g_opt_threads(%rip)
    ja 1f
    xor %eax, %eax
1:  ret
ENDF pexec_enabled

/* ================================================================ tuple sets */

/* ts_append(ts rdi, tuples rsi, k rdx): appends k tuples */
FUNC ts_append
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov TS_N(%rbx), %r14
    add %r13, %r14                  /* needed */
    mov TS_CAP(%rbx), %r15
    cmp %r15, %r14
    jbe 2f
1:  add %r15, %r15
    cmp %r15, %r14
    ja 1b
    mov %r15, %rdi
    imul TS_W(%rbx), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, %r14
    mov %rax, %rdi
    mov TS_DATA(%rbx), %rsi
    mov TS_N(%rbx), %rdx
    imul TS_W(%rbx), %rdx
    shl $3, %rdx
    call memcpy
    mov %r14, TS_DATA(%rbx)
    mov %r15, TS_CAP(%rbx)
2:  mov TS_N(%rbx), %rdi
    imul TS_W(%rbx), %rdi
    shl $3, %rdi
    add TS_DATA(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    imul TS_W(%rbx), %rdx
    shl $3, %rdx
    call memcpy
    add %r13, TS_N(%rbx)
    LEAVE
ENDF ts_append

/* ================================================================ row kernels
 * Batch kernels: ctx rdi (worker EvalCtx), tuples (W words each), n, W.
 * In vectorized mode they forward to the vector kernels of vec.S. */

/* k_filter(ctx rdi, pred rsi, tuples rdx, n rcx, W r8) -> rax kept: keeps
 * the tuples for which pred is TRUE, compacted at the front */
FUNC k_filter
    test %rsi, %rsi
    jnz 0f
    mov %rcx, %rax                  /* no predicate */
    ret
0:  cmpq $MODE_ROW, g_opt_mode(%rip)
    jne vk_filter
    jmp rk_filter
ENDF k_filter

FUNC rk_filter
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    lea (,%r8,8), %r15              /* tuple bytes */
    movq $0, 0(%rsp)                /* read */
    movq $0, 8(%rsp)                /* write */
1:  mov 0(%rsp), %rax
    cmp %r14, %rax
    jae 9f
    imul %r15, %rax
    add %r13, %rax
    mov %rax, 16(%rsp)
    mov %rax, EC_TUPLE(%rbx)
    mov %r12, %rdi
    mov %rbx, %rsi
    call eval
    test %edx, %edx
    jnz 3f
    test $1, %eax
    jz 3f
    mov 8(%rsp), %rdi
    cmp 0(%rsp), %rdi
    je 2f
    imul %r15, %rdi
    add %r13, %rdi
    mov 16(%rsp), %rsi
    mov %r15, %rcx
    shr $3, %rcx
    rep movsq
2:  incq 8(%rsp)
3:  incq 0(%rsp)
    jmp 1b
9:  mov 8(%rsp), %rax
    LEAVE
ENDF rk_filter

/* k_project(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, rows Vec* r9) */
FUNC k_project
    cmpq $MODE_ROW, g_opt_mode(%rip)
    jne vk_project
    jmp rk_project
ENDF k_project

FUNC rk_project
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    lea (,%r8,8), %r15
    mov %r9, 0(%rsp)
1:  test %r14, %r14
    jz 9f
    mov %r13, EC_TUPLE(%rbx)
    mov %r12, %rdi
    mov %rbx, %rsi
    call build_row
    mov 0(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    add %r15, %r13
    dec %r14
    jmp 1b
9:  LEAVE
ENDF rk_project

/* k_agg_single(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, states r9) */
FUNC k_agg_single
    cmpq $MODE_ROW, g_opt_mode(%rip)
    jne vk_agg_single
    jmp rk_agg_single
ENDF k_agg_single

FUNC rk_agg_single
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    lea (,%r8,8), %r15
    mov %r9, 0(%rsp)
1:  test %r14, %r14
    jz 9f
    mov %r13, EC_TUPLE(%rbx)
    mov %r12, %rdi
    mov %rbx, %rsi
    mov 0(%rsp), %rdx
    call agg_update
    add %r15, %r13
    dec %r14
    jmp 1b
9:  LEAVE
ENDF rk_agg_single

/* k_agg_groups(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, states*[n] r9):
 * feeds tuple i to the group states states[i] */
FUNC k_agg_groups
    cmpq $MODE_ROW, g_opt_mode(%rip)
    jne vk_agg_groups
    jmp rk_agg_groups
ENDF k_agg_groups

FUNC rk_agg_groups
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    lea (,%r8,8), %r15
    mov %r9, 0(%rsp)
1:  test %r14, %r14
    jz 9f
    mov %r13, EC_TUPLE(%rbx)
    mov %r12, %rdi
    mov %rbx, %rsi
    mov 0(%rsp), %rax
    mov (%rax), %rdx
    addq $8, 0(%rsp)
    call agg_update
    add %r15, %r13
    dec %r14
    jmp 1b
9:  LEAVE
ENDF rk_agg_groups

/* k_group_keys(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, keys r9):
 * the GROUP BY key cells of each tuple, ngroup cells per tuple */
FUNC k_group_keys
    cmpq $MODE_ROW, g_opt_mode(%rip)
    jne vk_group_keys
    jmp rk_group_keys
ENDF k_group_keys

FUNC rk_group_keys
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    lea (,%r8,8), %r15
    mov %r9, 0(%rsp)                /* next key cell */
1:  test %r14, %r14
    jz 9f
    mov %r13, EC_TUPLE(%rbx)
    movq $0, 8(%rsp)
2:  mov 8(%rsp), %rcx
    cmp QP_NGROUP(%r12), %rcx
    jae 3f
    mov QP_GROUP(%r12), %rax
    mov (%rax, %rcx, 8), %rdi
    mov %rbx, %rsi
    call eval
    mov 0(%rsp), %rcx
    mov %rax, VAL_P(%rcx)
    mov %rdx, VAL_NULL(%rcx)
    addq $VAL_SIZE, 0(%rsp)
    incq 8(%rsp)
    jmp 2b
3:  add %r15, %r13
    dec %r14
    jmp 1b
9:  LEAVE
ENDF rk_group_keys

/* ================================================================ scan */

/* next_run(fp rdi, table rsi, pos rdx, hi rcx) -> rax start, rdx end: the
 * next range of rows at or after pos (below hi) that is not in a skipped
 * row group; start >= end when there is none */
FUNC next_run
    mov FP_RGSKIP(%rdi), %r8
    test %r8, %r8
    jnz 1f
    mov %rdx, %rax
    mov %rcx, %rdx
    ret
1:  xor %r9d, %r9d                  /* row group */
2:  cmp TB_NRG(%rsi), %r9
    jae 8f
    imul $RG_SIZE, %r9, %r10
    add TB_RGS(%rsi), %r10
    mov RG_START(%r10), %rax
    mov %rax, %r11
    add RG_N(%r10), %r11            /* group end */
    inc %r9
    cmp %rdx, %r11
    jbe 2b
    cmpb $0, -1(%r8, %r9)
    jne 2b
    cmp %rdx, %rax
    cmovb %rdx, %rax                /* start = max(group start, pos) */
    cmp %rcx, %r11
    cmova %rcx, %r11                /* end = min(group end, hi) */
    mov %r11, %rdx
    ret
8:  mov %rcx, %rax
    mov %rcx, %rdx
    ret
ENDF next_run

/* scan_part(task rdi, part rsi, lo rdx, hi rcx) */
FUNC scan_part
    ENTER 160
    mov %rdi, %rbx                  /* task */
    mov %rsi, 64(%rsp)
    mov %rdx, 72(%rsp)              /* pos */
    mov %rcx, 80(%rsp)              /* hi */
    mov PT_FP(%rbx), %r12           /* fp */
    mov PT_XS(%rbx), %r13           /* xs */
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_TABLES(%r13), %rax
    mov FP_RV(%r12), %rcx
    mov (%rax, %rcx, 8), %rax
    mov %rax, 88(%rsp)              /* table */
    mov XS_W(%r13), %rdi
    mov $16, %esi
    call ts_new
    mov %rax, 96(%rsp)              /* out */
    mov XS_W(%r13), %rdi
    imul $VB*8, %rdi, %rdi
    call tmp_alloc
    mov %rax, 104(%rsp)             /* batch tuples */
1:  mov %r12, %rdi
    mov 88(%rsp), %rsi
    mov 72(%rsp), %rdx
    mov 80(%rsp), %rcx
    call next_run
    cmp %rdx, %rax
    jae 9f
    mov %rax, %r14                  /* run start */
    mov %rdx, 112(%rsp)             /* run end */
2:  cmp 112(%rsp), %r14
    jae 5f
    call check_deadline
    mov 112(%rsp), %r15
    sub %r14, %r15
    cmp $VB, %r15
    jbe 3f
    mov $VB, %r15d                  /* batch rows */
3:  mov 104(%rsp), %rdi             /* tuples: -1 except this variable */
    mov $0xff, %esi
    mov XS_W(%r13), %rdx
    imul %r15, %rdx
    shl $3, %rdx
    call memset
    mov 104(%rsp), %rax
    mov FP_RV(%r12), %rcx
    lea (%rax, %rcx, 8), %rax
    mov XS_W(%r13), %rcx
    shl $3, %rcx
    xor %edx, %edx
4:  lea (%r14, %rdx), %rsi
    mov %rsi, (%rax)
    add %rcx, %rax
    inc %rdx
    cmp %r15, %rdx
    jb 4b
    lea 0(%rsp), %rdi
    mov FP_FILTER(%r12), %rsi
    mov 104(%rsp), %rdx
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    call k_filter
    mov 96(%rsp), %rdi
    mov 104(%rsp), %rsi
    mov %rax, %rdx
    call ts_append
    add %r15, %r14
    jmp 2b
5:  mov 112(%rsp), %rax
    mov %rax, 72(%rsp)
    jmp 1b
9:  mov 64(%rsp), %rcx
    mov 96(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE
ENDF scan_part

/* pexec_scan(xs rdi, fp rsi) -> rax TupleSet*: full scan of a base table
 * (minus skipped row groups) filtered by the pushed-down conjuncts */
FUNC pexec_scan
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    call pexec_threads
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov %r12, PT_FP(%r13)
    mov XS_TABLES(%rbx), %rax
    mov FP_RV(%r12), %rcx
    mov (%rax, %rcx, 8), %rax
    mov TB_NROWS(%rax), %rdi
    lea scan_part(%rip), %rsi
    mov %r13, %rdx
    call par_for
    mov %rax, %r14                  /* parts */
    mov PT_OUT(%r13), %r15          /* part 0's set collects the others */
    mov $1, %ebx
1:  cmp %r14, %rbx
    jae 9f
    mov PT_OUT(%r13, %rbx, 8), %rax
    mov %r15, %rdi
    mov TS_DATA(%rax), %rsi
    mov TS_N(%rax), %rdx
    call ts_append
    inc %rbx
    jmp 1b
9:  mov %r15, %rax
    LEAVE
ENDF pexec_scan

/* ================================================================ WHERE */

/* filter_part(task rdi, part rsi, lo rdx, hi rcx): compacts the passing
 * tuples of [lo, hi) to the front of the range; PT_CNT[part] = count */
FUNC filter_part
    ENTER 112
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, %r14                  /* batch start */
    mov %rdx, 72(%rsp)              /* write position */
    mov %rcx, 80(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_W(%r13), %r12
    shl $3, %r12                    /* tuple bytes */
1:  cmp 80(%rsp), %r14
    jae 9f
    call check_deadline
    mov 80(%rsp), %r15
    sub %r14, %r15
    cmp $VB, %r15
    jbe 2f
    mov $VB, %r15d
2:  mov XS_TS(%r13), %rax
    mov %r14, %rdx
    imul %r12, %rdx
    add TS_DATA(%rax), %rdx
    mov %rdx, 88(%rsp)              /* batch */
    lea 0(%rsp), %rdi
    mov XS_PLAN(%r13), %rsi
    mov QP_WHERE(%rsi), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    call k_filter
    mov %rax, 96(%rsp)              /* kept */
    mov XS_TS(%r13), %rcx
    mov 72(%rsp), %rdi
    imul %r12, %rdi
    add TS_DATA(%rcx), %rdi
    mov 88(%rsp), %rsi
    mov %rax, %rdx
    imul %r12, %rdx
    call memmove
    mov 96(%rsp), %rax
    add %rax, 72(%rsp)
    add %r15, %r14
    jmp 1b
9:  mov 64(%rsp), %rcx
    mov 72(%rsp), %rax
    lea PT_CNT(%rbx), %rdx
    mov %rax, (%rdx, %rcx, 8)       /* end of the kept tuples */
    LEAVE
ENDF filter_part

/* pexec_filter(xs rdi) */
FUNC pexec_filter
    ENTER 16
    mov %rdi, %rbx
    call pexec_threads
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov XS_TS(%rbx), %r12
    mov TS_N(%r12), %rdi
    mov %rdi, PT_N(%r13)
    lea filter_part(%rip), %rsi
    mov %r13, %rdx
    call par_for
    mov %rax, %r14                  /* parts */
    mov PT_CNT(%r13), %r15          /* write = end of part 0 */
    mov XS_W(%rbx), %rax
    shl $3, %rax
    mov %rax, 0(%rsp)               /* tuple bytes */
    mov $1, %ebx
1:  cmp %r14, %rbx
    jae 9f
    mov PT_N(%r13), %rax            /* part start = n * p / P */
    mul %rbx
    div %r14
    lea PT_CNT(%r13), %rcx
    mov (%rcx, %rbx, 8), %rdx
    sub %rax, %rdx                  /* kept */
    mov %rdx, 8(%rsp)
    mov %rax, %rsi
    imul 0(%rsp), %rsi
    add TS_DATA(%r12), %rsi
    mov %r15, %rdi
    imul 0(%rsp), %rdi
    add TS_DATA(%r12), %rdi
    imul 0(%rsp), %rdx
    call memmove
    add 8(%rsp), %r15
    inc %rbx
    jmp 1b
9:  mov %r15, TS_N(%r12)
    LEAVE
ENDF pexec_filter

/* ================================================================ projection */

/* heap_cmp(heap rdi, i rsi, j rdx, plan rcx) -> eax row_cmp(heap[i], heap[j]) */
FUNC heap_cmp
    lea (%rdi, %rsi, 8), %rsi
    lea (%rdi, %rdx, 8), %rdx
    xchg %rsi, %rdi
    xchg %rdx, %rsi
    mov %rcx, %rdx
    jmp row_cmp
ENDF heap_cmp

/* topn_offer(heap rdi, size* rsi, K rdx, row rcx, plan r8): keeps the K
 * smallest rows (ORDER BY order) in a binary max-heap */
FUNC topn_offer
    ENTER 32
    mov %rdi, %rbx                  /* heap (one spare slot at [K]) */
    mov %rsi, %r12
    mov %rdx, %r13                  /* K */
    mov %r8, %r15                   /* plan */
    mov (%r12), %r14                /* size */
    cmp %r13, %r14
    jae 10f
    mov %rcx, (%rbx, %r14, 8)       /* ---- push and sift up */
    incq (%r12)
1:  test %r14, %r14
    jz 9f
    lea -1(%r14), %rax
    shr $1, %rax
    mov %rax, 0(%rsp)               /* parent */
    mov %rbx, %rdi
    mov %r14, %rsi
    mov %rax, %rdx
    mov %r15, %rcx
    call heap_cmp
    cmp $0, %eax
    jle 9f
    mov 0(%rsp), %rax
    mov (%rbx, %rax, 8), %rcx
    mov (%rbx, %r14, 8), %rdx
    mov %rdx, (%rbx, %rax, 8)
    mov %rcx, (%rbx, %r14, 8)
    mov %rax, %r14
    jmp 1b
10: test %r13, %r13                 /* ---- full: replace the maximum? */
    jz 9f
    mov %rcx, (%rbx, %r13, 8)       /* candidate in the spare slot */
    mov %rbx, %rdi
    mov %r13, %rsi
    xor %edx, %edx
    mov %r15, %rcx
    call heap_cmp
    cmp $0, %eax
    jge 9f
    mov (%rbx, %r13, 8), %rax
    mov %rax, (%rbx)
    xor %r14d, %r14d                /* sift down */
11: lea 1(%r14, %r14), %rax         /* left child */
    cmp %r13, %rax
    jae 9f
    mov %rax, 0(%rsp)               /* largest */
    lea 1(%rax), %rcx
    mov %rcx, 8(%rsp)               /* right child */
    cmp %r13, %rcx
    jae 12f
    mov %rbx, %rdi
    mov %rcx, %rsi
    mov %rax, %rdx
    mov %r15, %rcx
    call heap_cmp
    cmp $0, %eax
    jle 12f
    mov 8(%rsp), %rax
    mov %rax, 0(%rsp)
12: mov %rbx, %rdi
    mov 0(%rsp), %rsi
    mov %r14, %rdx
    mov %r15, %rcx
    call heap_cmp
    cmp $0, %eax
    jle 9f
    mov 0(%rsp), %rax
    mov (%rbx, %rax, 8), %rcx
    mov (%rbx, %r14, 8), %rdx
    mov %rdx, (%rbx, %rax, 8)
    mov %rcx, (%rbx, %r14, 8)
    mov %rax, %r14
    jmp 11b
9:  LEAVE
ENDF topn_offer

/* project_part(task rdi, part rsi, lo rdx, hi rcx): output rows of the
 * tuples [lo, hi) -> PT_OUT[part]; with top-N (PT_D, K = PT_A) only the
 * K first rows in ORDER BY order are kept */
FUNC project_part
    ENTER 128
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, %r14
    mov %rcx, 72(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    call cur_arena
    mov %rax, %rdi
    call vec_new
    mov %rax, 80(%rsp)              /* rows (top-N: rows of one batch) */
    movq $0, 96(%rsp)               /* heap size */
    cmpq $0, PT_D(%rbx)
    je 0f
    mov PT_A(%rbx), %rdi
    lea 8(, %rdi, 8), %rdi
    call tmp_alloc
    mov %rax, 88(%rsp)              /* heap */
0:  mov XS_W(%r13), %r12
    shl $3, %r12
1:  cmp 72(%rsp), %r14
    jae 9f
    call check_deadline
    mov 72(%rsp), %r15
    sub %r14, %r15
    cmp $VB, %r15
    jbe 2f
    mov $VB, %r15d
2:  mov XS_TS(%r13), %rax
    mov %r14, %rdx
    imul %r12, %rdx
    add TS_DATA(%rax), %rdx
    lea 0(%rsp), %rdi
    mov XS_PLAN(%r13), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 80(%rsp), %r9
    call k_project
    add %r15, %r14
    cmpq $0, PT_D(%rbx)
    je 1b
    movq $0, 104(%rsp)              /* top-N: offer the batch's rows */
3:  mov 80(%rsp), %rax
    mov 104(%rsp), %rcx
    cmp VEC_LEN(%rax), %rcx
    jae 4f
    mov VEC_DATA(%rax), %rax
    mov (%rax, %rcx, 8), %rcx
    mov 88(%rsp), %rdi
    lea 96(%rsp), %rsi
    mov PT_A(%rbx), %rdx
    mov XS_PLAN(%r13), %r8
    call topn_offer
    incq 104(%rsp)
    jmp 3b
4:  mov 80(%rsp), %rax
    movq $0, VEC_LEN(%rax)
    jmp 1b
9:  cmpq $0, PT_D(%rbx)
    je 91f
    mov 80(%rsp), %rax              /* the heap becomes the part's rows */
    mov 88(%rsp), %rcx
    mov %rcx, VEC_DATA(%rax)
    mov 96(%rsp), %rcx
    mov %rcx, VEC_LEN(%rax)
    mov %rcx, VEC_CAP(%rax)
91: mov 64(%rsp), %rcx
    mov 80(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE
ENDF project_part

/* pexec_project(xs rdi): appends the output row of every tuple to XS_ROWS;
 * for ORDER BY ... LIMIT (without DISTINCT) only the candidates of a top-N:
 * the LIMIT + OFFSET first rows of every part (the sort that follows picks
 * the final ones) */
FUNC pexec_project
    ENTER 16
    mov %rdi, %rbx
    call pexec_threads
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov XS_PLAN(%rbx), %rcx
    cmpq $0, QP_NKEYS(%rcx)
    je 1f
    cmpq $0, QP_DISTINCT(%rcx)
    jne 1f
    mov QP_LIMIT(%rcx), %rax
    test %rax, %rax
    js 1f
    add QP_OFFSET(%rcx), %rax
    jo 1f
    cmp $TOPN_MAX, %rax
    ja 1f
    mov %rax, PT_A(%r13)            /* K */
    movq $1, PT_D(%r13)
1:  mov XS_TS(%rbx), %rax
    mov TS_N(%rax), %rdi
    lea project_part(%rip), %rsi
    mov %r13, %rdx
    call par_for
    mov %rax, %r14
    xor %r15d, %r15d
2:  cmp %r14, %r15
    jae 9f
    mov PT_OUT(%r13, %r15, 8), %rsi
    lea XS_ROWS(%rbx), %rdi
    call vec_append
    inc %r15
    jmp 2b
9:  LEAVE
ENDF pexec_project

/* vec_append(dst Vec* rdi, src Vec* rsi): appends all elements of src */
FUNC vec_append
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  cmp VEC_LEN(%r12), %r13
    jae 9f
    mov VEC_DATA(%r12), %rax
    mov (%rax, %r13, 8), %rsi
    mov %rbx, %rdi
    call vec_push
    inc %r13
    jmp 1b
9:  LEAVE
ENDF vec_append

/* ================================================================ aggregation */

/* agg_states_new(plan rdi) -> rax zeroed aggregate states */
FUNC agg_states_new
    sub $8, %rsp
    mov QP_NAGGS(%rdi), %rdi
    imul $AS_SIZE, %rdi, %rdi
    add $8, %rdi
    call tmp_zalloc
    add $8, %rsp
    ret
ENDF agg_states_new

/* agg_merge(plan rdi, dst rsi, src rdx): dst += src (non-DISTINCT states) */
FUNC agg_merge
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    xor %r14d, %r14d
1:  cmp QP_NAGGS(%rbx), %r14
    jae 9f
    mov QP_AGGS(%rbx), %rax
    mov (%rax, %r14, 8), %r15       /* agg node */
    imul $AS_SIZE, %r14, %rcx
    lea (%r12, %rcx), %rdi          /* dst state */
    lea (%r13, %rcx), %rsi          /* src state */
    inc %r14
    mov AS_COUNT(%rsi), %rax
    add %rax, AS_COUNT(%rdi)
    mov N_OP(%r15), %eax
    cmp $AGG_COUNT, %eax
    jbe 1b
    cmp $AGG_MIN, %eax
    jae 5f
    mov N_A(%r15), %rax             /* SUM / AVG */
    movzbl N_TYPE(%rax), %eax
    cmp $T_FLOAT, %eax
    jne 3f
    movsd AS_VAL(%rdi), %xmm0
    addsd AS_VAL(%rsi), %xmm0
    movsd %xmm0, AS_VAL(%rdi)
    jmp 1b
3:  mov AS_LO(%rsi), %rax
    mov AS_HI(%rsi), %rdx
    add %rax, AS_LO(%rdi)
    adc %rdx, AS_HI(%rdi)
    jmp 1b
5:  cmpq $0, AS_HAS(%rsi)           /* MIN / MAX */
    je 1b
    cmpq $0, AS_HAS(%rdi)
    je 7f
    push %rdi
    push %rsi
    mov N_A(%r15), %rax
    mov N_TYPE(%rax), %edi
    mov AS_VAL(%rsi), %rsi
    mov 8(%rsp), %rdx
    mov AS_VAL(%rdx), %rdx
    call value_cmp                  /* src vs dst */
    pop %rsi
    pop %rdi
    cmpl $AGG_MIN, N_OP(%r15)
    jne 6f
    cmp $0, %eax
    jge 1b
    jmp 7f
6:  cmp $0, %eax
    jle 1b
7:  mov AS_VAL(%rsi), %rax
    mov %rax, AS_VAL(%rdi)
    movq $1, AS_HAS(%rdi)
    jmp 1b
9:  LEAVE
ENDF agg_merge

/* single_part(task rdi, part rsi, lo rdx, hi rcx): aggregates [lo, hi) of
 * XS_TS into fresh states PT_OUT[part] */
FUNC single_part
    ENTER 112
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, %r14
    mov %rcx, 72(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_PLAN(%r13), %rdi
    call agg_states_new
    mov %rax, 80(%rsp)
    mov XS_W(%r13), %r12
    shl $3, %r12
1:  cmp 72(%rsp), %r14
    jae 9f
    call check_deadline
    mov 72(%rsp), %r15
    sub %r14, %r15
    cmp $VB, %r15
    jbe 2f
    mov $VB, %r15d
2:  mov XS_TS(%r13), %rax
    mov %r14, %rdx
    imul %r12, %rdx
    add TS_DATA(%rax), %rdx
    lea 0(%rsp), %rdi
    mov XS_PLAN(%r13), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 80(%rsp), %r9
    call k_agg_single
    add %r15, %r14
    jmp 1b
9:  mov 64(%rsp), %rcx
    mov 80(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE
ENDF single_part

/* gkey_part(task rdi, part rsi, lo rdx, hi rcx): key cells (PT_A) and
 * hashes (PT_B) of the tuples [lo, hi); PT_C = key types */
FUNC gkey_part
    ENTER 112
    mov %rdi, %rbx
    mov %rdx, %r14
    mov %rcx, 72(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_W(%r13), %r12
    shl $3, %r12
    mov XS_PLAN(%r13), %rax
    mov QP_NGROUP(%rax), %rax
    shl $4, %rax
    mov %rax, 80(%rsp)              /* key bytes per tuple */
1:  cmp 72(%rsp), %r14
    jae 9f
    call check_deadline
    mov 72(%rsp), %r15
    sub %r14, %r15
    cmp $VB, %r15
    jbe 2f
    mov $VB, %r15d
2:  mov XS_TS(%r13), %rax
    mov %r14, %rdx
    imul %r12, %rdx
    add TS_DATA(%rax), %rdx
    mov %r14, %r9
    imul 80(%rsp), %r9
    add PT_A(%rbx), %r9
    lea 0(%rsp), %rdi
    mov XS_PLAN(%r13), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    call k_group_keys
    xor %ecx, %ecx                  /* hashes */
3:  mov %rcx, 88(%rsp)
    lea (%r14, %rcx), %rdi
    imul 80(%rsp), %rdi
    add PT_A(%rbx), %rdi
    mov XS_PLAN(%r13), %rsi
    mov QP_NGROUP(%rsi), %rsi
    mov PT_C(%rbx), %rdx
    call hash_cells
    mov 88(%rsp), %rcx
    lea (%r14, %rcx), %rdx
    mov PT_B(%rbx), %rsi
    mov %rax, (%rsi, %rdx, 8)
    inc %rcx
    cmp %r15, %rcx
    jb 3b
    add %r15, %r14
    jmp 1b
9:  LEAVE
ENDF gkey_part

/* gagg_part(task rdi, part rsi): aggregates the groups of hash partition
 * `part` (of PT_D partitions), visiting their tuples in input order;
 * PT_OUT[part] = Vec of group entries (EN_D0 states, EN_D1 first tuple) */
FUNC gagg_part
    ENTER 160
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_PLAN(%r13), %rax
    mov QP_NGROUP(%rax), %rdi
    mov PT_C(%rbx), %rsi
    call ht_new
    mov %rax, 72(%rsp)              /* groups of this partition */
    call cur_arena
    mov %rax, %rdi
    call vec_new
    mov %rax, 80(%rsp)              /* entries in first-seen order */
    mov XS_W(%r13), %r12
    shl $3, %r12                    /* tuple bytes */
    mov %r12, %rdi
    imul $VB, %rdi, %rdi
    call tmp_alloc
    mov %rax, 88(%rsp)              /* batch tuples */
    mov $VB*8, %edi
    call tmp_alloc
    mov %rax, 96(%rsp)              /* batch states */
    mov XS_PLAN(%r13), %rax
    mov QP_NGROUP(%rax), %rax
    shl $4, %rax
    mov %rax, 104(%rsp)             /* key bytes per tuple */
    xor %r15d, %r15d                /* batch fill */
    xor %r14d, %r14d                /* tuple */
1:  cmp PT_N(%rbx), %r14
    jae 8f
    test $0xffff, %r14
    jnz 2f
    call check_deadline
2:  mov PT_B(%rbx), %rax
    mov (%rax, %r14, 8), %rcx       /* hash */
    mov %rcx, 112(%rsp)
    mov %rcx, %rax                  /* partition = (hash >> 32) * P >> 32 */
    shr $32, %rax
    mulq PT_D(%rbx)
    shr $32, %rax
    cmp 64(%rsp), %rax
    jne 7f
    mov 72(%rsp), %rdi
    mov %r14, %rsi
    imul 104(%rsp), %rsi
    add PT_A(%rbx), %rsi
    mov $1, %edx
    mov 112(%rsp), %rcx
    call ht_lookup_h
    mov %rax, 120(%rsp)
    test %edx, %edx
    jz 3f
    mov XS_TS(%r13), %rcx           /* new group */
    mov %r14, %rdx
    imul %r12, %rdx
    add TS_DATA(%rcx), %rdx
    mov %rdx, EN_D1(%rax)           /* representative = first tuple */
    mov XS_PLAN(%r13), %rdi
    call agg_states_new
    mov 120(%rsp), %rcx
    mov %rax, EN_D0(%rcx)
    mov 80(%rsp), %rdi
    mov %rcx, %rsi
    call vec_push
3:  mov 120(%rsp), %rax             /* queue the tuple for its group */
    mov EN_D0(%rax), %rax
    mov 96(%rsp), %rcx
    mov %rax, (%rcx, %r15, 8)
    mov %r15, %rdi
    imul %r12, %rdi
    add 88(%rsp), %rdi
    mov XS_TS(%r13), %rsi
    mov %r14, %rax
    imul %r12, %rax
    mov TS_DATA(%rsi), %rsi
    add %rax, %rsi
    mov %r12, %rcx
    shr $3, %rcx
    rep movsq
    inc %r15
    cmp $VB, %r15
    jb 7f
    call gagg_flush
7:  inc %r14
    jmp 1b
8:  call gagg_flush
    mov 64(%rsp), %rcx
    mov 80(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE

/* gagg_flush: local helper on gagg_part's frame (r15 = queued tuples) */
gagg_flush:
    test %r15, %r15
    jz 9f
    sub $8, %rsp
    lea 16(%rsp), %rdi              /* ctx at 0(%rsp) of the caller */
    mov XS_PLAN(%r13), %rsi
    mov 16+88(%rsp), %rdx
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 16+96(%rsp), %r9
    call k_agg_groups
    add $8, %rsp
    xor %r15d, %r15d
9:  ret
ENDF gagg_part

/* entry_cmp(a rdi, b rsi) -> eax: orders group entries by first tuple */
FUNC entry_cmp
    mov (%rdi), %rax
    mov (%rsi), %rcx
    mov EN_D1(%rax), %rax
    mov EN_D1(%rcx), %rcx
    xor %edx, %edx
    cmp %rcx, %rax
    seta %dl
    mov $-1, %eax
    cmovae %edx, %eax
    ret
ENDF entry_cmp

/* pexec_aggregate(xs rdi): one output row per group (HAVING applied) */
FUNC pexec_aggregate
    ENTER 32
    mov %rdi, %rbx
    mov XS_PLAN(%rbx), %r12
    call pexec_threads
    mov %rax, 0(%rsp)               /* threads */
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov XS_TS(%rbx), %rax
    mov TS_N(%rax), %rax
    mov %rax, PT_N(%r13)
    cmpq $0, QP_NGROUP(%r12)
    jne 20f

    /* ---- one group: partial states per part, merged in part order */
    xor %ecx, %ecx                  /* DISTINCT states cannot be merged */
1:  cmp QP_NAGGS(%r12), %rcx
    jae 2f
    mov QP_AGGS(%r12), %rax
    mov (%rax, %rcx, 8), %rax
    inc %rcx
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jz 1b
    movq $1, g_par_threads(%rip)
2:  mov PT_N(%r13), %rdi
    lea single_part(%rip), %rsi
    mov %r13, %rdx
    call par_for
    mov %rax, %r14
    mov $1, %r15d
3:  cmp %r14, %r15
    jae 4f
    mov %r12, %rdi
    mov PT_OUT(%r13), %rsi
    mov PT_OUT(%r13, %r15, 8), %rdx
    call agg_merge
    inc %r15
    jmp 3b
4:  mov XS_TS(%rbx), %rax           /* representative: the first tuple, */
    cmpq $0, TS_N(%rax)             /* or all NULL on empty input */
    je 5f
    mov TS_DATA(%rax), %rsi
    jmp 6f
5:  mov XS_W(%rbx), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, 8(%rsp)
    mov %rax, %rdi
    mov $0xff, %esi
    mov XS_W(%rbx), %rdx
    shl $3, %rdx
    call memset
    mov 8(%rsp), %rsi
6:  mov %rbx, %rdi
    mov PT_OUT(%r13), %rdx
    call emit_group
    LEAVE

20: /* ---- GROUP BY: keys + hashes, then hash-partitioned aggregation */
    mov QP_NGROUP(%r12), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, PT_C(%r13)            /* key types */
    xor %ecx, %ecx
21: cmp QP_NGROUP(%r12), %rcx
    jae 22f
    mov QP_GROUP(%r12), %rdx
    mov (%rdx, %rcx, 8), %rdx
    mov N_TYPE(%rdx), %edx
    mov PT_C(%r13), %rsi
    mov %rdx, (%rsi, %rcx, 8)
    inc %rcx
    jmp 21b
22: mov PT_N(%r13), %rdi
    imul QP_NGROUP(%r12), %rdi
    shl $4, %rdi
    add $16, %rdi
    call tmp_alloc
    mov %rax, PT_A(%r13)            /* key cells */
    mov PT_N(%r13), %rdi
    lea 8(, %rdi, 8), %rdi
    call tmp_alloc
    mov %rax, PT_B(%r13)            /* hashes */
    mov PT_N(%r13), %rdi
    lea gkey_part(%rip), %rsi
    mov %r13, %rdx
    call par_for
    mov %rax, PT_D(%r13)            /* partitions = parts of phase 1 */
    mov %rax, %rdi
    mov %rax, %rsi
    lea gagg_part(%rip), %rdx
    mov %r13, %rcx
    call par_run
    /* all groups, ordered by their first tuple */
    call cur_arena
    mov %rax, %rdi
    call vec_new
    mov %rax, %r14
    xor %r15d, %r15d
23: cmp PT_D(%r13), %r15
    jae 24f
    mov %r14, %rdi
    mov PT_OUT(%r13, %r15, 8), %rsi
    call vec_append
    inc %r15
    jmp 23b
24: cmpq $1, PT_D(%r13)
    je 25f
    mov VEC_DATA(%r14), %rdi
    mov VEC_LEN(%r14), %rsi
    mov $8, %edx
    lea entry_cmp(%rip), %rcx
    call qsort
25: xor %r15d, %r15d
26: cmp VEC_LEN(%r14), %r15
    jae 29f
    mov VEC_DATA(%r14), %rax
    mov (%rax, %r15, 8), %rax
    mov EN_D1(%rax), %rsi
    mov EN_D0(%rax), %rdx
    mov %rbx, %rdi
    call emit_group
    inc %r15
    jmp 26b
29: LEAVE
ENDF pexec_aggregate
