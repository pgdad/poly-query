/*
 * pexec.S - batch-at-a-time, parallel operator drivers (Phase 5).
 *
 * Used for every query block unless the physical planner chose the row
 * baseline (g_exec_mode = MODE_ROW with one thread, which runs the original
 * tuple-at-a-time operators of exec.S).  Each operator splits its input into contiguous
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

/* GROUP BY with local aggregation per part (gfused_part on every part,
 * then lagg_merge): PT_LMAX groups per part at most, else PT_LABORT is set
 * and the hash-partitioned aggregation runs instead */
#define PT_LMAX   PT_A
#define PT_LABORT PT_B
#define LAGG_MAX  2048

/* hash-partitioned GROUP BY: u64[n], the group entry created at tuple i
 * (0 if none), so the groups come out in first-seen order without sorting */
#define PT_SLOT   PT_FP

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
    cmpq $1, g_exec_threads(%rip)
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
    mov g_exec_threads(%rip), %r12
9:  mov %r12, g_par_threads(%rip)
    mov %r12, %rax
    LEAVE
ENDF pexec_threads

/* pexec_enabled(xs rdi) -> eax 1 when this module executes the block (every
 * mode except the row baseline with one thread) */
FUNC pexec_enabled
    mov $1, %eax
    cmpq $MODE_ROW, g_exec_mode(%rip)
    jne 1f
    cmpq $1, g_exec_threads(%rip)
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
0:  cmpq $MODE_ROW, g_exec_mode(%rip)
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
    cmpq $MODE_ROW, g_exec_mode(%rip)
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
    cmpq $MODE_ROW, g_exec_mode(%rip)
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
    cmpq $MODE_ROW, g_exec_mode(%rip)
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
    cmpq $MODE_ROW, g_exec_mode(%rip)
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

/* heap_cmp(heap rdi, i rsi, j rdx, plan rcx) -> eax: compares the heap's
 * (row, sequence) entries i and j (ORDER BY keys, then sequence) */
FUNC heap_cmp
    shl $4, %rsi
    shl $4, %rdx
    add %rdi, %rsi
    add %rdi, %rdx
    mov %rsi, %rdi
    mov %rdx, %rsi
    mov %rcx, %rdx
    jmp row_cmp_stable
ENDF heap_cmp

/* seq_cmp(a rdi, b rsi) -> eax: orders (row, sequence) pairs by sequence */
FUNC seq_cmp
    mov 8(%rdi), %rax
    cmp 8(%rsi), %rax
    seta %al
    setb %cl
    sub %cl, %al
    movsbl %al, %eax
    ret
ENDF seq_cmp

/* topn_offer(heap rdi, size* rsi, K rdx, row rcx, sequence r9, plan r8):
 * keeps the K first (row, sequence) entries in ORDER BY order (ties by
 * sequence, as the stable final sort orders them) in a binary max-heap of
 * 16-byte entries with a spare slot at [K] */
FUNC topn_offer
    ENTER 32
    mov %rdi, %rbx                  /* heap */
    mov %rsi, %r12
    mov %rdx, %r13                  /* K */
    mov %r8, %r15                   /* plan */
    mov (%r12), %r14                /* size */
    cmp %r13, %r14
    jae 10f
    mov %r14, %rax                  /* ---- push and sift up */
    shl $4, %rax
    mov %rcx, (%rbx, %rax)
    mov %r9, 8(%rbx, %rax)
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
    mov 0(%rsp), %rsi
    mov %r14, %rdi
    call heap_swap
    mov 0(%rsp), %r14
    jmp 1b
10: test %r13, %r13                 /* ---- full: replace the maximum? */
    jz 9f
    mov %r13, %rax                  /* candidate in the spare slot */
    shl $4, %rax
    mov %rcx, (%rbx, %rax)
    mov %r9, 8(%rbx, %rax)
    mov %rbx, %rdi
    mov %r13, %rsi
    xor %edx, %edx
    mov %r15, %rcx
    call heap_cmp
    cmp $0, %eax
    jge 9f
    mov %r13, %rdi
    xor %esi, %esi
    call heap_swap
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
    mov 0(%rsp), %rsi
    mov %r14, %rdi
    call heap_swap
    mov 0(%rsp), %r14
    jmp 11b
9:  LEAVE

/* heap_swap: local helper (rbx = heap): swaps entries rdi and rsi */
heap_swap:
    shl $4, %rdi
    shl $4, %rsi
    mov (%rbx, %rdi), %rax
    mov 8(%rbx, %rdi), %rcx
    mov (%rbx, %rsi), %rdx
    mov 8(%rbx, %rsi), %r8
    mov %rdx, (%rbx, %rdi)
    mov %r8, 8(%rbx, %rdi)
    mov %rax, (%rbx, %rsi)
    mov %rcx, 8(%rbx, %rsi)
    ret
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
    inc %rdi
    shl $4, %rdi
    call tmp_alloc
    mov %rax, 88(%rsp)              /* heap of (row, sequence) */
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
    cmpq $0, PT_D(%rbx)
    je 31f
    movq $0, 104(%rsp)              /* top-N: offer the batch's rows */
3:  mov 80(%rsp), %rax
    mov 104(%rsp), %rcx
    cmp VEC_LEN(%rax), %rcx
    jae 4f
    mov VEC_DATA(%rax), %rax
    lea (%r14, %rcx), %r9           /* sequence = tuple index */
    mov (%rax, %rcx, 8), %rcx
    mov 88(%rsp), %rdi
    lea 96(%rsp), %rsi
    mov PT_A(%rbx), %rdx
    mov XS_PLAN(%r13), %r8
    call topn_offer
    incq 104(%rsp)
    jmp 3b
31: add %r15, %r14
    jmp 1b
4:  mov 80(%rsp), %rax
    movq $0, VEC_LEN(%rax)
    add %r15, %r14
    jmp 1b
9:  cmpq $0, PT_D(%rbx)
    je 91f
    mov 88(%rsp), %rdi              /* the heap, in production order, */
    mov 96(%rsp), %rsi              /* becomes the part's rows */
    mov $16, %edx
    lea seq_cmp(%rip), %rcx
    call qsort
    mov 80(%rsp), %rax
    movq $0, VEC_LEN(%rax)
    xor %r14d, %r14d
92: cmp 96(%rsp), %r14
    jae 91f
    mov %r14, %rsi
    shl $4, %rsi
    add 88(%rsp), %rsi
    mov (%rsi), %rsi
    mov 80(%rsp), %rdi
    call vec_push
    inc %r14
    jmp 92b
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
    mov VEC_LEN+XS_ROWS(%rbx), %rsi /* room for all parts' rows */
    xor %ecx, %ecx
1:  cmp %r14, %rcx
    jae 11f
    mov PT_OUT(%r13, %rcx, 8), %rax
    add VEC_LEN(%rax), %rsi
    inc %rcx
    jmp 1b
11: lea XS_ROWS(%rbx), %rdi
    call vec_reserve
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
    mov VEC_LEN(%rbx), %rsi         /* room: at least double the capacity */
    add VEC_LEN(%r12), %rsi
    mov VEC_CAP(%rbx), %rax
    add %rax, %rax
    cmp %rax, %rsi
    jae 1f
    cmp VEC_CAP(%rbx), %rsi
    jbe 1f
    mov %rax, %rsi
1:  call vec_reserve
    mov VEC_LEN(%rbx), %rdi
    shl $3, %rdi
    add VEC_DATA(%rbx), %rdi
    mov VEC_DATA(%r12), %rsi
    mov VEC_LEN(%r12), %rdx
    add %rdx, VEC_LEN(%rbx)
    shl $3, %rdx
    call memcpy
    LEAVE
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
3:  mov N_A(%r15), %rax
    mov N_TYPE(%rax), %eax
    mov %eax, %ecx
    shr $8, %ecx
    cmp $T_DEC, %al
    jne 4f
    cmp $18, %cl
    jbe 4f
    add $AS_LO, %rdi                /* wide DECIMAL: 192-bit sums */
    add $AS_LO, %rsi
    call sum192_merge
    jmp 1b
4:  mov AS_LO(%rsi), %rax           /* 128-bit sums */
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
    lea (, %r14, 8), %rdi           /* clear this range's group slots */
    add PT_SLOT(%rbx), %rdi
    xor %esi, %esi
    sub %r14, %rcx
    lea (, %rcx, 8), %rdx
    call memset
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
    mov PT_SLOT(%rbx), %rax         /* the group's first tuple */
    mov %rcx, (%rax, %r14, 8)
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

/* gfused_part(task rdi, part rsi, lo rdx, hi rcx): single-pass grouping of
 * [lo, hi) (used when one part does all the work): per batch the key
 * cells, their groups and then the aggregate updates; groups in first-seen
 * order -> PT_OUT[part] */
