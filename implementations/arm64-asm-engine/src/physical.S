// =============================================================================
// physical.S — physical planning: maps the (optimized) logical plan of a
// query level to physical operators (PlanNode, pq.inc PN_* / PO_*). Every
// decision about *how* the plan runs is taken here, and only here:
//
//   phys_plan(x0 LogicalNode*) -> x0 PlanNode*   plans one query level (UNION
//       ALL branches as levels of their own)
//
//   * predicate placement (indexes-and-planning.md §3.1, independent of the
//     option "optimize"): every WHERE conjunct is evaluated at the lowest scan
//     or join that produces its range variables (never below the NULL-padded
//     side of a LEFT JOIN); join conditions are split again: single-input
//     conjuncts move into the inputs (only the right one of a LEFT JOIN).
//     After the optimizer rules push_filters / push_join_conditions nothing
//     is left to move; with "optimize": false this produces the same plan;
//   * join algorithm (option "join"): equality conjuncts between the two
//     inputs whose operand types share one payload encoding become join
//     keys; with keys HashJoin (auto, hash), MergeJoin (merge) or
//     NestedLoopJoin (nested_loop: the keys are compared per pair); without
//     keys always NestedLoopJoin;
//   * access paths (access.S ap_scan): simple predicates, index scan or
//     table scan (option "use_indexes"), PQCF row groups skipped, estimates;
//   * columns read by base-table scans: the set chosen by the optimizer rule
//     prune_columns, else every column the query references (§3.2);
//   * hash join build side (with "optimize"): an inner join builds on the
//     input with the smaller estimate (inputs swapped); a LEFT join builds
//     on its left (preserved) input when that one is smaller (PN_SWAP =
//     SWAP_LBUILD: probes stay balanced when a few left rows match most of
//     the right ones), else on the right input;
//   * top-N (with "optimize"): a Sort directly below a Limit keeps a bounded
//     heap of LIMIT + OFFSET rows (PN_TOPN);
//   * execution mode and threads (options "mode", "threads"): recorded in
//     the root (PN_XMODE, auto = vectorized; PN_XTHREADS); the executor runs
//     the plan with them. No native kernels are loaded ("native" is
//     accepted and ignored), so no kernel operators are chosen.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// pn_new(w0 op, x1 BoundQuery*, x2 left child) -> x0 PlanNode*
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
    LEAVE 2
ENDF pn_new

