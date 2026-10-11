// =============================================================================
// plan.S — query planning: logical plan, physical plan, EXPLAIN output.
//
//   plan_statement(x0 root BoundQuery*) -> x0 PlanNode*   plans the statement
//                                          and every SubPlan in BQ_SPV
//   plan_explain(x0 Buf*, x1 PlanNode*)    writes the plan as JSON
//                                          (indexes-and-planning.md §4)
//
// Stage 1, logical plan (lp_*): a direct translation of the bound query:
//     Limit? <- Sort? <- Distinct? <- (Aggregate | Project)
//            <- Filter(WHERE)? <- FROM tree (Scan / Join) | Values
// Stage 2, physical plan (pp_*), rewrites the logical plan in place:
//   * predicate pushdown: WHERE conjuncts move to the lowest scan or join
//     that covers the range variables they reference (never below the
//     NULL-padded side of a LEFT JOIN); a conjunct over two sides of an inner
//     or cross join becomes part of that join's condition;
//   * join conditions are split again: single-side conjuncts move into the
//     children (only the right child for LEFT JOIN), equality conjuncts
//     between the two sides become hash keys, the rest stays as residual;
//   * join algorithm: HashJoin when there are equi keys, else NestedLoopJoin;
//   * column pruning: scans read only referenced columns (RV_USED, collected
//     by the binder) — reported by EXPLAIN as the TableScan column list.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define MASK_ALL   -1              // conjunct must stay where it is

    .text

