/*
 * test_planner.S - unit tests for planner.S on catalog tables
 *   t(a = 0..99, b = a % 10) with a BTREE index on a and a HASH index on b,
 *   u(a = 0..9):
 *   - equality / range / non-selective predicates -> index choice and mode
 *   - pushdown: single-table conjuncts leave the WHERE, mixed ones stay
 *   - LEFT JOIN: conjuncts on the NULL-padded side are not pushed
 *   - hash-join build side follows the estimated cardinalities
 *   - optimize = false keeps index selection, use_indexes = false disables it
 *   - the join option forces the join algorithm of equi-joins
 *   - the whole pipeline: folded predicates in the physical plan (the rules
 *     themselves are unit-tested in test_optimizer.S), optimize = false
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .data
    .p2align 3
s_t:     .quad 1
         .asciz "t"
    .p2align 3
s_u:     .quad 1
         .asciz "u"
    .p2align 3
s_ixa:   .quad 4
         .asciz "ix_a"
    .p2align 3
s_hxb:   .quad 4
         .asciz "hx_b"
ix_a:    .quad 0
hx_b:    .quad 0
    .text

#include "test_lib.inc"

FUNC main
    ENTER 32
    call arena_new
    mov %rax, g_arena(%rip)
    lea s_t(%rip), %rdi
    mov $2, %esi
    mov $100, %edx
    call mk_int_table
    mov %rax, %rbx                  /* t */
    lea s_u(%rip), %rdi
    mov $1, %esi
    mov $10, %edx
    call mk_int_table
    mov %rbx, %rdi                  /* indexes on t */
    xor %esi, %esi
    mov $IXK_BTREE, %edx
    lea s_ixa(%rip), %rcx
    call idx_build
    mov %rax, ix_a(%rip)
    mov %rbx, %rdi
    mov %rax, %rsi
    call idx_attach
    mov %rbx, %rdi
    mov $1, %esi
    mov $IXK_HASH, %edx
    lea s_hxb(%rip), %rcx
    call idx_build
    mov %rax, hx_b(%rip)
    mov %rbx, %rdi
    mov %rax, %rsi
    call idx_attach

    /* ---- equality on the BTREE column */
    CSTR %rdi, "SELECT a FROM t WHERE a = 5"
    call plan_of
    mov %rax, %r12
    mov QP_FROM(%r12), %r13
    xor %edi, %edi
    mov ix_a(%rip), %rax
    cmp FP_INDEX(%r13), %rax
    jne 1f
    cmpq $IM_EQ, FP_IMODE(%r13)
    sete %dil
1:  CSTR %rsi, "a = 5 uses ix_a (equality)"
    call check
    xor %edi, %edi
    cmpq $0, QP_WHERE(%r12)
    jne 1f
    cmpq $0, FP_FILTER(%r13)
    setne %dil
1:  CSTR %rsi, "a = 5 is pushed into the scan"
    call check

    /* ---- selective range: BTREE range lookup */
    CSTR %rdi, "SELECT a FROM t WHERE a > 95"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    mov ix_a(%rip), %rax
    cmp FP_INDEX(%r13), %rax
    jne 1f
    cmpq $IM_RANGE, FP_IMODE(%r13)
    jne 1f
    cmpq $RF_LO, FP_IFLAGS(%r13)
    sete %dil
1:  CSTR %rsi, "a > 95 uses an exclusive range on ix_a"
    call check

    /* ---- intersected bounds */
    CSTR %rdi, "SELECT a FROM t WHERE a >= 10 AND 15 > a AND a >= 12"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $RF_LO|RF_LOI|RF_HI, FP_IFLAGS(%r13)
    jne 1f
    cmpq $12, FP_IVALS(%r13)
    jne 1f
    cmpq $15, FP_INV(%r13)
    sete %dil
