// =============================================================================
// plan.S — query planning driver, EXPLAIN output, planner helpers.
//
//   plan_statement(x0 root BoundQuery*) -> x0 PlanNode*   plans the statement
//       and every SubPlan in BQ_SPV (SP_LPLAN logical, SP_PLAN physical)
//   plan_query(x0 BoundQuery*) -> x0 PlanNode*, x1 LogicalNode*
//       one query level:  lp_build (logical.S)  ->  optimize (optimize.S,
//       rule_*.S; no rule with "optimize": false)  ->  phys_plan (physical.S)
//   plan_explain(x0 Buf*, x1 PlanNode*)    writes the physical plan as JSON
//                                          (indexes-and-planning.md §4)
//
// Helpers shared by the logical rules, the physical planner and access.S:
//   split_conj, and_append, pvec_push, expr_rvmask.
//
// Planner inputs: the execution options of the request (thread-local,
// written by protocol.S parse_exec_opts): g_opt_mode, g_opt_join,
// g_opt_threads, g_opt_optimize (and access.S g_use_indexes).
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define MASK_ALL   -1              // conjunct must stay where it is

    TDATA
    .p2align 3
    .global g_opt_threads, g_opt_mode, g_opt_join, g_opt_optimize
g_opt_threads:  .quad 1
g_opt_mode:     .word XM_AUTO
g_opt_join:     .word XJ_AUTO
g_opt_optimize: .word 1

    .text