FUNC gfused_part
    ENTER 160
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, %r14                  /* batch start */
    mov %rcx, 72(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_PLAN(%r13), %rax
    mov QP_NGROUP(%rax), %rdi
    mov PT_C(%rbx), %rsi
    call ht_new
    mov %rax, 80(%rsp)
    call cur_arena
    mov %rax, %rdi
    call vec_new
    mov %rax, 88(%rsp)
    mov XS_PLAN(%r13), %rax
    mov QP_NGROUP(%rax), %rax
    shl $4, %rax
    mov %rax, 112(%rsp)             /* key bytes per tuple */
    imul $VB, %rax, %rdi
    call tmp_alloc
    mov %rax, 96(%rsp)              /* batch key cells */
    mov $VB*8, %edi
    call tmp_alloc
    mov %rax, 104(%rsp)             /* batch states */
    mov XS_W(%r13), %r12
    shl $3, %r12                    /* tuple bytes */
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
    mov %rdx, 128(%rsp)             /* batch tuples */
    lea 0(%rsp), %rdi
    mov XS_PLAN(%r13), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 96(%rsp), %r9
    call k_group_keys
    movq $0, 136(%rsp)
3:  mov 136(%rsp), %rax             /* group of each tuple */
    cmp %r15, %rax
    jae 6f
    imul 112(%rsp), %rax
    add 96(%rsp), %rax
    mov %rax, 144(%rsp)             /* its key cells */
    mov %rax, %rdi
    mov XS_PLAN(%r13), %rsi
    mov QP_NGROUP(%rsi), %rsi
    mov PT_C(%rbx), %rdx
    call hash_cells
    mov %rax, %rcx
    mov 80(%rsp), %rdi
    mov 144(%rsp), %rsi
    mov $1, %edx
    call ht_lookup_h
    mov %rax, 152(%rsp)
    test %edx, %edx
    jz 5f
    mov 112(%rsp), %rdi             /* new group: persistent key copy */
    call tmp_alloc
    mov 152(%rsp), %rcx
    mov %rax, EN_KEY(%rcx)
    mov %rax, %rdi
    mov 144(%rsp), %rsi
    mov 112(%rsp), %rdx
    call memcpy
    mov 136(%rsp), %rax             /* representative = first tuple */
    imul %r12, %rax
    add 128(%rsp), %rax
    mov 152(%rsp), %rcx
    mov %rax, EN_D1(%rcx)
    mov XS_PLAN(%r13), %rdi
    call agg_states_new
    mov 152(%rsp), %rcx
    mov %rax, EN_D0(%rcx)
    mov 88(%rsp), %rdi
    mov %rcx, %rsi
    call vec_push
5:  mov 152(%rsp), %rax
    mov EN_D0(%rax), %rax
    mov 104(%rsp), %rcx
    mov 136(%rsp), %rdx
    mov %rax, (%rcx, %rdx, 8)
    incq 136(%rsp)
    jmp 3b
6:  lea 0(%rsp), %rdi
    mov XS_PLAN(%r13), %rsi
    mov 128(%rsp), %rdx
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 104(%rsp), %r9
    call k_agg_groups
    add %r15, %r14
    mov PT_LMAX(%rbx), %rax         /* local aggregation: give up when */
    test %rax, %rax                 /* this part has too many groups or */
    jz 1b                           /* another part gave up */
    mov 80(%rsp), %rcx
    cmp HT_N(%rcx), %rax
    jae 8f
    movq $1, PT_LABORT(%rbx)
8:  cmpq $0, PT_LABORT(%rbx)
    je 1b
9:  mov 64(%rsp), %rcx
    mov 88(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE
ENDF gfused_part

/* lagg_ok(plan rdi) -> eax 1 if partial aggregate states merge exactly:
 * no DISTINCT aggregates and no FLOAT64 SUM / AVG */
FUNC lagg_ok
    xor %ecx, %ecx
1:  cmp QP_NAGGS(%rdi), %rcx
    jae 8f
    mov QP_AGGS(%rdi), %rax
    mov (%rax, %rcx, 8), %rax
    inc %rcx
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jnz 7f
    mov N_OP(%rax), %edx
    cmp $AGG_SUM, %edx
    je 2f
    cmp $AGG_AVG, %edx
    jne 1b
2:  mov N_A(%rax), %rax
    movzbl N_TYPE(%rax), %eax
    cmp $T_FLOAT, %eax
    jne 1b
7:  xor %eax, %eax
    ret
8:  mov $1, %eax
    ret
ENDF lagg_ok

/* lagg_merge(task rdi): merges the parts' local groups (PT_OUT[0..PT_D))
 * in part order into one list in global first-seen order -> PT_OUT[0],
 * PT_D = 1 */
FUNC lagg_merge
    ENTER 16
    mov %rdi, %rbx
    mov PT_XS(%rbx), %rax
    mov XS_PLAN(%rax), %r12
    mov QP_NGROUP(%r12), %rdi
    mov PT_C(%rbx), %rsi
    call ht_new
    mov %rax, %r13                  /* all groups */
    call cur_arena
    mov %rax, %rdi
    call vec_new
    mov %rax, 0(%rsp)
    xor %r14d, %r14d                /* part */
1:  cmp PT_D(%rbx), %r14
    jae 8f
    xor %r15d, %r15d                /* its groups */
2:  mov PT_OUT(%rbx, %r14, 8), %rax
    cmp VEC_LEN(%rax), %r15
    jae 7f
    mov VEC_DATA(%rax), %rax
    mov (%rax, %r15, 8), %rax
    mov %rax, 8(%rsp)               /* local entry */
    mov %r13, %rdi
    mov EN_KEY(%rax), %rsi
    mov $1, %edx
    mov EN_HASH(%rax), %rcx
    call ht_lookup_h
    mov 8(%rsp), %rcx
    test %edx, %edx
    jz 3f
    mov EN_D0(%rcx), %rdx           /* first seen in this part */
    mov %rdx, EN_D0(%rax)
    mov EN_D1(%rcx), %rdx
    mov %rdx, EN_D1(%rax)
    mov 0(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    jmp 4f
3:  mov %r12, %rdi
    mov EN_D0(%rax), %rsi
    mov EN_D0(%rcx), %rdx
    call agg_merge
4:  inc %r15
    jmp 2b
7:  inc %r14
    jmp 1b
8:  mov 0(%rsp), %rax
    mov %rax, PT_OUT(%rbx)
    movq $1, PT_D(%rbx)
    LEAVE
ENDF lagg_merge

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
                                    /* (unless split: pexec_dsplit) */
1:  cmp QP_NAGGS(%r12), %rcx
    jae 2f
    mov QP_AGGS(%r12), %rax
    mov (%rax, %rcx, 8), %rax
    inc %rcx
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jz 1b
    mov %rbx, %rdi                  /* hash-partitioned DISTINCT */
    mov PT_N(%r13), %rsi
    call pexec_dsplit
    mov %rax, PT_OUT(%r13)
    test %rax, %rax
    jnz 4f
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
22: mov PT_N(%r13), %rdi            /* one part: single pass */
    call par_parts
    cmp $1, %rax
    je 223f
    mov %rax, 8(%rsp)               /* local aggregation per part when */
    mov %r12, %rdi                  /* the states merge exactly and the */
    call lagg_ok                    /* groups are few */
    test %eax, %eax
    jz 220f
    mov 8(%rsp), %rax
    mov %rax, PT_D(%r13)
    movq $LAGG_MAX, PT_LMAX(%r13)
    movq $0, PT_LABORT(%r13)
    mov PT_N(%r13), %rdi
    mov %rax, %rsi
    lea gfused_part(%rip), %rdx
    mov %r13, %rcx
    call par_run
    cmpq $0, PT_LABORT(%r13)
    jne 222f
    mov %r13, %rdi
    call lagg_merge
    jmp 221f
222: movq $0, PT_LMAX(%r13)         /* too many groups: hash partitions */
    movq $0, PT_LABORT(%r13)
    jmp 220f
223:
    movq $1, PT_D(%r13)
    mov PT_N(%r13), %rdi
    mov $1, %esi
    lea gfused_part(%rip), %rdx
    mov %r13, %rcx
    call par_run
    jmp 221f
220: mov PT_N(%r13), %rdi
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
    shl $3, %rdi
    call tmp_alloc
    mov %rax, PT_SLOT(%r13)         /* group slots by first tuple */
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
    mov %r13, %rdi                  /* groups in first-seen order */
    call slot_order
221: /* all groups, ordered by their first tuple */
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
25: mov %rbx, %rdi
    mov %r14, %rsi
    call pexec_emit
    LEAVE
ENDF pexec_aggregate

/* scount_part(task rdi, part rsi, lo rdx, hi rcx): PT_CNT[part] = groups
 * whose first tuple lies in [lo, hi) */
FUNC scount_part
    mov PT_SLOT(%rdi), %r8
    xor %eax, %eax
1:  cmp %rcx, %rdx
    jae 9f
    cmpq $0, (%r8, %rdx, 8)
    je 2f
    inc %rax
2:  inc %rdx
    jmp 1b
9:  mov %rax, PT_CNT(%rdi, %rsi, 8)
    ret
ENDF scount_part

/* scopy_part(task rdi, part rsi, lo rdx, hi rcx): copies those groups to
 * the entry array PT_A from position PT_CNT[part] on */
FUNC scopy_part
    mov PT_SLOT(%rdi), %r8
    mov PT_CNT(%rdi, %rsi, 8), %r9
    shl $3, %r9
    add PT_A(%rdi), %r9
1:  cmp %rcx, %rdx
    jae 9f
    mov (%r8, %rdx, 8), %rax
    test %rax, %rax
    jz 2f
    mov %rax, (%r9)
    add $8, %r9
2:  inc %rdx
    jmp 1b
9:  ret
ENDF scopy_part

/* slot_order(task rdi): the groups of all partitions in first-seen order
 * (from the slots gagg_part filled) -> PT_OUT[0], PT_D = 1 */
FUNC slot_order
    ENTER 16
    mov %rdi, %rbx
    mov PT_N(%rbx), %rdi
    call par_parts
    mov %rax, %r12                  /* parts */
    mov PT_N(%rbx), %rdi
    mov %r12, %rsi
    lea scount_part(%rip), %rdx
    mov %rbx, %rcx
    call par_run
    xor %eax, %eax                  /* counts -> start positions */
    xor %ecx, %ecx
1:  mov PT_CNT(%rbx, %rcx, 8), %rdx
    mov %rax, PT_CNT(%rbx, %rcx, 8)
    add %rdx, %rax
    inc %rcx
    cmp %r12, %rcx
    jb 1b
    mov %rax, %r13                  /* groups */
    call cur_arena
    mov %rax, %rdi
    call vec_new
    mov %rax, %r14
    mov %r14, %rdi
    mov %r13, %rsi
    call vec_reserve
    mov %r13, VEC_LEN(%r14)
    mov VEC_DATA(%r14), %rax
    mov %rax, PT_A(%rbx)
    mov PT_N(%rbx), %rdi
    mov %r12, %rsi
    lea scopy_part(%rip), %rdx
    mov %rbx, %rcx
    call par_run
    mov %r14, PT_OUT(%rbx)
    movq $1, PT_D(%rbx)
    LEAVE
ENDF slot_order

/* emit_part(task rdi, part rsi, lo rdx, hi rcx): output rows of the groups
 * [lo, hi) of the entry array PT_A (HAVING applied) -> PT_OUT[part] */
FUNC emit_part
    ENTER 96                        /* 0: EvalCtx, 64: part, 72: hi, 80: rows */
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, %r14
    mov %rcx, 72(%rsp)
    mov PT_XS(%rbx), %r13
    mov XS_PLAN(%r13), %r12
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    call cur_arena
    mov %rax, %rdi
    call vec_new
    mov %rax, 80(%rsp)
1:  cmp 72(%rsp), %r14
    jae 9f
    test $0xfff, %r14d
    jnz 2f
    call check_deadline
2:  mov PT_A(%rbx), %rax
    mov (%rax, %r14, 8), %r15       /* group entry */
    mov EN_D1(%r15), %rax
    mov %rax, 0+EC_TUPLE(%rsp)
    mov %r12, %rdi
    mov EN_D0(%r15), %rsi
    call agg_finish
    mov %rax, 0+EC_AGGV(%rsp)
    mov QP_HAVING(%r12), %rdi
    test %rdi, %rdi
    jz 3f
    lea 0(%rsp), %rsi
    call eval
    test %edx, %edx
    jnz 4f
    test $1, %eax
    jz 4f
3:  mov %r12, %rdi
    lea 0(%rsp), %rsi
    call build_row
    mov 80(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
4:  inc %r14
    jmp 1b
9:  mov 64(%rsp), %rcx
    mov 80(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE
ENDF emit_part

/* pexec_emit(xs rdi, entries Vec* rsi): emits the groups in order
 * (emit_group), in parallel parts when there are many */
FUNC pexec_emit
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov VEC_LEN(%r12), %rdi
    call par_parts
    mov %rax, %r14
    cmp $1, %r14
    ja 5f
    xor %r15d, %r15d                /* serial */
1:  cmp VEC_LEN(%r12), %r15
    jae 9f
    mov VEC_DATA(%r12), %rax
    mov (%rax, %r15, 8), %rax
    mov EN_D1(%rax), %rsi
    mov EN_D0(%rax), %rdx
    mov %rbx, %rdi
    call emit_group
    inc %r15
    jmp 1b
5:  mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov VEC_DATA(%r12), %rax
    mov %rax, PT_A(%r13)
    mov VEC_LEN(%r12), %rdi
    mov %r14, %rsi
    lea emit_part(%rip), %rdx
    mov %r13, %rcx
    call par_run
    mov VEC_LEN+XS_ROWS(%rbx), %rsi /* room for all rows, then in order */
    xor %ecx, %ecx
6:  mov PT_OUT(%r13, %rcx, 8), %rax
    add VEC_LEN(%rax), %rsi
    inc %rcx
    cmp %r14, %rcx
    jb 6b
    lea XS_ROWS(%rbx), %rdi
    call vec_reserve
    xor %r15d, %r15d
7:  lea XS_ROWS(%rbx), %rdi
    mov PT_OUT(%r13, %r15, 8), %rsi
    call vec_append
    inc %r15
    cmp %r14, %r15
    jb 7b
9:  LEAVE
ENDF pexec_emit

/* ================================================================ DISTINCT aggregates */

/* Aggregation without GROUP BY with DISTINCT aggregates: the other
 * aggregates run through single_part on a copy of the plan that omits the
 * DISTINCT ones.  Each DISTINCT aggregate is hash-partitioned: phase 1
 * evaluates its argument and hashes it for every tuple in parallel
 * (dkey_part); in phase 2 partition p keeps the values whose hash falls
 * into p in its own set and aggregates each new value once (dins_part).
 * The partitions hold disjoint value sets, so merging their states is
 * exact; FLOAT64 sums (order dependent) are not split. */

#define PT_NPART PT_FP          /* dins_part: number of partitions */
#define PT_AUX   PT_CNT         /* DistinctAux* (PT_CNT[0] reused) */

/* DistinctAux: the tuples grouped by partition (radix partitioning) */
#define AX_PID   0      /* u8[n]: partition of each tuple's value, 0xff NULL */
#define AX_CNT   8      /* u64[P][P]: per part, values per partition; then
                           each part's write position per partition */
#define AX_IDX   16     /* u32[n]: tuple indices by partition, in tuple order */
#define AX_BND   24     /* u64[P + 1]: partition bounds in AX_IDX */
#define AX_SIZE  32

/* dsplit_ok(plan rdi) -> eax 1 if every DISTINCT aggregate is COUNT, or
 * SUM / AVG / MIN / MAX of a non-FLOAT64 argument */
FUNC dsplit_ok
    xor %ecx, %ecx
1:  cmp QP_NAGGS(%rdi), %rcx
    jae 8f
    mov QP_AGGS(%rdi), %rax
    mov (%rax, %rcx, 8), %rax
    inc %rcx
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jz 1b
    cmpl $AGG_COUNT, N_OP(%rax)
    je 1b
    mov N_A(%rax), %rax
    movzbl N_TYPE(%rax), %eax
    cmp $T_FLOAT, %eax
    jne 1b
    xor %eax, %eax
    ret
8:  mov $1, %eax
    ret
ENDF dsplit_ok

/* dagg_add(agg node rdi, state rsi, value rdx): feeds a new distinct
 * (non-NULL) value to the state, as agg_update does */
FUNC dagg_add
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    incq AS_COUNT(%r12)
    mov N_OP(%rbx), %eax
    cmp $AGG_COUNT, %eax
    je 9f
    cmp $AGG_MIN, %eax
    jae 5f
    mov N_A(%rbx), %rcx             /* SUM / AVG */
    mov N_TYPE(%rcx), %ecx
    cmp $T_DEC, %cl
    jne 3f
    shr $8, %ecx
    cmp $18, %cl
    ja 4f
3:  mov %r13, %rax                  /* 128-bit integer sum */
    cqo
    add %rax, AS_LO(%r12)
    adc %rdx, AS_HI(%r12)
    jmp 9f
4:  lea AS_LO(%r12), %rdi           /* wide DECIMAL: 192-bit sum */
    mov (%r13), %rsi
    mov 8(%r13), %rdx
    call sum192_add
    jmp 9f
5:  cmpq $0, AS_HAS(%r12)           /* MIN / MAX */
    je 7f
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %edi
    mov %r13, %rsi
    mov AS_VAL(%r12), %rdx
    call value_cmp
    cmpl $AGG_MIN, N_OP(%rbx)
    jne 6f
    cmp $0, %eax
    jge 9f
    jmp 7f
6:  cmp $0, %eax
    jle 9f
7:  mov %r13, AS_VAL(%r12)
    movq $1, AS_HAS(%r12)
9:  LEAVE
ENDF dagg_add

/* dkey_part(task rdi, part rsi, lo rdx, hi rcx): value cells (PT_A) and
 * hashes (PT_B) of the argument of aggregate PT_C (types PT_D) for the
 * tuples [lo, hi) */
FUNC dkey_part
    ENTER (112+8*MAX_THREADS)      /* 0: EvalCtx, 72: hi, 80: vector, */
    mov %rdi, %rbx                  /* 88: batch index, 96: tuple index, */
    mov %rdx, %r14                  /* 104: part, 112: counts */
    mov %rcx, 72(%rsp)
    mov %rsi, 104(%rsp)
    lea 112(%rsp), %rdi
    xor %eax, %eax
    mov $MAX_THREADS, %ecx
    rep stosq
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov $VSIZE, %edi
    call tmp_alloc
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
    mov PT_C(%rbx), %rsi
    mov N_A(%rsi), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 80(%rsp), %r9
    call k_eval1
    movq $0, 88(%rsp)
3:  mov 88(%rsp), %rcx
    cmp %r15, %rcx
    jae 5f
    mov 80(%rsp), %rax
    mov (%rax, %rcx, 8), %rdx       /* value */
    movzbl VNULL(%rax, %rcx), %esi  /* NULL flag */
    lea (%r14, %rcx), %r8
    mov %r8, 96(%rsp)
    mov %r8, %rdi
    shl $4, %rdi
    add PT_A(%rbx), %rdi            /* cell */
    mov %rdx, VAL_P(%rdi)
    mov %rsi, VAL_NULL(%rdi)
    xor %eax, %eax
    mov $0xff, %ecx                 /* NULL: no partition */
    test %esi, %esi
    jnz 4f
    mov $1, %esi
    mov PT_D(%rbx), %rdx
    call hash_cells
    mov %rax, %rcx                  /* partition = (hash >> 32) * P >> 32 */
    shr $32, %rcx
    imul PT_NPART(%rbx), %rcx
    shr $32, %rcx
    incq 112(%rsp, %rcx, 8)
4:  mov 96(%rsp), %r8
    mov PT_AUX(%rbx), %rdx
    mov AX_PID(%rdx), %rdx
    mov %cl, (%rdx, %r8)
    mov PT_B(%rbx), %rcx
    mov %rax, (%rcx, %r8, 8)
    incq 88(%rsp)
    jmp 3b
5:  add %r15, %r14
    jmp 1b
9:  mov PT_AUX(%rbx), %rdi          /* publish the counts */
    mov AX_CNT(%rdi), %rdi
    mov 104(%rsp), %rax
    imul PT_NPART(%rbx), %rax
    lea (%rdi, %rax, 8), %rdi
    lea 112(%rsp), %rsi
    mov PT_NPART(%rbx), %rdx
    shl $3, %rdx
    call memcpy
    LEAVE
ENDF dkey_part

/* dscat_part(task rdi, part rsi, lo rdx, hi rcx): appends the tuples
 * [lo, hi) to their partitions' index lists (AX_CNT[part]: positions) */
FUNC dscat_part
    ENTER (8*MAX_THREADS)
    mov %rdi, %rbx
    mov %rdx, %r12                  /* tuple */
    mov %rcx, %r13                  /* end */
    mov PT_AUX(%rbx), %r14
    imul PT_NPART(%rbx), %rsi       /* the part's positions, on the stack */
    mov AX_CNT(%r14), %rax
    lea (%rax, %rsi, 8), %rsi
    lea 0(%rsp), %rdi
    mov PT_NPART(%rbx), %rdx
    shl $3, %rdx
    call memcpy
    mov AX_PID(%r14), %r8
    mov AX_IDX(%r14), %r9
1:  cmp %r13, %r12
    jae 9f
    movzbl (%r8, %r12), %eax
    cmp $0xff, %eax
    je 2f
    mov 0(%rsp, %rax, 8), %rcx
    incq 0(%rsp, %rax, 8)
    mov %r12d, (%r9, %rcx, 4)
2:  inc %r12
    jmp 1b
9:  LEAVE
ENDF dscat_part

/* Open-addressing set of u64 values for the integer-like types (BOOLEAN,
 * INT64, DATE, TIMESTAMP, narrow DECIMAL: equal exactly when bit-equal),
 * with each value's hash kept for growing; linear probing, at most half
 * full.  Used by dins_part instead of the generic chained table. */
#define OS_CAP  0       /* slots (a power of two) */
#define OS_N    8
#define OS_KEY  16      /* u64[cap] */
#define OS_HSH  24      /* u64[cap] */
#define OS_USED 32      /* u8[cap] */
#define OS_SIZE 40

/* oset_init(set rdi, cap rsi): an empty set of `cap` slots */
FUNC oset_init
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %r12, OS_CAP(%rbx)
    movq $0, OS_N(%rbx)
    lea (, %r12, 8), %rdi
    call tmp_alloc
    mov %rax, OS_KEY(%rbx)
    lea (, %r12, 8), %rdi
    call tmp_alloc
    mov %rax, OS_HSH(%rbx)
    mov %r12, %rdi
    call tmp_zalloc
    mov %rax, OS_USED(%rbx)
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF oset_init

/* oset_grow(set rdi): doubles the slots and re-inserts the values */
FUNC oset_grow
    ENTER 16
    mov %rdi, %rbx
    mov OS_CAP(%rbx), %r12          /* old slots */
    mov OS_KEY(%rbx), %r13
    mov OS_HSH(%rbx), %r14
    mov OS_USED(%rbx), %r15
    mov OS_N(%rbx), %rax
    mov %rax, 0(%rsp)
    mov %rbx, %rdi
    lea (%r12, %r12), %rsi
    call oset_init
    mov 0(%rsp), %rax
    mov %rax, OS_N(%rbx)
    mov OS_CAP(%rbx), %r8
    dec %r8                         /* mask */
    mov OS_USED(%rbx), %r9
    mov OS_KEY(%rbx), %r10
    mov OS_HSH(%rbx), %r11
    xor %ecx, %ecx
1:  cmp %r12, %rcx
    jae 9f
    cmpb $0, (%r15, %rcx)
    je 4f
    mov (%r14, %rcx, 8), %rdx       /* hash */
    mov %rdx, %rax
    and %r8, %rax
2:  cmpb $0, (%r9, %rax)
    je 3f
    inc %rax
    and %r8, %rax
    jmp 2b
3:  movb $1, (%r9, %rax)
    mov (%r13, %rcx, 8), %rsi
    mov %rsi, (%r10, %rax, 8)
    mov %rdx, (%r11, %rax, 8)
4:  inc %rcx
    jmp 1b
9:  LEAVE
ENDF oset_grow

/* oset_add(set rdi, value rsi, hash rdx) -> eax 1 if the value is new */
FUNC oset_add
    mov OS_CAP(%rdi), %r8
    dec %r8
    mov OS_USED(%rdi), %r9
    mov OS_KEY(%rdi), %r10
    mov %rdx, %rcx
    and %r8, %rcx
1:  cmpb $0, (%r9, %rcx)
    je 2f
    cmp (%r10, %rcx, 8), %rsi
    je 8f
    inc %rcx
    and %r8, %rcx
    jmp 1b
2:  movb $1, (%r9, %rcx)
    mov %rsi, (%r10, %rcx, 8)
    mov OS_HSH(%rdi), %rax
    mov %rdx, (%rax, %rcx, 8)
    incq OS_N(%rdi)
    mov OS_N(%rdi), %rax
    add %rax, %rax
    cmp OS_CAP(%rdi), %rax
    jbe 3f
    sub $8, %rsp
    call oset_grow
    add $8, %rsp
3:  mov $1, %eax
    ret
8:  xor %eax, %eax
    ret
ENDF oset_add

/* dins_part(task rdi, partition rsi): the distinct values of partition p
 * (its tuples listed by dscat_part, in tuple order) -> state PT_OUT[p] */
#define DI_PART 0
#define DI_FAST 8       /* integer-like values: the open-addressing set */
#define DI_K    16      /* position in the partition's index list */
#define DI_END  24
#define DI_SET  32      /* OS_SIZE bytes */
FUNC dins_part
    ENTER DI_SET + OS_SIZE
    mov %rdi, %rbx
    mov %rsi, DI_PART(%rsp)
    mov PT_D(%rbx), %rax            /* value type */
    mov (%rax), %eax
    xor %ecx, %ecx
    cmp $T_BOOL, %al
    je 01f
    cmp $T_INT, %al
    je 01f
    cmp $T_DATE, %al
    je 01f
    cmp $T_TS, %al
    je 01f
    cmp $T_DEC, %al
    jne 02f
    shr $8, %eax
    cmp $18, %al
    ja 02f
01: mov $1, %ecx
02: mov %rcx, DI_FAST(%rsp)
    test %rcx, %rcx
    jz 03f
    lea DI_SET(%rsp), %rdi
    mov $1024, %esi
    call oset_init
    jmp 04f
03: mov $1, %edi
    mov PT_D(%rbx), %rsi
    call ht_new
    mov %rax, %r12                  /* value set */
04: mov $AS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13                  /* state */
    mov DI_PART(%rsp), %rcx
    mov %r13, PT_OUT(%rbx, %rcx, 8)
    mov PT_AUX(%rbx), %rax          /* this partition's tuples */
    mov AX_BND(%rax), %rax
    mov DI_PART(%rsp), %rcx
    mov 8(%rax, %rcx, 8), %rdx
    mov %rdx, DI_END(%rsp)
    mov (%rax, %rcx, 8), %rax
    mov %rax, DI_K(%rsp)
1:  mov DI_K(%rsp), %rax
    cmp DI_END(%rsp), %rax
    jae 9f
    test $0xffff, %eax
    jnz 2f
    call check_deadline
2:  mov PT_AUX(%rbx), %rax
    mov AX_IDX(%rax), %rax
    mov DI_K(%rsp), %rcx
    incq DI_K(%rsp)
    mov (%rax, %rcx, 4), %r14d      /* tuple */
    mov %r14, %r15
    shl $4, %r15
    add PT_A(%rbx), %r15            /* cell */
    mov PT_B(%rbx), %rcx
    mov (%rcx, %r14, 8), %rcx       /* hash */
    cmpq $0, DI_FAST(%rsp)
    je 3f
    lea DI_SET(%rsp), %rdi
    mov VAL_P(%r15), %rsi
    mov %rcx, %rdx
    call oset_add
    test %eax, %eax
    jz 8f
    jmp 4f
3:  mov %r12, %rdi
    mov %r15, %rsi
    mov $1, %edx
    call ht_lookup_h
    test %edx, %edx
    jz 8f
4:  mov PT_C(%rbx), %rdi            /* a new value */
    mov %r13, %rsi
    mov VAL_P(%r15), %rdx
    call dagg_add
8:  jmp 1b
9:  LEAVE
ENDF dins_part

/* dsplit_bounds(task rdi): partition bounds (AX_BND) and every part's
 * first position per partition (AX_CNT, from the counts) */
FUNC dsplit_bounds
    mov PT_AUX(%rdi), %r8
    mov PT_NPART(%rdi), %r9
    mov AX_CNT(%r8), %r10
    mov AX_BND(%r8), %r11
    xor %eax, %eax                  /* position */
    xor %ecx, %ecx                  /* partition */
1:  mov %rax, (%r11, %rcx, 8)
    xor %edx, %edx                  /* part */
2:  mov %rdx, %rsi
    imul %r9, %rsi
    add %rcx, %rsi
    mov (%r10, %rsi, 8), %rdi
    mov %rax, (%r10, %rsi, 8)
    add %rdi, %rax
    inc %rdx
    cmp %r9, %rdx
    jb 2b
    inc %rcx
    cmp %r9, %rcx
    jb 1b
    mov %rax, (%r11, %r9, 8)
    ret
ENDF dsplit_bounds

/* pexec_dsplit(xs rdi, n rsi) -> rax the aggregate states of the single
 * group, or 0 when the DISTINCT aggregates are not split (one part, or an
 * aggregate dsplit_ok rejects) */
FUNC pexec_dsplit
    ENTER 48
    mov %rdi, %rbx
    mov XS_PLAN(%rbx), %r12
    mov %rsi, 0(%rsp)               /* n */
    mov %r12, %rdi
    call dsplit_ok
    test %eax, %eax
    jz 90f
    mov 0(%rsp), %rdi
    call par_parts
    cmp $1, %rax
    jbe 90f
    mov %rax, 8(%rsp)               /* partitions */
    mov %r12, %rdi
    call agg_states_new
    mov %rax, 16(%rsp)              /* states of all aggregates */
    /* plan copy with the other aggregates */
    mov $QP_SIZE, %edi
    call tmp_alloc
    mov %rax, %r13
    mov %r13, %rdi
    mov %r12, %rsi
    mov $QP_SIZE, %edx
    call memcpy
    mov QP_NAGGS(%r12), %rdi
    lea 8(, %rdi, 8), %rdi
    call tmp_alloc
    mov %rax, QP_AGGS(%r13)
    movq $0, QP_NAGGS(%r13)
    xor %ecx, %ecx
1:  cmp QP_NAGGS(%r12), %rcx
    jae 2f
    mov QP_AGGS(%r12), %rax
    mov (%rax, %rcx, 8), %rax
    inc %rcx
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jnz 1b
    mov QP_NAGGS(%r13), %rdx
    mov QP_AGGS(%r13), %rsi
    mov %rax, (%rsi, %rdx, 8)
    incq QP_NAGGS(%r13)
    jmp 1b
2:  cmpq $0, QP_NAGGS(%r13)
    je 5f
    mov $XS_SIZE, %edi              /* single_part on an XS copy */
    call tmp_alloc
    mov %rax, %r14
    mov %r14, %rdi
    mov %rbx, %rsi
    mov $XS_SIZE, %edx
    call memcpy
    mov %r13, XS_PLAN(%r14)
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r15
    mov %r14, PT_XS(%r15)
    mov 0(%rsp), %rax
    mov %rax, PT_N(%r15)
    mov %rax, %rdi
    lea single_part(%rip), %rsi
    mov %r15, %rdx
    call par_for
    mov %rax, %r14
    mov $1, %ecx
3:  cmp %r14, %rcx
    jae 4f
    mov %rcx, 24(%rsp)
    mov %r13, %rdi
    mov PT_OUT(%r15), %rsi
    mov PT_OUT(%r15, %rcx, 8), %rdx
    call agg_merge
    mov 24(%rsp), %rcx
    inc %rcx
    jmp 3b
4:  mov PT_OUT(%r15), %r15          /* copy them to their positions */
    xor %r14d, %r14d
41: cmp QP_NAGGS(%r12), %r14
    jae 5f
    mov QP_AGGS(%r12), %rax
    mov (%rax, %r14, 8), %rax
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jnz 42f
    imul $AS_SIZE, %r14, %rdi
    add 16(%rsp), %rdi
    mov %r15, %rsi
    mov $AS_SIZE, %edx
    call memcpy
    add $AS_SIZE, %r15
42: inc %r14
    jmp 41b
5:  /* the DISTINCT aggregates */
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r15
    mov %rbx, PT_XS(%r15)
    mov 0(%rsp), %rdi
    mov %rdi, PT_N(%r15)
    shl $4, %rdi
    call tmp_alloc
    mov %rax, PT_A(%r15)
    mov 0(%rsp), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, PT_B(%r15)
    mov 8(%rsp), %rax
    mov %rax, PT_NPART(%r15)
    mov $AX_SIZE, %edi              /* radix partitioning of the tuples */
    call tmp_alloc
    mov %rax, PT_AUX(%r15)
    mov 0(%rsp), %rdi
    call tmp_alloc
    mov PT_AUX(%r15), %rcx
    mov %rax, AX_PID(%rcx)
    mov 0(%rsp), %rdi
    shl $2, %rdi
    call tmp_alloc
    mov PT_AUX(%r15), %rcx
    mov %rax, AX_IDX(%rcx)
    mov 8(%rsp), %rdi
    imul %rdi, %rdi
    shl $3, %rdi
    call tmp_alloc
    mov PT_AUX(%r15), %rcx
    mov %rax, AX_CNT(%rcx)
    mov 8(%rsp), %rdi
    lea 8(, %rdi, 8), %rdi
    call tmp_alloc
    mov PT_AUX(%r15), %rcx
    mov %rax, AX_BND(%rcx)
    mov $16, %edi                   /* one-aggregate plan for agg_merge */
    call tmp_alloc                  /* (only QP_NAGGS / QP_AGGS are read) */
    mov %rax, 32(%rsp)
    mov $QP_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    movq $1, QP_NAGGS(%r13)
    mov 32(%rsp), %rax
    mov %rax, QP_AGGS(%r13)
    xor %r14d, %r14d
6:  cmp QP_NAGGS(%r12), %r14
    jae 80f
    mov QP_AGGS(%r12), %rax
    mov (%rax, %r14, 8), %rax
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jz 7f
    mov %rax, PT_C(%r15)
    mov 32(%rsp), %rcx
    mov %rax, (%rcx)
    mov N_A(%rax), %rax
    lea N_TYPE(%rax), %rax
    mov %rax, PT_D(%r15)
    mov 0(%rsp), %rdi               /* phase 1: cells, hashes, partitions */
    mov 8(%rsp), %rsi
    lea dkey_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    mov %r15, %rdi
    call dsplit_bounds
    mov 0(%rsp), %rdi               /* tuples by partition */
    mov 8(%rsp), %rsi
    lea dscat_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    mov 8(%rsp), %rdi               /* phase 2: one part per partition */
    mov %rdi, %rsi
    lea dins_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    xor %ecx, %ecx
61: cmp 8(%rsp), %rcx
    jae 7f
    mov %rcx, 24(%rsp)
    mov %r13, %rdi
    imul $AS_SIZE, %r14, %rsi
    add 16(%rsp), %rsi
    mov PT_OUT(%r15, %rcx, 8), %rdx
    call agg_merge
    mov 24(%rsp), %rcx
    inc %rcx
    jmp 61b
7:  inc %r14
    jmp 6b
80: mov 16(%rsp), %rax
    LEAVE
90: xor %eax, %eax
    LEAVE
ENDF pexec_dsplit

/* ================================================================ hash join */

/* k_eval1(ctx rdi, expr rsi, tuples rdx, n rcx, W r8, out vector r9) */
FUNC k_eval1
    cmpq $MODE_ROW, g_exec_mode(%rip)
    jne vk_eval1
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    lea (,%r8,8), %r15
    mov %r9, 0(%rsp)
    xor %r14d, %r14d
1:  cmp %rcx, %r14
    jae 9f
    mov %rcx, 8(%rsp)
    mov %r13, EC_TUPLE(%rbx)
    mov %r12, %rdi
    mov %rbx, %rsi
    call eval
    mov 0(%rsp), %rcx
    mov %rax, (%rcx, %r14, 8)
    mov %dl, VNULL(%rcx, %r14)
    mov 8(%rsp), %rcx
    add %r15, %r13
    inc %r14
    jmp 1b
9:  LEAVE
ENDF k_eval1

/* k_pred(ctx rdi, pred rsi, tuples rdx, n rcx, W r8, flags r9) */
FUNC k_pred
    cmpq $MODE_ROW, g_exec_mode(%rip)
    jne vk_pred
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    lea (,%r8,8), %r15
    mov %r9, 0(%rsp)
    xor %r14d, %r14d
1:  cmp %rcx, %r14
    jae 9f
    mov %rcx, 8(%rsp)
    mov %r13, EC_TUPLE(%rbx)
    mov %r12, %rdi
    mov %rbx, %rsi
    call eval
    xor $1, %edx
    and %edx, %eax
    and $1, %eax
    mov 0(%rsp), %rcx
    mov %al, (%rcx, %r14)
    mov 8(%rsp), %rcx
    add %r15, %r13
    inc %r14
    jmp 1b
9:  LEAVE
ENDF k_pred

/* probe task: PT_A probe TupleSet, PT_B build TupleSet, PT_C HashTable,
 * PT_D next[] (build chains), PT_N 1 = ON is just the key equality */

/* probe_part(task rdi, part rsi, lo rdx, hi rcx) */
FUNC probe_part
    ENTER 224
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, 136(%rsp)             /* batch start */
    mov %rcx, 72(%rsp)              /* hi */
    mov PT_FP(%rbx), %r12
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_W(%r13), %r15
    shl $3, %r15                    /* tuple bytes */
    mov XS_W(%r13), %rdi
    mov $16, %esi
    call ts_new
    mov %rax, 80(%rsp)              /* out */
    mov XS_W(%r13), %rdi
    mov $VB, %esi
    call ts_new
    mov %rax, 88(%rsp)              /* candidates */
    movq $VB, 104(%rsp)             /* owner / flags capacity */
    mov $VB*8, %edi
    call tmp_alloc
    mov %rax, 96(%rsp)              /* owner[] */
    mov $VB, %edi
    call tmp_alloc
    mov %rax, 120(%rsp)             /* flags[] */
    mov $VSIZE, %edi
    call tmp_alloc
    mov %rax, 112(%rsp)             /* probe keys */
1:  mov 136(%rsp), %rax
    cmp 72(%rsp), %rax
    jae 90f
    call check_deadline
    mov 72(%rsp), %rcx
    sub 136(%rsp), %rcx
    cmp $VB, %rcx
    jbe 2f
    mov $VB, %ecx
2:  mov %rcx, 144(%rsp)             /* b */
    mov PT_A(%rbx), %rax
    mov 136(%rsp), %rdx
    imul %r15, %rdx
    add TS_DATA(%rax), %rdx
    mov %rdx, 176(%rsp)             /* batch tuples */
    lea 0(%rsp), %rdi
    mov FP_BUILDL(%r12), %rsi       /* probe key */
    test %rsi, %rsi
    mov FP_LKEY(%r12), %rsi
    jz 3f
    mov FP_RKEY(%r12), %rsi
3:  mov XS_W(%r13), %r8
    mov 112(%rsp), %r9
    call k_eval1
    mov 88(%rsp), %rax
    movq $0, TS_N(%rax)
    movq $0, 152(%rsp)              /* k */
10: /* ---- candidates of probe tuple k */
    mov 152(%rsp), %rcx
    cmp 144(%rsp), %rcx
    jae 20f
    mov 112(%rsp), %rax
    cmpb $0, VNULL(%rax, %rcx)
    jne 19f                         /* NULL keys never match */
    mov (%rax, %rcx, 8), %rax
    mov %rax, 184(%rsp)             /* key cell 184..199 */
    movq $0, 192(%rsp)
    lea 184(%rsp), %rdi
    mov $1, %esi
    mov PT_C(%rbx), %rdx
    mov HT_TYPES(%rdx), %rdx
    call hash_cells
    mov PT_C(%rbx), %rdi
    lea 184(%rsp), %rsi
    xor %edx, %edx
    mov %rax, %rcx
    call ht_lookup_h
    test %rax, %rax
    jz 19f
    mov EN_D0(%rax), %r14           /* chain of build tuples */
11: cmp $-1, %r14
    je 19f
    mov 88(%rsp), %rax              /* room for one more owner */
    mov TS_N(%rax), %rax
    cmp 104(%rsp), %rax
    jb 12f
    call probe_grow
12: mov 88(%rsp), %rdi
    call ts_slot
    mov %rax, %rdi
    mov 152(%rsp), %rsi
    imul %r15, %rsi
    add 176(%rsp), %rsi             /* probe tuple */
    mov PT_B(%rbx), %rdx
    mov TS_DATA(%rdx), %rdx
    mov %r14, %rcx
    imul %r15, %rcx
    add %rcx, %rdx                  /* build tuple */
    cmpq $0, FP_BUILDL(%r12)
    je 13f
    xchg %rsi, %rdx                 /* the build side is the left input */
13: mov %r12, %rcx
    mov XS_W(%r13), %r8
    call tuple_combine
    mov 88(%rsp), %rax
    mov TS_N(%rax), %rax
    mov 96(%rsp), %rcx
    mov 152(%rsp), %rdx
    mov %rdx, -8(%rcx, %rax, 8)     /* owner */
    mov PT_D(%rbx), %rax
    mov (%rax, %r14, 8), %r14
    jmp 11b
19: incq 152(%rsp)
    jmp 10b

20: /* ---- ON condition on the candidates */
    mov 88(%rsp), %rax
    mov TS_N(%rax), %r14            /* candidates */
    cmpq $0, PT_N(%rbx)
    je 21f
    cmpq $JT_LEFT, FP_JTYPE(%r12)
    je 21f
    mov 80(%rsp), %rdi              /* inner join on the key alone: all of them */
    mov TS_DATA(%rax), %rsi
    mov %r14, %rdx
    call ts_append
    jmp 40f
21: cmpq $0, PT_N(%rbx)
    je 22f
    mov 120(%rsp), %rdi
    mov $1, %esi
    mov %r14, %rdx
    call memset
    jmp 30f
22: movq $0, 160(%rsp)              /* chunk start */
23: mov 160(%rsp), %rax
    cmp %r14, %rax
    jae 30f
    mov %r14, %rcx
    sub %rax, %rcx
    cmp $VB, %rcx
    jbe 24f
    mov $VB, %ecx
24: lea 0(%rsp), %rdi
    mov FP_ON(%r12), %rsi
    mov 88(%rsp), %rdx
    mov TS_DATA(%rdx), %rdx
    mov %rax, %r8
    imul %r15, %r8
    add %r8, %rdx
    mov XS_W(%r13), %r8
    mov 120(%rsp), %r9
    add %rax, %r9
    add %rcx, 160(%rsp)
    call k_pred
    jmp 23b

30: /* ---- emit in probe order, NULL-padding unmatched LEFT JOIN tuples */
    movq $0, 160(%rsp)              /* candidate */
    movq $0, 152(%rsp)              /* k */
31: mov 152(%rsp), %rax
    cmp 144(%rsp), %rax
    jae 40f
    movq $0, 168(%rsp)              /* matched */
32: mov 160(%rsp), %rcx
    cmp %r14, %rcx
    jae 34f
    mov 96(%rsp), %rax
    mov 152(%rsp), %rdx
    cmp %rdx, (%rax, %rcx, 8)
    jne 34f
    mov 120(%rsp), %rax
    cmpb $0, (%rax, %rcx)
    je 33f
    movq $1, 168(%rsp)
    mov 88(%rsp), %rax
    mov TS_DATA(%rax), %rsi
    imul %r15, %rcx
    add %rcx, %rsi
    mov 80(%rsp), %rdi
    mov $1, %edx
    call ts_append
33: incq 160(%rsp)
    jmp 32b
34: cmpq $JT_LEFT, FP_JTYPE(%r12)
    jne 35f
    cmpq $0, 168(%rsp)
    jne 35f
    mov 80(%rsp), %rdi
    call ts_slot
    mov %rax, %rdi
    mov 152(%rsp), %rsi
    imul %r15, %rsi
    add 176(%rsp), %rsi
    xor %edx, %edx
    mov %r12, %rcx
    mov XS_W(%r13), %r8
    call tuple_combine
35: incq 152(%rsp)
    jmp 31b

40: mov 80(%rsp), %rdi
    call check_join_rows
    mov 144(%rsp), %rax
    add %rax, 136(%rsp)
    jmp 1b
90: mov 64(%rsp), %rcx
    mov 80(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE

/* probe_grow: local helper on probe_part's frame - doubles owner[] and
 * flags[] */
probe_grow:
    sub $8, %rsp
    mov 16+104(%rsp), %rdi
    shl $4, %rdi                    /* 2 * cap * 8 */
    call tmp_alloc
    mov %rax, (%rsp)
    mov %rax, %rdi
    mov 16+96(%rsp), %rsi
    mov 16+104(%rsp), %rdx
    shl $3, %rdx
    call memcpy
    mov (%rsp), %rax
    mov %rax, 16+96(%rsp)
    mov 16+104(%rsp), %rdi
    add %rdi, %rdi
    call tmp_alloc
    mov %rax, 16+120(%rsp)
    shlq $1, 16+104(%rsp)
    add $8, %rsp
    ret
ENDF probe_part

/* pexec_probe(xs rdi, fp rsi, probe TupleSet rdx, build TupleSet rcx,
 * ht r8, next[] r9) -> rax joined TupleSet: the probe phase of a hash join,
 * in parallel parts over the probe input */
FUNC pexec_probe
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, 0(%rsp)
    mov %rcx, 8(%rsp)
    mov %r8, %r14
    mov %r9, %r15
    call pexec_threads
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov %r12, PT_FP(%r13)
    mov 0(%rsp), %rax
    mov %rax, PT_A(%r13)
    mov 8(%rsp), %rax
    mov %rax, PT_B(%r13)
    mov %r14, PT_C(%r13)
    mov %r15, PT_D(%r13)
    mov FP_ON(%r12), %rax           /* ON = (left key = right key) only? */
    cmpl $EK_BINARY, N_KIND(%rax)
    jne 2f
    cmpl $B_EQ, N_OP(%rax)
    jne 2f
    mov N_A(%rax), %rcx
    mov N_B(%rax), %rdx
    cmp FP_LKEY(%r12), %rcx
    jne 1f
    cmp FP_RKEY(%r12), %rdx
    jne 2f
    movq $1, PT_N(%r13)
    jmp 2f
1:  cmp FP_RKEY(%r12), %rcx
    jne 2f
    cmp FP_LKEY(%r12), %rdx
    jne 2f
    movq $1, PT_N(%r13)
2:  mov 0(%rsp), %rax
    mov TS_N(%rax), %rdi
    lea probe_part(%rip), %rsi
    mov %r13, %rdx
    call par_for
    mov %rax, %r14                  /* parts */
    mov PT_OUT(%r13), %r15
    mov $1, %ebx
3:  cmp %r14, %rbx
    jae 9f
    mov PT_OUT(%r13, %rbx, 8), %rax
    mov %r15, %rdi
    mov TS_DATA(%rax), %rsi
    mov TS_N(%rax), %rdx
    call ts_append
    mov %r15, %rdi
    call check_join_rows
    inc %rbx
    jmp 3b
9:  mov %r15, %rax
    LEAVE
ENDF pexec_probe

/* ================================================================ hash build */

/* Parallel hash-join build (pexec_build): phase 1 evaluates and hashes the
 * build key of every build tuple in parallel (bkey_part); phase 2 inserts
 * them into a table whose bucket array is sized up-front, every part
 * owning a contiguous range of buckets (bins_part), so no two parts touch
 * the same chain.  Each part walks the build tuples backwards, so every
 * key's tuple chain (EN_D0 / next[]) lists its tuples in input order,
 * exactly as the serial build in exec_from does. */

/* bkey_part(task rdi, part rsi, lo rdx, hi rcx): key cells (PT_A) and
 * hashes (PT_B) of key PT_D for the tuples [lo, hi) of TupleSet PT_FP
 * (key types: HT_TYPES of PT_C) */
FUNC bkey_part
    ENTER 112                       /* 0: EvalCtx, 72: hi, 80: vector, */
    mov %rdi, %rbx                  /* 88: batch index, 96: tuple index */
    mov %rdx, %r14
    mov %rcx, 72(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov $VSIZE, %edi
    call tmp_alloc
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
2:  mov PT_FP(%rbx), %rax
    mov %r14, %rdx
    imul %r12, %rdx
    add TS_DATA(%rax), %rdx
    lea 0(%rsp), %rdi
    mov PT_D(%rbx), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 80(%rsp), %r9
    call k_eval1
    movq $0, 88(%rsp)
3:  mov 88(%rsp), %rcx
    cmp %r15, %rcx
    jae 5f
    mov 80(%rsp), %rax
    mov (%rax, %rcx, 8), %rdx       /* value */
    movzbl VNULL(%rax, %rcx), %esi  /* NULL flag */
    lea (%r14, %rcx), %r8
    mov %r8, 96(%rsp)
    mov %r8, %rdi
    shl $4, %rdi
    add PT_A(%rbx), %rdi            /* cell */
    mov %rdx, VAL_P(%rdi)
    mov %rsi, VAL_NULL(%rdi)
    xor %eax, %eax
    test %esi, %esi
    jnz 4f
    mov $1, %esi
    mov PT_C(%rbx), %rdx
    mov HT_TYPES(%rdx), %rdx
    call hash_cells
4:  mov 96(%rsp), %r8
    mov PT_B(%rbx), %rcx
    mov %rax, (%rcx, %r8, 8)
    incq 88(%rsp)
    jmp 3b
5:  add %r15, %r14
    jmp 1b
9:  LEAVE
ENDF bkey_part

/* bins_part(task rdi, part rsi): inserts the build tuples (PT_N of them,
 * cells PT_A, hashes PT_B) whose bucket lies in this part's range of the
 * buckets of table PT_C, last tuple first; chains in next[] (PT_D);
 * PT_OUT[part] = number of new entries */
#define BI_LO   0
#define BI_HI   8
#define BI_NEW  16
#define BI_PART 24
#define BI_CELL 32
FUNC bins_part
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, BI_PART(%rsp)
    mov PT_C(%rbx), %r12            /* table */
    mov HT_NB(%r12), %rax           /* buckets [nb * p / P, nb * (p+1) / P) */
    mul %rsi
    divq PT_FP(%rbx)
    mov %rax, BI_LO(%rsp)
    mov HT_NB(%r12), %rax
    mov BI_PART(%rsp), %rcx
    inc %rcx
    mul %rcx
    divq PT_FP(%rbx)
    mov %rax, BI_HI(%rsp)
    movq $0, BI_NEW(%rsp)
    mov HT_NB(%r12), %r15
    dec %r15                        /* bucket mask */
    mov PT_N(%rbx), %r13            /* tuple (counting down) */
1:  sub $1, %r13
    jb 9f
    test $0xffff, %r13d
    jnz 2f
    call check_deadline
2:  mov %r13, %rax
    shl $4, %rax
    add PT_A(%rbx), %rax
    cmpq $0, VAL_NULL(%rax)
    jne 1b                          /* NULL keys never match */
    mov %rax, BI_CELL(%rsp)
    mov PT_B(%rbx), %rax
    mov (%rax, %r13, 8), %rax       /* hash */
    mov %rax, %rcx
    and %r15, %rcx                  /* bucket */
    cmp BI_LO(%rsp), %rcx
    jb 1b
    cmp BI_HI(%rsp), %rcx
    jae 1b
    mov HT_BKT(%r12), %rdx
    lea (%rdx, %rcx, 8), %rdx
    mov (%rdx), %r14                /* chain */
3:  test %r14, %r14
    jz 5f
    cmp EN_HASH(%r14), %rax
    jne 4f
    push %rax
    push %rdx
    mov EN_KEY(%r14), %rdi
    mov BI_CELL+16(%rsp), %rsi
    mov $1, %edx
    mov HT_TYPES(%r12), %rcx
    call cells_eq
    pop %rdx
    mov %eax, %ecx
    pop %rax
    test %ecx, %ecx
    jnz 6f
4:  mov EN_NEXT(%r14), %r14
    jmp 3b
5:  push %rax                       /* new key */
    push %rdx
    mov $EN_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r14
    pop %rdx
    pop %rax
    mov %rax, EN_HASH(%r14)
    mov BI_CELL(%rsp), %rax
    mov %rax, EN_KEY(%r14)
    movq $-1, EN_D0(%r14)
    mov (%rdx), %rax
    mov %rax, EN_NEXT(%r14)
    mov %r14, (%rdx)
    incq BI_NEW(%rsp)
6:  mov EN_D0(%r14), %rax           /* tuple joins the key's chain */
    mov PT_D(%rbx), %rcx
    mov %rax, (%rcx, %r13, 8)
    mov %r13, EN_D0(%r14)
    jmp 1b
9:  mov BI_PART(%rsp), %rcx
    mov BI_NEW(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE
ENDF bins_part

/* pexec_build(xs rdi, build TupleSet rsi, key rdx, table rcx, next r8)
 * -> eax 1 if the table was built here (more than one part), else 0 */
FUNC pexec_build
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, 0(%rsp)
    mov %rcx, %r13
    mov %r8, 8(%rsp)
    call pexec_threads
    mov TS_N(%r12), %rdi
    call par_parts
    mov %rax, %r14                  /* parts */
    xor %eax, %eax
    cmp $1, %r14
    jbe 99f
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r15
    mov %rbx, PT_XS(%r15)
    mov %r12, PT_FP(%r15)
    mov TS_N(%r12), %rax
    mov %rax, PT_N(%r15)
    mov %r13, PT_C(%r15)
    mov 0(%rsp), %rax
    mov %rax, PT_D(%r15)
    mov PT_N(%r15), %rdi
    shl $4, %rdi
    call tmp_alloc
    mov %rax, PT_A(%r15)            /* key cells */
    mov PT_N(%r15), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, PT_B(%r15)            /* hashes */
    mov PT_N(%r15), %rdi            /* phase 1 */
    mov %r14, %rsi
    lea bkey_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    mov $64, %ecx                   /* buckets: a power of two >= n */
1:  cmp PT_N(%r15), %rcx
    jae 2f
    shl $1, %rcx
    jmp 1b
2:  mov %rcx, HT_NB(%r13)
    lea (, %rcx, 8), %rdi
    call tmp_zalloc
    mov %rax, HT_BKT(%r13)
    mov %r14, PT_FP(%r15)           /* phase 2: P bucket ranges */
    mov 8(%rsp), %rax
    mov %rax, PT_D(%r15)
    mov %r14, %rdi
    mov %r14, %rsi
    lea bins_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    xor %eax, %eax                  /* entries */
    xor %ecx, %ecx
3:  add PT_OUT(%r15, %rcx, 8), %rax
    inc %rcx
    cmp %r14, %rcx
    jb 3b
    mov %rax, HT_N(%r13)
    mov $1, %eax
99: LEAVE
ENDF pexec_build

/* ================================================================ merge join keys */

/* jkey_part(task rdi, part rsi, lo rdx, hi rcx): (key, index) entries of
 * the tuples [lo, hi) of PT_A with non-NULL key PT_B, written from
 * PT_C + lo * 16 on; PT_CNT[part] = count */
FUNC jkey_part
    ENTER 112
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, %r14                  /* batch start */
    mov %rcx, 72(%rsp)
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov $VSIZE, %edi
    call tmp_alloc
    mov %rax, 80(%rsp)              /* key vector */
    mov %r14, %r12
    shl $4, %r12
    add PT_C(%rbx), %r12            /* next entry */
    mov %r12, 88(%rsp)              /* first entry */
1:  cmp 72(%rsp), %r14
    jae 9f
    call check_deadline
    mov 72(%rsp), %r15
    sub %r14, %r15
    cmp $VB, %r15
    jbe 2f
    mov $VB, %r15d
2:  mov PT_A(%rbx), %rax
    mov XS_W(%r13), %rdx
    shl $3, %rdx
    imul %r14, %rdx
    add TS_DATA(%rax), %rdx
    lea 0(%rsp), %rdi
    mov PT_B(%rbx), %rsi
    mov %r15, %rcx
    mov XS_W(%r13), %r8
    mov 80(%rsp), %r9
    call k_eval1
    mov 80(%rsp), %rax
    xor %ecx, %ecx
3:  cmp %r15, %rcx
    jae 4f
    cmpb $0, VNULL(%rax, %rcx)
    jne 31f
    mov (%rax, %rcx, 8), %rdx
    mov %rdx, (%r12)
    lea (%r14, %rcx), %rdx
    mov %rdx, 8(%r12)
    add $16, %r12
31: inc %rcx
    jmp 3b
4:  add %r15, %r14
    jmp 1b
9:  sub 88(%rsp), %r12
    shr $4, %r12
    mov 64(%rsp), %rcx
    lea PT_CNT(%rbx), %rax
    mov %r12, (%rax, %rcx, 8)
    LEAVE
ENDF jkey_part

/* pexec_join_keys(xs rdi, ts rsi, key rdx, entries rcx) -> rax count: the
 * (key, tuple index) entries of the non-NULL keys, in tuple order */
FUNC pexec_join_keys
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r14
    mov %rcx, %r15
    call pexec_threads
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov %r12, PT_A(%r13)
    mov %r14, PT_B(%r13)
    mov %r15, PT_C(%r13)
    mov TS_N(%r12), %rdi
    mov %rdi, PT_N(%r13)
    lea jkey_part(%rip), %rsi
    mov %r13, %rdx
    call par_for
    mov %rax, %r14                  /* parts: compact their entries */
    mov PT_CNT(%r13), %r15          /* count = part 0's */
    mov $1, %ebx
1:  cmp %r14, %rbx
    jae 9f
    mov PT_N(%r13), %rax            /* part start = n * p / P */
    mul %rbx
    div %r14
    mov %rax, %rsi
    shl $4, %rsi
    add PT_C(%r13), %rsi
    mov %r15, %rdi
    shl $4, %rdi
    add PT_C(%r13), %rdi
    lea PT_CNT(%r13), %rcx
    mov (%rcx, %rbx, 8), %rdx
    add %rdx, %r15
    shl $4, %rdx
    call memmove
    inc %rbx
    jmp 1b
9:  mov %r15, %rax
    LEAVE
ENDF pexec_join_keys

/* ================================================================ nested loop */

/* nl_part(task rdi, part rsi, lo rdx, hi rcx): every pair of the left
 * tuples [lo, hi) (PT_A) with all right tuples (PT_B), in left-major order;
 * ON evaluated per chunk of VB pairs; LEFT JOIN padding */
FUNC nl_part
    ENTER 160
    mov %rdi, %rbx
    mov %rsi, 64(%rsp)
    mov %rdx, %r14                  /* left tuple */
    mov %rcx, 72(%rsp)
    mov PT_FP(%rbx), %r12
    mov PT_XS(%rbx), %r13
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call wctx_init
    mov XS_W(%r13), %r15
    shl $3, %r15                    /* tuple bytes */
    mov XS_W(%r13), %rdi
    mov $16, %esi
    call ts_new
    mov %rax, 80(%rsp)              /* out */
    mov XS_W(%r13), %rdi
    mov $VB, %esi
    call ts_new
    mov %rax, 88(%rsp)              /* candidate pairs */
    mov $VB, %edi
    call tmp_alloc
    mov %rax, 96(%rsp)              /* flags */
1:  cmp 72(%rsp), %r14
    jae 90f
    call check_deadline
    movq $0, 104(%rsp)              /* matched */
    movq $0, 112(%rsp)              /* right chunk start */
    mov PT_A(%rbx), %rax
    mov %r14, %rcx
    imul %r15, %rcx
    add TS_DATA(%rax), %rcx
    mov %rcx, 120(%rsp)             /* left tuple */
2:  mov PT_B(%rbx), %rax
    mov 112(%rsp), %rcx
    cmp TS_N(%rax), %rcx
    jae 6f
    mov TS_N(%rax), %rdx
    sub %rcx, %rdx
    cmp $VB, %rdx
    jbe 21f
    mov $VB, %edx
21: mov %rdx, 128(%rsp)             /* chunk size */
    mov 88(%rsp), %rax
    movq $0, TS_N(%rax)
    movq $0, 136(%rsp)
3:  mov 136(%rsp), %rcx             /* candidates */
    cmp 128(%rsp), %rcx
    jae 4f
    mov 88(%rsp), %rdi
    call ts_slot
    mov %rax, %rdi
    mov 120(%rsp), %rsi
    mov PT_B(%rbx), %rdx
    mov 112(%rsp), %rcx
    add 136(%rsp), %rcx
    imul %r15, %rcx
    add TS_DATA(%rdx), %rcx
    mov %rcx, %rdx
    mov %r12, %rcx
    mov XS_W(%r13), %r8
    call tuple_combine
    incq 136(%rsp)
    jmp 3b
4:  cmpq $0, FP_ON(%r12)
    jne 41f
    mov 96(%rsp), %rdi              /* no condition: every pair */
    mov $1, %esi
    mov 128(%rsp), %rdx
    call memset
    jmp 42f
41: lea 0(%rsp), %rdi
    mov FP_ON(%r12), %rsi
    mov 88(%rsp), %rdx
    mov TS_DATA(%rdx), %rdx
    mov 128(%rsp), %rcx
    mov XS_W(%r13), %r8
    mov 96(%rsp), %r9
    call k_pred
42: movq $0, 136(%rsp)              /* emit the matching pairs in order */
5:  mov 136(%rsp), %rcx
    cmp 128(%rsp), %rcx
    jae 51f
    mov 96(%rsp), %rax
    cmpb $0, (%rax, %rcx)
    je 50f
    movq $1, 104(%rsp)
    mov 88(%rsp), %rax
    mov TS_DATA(%rax), %rsi
    imul %r15, %rcx
    add %rcx, %rsi
    mov 80(%rsp), %rdi
    mov $1, %edx
    call ts_append
50: incq 136(%rsp)
    jmp 5b
51: mov 80(%rsp), %rdi
    call check_join_rows
    mov 128(%rsp), %rax
    add %rax, 112(%rsp)
    jmp 2b
6:  cmpq $JT_LEFT, FP_JTYPE(%r12)   /* unmatched left tuple: NULL-padded */
    jne 7f
    cmpq $0, 104(%rsp)
    jne 7f
    mov 80(%rsp), %rdi
    call ts_slot
    mov %rax, %rdi
    mov 120(%rsp), %rsi
    xor %edx, %edx
    mov %r12, %rcx
    mov XS_W(%r13), %r8
    call tuple_combine
    mov 80(%rsp), %rdi
    call check_join_rows
7:  inc %r14
    jmp 1b
90: mov 64(%rsp), %rcx
    mov 80(%rsp), %rax
    mov %rax, PT_OUT(%rbx, %rcx, 8)
    LEAVE
ENDF nl_part

/* pexec_nl(xs rdi, fp rsi, L rdx, R rcx) -> rax joined TupleSet: nested-loop
 * join in parallel parts over the left input */
FUNC pexec_nl
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r14
    mov %rcx, %r15
    call pexec_threads
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, PT_XS(%r13)
    mov %r12, PT_FP(%r13)
    mov %r14, PT_A(%r13)
    mov %r15, PT_B(%r13)
    mov TS_N(%r14), %rax            /* parts sized by pairs, at most one */
    mov TS_N(%r15), %rcx            /* per left tuple */
    inc %rcx
    mul %rcx
    jno 1f
    mov $0x7fffffffffffffff, %rax
1:  mov %rax, %rdi
    call par_parts
    mov TS_N(%r14), %rdi
    cmp %rdi, %rax
    cmova %rdi, %rax
    mov $1, %ecx
    test %rax, %rax
    cmovz %rcx, %rax
    mov %rax, %rsi
    lea nl_part(%rip), %rdx
    mov %r13, %rcx
    call par_run
    mov %rax, %r14
    mov PT_OUT(%r13), %r15
    mov $1, %ebx
2:  cmp %r14, %rbx
    jae 9f
    mov PT_OUT(%r13, %rbx, 8), %rax
    mov %r15, %rdi
    mov TS_DATA(%rax), %rsi
    mov TS_N(%rax), %rdx
    call ts_append
    mov %r15, %rdi
    call check_join_rows
    inc %rbx
    jmp 2b
9:  mov %r15, %rax
    LEAVE
ENDF pexec_nl

/* ================================================================ sort */

/* sort task: PT_A rows, PT_B source pairs, PT_C plan, PT_D destination
 * pairs, PT_N run bounds (u64[runs + 1]) */

/* sort_part(task rdi, part rsi, lo rdx, hi rcx): sorts the (row, sequence)
 * pairs of rows [lo, hi) */
FUNC sort_part
    ENTER 0
    mov %rdi, %rbx
    mov %rdx, %r12
    mov %rcx, %r13
    mov PT_A(%rbx), %r8
    mov PT_B(%rbx), %r9
    mov %r12, %rcx
1:  cmp %r13, %rcx
    jae 2f
    mov %rcx, %rdx
    shl $4, %rdx
    mov (%r8, %rcx, 8), %rax
    mov %rax, (%r9, %rdx)
    mov %rcx, 8(%r9, %rdx)
    inc %rcx
    jmp 1b
2:  mov %r12, %rdi
    shl $4, %rdi
    add PT_B(%rbx), %rdi
    mov %r13, %rsi
    sub %r12, %rsi
    mov $16, %edx
    lea row_cmp_stable(%rip), %rcx
    mov PT_C(%rbx), %r8
    call qsort_r
    LEAVE
ENDF sort_part

/* merge_part(task rdi, part k rsi): merges the sorted runs 2k and 2k+1 of
 * PT_B into PT_D */
FUNC merge_part
    ENTER 16
    mov %rdi, %rbx
    mov PT_N(%rbx), %rax
    lea (%rsi, %rsi), %rcx
    mov (%rax, %rcx, 8), %r12       /* i: first run */
    mov 8(%rax, %rcx, 8), %r13      /* j: second run (= end of the first) */
    mov %r13, 0(%rsp)
    mov 16(%rax, %rcx, 8), %rax
    mov %rax, 8(%rsp)               /* end of the second run */
    mov %r12, %r14                  /* output position */
1:  cmp 0(%rsp), %r12
    jae 5f
    cmp 8(%rsp), %r13
    jae 5f
    mov %r13, %rdi
    shl $4, %rdi
    add PT_B(%rbx), %rdi
    mov %r12, %rsi
    shl $4, %rsi
    add PT_B(%rbx), %rsi
    mov PT_C(%rbx), %rdx
    call row_cmp_stable
    mov %r12, %rcx
    cmp $0, %eax
    jge 2f
    mov %r13, %rcx                  /* the second run's entry first */
    inc %r13
    jmp 3f
2:  inc %r12
3:  shl $4, %rcx
    add PT_B(%rbx), %rcx
    mov %r14, %rdx
    shl $4, %rdx
    add PT_D(%rbx), %rdx
    mov (%rcx), %rax
    mov %rax, (%rdx)
    mov 8(%rcx), %rax
    mov %rax, 8(%rdx)
    inc %r14
    jmp 1b
5:  mov %r14, %rdi                  /* the rest of either run */
    shl $4, %rdi
    add PT_D(%rbx), %rdi
    mov %r12, %rsi
    shl $4, %rsi
    add PT_B(%rbx), %rsi
    mov 0(%rsp), %rdx
    sub %r12, %rdx
    add %rdx, %r14
    shl $4, %rdx
    call memcpy
    mov %r14, %rdi
    shl $4, %rdi
    add PT_D(%rbx), %rdi
    mov %r13, %rsi
    shl $4, %rsi
    add PT_B(%rbx), %rsi
    mov 8(%rsp), %rdx
    sub %r13, %rdx
    shl $4, %rdx
    call memcpy
    LEAVE
ENDF merge_part

/* pexec_sort(rows rdi, n rsi, plan rdx) -> eax 1 if sorted here (stable,
 * like sort_rows), 0 when one part would do all the work */
FUNC pexec_sort
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov g_exec_threads(%rip), %rax   /* sorting evaluates no expressions */
    mov %rax, g_par_threads(%rip)
    mov %r12, %rdi
    call par_parts
    mov %rax, %r14                  /* runs */
    xor %eax, %eax
    cmp $1, %r14
    jbe 99f
    mov $PT_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r15
    mov %rbx, PT_A(%r15)
    mov %r13, PT_C(%r15)
    mov %r12, %rdi
    shl $4, %rdi
    call tmp_alloc
    mov %rax, PT_B(%r15)
    mov %r12, %rdi
    shl $4, %rdi
    call tmp_alloc
    mov %rax, PT_D(%r15)
    lea 8(, %r14, 8), %rdi
    call tmp_alloc
    mov %rax, PT_N(%r15)            /* bounds of part p: n * p / P */
    xor %ecx, %ecx
1:  cmp %r14, %rcx
    ja 2f
    mov %r12, %rax
    mul %rcx
    div %r14
    mov PT_N(%r15), %rdx
    mov %rax, (%rdx, %rcx, 8)
    inc %rcx
    jmp 1b
2:  mov %r12, %rdi                  /* sorted runs */
    mov %r14, %rsi
    lea sort_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
3:  cmp $1, %r14                    /* merge rounds */
    jbe 8f
    mov %r14, %rdi
    shr $1, %rdi
    mov %rdi, %rsi
    lea merge_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    test $1, %r14                   /* odd run count: the last run moves */
    jz 4f
    mov PT_N(%r15), %rax
    mov -8(%rax, %r14, 8), %rsi     /* start of the last run */
    mov (%rax, %r14, 8), %rdx
    sub %rsi, %rdx
    shl $4, %rdx
    shl $4, %rsi
    mov PT_D(%r15), %rdi
    add %rsi, %rdi
    add PT_B(%r15), %rsi
    call memcpy
4:  mov PT_N(%r15), %rax            /* bounds of the merged runs */
    xor %ecx, %ecx
5:  lea (%rcx, %rcx), %rdx
    cmp %r14, %rdx
    jae 6f
    mov (%rax, %rdx, 8), %rdx
    mov %rdx, (%rax, %rcx, 8)
    inc %rcx
    jmp 5b
6:  mov (%rax, %r14, 8), %rdx       /* final bound */
    mov %rdx, (%rax, %rcx, 8)
    mov %rcx, %r14                  /* runs = ceil(runs / 2) */
    mov PT_B(%r15), %rax            /* swap source and destination */
    mov PT_D(%r15), %rcx
    mov %rcx, PT_B(%r15)
    mov %rax, PT_D(%r15)
    jmp 3b
8:  mov PT_B(%r15), %rcx            /* rows in sorted order */
    xor %edx, %edx
81: cmp %r12, %rdx
    jae 82f
    mov %rdx, %rax
    shl $4, %rax
    mov (%rcx, %rax), %rax
    mov %rax, (%rbx, %rdx, 8)
    inc %rdx
    jmp 81b
82: mov $1, %eax
99: LEAVE
ENDF pexec_sort