1:  CSTR %rsi, "range bounds are intersected to [12, 15)"
    call check

    /* ---- non-selective range: full scan */
    CSTR %rdi, "SELECT a FROM t WHERE a > 5"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $0, FP_INDEX(%r13)
    sete %dil
    CSTR %rsi, "a > 5 is a full scan"
    call check

    /* ---- HASH equality at exactly 10% */
    CSTR %rdi, "SELECT a FROM t WHERE b = 3"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    mov hx_b(%rip), %rax
    cmp FP_INDEX(%r13), %rax
    sete %dil
    CSTR %rsi, "b = 3 uses hx_b"
    call check

    /* ---- IN list of 3 values: 30% -> full scan */
    CSTR %rdi, "SELECT a FROM t WHERE b IN (1, 2, 3)"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $0, FP_INDEX(%r13)
    sete %dil
    CSTR %rsi, "b IN (1,2,3) is a full scan"
    call check

    /* ---- join: pushdown to both sides, mixed conjunct stays, build side */
    CSTR %rdi, "SELECT t.a FROM t JOIN u ON t.a = u.a WHERE u.a = 1 AND t.b > 0 AND t.a + u.a > 3"
    call plan_of
    mov %rax, %r12
    mov QP_FROM(%r12), %r13
    xor %edi, %edi
    mov QP_WHERE(%r12), %rax
    test %rax, %rax
    jz 1f
    cmpl $B_GT, N_OP(%rax)          /* the residual is the mixed conjunct */
    jne 1f
    mov FP_LEFT(%r13), %rax
    cmpq $0, FP_FILTER(%rax)
    je 1f
    mov FP_RIGHT(%r13), %rax
    cmpq $0, FP_FILTER(%rax)
    setne %dil
1:  CSTR %rsi, "join: single-table conjuncts pushed, mixed one residual"
    call check
    xor %edi, %edi
    cmpq $0, FP_BUILDL(%r13)
    sete %dil
    CSTR %rsi, "join: builds on the smaller right input"
    call check
    CSTR %rdi, "SELECT t.a FROM u JOIN t ON t.a = u.a WHERE u.a = 1"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $1, FP_BUILDL(%r13)
    sete %dil
    CSTR %rsi, "join: builds on the smaller left input"
    call check

    /* ---- LEFT JOIN: the NULL-padded side keeps its WHERE conjuncts */
    CSTR %rdi, "SELECT t.a FROM t LEFT JOIN u ON t.a = u.a WHERE u.a IS NULL AND t.b = 1"
    call plan_of
    mov %rax, %r12
    mov QP_FROM(%r12), %r13
    xor %edi, %edi
    cmpq $0, QP_WHERE(%r12)
    je 1f
    mov FP_RIGHT(%r13), %rax
    cmpq $0, FP_FILTER(%rax)
    jne 1f
    mov FP_LEFT(%r13), %rax
    cmpq $0, FP_FILTER(%rax)
    je 1f
    cmpq $0, FP_BUILDL(%r13)
    sete %dil
1:  CSTR %rsi, "left join: right-side conjunct not pushed, left-side pushed"
    call check

    /* ---- options */
    movq $0, g_opt_indexes(%rip)
    CSTR %rdi, "SELECT a FROM t WHERE a = 5"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $0, FP_INDEX(%r13)
    jne 1f
    cmpq $0, FP_FILTER(%r13)
    setne %dil
