// =============================================================================
// binder.S — semantic analysis: name resolution, typing, aggregation checks.
//
//   bind_query(x0 Query*) -> x0 BoundQuery*      (raises SEMANTIC / TYPE /
//                                                 UNSUPPORTED / INVALID_ARGUMENT)
//
// Structure:
//   * One binder context (BC_*) per query level (main query, each subquery,
//     derived table and CTE body). It carries the query, the BoundQuery under
//     construction, the scope (range variables, RV_*), the clause flags
//     (BF_*), growable vectors for aggregate slots and hidden ORDER BY
//     expressions, the parent context (outer scopes for correlation), the
//     visible CTEs and the statement-wide list of subplans.
//   * Column resolution walks the context chain: the current FROM first, then
//     enclosing queries (correlated references, N_OP = depth). The FROM of a
//     query is invisible to its own derived tables / CTE bodies (BC_HIDE).
//   * bind_expr(ctx, node) is a recursive dispatcher; binding mutates the AST
//     in place (request arena) and may wrap operands in implicit NK_CAST nodes
//     so that at run time operators see operands of one type kind.
//     Scalar functions, CASE, LIKE, BETWEEN and IN lists live in functions.S.
//   * Aggregate calls become NK_AGG slots. Whether a query is aggregated is
//     known only after all clauses are bound; then group_rewrite replaces
//     GROUP BY expressions by NK_GKEY and rejects remaining column references.
//   * Subqueries / derived tables / CTE bodies are bound recursively into their
//     own BoundQuery wrapped in a SubPlan; every SubPlan is registered in the
//     statement-wide vector BQ_SPV of the root query for the planner.
//   * Nothing is evaluated during binding except constants (LIMIT/OFFSET),
//     which happens last so that semantic/type errors take precedence.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// ------------------------------------------------------- binder context -----
#define BC_Q        0       // Query*
#define BC_BQ       8       // BoundQuery*
#define BC_NRV      16      // u64 number of range variables in scope
#define BC_RVS      24      // RV* array (capacity MAX_RV)
#define BC_FLAGS    32      // u32 BF_* flags of the clause being bound
#define BC_HIDE     36      // u32 1 = the parent's range variables are invisible
#define BC_AGGV     40      // Vec of NK_AGG Node* (slot order)
#define BC_EXV      64      // Vec of hidden ORDER BY expressions
#define BC_PARENT   88      // enclosing BindCtx* or 0
#define BC_CTES     96      // CteList* visible CTEs (innermost first)
#define BC_CORR     104     // u64 1 = references an enclosing query
#define BC_SPV      112     // Vec* statement-wide SubPlan list
#define BC_RVLO     120     // u64 first range variable visible (ON clauses
                            //   see only their own from_item)
#define BC_OREFS    128     // Vec of outer references from subqueries in
                            //   SELECT / HAVING / ORDER BY (grouping check)
#define BC_SIZE     160

#define MAX_RV      64

// CTE scope list node
#define CL_NAME     0       // Str*
#define CL_DEF      8       // CteDef*
#define CL_NEXT     16      // CteList*
#define CL_OWNER    24      // BindCtx* of the query owning the WITH
#define CL_SIZE     32

// Growable vector of pointers (arena backed)
#define V_N         0
#define V_CAP       8
#define V_DATA      16
#define V_SIZE      24

// Clause flags
#define BF_AGG_OK   1       // aggregates allowed (SELECT list, HAVING, ORDER BY)
#define BF_IN_AGG   2       // currently inside an aggregate argument
#define BF_NO_COLS  4       // column references forbidden (LIMIT / OFFSET)

#define DEC18       (T_DEC | (18 << T_PREC_SHIFT))   // DECIMAL(18,0)

