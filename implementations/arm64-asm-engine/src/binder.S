// =============================================================================
// binder.S — semantic analysis: name resolution, typing, aggregate collection.
//
//   bind_query(x0 Query*) -> x0 BoundQuery*      (raises SEMANTIC / TYPE /
//                                                 UNSUPPORTED / INVALID_ARGUMENT)
//
// Structure (designed to grow with later phases):
//   * A binder context (BC_*) carries the query, the BoundQuery under
//     construction, the scope (array of range variables, RV_*), the current
//     clause flags (BF_*) and growable vectors for aggregate slots and hidden
//     ORDER BY expressions.
//   * bind_expr(ctx, node) is a recursive dispatcher; each node kind has its
//     own binder (bind_col, bind_unary, bind_binary, ...). Binding mutates the
//     AST in place (it lives in the request arena) and may wrap operands in
//     new implicit NK_CAST nodes so that at run time every binary operator
//     sees operands of the same type kind (DECIMAL operands of + - and
//     comparisons may still differ in scale; eval aligns them exactly).
//   * Aggregate calls are converted into NK_AGG nodes and registered as slots.
//     Whether a query is aggregated is known only after SELECT and ORDER BY
//     are bound, so the "no bare column outside aggregates" rule is a
//     post-pass (check_agg_refs) — the natural place to add GROUP BY matching.
//   * Nothing is evaluated during binding except LIMIT/OFFSET, which happens
//     last so that all semantic/type errors take precedence over runtime ones.
// =============================================================================
#include "pq.inc"

// ------------------------------------------------------- binder context -----
#define BC_Q        0       // Query*
#define BC_BQ       8       // BoundQuery*
#define BC_NRV      16      // u64 number of range variables in scope
#define BC_RVS      24      // RV* array (capacity MAX_RV)
#define BC_FLAGS    32      // u32 BF_* flags of the clause being bound
#define BC_AGGV     40      // Vec of NK_AGG Node* (slot order)
#define BC_EXV      64      // Vec of hidden ORDER BY expressions
#define BC_SIZE     96

// Range variable (one per FROM table reference)
#define RV_NAME     0       // Str* alias, or table name
#define RV_TABLE    8       // Table*
#define RV_SIZE     16
#define MAX_RV      16

// Growable vector of pointers (arena backed)
#define V_N         0
#define V_CAP       8
#define V_DATA      16

// Clause flags
#define BF_AGG_OK   1       // aggregates allowed (SELECT list, ORDER BY)
#define BF_IN_AGG   2       // currently inside an aggregate argument
#define BF_NO_COLS  4       // column references forbidden (LIMIT / OFFSET)

// Function table ids local to the binder

#define DEC18       (T_DEC | (18 << T_PREC_SHIFT))   // DECIMAL(18,0)