// =============================================================================
// pn_new(w0 op, x1 BoundQuery*, x2 left child) -> x0 PlanNode*
// The new node inherits the rv range of its child.
// =============================================================================
LFUNC pn_new
    ENTER 2
    mov  w19, w0
    stp  x1, x2, [sp, #-16]!
    mov  x0, #PN_SIZE
    bl   arena_zalloc
    ldp  x1, x2, [sp], #16
    str  w19, [x0, #PN_OP]
    str  x1, [x0, #PN_BQ]
    str  x2, [x0, #PN_LEFT]
    cbz  x2, 1f
    ldr  x9, [x2, #PN_LO]               // PN_LO / PN_HI
    str  x9, [x0, #PN_LO]
1:  LEAVE 2
ENDF pn_new

// =============================================================================
// plan_statement(x0 root BoundQuery*) -> x0 root PlanNode*
//   x19 root bq, x20 SubPlan vector, x21 index
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
    ldr  x22, [x9, x21, lsl #3]         // SubPlan*  (x22 saved by ENTER 2)
    ldr  x0, [x22, #SP_BQ]
    bl   plan_query
    str  x0, [x22, #SP_PLAN]
    add  x21, x21, #1
    b    1b
2:  mov  x0, x19
    bl   plan_query
    LEAVE 2
ENDF plan_statement

// plan_query(x0 BoundQuery*) -> x0 physical PlanNode*
LFUNC plan_query
    ENTER 1
    bl   lp_build
    mov  x19, x0
    bl   pp_rewrite
    mov  x0, x19
    LEAVE 1
ENDF plan_query

// =============================================================================
// Logical plan
// lp_build(x0 BoundQuery*) -> x0 PlanNode*
//   x19 bq, x20 current top node
// =============================================================================
LFUNC lp_build
    ENTER 2
    mov  x19, x0
    ldr  x1, [x19, #BQ_FROM]
    cbz  x1, 1f
    bl   lp_from
    mov  x20, x0
    b    2f
1:  mov  w0, #PO_VALUES
    mov  x1, x19
    mov  x2, #0
    bl   pn_new
    mov  x20, x0
2:  ldr  x9, [x19, #BQ_WHERE]
    cbz  x9, 3f
    mov  w0, #PO_FILTER
    mov  x1, x19
    mov  x2, x20
    bl   pn_new
    ldr  x9, [x19, #BQ_WHERE]
    str  x9, [x0, #PN_EXPR]
    mov  x20, x0
3:  mov  w0, #PO_PROJECT
    ldr  x9, [x19, #BQ_ISAGG]
    cbz  x9, 4f
    mov  w0, #PO_AGGREGATE
4:  mov  x1, x19
    mov  x2, x20
    bl   pn_new
    ldr  x9, [x19, #BQ_HAVING]
    str  x9, [x0, #PN_EXPR]
    mov  x20, x0
    ldr  x9, [x19, #BQ_DISTINCT]
    cbz  x9, 5f
    mov  w0, #PO_DISTINCT
    mov  x1, x19
    mov  x2, x20
    bl   pn_new
    mov  x20, x0
5:  ldr  x9, [x19, #BQ_NORDER]
    cbz  x9, 6f
    mov  w0, #PO_SORT
    mov  x1, x19
    mov  x2, x20
    bl   pn_new
    mov  x20, x0
6:  ldr  x9, [x19, #BQ_LIMIT]
    ldr  x10, [x19, #BQ_OFFSET]
    cmn  x9, #1
    ccmp x10, #0, #0, eq                // no LIMIT and OFFSET 0: no node
    b.eq 7f
    mov  w0, #PO_LIMIT
    mov  x1, x19
    mov  x2, x20
    bl   pn_new
    mov  x20, x0
7:  mov  x0, x20
    LEAVE 2
ENDF lp_build

// lp_from(x0 BoundQuery*, x1 BoundFrom*) -> x0 PlanNode* (Scan / Join tree)
//   x19 bq, x20 BoundFrom*, x21 node
LFUNC lp_from
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x20, #BF_KIND]
    cmp  w9, #BFK_JOIN
    b.eq 1f
    mov  w0, #PO_SCAN
    mov  x1, x19
    mov  x2, #0
    bl   pn_new
    ldr  x9, [x20, #BF_RV]
    str  x9, [x0, #PN_RV]
    ldr  x9, [x20, #BF_LO]
    str  x9, [x0, #PN_LO]
    LEAVE 3
1:  mov  w0, #PO_JOIN
    mov  x1, x19
    mov  x2, #0
    bl   pn_new
    mov  x21, x0
    ldr  w9, [x20, #BF_JT]
    str  w9, [x21, #PN_JT]
    ldr  x9, [x20, #BF_ON]
    str  x9, [x21, #PN_EXPR]
    ldr  x9, [x20, #BF_LO]
    str  x9, [x21, #PN_LO]
    mov  x0, x19
    ldr  x1, [x20, #BF_LEFT]
    bl   lp_from
    str  x0, [x21, #PN_LEFT]
    mov  x0, x19
    ldr  x1, [x20, #BF_RIGHT]
    bl   lp_from
    str  x0, [x21, #PN_RIGHT]
    mov  x0, x21
    LEAVE 3
ENDF lp_from

// =============================================================================
// Physical plan
// pp_rewrite(x0 PlanNode* root) — in place.
// Finds the FROM tree (below an optional WHERE filter), pushes the WHERE
// conjuncts down, then rewrites every join.
//   x19 filter node or 0, x20 FROM root, x21 conjunct list (Vec), x22 index,
//   x23 conjunct, x24 remaining predicate
// =============================================================================
LFUNC pp_rewrite
    ENTER 4
    sub  sp, sp, #32                    // Vec of conjuncts: n, cap, data
    mov  x9, x0                         // descend to Aggregate / Project
1:  ldr  w10, [x9, #PN_OP]
    cmp  w10, #PO_AGGREGATE
    b.eq 2f
    cmp  w10, #PO_PROJECT
    b.eq 2f
    ldr  x9, [x9, #PN_LEFT]
    b    1b
2:  ldr  x20, [x9, #PN_LEFT]
    mov  x19, #0
    ldr  w10, [x20, #PN_OP]
    cmp  w10, #PO_FILTER
    b.ne 3f
    mov  x19, x20
    ldr  x20, [x19, #PN_LEFT]
3:  ldr  w10, [x20, #PN_OP]
    cmp  w10, #PO_VALUES
    b.eq .Lpp_end
    cbz  x19, .Lpp_joins
    // ---- WHERE pushdown --------------------------------------------------
    stp  xzr, xzr, [sp]
    str  xzr, [sp, #16]
    mov  x0, sp
    ldr  x1, [x19, #PN_EXPR]
    bl   split_conj
    mov  x24, #0
    mov  x22, #0
4:  ldr  x9, [sp]
    cmp  x22, x9
    b.hs 6f
    ldr  x9, [sp, #16]
    ldr  x23, [x9, x22, lsl #3]
    mov  x0, x23
    bl   expr_rvmask
    cbz  x0, 5f                         // constant / outer only: keep
    mov  x2, x0
    mov  x0, x20
    mov  x1, x23
    bl   push_conj
    cbnz w0, 41f
5:  mov  x0, x24                        // keep in the filter
    mov  x1, x23
    bl   and_append
    mov  x24, x0
41: add  x22, x22, #1
    b    4b
6:  str  x24, [x19, #PN_EXPR]
    cbnz x24, .Lpp_joins
    // filter became empty: unlink it (its parent is the Aggregate/Project)
    // the filter became empty: overwrite it with its child (the FROM root)
    mov  x0, x19
    ldr  x1, [x19, #PN_LEFT]
    mov  x2, #PN_SIZE
    bl   memcpy
    mov  x20, x19                       // the FROM root now lives in x19
.Lpp_joins:
    mov  x0, x20
    bl   pp_joins
.Lpp_end:
    add  sp, sp, #32
    LEAVE 4
ENDF pp_rewrite

// =============================================================================
// push_conj(x0 PlanNode* (scan/join subtree), x1 conjunct, x2 rv mask)
//   -> w0 1 if the conjunct was absorbed by the subtree
//   x19 node, x20 conjunct, x21 mask, x22 left mask, x23 right mask
// =============================================================================
LFUNC push_conj
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_SCAN
    b.ne 1f
    ldr  x0, [x19, #PN_EXPR]
    mov  x1, x20
    bl   and_append
    str  x0, [x19, #PN_EXPR]
    b    .Lpc_yes
1:  ldr  x0, [x19, #PN_LEFT]
    bl   range_mask
    mov  x22, x0
    ldr  x0, [x19, #PN_RIGHT]
    bl   range_mask
    mov  x23, x0
    bics xzr, x21, x22                  // mask within the left side?
    b.ne 2f
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    mov  x2, x21
    bl   push_conj
    b    .Lpc_ret
2:  ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.eq .Lpc_no                        // never into / onto a LEFT JOIN
    bics xzr, x21, x23                  // within the right side?
    b.ne 3f
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    mov  x2, x21
    bl   push_conj
    b    .Lpc_ret
3:  ldr  x0, [x19, #PN_EXPR]            // spans both: join condition
    mov  x1, x20
    bl   and_append
    str  x0, [x19, #PN_EXPR]
    mov  w9, #JT_INNER                  // CROSS + condition = INNER
    str  w9, [x19, #PN_JT]
.Lpc_yes:
    mov  w0, #1
.Lpc_ret:
    LEAVE 4
.Lpc_no:
    mov  w0, #0
    LEAVE 4
ENDF push_conj

// range_mask(x0 PlanNode*) -> x0 bitmask of the rvs [PN_LO, PN_HI)   (leaf)
LFUNC range_mask
    ldr  w9, [x0, #PN_LO]
    ldr  w10, [x0, #PN_HI]
    mov  x0, #0
    mov  x11, #1
1:  cmp  w9, w10
    b.hs 2f
    lsl  x12, x11, x9
    orr  x0, x0, x12
    add  w9, w9, #1
    b    1b
2:  ret
ENDF range_mask

// =============================================================================
// pp_joins(x0 PlanNode*) — rewrites every join of a FROM tree (pre-order, so
// that conjuncts pushed down from a parent are seen by the children).
//   x19 node, x20 conjunct Vec (stack), x21 index, x22 conjunct,
//   x23 left mask, x24 right mask, x25 residual, x26 key vectors base
// =============================================================================
LFUNC pp_joins
    ENTER 5
    sub  sp, sp, #80                    // [0] conjuncts Vec, [32] lkeys Vec,
                                        // [56] rkeys Vec (n, cap, data)
    mov  x19, x0
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_SCAN
    b.eq .Lpj_end
    ldr  x0, [x19, #PN_LEFT]
    bl   range_mask
    mov  x23, x0
    ldr  x0, [x19, #PN_RIGHT]
    bl   range_mask
    mov  x24, x0
    stp  xzr, xzr, [sp]
    str  xzr, [sp, #16]
    stp  xzr, xzr, [sp, #32]
    str  xzr, [sp, #48]
    stp  xzr, xzr, [sp, #56]
    str  xzr, [sp, #72]
    mov  x0, sp
    ldr  x1, [x19, #PN_EXPR]
    bl   split_conj
    mov  x25, #0
    mov  x21, #0
.Lpj_conj:
    ldr  x9, [sp]
    cmp  x21, x9
    b.hs .Lpj_conj_done
    ldr  x9, [sp, #16]
    ldr  x22, [x9, x21, lsl #3]
    mov  x0, x22
    bl   expr_rvmask
    mov  x26, x0
    cbz  x26, .Lpj_residual
    // single side?
    bics xzr, x26, x24                  // within the right side
    b.ne 1f
    ldr  x0, [x19, #PN_RIGHT]           // (valid for INNER and LEFT joins)
    mov  x1, x22
    mov  x2, x26
    bl   push_conj
    cbnz w0, .Lpj_next
    b    .Lpj_residual
1:  ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.eq 2f
    bics xzr, x26, x23                  // within the left side (inner only)
    b.ne 2f
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x22
    mov  x2, x26
    bl   push_conj
    cbnz w0, .Lpj_next
    b    .Lpj_residual
2:  // equi-join key: left_expr = right_expr across the two sides?
    mov  x0, x22
    mov  x1, x23
    mov  x2, x24
    add  x3, sp, #32
    add  x4, sp, #56
    bl   try_hash_key
    cbnz w0, .Lpj_next
.Lpj_residual:
    mov  x0, x25
    mov  x1, x22
    bl   and_append
    mov  x25, x0
.Lpj_next:
    add  x21, x21, #1
    b    .Lpj_conj
.Lpj_conj_done:
    str  x25, [x19, #PN_EXPR]
    ldr  x9, [sp, #32]
    str  x9, [x19, #PN_NKEYS]
    ldr  x9, [sp, #48]
    str  x9, [x19, #PN_LKEYS]
    ldr  x9, [sp, #72]
    str  x9, [x19, #PN_RKEYS]
    mov  w9, #PO_NLJOIN
    ldr  x10, [x19, #PN_NKEYS]
    cbz  x10, 3f
    mov  w9, #PO_HASHJOIN
3:  str  w9, [x19, #PN_OP]
    ldr  w9, [x19, #PN_JT]              // a cross join that got a condition
    cmp  w9, #JT_CROSS
    b.ne 4f
    ldr  x10, [x19, #PN_EXPR]
    ldr  x11, [x19, #PN_NKEYS]
    orr  x10, x10, x11
    cbz  x10, 4f
    mov  w9, #JT_INNER
    str  w9, [x19, #PN_JT]
4:  ldr  x0, [x19, #PN_LEFT]
    bl   pp_joins
    ldr  x0, [x19, #PN_RIGHT]
    bl   pp_joins
.Lpj_end:
    add  sp, sp, #80
    LEAVE 5
ENDF pp_joins


// =============================================================================
// try_hash_key(x0 conjunct, x1 left mask, x2 right mask, x3 lkeys Vec*,
//              x4 rkeys Vec*) -> w0 1 if the conjunct became a hash key pair
// An equality whose operands reference disjoint sides, and whose operand
// types have one payload encoding (same kind; DECIMAL with the same scale).
//   x19 conjunct, x20 lmask, x21 rmask, x22 lkeys, x23 rkeys, x24 mask a,
//   x25 mask b
// =============================================================================
LFUNC try_hash_key
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x23, x4
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_BINARY
    b.ne .Lthk_no
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_EQ
    b.ne .Lthk_no
    ldr  x9, [x19, #N_A]
    ldr  x10, [x19, #N_B]
    ldr  w11, [x9, #N_TYPE]
    ldr  w12, [x10, #N_TYPE]
    and  w13, w11, #T_KIND_MASK
    and  w14, w12, #T_KIND_MASK
    cmp  w13, w14
    b.ne .Lthk_no
    cbz  w13, .Lthk_no                  // NULL literal: never matches anyway
    cmp  w13, #T_DEC
    b.ne 1f
    lsr  w11, w11, #T_SCALE_SHIFT
    lsr  w12, w12, #T_SCALE_SHIFT
    cmp  w11, w12
    b.ne .Lthk_no
1:  ldr  x0, [x19, #N_A]
    bl   expr_rvmask
    mov  x24, x0
    ldr  x0, [x19, #N_B]
    bl   expr_rvmask
    mov  x25, x0
    cbz  x24, .Lthk_no
    cbz  x25, .Lthk_no
    // a within left and b within right, or swapped
    bics xzr, x24, x20
    b.ne 2f
    bics xzr, x25, x21
    b.ne 2f
    ldr  x1, [x19, #N_A]
    ldr  x2, [x19, #N_B]
    b    3f
2:  bics xzr, x24, x21
    b.ne .Lthk_no
    bics xzr, x25, x20
    b.ne .Lthk_no
    ldr  x1, [x19, #N_B]
    ldr  x2, [x19, #N_A]
3:  mov  x24, x2
    mov  x0, x22
    bl   pvec_push
    mov  x0, x23
    mov  x1, x24
    bl   pvec_push
    mov  w0, #1
    LEAVE 5
.Lthk_no:
    mov  w0, #0
    LEAVE 5
ENDF try_hash_key

// =============================================================================
// Expression helpers
// split_conj(x0 Vec*, x1 Node* or 0) — appends the AND-conjuncts of x1
//   x19 vec, x20 node
// =============================================================================
LFUNC split_conj
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
LFUNC and_append
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
LFUNC pvec_push
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
    b.eq 1f
    ADR_L x1, s_subscan
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
    cmp  w9, #PO_PROJECT
    b.eq .Lpe_project
    cmp  w9, #PO_AGGREGATE
    b.eq .Lpe_project
    b    .Lpe_children

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
    mov  x0, x19                        // "columns":[used columns]
    ADR_L x1, ex_columns
    bl   buf_puts
    mov  x22, #0
    mov  x24, #0                        // items written
2:  ldr  x9, [x23, #RV_TABLE]
    ldr  x10, [x9, #TBL_NCOLS]
    cmp  x22, x10
    b.hs 4f
    ldr  x10, [x23, #RV_USED]
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
ENDF plan_explain

// =============================================================================
// pe_subplans(x0 Buf*, x1 PlanNode*, x2 children written) -> x0 children
// Appends the plans of the subqueries used in the node's expressions.
//   x19 buf, x20 node, x21 count, x22 bq, x23 index
// =============================================================================
LFUNC pe_subplans
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
jt_names:
    .quad s_unknown, s_inner, s_left, s_cross
s_unknown:   .asciz "Unknown"
s_scan:      .asciz "TableScan"
s_subscan:   .asciz "SubqueryScan"
s_values:    .asciz "Values"
s_filter:    .asciz "Filter"
s_join:      .asciz "Join"
s_hashjoin:  .asciz "HashJoin"
s_nljoin:    .asciz "NestedLoopJoin"
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
    .text

    NOTE_GNU_STACK
