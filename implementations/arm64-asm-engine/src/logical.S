// =============================================================================
// logical.S — logical query plans: relational operators without execution
// strategy (LogicalNode, pq.inc LN_* / LO_*).
//
//   lp_build(x0 BoundQuery*) -> x0 LogicalNode*   translates one query level:
//       Limit? <- Sort? <- Distinct? <- (Aggregate | Project)
//              <- Filter(WHERE)? <- FROM tree (Scan / SubqueryScan / Join)
//                                   | Values
//     or, for a UNION ALL compound:
//       Limit? <- Sort? <- UnionAll <- branch plans (each built as above)
//   ln_new(w0 op, x1 BoundQuery*, x2 input or 0) -> x0 LogicalNode*
//   lp_exprs(x0 LogicalNode*, x1 fn, x2 arg)
//       calls fn(x0 Node** slot, x1 arg) for every expression of the plan:
//       predicates (Scan / Filter / Join / HAVING), grouping keys, aggregate
//       arguments, output and hidden ORDER BY expressions — of this query
//       level and its UNION ALL branches. Subquery plans are levels of their
//       own and are not visited.
//   lp_print(x0 Buf*, x1 LogicalNode*)   debug text, one line per operator
//       (two spaces of indentation per level), SubqueryScans with the plan of
//       their subquery when it has been built (SP_LPLAN)
//   lp_print_expr(x0 Buf*, x1 Node*, x2 BoundQuery*)   expression text
//
// The builder takes no decision: WHERE stays one Filter above the FROM tree,
// ON conditions stay on their joins, scans read every column. The optimizer
// rules (optimize.S) rewrite the plan; physical.S maps it to PlanNodes.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// ln_new(w0 op, x1 BoundQuery*, x2 input or 0) -> x0 LogicalNode*
// The new node inherits the range-variable mask of its input.
// =============================================================================
FUNC ln_new
    ENTER 1
    mov  w19, w0
    stp  x1, x2, [sp, #-16]!
    mov  x0, #LN_SIZE
    bl   arena_zalloc
    ldp  x1, x2, [sp], #16
    str  w19, [x0, #LN_OP]
    str  x1, [x0, #LN_BQ]
    str  x2, [x0, #LN_LEFT]
    cbz  x2, 1f
    ldr  x9, [x2, #LN_MASK]
    str  x9, [x0, #LN_MASK]
1:  LEAVE 1
ENDF ln_new

// =============================================================================
// lp_build(x0 BoundQuery*) -> x0 LogicalNode*
//   x19 bq, x20 current top node
// =============================================================================
FUNC lp_build
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ldr  x9, [x0, #BQ_NUNION]
    cbnz x9, lp_union
    ENTER 2
    mov  x19, x0
    ldr  x1, [x19, #BQ_FROM]
    cbz  x1, 1f
    bl   lp_from
    mov  x20, x0
    b    2f
1:  mov  w0, #LO_VALUES
    mov  x1, x19
    mov  x2, #0
    bl   ln_new
    mov  x20, x0
2:  ldr  x9, [x19, #BQ_WHERE]
    cbz  x9, 3f
    mov  w0, #LO_FILTER
    mov  x1, x19
    mov  x2, x20
    bl   ln_new
    ldr  x9, [x19, #BQ_WHERE]
    str  x9, [x0, #LN_PRED]
    mov  x20, x0
3:  mov  w0, #LO_PROJECT
    ldr  x9, [x19, #BQ_ISAGG]
    cbz  x9, 4f
    mov  w0, #LO_AGGREGATE
4:  mov  x1, x19
    mov  x2, x20
    bl   ln_new
    ldr  x9, [x19, #BQ_HAVING]
    str  x9, [x0, #LN_PRED]
    mov  x20, x0
    ldr  x9, [x19, #BQ_DISTINCT]
    cbz  x9, 5f
    mov  w0, #LO_DISTINCT
    mov  x1, x19
    mov  x2, x20
    bl   ln_new
    mov  x20, x0
5:  mov  x0, x19
    mov  x1, x20
    bl   lp_upper
    LEAVE 2
ENDF lp_build

// lp_union(x0 compound BoundQuery*) -> x0 LogicalNode*
//   Limit? <- Sort? <- UnionAll(branch plans, in order)
//   x19 bq, x20 node, x21 index, x22 children array
LFUNC lp_union
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    mov  x19, x0
    mov  w0, #LO_UNION
    mov  x1, x19
    mov  x2, #0
    bl   ln_new
    mov  x20, x0
    ldr  x9, [x19, #BQ_NUNION]
    str  x9, [x20, #LN_NKIDS]
    lsl  x0, x9, #3
    bl   arena_zalloc
    mov  x22, x0
    str  x22, [x20, #LN_KIDS]
    mov  x21, #0
1:  ldr  x9, [x19, #BQ_NUNION]
    cmp  x21, x9
    b.hs 2f
    ldr  x9, [x19, #BQ_UNION]
    ldr  x0, [x9, x21, lsl #3]
    bl   lp_build
    str  x0, [x22, x21, lsl #3]
    add  x21, x21, #1
    b    1b
2:  mov  x0, x19
    mov  x1, x20
    bl   lp_upper
    LEAVE 3
ENDF lp_union

// lp_upper(x0 BoundQuery*, x1 LogicalNode*) -> x0 LogicalNode*
// Adds the Sort (ORDER BY) and Limit (LIMIT / OFFSET) operators on top.
//   x19 bq, x20 current top node
LFUNC lp_upper
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x9, [x19, #BQ_NORDER]
    cbz  x9, 1f
    mov  w0, #LO_SORT
    mov  x1, x19
    mov  x2, x20
    bl   ln_new
    mov  x20, x0
1:  ldr  x9, [x19, #BQ_LIMIT]
    ldr  x10, [x19, #BQ_OFFSET]
    cmn  x9, #1
    ccmp x10, #0, #0, eq                // no LIMIT and OFFSET 0: no node
    b.eq 2f
    mov  w0, #LO_LIMIT
    mov  x1, x19
    mov  x2, x20
    bl   ln_new
    mov  x20, x0
2:  mov  x0, x20
    LEAVE 2
ENDF lp_upper

// lp_from(x0 BoundQuery*, x1 BoundFrom*) -> x0 LogicalNode* (FROM tree)
//   x19 bq, x20 BoundFrom*, x21 rv index / join node
LFUNC lp_from
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x20, #BF_KIND]
    cmp  w9, #BFK_JOIN
    b.eq 2f
    ldr  x21, [x20, #BF_RV]
    ldr  x9, [x19, #BQ_RVS]
    mov  x10, #RV_SIZE
    madd x9, x21, x10, x9
    ldr  w10, [x9, #RV_KIND]
    mov  w0, #LO_SCAN
    cmp  w10, #RVK_BASE
    b.eq 1f
    mov  w0, #LO_SUBQUERY               // derived table / CTE
1:  mov  x1, x19
    mov  x2, #0
    bl   ln_new
    str  x21, [x0, #LN_RV]
    mov  x10, #1
    lsl  x10, x10, x21
    str  x10, [x0, #LN_MASK]
    LEAVE 3
2:  mov  w0, #LO_JOIN
    mov  x1, x19
    mov  x2, #0
    bl   ln_new
    mov  x21, x0
    ldr  w9, [x20, #BF_JT]
    str  w9, [x21, #LN_JT]
    ldr  x9, [x20, #BF_ON]
    str  x9, [x21, #LN_PRED]
    mov  x0, x19
    ldr  x1, [x20, #BF_LEFT]
    bl   lp_from
    str  x0, [x21, #LN_LEFT]
    mov  x0, x19
    ldr  x1, [x20, #BF_RIGHT]
    bl   lp_from
    str  x0, [x21, #LN_RIGHT]
    ldr  x9, [x21, #LN_LEFT]
    ldr  x9, [x9, #LN_MASK]
    ldr  x10, [x0, #LN_MASK]
    orr  x9, x9, x10
    str  x9, [x21, #LN_MASK]
    mov  x0, x21
    LEAVE 3
ENDF lp_from

// =============================================================================
// lp_exprs(x0 LogicalNode* or 0, x1 fn, x2 arg)
//   x19 node, x20 fn, x21 arg, x22 bq, x23 index
// =============================================================================
FUNC lp_exprs
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    cbz  x0, 9f
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x22, [x19, #LN_BQ]
    ldr  x9, [x19, #LN_PRED]
    cbz  x9, 1f
    add  x0, x19, #LN_PRED
    mov  x1, x21
    blr  x20
1:  ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_AGGREGATE
    b.eq .Lle_agg
    cmp  w9, #LO_PROJECT
    b.eq .Lle_out
    cmp  w9, #LO_UNION
    b.eq .Lle_union
    b    .Lle_inputs
.Lle_agg:
    mov  x23, #0                        // grouping keys
2:  ldr  x9, [x22, #BQ_NGROUP]
    cmp  x23, x9
    b.hs 3f
    ldr  x9, [x22, #BQ_GROUP]
    add  x0, x9, x23, lsl #3
    mov  x1, x21
    blr  x20
    add  x23, x23, #1
    b    2b
3:  mov  x23, #0                        // aggregate arguments
4:  ldr  x9, [x22, #BQ_NAGG]
    cmp  x23, x9
    b.hs .Lle_out
    ldr  x9, [x22, #BQ_AGGS]
    ldr  x9, [x9, x23, lsl #3]
    add  x0, x9, #N_A
    ldr  x10, [x0]
    cbz  x10, 41f                       // COUNT(*)
    mov  x1, x21
    blr  x20
41: add  x23, x23, #1
    b    4b
.Lle_out:
    mov  x23, #0                        // output expressions
5:  ldr  x9, [x22, #BQ_NOUT]
    cmp  x23, x9
    b.hs 6f
    ldr  x9, [x22, #BQ_OUT]
    mov  x10, #OC_SIZE
    madd x0, x23, x10, x9
    add  x0, x0, #OC_EXPR
    mov  x1, x21
    blr  x20
    add  x23, x23, #1
    b    5b
6:  mov  x23, #0                        // hidden ORDER BY expressions
7:  ldr  x9, [x22, #BQ_NEXTRA]
    cmp  x23, x9
    b.hs .Lle_inputs
    ldr  x9, [x22, #BQ_EXTRA]
    add  x0, x9, x23, lsl #3
    mov  x1, x21
    blr  x20
    add  x23, x23, #1
    b    7b
.Lle_union:
    mov  x23, #0
8:  ldr  x9, [x19, #LN_NKIDS]
    cmp  x23, x9
    b.hs .Lle_inputs
    ldr  x9, [x19, #LN_KIDS]
    ldr  x0, [x9, x23, lsl #3]
    mov  x1, x20
    mov  x2, x21
    bl   lp_exprs
    add  x23, x23, #1
    b    8b
.Lle_inputs:
    ldr  x0, [x19, #LN_LEFT]
    mov  x1, x20
    mov  x2, x21
    bl   lp_exprs
    ldr  x0, [x19, #LN_RIGHT]
    mov  x1, x20
    mov  x2, x21
    bl   lp_exprs
    LEAVE 4
9:  ret
ENDF lp_exprs

// =============================================================================
// lp_print(x0 Buf*, x1 LogicalNode*)
// =============================================================================
FUNC lp_print
    mov  x2, #0
    b    lp_print_at
ENDF lp_print

// lp_print_at(x0 Buf*, x1 LogicalNode*, x2 depth)
//   x19 buf, x20 node, x21 depth, x22 bq, x23 index / RV*, x24 scratch,
//   x25 / x26 column loop
LFUNC lp_print_at
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x22, [x20, #LN_BQ]
    mov  x23, #0                        // indentation
1:  cmp  x23, x21
    b.hs 2f
    mov  x0, x19
    ADR_L x1, s_indent
    bl   buf_puts
    add  x23, x23, #1
    b    1b
2:  ldr  w9, [x20, #LN_OP]
    ADR_L x10, lo_names
    ldr  x1, [x10, x9, lsl #3]
    mov  x0, x19
    bl   buf_puts
    ldr  w9, [x20, #LN_OP]
    cmp  w9, #LO_SUBQUERY
    b.ls .Llp_scan
    cmp  w9, #LO_JOIN
    b.eq .Llp_join
    cmp  w9, #LO_FILTER
    b.eq .Llp_filter
    cmp  w9, #LO_AGGREGATE
    b.eq .Llp_agg
    cmp  w9, #LO_PROJECT
    b.eq .Llp_out
    cmp  w9, #LO_SORT
    b.eq .Llp_sort
    cmp  w9, #LO_LIMIT
    b.eq .Llp_limit
    b    .Llp_eol

.Llp_scan:                              // " <table> AS <alias>" / " <alias>"
    mov  x0, x19
    mov  w1, #' '
    bl   buf_putc
    ldr  x9, [x20, #LN_RV]
    ldr  x23, [x22, #BQ_RVS]
    mov  x10, #RV_SIZE
    madd x23, x9, x10, x23
    ldr  w9, [x20, #LN_OP]
    cmp  w9, #LO_SCAN
    b.ne 3f
    ldr  x9, [x23, #RV_TABLE]
    ldr  x1, [x9, #TBL_NAME]
    mov  x0, x19
    bl   .Llp_str
    mov  x0, x19
    ADR_L x1, s_as
    bl   buf_puts
3:  mov  x0, x19
    ldr  x1, [x23, #RV_NAME]
    bl   .Llp_str
    ldr  x24, [x20, #LN_COLS]           // " columns=[a,b]" once pruned
    cbz  x24, 6f
    mov  x0, x19
    ADR_L x1, s_columns
    bl   buf_puts
    mov  x26, #0                        // column index
    mov  x25, #0                        // columns written
4:  ldr  x9, [x23, #RV_TABLE]
    ldr  x10, [x9, #TBL_NCOLS]
    cmp  x26, x10
    b.hs 5f
    ldrb w10, [x24, x26]
    cbz  w10, 41f
    cbz  x25, 40f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
40: mov  x25, #1
    ldr  x9, [x23, #RV_TABLE]
    ldr  x9, [x9, #TBL_COLS]
    add  x9, x9, x26, lsl #5
    ldr  x1, [x9, #COL_NAME]
    mov  x0, x19
    bl   .Llp_str
41: add  x26, x26, #1
    b    4b
5:  mov  x0, x19
    mov  w1, #']'
    bl   buf_putc
6:  ldr  x24, [x20, #LN_PRED]
    cbz  x24, .Llp_eol
    mov  x0, x19
    ADR_L x1, s_filter
    bl   buf_puts
    mov  x0, x19
    mov  x1, x24
    mov  x2, x22
    bl   lp_print_expr
    b    .Llp_eol

.Llp_join:
    ldr  w9, [x20, #LN_JT]
    ADR_L x10, jt_text
    ldr  x1, [x10, x9, lsl #3]
    mov  x0, x19
    bl   buf_puts
    ldr  x24, [x20, #LN_PRED]
    cbz  x24, .Llp_eol
    mov  x0, x19
    ADR_L x1, s_on
    bl   buf_puts
    b    .Llp_pred
.Llp_filter:
    ldr  x24, [x20, #LN_PRED]
    mov  x0, x19
    mov  w1, #' '
    bl   buf_putc
.Llp_pred:
    mov  x0, x19
    mov  x1, x24
    mov  x2, x22
    bl   lp_print_expr
    b    .Llp_eol

.Llp_agg:                               // " keys=[..] aggs=[..] having .."
    mov  x0, x19
    ADR_L x1, s_keys
    ldr  x2, [x22, #BQ_GROUP]
    ldr  x3, [x22, #BQ_NGROUP]
    mov  x4, #8
    bl   .Llp_list
    mov  x0, x19
    ADR_L x1, s_aggs
    ldr  x2, [x22, #BQ_AGGS]
    ldr  x3, [x22, #BQ_NAGG]
    mov  x4, #8
    bl   .Llp_list
    ldr  x24, [x20, #LN_PRED]
    cbz  x24, .Llp_out
    mov  x0, x19
    ADR_L x1, s_having
    bl   buf_puts
    mov  x0, x19
    mov  x1, x24
    mov  x2, x22
    bl   lp_print_expr
.Llp_out:                               // " out=[..] hidden=[..]"
    mov  x0, x19
    ADR_L x1, s_out
    ldr  x2, [x22, #BQ_OUT]
    add  x2, x2, #OC_EXPR
    ldr  x3, [x22, #BQ_NOUT]
    mov  x4, #OC_SIZE
    bl   .Llp_list
    ldr  x3, [x22, #BQ_NEXTRA]
    cbz  x3, .Llp_eol
    mov  x0, x19
    ADR_L x1, s_hidden
    ldr  x2, [x22, #BQ_EXTRA]
    mov  x4, #8
    bl   .Llp_list
    b    .Llp_eol

.Llp_sort:                              // " keys=N"
    mov  x0, x19
    ADR_L x1, s_nkeys
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x22, #BQ_NORDER]
    bl   buf_put_u64
    b    .Llp_eol
.Llp_limit:                             // " limit=N offset=M" (-1: none)
    mov  x0, x19
    ADR_L x1, s_limit
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x22, #BQ_LIMIT]
    bl   buf_put_i64
    mov  x0, x19
    ADR_L x1, s_offset
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x22, #BQ_OFFSET]
    bl   buf_put_i64

.Llp_eol:
    mov  x0, x19
    mov  w1, #'\n'
    bl   buf_putc
    add  x21, x21, #1                   // inputs, one level deeper
    ldr  w9, [x20, #LN_OP]
    cmp  w9, #LO_SUBQUERY
    b.eq .Llp_subquery
    cmp  w9, #LO_UNION
    b.eq .Llp_union
    ldr  x1, [x20, #LN_LEFT]
    cbz  x1, .Llp_ret
    mov  x0, x19
    mov  x2, x21
    bl   lp_print_at
    ldr  x1, [x20, #LN_RIGHT]
    cbz  x1, .Llp_ret
    mov  x0, x19
    mov  x2, x21
    bl   lp_print_at
    b    .Llp_ret
.Llp_subquery:                          // the subquery's plan, if built
    ldr  x9, [x20, #LN_RV]
    ldr  x23, [x22, #BQ_RVS]
    mov  x10, #RV_SIZE
    madd x23, x9, x10, x23
    ldr  x9, [x23, #RV_SUB]
    ldr  w10, [x23, #RV_KIND]
    cmp  w10, #RVK_CTE
    b.ne 7f
    ldr  x9, [x9, #CD_SP]
7:  ldr  x1, [x9, #SP_LPLAN]
    cbz  x1, .Llp_ret
    mov  x0, x19
    mov  x2, x21
    bl   lp_print_at
    b    .Llp_ret
.Llp_union:
    mov  x23, #0
8:  ldr  x9, [x20, #LN_NKIDS]
    cmp  x23, x9
    b.hs .Llp_ret
    ldr  x9, [x20, #LN_KIDS]
    ldr  x1, [x9, x23, lsl #3]
    mov  x0, x19
    mov  x2, x21
    bl   lp_print_at
    add  x23, x23, #1
    b    8b
.Llp_ret:
    LEAVE 4

// local helper (shares the frame): x0 Buf*, x1 Str*. Clobbers x0-x2, x9.
.Llp_str:
    ldr  x2, [x1, #STR_LEN]
    add  x1, x1, #STR_DATA
    b    buf_put

// local helper (shares the frame): x0 Buf*, x1 label cstr, x2 first Node**
// slot, x3 count, x4 stride: label then "[e1, e2]". Uses x23-x26 (callee-
// saved by this frame; x25/x26 are restored before returning).
.Llp_list:
    stp  x29, x30, [sp, #-48]!
    stp  x25, x26, [sp, #16]
    stp  x23, x24, [sp, #32]
    mov  x23, x2
    mov  x24, x3
    mov  x25, x4
    bl   buf_puts
    mov  x0, x19
    mov  w1, #'['
    bl   buf_putc
    mov  x26, #0
1:  cmp  x26, x24
    b.hs 3f
    cbz  x26, 2f
    mov  x0, x19
    ADR_L x1, s_comma
    bl   buf_puts
2:  mul  x9, x26, x25
    ldr  x1, [x23, x9]
    mov  x0, x19
    mov  x2, x22
    bl   lp_print_expr
    add  x26, x26, #1
    b    1b
3:  mov  x0, x19
    mov  w1, #']'
    bl   buf_putc
    ldp  x23, x24, [sp, #32]
    ldp  x25, x26, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret
ENDF lp_print_at

// =============================================================================
// lp_print_expr(x0 Buf*, x1 Node*, x2 BoundQuery*)
//   literal (JSON value text), rv.column (depth 0) / ^d.column (outer
//   reference), (a op b), NOT a / -a / +a, otherwise NAME(children...)
//   x19 buf, x20 node, x21 bq, x22 index, x23 count
// =============================================================================
FUNC lp_print_expr
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  w9, [x20, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq .Lpx_lit
    cmp  w9, #NK_COL
    b.eq .Lpx_col
    cmp  w9, #NK_BINARY
    b.eq .Lpx_binary
    cmp  w9, #NK_UNARY
    b.eq .Lpx_unary
    cmp  w9, #NK_GKEY
    b.eq .Lpx_gkey
    // NAME(children): the function / aggregate name if known, else the kind
    cmp  w9, #NK_FUNC
    b.eq 1f
    cmp  w9, #NK_AGG
    b.ne 11f
1:  ldr  x1, [x20, #N_NAME]
    cbz  x1, 11f
    mov  x0, x19
    bl   .Lpx_str
    b    2f
11: ldr  w9, [x20, #N_KIND]
    ADR_L x10, nk_names
    cmp  w9, #NK_GKEY
    csel w9, w9, wzr, ls
    ldr  x1, [x10, x9, lsl #3]
    mov  x0, x19
    bl   buf_puts
2:  mov  x0, x19
    mov  w1, #'('
    bl   buf_putc
    mov  x0, x20
    bl   expr_nchildren
    mov  x23, x0
    mov  x22, #0
3:  cmp  x22, x23
    b.hs 4f
    cbz  x22, 31f
    mov  x0, x19
    ADR_L x1, s_comma
    bl   buf_puts
31: mov  x0, x20
    mov  x1, x22
    bl   expr_child_slot
    ldr  x1, [x0]
    mov  x0, x19
    mov  x2, x21
    bl   lp_print_expr
    add  x22, x22, #1
    b    3b
4:  mov  x0, x19
    mov  w1, #')'
    bl   buf_putc
    LEAVE 3

.Lpx_lit:
    ldr  x1, [x20, #N_VAL]
    ldr  w9, [x20, #N_FLAGS]
    and  x2, x9, #NF_NULL
    ldr  w3, [x20, #N_TYPE]
    mov  x0, x19
    bl   write_value_json
    LEAVE 3
.Lpx_col:
    ldr  w9, [x20, #N_OP]               // outer depth
    cbnz w9, 5f
    ldr  x9, [x20, #N_B]                // rv.column of this level
    ldr  x22, [x21, #BQ_RVS]
    mov  x10, #RV_SIZE
    madd x22, x9, x10, x22
    ldr  x1, [x22, #RV_NAME]
    mov  x0, x19
    bl   .Lpx_str
    mov  x0, x19
    mov  w1, #'.'
    bl   buf_putc
    ldr  x9, [x22, #RV_TABLE]
    ldr  x9, [x9, #TBL_COLS]
    ldr  x10, [x20, #N_VAL]
    add  x9, x9, x10, lsl #5
    ldr  x1, [x9, #COL_NAME]
    mov  x0, x19
    bl   .Lpx_str
    LEAVE 3
5:  mov  x0, x19                        // ^depth.name
    mov  w1, #'^'
    bl   buf_putc
    mov  x0, x19
    ldr  w1, [x20, #N_OP]
    bl   buf_put_u64
    mov  x0, x19
    mov  w1, #'.'
    bl   buf_putc
    ldr  x1, [x20, #N_NAME]
    cbz  x1, 6f
    mov  x0, x19
    bl   .Lpx_str
6:  LEAVE 3
.Lpx_gkey:
    mov  x0, x19
    ADR_L x1, s_gkey
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #N_VAL]
    bl   buf_put_u64
    LEAVE 3
.Lpx_binary:
    mov  x0, x19
    mov  w1, #'('
    bl   buf_putc
    mov  x0, x19
    ldr  x1, [x20, #N_A]
    mov  x2, x21
    bl   lp_print_expr
    ldr  w9, [x20, #N_OP]
    ADR_L x10, op_text
    sub  w9, w9, #OP_ADD
    cmp  w9, #(OP_OR - OP_ADD)
    b.ls 7f
    mov  w9, #(OP_OR - OP_ADD + 1)      // unknown operator
7:  ldr  x1, [x10, x9, lsl #3]
    mov  x0, x19
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #N_B]
    mov  x2, x21
    bl   lp_print_expr
    mov  x0, x19
    mov  w1, #')'
    bl   buf_putc
    LEAVE 3
.Lpx_unary:
    ldr  w9, [x20, #N_OP]
    ADR_L x1, s_not
    cmp  w9, #OP_NOT
    b.eq 8f
    ADR_L x1, s_neg
    cmp  w9, #OP_NEG
    b.eq 8f
    ADR_L x1, s_pos
8:  mov  x0, x19
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #N_A]
    mov  x2, x21
    bl   lp_print_expr
    LEAVE 3

// local helper: x0 Buf*, x1 Str*
.Lpx_str:
    ldr  x2, [x1, #STR_LEN]
    add  x1, x1, #STR_DATA
    b    buf_put
ENDF lp_print_expr

    .section .rodata
    .p2align 3
lo_names:
    .quad s_unknown, s_scan, s_subscan, s_values, s_filtername, s_join
    .quad s_aggregate, s_project, s_distinct, s_sort, s_limitname, s_union
jt_text:
    .quad s_unknown, s_inner, s_left, s_cross
nk_names:                               // indexed by NK_* (0..NK_GKEY)
    .quad s_unknown, s_unknown, s_unknown, s_unknown, s_unknown
    .quad s_isnull, s_cast, s_func, s_agg, s_case, s_between
    .quad s_in, s_insub, s_like, s_exists, s_subq, s_unknown, s_unknown
op_text:                                // OP_ADD .. OP_OR, then "unknown"
    .quad s_add, s_sub, s_mul, s_div, s_mod, s_concat, s_bad, s_bad
    .quad s_bad, s_bad, s_eq, s_ne, s_lt, s_le, s_gt, s_ge, s_bad, s_bad
    .quad s_bad, s_bad, s_and, s_or, s_bad
s_unknown:   .asciz "?"
s_scan:      .asciz "Scan"
s_subscan:   .asciz "SubqueryScan"
s_values:    .asciz "Values"
s_filter:    .asciz " filter="
s_filtername: .asciz "Filter"
s_limitname: .asciz "Limit"
s_func:      .asciz "FUNC"
s_agg:       .asciz "AGG"
s_join:      .asciz "Join"
s_aggregate: .asciz "Aggregate"
s_project:   .asciz "Project"
s_distinct:  .asciz "Distinct"
s_sort:      .asciz "Sort"
s_limit:     .asciz " limit="
s_union:     .asciz "UnionAll"
s_inner:     .asciz " INNER"
s_left:      .asciz " LEFT"
s_cross:     .asciz " CROSS"
s_indent:    .asciz "  "
s_as:        .asciz " AS "
s_columns:   .asciz " columns=["
s_on:        .asciz " on "
s_keys:      .asciz " keys="
s_aggs:      .asciz " aggs="
s_having:    .asciz " having "
s_out:       .asciz " out="
s_hidden:    .asciz " hidden="
s_nkeys:     .asciz " keys="
s_offset:    .asciz " offset="
s_comma:     .asciz ", "
s_gkey:      .asciz "key#"
s_isnull:    .asciz "ISNULL"
s_cast:      .asciz "CAST"
s_case:      .asciz "CASE"
s_between:   .asciz "BETWEEN"
s_in:        .asciz "IN"
s_insub:     .asciz "IN_SUBQUERY"
s_like:      .asciz "LIKE"
s_exists:    .asciz "EXISTS"
s_subq:      .asciz "SUBQUERY"
s_not:       .asciz "NOT "
s_neg:       .asciz "-"
s_pos:       .asciz "+"
s_add:       .asciz " + "
s_sub:       .asciz " - "
s_mul:       .asciz " * "
s_div:       .asciz " / "
s_mod:       .asciz " % "
s_concat:    .asciz " || "
s_eq:        .asciz " = "
s_ne:        .asciz " <> "
s_lt:        .asciz " < "
s_le:        .asciz " <= "
s_gt:        .asciz " > "
s_ge:        .asciz " >= "
s_and:       .asciz " AND "
s_or:        .asciz " OR "
s_bad:       .asciz " ? "
    .text

    NOTE_GNU_STACK