// ------------------------------------------------------------ frame macros --
// ENTER np: frame record + np pairs of callee-saved registers (x19..x28).
.macro ENTER np
    stp  x29, x30, [sp, #-(16 + 16 * \np)]!
    mov  x29, sp
    .if \np >= 1
    stp  x19, x20, [sp, #16]
    .endif
    .if \np >= 2
    stp  x21, x22, [sp, #32]
    .endif
    .if \np >= 3
    stp  x23, x24, [sp, #48]
    .endif
    .if \np >= 4
    stp  x25, x26, [sp, #64]
    .endif
    .if \np >= 5
    stp  x27, x28, [sp, #80]
    .endif
.endm

.macro LEAVE np
    LEAVE_NORET \np
    ret
.endm

// LEAVE_NORET np: restore registers and pop the frame without returning
// (for tail calls).
.macro LEAVE_NORET np
    .if \np >= 5
    ldp  x27, x28, [sp, #80]
    .endif
    .if \np >= 4
    ldp  x25, x26, [sp, #64]
    .endif
    .if \np >= 3
    ldp  x23, x24, [sp, #48]
    .endif
    .if \np >= 2
    ldp  x21, x22, [sp, #32]
    .endif
    .if \np >= 1
    ldp  x19, x20, [sp, #16]
    .endif
    ldp  x29, x30, [sp], #(16 + 16 * \np)
.endm

// RAISE_S code, "prefix", strreg: raise with message prefix + 'Str contents'
.macro RAISE_S code, msg, sreg
    ldr  x3, [\sreg, #STR_LEN]
    add  x2, \sreg, #STR_DATA
    mov  w0, #\code
    adr  x1, 9996f
    b    pq_raise_s
9996: .asciz "\msg"
    .p2align 2
.endm

// =============================================================================
// bind_query(x0 Query*) -> x0 BoundQuery*
//   x19 ctx, x20 Query*, x21 BoundQuery*, x22/x23 bound LIMIT/OFFSET exprs
// =============================================================================
FUNC bind_query
    ENTER 3
    mov  x20, x0

    // --- features outside Phase 1 ------------------------------------------
    ldr  x9, [x20, #Q_NCTES]
    cbnz x9, .Lbq_unsup_cte
    ldr  w9, [x20, #Q_DISTINCT]
    cbnz w9, .Lbq_unsup_distinct
    ldr  x9, [x20, #Q_NGROUP]
    cbnz x9, .Lbq_unsup_group
    ldr  x9, [x20, #Q_HAVING]
    cbnz x9, .Lbq_unsup_having

    // --- allocate context, BoundQuery, scope --------------------------------
    mov  x0, #BC_SIZE
    bl   arena_zalloc
    mov  x19, x0
    str  x20, [x19, #BC_Q]
    mov  x0, #BQ_SIZE
    bl   arena_zalloc
    mov  x21, x0
    str  x21, [x19, #BC_BQ]
    mov  x9, #-1
    str  x9, [x21, #BQ_LIMIT]
    mov  x0, #(RV_SIZE * MAX_RV)
    bl   arena_zalloc
    str  x0, [x19, #BC_RVS]

    // --- FROM ---------------------------------------------------------------
    ldr  x1, [x20, #Q_FROM]
    cbz  x1, 1f
    mov  x0, x19
    bl   bind_from
    ldr  x9, [x19, #BC_RVS]
    ldr  x9, [x9, #RV_TABLE]            // phase 1: exactly one table
    str  x9, [x21, #BQ_TABLE]
1:
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
    ldrb w9, [x0, #N_TYPE]
    cmp  w9, #T_NULL
    b.eq 2f
    cmp  w9, #T_BOOL
    b.ne .Lbq_where_type
2:
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

    mov  x0, x21
    LEAVE 3

.Lbq_unsup_cte:
    RAISE ERR_UNSUPPORTED, "WITH (common table expressions) is not supported"
.Lbq_unsup_distinct:
    RAISE ERR_UNSUPPORTED, "SELECT DISTINCT is not supported"
.Lbq_unsup_group:
    RAISE ERR_UNSUPPORTED, "GROUP BY is not supported"
.Lbq_unsup_having:
    RAISE ERR_UNSUPPORTED, "HAVING is not supported"
.Lbq_where_type:
    RAISE ERR_TYPE, "WHERE condition must be BOOLEAN"
ENDF bind_query

// =============================================================================
// bind_from(x0 ctx, x1 FromItem*) — adds range variables to the scope.
//   x19 ctx, x20 FromItem*, x21 Table*
// =============================================================================
LFUNC bind_from
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x20, #FR_KIND]
    cmp  w9, #FRK_TABLE
    b.ne .Lbf_unsup
    ldr  x9, [x20, #FR_NAME]
    add  x0, x9, #STR_DATA
    ldr  x1, [x9, #STR_LEN]
    bl   catalog_find
    cbz  x0, .Lbf_unknown
    mov  x21, x0
    // register the range variable: alias if given, else the table name
    ldr  x9, [x19, #BC_NRV]
    cmp  x9, #MAX_RV
    b.hs .Lbf_unsup
    ldr  x10, [x19, #BC_RVS]
    add  x10, x10, x9, lsl #4
    ldr  x11, [x20, #FR_ALIAS]
    cbnz x11, 1f
    ldr  x11, [x20, #FR_NAME]
1:  str  x11, [x10, #RV_NAME]
    str  x21, [x10, #RV_TABLE]
    add  x9, x9, #1
    str  x9, [x19, #BC_NRV]
    LEAVE 2
.Lbf_unknown:
    ldr  x9, [x20, #FR_NAME]
    RAISE_S ERR_SEMANTIC, "unknown table ", x9
.Lbf_unsup:
    RAISE ERR_UNSUPPORTED, "joins and derived tables are not supported"
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
    ldr  x9, [x19, #BC_RVS]
    add  x9, x9, x21, lsl #4
    ldr  x0, [x9, #RV_NAME]
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

// rv_column(x0 ctx, x1 rv index, x2 column index) -> x0 Column*   (leaf)
LFUNC rv_column
    ldr  x9, [x0, #BC_RVS]
    add  x9, x9, x1, lsl #4
    ldr  x9, [x9, #RV_TABLE]
    ldr  x9, [x9, #TBL_COLS]
    add  x0, x9, x2, lsl #5             // COL_SIZE = 32
    ret
ENDF rv_column

// rv_ncols(x0 ctx, x1 rv index) -> x0 number of columns   (leaf)
LFUNC rv_ncols
    ldr  x9, [x0, #BC_RVS]
    add  x9, x9, x1, lsl #4
    ldr  x9, [x9, #RV_TABLE]
    ldr  x0, [x9, #TBL_NCOLS]
    ret
ENDF rv_ncols

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
    RAISE ERR_UNSUPPORTED, "subqueries are not supported"
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
// Resolves [q.]c against the range variables in scope.
//   x19 ctx, x20 node, x21 rv index, x22 column index, x23 ncols,
//   x24 found rv (-1 none), x25 found column, x26 qualifier matched flag
// =============================================================================
LFUNC bind_col
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ldr  w9, [x19, #BC_FLAGS]
    tbnz w9, #2, .Lbc_nocols            // BF_NO_COLS
    mov  x24, #-1
    mov  x26, #0
    mov  x21, #0
.Lbc_rv:
    ldr  x9, [x19, #BC_NRV]
    cmp  x21, x9
    b.hs .Lbc_done
    ldr  x1, [x20, #N_C]                // qualifier must name this rv
    cbz  x1, 1f
    ldr  x9, [x19, #BC_RVS]
    add  x9, x9, x21, lsl #4
    ldr  x0, [x9, #RV_NAME]
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
    cbnz w0, 2f
    add  x22, x22, #1
    b    .Lbc_colloop
2:  tbz  x24, #63, .Lbc_ambiguous       // already matched another rv
    mov  x24, x21
    mov  x25, x22
.Lbc_next_rv:
    add  x21, x21, #1
    b    .Lbc_rv
.Lbc_done:
    tbnz x24, #63, .Lbc_unknown
    str  x25, [x20, #N_VAL]
    str  x24, [x20, #N_B]
    mov  x0, x19
    mov  x1, x24
    mov  x2, x25
    bl   rv_column
    ldr  w9, [x0, #COL_TYPE]
    str  w9, [x20, #N_TYPE]
    ldr  w9, [x20, #N_FLAGS]
    bic  w9, w9, #NF_CONST
    str  w9, [x20, #N_FLAGS]
    mov  x0, x20
    LEAVE 4
.Lbc_unknown:
    ldr  x9, [x20, #N_C]
    cbz  x9, 3f
    cbnz x26, 3f
    RAISE_S ERR_SEMANTIC, "unknown table or alias ", x9
3:  ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "unknown column ", x9
.Lbc_ambiguous:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "ambiguous column ", x9
.Lbc_nocols:
    RAISE ERR_SEMANTIC, "LIMIT/OFFSET must be a constant expression"
ENDF bind_col

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
1:  // unary + / -: numeric, type preserved; -NULL is INT64
    cbnz w11, 2f
    mov  w10, #T_INT
    b    9f
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
    b.eq .Lbb_done                      // same kind (DECIMAL scales may differ)
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
2:  cmp  w26, #T_INT                    // INT vs DECIMAL(p,s): INT -> DECIMAL(18,s)
    b.ne 3f
    and  w1, w24, #(0xff << T_SCALE_SHIFT)
    mov  w9, #DEC18
    orr  w1, w1, w9
    mov  x0, x21
    bl   mk_cast
    mov  x21, x0
    b    .Lbb_done
3:  and  w1, w23, #(0xff << T_SCALE_SHIFT)
    mov  w9, #DEC18
    orr  w1, w1, w9
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
4:  cmp  w25, #OP_MUL
    b.ne 5f
    // DECIMAL *: result scale s1+s2 (> 18 => TYPE_ERROR); INT64 -> DECIMAL(18,0)
    add  w14, w12, w13
    cmp  w14, #18
    b.hi .Lbb_scale_type
    mov  w28, #DEC18
    orr  w28, w28, w14, lsl #T_SCALE_SHIFT
    mov  w15, #DEC18                    // cast target for INT64 operands
    b    6f
5:  // DECIMAL + -: result scale max(s1,s2); INT64 -> DECIMAL(18, other scale)
    cmp  w12, w13
    csel w14, w12, w13, hi
    mov  w28, #DEC18
    orr  w28, w28, w14, lsl #T_SCALE_SHIFT
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
    RAISE ERR_TYPE, "DECIMAL product scale exceeds 18"
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
    tbnz w9, #1, .Lbfn_distinct         // NF_DISTINCT
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
    and  w24, w10, #(0xff << T_SCALE_SHIFT)  // SUM DECIMAL(p,s) -> DECIMAL(18,s)
    mov  w9, #DEC18
    orr  w24, w24, w9
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
.Lbfn_distinct:
    RAISE ERR_UNSUPPORTED, "aggregate DISTINCT is not supported"
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
    cbnz x0, 5f
    ldr  w9, [x26, #N_KIND]
    cmp  w9, #NK_COL
    b.ne 4f
    mov  x0, x19                        // bare column: its declared name
    ldr  x1, [x26, #N_B]
    ldr  x2, [x26, #N_VAL]
    bl   rv_column
    ldr  x0, [x0, #COL_NAME]
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
// bind_order(x0 ctx) — ORDER BY keys (semantics.md §6)
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
4:  ldr  x9, [x20, #BQ_OUT]             // further match: must be the same expr
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

.Lbo_expr:                              // hidden expression over input columns
    mov  w9, #BF_AGG_OK
    str  w9, [x19, #BC_FLAGS]
    mov  x0, x19
    mov  x1, x25
    bl   bind_expr
    mov  x1, x0
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
.Lbo_ambiguous:
    ldr  x9, [x25, #N_NAME]
    RAISE_S ERR_SEMANTIC, "ambiguous ORDER BY column ", x9
ENDF bind_order

// =============================================================================
// finish_aggregation(x0 ctx)
// Publishes the aggregate slots; in an aggregated query (no GROUP BY yet) no
// column reference may appear outside aggregate arguments in the select list
// or ORDER BY.
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
    cbz  x9, 9f
    mov  x9, #1
    str  x9, [x20, #BQ_ISAGG]
    mov  x21, #0
    ldr  x22, [x20, #BQ_NOUT]
1:  cmp  x21, x22
    b.hs 2f
    ldr  x9, [x20, #BQ_OUT]
    add  x9, x9, x21, lsl #5
    ldr  x0, [x9, #OC_EXPR]
    bl   check_agg_refs
    add  x21, x21, #1
    b    1b
2:  mov  x21, #0
    ldr  x22, [x20, #BQ_NEXTRA]
3:  cmp  x21, x22
    b.hs 9f
    ldr  x9, [x20, #BQ_EXTRA]
    ldr  x0, [x9, x21, lsl #3]
    bl   check_agg_refs
    add  x21, x21, #1
    b    3b
9:  LEAVE 2
ENDF finish_aggregation

// check_agg_refs(x0 Node*) — raises SEMANTIC_ERROR on a column reference
// outside aggregate arguments.
//   x19 node, x20 argument index, x21 argument count
LFUNC check_agg_refs
    ENTER 2
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_COL
    b.eq .Lcar_col
    cmp  w9, #NK_BINARY
    b.eq 1f
    cmp  w9, #NK_UNARY
    b.eq 2f
    cmp  w9, #NK_CAST
    b.eq 2f
    cmp  w9, #NK_ISNULL
    b.eq 2f
    cmp  w9, #NK_FUNC
    b.eq 3f
    b    9f                             // literals, aggregates
1:  ldr  x0, [x19, #N_B]
    bl   check_agg_refs
2:  ldr  x0, [x19, #N_A]
    bl   check_agg_refs
    b    9f
3:  mov  x20, #0
    ldr  x21, [x19, #N_VAL]
4:  cmp  x20, x21
    b.hs 9f
    ldr  x9, [x19, #N_C]
    ldr  x0, [x9, x20, lsl #3]
    bl   check_agg_refs
    add  x20, x20, #1
    b    4b
9:  LEAVE 2
.Lcar_col:
    ldr  x9, [x19, #N_NAME]
    RAISE_S ERR_SEMANTIC, "column must be used inside an aggregate: ", x9
ENDF check_agg_refs

// =============================================================================
// expr_equal(x0 Node*, x1 Node*) -> w0 1 if structurally equal (bound trees)
//   x19 a, x20 b, x21 argument index, x22 argument count
// =============================================================================
LFUNC expr_equal
    ENTER 2
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
    cmp  w9, #NK_BINARY
    b.eq .Lee_bin
    cmp  w9, #NK_UNARY
    b.eq .Lee_a
    cmp  w9, #NK_CAST
    b.eq .Lee_a
    cmp  w9, #NK_ISNULL
    b.eq .Lee_a
    cmp  w9, #NK_AGG
    b.eq .Lee_agg
    cmp  w9, #NK_FUNC
    b.eq .Lee_func
    b    .Lee_false
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
    ldr  x0, [x19, #N_VAL]
    ldr  x1, [x20, #N_VAL]
.Lee_val:
    cmp  x0, x1
    b.ne .Lee_false
    b    .Lee_true
.Lee_bin:
    ldr  x0, [x19, #N_B]
    ldr  x1, [x20, #N_B]
    bl   expr_equal
    cbz  w0, .Lee_false
.Lee_a:
    ldr  x0, [x19, #N_A]
    ldr  x1, [x20, #N_A]
    bl   expr_equal
    LEAVE 2
.Lee_agg:
    ldr  w9, [x19, #N_FLAGS]
    ldr  w10, [x20, #N_FLAGS]
    eor  w9, w9, w10
    tst  w9, #NF_DISTINCT
    b.ne .Lee_false
    b    .Lee_a                         // COUNT(*): both arguments are 0
.Lee_func:
    ldr  x22, [x19, #N_VAL]
    ldr  x9, [x20, #N_VAL]
    cmp  x22, x9
    b.ne .Lee_false
    mov  x21, #0
1:  cmp  x21, x22
    b.hs .Lee_true
    ldr  x9, [x19, #N_C]
    ldr  x0, [x9, x21, lsl #3]
    ldr  x9, [x20, #N_C]
    ldr  x1, [x9, x21, lsl #3]
    bl   expr_equal
    cbz  w0, .Lee_false
    add  x21, x21, #1
    b    1b
.Lee_true:
    mov  w0, #1
    LEAVE 2
.Lee_false:
    mov  w0, #0
    LEAVE 2
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
// Evaluates without table/aggregate context; NULL => default; < 0 raises.
//   x19 default
LFUNC eval_limit
    cbnz x0, 1f
    mov  x0, x1
    ret
1:  ENTER 1
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
    LEAVE 1
2:  tbnz x0, #63, .Lel_neg
    LEAVE 1
.Lel_neg:
    RAISE ERR_INVALID_ARGUMENT, "LIMIT/OFFSET must not be negative"
ENDF eval_limit

    NOTE_GNU_STACK