1:  CSTR %rsi, "use_indexes = false: pushed but no index"
    call check
    movq $1, g_opt_indexes(%rip)
    movq $0, g_opt_optimize(%rip)
    CSTR %rdi, "SELECT a FROM t WHERE a = 5"
    call plan_of
    mov %rax, %r12
    mov QP_FROM(%r12), %r13
    xor %edi, %edi
    cmpq $0, FP_INDEX(%r13)
    setne %dil
    CSTR %rsi, "optimize = false: physical index selection unchanged"
    call check
    movq $1, g_opt_optimize(%rip)

    /* ---- join algorithm: forced by the join option, nested loop otherwise */
    mov $JOIN_MERGE, %eax
    mov %rax, g_opt_join(%rip)
    CSTR %rdi, "SELECT t.a FROM t JOIN u ON t.a = u.a"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $JA_MERGE, FP_ALGO(%r13)
    sete %dil
    CSTR %rsi, "join = merge: MergeJoin for an equi-join"
    call check
    CSTR %rdi, "SELECT t.a FROM t JOIN u ON t.a < u.a"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $JA_NL, FP_ALGO(%r13)
    sete %dil
    CSTR %rsi, "join = merge: non-equi join falls back to a nested loop"
    call check
    movq $JOIN_HASH, g_opt_join(%rip)
    CSTR %rdi, "SELECT t.a FROM t JOIN u ON t.a = u.a"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $JA_HASH, FP_ALGO(%r13)
    sete %dil
    CSTR %rsi, "join = hash: HashJoin"
    call check
    movq $JOIN_NL, g_opt_join(%rip)
    CSTR %rdi, "SELECT t.a FROM t JOIN u ON t.a = u.a"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $JA_NL, FP_ALGO(%r13)
    sete %dil
    CSTR %rsi, "join = nested_loop: NestedLoopJoin"
    call check
    movq $JOIN_AUTO, g_opt_join(%rip)

    /* ---- optimizer rules reach the physical plan; index selection is
     * planned on the predicates as written */
    CSTR %rdi, "SELECT a FROM t WHERE b = 1 + 2"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $0, FP_INDEX(%r13)         /* planned on the original predicate */
    jne 1f
    mov FP_FILTER(%r13), %rax
    mov N_B(%rax), %rax
    cmpl $EK_LIT, N_KIND(%rax)
    jne 1f
    cmpq $3, N_V1(%rax)
    sete %dil
1:  CSTR %rsi, "optimizer: 1 + 2 folded to 3 in the pushed filter"
    call check
    CSTR %rdi, "SELECT a FROM t WHERE 1 / 0 = a"
    call plan_of
    mov QP_FROM(%rax), %r13
    mov FP_FILTER(%r13), %rax
    mov N_A(%rax), %rax
    xor %edi, %edi
    cmpl $EK_BINARY, N_KIND(%rax)
    sete %dil
    CSTR %rsi, "optimizer: a failing constant (1 / 0) is not folded"
    call check
    CSTR %rdi, "SELECT a FROM t WHERE a > 5 AND 1 = 1"
    call plan_of
    xor %edi, %edi
    cmpq $0, QP_WHERE(%rax)
    sete %dil
    CSTR %rsi, "optimizer: a residual TRUE conjunct disappears"
    call check
    CSTR %rdi, "SELECT a FROM t WHERE a > 5 OR 1 = 0"
    call plan_of
    mov QP_FROM(%rax), %r13
    mov FP_FILTER(%r13), %rax
    xor %edi, %edi
    cmpl $EK_BINARY, N_KIND(%rax)
    jne 1f
    cmpl $B_GT, N_OP(%rax)
    sete %dil
1:  CSTR %rsi, "optimizer: x OR FALSE -> x"
    call check
    CSTR %rdi, "SELECT a FROM t WHERE a / 2 > 1 AND 1 = 0"
    call plan_of
    mov QP_FROM(%rax), %r13
    xor %edi, %edi
    cmpq $0, FP_FILTER(%r13)        /* a / 2 > 1 is pushed, FALSE residual */
    setne %dil
    CSTR %rsi, "optimizer: unsafe conjuncts are kept"
    call check
    movq $0, g_opt_optimize(%rip)
    CSTR %rdi, "SELECT a FROM t WHERE b = 1 + 2"
    call plan_of
    mov QP_FROM(%rax), %r13
    mov FP_FILTER(%r13), %rax
    mov N_B(%rax), %rax
    xor %edi, %edi
    cmpl $EK_BINARY, N_KIND(%rax)
    sete %dil
    CSTR %rsi, "optimize = false: no folding"
    call check
    movq $1, g_opt_optimize(%rip)

    CSTR %rdi, "test_planner"
    call test_done
    LEAVE
ENDF main