// =============================================================================
// plan_statement(x0 root BoundQuery*) -> x0 root PlanNode*
//   x19 root bq, x20 SubPlan vector, x21 index, x22 SubPlan*
// =============================================================================
FUNC plan_statement
    ENTER 2
    mov  x19, x0
    ldr  x20, [x19, #BQ_SPV]
    mov  x21, #0
1:  cbz  x20, 2f
    ldr  x9, [x20]                      // n
    cmp  x21, x9
    b.hs 2f
    ldr  x9, [x20, #16]
    ldr  x22, [x9, x21, lsl #3]
    ldr  x0, [x22, #SP_BQ]
    bl   plan_query
    str  x0, [x22, #SP_PLAN]
    str  x1, [x22, #SP_LPLAN]
    add  x21, x21, #1
    b    1b
2:  mov  x0, x19
    bl   plan_query
    LEAVE 2
ENDF plan_statement

// plan_query(x0 BoundQuery*) -> x0 physical PlanNode*, x1 LogicalNode*
//   x19 logical plan
FUNC plan_query
    ENTER 1
    bl   lp_build
    bl   optimize
    mov  x19, x0
    bl   phys_plan
    mov  x1, x19
    LEAVE 1
ENDF plan_query

// =============================================================================
// Expression helpers
// split_conj(x0 Vec*, x1 Node* or 0) — appends the AND-conjuncts of x1
//   x19 vec, x20 node
// =============================================================================
FUNC split_conj
    GUARD_TICK                          // CR-6: recursive
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    cbz  x20, 2f
    ldr  w9, [x20, #N_KIND]
    cmp  w9, #NK_BINARY
    b.ne 1f
    ldr  w9, [x20, #N_OP]
    cmp  w9, #OP_AND
    b.ne 1f
    mov  x0, x19
    ldr  x1, [x20, #N_A]
    bl   split_conj
    mov  x0, x19
    ldr  x1, [x20, #N_B]
    bl   split_conj
    b    2f
1:  mov  x0, x19
    mov  x1, x20
    bl   pvec_push
2:  LEAVE 2
ENDF split_conj

// and_append(x0 Node* or 0, x1 Node*) -> x0 (x0 AND x1), or x1 if x0 is 0
//   x19 a, x20 b
FUNC and_append
    cbnz x0, 1f
    mov  x0, x1
    ret
1:  ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x0, #N_SIZE
    bl   arena_zalloc
    mov  w9, #NK_BINARY
    str  w9, [x0, #N_KIND]
    mov  w9, #OP_AND
    str  w9, [x0, #N_OP]
    mov  w9, #T_BOOL
    str  w9, [x0, #N_TYPE]
    str  x19, [x0, #N_A]
    str  x20, [x0, #N_B]
    LEAVE 2
ENDF and_append

// pvec_push(x0 Vec* {n, cap, data}, x1 item)
//   x19 vec, x20 item, x21 new cap
FUNC pvec_push
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldp  x9, x10, [x19]
    cmp  x9, x10
    b.lo 1f
    lsl  x21, x10, #1
    cmp  x21, #8
    mov  x11, #8
    csel x21, x11, x21, lo
    lsl  x0, x21, #3
    bl   arena_alloc
    ldr  x1, [x19, #16]
    ldr  x2, [x19]
    lsl  x2, x2, #3
    str  x0, [x19, #16]
    str  x21, [x19, #8]
    bl   memcpy
1:  ldr  x9, [x19]
    ldr  x10, [x19, #16]
    str  x20, [x10, x9, lsl #3]
    add  x9, x9, #1
    str  x9, [x19]
    LEAVE 3
ENDF pvec_push

// =============================================================================
// expr_rvmask(x0 Node*) -> x0 bitmask of this query's range variables used
// (column references of depth 0). A correlated subquery yields MASK_ALL so
// that its conjunct is evaluated only where the whole tuple is available.
//   x19 node, x20 mask, x21 index, x22 count
// =============================================================================
FUNC expr_rvmask
    GUARD_TICK                          // CR-6: recursive
    ENTER 3
    mov  x19, x0
    mov  x20, #0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_COL
    b.eq .Lrm_col
    cmp  w9, #NK_SUBQ
    b.eq .Lrm_sub
    cmp  w9, #NK_EXISTS
    b.eq .Lrm_sub
    cmp  w9, #NK_INSUB
    b.ne .Lrm_children
.Lrm_sub:
    ldr  x9, [x19, #N_C]
    ldr  x9, [x9, #SP_BQ]
    ldr  x9, [x9, #BQ_CORR]
    cbz  x9, .Lrm_children
    mov  x20, #MASK_ALL
    b    .Lrm_ret
.Lrm_children:
    mov  x0, x19
    bl   expr_nchildren
    mov  x22, x0
    mov  x21, #0
1:  cmp  x21, x22
    b.hs .Lrm_ret
    mov  x0, x19
    mov  x1, x21
    bl   expr_child_slot
    ldr  x0, [x0]
    bl   expr_rvmask
    orr  x20, x20, x0
    add  x21, x21, #1
    b    1b
.Lrm_col:
    ldr  w9, [x19, #N_OP]
    cbnz w9, .Lrm_ret
    ldr  x9, [x19, #N_B]
    mov  x10, #1
    lsl  x20, x10, x9
.Lrm_ret:
    mov  x0, x20
    LEAVE 3
ENDF expr_rvmask

// =============================================================================
// EXPLAIN: plan_explain(x0 Buf*, x1 PlanNode*)
// {"op":…,"children":[…]} plus node properties. Scans of derived tables and
// CTEs are shown as "SubqueryScan" with the subquery's plan as child.
//   x19 buf, x20 node, x21 bq, x22 index / scratch, x23 RV*
// =============================================================================
FUNC plan_explain
    GUARD_TICK                          // CR-6: recursive
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x20, #PN_BQ]
    mov  x0, x19
    ADR_L x1, ex_op
    bl   buf_puts
    ldr  w9, [x20, #PN_OP]
    ADR_L x10, op_names
    ldr  x1, [x10, x9, lsl #3]
    cmp  w9, #PO_SCAN
    b.ne 1f
    ldr  x22, [x20, #PN_RV]             // base table or subquery?
    ldr  x23, [x21, #BQ_RVS]
    mov  x10, #RV_SIZE
    madd x23, x22, x10, x23
    ldr  w10, [x23, #RV_KIND]
    cmp  w10, #RVK_BASE
    b.eq 11f
    ADR_L x1, s_subscan
    b    1f
11: ldr  x9, [x20, #PN_IDX]
    cbz  x9, 1f
    ADR_L x1, s_indexscan
1:  mov  x0, x19
    bl   buf_puts
    mov  x0, x19
    mov  w1, #'"'
    bl   buf_putc
    ldr  w9, [x20, #PN_OP]
    cmp  w9, #PO_SCAN
    b.eq .Lpe_scan
    cmp  w9, #PO_HASHJOIN
    b.eq .Lpe_join
    cmp  w9, #PO_NLJOIN
    b.eq .Lpe_join
    cmp  w9, #PO_MERGEJOIN
    b.eq .Lpe_join
    cmp  w9, #PO_PROJECT
    b.eq .Lpe_project
    cmp  w9, #PO_AGGREGATE
    b.eq .Lpe_project
    cmp  w9, #PO_UNION
    b.eq .Lpe_union
    b    .Lpe_children

.Lpe_union:                             // "children": the branch plans
    mov  x0, x19
    ADR_L x1, ex_children
    bl   buf_puts
    mov  x22, #0
8:  ldr  x9, [x20, #PN_NKIDS]
    cmp  x22, x9
    b.hs .Lpe_subplans
    cbz  x22, 81f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
81: ldr  x9, [x20, #PN_KIDS]
    mov  x0, x19
    ldr  x1, [x9, x22, lsl #3]
    bl   plan_explain
    add  x22, x22, #1
    b    8b

.Lpe_scan:
    ldr  w10, [x23, #RV_KIND]
    cmp  w10, #RVK_BASE
    b.ne .Lpe_subscan
    mov  x0, x19                        // "table":name
    ADR_L x1, ex_table
    bl   buf_puts
    ldr  x9, [x23, #RV_TABLE]
    ldr  x9, [x9, #TBL_NAME]
    mov  x0, x19
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   buf_put_jstr
    mov  x0, x19                        // "alias":name
    ADR_L x1, ex_alias
    bl   buf_puts
    ldr  x9, [x23, #RV_NAME]
    mov  x0, x19
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   buf_put_jstr
    mov  x0, x19                        // "columns":[columns read]
    ADR_L x1, ex_columns
    bl   buf_puts
    mov  x22, #0
    mov  x24, #0                        // items written
2:  ldr  x9, [x23, #RV_TABLE]
    ldr  x10, [x9, #TBL_NCOLS]
    cmp  x22, x10
    b.hs 4f
    ldr  x10, [x20, #PN_COLS]
    ldrb w10, [x10, x22]
    cbz  w10, 3f
    cbz  x24, 21f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
21: add  x24, x24, #1
    ldr  x9, [x23, #RV_TABLE]
    ldr  x9, [x9, #TBL_COLS]
    add  x9, x9, x22, lsl #5
    ldr  x9, [x9, #COL_NAME]
    mov  x0, x19
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   buf_put_jstr
3:  add  x22, x22, #1
    b    2b
4:  mov  x0, x19
    mov  w1, #']'
    bl   buf_putc
    bl   .Lpe_filter_prop
    ldr  x22, [x20, #PN_IDX]            // index scan: "index", "kind"
    cbz  x22, 41f
    mov  x0, x19
    ADR_L x1, ex_index
    bl   buf_puts
    ldr  x9, [x22, #IX_NAME]
    mov  x0, x19
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   buf_put_jstr
    ldr  w9, [x22, #IX_KIND]
    ADR_L x1, ex_kind_hash
    cmp  w9, #IXK_HASH
    b.eq 40f
    ADR_L x1, ex_kind_btree
40: mov  x0, x19
    bl   buf_puts
41: ldr  x9, [x23, #RV_TABLE]           // PQCF row groups
    ldr  x9, [x9, #TBL_NRG]
    cbz  x9, 42f
    mov  x0, x19
    ADR_L x1, ex_rgs
    bl   buf_puts
    ldr  x9, [x23, #RV_TABLE]
    mov  x0, x19
    ldr  x1, [x9, #TBL_NRG]
    bl   buf_put_u64
    mov  x0, x19
    ADR_L x1, ex_rgskip
    bl   buf_puts
    mov  x0, x19
    ldr  w1, [x20, #PN_RGSKIP]
    bl   buf_put_u64
42: bl   .Lpe_est_prop
    mov  x0, x19
    ADR_L x1, ex_children
    bl   buf_puts
    mov  x22, #0
    b    .Lpe_subplans

.Lpe_subscan:
    mov  x0, x19
    ADR_L x1, ex_alias
    bl   buf_puts
    ldr  x9, [x23, #RV_NAME]
    mov  x0, x19
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   buf_put_jstr
    bl   .Lpe_filter_prop
    mov  x0, x19
    ADR_L x1, ex_children
    bl   buf_puts
    ldr  x9, [x23, #RV_SUB]
    ldr  w10, [x23, #RV_KIND]
    cmp  w10, #RVK_CTE
    b.ne 5f
    ldr  x9, [x9, #CD_SP]
5:  mov  x0, x19
    ldr  x1, [x9, #SP_PLAN]
    bl   plan_explain
    mov  x22, #1
    b    .Lpe_subplans

.Lpe_join:
    mov  x0, x19
    ADR_L x1, ex_jtype
    bl   buf_puts
    ldr  w9, [x20, #PN_JT]
    ADR_L x10, jt_names
    ldr  x1, [x10, x9, lsl #3]
    mov  x0, x19
    bl   buf_puts
    mov  x0, x19
    ADR_L x1, ex_nkeys
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #PN_NKEYS]
    bl   buf_put_u64
    bl   .Lpe_est_prop
    b    .Lpe_children

.Lpe_project:
    mov  x0, x19
    ADR_L x1, ex_columns
    bl   buf_puts
    mov  x22, #0
6:  ldr  x9, [x21, #BQ_NOUT]
    cmp  x22, x9
    b.hs 7f
    cbz  x22, 61f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
61: ldr  x9, [x21, #BQ_OUT]
    add  x9, x9, x22, lsl #5
    ldr  x9, [x9, #OC_NAME]
    mov  x0, x19
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   buf_put_jstr
    add  x22, x22, #1
    b    6b
7:  mov  x0, x19
    mov  w1, #']'
    bl   buf_putc

.Lpe_children:
    mov  x0, x19
    ADR_L x1, ex_children
    bl   buf_puts
    mov  x22, #0
    ldr  x1, [x20, #PN_LEFT]
    cbz  x1, .Lpe_subplans
    mov  x0, x19
    bl   plan_explain
    mov  x22, #1
    ldr  x1, [x20, #PN_RIGHT]
    cbz  x1, .Lpe_subplans
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
    mov  x0, x19
    ldr  x1, [x20, #PN_RIGHT]
    bl   plan_explain
    mov  x22, #2
.Lpe_subplans:                          // plans of expression subqueries
    mov  x0, x19
    mov  x1, x20
    mov  x2, x22
    bl   pe_subplans
    mov  x0, x19
    mov  w1, #']'
    bl   buf_putc
.Lpe_close:
    mov  x0, x19
    mov  w1, #'}'
    bl   buf_putc
    LEAVE 4

// local helper (shares the frame): ,"filter":true if the scan has a
// pushed-down predicate. Clobbers x0-x2, x9.
.Lpe_filter_prop:
    ldr  x9, [x20, #PN_EXPR]
    cbz  x9, 9f
    stp  x29, x30, [sp, #-16]!
    mov  x0, x19
    ADR_L x1, ex_filter
    bl   buf_puts
    ldp  x29, x30, [sp], #16
9:  ret

// local helper: ,"estimated_rows":N for tuple operators. Clobbers x0-x2, x9.
.Lpe_est_prop:
    stp  x29, x30, [sp, #-16]!
    mov  x0, x19
    ADR_L x1, ex_est
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #PN_EST]
    bl   buf_put_u64
    ldp  x29, x30, [sp], #16
    ret
ENDF plan_explain

// =============================================================================
// pe_subplans(x0 Buf*, x1 PlanNode*, x2 children written) -> x0 children
// Appends the plans of the subqueries used in the node's expressions.
//   x19 buf, x20 node, x21 count, x22 bq, x23 index
// =============================================================================
LFUNC pe_subplans
    GUARD_TICK                          // CR-6: recursive
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x22, [x20, #PN_BQ]
    mov  x0, x19
    ldr  x1, [x20, #PN_EXPR]
    mov  x2, x21
    bl   pe_expr
    mov  x21, x0
    ldr  w9, [x20, #PN_OP]
    cmp  w9, #PO_HASHJOIN
    b.eq .Lps_keys
    cmp  w9, #PO_MERGEJOIN
    b.eq .Lps_keys
    cmp  w9, #PO_NLJOIN
    b.eq .Lps_keys
    cmp  w9, #PO_PROJECT
    b.eq .Lps_out
    cmp  w9, #PO_AGGREGATE
    b.eq .Lps_out
    b    .Lps_end
.Lps_keys:
    mov  x23, #0
1:  ldr  x9, [x20, #PN_NKEYS]
    cmp  x23, x9
    b.hs .Lps_end
    ldr  x9, [x20, #PN_LKEYS]
    ldr  x1, [x9, x23, lsl #3]
    mov  x0, x19
    mov  x2, x21
    bl   pe_expr
    ldr  x9, [x20, #PN_RKEYS]
    ldr  x1, [x9, x23, lsl #3]
    mov  x2, x0
    mov  x0, x19
    bl   pe_expr
    mov  x21, x0
    add  x23, x23, #1
    b    1b
.Lps_out:
    mov  x23, #0
2:  ldr  x9, [x22, #BQ_NOUT]
    cmp  x23, x9
    b.hs 3f
    ldr  x9, [x22, #BQ_OUT]
    add  x9, x9, x23, lsl #5
    ldr  x1, [x9, #OC_EXPR]
    mov  x0, x19
    mov  x2, x21
    bl   pe_expr
    mov  x21, x0
    add  x23, x23, #1
    b    2b
3:  mov  x23, #0
4:  ldr  x9, [x22, #BQ_NEXTRA]
    cmp  x23, x9
    b.hs 5f
    ldr  x9, [x22, #BQ_EXTRA]
    ldr  x1, [x9, x23, lsl #3]
    mov  x0, x19
    mov  x2, x21
    bl   pe_expr
    mov  x21, x0
    add  x23, x23, #1
    b    4b
5:  ldr  w9, [x20, #PN_OP]
    cmp  w9, #PO_AGGREGATE
    b.ne .Lps_end
    mov  x23, #0
6:  ldr  x9, [x22, #BQ_NGROUP]
    cmp  x23, x9
    b.hs .Lps_end
    ldr  x9, [x22, #BQ_GROUP]
    ldr  x1, [x9, x23, lsl #3]
    mov  x0, x19
    mov  x2, x21
    bl   pe_expr
    mov  x21, x0
    add  x23, x23, #1
    b    6b
.Lps_end:
    mov  x0, x21
    LEAVE 4
ENDF pe_subplans

// pe_expr(x0 Buf*, x1 Node* or 0, x2 children written) -> x0 children
//   x19 buf, x20 node, x21 count, x22 index, x23 child count
LFUNC pe_expr
    GUARD_TICK                          // CR-6: recursive
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    cbz  x20, 9f
    ldr  w9, [x20, #N_KIND]
    cmp  w9, #NK_SUBQ
    b.eq 1f
    cmp  w9, #NK_EXISTS
    b.eq 1f
    cmp  w9, #NK_INSUB
    b.ne 2f
1:  cbz  x21, 11f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
11: ldr  x9, [x20, #N_C]
    mov  x0, x19
    ldr  x1, [x9, #SP_PLAN]
    bl   plan_explain
    add  x21, x21, #1
2:  mov  x0, x20
    bl   expr_nchildren
    mov  x23, x0
    mov  x22, #0
3:  cmp  x22, x23
    b.hs 9f
    mov  x0, x20
    mov  x1, x22
    bl   expr_child_slot
    ldr  x1, [x0]
    mov  x0, x19
    mov  x2, x21
    bl   pe_expr
    mov  x21, x0
    add  x22, x22, #1
    b    3b
9:  mov  x0, x21
    LEAVE 4
ENDF pe_expr

    .section .rodata
    .p2align 3
op_names:
    .quad s_unknown, s_scan, s_values, s_filter, s_join, s_hashjoin
    .quad s_nljoin, s_aggregate, s_project, s_distinct, s_sort, s_limit
    .quad s_mergejoin, s_union
jt_names:
    .quad s_unknown, s_inner, s_left, s_cross
s_unknown:   .asciz "Unknown"
s_scan:      .asciz "TableScan"
s_subscan:   .asciz "SubqueryScan"
s_indexscan: .asciz "IndexScan"
s_values:    .asciz "Values"
s_filter:    .asciz "Filter"
s_join:      .asciz "Join"
s_hashjoin:  .asciz "HashJoin"
s_nljoin:    .asciz "NestedLoopJoin"
s_mergejoin: .asciz "MergeJoin"
s_union:     .asciz "UnionAll"
s_aggregate: .asciz "Aggregate"
s_project:   .asciz "Project"
s_distinct:  .asciz "Distinct"
s_sort:      .asciz "Sort"
s_limit:     .asciz "Limit"
s_inner:     .asciz "\"INNER\""
s_left:      .asciz "\"LEFT\""
s_cross:     .asciz "\"CROSS\""
ex_op:          .asciz "{\"op\":\""
ex_table:       .asciz ",\"table\":"
ex_alias:       .asciz ",\"alias\":"
ex_columns:     .asciz ",\"columns\":["
ex_filter:      .asciz ",\"filter\":true"
ex_jtype:       .asciz ",\"join_type\":"
ex_nkeys:       .asciz ",\"hash_keys\":"
ex_children:    .asciz ",\"children\":["
ex_index:       .asciz ",\"index\":"
ex_kind_hash:   .asciz ",\"kind\":\"HASH\""
ex_kind_btree:  .asciz ",\"kind\":\"BTREE\""
ex_rgs:         .asciz ",\"row_groups\":"
ex_rgskip:      .asciz ",\"row_groups_skipped\":"
ex_est:         .asciz ",\"estimated_rows\":"
    .text

    NOTE_GNU_STACK