// =============================================================================
// bind_query(x0 Query*) -> x0 BoundQuery*   (root of a statement)
// The root BoundQuery carries the statement's SubPlan list in BQ_SPV.
//   x19 SubPlan vector
// =============================================================================
FUNC bind_query
    ENTER 2
    mov  x20, x0
    mov  x0, #V_SIZE
    bl   arena_zalloc
    mov  x19, x0
    mov  x0, x20
    mov  x1, #0                         // no parent
    mov  w2, #0
    mov  x3, x19
    mov  x4, #0                         // no CTEs
    bl   bq_bind
    str  x19, [x0, #BQ_SPV]
    LEAVE 2
ENDF bind_query

// =============================================================================
// bq_bind(x0 Query*, x1 parent ctx or 0, w2 hide parent rvs, x3 SubPlan Vec*,
//         x4 visible CTE list) -> x0 BoundQuery*
// Binds one query level: WITH, FROM, SELECT, WHERE, GROUP BY, HAVING,
// ORDER BY, aggregation checks, LIMIT/OFFSET.
//   x19 ctx, x20 Query*, x21 BoundQuery*, x22/x23 bound LIMIT/OFFSET exprs
// =============================================================================
LFUNC bq_bind
    ldr  x9, [x0, #Q_NUNION]            // UNION ALL compound
    cbnz x9, bq_bind_union
    ENTER 3
    mov  x20, x0
    stp  x1, x2, [sp, #-32]!
    stp  x3, x4, [sp, #16]
    mov  x0, #BC_SIZE
    bl   arena_zalloc
    mov  x19, x0
    ldp  x1, x2, [sp]
    ldp  x3, x4, [sp, #16]
    add  sp, sp, #32
    str  x20, [x19, #BC_Q]
    str  x1, [x19, #BC_PARENT]
    str  w2, [x19, #BC_HIDE]
    str  x3, [x19, #BC_SPV]
    str  x4, [x19, #BC_CTES]
    mov  x0, #BQ_SIZE
    bl   arena_zalloc
    mov  x21, x0
    str  x21, [x19, #BC_BQ]
    mov  x9, #-1
    str  x9, [x21, #BQ_LIMIT]
    ldr  w9, [x20, #Q_DISTINCT]
    str  x9, [x21, #BQ_DISTINCT]
    mov  x0, #(RV_SIZE * MAX_RV)
    bl   arena_zalloc
    str  x0, [x19, #BC_RVS]
    str  x0, [x21, #BQ_RVS]

    // --- WITH ---------------------------------------------------------------
    mov  x0, x19
    bl   bind_with

    // --- FROM ---------------------------------------------------------------
    ldr  x1, [x20, #Q_FROM]
    cbz  x1, 1f
    mov  x0, x19
    bl   bind_from
    str  x0, [x21, #BQ_FROM]
1:  ldr  x9, [x19, #BC_NRV]
    str  x9, [x21, #BQ_NRV]

    // --- SELECT list --------------------------------------------------------
    mov  x0, x19
    bl   bind_select

    // --- WHERE (no aggregates; BOOLEAN or null type) ------------------------
    ldr  x1, [x20, #Q_WHERE]
    cbz  x1, 2f
    str  wzr, [x19, #BC_FLAGS]
    mov  x0, x19
    bl   bind_expr
    str  x0, [x21, #BQ_WHERE]
    bl   check_bool
2:
    // --- GROUP BY -----------------------------------------------------------
    mov  x0, x19
    bl   bind_group

    // --- HAVING (aggregates allowed; BOOLEAN) --------------------------------
    ldr  x1, [x20, #Q_HAVING]
    cbz  x1, 3f
    mov  w9, #BF_AGG_OK
    str  w9, [x19, #BC_FLAGS]
    mov  x0, x19
    bl   bind_expr
    str  x0, [x21, #BQ_HAVING]
    bl   check_bool
3:
    // --- ORDER BY -----------------------------------------------------------
    mov  x0, x19
    bl   bind_order

    // --- aggregation --------------------------------------------------------
    mov  x0, x19
    bl   finish_aggregation

    // --- LIMIT / OFFSET: bind both (type check), then evaluate --------------
    mov  x0, x19
    ldr  x1, [x20, #Q_LIMIT]
    bl   bind_limit_expr
    mov  x22, x0
    mov  x0, x19
    ldr  x1, [x20, #Q_OFFSET]
    bl   bind_limit_expr
    mov  x23, x0
    mov  x0, x22
    mov  x1, #-1
    bl   eval_limit
    str  x0, [x21, #BQ_LIMIT]
    mov  x0, x23
    mov  x1, #0
    bl   eval_limit
    str  x0, [x21, #BQ_OFFSET]

    ldr  x9, [x19, #BC_CORR]
    str  x9, [x21, #BQ_CORR]
    mov  x0, x21
    LEAVE 3
ENDF bq_bind

// =============================================================================
// bq_bind_union(x0 Query*, x1 parent ctx or 0, w2 hide parent rvs,
//               x3 SubPlan Vec*, x4 visible CTE list) -> x0 BoundQuery*
// Binds a UNION ALL compound (spec/changes/union-all.md). The compound is a
// query level of its own without range variables: it owns the WITH clause
// (visible to every branch), the branches are bound as nested levels below
// it, and ORDER BY / LIMIT / OFFSET apply to the concatenated result.
// Output column i: name of the first branch, common type of column i of all
// branches (CASE rule, common_type); branch expressions of another type are
// wrapped in an implicit CAST, so every branch produces rows of the
// compound's types. ORDER BY may only name output columns (bind_order).
//   x19 ctx, x20 Query*, x21 BoundQuery*, x22 branch BoundQuery** array,
//   x23 branches, x24 branch index, x25 column index, w26 type, x27 nout,
//   x28 OutCol*
// =============================================================================
LFUNC bq_bind_union
    ENTER 5
    mov  x20, x0
    stp  x1, x2, [sp, #-32]!
    stp  x3, x4, [sp, #16]
    mov  x0, #BC_SIZE
    bl   arena_zalloc
    mov  x19, x0
    ldp  x1, x2, [sp]
    ldp  x3, x4, [sp, #16]
    add  sp, sp, #32
    str  x20, [x19, #BC_Q]
    str  x1, [x19, #BC_PARENT]
    str  w2, [x19, #BC_HIDE]
    str  x3, [x19, #BC_SPV]
    str  x4, [x19, #BC_CTES]
    mov  x0, #BQ_SIZE
    bl   arena_zalloc
    mov  x21, x0
    str  x21, [x19, #BC_BQ]
    mov  x9, #-1
    str  x9, [x21, #BQ_LIMIT]
    mov  x0, #RV_SIZE                   // no range variables
    bl   arena_zalloc
    str  x0, [x19, #BC_RVS]
    str  x0, [x21, #BQ_RVS]

    mov  x0, x19                        // WITH (shared by all branches)
    bl   bind_with

    // --- branches -----------------------------------------------------------
    ldr  x23, [x20, #Q_NUNION]
    lsl  x0, x23, #3
    bl   arena_zalloc
    mov  x22, x0
    str  x22, [x21, #BQ_UNION]
    str  x23, [x21, #BQ_NUNION]
    mov  x24, #0
1:  cmp  x24, x23
    b.hs 2f
    ldr  x9, [x20, #Q_UNION]
    ldr  x0, [x9, x24, lsl #3]
    mov  x1, x19
    mov  w2, #0
    ldr  x3, [x19, #BC_SPV]
    ldr  x4, [x19, #BC_CTES]
    bl   bq_bind
    str  x0, [x22, x24, lsl #3]
    ldr  x9, [x0, #BQ_NOUT]             // same number of columns
    ldr  x10, [x22]
    ldr  x10, [x10, #BQ_NOUT]
    cmp  x9, x10
    b.ne .Lbq_u_ncols
    add  x24, x24, #1
    b    1b

    // --- output columns: names of branch 0, common types --------------------
2:  ldr  x9, [x22]
    ldr  x27, [x9, #BQ_NOUT]
    lsl  x0, x27, #5                    // OC_SIZE = 32
    add  x0, x0, #OC_SIZE
    bl   arena_zalloc
    mov  x28, x0
    str  x27, [x21, #BQ_NOUT]
    str  x28, [x21, #BQ_OUT]
    mov  x25, #0
3:  cmp  x25, x27
    b.hs 7f
    ldr  x9, [x22]
    ldr  x9, [x9, #BQ_OUT]
    add  x9, x9, x25, lsl #5
    ldr  w26, [x9, #OC_TYPE]
    add  x10, x28, x25, lsl #5
    ldr  x11, [x9, #OC_NAME]
    str  x11, [x10, #OC_NAME]
    ldr  w11, [x9, #OC_ALIASED]
    str  w11, [x10, #OC_ALIASED]
    mov  x24, #1
4:  cmp  x24, x23
    b.hs 5f
    ldr  x9, [x22, x24, lsl #3]
    ldr  x9, [x9, #BQ_OUT]
    add  x9, x9, x25, lsl #5
    mov  w0, w26
    ldr  w1, [x9, #OC_TYPE]
    bl   common_type
    cmn  w0, #1
    b.eq .Lbq_u_type
    mov  w26, w0
    add  x24, x24, #1
    b    4b
5:  add  x10, x28, x25, lsl #5
    str  w26, [x10, #OC_TYPE]
    mov  x24, #0                        // convert the branch columns
6:  cmp  x24, x23
    b.hs 61f
    ldr  x9, [x22, x24, lsl #3]
    ldr  x9, [x9, #BQ_OUT]
    add  x9, x9, x25, lsl #5
    ldr  w10, [x9, #OC_TYPE]
    cmp  w10, w26
    b.eq 60f
    str  x9, [sp, #-16]!
    ldr  x0, [x9, #OC_EXPR]
    mov  w1, w26
    bl   mk_cast                        // (NULL-typed: unchanged)
    ldr  x9, [sp], #16
    str  x0, [x9, #OC_EXPR]
    ldr  w10, [x0, #N_TYPE]
    str  w10, [x9, #OC_TYPE]
60: add  x24, x24, #1
    b    6b
61: add  x25, x25, #1
    b    3b

    // --- ORDER BY (output columns only), LIMIT / OFFSET ---------------------
7:  mov  x0, x19
    bl   bind_order
    mov  x0, x19
    ldr  x1, [x20, #Q_LIMIT]
    bl   bind_limit_expr
    mov  x22, x0
    mov  x0, x19
    ldr  x1, [x20, #Q_OFFSET]
    bl   bind_limit_expr
    mov  x23, x0
    mov  x0, x22
    mov  x1, #-1
    bl   eval_limit
    str  x0, [x21, #BQ_LIMIT]
    mov  x0, x23
    mov  x1, #0
    bl   eval_limit
    str  x0, [x21, #BQ_OFFSET]

    ldr  x9, [x19, #BC_CORR]
    str  x9, [x21, #BQ_CORR]
    mov  x0, x21
    LEAVE 5
.Lbq_u_ncols:
    RAISE ERR_SEMANTIC, "each UNION ALL branch must have the same number of columns"
.Lbq_u_type:
    add  x9, x28, x25, lsl #5
    ldr  x9, [x9, #OC_NAME]
    RAISE_S ERR_TYPE, "UNION ALL branches have incompatible types for column ", x9
ENDF bq_bind_union

// check_bool(x0 bound Node*): WHERE / HAVING / ON conditions must be BOOLEAN
// (or of the null type).   (leaf)
LFUNC check_bool
    ldrb w9, [x0, #N_TYPE]
    cmp  w9, #T_NULL
    b.eq 1f
    cmp  w9, #T_BOOL
    b.ne 2f
1:  ret
2:  RAISE ERR_TYPE, "condition must be BOOLEAN"
ENDF check_bool

// =============================================================================
// new_subplan(x0 ctx, x1 BoundQuery*) -> x0 SubPlan* (registered in BC_SPV)
//   x19 ctx, x20 SubPlan*
// =============================================================================
LFUNC new_subplan
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x0, #SP_SIZE
    bl   arena_zalloc
    str  x20, [x0, #SP_BQ]
    mov  x20, x0
    ldr  x0, [x19, #BC_SPV]
    mov  x1, x20
    bl   vec_push
    mov  x0, x20
    LEAVE 2
ENDF new_subplan

// =============================================================================
// shape_table(x0 BoundQuery*, x1 Str** names or 0, x2 nnames) -> x0 Table*
// A data-less table describing a subquery's output (names, types). With a
// CTE column list the names are replaced (count mismatch => SEMANTIC_ERROR).
//   x19 bq, x20 names, x21 nnames, x22 Table*, x23 index, x24 ncols
// =============================================================================
LFUNC shape_table
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x24, [x19, #BQ_NOUT]
    cbz  x20, 1f
    cmp  x21, x24
    b.ne .Lsh_count
1:  mov  x0, #TBL_SIZE
    bl   arena_zalloc
    mov  x22, x0
    str  x24, [x22, #TBL_NCOLS]
    lsl  x0, x24, #5                    // COL_SIZE = 32
    add  x0, x0, #COL_SIZE
    bl   arena_zalloc
    str  x0, [x22, #TBL_COLS]
    mov  x23, #0
2:  cmp  x23, x24
    b.hs 4f
    ldr  x9, [x19, #BQ_OUT]
    add  x9, x9, x23, lsl #5            // OutCol
    ldr  x10, [x22, #TBL_COLS]
    add  x10, x10, x23, lsl #5          // Column
    ldr  x11, [x9, #OC_NAME]
    cbz  x20, 3f
    ldr  x11, [x20, x23, lsl #3]
3:  str  x11, [x10, #COL_NAME]
    ldr  w11, [x9, #OC_TYPE]
    str  w11, [x10, #COL_TYPE]
    add  x23, x23, #1
    b    2b
4:  mov  x0, x22
    LEAVE 3
.Lsh_count:
    RAISE ERR_SEMANTIC, "CTE column list does not match the number of columns"
ENDF shape_table

// =============================================================================
// bind_with(x0 ctx) — binds the CTEs of the query in order. Each CTE body sees
// the CTEs visible outside plus the earlier CTEs of this WITH (not itself).
//   x19 ctx, x20 CTE cursor, x21 CTEs left, x22 BoundQuery*, x23 CteDef*,
//   x24 list node
// =============================================================================
LFUNC bind_with
    ENTER 3
    mov  x19, x0
    ldr  x9, [x19, #BC_Q]
    ldr  x20, [x9, #Q_CTES]
    ldr  x21, [x9, #Q_NCTES]
.Lbw_loop:
    cbz  x21, .Lbw_end
    // duplicate name within this WITH?
    ldr  x24, [x19, #BC_CTES]
1:  cbz  x24, 2f
    ldr  x9, [x24, #CL_OWNER]
    cmp  x9, x19
    b.ne 2f                             // entries of outer WITHs come later
    ldr  x0, [x24, #CL_NAME]
    ldr  x1, [x20, #CTE_NAME]
    bl   str_ieq
    cbnz w0, .Lbw_dup
    ldr  x24, [x24, #CL_NEXT]
    b    1b
2:  // bind the body (this query's FROM is not visible; it has none yet)
    ldr  x0, [x20, #CTE_QUERY]
    mov  x1, x19
    mov  w2, #1
    ldr  x3, [x19, #BC_SPV]
    ldr  x4, [x19, #BC_CTES]
    bl   bq_bind
    mov  x22, x0
    mov  x0, #CD_SIZE
    bl   arena_zalloc
    mov  x23, x0
    ldr  x9, [x20, #CTE_NAME]
    str  x9, [x23, #CD_NAME]
    mov  x0, x19
    mov  x1, x22
    bl   new_subplan
    str  x0, [x23, #CD_SP]
    mov  x0, x22
    ldr  x1, [x20, #CTE_COLS]
    ldr  x2, [x20, #CTE_NCOLS]
    bl   shape_table
    str  x0, [x23, #CD_SHAPE]
    mov  x0, #CL_SIZE
    bl   arena_zalloc
    ldr  x9, [x20, #CTE_NAME]
    str  x9, [x0, #CL_NAME]
    str  x23, [x0, #CL_DEF]
    ldr  x9, [x19, #BC_CTES]
    str  x9, [x0, #CL_NEXT]
    str  x19, [x0, #CL_OWNER]
    str  x0, [x19, #BC_CTES]
    add  x20, x20, #CTE_SIZE
    sub  x21, x21, #1
    b    .Lbw_loop
.Lbw_end:
    LEAVE 3
.Lbw_dup:
    ldr  x9, [x20, #CTE_NAME]
    RAISE_S ERR_SEMANTIC, "duplicate CTE name ", x9
ENDF bind_with

// =============================================================================
// add_rv(x0 ctx, x1 Str* name, x2 Table*, w3 kind, x4 sub, w5 cte levels up)
//   -> x0 rv index.  Duplicate range variable names => SEMANTIC_ERROR.
//   x19 ctx, x20 name, x21 index, x22 RV*
// =============================================================================
LFUNC add_rv
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    sub  sp, sp, #32
    stp  x2, x3, [sp]
    stp  x4, x5, [sp, #16]
    mov  x21, #0
1:  ldr  x9, [x19, #BC_NRV]
    cmp  x21, x9
    b.hs 2f
    mov  x0, x19
    mov  x1, x21
    bl   rv_ptr
    ldr  x0, [x0, #RV_NAME]
    mov  x1, x20
    bl   str_ieq
    cbnz w0, .Lar_dup
    add  x21, x21, #1
    b    1b
2:  cmp  x21, #MAX_RV
    b.hs .Lar_many
    mov  x0, x19
    mov  x1, x21
    bl   rv_ptr
    mov  x22, x0
    str  x20, [x22, #RV_NAME]
    ldp  x2, x3, [sp]
    ldp  x4, x5, [sp, #16]
    str  x2, [x22, #RV_TABLE]
    str  w3, [x22, #RV_KIND]
    str  w5, [x22, #RV_CTEUP]
    str  x4, [x22, #RV_SUB]
    ldr  x0, [x2, #TBL_NCOLS]
    add  x0, x0, #1
    bl   arena_zalloc
    str  x0, [x22, #RV_USED]
    add  x9, x21, #1
    str  x9, [x19, #BC_NRV]
    mov  x0, x21
    add  sp, sp, #32
    LEAVE 3
.Lar_dup:
    RAISE_S ERR_SEMANTIC, "duplicate table name or alias in FROM: ", x20
.Lar_many:
    RAISE ERR_RESOURCE_LIMIT, "too many tables in FROM"
ENDF add_rv

// =============================================================================
// bind_from(x0 ctx, x1 FromItem*) -> x0 BoundFrom*
// Adds range variables in FROM order and binds ON conditions (which see every
// range variable introduced so far).
//   x19 ctx, x20 FromItem*, x21 BoundFrom*, x22 Table* / scratch,
//   x23 CTE list cursor, x24 levels up
// =============================================================================
LFUNC bind_from
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x0, #BF_SIZE
    bl   arena_zalloc
    mov  x21, x0
    ldr  x9, [x19, #BC_NRV]
    str  w9, [x21, #BF_LO]
    ldr  w9, [x20, #FR_KIND]
    cmp  w9, #FRK_JOIN
    b.eq .Lbf_join
    cmp  w9, #FRK_SUBQUERY
    b.eq .Lbf_derived

    // ---- table name: CTE (innermost first), then catalog -------------------
    ldr  x23, [x19, #BC_CTES]
    mov  x24, #0                        // levels from ctx up to the owner
    mov  x22, x19                       // ctx whose level x24 counts
.Lbf_cte:
    cbz  x23, .Lbf_catalog
    ldr  x0, [x23, #CL_NAME]
    ldr  x1, [x20, #FR_NAME]
    bl   str_ieq
    cbnz w0, .Lbf_found_cte
    ldr  x23, [x23, #CL_NEXT]
    b    .Lbf_cte
.Lbf_found_cte:
    ldr  x9, [x23, #CL_OWNER]           // count levels up to the owner
1:  cmp  x22, x9
    b.eq 2f
    ldr  x22, [x22, #BC_PARENT]
    add  x24, x24, #1
    b    1b
2:  ldr  x10, [x23, #CL_DEF]
    ldr  x1, [x20, #FR_ALIAS]
    cbnz x1, 3f
    ldr  x1, [x20, #FR_NAME]
3:  mov  x0, x19
    ldr  x2, [x10, #CD_SHAPE]
    mov  w3, #RVK_CTE
    mov  x4, x10
    mov  w5, w24
    bl   add_rv
    b    .Lbf_leaf
.Lbf_catalog:
    ldr  x9, [x20, #FR_NAME]
    add  x0, x9, #STR_DATA
    ldr  x1, [x9, #STR_LEN]
    bl   catalog_find
    cbz  x0, .Lbf_unknown
    mov  x2, x0
    ldr  x1, [x20, #FR_ALIAS]
    cbnz x1, 4f
    ldr  x1, [x20, #FR_NAME]
4:  mov  x0, x19
    mov  w3, #RVK_BASE
    mov  x4, #0
    mov  w5, #0
    bl   add_rv
    b    .Lbf_leaf

    // ---- derived table (query) alias ----------------------------------------
.Lbf_derived:
    ldr  x0, [x20, #FR_LEFT]
    mov  x1, x19
    mov  w2, #1                         // this FROM is invisible inside
    ldr  x3, [x19, #BC_SPV]
    ldr  x4, [x19, #BC_CTES]
    bl   bq_bind
    mov  x22, x0
    mov  x0, x19
    mov  x1, x22
    bl   new_subplan
    mov  x23, x0
    mov  x0, x22
    mov  x1, #0
    mov  x2, #0
    bl   shape_table
    mov  x2, x0
    mov  x0, x19
    ldr  x1, [x20, #FR_ALIAS]
    mov  w3, #RVK_DERIVED
    mov  x4, x23
    mov  w5, #0
    bl   add_rv

.Lbf_leaf:
    mov  w9, #BFK_RV
    str  w9, [x21, #BF_KIND]
    str  x0, [x21, #BF_RV]
    add  w9, w0, #1
    str  w9, [x21, #BF_HI]
    mov  x0, x21
    LEAVE 4

    // ---- join -----------------------------------------------------------------
.Lbf_join:
    mov  w9, #BFK_JOIN
    str  w9, [x21, #BF_KIND]
    ldr  w9, [x20, #FR_JOIN]
    str  w9, [x21, #BF_JT]
    mov  x0, x19
    ldr  x1, [x20, #FR_LEFT]
    bl   bind_from
    str  x0, [x21, #BF_LEFT]
    mov  x0, x19
    ldr  x1, [x20, #FR_RIGHT]
    bl   bind_from
    str  x0, [x21, #BF_RIGHT]
    ldr  x9, [x19, #BC_NRV]
    str  w9, [x21, #BF_HI]
    ldr  x1, [x20, #FR_ON]
    cbz  x1, 5f
    str  wzr, [x19, #BC_FLAGS]
    ldr  x22, [x19, #BC_RVLO]           // ON sees only this from_item
    ldr  w9, [x21, #BF_LO]
    str  x9, [x19, #BC_RVLO]
    mov  x0, x19
    bl   bind_expr
    str  x0, [x21, #BF_ON]
    str  x22, [x19, #BC_RVLO]
    bl   check_bool
5:  mov  x0, x21
    LEAVE 4
.Lbf_unknown:
    ldr  x9, [x20, #FR_NAME]
    RAISE_S ERR_SEMANTIC, "unknown table ", x9
ENDF bind_from

// =============================================================================
// find_rv(x0 ctx, x1 Str* name) -> x0 range variable index or -1
//   x19 ctx, x20 name, x21 index
// =============================================================================
LFUNC find_rv
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, #0
1:  ldr  x9, [x19, #BC_NRV]
    cmp  x21, x9
    b.hs 3f
    mov  x0, x19
    mov  x1, x21
    bl   rv_ptr
    ldr  x0, [x0, #RV_NAME]
    mov  x1, x20
    bl   str_ieq
    cbnz w0, 2f
    add  x21, x21, #1
    b    1b
2:  mov  x0, x21
    LEAVE 2
3:  mov  x0, #-1
    LEAVE 2
ENDF find_rv

// rv_ptr(x0 ctx, x1 rv index) -> x0 RV*   (leaf)
LFUNC rv_ptr
    ldr  x9, [x0, #BC_RVS]
    mov  x10, #RV_SIZE
    madd x0, x1, x10, x9
    ret
ENDF rv_ptr

// rv_column(x0 ctx, x1 rv index, x2 column index) -> x0 Column*   (leaf)
LFUNC rv_column
    ldr  x9, [x0, #BC_RVS]
    mov  x10, #RV_SIZE
    madd x9, x1, x10, x9
    ldr  x9, [x9, #RV_TABLE]
    ldr  x9, [x9, #TBL_COLS]
    add  x0, x9, x2, lsl #5             // COL_SIZE = 32
    ret
ENDF rv_column

// rv_ncols(x0 ctx, x1 rv index) -> x0 number of columns   (leaf)
LFUNC rv_ncols
    ldr  x9, [x0, #BC_RVS]
    mov  x10, #RV_SIZE
    madd x9, x1, x10, x9
    ldr  x9, [x9, #RV_TABLE]
    ldr  x0, [x9, #TBL_NCOLS]
    ret
ENDF rv_ncols

// rv_mark_used(x0 ctx, x1 rv index, x2 column index, w3 RVU_* flag)   (leaf)
LFUNC rv_mark_used
    ldr  x9, [x0, #BC_RVS]
    mov  x10, #RV_SIZE
    madd x9, x1, x10, x9
    ldr  x9, [x9, #RV_USED]
    ldrb w10, [x9, x2]
    orr  w10, w10, w3
    strb w10, [x9, x2]
    ret
ENDF rv_mark_used

// =============================================================================
// Vectors
// vec_push(x0 Vec*, x1 item) -> x0 index of the item
//   x19 Vec*, x20 item, x21 new capacity, x22 new data
// =============================================================================
LFUNC vec_push
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldp  x9, x10, [x19, #V_N]           // n, cap
    cmp  x9, x10
    b.lo 1f
    lsl  x21, x10, #1                   // grow: cap = max(8, 2 * cap)
    mov  x11, #8
    cmp  x21, x11
    csel x21, x11, x21, lo
    lsl  x0, x21, #3
    bl   arena_alloc
    mov  x22, x0
    ldr  x1, [x19, #V_DATA]
    ldr  x2, [x19, #V_N]
    lsl  x2, x2, #3
    bl   memcpy
    str  x21, [x19, #V_CAP]
    str  x22, [x19, #V_DATA]
1:  ldr  x9, [x19, #V_N]
    ldr  x10, [x19, #V_DATA]
    str  x20, [x10, x9, lsl #3]
    add  x10, x9, #1
    str  x10, [x19, #V_N]
    mov  x0, x9
    LEAVE 2
ENDF vec_push

// =============================================================================
// mk_cast(x0 Node*, w1 type) -> x0 Node*
// Wraps an expression in an implicit CAST. Expressions of the null type are
// returned unchanged (they always evaluate to NULL).
//   x19 operand, w20 target type
// =============================================================================
FUNC mk_cast
    ldrb w9, [x0, #N_TYPE]
    cbnz w9, 1f
    ret                                 // T_NULL operand: no cast needed
1:  ENTER 1
    mov  x19, x0
    mov  w20, w1
    mov  x0, #N_SIZE
    bl   arena_zalloc
    mov  w9, #NK_CAST
    str  w9, [x0, #N_KIND]
    str  w20, [x0, #N_TYPE]
    mov  w9, w20
    str  x9, [x0, #N_VAL]
    str  x19, [x0, #N_A]
    ldr  w9, [x19, #N_FLAGS]
    and  w9, w9, #NF_CONST
    str  w9, [x0, #N_FLAGS]
    ldr  x9, [x19, #N_LINE]             // line + column
    str  x9, [x0, #N_LINE]
    LEAVE 1
ENDF mk_cast

// dec_wtype(w0 t1, w1 t2) -> w0 T_DEC | W << T_PREC_SHIFT (scale 0): the
// result precision W of decimal38.md §2 — 38 if t1 or t2 is a wide
// DECIMAL, else 18 (INT64 operands do not count).   (leaf)
FUNC dec_wtype
    mov  w9, w0
    mov  w0, #DEC_TYPE(DEC_MAX_PREC, 0)
    BR_WIDE w9, w10, 1f
    BR_WIDE w1, w10, 1f
    mov  w0, #DEC18
1:  ret
ENDF dec_wtype

// dec_widen(x0 bound Node* of type DECIMAL(p,s), w1 its type) -> x0 Node*
// implicit CAST to DECIMAL(38,s) (exact: a narrow value always fits)
FUNC dec_widen
    and  w1, w1, #(0xff << T_SCALE_SHIFT)
    mov  w9, #DEC_TYPE(DEC_MAX_PREC, 0)
    orr  w1, w1, w9
    b    mk_cast
ENDF dec_widen

// =============================================================================
// bind_expr(x0 ctx, x1 Node*) -> x0 bound Node*  (may differ from the input)
// Dispatcher: tail-calls the binder of the node kind (no frame of its own).
// =============================================================================
FUNC bind_expr
    ldr  w9, [x1, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq bind_lit
    cmp  w9, #NK_COL
    b.eq bind_col
    cmp  w9, #NK_BINARY
    b.eq bind_binary
    cmp  w9, #NK_UNARY
    b.eq bind_unary
    cmp  w9, #NK_FUNC
    b.eq bind_func
    cmp  w9, #NK_CAST
    b.eq bind_cast
    cmp  w9, #NK_ISNULL
    b.eq bind_isnull
    cmp  w9, #NK_CASE
    b.eq bind_case                      // functions.S
    cmp  w9, #NK_BETWEEN
    b.eq bind_between                   // functions.S
    cmp  w9, #NK_IN
    b.eq bind_inlist                    // functions.S
    cmp  w9, #NK_LIKE
    b.eq bind_like                      // functions.S
    cmp  w9, #NK_INSUB
    b.eq .Lbe_subq
    cmp  w9, #NK_EXISTS
    b.eq .Lbe_subq
    cmp  w9, #NK_SUBQ
    b.eq .Lbe_subq
    RAISE ERR_INTERNAL, "binder: unexpected expression node"
.Lbe_subq:
    b    bind_subq
ENDF bind_expr

// bind_lit(x0 ctx, x1 Node*) -> x0 Node*   (leaf)
// Literals are typed by the parser; a NULL literal has the null type.
LFUNC bind_lit
    ldr  w9, [x1, #N_FLAGS]
    orr  w9, w9, #NF_CONST
    str  w9, [x1, #N_FLAGS]
    tbz  w9, #0, 1f                     // NF_NULL == 1
    str  wzr, [x1, #N_TYPE]
1:  mov  x0, x1
    ret
ENDF bind_lit

// =============================================================================
// bind_col(x0 ctx, x1 Node*) -> x0 Node*
// Resolves [q.]c against the range variables of the current query, then of
// the enclosing queries (correlated reference, N_OP = depth). Levels hidden
// by BC_HIDE (a query's FROM seen from its derived tables / CTE bodies) are
// skipped but counted. Every level between the reference and the resolving
// query is marked correlated.
//   x19 ctx being searched, x20 node, x21 rv index, x22 column index,
//   x23 ncols, x24 found rv (-1 none), x25 found column, x26 qualifier
//   matched (any level), x27 depth, x28 starting ctx
// =============================================================================
LFUNC bind_col
    ENTER 5
    mov  x28, x0
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x19, #BC_FLAGS]
    tbnz w9, #2, .Lbc_nocols            // BF_NO_COLS
    mov  x26, #0
    mov  x27, #0
.Lbc_level:
    mov  x24, #-1
    ldr  x21, [x19, #BC_RVLO]
.Lbc_rv:
    ldr  x9, [x19, #BC_NRV]
    cmp  x21, x9
    b.hs .Lbc_level_done
    ldr  x1, [x20, #N_C]                // qualifier must name this rv
    cbz  x1, 1f
    mov  x0, x19
    mov  x1, x21
    bl   rv_ptr
    ldr  x0, [x0, #RV_NAME]
    ldr  x1, [x20, #N_C]
    bl   str_ieq
    cbz  w0, .Lbc_next_rv
    mov  x26, #1
1:  mov  x0, x19
    mov  x1, x21
    bl   rv_ncols
    mov  x23, x0
    mov  x22, #0
.Lbc_colloop:
    cmp  x22, x23
    b.hs .Lbc_next_rv
    mov  x0, x19
    mov  x1, x21
    mov  x2, x22
    bl   rv_column
    ldr  x0, [x0, #COL_NAME]
    ldr  x1, [x20, #N_NAME]
    bl   str_ieq
    cbz  w0, 2f
    tbz  x24, #63, .Lbc_ambiguous       // already matched (any rv)
    mov  x24, x21
    mov  x25, x22
2:  add  x22, x22, #1
    b    .Lbc_colloop
.Lbc_next_rv:
    add  x21, x21, #1
    b    .Lbc_rv
.Lbc_level_done:
    tbz  x24, #63, .Lbc_found
    cbnz x26, .Lbc_unknown_col          // qualifier named an rv of this level
.Lbc_up:
    ldr  w9, [x19, #BC_HIDE]
    ldr  x19, [x19, #BC_PARENT]
    cbz  x19, .Lbc_unknown
    add  x27, x27, #1
    cbnz w9, .Lbc_up                    // that level's FROM is invisible
    b    .Lbc_level

.Lbc_found:
    str  x25, [x20, #N_VAL]
    str  x24, [x20, #N_B]
    str  w27, [x20, #N_OP]
    mov  x0, x19
    mov  x1, x24
    mov  x2, x25
    cmp  x27, #0
    mov  w3, #RVU_LOCAL
    mov  w9, #RVU_OUTER
    csel w3, w3, w9, eq
    bl   rv_mark_used
    mov  x0, x19
    mov  x1, x24
    mov  x2, x25
    bl   rv_column
    ldr  w9, [x0, #COL_TYPE]
    str  w9, [x20, #N_TYPE]
    ldr  w9, [x20, #N_FLAGS]
    bic  w9, w9, #NF_CONST
    str  w9, [x20, #N_FLAGS]
    cbz  x27, 31f                       // outer reference from a
    ldr  w9, [x19, #BC_FLAGS]           // grouped-context clause: remember
    and  w9, w9, #(BF_AGG_OK | BF_IN_AGG)
    cmp  w9, #BF_AGG_OK
    b.ne 31f
    add  x0, x19, #BC_OREFS
    mov  x1, x20
    bl   vec_push
31: mov  x9, x28                        // mark correlated levels
    mov  x10, #1
3:  cmp  x9, x19
    b.eq 4f
    str  x10, [x9, #BC_CORR]
    ldr  x9, [x9, #BC_PARENT]
    b    3b
4:  mov  x0, x20
    LEAVE 5
.Lbc_unknown:
    ldr  x9, [x20, #N_C]
    cbz  x9, .Lbc_unknown_col
    cbnz x26, .Lbc_unknown_col
    RAISE_S ERR_SEMANTIC, "unknown table or alias ", x9
.Lbc_unknown_col:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "unknown column ", x9
.Lbc_ambiguous:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "ambiguous column ", x9
.Lbc_nocols:
    RAISE ERR_SEMANTIC, "LIMIT/OFFSET must be a constant expression"
ENDF bind_col

// col_decl_name(x0 ctx, x1 bound NK_COL) -> x0 Str* declared column name
// (walks N_OP levels up for outer references).   (leaf)
LFUNC col_decl_name
    ldr  w9, [x1, #N_OP]
1:  cbz  w9, 2f
    ldr  x0, [x0, #BC_PARENT]
    sub  w9, w9, #1
    b    1b
2:  ldr  x9, [x0, #BC_RVS]
    ldr  x10, [x1, #N_B]
    mov  x11, #RV_SIZE
    madd x9, x10, x11, x9
    ldr  x9, [x9, #RV_TABLE]
    ldr  x9, [x9, #TBL_COLS]
    ldr  x10, [x1, #N_VAL]
    add  x9, x9, x10, lsl #5
    ldr  x0, [x9, #COL_NAME]
    ret
ENDF col_decl_name

// col_exists_local(x0 ctx, x1 Str* name) -> w0 1 if some range variable of
// the current query has a column of that name.
//   x19 ctx, x20 name, x21 rv, x22 column, x23 ncols
LFUNC col_exists_local
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, #0
1:  ldr  x9, [x19, #BC_NRV]
    cmp  x21, x9
    b.hs 4f
    mov  x0, x19
    mov  x1, x21
    bl   rv_ncols
    mov  x23, x0
    mov  x22, #0
2:  cmp  x22, x23
    b.hs 3f
    mov  x0, x19
    mov  x1, x21
    mov  x2, x22
    bl   rv_column
    ldr  x0, [x0, #COL_NAME]
    mov  x1, x20
    bl   str_ieq
    cbnz w0, 5f
    add  x22, x22, #1
    b    2b
3:  add  x21, x21, #1
    b    1b
4:  mov  w0, #0
5:  LEAVE 3
ENDF col_exists_local

// =============================================================================
// bind_subq(x0 ctx, x1 Node*) -> x0 Node*   NK_SUBQ / NK_EXISTS / NK_INSUB
// The subquery is bound as a nested query level that sees this query's range
// variables (correlation) and is wrapped in a SubPlan (N_C).
//   x19 ctx, x20 node, x21 bound x (IN), x22 BoundQuery*, w23 type x,
//   w24 type of the subquery column, w25 values type
// =============================================================================
LFUNC bind_subq
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x19, #BC_FLAGS]
    tbnz w9, #2, .Lbsq_nocols           // not allowed in LIMIT / OFFSET
    ldr  w9, [x20, #N_KIND]
    cmp  w9, #NK_INSUB
    b.ne 1f
    mov  x0, x19
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    mov  x21, x0
1:  ldr  x0, [x20, #N_C]
    mov  x1, x19
    mov  w2, #0
    ldr  x3, [x19, #BC_SPV]
    ldr  x4, [x19, #BC_CTES]
    bl   bq_bind
    mov  x22, x0
    mov  x0, x19
    mov  x1, x22
    bl   new_subplan
    str  x0, [x20, #N_C]
    ldr  w9, [x20, #N_FLAGS]
    bic  w9, w9, #NF_CONST
    str  w9, [x20, #N_FLAGS]
    mov  w9, #T_BOOL
    str  w9, [x20, #N_TYPE]
    ldr  w9, [x20, #N_KIND]
    cmp  w9, #NK_EXISTS
    b.eq .Lbsq_ret
    ldr  x9, [x22, #BQ_NOUT]
    cmp  x9, #1
    b.ne .Lbsq_cols
    ldr  x9, [x22, #BQ_OUT]
    ldr  w24, [x9, #OC_TYPE]
    ldr  w9, [x20, #N_KIND]
    cmp  w9, #NK_SUBQ
    b.ne .Lbsq_in
    str  w24, [x20, #N_TYPE]
    b    .Lbsq_ret

    // ---- x IN (subquery): comparison promotion (types.md §5) ---------------
.Lbsq_in:
    ldr  w23, [x21, #N_TYPE]
    mov  w25, w24                       // default: values keep their type
    and  w10, w23, #T_KIND_MASK
    and  w11, w24, #T_KIND_MASK
    cbz  w10, .Lbsq_in_done
    cbz  w11, .Lbsq_in_done
    cmp  w10, w11
    b.eq .Lbsq_in_done
    sub  w12, w10, #T_INT
    cmp  w12, #(T_FLOAT - T_INT)
    b.hi .Lbsq_in_temporal
    sub  w12, w11, #T_INT
    cmp  w12, #(T_FLOAT - T_INT)
    b.hi .Lbsq_in_type
    cmp  w10, #T_FLOAT
    ccmp w11, #T_FLOAT, #4, ne          // eq if either is FLOAT64
    b.ne 2f
    mov  w25, #T_FLOAT
    cmp  w10, #T_FLOAT
    b.eq .Lbsq_in_done
    mov  x0, x21
    mov  w1, #T_FLOAT
    bl   mk_cast
    mov  x21, x0
    b    .Lbsq_in_done
2:  b    .Lbsq_in_done                  // INT64 vs DECIMAL: no casts, the
                                        // values compare exactly (cmp_typed)
.Lbsq_in_temporal:
    cmp  w10, #T_DATE
    ccmp w11, #T_TS, #0, eq
    b.ne 4f
    mov  x0, x21
    mov  w1, #T_TS
    bl   mk_cast
    mov  x21, x0
    mov  w25, #T_TS
    b    .Lbsq_in_done
4:  cmp  w10, #T_TS
    ccmp w11, #T_DATE, #0, eq
    b.ne .Lbsq_in_type
    mov  w25, #T_TS
.Lbsq_in_done:
    str  x21, [x20, #N_A]
    ldr  x9, [x20, #N_C]
    str  w25, [x9, #SP_INTYPE]
.Lbsq_ret:
    mov  x0, x20
    LEAVE 4
.Lbsq_cols:
    RAISE ERR_SEMANTIC, "subquery must return exactly one column"
.Lbsq_in_type:
    RAISE ERR_TYPE, "IN subquery column type is not comparable"
.Lbsq_nocols:
    RAISE ERR_SEMANTIC, "LIMIT/OFFSET must be a constant expression"
ENDF bind_subq


// =============================================================================
// bind_unary(x0 ctx, x1 Node*) -> x0 Node*
//   x19 ctx, x20 node, x21 bound operand
// =============================================================================
LFUNC bind_unary
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    mov  x21, x0
    str  x21, [x20, #N_A]
    ldr  w10, [x21, #N_TYPE]            // operand type
    and  w11, w10, #T_KIND_MASK
    ldr  w9, [x20, #N_OP]
    cmp  w9, #OP_NOT
    b.ne 1f
    // NOT: BOOLEAN or null type -> BOOLEAN
    cmp  w11, #T_NULL
    ccmp w11, #T_BOOL, #4, ne           // eq if NULL or BOOL
    b.ne .Lbu_type
    mov  w10, #T_BOOL
    b    9f
1:  // unary + / -: numeric or null type, type preserved (types.md §4)
    cbz  w11, 9f
2:  sub  w12, w11, #T_INT
    cmp  w12, #(T_FLOAT - T_INT)
    b.hi .Lbu_type
9:  str  w10, [x20, #N_TYPE]
    ldr  w9, [x21, #N_FLAGS]
    and  w9, w9, #NF_CONST
    ldr  w10, [x20, #N_FLAGS]
    bic  w10, w10, #NF_CONST
    orr  w10, w10, w9
    str  w10, [x20, #N_FLAGS]
    mov  x0, x20
    LEAVE 2
.Lbu_type:
    RAISE ERR_TYPE, "invalid operand type for unary operator"
ENDF bind_unary

// =============================================================================
// bind_isnull(x0 ctx, x1 Node*) -> x0 Node*  (any operand type -> BOOLEAN)
//   x19 ctx, x20 node
// =============================================================================
LFUNC bind_isnull
    ENTER 1
    mov  x19, x0
    mov  x20, x1
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    str  x0, [x20, #N_A]
    mov  w9, #T_BOOL
    str  w9, [x20, #N_TYPE]
    ldr  w9, [x0, #N_FLAGS]
    and  w9, w9, #NF_CONST
    ldr  w10, [x20, #N_FLAGS]
    bic  w10, w10, #NF_CONST
    orr  w10, w10, w9
    str  w10, [x20, #N_FLAGS]
    mov  x0, x20
    LEAVE 1
ENDF bind_isnull

// =============================================================================
// bind_cast(x0 ctx, x1 Node*) -> x0 Node*  (explicit CAST; types.md §8)
//   x19 ctx, x20 node, x21 bound operand
// =============================================================================
LFUNC bind_cast
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    mov  x21, x0
    str  x21, [x20, #N_A]
    ldr  w0, [x21, #N_TYPE]
    ldr  x1, [x20, #N_VAL]
    str  w1, [x20, #N_TYPE]
    bl   cast_allowed
    cbz  w0, .Lbca_type
    ldr  w9, [x21, #N_FLAGS]
    and  w9, w9, #NF_CONST
    ldr  w10, [x20, #N_FLAGS]
    bic  w10, w10, #NF_CONST
    orr  w10, w10, w9
    str  w10, [x20, #N_FLAGS]
    mov  x0, x20
    LEAVE 2
.Lbca_type:
    RAISE ERR_TYPE, "invalid CAST"
ENDF bind_cast

// =============================================================================
// bind_binary(x0 ctx, x1 Node*) -> x0 Node*: binds both operands, then types.
//   x19 ctx, x20 node
// =============================================================================
LFUNC bind_binary
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    str  x0, [x20, #N_A]
    mov  x0, x19
    ldr  x1, [x20, #N_B]
    bl   bind_expr
    str  x0, [x20, #N_B]
    mov  x0, x20
    bl   bind_binary_typed
    LEAVE 2
ENDF bind_binary

// =============================================================================
// make_compare(w0 op, x1 bound left, x2 bound right) -> x0 bound NK_BINARY
// Builds and types a binary node over already bound operands (used for the
// rewrites of BETWEEN, IN lists and simple CASE). Position from the left.
// =============================================================================
FUNC make_compare
    ENTER 2
    mov  w19, w0
    mov  x20, x1
    mov  x21, x2
    mov  x0, #N_SIZE
    bl   arena_zalloc
    mov  w9, #NK_BINARY
    str  w9, [x0, #N_KIND]
    str  w19, [x0, #N_OP]
    str  x20, [x0, #N_A]
    str  x21, [x0, #N_B]
    ldr  x9, [x20, #N_LINE]
    str  x9, [x0, #N_LINE]
    bl   bind_binary_typed
    LEAVE 2
ENDF make_compare

// =============================================================================
// bind_binary_typed(x0 Node* with bound N_A / N_B) -> x0 Node*
// Types the operator (types.md §2, §4-§6) and inserts implicit casts.
//   x20 node, x21 left, x22 right, w23 left type, w24 right type,
//   w25 op, w26 left kind, w27 right kind, w28 result type
// =============================================================================
FUNC bind_binary_typed
    ENTER 5
    mov  x20, x0
    ldr  x21, [x20, #N_A]
    ldr  x22, [x20, #N_B]
    ldr  w23, [x21, #N_TYPE]
    ldr  w24, [x22, #N_TYPE]
    and  w26, w23, #T_KIND_MASK
    and  w27, w24, #T_KIND_MASK
    ldr  w25, [x20, #N_OP]
    cmp  w25, #OP_CONCAT
    b.lo .Lbb_arith
    b.eq .Lbb_concat
    cmp  w25, #OP_AND
    b.hs .Lbb_logic

    // ---- comparisons: = <> < <= > >= -> BOOLEAN ---------------------------
    mov  w28, #T_BOOL
    cbz  w26, .Lbb_done                 // NULL compares with anything
    cbz  w27, .Lbb_done
    cmp  w26, w27
    b.ne 0f
    cmp  w26, #T_DEC                    // same kind (DECIMAL scales may differ;
    b.ne .Lbb_done                      // a narrow operand of a wide one is
    BR_WIDE w23, w9, 71f                // widened, which never overflows)
    BR_WIDE w24, w9, 72f
    b    .Lbb_done
71: BR_WIDE w24, w9, .Lbb_done
    mov  x0, x22
    mov  w1, w24
    bl   dec_widen
    mov  x22, x0
    b    .Lbb_done
72: mov  x0, x21
    mov  w1, w23
    bl   dec_widen
    mov  x21, x0
    b    .Lbb_done
0:
    sub  w9, w26, #T_INT
    cmp  w9, #(T_FLOAT - T_INT)
    b.hi .Lbb_cmp_nonnum
    sub  w9, w27, #T_INT
    cmp  w9, #(T_FLOAT - T_INT)
    b.hi .Lbb_type
    cmp  w26, #T_FLOAT
    b.ne 1f
    mov  x0, x22                        // FLOAT vs INT/DEC
    mov  w1, #T_FLOAT
    bl   mk_cast
    mov  x22, x0
    b    .Lbb_done
1:  cmp  w27, #T_FLOAT
    b.ne 2f
    mov  x0, x21
    mov  w1, #T_FLOAT
    bl   mk_cast
    mov  x21, x0
    b    .Lbb_done
2:  cmp  w26, #T_INT                    // INT vs DECIMAL(p,s): INT -> saturating
    b.ne 3f                             // DECIMAL(W,s) (exact comparison)
    mov  w0, w24
    mov  w1, w24
    bl   dec_wtype
    and  w1, w24, #(0xff << T_SCALE_SHIFT)
    orr  w1, w1, w0
    orr  w1, w1, #T_SATF
    mov  x0, x21
    bl   mk_cast
    mov  x21, x0
    b    .Lbb_done
3:  mov  w0, w23
    mov  w1, w23
    bl   dec_wtype
    and  w1, w23, #(0xff << T_SCALE_SHIFT)
    orr  w1, w1, w0
    orr  w1, w1, #T_SATF
    mov  x0, x22
    bl   mk_cast
    mov  x22, x0
    b    .Lbb_done
.Lbb_cmp_nonnum:                        // DATE vs TIMESTAMP: DATE -> TIMESTAMP
    cmp  w26, #T_DATE
    ccmp w27, #T_TS, #0, eq
    b.ne 4f
    mov  x0, x21
    mov  w1, #T_TS
    bl   mk_cast
    mov  x21, x0
    b    .Lbb_done
4:  cmp  w26, #T_TS
    ccmp w27, #T_DATE, #0, eq
    b.ne .Lbb_type
    mov  x0, x22
    mov  w1, #T_TS
    bl   mk_cast
    mov  x22, x0
    b    .Lbb_done

    // ---- AND / OR: BOOLEAN or null type operands ---------------------------
.Lbb_logic:
    mov  w28, #T_BOOL
    cmp  w26, #T_NULL
    ccmp w26, #T_BOOL, #4, ne
    b.ne .Lbb_type
    cmp  w27, #T_NULL
    ccmp w27, #T_BOOL, #4, ne
    b.ne .Lbb_type
    b    .Lbb_done

    // ---- || : STRING or null type operands ---------------------------------
.Lbb_concat:
    mov  w28, #T_STR
    cmp  w26, #T_NULL
    ccmp w26, #T_STR, #4, ne
    b.ne .Lbb_type
    cmp  w27, #T_NULL
    ccmp w27, #T_STR, #4, ne
    b.ne .Lbb_type
    b    .Lbb_done

    // ---- + - * / % ---------------------------------------------------------
    // For typing a null-typed operand behaves like INT64 (it is never cast).
.Lbb_arith:
    mov  w10, w26                       // effective kinds
    cbnz w10, 1f
    mov  w10, #T_INT
1:  mov  w11, w27
    cbnz w11, 2f
    mov  w11, #T_INT
2:  sub  w9, w10, #T_INT
    cmp  w9, #(T_FLOAT - T_INT)
    b.hi .Lbb_arith_type
    sub  w9, w11, #T_INT
    cmp  w9, #(T_FLOAT - T_INT)
    b.hi .Lbb_arith_type
    // INT64 op INT64 -> INT64
    mov  w28, #T_INT
    cmp  w10, #T_INT
    ccmp w11, #T_INT, #0, eq
    b.eq .Lbb_done
    // any FLOAT64 -> FLOAT64 (no %)
    cmp  w10, #T_FLOAT
    ccmp w11, #T_FLOAT, #4, ne          // eq if either is FLOAT
    b.eq .Lbb_to_float
    // DECIMAL involved (other INT64 or DECIMAL)
    cmp  w25, #OP_MOD
    b.eq .Lbb_mod_type
    cmp  w25, #OP_DIV
    b.eq .Lbb_to_float
    // scales (INT64 / null type -> 0)
    mov  w12, #0
    cmp  w26, #T_DEC
    b.ne 3f
    ubfx w12, w23, #T_SCALE_SHIFT, #8
3:  mov  w13, #0
    cmp  w27, #T_DEC
    b.ne 4f
    ubfx w13, w24, #T_SCALE_SHIFT, #8
4:  stp  w12, w13, [sp, #-16]!
    mov  w0, w23                        // DECIMAL(W, ..): W = 38 if an
    mov  w1, w24                        // operand is a wide DECIMAL
    bl   dec_wtype
    mov  w15, w0
    ldp  w12, w13, [sp], #16
    cmp  w25, #OP_MUL
    b.ne 5f
    // DECIMAL *: result scale s1+s2 (> W => TYPE_ERROR); INT64 -> DECIMAL(W,0)
    add  w14, w12, w13
    ubfx w9, w15, #T_PREC_SHIFT, #8
    cmp  w14, w9
    b.hi .Lbb_scale_type
    orr  w28, w15, w14, lsl #T_SCALE_SHIFT
    b    6f                             // cast target for INT64: w15
5:  // DECIMAL + -: result scale max(s1,s2); INT64 -> DECIMAL(W, other scale)
    cmp  w12, w13
    csel w14, w12, w13, hi
    orr  w28, w15, w14, lsl #T_SCALE_SHIFT
    mov  w15, w28
6:  str  w15, [sp, #-16]!               // keep the cast target across calls
    cmp  w26, #T_INT
    b.ne 7f
    mov  x0, x21
    ldr  w1, [sp]
    bl   mk_cast
    mov  x21, x0
7:  cmp  w27, #T_INT
    b.ne 8f
    mov  x0, x22
    ldr  w1, [sp]
    bl   mk_cast
    mov  x22, x0
8:  add  sp, sp, #16
    b    .Lbb_done

.Lbb_to_float:                          // both operands -> FLOAT64
    cmp  w25, #OP_MOD
    b.eq .Lbb_mod_type
    mov  w28, #T_FLOAT
    cmp  w26, #T_FLOAT
    b.eq 1f
    mov  x0, x21
    mov  w1, #T_FLOAT
    bl   mk_cast
    mov  x21, x0
1:  cmp  w27, #T_FLOAT
    b.eq .Lbb_done
    mov  x0, x22
    mov  w1, #T_FLOAT
    bl   mk_cast
    mov  x22, x0

.Lbb_done:
    str  x21, [x20, #N_A]
    str  x22, [x20, #N_B]
    str  w28, [x20, #N_TYPE]
    ldr  w9, [x21, #N_FLAGS]
    ldr  w10, [x22, #N_FLAGS]
    and  w9, w9, w10
    and  w9, w9, #NF_CONST
    ldr  w10, [x20, #N_FLAGS]
    bic  w10, w10, #NF_CONST
    orr  w10, w10, w9
    str  w10, [x20, #N_FLAGS]
    mov  x0, x20
    LEAVE 5

.Lbb_type:
    RAISE ERR_TYPE, "operand types are not comparable"
.Lbb_arith_type:
    RAISE ERR_TYPE, "arithmetic requires numeric operands"
.Lbb_mod_type:
    RAISE ERR_TYPE, "% requires INT64 operands"
.Lbb_scale_type:
    RAISE ERR_TYPE, "DECIMAL product scale exceeds the result precision"
ENDF bind_binary_typed

// =============================================================================
// Function table: 12-byte NUL padded upper-case name + u32 id.
// =============================================================================
.macro FENTRY name, id
9998:
    .ascii "\name"
    .org 9998b + 12, 0
    .word \id
.endm

    .section .rodata
    .p2align 2
func_table:
    FENTRY "COUNT",      F_COUNT
    FENTRY "SUM",        F_SUM
    FENTRY "MIN",        F_MIN
    FENTRY "MAX",        F_MAX
    FENTRY "AVG",        F_AVG
    .word 0                             // end marker (empty name)
    .text

// func_lookup(x0 Str* name) -> w0 function id, 0 if unknown
//   x19 name, x20 table entry
LFUNC func_lookup
    ENTER 1
    mov  x19, x0
    ADR_L x20, func_table
1:  ldrb w9, [x20]
    cbz  w9, 3f
    mov  x0, x19
    mov  x1, x20
    bl   str_ieq_c
    cbnz w0, 2f
    add  x20, x20, #16
    b    1b
2:  ldr  w0, [x20, #12]
    LEAVE 1
3:  mov  w0, #0
    LEAVE 1
ENDF func_lookup

// =============================================================================
// bind_func(x0 ctx, x1 Node*) -> x0 Node*
// Aggregates become NK_AGG nodes registered as slots; everything else is a
// scalar function bound by bind_scalar_func (functions.S).
//   x19 ctx, x20 node, w21 function id, x22 bound argument, w23 saved flags,
//   w24 result type
// =============================================================================
LFUNC bind_func
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x20, #N_NAME]
    bl   func_lookup
    mov  w21, w0
    cbnz w21, .Lbfn_agg
    mov  x0, x19                        // not an aggregate: scalar function
    mov  x1, x20
    LEAVE_NORET 3
    b    bind_scalar_func               // functions.S (tail call)

    // ---- aggregates ----------------------------------------------------------
.Lbfn_agg:
    ldr  w9, [x20, #N_FLAGS]
    tbz  w9, #2, 1f                     // NF_STAR
    cmp  w21, #F_COUNT
    b.ne .Lbfn_star
    mov  w21, #F_COUNT_STAR
    b    2f
1:  ldr  x10, [x20, #N_VAL]
    cmp  x10, #1
    b.ne .Lbfn_arity
2:  ldr  w23, [x19, #BC_FLAGS]
    tbz  w23, #0, .Lbfn_notallowed      // BF_AGG_OK
    tbnz w23, #1, .Lbfn_nested          // BF_IN_AGG
    mov  x22, #0
    mov  w24, #T_INT                    // COUNT / COUNT(*) -> INT64
    cmp  w21, #F_COUNT_STAR
    b.eq .Lbfn_mkagg
    // bind the argument with BF_IN_AGG set
    orr  w9, w23, #BF_IN_AGG
    str  w9, [x19, #BC_FLAGS]
    mov  x0, x19
    ldr  x9, [x20, #N_C]
    ldr  x1, [x9]
    bl   bind_expr
    mov  x22, x0
    str  w23, [x19, #BC_FLAGS]
    ldr  w10, [x22, #N_TYPE]
    and  w11, w10, #T_KIND_MASK
    cmp  w21, #F_COUNT
    b.eq .Lbfn_mkagg
    cmp  w21, #F_MIN
    b.eq 3f
    cmp  w21, #F_MAX
    b.eq 3f
    // SUM / AVG need a numeric (or null-typed) argument
    cbz  w11, 4f
    sub  w12, w11, #T_INT
    cmp  w12, #(T_FLOAT - T_INT)
    b.hi .Lbfn_argtype
4:  mov  w24, #T_FLOAT                  // AVG -> FLOAT64
    cmp  w21, #F_AVG
    b.eq .Lbfn_mkagg
    mov  w24, #T_INT                    // SUM: INT64 / null -> INT64
    cmp  w11, #T_INT
    b.ls .Lbfn_mkagg
    mov  w24, #T_FLOAT                  // SUM FLOAT64 -> FLOAT64
    cmp  w11, #T_FLOAT
    b.eq .Lbfn_mkagg
    mov  w0, w10                        // SUM DECIMAL(p,s) -> DECIMAL(W,s)
    mov  w1, w10
    bl   dec_wtype
    ldr  w10, [x22, #N_TYPE]
    and  w24, w10, #(0xff << T_SCALE_SHIFT)
    orr  w24, w24, w0
    b    .Lbfn_mkagg
3:  mov  w24, w10                       // MIN / MAX keep the argument type
.Lbfn_mkagg:
    mov  w9, #NK_AGG
    str  w9, [x20, #N_KIND]
    str  w21, [x20, #N_OP]
    str  w24, [x20, #N_TYPE]
    str  x22, [x20, #N_A]
    ldr  w9, [x20, #N_FLAGS]
    bic  w9, w9, #NF_CONST
    str  w9, [x20, #N_FLAGS]
    add  x0, x19, #BC_AGGV
    mov  x1, x20
    bl   vec_push
    str  x0, [x20, #N_B]                // slot index
    mov  x0, x20
    LEAVE 3

.Lbfn_arity:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "wrong number of arguments for ", x9
.Lbfn_star:
    RAISE ERR_SEMANTIC, "only COUNT accepts *"
.Lbfn_argtype:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_TYPE, "invalid argument type for ", x9
.Lbfn_notallowed:
    RAISE ERR_SEMANTIC, "aggregate functions are not allowed here"
.Lbfn_nested:
    RAISE ERR_SEMANTIC, "aggregate calls cannot be nested"
ENDF bind_func

// =============================================================================
// Output column naming helpers
// make_colname(x0 n) -> x0 Str* "_col<n>"
// =============================================================================
LFUNC make_colname
    ENTER 0
    sub  sp, sp, #32
    mov  w9, #'_'
    strb w9, [sp]
    mov  w9, #'c'
    strb w9, [sp, #1]
    mov  w9, #'o'
    strb w9, [sp, #2]
    mov  w9, #'l'
    strb w9, [sp, #3]
    // digits written backwards into [sp+31 ...], then moved after "_col"
    add  x10, sp, #31
    mov  x11, #10
1:  udiv x12, x0, x11
    msub x13, x12, x11, x0
    add  w13, w13, #'0'
    strb w13, [x10, #-1]!
    mov  x0, x12
    cbnz x0, 1b
    add  x14, sp, #31
    sub  x15, x14, x10                  // digit count
    add  x16, sp, #4
2:  ldrb w13, [x10], #1
    strb w13, [x16], #1
    cmp  x10, x14
    b.lo 2b
    mov  x0, sp
    add  x1, x15, #4
    bl   str_new
    add  sp, sp, #32
    LEAVE 0
ENDF make_colname

// emit_rv_cols(x0 ctx, x1 rv index, x2 OutCol*) -> x0 number of columns
// Expands rv.* into bound column references.
//   x19 ctx, x20 rv index, x21 OutCol cursor, x22 column index, x23 ncols,
//   x24 Column*
LFUNC emit_rv_cols
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    bl   rv_ncols
    mov  x23, x0
    mov  x22, #0
1:  cmp  x22, x23
    b.hs 2f
    mov  x0, x19
    mov  x1, x20
    mov  x2, x22
    bl   rv_column
    mov  x24, x0
    mov  x0, x19
    mov  x1, x20
    mov  x2, x22
    mov  w3, #RVU_LOCAL
    bl   rv_mark_used
    mov  x0, #N_SIZE
    bl   arena_zalloc
    mov  w9, #NK_COL
    str  w9, [x0, #N_KIND]
    ldr  w9, [x24, #COL_TYPE]
    str  w9, [x0, #N_TYPE]
    str  x22, [x0, #N_VAL]
    str  x20, [x0, #N_B]
    ldr  x10, [x24, #COL_NAME]
    str  x10, [x0, #N_NAME]
    str  x0, [x21, #OC_EXPR]
    str  x10, [x21, #OC_NAME]
    str  w9, [x21, #OC_TYPE]
    add  x21, x21, #OC_SIZE
    add  x22, x22, #1
    b    1b
2:  mov  x0, x23
    LEAVE 3
ENDF emit_rv_cols

// =============================================================================
// bind_select(x0 ctx) — builds BQ_OUT / BQ_NOUT (semantics.md §1, §3)
//   x19 ctx, x20 Query*, x21 item cursor, x22 items left, x23 total columns,
//   x24 OutCol array, x25 output position, x26 bound expr, x27 rv index
// =============================================================================
LFUNC bind_select
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #BC_Q]

    // ---- pass 1: count the expanded output columns, validate * forms ------
    mov  x23, #0
    ldr  x21, [x20, #Q_ITEMS]
    ldr  x22, [x20, #Q_NITEMS]
.Lbs_count:
    cbz  x22, .Lbs_alloc
    ldr  w9, [x21, #SI_KIND]
    cmp  w9, #SIK_STAR
    b.eq 1f
    cmp  w9, #SIK_QSTAR
    b.eq 3f
    add  x23, x23, #1
    b    9f
1:  ldr  x9, [x19, #BC_NRV]             // * : all columns of all rvs
    cbz  x9, .Lbs_star_nofrom
    mov  x27, #0
2:  ldr  x9, [x19, #BC_NRV]
    cmp  x27, x9
    b.hs 9f
    mov  x0, x19
    mov  x1, x27
    bl   rv_ncols
    add  x23, x23, x0
    add  x27, x27, #1
    b    2b
3:  mov  x0, x19                        // q.* : columns of rv q
    ldr  x1, [x21, #SI_QUAL]
    bl   find_rv
    tbnz x0, #63, .Lbs_badqual
    mov  x1, x0
    mov  x0, x19
    bl   rv_ncols
    add  x23, x23, x0
9:  add  x21, x21, #SI_SIZE
    sub  x22, x22, #1
    b    .Lbs_count

.Lbs_alloc:
    lsl  x0, x23, #5                    // OC_SIZE = 32
    bl   arena_zalloc
    mov  x24, x0
    ldr  x9, [x19, #BC_BQ]
    str  x23, [x9, #BQ_NOUT]
    str  x24, [x9, #BQ_OUT]

    // ---- pass 2: bind and name ---------------------------------------------
    mov  x25, #0
    ldr  x21, [x20, #Q_ITEMS]
    ldr  x22, [x20, #Q_NITEMS]
.Lbs_bind:
    cbz  x22, .Lbs_end
    ldr  w9, [x21, #SI_KIND]
    cmp  w9, #SIK_STAR
    b.eq 1f
    cmp  w9, #SIK_QSTAR
    b.eq 3f
    // expression item
    mov  w9, #BF_AGG_OK
    str  w9, [x19, #BC_FLAGS]
    mov  x0, x19
    ldr  x1, [x21, #SI_EXPR]
    bl   bind_expr
    mov  x26, x0
    add  x27, x24, x25, lsl #5          // OutCol*
    str  x26, [x27, #OC_EXPR]
    ldr  w9, [x26, #N_TYPE]
    str  w9, [x27, #OC_TYPE]
    ldr  x0, [x21, #SI_ALIAS]
    cbz  x0, 6f
    mov  w9, #1
    str  w9, [x27, #OC_ALIASED]
    b    5f
6:  ldr  w9, [x26, #N_KIND]
    cmp  w9, #NK_COL
    b.ne 4f
    mov  x0, x19                        // bare column: its declared name
    mov  x1, x26
    bl   col_decl_name
    b    5f
4:  add  x0, x25, #1                    // _colN
    bl   make_colname
5:  add  x27, x24, x25, lsl #5
    str  x0, [x27, #OC_NAME]
    add  x25, x25, #1
    b    9f
1:  mov  x27, #0                        // *
2:  ldr  x9, [x19, #BC_NRV]
    cmp  x27, x9
    b.hs 9f
    mov  x0, x19
    mov  x1, x27
    add  x2, x24, x25, lsl #5
    bl   emit_rv_cols
    add  x25, x25, x0
    add  x27, x27, #1
    b    2b
3:  mov  x0, x19                        // q.*
    ldr  x1, [x21, #SI_QUAL]
    bl   find_rv
    mov  x1, x0
    mov  x0, x19
    add  x2, x24, x25, lsl #5
    bl   emit_rv_cols
    add  x25, x25, x0
9:  add  x21, x21, #SI_SIZE
    sub  x22, x22, #1
    b    .Lbs_bind
.Lbs_end:
    LEAVE 5

.Lbs_star_nofrom:
    RAISE ERR_SEMANTIC, "SELECT * requires a FROM clause"
.Lbs_badqual:
    ldr  x9, [x21, #SI_QUAL]
    RAISE_S ERR_SEMANTIC, "unknown table or alias ", x9
ENDF bind_select

// =============================================================================
// bind_order(x0 ctx) — ORDER BY keys (semantics.md §6). For a UNION ALL
// compound only output column names and positions are accepted.
//   x19 ctx, x20 BoundQuery*, x21 OrderItem cursor, x22 index, x23 count,
//   x24 OrderKey array, x25 expr, x26 cell, x27 first matching output column,
//   x28 output column index (name matching)
// =============================================================================
LFUNC bind_order
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #BC_BQ]
    ldr  x9, [x19, #BC_Q]
    ldr  x21, [x9, #Q_ORDER]
    ldr  x23, [x9, #Q_NORDER]
    cbz  x23, .Lbo_end
    lsl  x0, x23, #4                    // OK_SIZE = 16
    bl   arena_zalloc
    mov  x24, x0
    str  x23, [x20, #BQ_NORDER]
    str  x24, [x20, #BQ_ORDER]
    mov  x22, #0
.Lbo_item:
    cmp  x22, x23
    b.hs .Lbo_end
    ldr  x25, [x21, #OI_EXPR]
    ldr  w9, [x25, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq .Lbo_lit
    cmp  w9, #NK_COL
    b.eq .Lbo_name
    b    .Lbo_expr

.Lbo_lit:                               // positive integer literal k
    ldr  w10, [x25, #N_FLAGS]
    tbnz w10, #0, .Lbo_expr             // NULL literal: constant expression
    ldrb w10, [x25, #N_TYPE]
    cmp  w10, #T_INT
    b.ne .Lbo_expr
    ldr  x10, [x25, #N_VAL]
    cmp  x10, #1
    b.lt .Lbo_range
    ldr  x11, [x20, #BQ_NOUT]
    cmp  x10, x11
    b.gt .Lbo_range
    sub  x26, x10, #1
    b    .Lbo_key

.Lbo_name:                              // unqualified name of an output column?
    ldr  x9, [x25, #N_C]
    cbnz x9, .Lbo_expr
    mov  x27, #-1
    mov  x28, #0
1:  ldr  x9, [x20, #BQ_NOUT]
    cmp  x28, x9
    b.hs 3f
    ldr  x9, [x20, #BQ_OUT]
    add  x9, x9, x28, lsl #5
    ldr  x0, [x9, #OC_NAME]
    ldr  x1, [x25, #N_NAME]
    bl   str_ieq
    cbz  w0, 2f
    tbz  x27, #63, 4f
    mov  x27, x28                       // first match
    b    2f
4:  ldr  x9, [x20, #BQ_NUNION]          // compound: names must be unique
    cbnz x9, .Lbo_ambiguous
    ldr  x9, [x20, #BQ_OUT]             // further match: must be the same expr
    add  x10, x9, x27, lsl #5
    ldr  x0, [x10, #OC_EXPR]
    add  x10, x9, x28, lsl #5
    ldr  x1, [x10, #OC_EXPR]
    bl   expr_equal
    cbz  w0, .Lbo_ambiguous
2:  add  x28, x28, #1
    b    1b
3:  tbnz x27, #63, .Lbo_expr
    mov  x26, x27
    b    .Lbo_key

.Lbo_expr:                              // expression over input columns
    ldr  x9, [x20, #BQ_NUNION]          // (not in a UNION ALL compound)
    cbnz x9, .Lbo_union
    mov  w9, #BF_AGG_OK
    str  w9, [x19, #BC_FLAGS]
    mov  x0, x19
    mov  x1, x25
    bl   bind_expr
    mov  x25, x0
    mov  x26, #0                        // equal to an output expression?
6:  ldr  x9, [x20, #BQ_NOUT]
    cmp  x26, x9
    b.hs 7f
    ldr  x9, [x20, #BQ_OUT]
    add  x9, x9, x26, lsl #5
    ldr  x0, [x9, #OC_EXPR]
    mov  x1, x25
    bl   expr_equal
    cbnz w0, .Lbo_key
    add  x26, x26, #1
    b    6b
7:  ldr  x9, [x20, #BQ_DISTINCT]        // hidden key: not with DISTINCT
    cbnz x9, .Lbo_distinct
    mov  x1, x25
    add  x0, x19, #BC_EXV
    bl   vec_push
    ldr  x9, [x20, #BQ_NOUT]
    add  x26, x9, x0

.Lbo_key:
    add  x9, x24, x22, lsl #4
    str  x26, [x9, #OK_CELL]
    ldr  w10, [x21, #OI_DESC]
    str  w10, [x9, #OK_DESC]
    ldr  w11, [x21, #OI_NULLS]
    mov  w12, #1                        // NULLS FIRST
    cmp  w11, #1
    b.eq 5f
    mov  w12, #0                        // NULLS LAST
    cmp  w11, #2
    b.eq 5f
    eor  w12, w10, #1                   // default: first iff ascending
5:  str  w12, [x9, #OK_NFIRST]
    add  x21, x21, #OI_SIZE
    add  x22, x22, #1
    b    .Lbo_item

.Lbo_end:
    ldr  x9, [x19, #BC_EXV + V_N]
    str  x9, [x20, #BQ_NEXTRA]
    ldr  x9, [x19, #BC_EXV + V_DATA]
    str  x9, [x20, #BQ_EXTRA]
    LEAVE 5
.Lbo_range:
    RAISE ERR_SEMANTIC, "ORDER BY position is out of range"
.Lbo_distinct:
    RAISE ERR_SEMANTIC, "ORDER BY expression must appear in the select list of SELECT DISTINCT"
.Lbo_union:
    RAISE ERR_SEMANTIC, "ORDER BY of UNION ALL must be an output column name or position"
.Lbo_ambiguous:
    ldr  x9, [x25, #N_NAME]
    RAISE_S ERR_SEMANTIC, "ambiguous ORDER BY column ", x9
ENDF bind_order

// =============================================================================
// bind_group(x0 ctx) — GROUP BY items (semantics.md §5) -> BQ_GROUP/BQ_NGROUP
// An item is a positive integer literal k (k-th select item), an unqualified
// name that is not an input column but a select alias, or an expression over
// input columns (no aggregates).
//   x19 ctx, x20 BoundQuery*, x21 index, x22 count, x23 Node** array,
//   x24 item, x25 output column cursor / index
// =============================================================================
LFUNC bind_group
    ENTER 4
    mov  x19, x0
    ldr  x20, [x19, #BC_BQ]
    ldr  x9, [x19, #BC_Q]
    ldr  x22, [x9, #Q_NGROUP]
    cbz  x22, .Lbg_end
    lsl  x0, x22, #3
    bl   arena_zalloc
    mov  x23, x0
    str  x22, [x20, #BQ_NGROUP]
    str  x23, [x20, #BQ_GROUP]
    mov  x21, #0
.Lbg_item:
    cmp  x21, x22
    b.hs .Lbg_end
    ldr  x9, [x19, #BC_Q]
    ldr  x9, [x9, #Q_GROUP]
    ldr  x24, [x9, x21, lsl #3]
    ldr  w9, [x24, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq .Lbg_lit
    cmp  w9, #NK_COL
    b.eq .Lbg_name
    b    .Lbg_expr
.Lbg_lit:                               // positive integer literal k
    ldr  w10, [x24, #N_FLAGS]
    tbnz w10, #0, .Lbg_expr
    ldrb w10, [x24, #N_TYPE]
    cmp  w10, #T_INT
    b.ne .Lbg_expr
    ldr  x25, [x24, #N_VAL]
    cmp  x25, #1
    b.lt .Lbg_range
    ldr  x11, [x20, #BQ_NOUT]
    cmp  x25, x11
    b.gt .Lbg_range
    sub  x25, x25, #1
    b    .Lbg_outexpr
.Lbg_name:                              // input column first, then alias
    ldr  x9, [x24, #N_C]
    cbnz x9, .Lbg_expr
    mov  x0, x19
    ldr  x1, [x24, #N_NAME]
    bl   col_exists_local
    cbnz w0, .Lbg_expr
    mov  x25, #0
1:  ldr  x9, [x20, #BQ_NOUT]
    cmp  x25, x9
    b.hs .Lbg_expr                      // not an alias: normal binding (error)
    ldr  x9, [x20, #BQ_OUT]
    add  x9, x9, x25, lsl #5
    ldr  w10, [x9, #OC_ALIASED]
    cbz  w10, 2f
    ldr  x0, [x9, #OC_NAME]
    ldr  x1, [x24, #N_NAME]
    bl   str_ieq
    cbnz w0, .Lbg_outexpr
2:  add  x25, x25, #1
    b    1b
.Lbg_outexpr:                           // the expression of output column x25
    ldr  x9, [x20, #BQ_OUT]
    add  x9, x9, x25, lsl #5
    ldr  x24, [x9, #OC_EXPR]
    mov  x0, x24
    bl   contains_agg
    cbnz w0, .Lbg_agg
    b    .Lbg_store
.Lbg_expr:
    str  wzr, [x19, #BC_FLAGS]          // no aggregates in GROUP BY
    mov  x0, x19
    mov  x1, x24
    bl   bind_expr
    mov  x24, x0
.Lbg_store:
    str  x24, [x23, x21, lsl #3]
    add  x21, x21, #1
    b    .Lbg_item
.Lbg_end:
    LEAVE 4
.Lbg_range:
    RAISE ERR_SEMANTIC, "GROUP BY position is out of range"
.Lbg_agg:
    RAISE ERR_SEMANTIC, "aggregate functions are not allowed in GROUP BY"
ENDF bind_group

// =============================================================================
// finish_aggregation(x0 ctx)
// Publishes the aggregate slots. The query is aggregated if it has GROUP BY,
// aggregates or HAVING; then every SELECT / HAVING / ORDER BY expression is
// rewritten for the group context (group_rewrite).
//   x19 ctx, x20 BoundQuery*, x21 index, x22 count
// =============================================================================
LFUNC finish_aggregation
    ENTER 2
    mov  x19, x0
    ldr  x20, [x19, #BC_BQ]
    ldr  x9, [x19, #BC_AGGV + V_N]
    str  x9, [x20, #BQ_NAGG]
    ldr  x10, [x19, #BC_AGGV + V_DATA]
    str  x10, [x20, #BQ_AGGS]
    ldr  x10, [x20, #BQ_NGROUP]
    orr  x9, x9, x10
    ldr  x10, [x20, #BQ_HAVING]
    orr  x9, x9, x10
    cbz  x9, 9f
    mov  x9, #1
    str  x9, [x20, #BQ_ISAGG]
    mov  x0, x19
    bl   check_outer_refs
    mov  x21, #0
    ldr  x22, [x20, #BQ_NOUT]
1:  cmp  x21, x22
    b.hs 2f
    ldr  x9, [x20, #BQ_OUT]
    add  x9, x9, x21, lsl #5
    ldr  x1, [x9, #OC_EXPR]
    mov  x0, x20
    bl   group_rewrite
    ldr  x9, [x20, #BQ_OUT]
    add  x9, x9, x21, lsl #5
    str  x0, [x9, #OC_EXPR]
    add  x21, x21, #1
    b    1b
2:  ldr  x1, [x20, #BQ_HAVING]
    cbz  x1, 3f
    mov  x0, x20
    bl   group_rewrite
    str  x0, [x20, #BQ_HAVING]
3:  mov  x21, #0
    ldr  x22, [x20, #BQ_NEXTRA]
4:  cmp  x21, x22
    b.hs 9f
    ldr  x9, [x20, #BQ_EXTRA]
    ldr  x1, [x9, x21, lsl #3]
    mov  x0, x20
    bl   group_rewrite
    ldr  x9, [x20, #BQ_EXTRA]
    str  x0, [x9, x21, lsl #3]
    add  x21, x21, #1
    b    4b
9:  LEAVE 2
ENDF finish_aggregation

// =============================================================================
// check_outer_refs(x0 ctx) — in an aggregated query, a column of this query
// referenced from a subquery in SELECT / HAVING / ORDER BY must itself be a
// GROUP BY expression (semantics.md §5); it is then evaluated on the group's
// representative tuple.
//   x19 ctx, x20 index, x21 reference, x22 group index, x23 bq
// =============================================================================
LFUNC check_outer_refs
    ENTER 3
    mov  x19, x0
    ldr  x23, [x19, #BC_BQ]
    mov  x20, #0
1:  ldr  x9, [x19, #BC_OREFS + V_N]
    cmp  x20, x9
    b.hs 5f
    ldr  x9, [x19, #BC_OREFS + V_DATA]
    ldr  x21, [x9, x20, lsl #3]
    mov  x22, #0
2:  ldr  x9, [x23, #BQ_NGROUP]
    cmp  x22, x9
    b.hs .Lcor_bad
    ldr  x9, [x23, #BQ_GROUP]
    ldr  x9, [x9, x22, lsl #3]
    ldr  w10, [x9, #N_KIND]
    cmp  w10, #NK_COL
    b.ne 3f
    ldr  w10, [x9, #N_OP]
    cbnz w10, 3f
    ldr  x10, [x9, #N_B]
    ldr  x11, [x21, #N_B]
    cmp  x10, x11
    b.ne 3f
    ldr  x10, [x9, #N_VAL]
    ldr  x11, [x21, #N_VAL]
    cmp  x10, x11
    b.eq 4f
3:  add  x22, x22, #1
    b    2b
4:  add  x20, x20, #1
    b    1b
5:  LEAVE 3
.Lcor_bad:
    ldr  x9, [x21, #N_NAME]
    RAISE_S ERR_SEMANTIC, "column must appear in GROUP BY or be used in an aggregate: ", x9
ENDF check_outer_refs

// =============================================================================
// group_rewrite(x0 BoundQuery*, x1 Node*) -> x0 Node*
// Replaces every subexpression structurally equal to a GROUP BY expression by
// an NK_GKEY node; a column reference of this query left outside aggregate
// arguments raises SEMANTIC_ERROR. Aggregates, literals, subqueries and outer
// references are kept.
//   x19 bq, x20 node, x21 index, x22 count
// =============================================================================
LFUNC group_rewrite
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, #0
1:  ldr  x9, [x19, #BQ_NGROUP]
    cmp  x21, x9
    b.hs 3f
    ldr  x9, [x19, #BQ_GROUP]
    ldr  x1, [x9, x21, lsl #3]
    mov  x0, x20
    bl   expr_equal
    cbnz w0, .Lgr_key
    add  x21, x21, #1
    b    1b
3:  ldr  w9, [x20, #N_KIND]
    cmp  w9, #NK_COL
    b.eq .Lgr_col
    cmp  w9, #NK_AGG
    b.eq .Lgr_keep
    cmp  w9, #NK_GKEY
    b.eq .Lgr_keep
    mov  x0, x20
    bl   expr_nchildren
    mov  x22, x0
    mov  x21, #0
4:  cmp  x21, x22
    b.hs .Lgr_keep
    mov  x0, x20
    mov  x1, x21
    bl   expr_child_slot
    mov  x23, x0
    ldr  x1, [x23]
    mov  x0, x19
    bl   group_rewrite
    str  x0, [x23]
    add  x21, x21, #1
    b    4b
.Lgr_col:
    ldr  w9, [x20, #N_OP]
    cbz  w9, .Lgr_bad                   // a column of this query
.Lgr_keep:
    mov  x0, x20
    LEAVE 3
.Lgr_key:
    mov  x0, #N_SIZE
    bl   arena_zalloc
    mov  w9, #NK_GKEY
    str  w9, [x0, #N_KIND]
    ldr  w9, [x20, #N_TYPE]
    str  w9, [x0, #N_TYPE]
    str  x21, [x0, #N_VAL]
    ldr  x9, [x20, #N_NAME]
    str  x9, [x0, #N_NAME]
    ldr  x9, [x20, #N_LINE]
    str  x9, [x0, #N_LINE]
    LEAVE 3
.Lgr_bad:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "column must appear in GROUP BY or be used in an aggregate: ", x9
ENDF group_rewrite

// contains_agg(x0 Node*) -> w0 1 if the expression contains an aggregate
//   x19 node, x20 index, x21 count
LFUNC contains_agg
    ENTER 2
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_AGG
    b.eq 3f
    bl   expr_nchildren
    mov  x21, x0
    mov  x20, #0
1:  cmp  x20, x21
    b.hs 2f
    mov  x0, x19
    mov  x1, x20
    bl   expr_child_slot
    ldr  x0, [x0]
    bl   contains_agg
    cbnz w0, 3f
    add  x20, x20, #1
    b    1b
2:  mov  w0, #0
    LEAVE 2
3:  mov  w0, #1
    LEAVE 2
ENDF contains_agg

// =============================================================================
// Generic child access for bound expression trees (also used by plan.S).
// expr_nchildren(x0 Node*) -> x0 number of child expressions   (leaf)
// Subquery internals are not children; NK_INSUB's child is its operand.
// =============================================================================
FUNC expr_nchildren
    ldr  w9, [x0, #N_KIND]
    cmp  w9, #NK_UNARY
    b.eq 1f
    cmp  w9, #NK_ISNULL
    b.eq 1f
    cmp  w9, #NK_CAST
    b.eq 1f
    cmp  w9, #NK_INSUB
    b.eq 1f
    cmp  w9, #NK_BINARY
    b.eq 2f
    cmp  w9, #NK_LIKE
    b.eq 2f
    cmp  w9, #NK_FUNC
    b.eq 3f
    cmp  w9, #NK_IN
    b.eq 3f
    cmp  w9, #NK_CASE
    b.eq 4f
    cmp  w9, #NK_AGG
    b.eq 5f
    mov  x0, #0
    ret
1:  mov  x0, #1
    ret
2:  mov  x0, #2
    ret
3:  ldr  x0, [x0, #N_VAL]
    ret
4:  ldr  x9, [x0, #N_VAL]
    ldr  x10, [x0, #N_B]
    cmp  x10, #0
    cset x10, ne
    add  x0, x10, x9, lsl #1
    ret
5:  ldr  x9, [x0, #N_A]
    cmp  x9, #0
    cset x0, ne
    ret
ENDF expr_nchildren

// expr_child_slot(x0 Node*, x1 index) -> x0 Node** address of child i   (leaf)
FUNC expr_child_slot
    ldr  w9, [x0, #N_KIND]
    cmp  w9, #NK_BINARY
    b.eq 2f
    cmp  w9, #NK_LIKE
    b.eq 2f
    cmp  w9, #NK_FUNC
    b.eq 3f
    cmp  w9, #NK_IN
    b.eq 3f
    cmp  w9, #NK_CASE
    b.eq 4f
1:  add  x0, x0, #N_A                   // unary kinds, NK_INSUB, NK_AGG
    ret
2:  cbz  x1, 1b
    add  x0, x0, #N_B
    ret
3:  ldr  x9, [x0, #N_C]
    add  x0, x9, x1, lsl #3
    ret
4:  ldr  x9, [x0, #N_VAL]
    cmp  x1, x9, lsl #1
    b.lo 3b
    add  x0, x0, #N_B                   // ELSE
    ret
ENDF expr_child_slot

// =============================================================================
// expr_equal(x0 Node*, x1 Node*) -> w0 1 if structurally equal (bound trees):
// same kind, operator / function id, type, literal value or column binding,
// and pairwise equal children. Subqueries are equal only to themselves.
//   x19 a, x20 b, x21 child index, x22 child count
// =============================================================================
FUNC expr_equal
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    cmp  x19, x20
    b.eq .Lee_true
    cbz  x19, .Lee_false
    cbz  x20, .Lee_false
    ldp  w9, w10, [x19, #N_KIND]        // kind, op
    ldp  w11, w12, [x20, #N_KIND]
    cmp  w9, w11
    b.ne .Lee_false
    cmp  w10, w12
    b.ne .Lee_false
    ldr  w10, [x19, #N_TYPE]
    ldr  w12, [x20, #N_TYPE]
    cmp  w10, w12
    b.ne .Lee_false
    cmp  w9, #NK_LIT
    b.eq .Lee_lit
    cmp  w9, #NK_COL
    b.eq .Lee_col
    cmp  w9, #NK_GKEY
    b.eq .Lee_gkey
    cmp  w9, #NK_SUBQ
    b.eq .Lee_false
    cmp  w9, #NK_EXISTS
    b.eq .Lee_false
    cmp  w9, #NK_INSUB
    b.eq .Lee_insub
    cmp  w9, #NK_AGG
    b.ne .Lee_children
    ldr  w9, [x19, #N_FLAGS]            // aggregates: same DISTINCT-ness
    ldr  w10, [x20, #N_FLAGS]
    eor  w9, w9, w10
    tst  w9, #NF_DISTINCT
    b.ne .Lee_false
    b    .Lee_children
.Lee_insub:
    ldr  x9, [x19, #N_C]
    ldr  x10, [x20, #N_C]
    cmp  x9, x10
    b.ne .Lee_false
.Lee_children:
    mov  x0, x19
    bl   expr_nchildren
    mov  x22, x0
    mov  x0, x20
    bl   expr_nchildren
    cmp  x0, x22
    b.ne .Lee_false
    mov  x21, #0
1:  cmp  x21, x22
    b.hs .Lee_true
    mov  x0, x19
    mov  x1, x21
    bl   expr_child_slot
    ldr  x23, [x0]
    mov  x0, x20
    mov  x1, x21
    bl   expr_child_slot
    ldr  x1, [x0]
    mov  x0, x23
    bl   expr_equal
    cbz  w0, .Lee_false
    add  x21, x21, #1
    b    1b
.Lee_lit:
    ldr  w9, [x19, #N_FLAGS]
    ldr  w10, [x20, #N_FLAGS]
    and  w9, w9, #NF_NULL
    and  w10, w10, #NF_NULL
    cmp  w9, w10
    b.ne .Lee_false
    cbnz w9, .Lee_true                  // both NULL
    ldr  x0, [x19, #N_VAL]
    ldr  x1, [x20, #N_VAL]
    ldrb w9, [x19, #N_TYPE]
    cmp  w9, #T_STR
    b.ne .Lee_val
    ldr  x2, [x0, #STR_LEN]
    ldr  x3, [x1, #STR_LEN]
    cmp  x2, x3
    b.ne .Lee_false
    add  x0, x0, #STR_DATA
    add  x1, x1, #STR_DATA
    bl   memcmp
    cbnz w0, .Lee_false
    b    .Lee_true
.Lee_col:
    ldr  x0, [x19, #N_B]
    ldr  x1, [x20, #N_B]
    cmp  x0, x1
    b.ne .Lee_false
.Lee_gkey:
    ldr  x0, [x19, #N_VAL]
    ldr  x1, [x20, #N_VAL]
.Lee_val:
    cmp  x0, x1
    b.ne .Lee_false
.Lee_true:
    mov  w0, #1
    LEAVE 3
.Lee_false:
    mov  w0, #0
    LEAVE 3
ENDF expr_equal

// =============================================================================
// LIMIT / OFFSET (grammar.md §2 notes): constant INT64 expressions.
// bind_limit_expr(x0 ctx, x1 Node* or 0) -> x0 bound Node*, or 0 when absent or
// of the null type (treated as absent).
//   x19 ctx
// =============================================================================
LFUNC bind_limit_expr
    cbnz x1, 1f
    mov  x0, #0
    ret
1:  ENTER 1
    mov  x19, x0
    mov  w9, #BF_NO_COLS                // no columns, no aggregates
    str  w9, [x19, #BC_FLAGS]
    bl   bind_expr
    ldrb w9, [x0, #N_TYPE]
    cbz  w9, 2f
    cmp  w9, #T_INT
    b.ne .Lble_type
    LEAVE 1
2:  mov  x0, #0
    LEAVE 1
.Lble_type:
    RAISE ERR_TYPE, "LIMIT/OFFSET must be an INT64 expression"
ENDF bind_limit_expr

// eval_limit(x0 bound Node* or 0, x1 default) -> x0 value
// Evaluates in a constant context; NULL => default; < 0 raises.
//   x19 default, x20 node
LFUNC eval_limit
    cbnz x0, 1f
    mov  x0, x1
    ret
1:  ENTER 2
    sub  sp, sp, #EC_SIZE
    mov  x19, x1
    mov  x20, x0
    mov  x0, sp                         // zeroed EvalCtx (constant context)
    mov  w1, #0
    mov  x2, #EC_SIZE
    bl   memset
    mov  x0, x20
    mov  x1, sp
    bl   eval
    add  sp, sp, #EC_SIZE
    cbz  x1, 2f
    mov  x0, x19                        // NULL: as if absent
    LEAVE 2
2:  tbnz x0, #63, .Lel_neg
    LEAVE 2
.Lel_neg:
    RAISE ERR_INVALID_ARGUMENT, "LIMIT/OFFSET must not be negative"
ENDF eval_limit

    NOTE_GNU_STACK