// =============================================================================
// phys_plan(x0 LogicalNode*) -> x0 PlanNode*
//   x19 logical plan, x20 physical root
// =============================================================================
FUNC phys_plan
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 1
    mov  x19, x0
    bl   pp_lower
    mov  x20, x0
    ldr  x9, [x19, #LN_BQ]
    ldr  x9, [x9, #BQ_NUNION]
    cbnz x9, 1f                         // compound: branches planned above
    mov  x0, x20
    bl   pp_rewrite
1:  mov  x0, x20
    bl   pp_root
    mov  x0, x20
    LEAVE 1
ENDF phys_plan

// =============================================================================
// pp_lower(x0 LogicalNode*) -> x0 PlanNode*: one physical operator per
// logical one (joins get their algorithm in pp_joins)
//   x19 logical node, x20 physical node, x21 index, x22 children array
// =============================================================================
LFUNC pp_lower
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    mov  x19, x0
    ldr  w9, [x19, #LN_OP]
    ADR_L x10, po_of_lo
    ldrb w0, [x10, x9]
    ldr  x1, [x19, #LN_BQ]
    mov  x2, #0
    bl   pn_new
    mov  x20, x0
    ldr  w9, [x19, #LN_JT]
    str  w9, [x20, #PN_JT]
    ldr  x9, [x19, #LN_PRED]
    str  x9, [x20, #PN_EXPR]
    ldr  x9, [x19, #LN_RV]
    str  x9, [x20, #PN_RV]
    ldr  x9, [x19, #LN_MASK]
    str  x9, [x20, #PN_MASK]
    ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_SCAN
    b.eq .Lpl_scan
    cmp  w9, #LO_UNION
    b.eq .Lpl_union
    ldr  x0, [x19, #LN_LEFT]
    cbz  x0, 9f
    bl   pp_lower
    str  x0, [x20, #PN_LEFT]
    ldr  x0, [x19, #LN_RIGHT]
    cbz  x0, 9f
    bl   pp_lower
    str  x0, [x20, #PN_RIGHT]
    b    9f
.Lpl_scan:                              // columns read
    ldr  x9, [x19, #LN_COLS]
    cbnz x9, 1f
    ldr  x10, [x19, #LN_BQ]             // not pruned: every referenced one
    ldr  x10, [x10, #BQ_RVS]
    ldr  x11, [x19, #LN_RV]
    mov  x12, #RV_SIZE
    madd x10, x11, x12, x10
    ldr  x9, [x10, #RV_USED]
1:  str  x9, [x20, #PN_COLS]
    b    9f
.Lpl_union:                             // branches: query levels
    ldr  x9, [x19, #LN_NKIDS]
    str  x9, [x20, #PN_NKIDS]
    lsl  x0, x9, #3
    bl   arena_zalloc
    mov  x22, x0
    str  x22, [x20, #PN_KIDS]
    mov  x21, #0
2:  ldr  x9, [x19, #LN_NKIDS]
    cmp  x21, x9
    b.hs 9f
    ldr  x9, [x19, #LN_KIDS]
    ldr  x0, [x9, x21, lsl #3]
    bl   phys_plan
    str  x0, [x22, x21, lsl #3]
    add  x21, x21, #1
    b    2b
9:  mov  x0, x20
    LEAVE 3
ENDF pp_lower

// =============================================================================
// pp_root(x0 PlanNode* root of a query level): top-N and execution settings
// (leaf)
// =============================================================================
LFUNC pp_root
    ldr  w9, [x0, #PN_OP]               // Limit directly above Sort, with
    cmp  w9, #PO_LIMIT                  // a LIMIT: top-N when optimizing
    b.ne 1f
    ldr  x10, [x0, #PN_LEFT]
    ldr  w9, [x10, #PN_OP]
    cmp  w9, #PO_SORT
    b.ne 1f
    ldr  x9, [x0, #PN_BQ]
    ldr  x9, [x9, #BQ_LIMIT]
    tbnz x9, #63, 1f
    TLS_ADDR x9, g_opt_optimize
    ldr  w9, [x9]
    str  w9, [x10, #PN_TOPN]
1:  TLS_ADDR x9, g_opt_mode             // execution mode: auto = vectorized
    ldr  w9, [x9]
    cmp  w9, #XM_AUTO
    mov  w10, #XM_VEC
    csel w9, w10, w9, eq
    str  w9, [x0, #PN_XMODE]
    TLS_LDR x9, g_opt_threads
    str  x9, [x0, #PN_XTHREADS]
    ret
ENDF pp_root

// =============================================================================
// pp_rewrite(x0 PlanNode* root of a query level) — in place.
// Finds the FROM tree (below an optional WHERE filter), places the WHERE
// conjuncts, rewrites every join, chooses the access paths.
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
    // ---- WHERE conjuncts ---------------------------------------------------
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
    // the filter became empty: overwrite it with its child (the FROM root)
    mov  x0, x19
    ldr  x1, [x19, #PN_LEFT]
    mov  x2, #PN_SIZE
    bl   memcpy
    mov  x20, x19                       // the FROM root now lives in x19
.Lpp_joins:
    mov  x0, x20
    bl   pp_joins
    mov  x0, x20
    bl   pp_access
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
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
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

// range_mask(x0 PlanNode* scan / join) -> x0 bitmask of its rvs   (leaf)
LFUNC range_mask
    ldr  x0, [x0, #PN_MASK]
    ret
ENDF range_mask

// =============================================================================
// pp_joins(x0 PlanNode*) — rewrites every join of a FROM tree (pre-order, so
// that conjuncts pushed down from a parent are seen by the children).
//   x19 node, x20 conjunct Vec (stack), x21 index, x22 conjunct,
//   x23 left mask, x24 right mask, x25 residual, x26 key vectors base
// =============================================================================
LFUNC pp_joins
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
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
    mov  w9, #PO_NLJOIN                 // algorithm: option "join"
    ldr  x10, [x19, #PN_NKEYS]
    cbz  x10, 3f                        // no equi keys: nested loop
    TLS_ADDR x11, g_opt_join
    ldr  w11, [x11]
    mov  w9, #PO_HASHJOIN               // auto / hash
    cmp  w11, #XJ_MERGE
    b.ne 31f
    mov  w9, #PO_MERGEJOIN
31: cmp  w11, #XJ_NL                    // keys stay: compared per pair
    b.ne 3f
    mov  w9, #PO_NLJOIN
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
// pp_access(x0 PlanNode*) -> x0 estimated rows
// Access paths and cardinality estimates of a FROM tree: scans choose their
// access path (access.S: index selection, row-group skipping); an inner hash
// join builds on the input with the smaller estimate (inputs swapped, the
// tuple layout does not depend on the order); LEFT joins build on the
// smaller input too, without swapping (SWAP_LBUILD).
//   x19 node, x20 left estimate, x21 right estimate
// =============================================================================
LFUNC pp_access
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    mov  x19, x0
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_SCAN
    b.ne 1f
    bl   ap_scan
    LEAVE 3
1:  ldr  x0, [x19, #PN_LEFT]
    bl   pp_access
    mov  x20, x0
    ldr  x0, [x19, #PN_RIGHT]
    bl   pp_access
    mov  x21, x0
    ldr  x9, [x19, #PN_NKEYS]
    cbz  x9, 3f
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_HASHJOIN
    b.ne 2f
    TLS_ADDR x9, g_opt_optimize         // build-side choice is an optimization
    ldr  w9, [x9]
    cbz  w9, 2f
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 11f
    cmp  x20, x21                       // LEFT: build on a smaller left
    b.hs 2f
    mov  w9, #SWAP_LBUILD
    str  w9, [x19, #PN_SWAP]
    b    2f
11: cmp  w9, #JT_INNER
    b.ne 2f
    cmp  x20, x21
    b.hs 2f
    ldp  x9, x10, [x19, #PN_LEFT]       // swap: build on the smaller left
    stp  x10, x9, [x19, #PN_LEFT]
    ldr  x9, [x19, #PN_LKEYS]
    ldr  x10, [x19, #PN_RKEYS]
    str  x10, [x19, #PN_LKEYS]
    str  x9, [x19, #PN_RKEYS]
    mov  w9, #1
    str  w9, [x19, #PN_SWAP]
2:  cmp  x20, x21                       // equi-join: about the larger input
    csel x0, x20, x21, hs
    b    9f
3:  umulh x9, x20, x21                  // nested loop: product (saturating)
    mul  x0, x20, x21
    cmp  x9, #0
    csinv x0, x0, xzr, eq
    ldr  x9, [x19, #PN_EXPR]
    cbz  x9, 9f
    mov  x9, #3                         // with a condition: a third
    udiv x0, x0, x9
9:  ldr  w9, [x19, #PN_JT]              // LEFT JOIN keeps every left row
    cmp  w9, #JT_LEFT
    b.ne 10f
    cmp  x0, x20
    csel x0, x0, x20, hs
10: str  x0, [x19, #PN_EST]
    LEAVE 3
ENDF pp_access

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
    mov  w26, #0                        // common key type (0: keep)
    cbz  w13, .Lthk_no                  // NULL literal: never matches anyway
    cbz  w14, .Lthk_no
    cmp  w13, w14
    b.ne 0f
    cmp  w13, #T_DEC
    b.ne 1f
0:  cmp  w13, #T_INT                    // INT64 / DECIMAL of different
    ccmp w13, #T_DEC, #4, ne            // encodings (scale, width): both
    b.ne .Lthk_no                       // keys are cast to the saturating
    cmp  w14, #T_INT                    // DECIMAL(W, max scale), which keeps
    ccmp w14, #T_DEC, #4, ne            // equality exact (pq.inc T_SATF)
    b.ne .Lthk_no
    ubfx w15, w11, #T_PREC_SHIFT, #8
    ubfx w16, w12, #T_PREC_SHIFT, #8
    cmp  w15, #DEC_NARROW_MAX
    cset w15, hi
    cmp  w16, #DEC_NARROW_MAX
    cset w16, hi
    ubfx w17, w11, #T_SCALE_SHIFT, #8
    ubfx w9, w12, #T_SCALE_SHIFT, #8
    cmp  w13, w14                       // both DECIMAL: same width and
    b.ne 05f                            // scale need no conversion
    cmp  w15, w16
    ccmp w17, w9, #0, eq
    b.eq 1f
05: cmp  w13, #T_DEC
    csel w17, w17, wzr, eq              // INT64 counts as scale 0
    cmp  w14, #T_DEC
    csel w9, w9, wzr, eq
    cmp  w17, w9
    csel w17, w17, w9, hs               // max scale
    str  w17, [sp, #-16]!
    mov  w0, w11
    mov  w1, w12
    bl   dec_wtype
    ldr  w17, [sp], #16
    orr  w26, w0, w17, lsl #T_SCALE_SHIFT
    orr  w26, w26, #T_SATF
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
3:  cbz  w26, 4f                        // convert the keys to one encoding
    mov  x27, x1
    mov  x28, x2
    ldr  w9, [x27, #N_TYPE]
    cmp  w9, w26
    b.eq 31f
    mov  x0, x27
    mov  w1, w26
    bl   mk_cast
    mov  x27, x0
31: ldr  w9, [x28, #N_TYPE]
    cmp  w9, w26
    b.eq 32f
    mov  x0, x28
    mov  w1, w26
    bl   mk_cast
    mov  x28, x0
32: mov  x1, x27
    mov  x2, x28
4:  mov  x24, x2
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

    .section .rodata
// physical operator of each logical operator (indexed by LO_*)
po_of_lo:
    .byte 0, PO_SCAN, PO_SCAN, PO_VALUES, PO_FILTER, PO_JOIN, PO_AGGREGATE
    .byte PO_PROJECT, PO_DISTINCT, PO_SORT, PO_LIMIT, PO_UNION
    .text

    NOTE_GNU_STACK
