// =============================================================================
// rule_prune.S — optimizer rule prune_columns (projection pushdown).
//
//   rule_prune_columns(x0 LogicalNode*) -> x0 LogicalNode*
//       every base-table Scan of the query level (and of its UNION ALL
//       branches) gets the set of columns the level still needs (LN_COLS):
//       the columns referenced by the expressions of the optimized plan,
//       plus those referenced from subqueries (correlated references, which
//       the binder flags with RVU_OUTER in RV_USED). Columns referenced by
//       the expressions as written are kept even if a later rewrite removes
//       the reference (optimize.S runs this rule first).
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// rule_prune_columns(x0 LogicalNode* or 0) -> x0 LogicalNode*
//   x19 plan, x20 bq, x21 column-flag array per rv (u8**), x22 rv index
// =============================================================================
FUNC rule_prune_columns
    STACK_GUARD                         // CR-6: recursive
    cbz  x0, 9f
    ENTER 3
    mov  x19, x0
    ldr  x20, [x19, #LN_BQ]
    ldr  x9, [x20, #BQ_NUNION]
    cbz  x9, 2f
    mov  x0, x19                        // compound: each branch is a level
1:  ldr  w9, [x0, #LN_OP]
    cmp  w9, #LO_UNION
    b.eq 11f
    ldr  x0, [x0, #LN_LEFT]
    b    1b
11: mov  x21, x0
    mov  x22, #0
12: ldr  x9, [x21, #LN_NKIDS]
    cmp  x22, x9
    b.hs 8f
    ldr  x9, [x21, #LN_KIDS]
    ldr  x0, [x9, x22, lsl #3]
    bl   rule_prune_columns
    add  x22, x22, #1
    b    12b
2:  ldr  x9, [x20, #BQ_NRV]
    lsl  x0, x9, #3
    add  x0, x0, #8
    bl   arena_zalloc
    mov  x21, x0
    mov  x0, x19                        // a fresh column set per scan
    mov  x1, x21
    bl   pr_scans
    mov  x22, #0                        // columns used by subqueries
3:  ldr  x9, [x20, #BQ_NRV]
    cmp  x22, x9
    b.hs 5f
    ldr  x10, [x21, x22, lsl #3]
    cbz  x10, 41f
    ldr  x11, [x20, #BQ_RVS]
    mov  x12, #RV_SIZE
    madd x11, x22, x12, x11
    ldr  x12, [x11, #RV_TABLE]
    ldr  x12, [x12, #TBL_NCOLS]
    ldr  x11, [x11, #RV_USED]
4:  cbz  x12, 41f
    sub  x12, x12, #1
    ldrb w13, [x11, x12]
    and  w13, w13, #RVU_OUTER
    cbz  w13, 4b
    mov  w13, #1
    strb w13, [x10, x12]
    b    4b
41: add  x22, x22, #1
    b    3b
5:  mov  x0, x19                        // columns used by the plan
    ADR_L x1, pr_slot
    mov  x2, x21
    bl   lp_exprs
8:  mov  x0, x19
    LEAVE 3
9:  ret
ENDF rule_prune_columns

// pr_scans(x0 LogicalNode* or 0, x1 u8** per rv): gives every base-table
// Scan of the FROM tree an empty column set and records it
//   x19 node, x20 array
LFUNC pr_scans
    STACK_GUARD                         // CR-6: recursive
    cbz  x0, 9f
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_SCAN
    b.ne 1f
    ldr  x9, [x19, #LN_BQ]
    ldr  x9, [x9, #BQ_RVS]
    ldr  x10, [x19, #LN_RV]
    mov  x11, #RV_SIZE
    madd x9, x10, x11, x9
    ldr  x9, [x9, #RV_TABLE]
    ldr  x0, [x9, #TBL_NCOLS]
    add  x0, x0, #1
    bl   arena_zalloc
    str  x0, [x19, #LN_COLS]
    ldr  x10, [x19, #LN_RV]
    str  x0, [x20, x10, lsl #3]
    LEAVE 2
1:  ldr  x0, [x19, #LN_LEFT]
    mov  x1, x20
    bl   pr_scans
    ldr  x0, [x19, #LN_RIGHT]
    mov  x1, x20
    bl   pr_scans
    LEAVE 2
9:  ret
ENDF pr_scans

// pr_slot(x0 Node** slot, x1 u8** per rv): marks the columns of this level
// that the expression references
LFUNC pr_slot
    ldr  x0, [x0]
    b    pr_expr
ENDF pr_slot

// pr_expr(x0 Node*, x1 u8** per rv)
//   x19 node, x20 array, x21 index, x22 count
LFUNC pr_expr
    STACK_GUARD                         // CR-6: recursive
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_COL
    b.ne 1f
    ldr  w9, [x19, #N_OP]               // outer references: other levels
    cbnz w9, 9f
    ldr  x9, [x19, #N_B]
    ldr  x9, [x20, x9, lsl #3]
    cbz  x9, 9f                         // not a base-table scan
    ldr  x10, [x19, #N_VAL]
    mov  w11, #1
    strb w11, [x9, x10]
    b    9f
1:  mov  x0, x19
    bl   expr_nchildren
    mov  x22, x0
    mov  x21, #0
2:  cmp  x21, x22
    b.hs 9f
    mov  x0, x19
    mov  x1, x21
    bl   expr_child_slot
    ldr  x0, [x0]
    mov  x1, x20
    bl   pr_expr
    add  x21, x21, #1
    b    2b
9:  LEAVE 3
ENDF pr_expr

    NOTE_GNU_STACK
