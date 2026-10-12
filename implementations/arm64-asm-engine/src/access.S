// =============================================================================
// access.S — access paths of base-table scans (indexes-and-planning.md §3).
//
//   ap_scan(x0 PlanNode* scan) -> x0 estimated rows
//       for a scan of a base table: extracts the simple predicates
//       "column op constant" of the pushed-down filter (PN_PREDS), estimates
//       the output cardinality from the table statistics, chooses an index
//       (PN_IDX / PN_IXA) and counts the PQCF row groups that the predicates
//       exclude (PN_RGSKIP, for EXPLAIN)
//   scan_estimate(x0 BoundQuery*, x1 rv index, x2 predicate or 0) -> x0
//       estimated output rows of a scan of the rv with that predicate, from
//       the statistics alone (for the logical optimizer's join ordering)
//   rg_skippable(x0 Pred** preds, x1 n, x2 Table*, x3 RowGroup*) -> w0 1 if
//       the min/max statistics of the row group prove that no row passes
//
// Selectivity estimates (from table_stats): equality 1/distinct, IN k/distinct,
// ranges by linear interpolation between min and max for numeric / temporal
// columns, 1/3 otherwise. An index is used when its predicate's estimated
// selectivity is <= 10% — or, for equality / IN lookups, when at most
// SMALL_LOOKUP rows are expected (a lookup that cheap never loses to a scan).
// Constants are literals (optionally negated / implicitly cast); they are
// evaluated here, at planning time, without any possibility of error.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define SMALL_LOOKUP 16

    TDATA
    .p2align 2
    .global g_use_indexes
g_use_indexes:  .word 1             // query option use_indexes (protocol.S)

    .section .rodata
    .p2align 3
k_one:      .double 1.0
k_third:    .double 0.3333333333333333
k_tenth:    .double 0.1
k_small:    .double 16.0
    .text

// =============================================================================
// const_value(x0 Node*) -> x0 payload, x1 isnull, w2 1 if constant (0: not a
// supported constant), w3 type
//   x19 node, w20 target type
// =============================================================================
LFUNC const_value
    ENTER 2
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq .Lcv_lit
    cmp  w9, #NK_CAST
    b.eq .Lcv_cast
    cmp  w9, #NK_UNARY
    b.eq .Lcv_unary
.Lcv_no:
    mov  w2, #0
    LEAVE 2
.Lcv_lit:
    ldr  x0, [x19, #N_VAL]
    ldr  w3, [x19, #N_TYPE]
    ldr  w9, [x19, #N_FLAGS]
    and  w1, w9, #NF_NULL
    and  w9, w3, #T_KIND_MASK
    cmp  w9, #T_NULL
    csinc w1, w1, wzr, ne
    mov  w2, #1
    LEAVE 2
.Lcv_unary:
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_NEG
    b.ne .Lcv_no
    ldr  x0, [x19, #N_A]
    bl   const_value
    cbz  w2, .Lcv_no
    cbnz x1, .Lcv_ret
    and  w9, w3, #T_KIND_MASK
    cmp  w9, #T_FLOAT
    b.eq 1f
    cmp  w9, #T_INT
    b.eq 2f
    cmp  w9, #T_DEC
    b.ne .Lcv_no
    neg  x0, x0
    b    .Lcv_ret
1:  eor  x0, x0, #0x8000000000000000
    b    .Lcv_ret
2:  mov  x9, #0x8000000000000000
    cmp  x0, x9
    b.eq .Lcv_no                        // -INT64_MIN overflows
    neg  x0, x0
    b    .Lcv_ret
.Lcv_cast:
    ldr  w20, [x19, #N_TYPE]
    ldr  x0, [x19, #N_A]
    bl   const_value
    cbz  w2, .Lcv_no
    cbnz x1, .Lcv_retcast               // CAST(NULL AS t) is NULL
    and  w9, w3, #T_KIND_MASK           // from kind
    and  w10, w20, #T_KIND_MASK         // to kind
    cmp  w9, w10
    b.ne 3f
    cmp  w9, #T_DEC
    b.ne .Lcv_retcast                   // same kind, same encoding
    ubfx w1, w3, #T_SCALE_SHIFT, #8     // DECIMAL rescale (rounds)
    ubfx w2, w20, #T_SCALE_SHIFT, #8
    bl   dec_rescale
    cbnz w1, .Lcv_no
    ubfx w1, w20, #T_PREC_SHIFT, #8
    mov  x19, x0
    bl   dec_fits
    cbz  w0, .Lcv_no
    mov  x0, x19
    b    .Lcv_retcast0
3:  cmp  w9, #T_INT
    b.ne 5f
    cmp  w10, #T_FLOAT
    b.ne 4f
    scvtf d0, x0
    fmov x0, d0
    b    .Lcv_retcast0
4:  cmp  w10, #T_DEC
    b.ne .Lcv_no
    mov  x1, #0                         // INT -> DECIMAL(p,s): v * 10^s
    ubfx w2, w20, #T_SCALE_SHIFT, #8
    mov  w1, #0
    bl   dec_rescale
    cbnz w1, .Lcv_no
    ubfx w1, w20, #T_PREC_SHIFT, #8
    mov  x19, x0
    bl   dec_fits
    cbz  w0, .Lcv_no
    mov  x0, x19
    b    .Lcv_retcast0
5:  cmp  w9, #T_DATE
    b.ne .Lcv_no
    cmp  w10, #T_TS
    b.ne .Lcv_no
    ldr  x9, =86400000000
    mul  x0, x0, x9
.Lcv_retcast0:
    mov  x1, #0
.Lcv_retcast:
    mov  w3, w20
.Lcv_ret:
    mov  w2, #1
    LEAVE 2
ENDF const_value

// rv_colref(x0 Node*, x1 rv) -> x0 column index or -1 (bare column of rv)
LFUNC rv_colref
    ldr  w9, [x0, #N_KIND]
    cmp  w9, #NK_COL
    b.ne 9f
    ldr  w9, [x0, #N_OP]
    cbnz w9, 9f
    ldr  x9, [x0, #N_B]
    cmp  x9, x1
    b.ne 9f
    ldr  x0, [x0, #N_VAL]
    ret
9:  mov  x0, #-1
    ret
ENDF rv_colref

// =============================================================================
// cmp_pred(x0 binary comparison Node*, x1 rv, x2 Table*, x3 Pred* out)
//   -> w0 1 if it is "column op constant" on rv (Pred filled: col, op, type,
//   val, null; operands swapped if the column is on the right)
//   x19 node, x20 rv, x21 table, x22 out, x23 column, w24 op
// =============================================================================
LFUNC cmp_pred
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_BINARY
    b.ne .Lcp_no
    ldr  w24, [x19, #N_OP]
    cmp  w24, #OP_EQ
    b.eq 1f
    cmp  w24, #OP_LT
    b.lo .Lcp_no
    cmp  w24, #OP_GE
    b.hi .Lcp_no
1:  ldr  x0, [x19, #N_A]
    mov  x1, x20
    bl   rv_colref
    tbnz x0, #63, 2f
    mov  x23, x0
    ldr  x0, [x19, #N_B]
    b    3f
2:  ldr  x0, [x19, #N_B]                // constant op column: mirror
    mov  x1, x20
    bl   rv_colref
    tbnz x0, #63, .Lcp_no
    mov  x23, x0
    cmp  w24, #OP_LT                    // LT<->GT, LE<->GE
    b.lo 21f
    cmp  w24, #OP_LE
    add  w9, w24, #2
    sub  w10, w24, #2
    csel w24, w9, w10, ls
21: ldr  x0, [x19, #N_A]
3:  bl   const_value
    cbz  w2, .Lcp_no
    str  x23, [x22, #PR_COL]
    str  w24, [x22, #PR_OP]
    str  w3, [x22, #PR_TYPE]
    str  x0, [x22, #PR_VAL]
    mov  x9, #1
    str  x9, [x22, #PR_N]
    str  w1, [x22, #PR_NULL]
    cbnz w1, 4f                         // NULL constant: never true
    ldr  x9, [x21, #TBL_COLS]           // same type kind as the column
    add  x9, x9, x23, lsl #5
    ldrb w9, [x9, #COL_TYPE]
    and  w3, w3, #T_KIND_MASK
    cmp  w9, w3
    b.ne .Lcp_no
4:  mov  w0, #1
    LEAVE 4
.Lcp_no:
    mov  w0, #0
    LEAVE 4
ENDF cmp_pred

// =============================================================================
// simple_pred(x0 conjunct, x1 rv, x2 Table*) -> x0 Pred* or 0
// "col op const" or "col IN (const, ...)" (all constants of one type).
//   x19 conjunct, x20 rv, x21 table, x22 Pred, x23 i, x24 values, x25 count,
//   x26 scratch Pred (stack)
// =============================================================================
LFUNC simple_pred
    ENTER 5
    sub  sp, sp, #48
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x0, #PR_SIZE
    bl   arena_zalloc
    mov  x22, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_IN
    b.eq .Lsp_in
    mov  x0, x19
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    bl   cmp_pred
    cbz  w0, .Lsp_no
    b    .Lsp_yes
.Lsp_in:
    ldr  w9, [x19, #N_OP]               // NOT IN: not indexable
    cbnz w9, .Lsp_no
    ldr  x25, [x19, #N_VAL]
    cbz  x25, .Lsp_no
    lsl  x0, x25, #3
    bl   arena_alloc
    mov  x24, x0
    mov  x23, #0
    str  xzr, [x22, #PR_N]
1:  cmp  x23, x25
    b.hs 3f
    ldr  x9, [x19, #N_C]
    ldr  x0, [x9, x23, lsl #3]
    mov  x1, x20
    mov  x2, x21
    mov  x3, sp
    bl   cmp_pred
    cbz  w0, .Lsp_no
    ldr  w9, [sp, #PR_OP]
    cmp  w9, #OP_EQ
    b.ne .Lsp_no
    ldr  x9, [sp, #PR_COL]
    cbz  x23, 11f
    ldr  x10, [x22, #PR_COL]            // same column, same constant type
    cmp  x9, x10
    b.ne .Lsp_no
    ldr  w10, [x22, #PR_TYPE]
    ldr  w11, [sp, #PR_TYPE]
    ldr  w12, [sp, #PR_NULL]
    cbnz w12, 2f                        // NULL element: never matches
    ldr  x12, [x22, #PR_N]
    cbz  x12, 12f                       // no typed value yet
    cmp  w10, w11
    b.ne .Lsp_no
    b    12f
11: str  x9, [x22, #PR_COL]
12: ldr  w12, [sp, #PR_NULL]
    cbnz w12, 2f
    ldr  w11, [sp, #PR_TYPE]
    str  w11, [x22, #PR_TYPE]
    ldr  x12, [x22, #PR_N]
    ldr  x13, [sp, #PR_VAL]
    str  x13, [x24, x12, lsl #3]
    add  x12, x12, #1
    str  x12, [x22, #PR_N]
2:  add  x23, x23, #1
    b    1b
3:  mov  w9, #PRO_IN
    str  w9, [x22, #PR_OP]
    str  x24, [x22, #PR_VAL]
    ldr  x9, [x22, #PR_N]               // only NULLs: never true
    cmp  x9, #0
    cset w9, eq
    str  w9, [x22, #PR_NULL]
.Lsp_yes:
    mov  x0, x22
    add  sp, sp, #48
    LEAVE 5
.Lsp_no:
    mov  x0, #0
    add  sp, sp, #48
    LEAVE 5
ENDF simple_pred

// to_double(x0 payload, w1 type) -> d0   (leaf-like)
LFUNC to_double
    and  w9, w1, #T_KIND_MASK
    cmp  w9, #T_FLOAT
    b.ne 1f
    fmov d0, x0
    ret
1:  scvtf d0, x0
    cmp  w9, #T_DEC
    b.ne 2f
    ENTER 0
    str  d0, [sp, #-16]!
    ubfx w0, w1, #T_SCALE_SHIFT, #8
    bl   pow10_i64
    scvtf d1, x0
    ldr  d0, [sp], #16
    fdiv d0, d0, d1
    LEAVE 0
2:  ret
ENDF to_double

// interpolable(w0 type) -> w0 1 for INT / DECIMAL / FLOAT / DATE / TIMESTAMP
LFUNC interpolable
    and  w9, w0, #T_KIND_MASK
    mov  w0, #0
    cmp  w9, #T_INT
    b.lo 1f
    cmp  w9, #T_FLOAT
    b.ls 2f
    cmp  w9, #T_DATE
    b.lo 1f
    cmp  w9, #T_TS
    b.hi 1f
2:  mov  w0, #1
1:  ret
ENDF interpolable

// =============================================================================
// range_sel(x0 lo Pred* or 0, x1 hi Pred* or 0, x2 Table*, x3 ColStats*)
//   -> d0 selectivity of lo AND hi (same column)
//   x19 lo, x20 hi, x21 table, x22 stats of the column, w23 column type
//   stack: [sp] min, [sp+8] max, [sp+16] a, [sp+24] b
// =============================================================================
LFUNC range_sel
    ENTER 4
    sub  sp, sp, #32
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    cmp  x19, #0
    csel x9, x20, x19, eq
    ldr  x9, [x9, #PR_COL]
    ldr  x10, [x21, #TBL_COLS]
    add  x10, x10, x9, lsl #5
    ldr  w23, [x10, #COL_TYPE]
    mov  w0, w23
    bl   interpolable
    cbz  w0, .Lrs_third
    ldr  x9, [x22, #CST_NULLS]
    ldr  x10, [x21, #TBL_NROWS]
    cmp  x9, x10
    b.hs .Lrs_zero                      // no non-NULL value
    ldr  x0, [x22, #CST_MIN]
    mov  w1, w23
    bl   to_double
    str  d0, [sp]
    ldr  x0, [x22, #CST_MAX]
    mov  w1, w23
    bl   to_double
    str  d0, [sp, #8]
    ldr  d0, [sp]                       // a = max(lo, min)
    cbz  x19, 1f
    ldr  x0, [x19, #PR_VAL]
    ldr  w1, [x19, #PR_TYPE]
    bl   to_double
    ldr  d1, [sp]
    fmax d0, d0, d1
1:  str  d0, [sp, #16]
    ldr  d0, [sp, #8]                   // b = min(hi, max)
    cbz  x20, 2f
    ldr  x0, [x20, #PR_VAL]
    ldr  w1, [x20, #PR_TYPE]
    bl   to_double
    ldr  d1, [sp, #8]
    fmin d0, d0, d1
2:  str  d0, [sp, #24]
    ldp  d0, d1, [sp]                   // range = max - min
    fsub d2, d1, d0
    fcmp d2, #0.0
    b.le .Lrs_one
    ldp  d0, d1, [sp, #16]
    fsub d0, d1, d0
    fdiv d0, d0, d2
    fmov d1, xzr
    fmax d0, d0, d1
    fmov d1, #1.0
    fmin d0, d0, d1
    b    .Lrs_ret
.Lrs_third:
    ADR_L x9, k_third
    ldr  d0, [x9]
    b    .Lrs_ret
.Lrs_zero:
    fmov d0, xzr
    b    .Lrs_ret
.Lrs_one:
    fmov d0, #1.0
.Lrs_ret:
    add  sp, sp, #32
    LEAVE 4
ENDF range_sel

// =============================================================================
// pred_sel(x0 Pred*, x1 Table*, x2 ColStats*) -> d0 selectivity
//   x19 pred, x20 table, x21 stats array
// =============================================================================
LFUNC pred_sel
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  w9, [x19, #PR_NULL]
    cbnz w9, .Lps_zero
    ldr  x9, [x19, #PR_COL]
    add  x21, x21, x9, lsl #5           // this column's stats
    ldr  w9, [x19, #PR_OP]
    cmp  w9, #OP_EQ
    b.eq 1f
    cmp  w9, #PRO_IN
    b.eq 1f
    cmp  w9, #OP_LE
    b.hi 2f
    mov  x0, #0                         // LT / LE: upper bound
    mov  x1, x19
    b    4f
2:  mov  x0, x19                        // GT / GE: lower bound
    mov  x1, #0
4:  mov  x2, x20
    mov  x3, x21
    bl   range_sel
    LEAVE 2
1:  ldr  x9, [x19, #PR_N]               // k / distinct, at most 1
    ucvtf d0, x9
    ldr  x9, [x21, #CST_DISTINCT]
    cmp  x9, #1
    csinc x9, x9, xzr, hs
    ucvtf d1, x9
    fdiv d0, d0, d1
    fmov d1, #1.0
    fmin d0, d0, d1
    LEAVE 2
.Lps_zero:
    fmov d0, xzr
    LEAVE 2
ENDF pred_sel

// =============================================================================
// ap_scan(x0 PlanNode* scan) -> x0 estimated output rows
//   x19 node, x20 table, x21 bq, x22 conjunct vec (stack) / preds vec,
//   x23 i, x24 stats, x25 nrows, x26 best Pred, x27 best Index*,
//   x28 best kind (IAK_*) ; stack: [sp] conjuncts Vec (24), [sp+32] preds
//   Vec (24), [sp+56] sel product, [sp+64] best sel, [sp+72] best lo,
//   [sp+80] best hi, [sp+88] scratch
// =============================================================================
FUNC ap_scan
    ENTER 5
    sub  sp, sp, #96
    mov  x19, x0
    ldr  x21, [x19, #PN_BQ]
    ldr  x9, [x21, #BQ_RVS]
    ldr  x10, [x19, #PN_RV]
    mov  x11, #RV_SIZE
    madd x9, x10, x11, x9
    ldr  w10, [x9, #RV_KIND]
    cmp  w10, #RVK_BASE
    b.eq 1f
    mov  x0, #1000                      // derived table / CTE: unknown
    b    .Lap_ret
1:  ldr  x20, [x9, #RV_TABLE]
    ldr  x25, [x20, #TBL_NROWS]
    ldr  x9, [x19, #PN_EXPR]
    cbnz x9, 2f
    mov  x0, x25
    b    .Lap_ret
2:  stp  xzr, xzr, [sp]                 // split the filter
    str  xzr, [sp, #16]
    stp  xzr, xzr, [sp, #32]
    str  xzr, [sp, #48]
    mov  x0, sp
    ldr  x1, [x19, #PN_EXPR]
    bl   split_conj
    mov  x23, #0
3:  ldr  x9, [sp]
    cmp  x23, x9
    b.hs 4f
    ldr  x9, [sp, #16]
    ldr  x0, [x9, x23, lsl #3]
    ldr  x1, [x19, #PN_RV]
    mov  x2, x20
    bl   simple_pred
    cbz  x0, 31f
    mov  x1, x0
    add  x0, sp, #32
    bl   pvec_push
31: add  x23, x23, #1
    b    3b
4:  ldr  x9, [sp, #48]
    str  x9, [x19, #PN_PREDS]
    ldr  x9, [sp, #32]
    str  x9, [x19, #PN_NPREDS]
    cbz  x9, .Lap_noest
    // row groups excluded by the predicates (EXPLAIN information)
    mov  x23, #0
    mov  x26, #0
41: ldr  x9, [x20, #TBL_NRG]
    cmp  x23, x9
    b.hs 42f
    ldr  x0, [x19, #PN_PREDS]
    ldr  x1, [x19, #PN_NPREDS]
    mov  x2, x20
    ldr  x3, [x20, #TBL_RGS]
    add  x3, x3, x23, lsl #5            // RG_SIZE = 32
    bl   rg_skippable
    add  x26, x26, x0
    add  x23, x23, #1
    b    41b
42: str  w26, [x19, #PN_RGSKIP]
    mov  x0, x20
    bl   table_stats
    mov  x24, x0
    // estimate: product of the predicate selectivities
    fmov d0, #1.0
    str  d0, [sp, #56]
    ldr  x9, =0x4000000000000000        // best sel = 2.0
    str  x9, [sp, #64]
    mov  x27, #0
    mov  x23, #0
5:  ldr  x9, [x19, #PN_NPREDS]
    cmp  x23, x9
    b.hs .Lap_choose
    ldr  x9, [x19, #PN_PREDS]
    ldr  x26, [x9, x23, lsl #3]
    ldr  w9, [x26, #PR_NULL]            // ranges: both bounds of a column
    cbnz w9, 52f                        // count once, combined
    ldr  w9, [x26, #PR_OP]
    cmp  w9, #OP_LT
    b.lo 52f
    cmp  w9, #OP_GE
    b.hi 52f
    mov  x0, x26
    bl   find_bounds
    cmp  x0, x26
    b.eq 53f
    cbnz x0, 54f                        // counted with its lower bound
    cmp  x1, x26
    b.ne 54f
53: mov  x2, x20
    mov  x3, x24
    ldr  x9, [x26, #PR_COL]
    add  x3, x3, x9, lsl #5
    bl   range_sel
    b    55f
52: mov  x0, x26
    mov  x1, x20
    mov  x2, x24
    bl   pred_sel
55: ldr  d1, [sp, #56]
    fmul d1, d1, d0
    str  d1, [sp, #56]
54:
    // index candidate for this predicate
    TLS_ADDR x9, g_use_indexes
    ldr  w9, [x9]
    cbz  w9, 59f
    ldr  w9, [x26, #PR_NULL]
    ldr  w10, [x26, #PR_OP]
    cbnz w9, 51f
    cmp  w10, #OP_EQ
    b.eq 51f
    cmp  w10, #PRO_IN
    b.eq 51f
    // range candidate: BTREE on the column, combine both bounds
    mov  x0, x20
    ldr  x1, [x26, #PR_COL]
    mov  w2, #1
    bl   index_for_column
    cbz  x0, 59f
    str  x0, [sp, #88]
    mov  x0, x26
    bl   find_bounds                    // x0 lo, x1 hi (uses x19)
    stp  x0, x1, [sp, #40]              // (preds Vec copied to the node)
    mov  x2, x20
    mov  x3, x24
    ldr  x9, [x26, #PR_COL]
    add  x3, x3, x9, lsl #5
    bl   range_sel
    ldr  d1, [sp, #64]
    fcmp d0, d1
    b.pl 59f
    str  d0, [sp, #64]
    ldr  x27, [sp, #88]
    mov  x28, #IAK_RANGE
    ldp  x9, x10, [sp, #40]
    stp  x9, x10, [sp, #72]
    b    59f
51: mov  x0, x20                        // equality candidate: any index
    ldr  x1, [x26, #PR_COL]
    mov  w2, #0
    bl   index_for_column
    cbz  x0, 59f
    str  x0, [sp, #88]
    mov  x0, x26
    mov  x1, x20
    mov  x2, x24
    bl   pred_sel
    ldr  d1, [sp, #64]
    fcmp d0, d1
    b.pl 59f
    str  d0, [sp, #64]
    ldr  x27, [sp, #88]
    mov  x28, #IAK_EQ
    str  x26, [sp, #72]
59: add  x23, x23, #1
    b    5b
.Lap_choose:
    cbz  x27, .Lap_est
    ldr  d0, [sp, #64]                  // selective enough?
    ADR_L x9, k_tenth
    ldr  d1, [x9]
    fcmp d0, d1
    b.ls 7f
    cmp  x28, #IAK_EQ
    b.ne .Lap_est
    ucvtf d1, x25                       // equality lookup of few rows
    fmul d0, d0, d1
    ADR_L x9, k_small
    ldr  d1, [x9]
    fcmp d0, d1
    b.hi .Lap_est
7:  mov  x0, #IA_SIZE
    bl   arena_zalloc
    str  w28, [x0, #IA_KIND]
    ldr  x9, [sp, #72]
    cmp  x28, #IAK_EQ
    b.ne 71f
    str  x9, [x0, #IA_EQ]
    b    72f
71: ldr  x10, [sp, #80]
    stp  x9, x10, [x0, #IA_LO]
72: str  x0, [x19, #PN_IXA]
    str  x27, [x19, #PN_IDX]
.Lap_est:
    ldr  d0, [sp, #56]
    ucvtf d1, x25
    fmul d0, d0, d1
    fcvtpu x0, d0
    cmp  x0, x25
    csel x0, x0, x25, ls
    cbnz x0, .Lap_ret
    cmp  x25, #0
    cset x0, ne
    b    .Lap_ret
.Lap_noest:
    mov  x0, x25
.Lap_ret:
    str  x0, [x19, #PN_EST]
    add  sp, sp, #96
    LEAVE 5
ENDF ap_scan

// =============================================================================
// scan_estimate(x0 BoundQuery*, x1 rv index, x2 predicate or 0) -> x0 rows
// Runs the estimation on a scratch scan node; the access path chosen on the
// way is discarded with it.
//   x19 predicate
// =============================================================================
FUNC scan_estimate
    ENTER 1
    stp  x0, x1, [sp, #-16]!
    mov  x19, x2
    mov  x0, #PN_SIZE
    bl   arena_zalloc
    ldp  x9, x10, [sp], #16
    str  x9, [x0, #PN_BQ]
    str  x10, [x0, #PN_RV]
    str  x19, [x0, #PN_EXPR]
    bl   ap_scan
    LEAVE 1
ENDF scan_estimate

// find_bounds(x0 Pred*) -> x0 lower-bound Pred* (GT/GE) or 0, x1 upper-bound
// Pred* (LT/LE) or 0, among the scan's predicates on the same column.
// Helper of ap_scan: reads its x19 (scan node).   (leaf)
LFUNC find_bounds
    ldr  x9, [x0, #PR_COL]
    ldr  x10, [x19, #PN_PREDS]
    ldr  x11, [x19, #PN_NPREDS]
    mov  x0, #0
    mov  x1, #0
1:  cbz  x11, 9f
    ldr  x12, [x10], #8
    sub  x11, x11, #1
    ldr  x13, [x12, #PR_COL]
    cmp  x13, x9
    b.ne 1b
    ldr  w13, [x12, #PR_NULL]
    cbnz w13, 1b
    ldr  w13, [x12, #PR_OP]
    cmp  w13, #OP_LT
    b.eq 2f
    cmp  w13, #OP_LE
    b.eq 2f
    cmp  w13, #OP_GT
    b.eq 3f
    cmp  w13, #OP_GE
    b.ne 1b
3:  cbnz x0, 1b
    mov  x0, x12
    b    1b
2:  cbnz x1, 1b
    mov  x1, x12
    b    1b
9:  ret
ENDF find_bounds

// =============================================================================
// rg_skippable(x0 Pred** preds, x1 n, x2 Table*, x3 RowGroup*) -> x0 1 if no
// row of the group can satisfy all predicates (min/max/null statistics).
//   x19 preds, x20 n, x21 table, x22 rg, x23 pred, x24 ChunkStat, w25 type,
//   x26 i / value index
// =============================================================================
FUNC rg_skippable
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    ldr  x9, [x22, #RG_NROWS]
    cbz  x9, .Lrg_yes
1:  cbz  x20, .Lrg_no
    ldr  x23, [x19], #8
    sub  x20, x20, #1
    ldr  w9, [x23, #PR_NULL]
    cbnz w9, .Lrg_yes
    ldr  x9, [x23, #PR_COL]
    ldr  x24, [x22, #RG_CHUNKS]
    cbz  x24, 1b
    add  x24, x24, x9, lsl #5           // CK_SIZE = 32
    ldr  x10, [x21, #TBL_COLS]
    add  x10, x10, x9, lsl #5
    ldr  w25, [x10, #COL_TYPE]
    ldr  x9, [x24, #CK_NULLS]           // only NULLs: no comparison is true
    ldr  x10, [x22, #RG_NROWS]
    cmp  x9, x10
    b.hs .Lrg_yes
    ldr  w9, [x24, #CK_HASMM]
    cbz  w9, 1b
    ldr  w9, [x23, #PR_OP]
    cmp  w9, #PRO_IN
    b.eq .Lrg_in
    ldr  x1, [x23, #PR_VAL]
    bl   .Lrg_cmp_min                   // w0 = cmp(min, v)
    ldr  w9, [x23, #PR_OP]
    cmp  w9, #OP_LT                     // min >= v
    b.ne 2f
    tbz  w0, #31, .Lrg_yes
    b    1b
2:  cmp  w9, #OP_LE                     // min > v
    b.ne 3f
    cmp  w0, #0
    b.gt .Lrg_yes
    b    1b
3:  cmp  w9, #OP_EQ                     // min > v or max < v
    b.ne 4f
    cmp  w0, #0
    b.gt .Lrg_yes
4:  ldr  x1, [x23, #PR_VAL]
    bl   .Lrg_cmp_max                   // w0 = cmp(max, v)
    ldr  w9, [x23, #PR_OP]
    cmp  w9, #OP_EQ
    b.ne 5f
    tbnz w0, #31, .Lrg_yes
    b    1b
5:  cmp  w9, #OP_GT                     // max <= v
    b.ne 6f
    cmp  w0, #0
    b.le .Lrg_yes
    b    1b
6:  cmp  w9, #OP_GE                     // max < v
    b.ne 1b
    tbnz w0, #31, .Lrg_yes
    b    1b
.Lrg_in:                                // every value outside [min, max]
    mov  x26, #0
7:  ldr  x9, [x23, #PR_N]
    cmp  x26, x9
    b.hs .Lrg_yes
    ldr  x9, [x23, #PR_VAL]
    ldr  x1, [x9, x26, lsl #3]
    bl   .Lrg_cmp_min
    cmp  w0, #0
    b.gt 8f
    ldr  x9, [x23, #PR_VAL]
    ldr  x1, [x9, x26, lsl #3]
    bl   .Lrg_cmp_max
    tbz  w0, #31, 1b                    // inside: cannot skip
8:  add  x26, x26, #1
    b    7b
.Lrg_yes:
    mov  x0, #1
    LEAVE 5
.Lrg_no:
    mov  x0, #0
    LEAVE 5
// local helpers sharing the frame: compare the chunk's min / max with x1
.Lrg_cmp_min:
    ldr  x0, [x24, #CK_MIN]
    b    9f
.Lrg_cmp_max:
    ldr  x0, [x24, #CK_MAX]
9:  mov  w2, w25
    ldr  w3, [x23, #PR_TYPE]
    b    cmp_typed                      // leaf: returns to our caller
ENDF rg_skippable

    NOTE_GNU_STACK
