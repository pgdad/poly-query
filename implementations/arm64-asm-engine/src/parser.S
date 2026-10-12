// =============================================================================
// parser.S — recursive-descent SQL parser (grammar.md §2) producing the AST
// described in pq.inc (Node / Query / SelectItem / FromItem / CTE / Statement).
//
// Entry point: parse_sql(x0 ptr, x1 len) -> x0 Statement*
//
// The lexer (lexer.S) first converts the whole text into a Token array ending
// with TK_EOF. Parsing state is a small Parser record (on parse_sql's stack)
// whose address is passed in x0 to every parse function, which keeps it in
// x19. Nothing is global, so the parser is reentrant.
//
// All AST memory comes from the request arena (arena_zalloc); identifiers and
// strings are Str* created by the lexer. Every error raises via pq_raise_pos
// (or lex_raise_text) with the line/column of the offending token:
//   PARSE_ERROR            syntax errors
//   UNSUPPORTED            FULL / RIGHT / UNION [DISTINCT] used as syntax
//   NUMERIC_OVERFLOW       integer literal > INT64_MAX, non-finite float literal
//   CONVERSION_ERROR       invalid DATE / TIMESTAMP literal
//   SEMANTIC_ERROR         unknown CAST type name or invalid type parameters
//   RESOURCE_LIMIT         nesting deeper than PARSE_MAX_DEPTH
//
// Expression precedence (lowest first), one function per level:
//   p_expr/OR -> AND -> p_not (NOT, right) -> p_pred (comparison, IS, BETWEEN,
//   IN, LIKE; non-associative) -> || -> + - -> * / % -> p_unary (+ -, right)
//   -> p_primary
// The left-associative binary levels share one table-driven loop (p_binloop).
// =============================================================================
#include "pq.inc"
#include "lexer.inc"

// Parser state record
#define PS_CUR     0        // Token* current token
#define PS_DEPTH   8        // u64 current nesting depth (expressions, FROM)
#define PS_SIZE    16

#define PARSE_MAX_DEPTH 256

// Growable array ("vector") living in a caller's stack frame. Elements are
// zero-initialised; growth copies into a new arena block (doubling).
#define V_DATA     0        // element array (0 while empty)
#define V_COUNT    8        // u64 number of elements
#define V_CAP      16       // u64 capacity (elements)
#define V_ESZ      24       // u64 element size in bytes
#define V_SIZE     32

#define INT64_MIN_BITS 0x8000000000000000

// ------------------------------------------------------------------ macros ---
// All macros assume x19 = Parser*.

// \reg = current token
.macro CURTOK reg
    ldr  \reg, [x19, #PS_CUR]
.endm

// \wreg = kind of the current token (clobbers x9)
.macro CURKIND wreg
    ldr  x9, [x19, #PS_CUR]
    ldr  \wreg, [x9, #TK_KIND]
.endm

// consume the current token (clobbers x9); never used on TK_EOF
.macro ADVANCE
    ldr  x9, [x19, #PS_CUR]
    add  x9, x9, #TK_SIZE
    str  x9, [x19, #PS_CUR]
.endm

// w0 = 1 and consume if the current token has kind \kind, else w0 = 0
.macro ACCEPT kind
    mov  x0, x19
    mov  w1, #\kind
    bl   p_accept
.endm

// consume a token of kind \kind (x0 = the token) or raise PARSE_ERROR
.macro EXPECT kind
    mov  x0, x19
    mov  w1, #\kind
    bl   p_expect
.endm

// call parse function \fn with the parser as argument
.macro PCALL fn
    mov  x0, x19
    bl   \fn
.endm

// initialise a vector at [sp, #\off] with element size \esz
.macro VEC_INIT off, esz
    stp  xzr, xzr, [sp, #\off]
    mov  x9, #\esz
    stp  xzr, x9, [sp, #(\off + 16)]
.endm

// x0 = pointer to a new zeroed element of the vector at [sp, #\off]
.macro VEC_PUSH off
    add  x0, sp, #\off
    bl   vec_push
.endm

// nesting depth accounting (guards the native stack against deep recursion)
.macro DEPTH_ENTER
    ldr  x9, [x19, #PS_DEPTH]
    add  x9, x9, #1
    str  x9, [x19, #PS_DEPTH]
    cmp  x9, #PARSE_MAX_DEPTH
    b.ls 8801f
    mov  x0, x19
    bl   p_too_deep
8801:
.endm

.macro DEPTH_LEAVE
    ldr  x9, [x19, #PS_DEPTH]
    sub  x9, x9, #1
    str  x9, [x19, #PS_DEPTH]
.endm

// ------------------------------------------------------------------- data ----
    .section .rodata
// Operator tables for p_binloop: (token kind, OP_* code) byte pairs, 0 ends.
optab_or:     .byte KW_OR, OP_OR, 0
optab_and:    .byte KW_AND, OP_AND, 0
optab_concat: .byte TK_CONCAT, OP_CONCAT, 0
optab_add:    .byte TK_PLUS, OP_ADD, TK_MINUS, OP_SUB, 0
optab_mul:    .byte TK_STAR, OP_MUL, TK_SLASH, OP_DIV, TK_PERCENT, OP_MOD, 0

s_hash:          .asciz "HASH"
s_btree:         .asciz "BTREE"
msg_syntax:      .asciz "syntax error at or near "
msg_eoi:         .asciz "syntax error: unexpected end of input"
msg_unsupported: .asciz "unsupported syntax "
msg_too_deep:    .asciz "statement nesting too deep"
msg_int_range:   .asciz "integer literal out of range "
msg_num_range:   .asciz "numeric literal out of range "
msg_bad_date:    .asciz "invalid DATE literal "
msg_bad_ts:      .asciz "invalid TIMESTAMP literal "
msg_bad_type:    .asciz "unknown type name "
msg_bad_tparams: .asciz "invalid type parameters for "

    .text

// =============================================================================
// parse_sql(x0 ptr, x1 len) -> x0 Statement*
//
//   statement = ( query | create_index | drop_index | explain ) [ ";" ] EOF
//
// Registers: x19 Parser* (record at [sp,#48]), x20 Statement*, x21 token
// =============================================================================
FUNC parse_sql
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    bl   lex_tokenize
    add  x19, sp, #48
    str  x0, [x19, #PS_CUR]
    str  xzr, [x19, #PS_DEPTH]
    mov  x0, #ST_SIZE
    bl   arena_zalloc
    mov  x20, x0

    CURKIND w10
    cmp  w10, #KW_EXPLAIN
    b.eq .Lst_explain
    cmp  w10, #KW_CREATE
    b.eq .Lst_create
    cmp  w10, #KW_DROP
    b.eq .Lst_drop
    mov  w9, #SK_QUERY              // anything else must be a query
    str  w9, [x20, #ST_KIND]
    PCALL p_query
    str  x0, [x20, #ST_QUERY]
    b    .Lst_end

.Lst_explain:                       // EXPLAIN query
    ADVANCE
    mov  w9, #SK_EXPLAIN
    str  w9, [x20, #ST_KIND]
    PCALL p_query
    str  x0, [x20, #ST_QUERY]
    b    .Lst_end

.Lst_create:    // CREATE INDEX [IF NOT EXISTS] name ON table (col) [USING HASH|BTREE]
    ADVANCE
    mov  w9, #SK_CREATE_INDEX
    str  w9, [x20, #ST_KIND]
    EXPECT KW_INDEX
    ACCEPT KW_IF
    cbz  w0, 1f
    EXPECT KW_NOT
    EXPECT KW_EXISTS
    mov  w9, #1
    str  w9, [x20, #ST_FLAGS]
1:  PCALL p_expect_ident
    str  x0, [x20, #ST_INDEX]
    EXPECT KW_ON
    PCALL p_expect_ident
    str  x0, [x20, #ST_TABLE]
    EXPECT TK_LPAREN
    PCALL p_expect_ident
    str  x0, [x20, #ST_COLUMN]
    EXPECT TK_RPAREN
    ACCEPT KW_USING
    cbz  w0, .Lst_end
    CURTOK x21                      // HASH / BTREE are plain identifiers
    ldr  w10, [x21, #TK_KIND]
    cmp  w10, #TK_IDENT
    b.ne .Lst_error
    ldr  x0, [x21, #TK_STR]
    ADR_L x1, s_hash
    bl   str_ieq_c
    mov  w9, #1
    cbnz w0, 2f
    ldr  x0, [x21, #TK_STR]
    ADR_L x1, s_btree
    bl   str_ieq_c
    cbz  w0, .Lst_error
    mov  w9, #2
2:  str  w9, [x20, #ST_USING]
    ADVANCE
    b    .Lst_end

.Lst_drop:                          // DROP INDEX [IF EXISTS] name
    ADVANCE
    mov  w9, #SK_DROP_INDEX
    str  w9, [x20, #ST_KIND]
    EXPECT KW_INDEX
    ACCEPT KW_IF
    cbz  w0, 1f
    EXPECT KW_EXISTS
    mov  w9, #1
    str  w9, [x20, #ST_FLAGS]
1:  PCALL p_expect_ident
    str  x0, [x20, #ST_INDEX]

.Lst_end:                           // [ ";" ] then end of input
    ACCEPT TK_SEMI
    CURKIND w10
    cbnz w10, .Lst_error            // TK_EOF == 0
    mov  x0, x20
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #64
    ret
.Lst_error:
    mov  x0, x19
    bl   p_error
ENDF parse_sql

// =============================================================================
// Query level
// =============================================================================

// -----------------------------------------------------------------------------
// p_query(x0 P) -> x0 Query*
//   query = [ with_clause ] compound [ order_by ] [ limit_clause ]
//   compound = select_core { UNION ALL select_core }   (CR-1)
//   order_item = expr [ASC|DESC] [NULLS (FIRST|LAST)]
//   limit_clause = LIMIT e [OFFSET e] | OFFSET e [LIMIT e]
// Registers: x19 P, x20 Query*, x21 order expr, w22 desc, w23 nulls.
// Stack: order-item vector at [sp,#64].
// -----------------------------------------------------------------------------
LFUNC p_query
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  x0, #Q_SIZE
    bl   arena_zalloc
    mov  x20, x0

    CURKIND w10
    cmp  w10, #KW_WITH
    b.ne 1f
    ADVANCE
    mov  x0, x19
    mov  x1, x20
    bl   p_with
1:  mov  x0, x19
    mov  x1, x20
    bl   p_select_core
    CURKIND w10                     // compound: { UNION ALL select_core }
    cmp  w10, #KW_UNION
    b.ne 11f
    mov  x0, x19
    mov  x1, x20
    bl   p_union

11: CURKIND w10                     // ORDER BY
    cmp  w10, #KW_ORDER
    b.ne .Lq_limit
    ADVANCE
    EXPECT KW_BY
    VEC_INIT 64, OI_SIZE
2:  PCALL p_expr
    mov  x21, x0
    mov  w22, #0
    mov  w23, #0
    ACCEPT KW_ASC
    cbnz w0, 3f
    ACCEPT KW_DESC
    mov  w22, w0
3:  ACCEPT KW_NULLS
    cbz  w0, 4f
    mov  w23, #1
    ACCEPT KW_FIRST
    cbnz w0, 4f
    mov  w23, #2
    EXPECT KW_LAST
4:  VEC_PUSH 64
    str  x21, [x0, #OI_EXPR]
    str  w22, [x0, #OI_DESC]
    str  w23, [x0, #OI_NULLS]
    ACCEPT TK_COMMA
    cbnz w0, 2b
    ldp  x9, x10, [sp, #64]
    str  x9, [x20, #Q_ORDER]
    str  x10, [x20, #Q_NORDER]

.Lq_limit:
    CURKIND w10
    cmp  w10, #KW_LIMIT
    b.eq 5f
    cmp  w10, #KW_OFFSET
    b.eq 6f
    b    .Lq_ret
5:  ADVANCE                         // LIMIT e [OFFSET e]
    PCALL p_expr
    str  x0, [x20, #Q_LIMIT]
    ACCEPT KW_OFFSET
    cbz  w0, .Lq_ret
    PCALL p_expr
    str  x0, [x20, #Q_OFFSET]
    b    .Lq_ret
6:  ADVANCE                         // OFFSET e [LIMIT e]
    PCALL p_expr
    str  x0, [x20, #Q_OFFSET]
    ACCEPT KW_LIMIT
    cbz  w0, .Lq_ret
    PCALL p_expr
    str  x0, [x20, #Q_LIMIT]
.Lq_ret:
    mov  x0, x20
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #96
    ret
ENDF p_query

// -----------------------------------------------------------------------------
// p_union(x0 P, x1 Query*) — the current token is UNION and the first
// select_core has been parsed into the Query. Moves that core into a new
// branch record, parses the remaining `UNION ALL select_core` branches and
// stores them in Q_UNION / Q_NUNION; the Query keeps its WITH clause and
// gets the ORDER BY / LIMIT of the whole compound. UNION without ALL ends in
// p_error (UNSUPPORTED).
// Registers: x19 P, x20 Query*, x21 branch. Stack: branch vector at [sp,#48].
// -----------------------------------------------------------------------------
LFUNC p_union
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    VEC_INIT 48, 8
    mov  x0, #Q_SIZE                // first branch = the core parsed so far
    bl   arena_zalloc
    mov  x21, x0
    mov  x1, x20
    mov  x2, #Q_CTES                // core fields precede Q_CTES
    bl   memcpy
    ldr  x9, [x20, #Q_LINE]         // line + column
    str  x9, [x21, #Q_LINE]
    mov  x0, x20
    mov  w1, #0
    mov  x2, #Q_CTES
    bl   memset
1:  VEC_PUSH 48
    str  x21, [x0]
    CURKIND w10
    cmp  w10, #KW_UNION
    b.ne 2f
    ldr  x9, [x19, #PS_CUR]         // UNION must be followed by ALL
    ldr  w10, [x9, #(TK_SIZE + TK_KIND)]
    cmp  w10, #KW_ALL
    b.ne 3f
    ADVANCE
    ADVANCE
    mov  x0, #Q_SIZE
    bl   arena_zalloc
    mov  x21, x0
    mov  x0, x19
    mov  x1, x21
    bl   p_select_core
    b    1b
2:  ldp  x9, x10, [sp, #48]
    str  x9, [x20, #Q_UNION]
    str  x10, [x20, #Q_NUNION]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #80
    ret
3:  mov  x0, x19                    // UNION [DISTINCT]: UNSUPPORTED
    bl   p_error
ENDF p_union

// -----------------------------------------------------------------------------
// p_with(x0 P, x1 Query*)   — WITH already consumed
//   with_clause = cte { "," cte }
//   cte = ident [ "(" ident { "," ident } ")" ] AS "(" query ")"
// Fills Q_CTES / Q_NCTES.
// Registers: x19 P, x20 Query*, x21 CTE name, x22 column name / sub-query.
// Stack: CTE vector at [sp,#48], column vector at [sp,#80].
// -----------------------------------------------------------------------------
LFUNC p_with
    stp  x29, x30, [sp, #-112]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    VEC_INIT 48, CTE_SIZE
1:  PCALL p_expect_ident
    mov  x21, x0
    VEC_INIT 80, 8
    ACCEPT TK_LPAREN
    cbz  w0, 3f
2:  PCALL p_expect_ident            // column list
    mov  x22, x0
    VEC_PUSH 80
    str  x22, [x0]
    ACCEPT TK_COMMA
    cbnz w0, 2b
    EXPECT TK_RPAREN
3:  EXPECT KW_AS
    EXPECT TK_LPAREN
    PCALL p_query
    mov  x22, x0
    EXPECT TK_RPAREN
    VEC_PUSH 48
    str  x21, [x0, #CTE_NAME]
    str  x22, [x0, #CTE_QUERY]
    ldp  x9, x10, [sp, #80]
    str  x9, [x0, #CTE_COLS]
    str  x10, [x0, #CTE_NCOLS]
    ACCEPT TK_COMMA
    cbnz w0, 1b
    ldp  x9, x10, [sp, #48]
    str  x9, [x20, #Q_CTES]
    str  x10, [x20, #Q_NCTES]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #112
    ret
ENDF p_with

// -----------------------------------------------------------------------------
// p_select_core(x0 P, x1 Query*)
//   select_core = SELECT [DISTINCT|ALL] select_item {"," select_item}
//                 [FROM from_item] [WHERE expr] [GROUP BY expr {"," expr}]
//                 [HAVING expr]
//   select_item = "*" | ident "." "*" | expr [ [AS] ident ]
// Registers: x19 P, x20 Query*, x21 item expr, x22 alias, w23 item kind,
//            x24 qualifier.  Stack: vector at [sp,#64] (items, then GROUP BY).
// -----------------------------------------------------------------------------
LFUNC p_select_core
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  x20, x1
    EXPECT KW_SELECT
    ldr  w9, [x0, #TK_LINE]
    str  w9, [x20, #Q_LINE]
    ldr  w9, [x0, #TK_COL]
    str  w9, [x20, #Q_COL]
    ACCEPT KW_DISTINCT
    cbz  w0, 1f
    mov  w9, #1
    str  w9, [x20, #Q_DISTINCT]
    b    2f
1:  ACCEPT KW_ALL
2:  VEC_INIT 64, SI_SIZE

.Lsc_item:
    mov  x21, #0
    mov  x22, #0
    mov  w23, #SIK_EXPR
    mov  x24, #0
    CURTOK x10
    ldr  w11, [x10, #TK_KIND]
    cmp  w11, #TK_STAR              // *
    b.ne 3f
    ADVANCE
    mov  w23, #SIK_STAR
    b    .Lsc_push
3:  cmp  w11, #TK_IDENT             // ident . *
    b.ne .Lsc_expr
    ldr  w12, [x10, #(TK_SIZE + TK_KIND)]
    cmp  w12, #TK_DOT
    b.ne .Lsc_expr
    ldr  w12, [x10, #(2 * TK_SIZE + TK_KIND)]
    cmp  w12, #TK_STAR
    b.ne .Lsc_expr
    ldr  x24, [x10, #TK_STR]
    add  x10, x10, #(3 * TK_SIZE)
    str  x10, [x19, #PS_CUR]
    mov  w23, #SIK_QSTAR
    b    .Lsc_push
.Lsc_expr:                          // expr [ [AS] ident ]
    PCALL p_expr
    mov  x21, x0
    ACCEPT KW_AS
    cbz  w0, 4f
    PCALL p_expect_ident
    mov  x22, x0
    b    .Lsc_push
4:  CURTOK x10
    ldr  w11, [x10, #TK_KIND]
    cmp  w11, #TK_IDENT
    b.ne .Lsc_push
    ldr  x22, [x10, #TK_STR]
    ADVANCE
.Lsc_push:
    VEC_PUSH 64
    str  x21, [x0, #SI_EXPR]
    str  x22, [x0, #SI_ALIAS]
    str  w23, [x0, #SI_KIND]
    str  x24, [x0, #SI_QUAL]
    ACCEPT TK_COMMA
    cbnz w0, .Lsc_item
    ldp  x9, x10, [sp, #64]
    str  x9, [x20, #Q_ITEMS]
    str  x10, [x20, #Q_NITEMS]

    ACCEPT KW_FROM
    cbz  w0, 5f
    PCALL p_from_item
    str  x0, [x20, #Q_FROM]
    mov  w9, #1
    str  w9, [x20, #Q_HASFROM]
5:  ACCEPT KW_WHERE
    cbz  w0, 6f
    PCALL p_expr
    str  x0, [x20, #Q_WHERE]
6:  CURKIND w10
    cmp  w10, #KW_GROUP
    b.ne 8f
    ADVANCE
    EXPECT KW_BY
    VEC_INIT 64, 8
7:  PCALL p_expr
    mov  x21, x0
    VEC_PUSH 64
    str  x21, [x0]
    ACCEPT TK_COMMA
    cbnz w0, 7b
    ldp  x9, x10, [sp, #64]
    str  x9, [x20, #Q_GROUP]
    str  x10, [x20, #Q_NGROUP]
8:  ACCEPT KW_HAVING
    cbz  w0, 9f
    PCALL p_expr
    str  x0, [x20, #Q_HAVING]
9:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #96
    ret
ENDF p_select_core

// -----------------------------------------------------------------------------
// p_from_item(x0 P) -> x0 FromItem*
//   from_item   = table_ref { join_clause }       (left-deep FRK_JOIN tree)
//   join_clause = [INNER] JOIN table_ref ON expr
//               | LEFT [OUTER] JOIN table_ref ON expr
//               | CROSS JOIN table_ref  |  "," table_ref
// FULL / RIGHT joins raise UNSUPPORTED. A join node's position is that of its
// join keyword (or comma).
// Registers: x19 P, x20 left tree, x21 right table_ref, w22 JT_*, x23 ON expr,
//            x24 join token.
// -----------------------------------------------------------------------------
LFUNC p_from_item
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    DEPTH_ENTER
    PCALL p_table_ref
    mov  x20, x0
.Lfi_loop:
    CURTOK x24
    ldr  w10, [x24, #TK_KIND]
    mov  x23, #0
    cmp  w10, #TK_COMMA
    b.eq .Lfi_comma
    cmp  w10, #KW_CROSS
    b.eq .Lfi_cross
    cmp  w10, #KW_JOIN
    b.eq .Lfi_join
    cmp  w10, #KW_INNER
    b.eq .Lfi_inner
    cmp  w10, #KW_LEFT
    b.eq .Lfi_left
    cmp  w10, #KW_FULL
    b.eq .Lfi_unsupported
    cmp  w10, #KW_RIGHT
    b.eq .Lfi_unsupported
    DEPTH_LEAVE
    mov  x0, x20
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
.Lfi_comma:
    ADVANCE
    mov  w22, #JT_CROSS
    b    .Lfi_right
.Lfi_cross:
    ADVANCE
    EXPECT KW_JOIN
    mov  w22, #JT_CROSS
    b    .Lfi_right
.Lfi_inner:
    ADVANCE
    EXPECT KW_JOIN
    mov  w22, #JT_INNER
    b    .Lfi_right_on
.Lfi_join:
    ADVANCE
    mov  w22, #JT_INNER
    b    .Lfi_right_on
.Lfi_left:
    ADVANCE
    ACCEPT KW_OUTER
    EXPECT KW_JOIN
    mov  w22, #JT_LEFT
.Lfi_right_on:
    PCALL p_table_ref
    mov  x21, x0
    EXPECT KW_ON
    PCALL p_expr
    mov  x23, x0
    b    .Lfi_make
.Lfi_right:
    PCALL p_table_ref
    mov  x21, x0
.Lfi_make:
    mov  w0, #FRK_JOIN
    mov  x1, x24
    bl   fr_new
    str  w22, [x0, #FR_JOIN]
    str  x20, [x0, #FR_LEFT]
    str  x21, [x0, #FR_RIGHT]
    str  x23, [x0, #FR_ON]
    mov  x20, x0
    b    .Lfi_loop
.Lfi_unsupported:
    mov  x0, x19
    bl   p_error                    // reports UNSUPPORTED for FULL/RIGHT
ENDF p_from_item

// -----------------------------------------------------------------------------
// p_table_ref(x0 P) -> x0 FromItem*
//   table_ref = ident [ [AS] ident ]
//             | "(" query ")" [AS] ident         (derived table, alias required)
//             | "(" from_item ")"
// Registers: x19 P, x20 first token, x21 result item.
// -----------------------------------------------------------------------------
LFUNC p_table_ref
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    CURTOK x20
    ldr  w10, [x20, #TK_KIND]
    cmp  w10, #TK_IDENT
    b.eq .Ltr_table
    cmp  w10, #TK_LPAREN
    b.ne .Ltr_error
    ldr  w11, [x20, #(TK_SIZE + TK_KIND)]
    cmp  w11, #KW_SELECT
    b.eq .Ltr_derived
    cmp  w11, #KW_WITH
    b.eq .Ltr_derived
    ADVANCE                         // "(" from_item ")"
    PCALL p_from_item
    mov  x21, x0
    EXPECT TK_RPAREN
    b    .Ltr_ret
.Ltr_derived:
    ADVANCE
    mov  w0, #FRK_SUBQUERY
    mov  x1, x20
    bl   fr_new
    mov  x21, x0
    PCALL p_query
    str  x0, [x21, #FR_LEFT]
    EXPECT TK_RPAREN
    ACCEPT KW_AS
    PCALL p_expect_ident
    str  x0, [x21, #FR_ALIAS]
    b    .Ltr_ret
.Ltr_table:
    mov  w0, #FRK_TABLE
    mov  x1, x20
    bl   fr_new
    mov  x21, x0
    ldr  x9, [x20, #TK_STR]
    str  x9, [x21, #FR_NAME]
    ADVANCE
    ACCEPT KW_AS
    cbz  w0, 1f
    PCALL p_expect_ident
    str  x0, [x21, #FR_ALIAS]
    b    .Ltr_ret
1:  CURTOK x10                      // bare alias
    ldr  w11, [x10, #TK_KIND]
    cmp  w11, #TK_IDENT
    b.ne .Ltr_ret
    ldr  x9, [x10, #TK_STR]
    str  x9, [x21, #FR_ALIAS]
    ADVANCE
.Ltr_ret:
    mov  x0, x21
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
.Ltr_error:
    mov  x0, x19
    bl   p_error
ENDF p_table_ref

// =============================================================================
// Expressions
// =============================================================================

// -----------------------------------------------------------------------------
// p_expr(x0 P) -> x0 Node*      expr = or_expr  (with nesting-depth guard)
// Registers: x19 P, x20 result.
// -----------------------------------------------------------------------------
LFUNC p_expr
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    DEPTH_ENTER
    PCALL p_or
    mov  x20, x0
    DEPTH_LEAVE
    mov  x0, x20
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF p_expr

// The left-associative binary levels: tail calls into p_binloop with the
// next-higher level as operand parser and the level's operator table.
LFUNC p_or                          // or_expr = and_expr { OR and_expr }
    adr  x1, p_and
    ADR_L x2, optab_or
    b    p_binloop
ENDF p_or

LFUNC p_and                         // and_expr = not_expr { AND not_expr }
    adr  x1, p_not
    ADR_L x2, optab_and
    b    p_binloop
ENDF p_and

LFUNC p_concat                      // concat_expr = additive { || additive }
    adr  x1, p_add
    ADR_L x2, optab_concat
    b    p_binloop
ENDF p_concat

LFUNC p_add                         // additive = mult { (+|-) mult }
    adr  x1, p_mul
    ADR_L x2, optab_add
    b    p_binloop
ENDF p_add

LFUNC p_mul                         // multiplicative = unary { (*|/|%) unary }
    adr  x1, p_unary
    ADR_L x2, optab_mul
    b    p_binloop
ENDF p_mul

// -----------------------------------------------------------------------------
// p_binloop(x0 P, x1 operand parser, x2 operator table) -> x0 Node*
// Parses  operand { op operand }  building left-associative NK_BINARY nodes
// positioned at the first token of the whole chain.
// Registers: x19 P, x20 operand parser, x21 op table, x22 left tree,
//            x23 start token, w24 operator code.
// -----------------------------------------------------------------------------
LFUNC p_binloop
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    CURTOK x23
    mov  x0, x19
    blr  x20
    mov  x22, x0
1:  CURKIND w10
    mov  x11, x21
2:  ldrb w12, [x11]                 // scan the table for the token kind
    cbz  w12, 9f
    cmp  w12, w10
    b.eq 3f
    add  x11, x11, #2
    b    2b
3:  ldrb w24, [x11, #1]
    ADVANCE
    mov  x0, x19
    blr  x20
    mov  x2, x0
    mov  w0, w24
    mov  x1, x22
    mov  x3, x23
    bl   node_binary
    mov  x22, x0
    b    1b
9:  mov  x0, x22
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF p_binloop

// -----------------------------------------------------------------------------
// p_not(x0 P) -> x0 Node*       not_expr = NOT not_expr | predicate
// Registers: x19 P, x20 NOT token, x21 operand.
// -----------------------------------------------------------------------------
LFUNC p_not
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    CURTOK x20
    ldr  w10, [x20, #TK_KIND]
    cmp  w10, #KW_NOT
    b.eq 1f
    mov  x0, x19                    // no NOT: tail call p_pred
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    b    p_pred
1:  ADVANCE
    DEPTH_ENTER
    PCALL p_not
    mov  x21, x0
    DEPTH_LEAVE
    mov  w0, #NK_UNARY
    mov  x1, x20
    bl   node_new
    mov  w9, #OP_NOT
    str  w9, [x0, #N_OP]
    str  x21, [x0, #N_A]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF p_not

// -----------------------------------------------------------------------------
// p_pred(x0 P) -> x0 Node*
//   predicate = concat_expr [ comp_op concat_expr
//                           | IS [NOT] NULL
//                           | [NOT] BETWEEN concat_expr AND concat_expr
//                           | [NOT] IN "(" ( query | expr {"," expr} ) ")"
//                           | [NOT] LIKE concat_expr ]
// At most one predicate operator (non-associative): whatever follows is left
// for the caller, which reports it as a syntax error.
// Registers: x19 P, x20 start token, x21 left operand, w22 negation flag,
//            x23 result node, x24 scratch (operator / element).
// Stack: IN-list vector at [sp,#64].
// -----------------------------------------------------------------------------
LFUNC p_pred
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    CURTOK x20
    PCALL p_concat
    mov  x21, x0
    mov  x23, x0                    // default result: the operand itself
    CURTOK x10
    ldr  w11, [x10, #TK_KIND]
    sub  w12, w11, #TK_EQ           // comparison operators TK_EQ..TK_GE
    cmp  w12, #(TK_GE - TK_EQ)
    b.ls .Lpr_cmp
    cmp  w11, #KW_IS
    b.eq .Lpr_is
    mov  w22, #0
    cmp  w11, #KW_NOT
    b.ne .Lpr_kw
    ldr  w11, [x10, #(TK_SIZE + TK_KIND)]   // NOT must precede BETWEEN/IN/LIKE
    cmp  w11, #KW_BETWEEN
    b.eq 1f
    cmp  w11, #KW_IN
    b.eq 1f
    cmp  w11, #KW_LIKE
    b.ne .Lpr_ret
1:  ADVANCE
    mov  w22, #1
.Lpr_kw:                            // w11 = kind of the predicate keyword
    cmp  w11, #KW_BETWEEN
    b.eq .Lpr_between
    cmp  w11, #KW_IN
    b.eq .Lpr_in
    cmp  w11, #KW_LIKE
    b.eq .Lpr_like
    b    .Lpr_ret

.Lpr_cmp:                           // token kind == OP_* code
    mov  w24, w11
    ADVANCE
    PCALL p_concat
    mov  x2, x0
    mov  w0, w24
    mov  x1, x21
    mov  x3, x20
    bl   node_binary
    mov  x23, x0
    b    .Lpr_ret

.Lpr_is:                            // IS [NOT] NULL
    ADVANCE
    ACCEPT KW_NOT
    mov  w22, w0
    EXPECT KW_NULL
    mov  w0, #NK_ISNULL
    mov  x1, x20
    bl   node_new
    str  x21, [x0, #N_A]
    str  w22, [x0, #N_OP]
    mov  x23, x0
    b    .Lpr_ret

.Lpr_between:                       // BETWEEN low AND high
    ADVANCE
    mov  w0, #NK_BETWEEN
    mov  x1, x20
    bl   node_new
    mov  x23, x0
    str  x21, [x23, #N_A]
    str  w22, [x23, #N_OP]
    PCALL p_concat
    str  x0, [x23, #N_B]
    EXPECT KW_AND
    PCALL p_concat
    str  x0, [x23, #N_C]
    b    .Lpr_ret

.Lpr_like:                          // LIKE pattern
    ADVANCE
    mov  w0, #NK_LIKE
    mov  x1, x20
    bl   node_new
    mov  x23, x0
    str  x21, [x23, #N_A]
    str  w22, [x23, #N_OP]
    PCALL p_concat
    str  x0, [x23, #N_B]
    b    .Lpr_ret

.Lpr_in:                            // IN ( query )  |  IN ( expr, ... )
    ADVANCE
    EXPECT TK_LPAREN
    CURKIND w10
    cmp  w10, #KW_SELECT
    b.eq .Lpr_insub
    cmp  w10, #KW_WITH
    b.eq .Lpr_insub
    mov  w0, #NK_IN
    mov  x1, x20
    bl   node_new
    mov  x23, x0
    str  x21, [x23, #N_A]
    str  w22, [x23, #N_OP]
    VEC_INIT 64, 8
2:  PCALL p_expr
    mov  x24, x0
    VEC_PUSH 64
    str  x24, [x0]
    ACCEPT TK_COMMA
    cbnz w0, 2b
    EXPECT TK_RPAREN
    ldp  x9, x10, [sp, #64]
    str  x9, [x23, #N_C]
    str  x10, [x23, #N_VAL]
    b    .Lpr_ret
.Lpr_insub:
    mov  w0, #NK_INSUB
    mov  x1, x20
    bl   node_new
    mov  x23, x0
    str  x21, [x23, #N_A]
    str  w22, [x23, #N_OP]
    PCALL p_query
    str  x0, [x23, #N_C]
    EXPECT TK_RPAREN

.Lpr_ret:
    mov  x0, x23
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #96
    ret
ENDF p_pred

// -----------------------------------------------------------------------------
// p_unary(x0 P) -> x0 Node*      unary = ("-" | "+") unary | primary
// Unary minus applied directly to the integer literal 9223372036854775808 is
// folded into the INT64_MIN literal (types.md §3).
// Registers: x19 P, x20 operator token, w21 OP_NEG/OP_POS, x22 operand.
// -----------------------------------------------------------------------------
LFUNC p_unary
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    CURTOK x20
    ldr  w10, [x20, #TK_KIND]
    cmp  w10, #TK_MINUS
    b.eq .Lun_minus
    cmp  w10, #TK_PLUS
    b.eq .Lun_plus
    mov  x0, x19                    // no sign: tail call p_primary
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    b    p_primary

.Lun_minus:
    ldr  w11, [x20, #(TK_SIZE + TK_KIND)]
    cmp  w11, #TK_NUMBER
    b.ne .Lun_neg
    ldr  w11, [x20, #(TK_SIZE + TK_AUX)]
    cbnz w11, .Lun_neg              // only digits-only literals fold
    ldr  x0, [x20, #(TK_SIZE + TK_PTR)]
    ldr  x1, [x20, #(TK_SIZE + TK_LEN)]
    bl   parse_uint_digits
    cbnz w1, .Lun_neg
    mov  x9, #INT64_MIN_BITS
    cmp  x0, x9
    b.ne .Lun_neg
    add  x10, x20, #(2 * TK_SIZE)   // consume "-" and the literal
    str  x10, [x19, #PS_CUR]
    mov  w0, #NK_LIT
    mov  x1, x20
    bl   node_new
    mov  w9, #T_INT
    str  w9, [x0, #N_TYPE]
    mov  x9, #INT64_MIN_BITS
    str  x9, [x0, #N_VAL]
    b    .Lun_ret
.Lun_neg:
    mov  w21, #OP_NEG
    b    1f
.Lun_plus:
    mov  w21, #OP_POS
1:  ADVANCE
    DEPTH_ENTER
    PCALL p_unary
    mov  x22, x0
    DEPTH_LEAVE
    mov  w0, #NK_UNARY
    mov  x1, x20
    bl   node_new
    str  w21, [x0, #N_OP]
    str  x22, [x0, #N_A]
.Lun_ret:
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF p_unary

// -----------------------------------------------------------------------------
// p_primary(x0 P) -> x0 Node*
//   primary = literal | column_ref | function_call | CAST "(" expr AS type ")"
//           | case_expr | EXISTS "(" query ")" | "(" query ")" | "(" expr ")"
//   literal = number | string | TRUE | FALSE | NULL | DATE string
//           | TIMESTAMP string
//   column_ref = ident [ "." ident ]
// Registers: x19 P, x20 first token, x21 node / operand, w22 type,
//            x23 string token.
// -----------------------------------------------------------------------------
LFUNC p_primary
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    CURTOK x20
    ldr  w10, [x20, #TK_KIND]
    cmp  w10, #TK_NUMBER
    b.eq .Lpp_number
    cmp  w10, #TK_STRING
    b.eq .Lpp_string
    cmp  w10, #TK_IDENT
    b.eq .Lpp_ident
    cmp  w10, #TK_LPAREN
    b.eq .Lpp_paren
    cmp  w10, #KW_TRUE
    b.eq .Lpp_bool
    cmp  w10, #KW_FALSE
    b.eq .Lpp_bool
    cmp  w10, #KW_NULL
    b.eq .Lpp_null
    cmp  w10, #KW_DATE
    b.eq .Lpp_date
    cmp  w10, #KW_TIMESTAMP
    b.eq .Lpp_ts
    cmp  w10, #KW_CAST
    b.eq .Lpp_cast
    cmp  w10, #KW_EXISTS
    b.eq .Lpp_exists
    cmp  w10, #KW_CASE
    b.ne .Lpp_error
    mov  x0, x19                    // CASE: tail call p_case
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    b    p_case

.Lpp_number:
    ADVANCE
    mov  x0, x20
    bl   lit_number
    b    .Lpp_ret

.Lpp_string:                        // 'text' -> T_STR, payload Str*
    ADVANCE
    mov  w0, #NK_LIT
    mov  x1, x20
    bl   node_new
    mov  w9, #T_STR
    str  w9, [x0, #N_TYPE]
    ldr  x9, [x20, #TK_STR]
    str  x9, [x0, #N_VAL]
    b    .Lpp_ret

.Lpp_bool:                          // TRUE / FALSE -> T_BOOL 1/0
    ADVANCE
    mov  w0, #NK_LIT
    mov  x1, x20
    bl   node_new
    mov  w9, #T_BOOL
    str  w9, [x0, #N_TYPE]
    ldr  w10, [x20, #TK_KIND]
    cmp  w10, #KW_TRUE
    cset x9, eq
    str  x9, [x0, #N_VAL]
    b    .Lpp_ret

.Lpp_null:                          // NULL -> T_NULL, NF_NULL
    ADVANCE
    mov  w0, #NK_LIT
    mov  x1, x20
    bl   node_new
    mov  w9, #NF_NULL
    str  w9, [x0, #N_FLAGS]
    b    .Lpp_ret

.Lpp_date:
    mov  w22, #T_DATE
    b    1f
.Lpp_ts:
    mov  w22, #T_TS
1:  ADVANCE                         // DATE 'x' / TIMESTAMP 'x'
    CURTOK x23
    ldr  w10, [x23, #TK_KIND]
    cmp  w10, #TK_STRING
    b.ne .Lpp_error
    ADVANCE
    ldr  x9, [x23, #TK_STR]
    add  x0, x9, #STR_DATA
    ldr  x1, [x9, #STR_LEN]
    cmp  w22, #T_DATE
    b.ne 2f
    bl   parse_date
    b    3f
2:  mov  w2, #0                     // no bare dates in TIMESTAMP literals
    bl   parse_timestamp
3:  cbnz w1, .Lpp_bad_datetime
    mov  x21, x0
    mov  w0, #NK_LIT
    mov  x1, x20
    bl   node_new
    str  w22, [x0, #N_TYPE]
    str  x21, [x0, #N_VAL]
    b    .Lpp_ret
.Lpp_bad_datetime:
    mov  w0, #ERR_CONVERSION
    ADR_L x1, msg_bad_date
    cmp  w22, #T_DATE
    b.eq 4f
    ADR_L x1, msg_bad_ts
4:  ldr  x9, [x23, #TK_STR]
    add  x2, x9, #STR_DATA
    ldr  x3, [x9, #STR_LEN]
    ldr  w4, [x23, #TK_LINE]
    ldr  w5, [x23, #TK_COL]
    bl   lex_raise_text

.Lpp_cast:                          // CAST ( expr AS type_name )
    ADVANCE
    EXPECT TK_LPAREN
    PCALL p_expr
    mov  x21, x0
    EXPECT KW_AS
    PCALL p_type_name
    mov  w22, w0
    EXPECT TK_RPAREN
    mov  w0, #NK_CAST
    mov  x1, x20
    bl   node_new
    str  x21, [x0, #N_A]
    str  w22, [x0, #N_TYPE]
    mov  w9, w22                    // zero-extended into N_VAL
    str  x9, [x0, #N_VAL]
    b    .Lpp_ret

.Lpp_exists:                        // EXISTS ( query )
    ADVANCE
    EXPECT TK_LPAREN
    PCALL p_query
    mov  x21, x0
    EXPECT TK_RPAREN
    mov  w0, #NK_EXISTS
    mov  x1, x20
    bl   node_new
    str  x21, [x0, #N_C]
    b    .Lpp_ret

.Lpp_paren:                         // ( query ) iff next is SELECT/WITH
    ldr  w11, [x20, #(TK_SIZE + TK_KIND)]
    cmp  w11, #KW_SELECT
    b.eq .Lpp_subq
    cmp  w11, #KW_WITH
    b.eq .Lpp_subq
    ADVANCE                         // ( expr )
    PCALL p_expr
    mov  x21, x0
    EXPECT TK_RPAREN
    ldr  w9, [x21, #N_FLAGS]
    orr  w9, w9, #NF_PAREN
    str  w9, [x21, #N_FLAGS]
    mov  x0, x21
    b    .Lpp_ret
.Lpp_subq:
    ADVANCE
    PCALL p_query
    mov  x21, x0
    EXPECT TK_RPAREN
    mov  w0, #NK_SUBQ
    mov  x1, x20
    bl   node_new
    str  x21, [x0, #N_C]
    b    .Lpp_ret

.Lpp_ident:                         // function call / [qualifier.]column
    ldr  w11, [x20, #(TK_SIZE + TK_KIND)]
    cmp  w11, #TK_LPAREN
    b.ne 5f
    mov  x0, x19                    // ident ( ... ): tail call p_funcall
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    b    p_funcall
5:  cmp  w11, #TK_DOT
    b.eq 6f
    ADVANCE                         // plain column
    mov  w0, #NK_COL
    mov  x1, x20
    bl   node_new
    ldr  x9, [x20, #TK_STR]
    str  x9, [x0, #N_NAME]
    b    .Lpp_ret
6:  add  x23, x20, #(2 * TK_SIZE)   // qualifier . column
    str  x23, [x19, #PS_CUR]
    ldr  w10, [x23, #TK_KIND]
    cmp  w10, #TK_IDENT
    b.ne .Lpp_error
    ADVANCE
    mov  w0, #NK_COL
    mov  x1, x20
    bl   node_new
    ldr  x9, [x23, #TK_STR]
    str  x9, [x0, #N_NAME]
    ldr  x9, [x20, #TK_STR]
    str  x9, [x0, #N_C]

.Lpp_ret:
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
.Lpp_error:
    mov  x0, x19
    bl   p_error
ENDF p_primary

// -----------------------------------------------------------------------------
// p_case(x0 P) -> x0 Node*
//   case_expr = CASE [expr] (WHEN expr THEN expr)+ [ELSE expr] END
// NK_CASE: N_A operand or 0, N_C Node** [w1,t1,w2,t2,...], N_VAL pair count,
//          N_B ELSE expression or 0.
// Registers: x19 P, x20 CASE token, x21 operand, x22 ELSE expr, x23 WHEN expr,
//            x24 THEN expr.  Stack: vector at [sp,#64].
// -----------------------------------------------------------------------------
LFUNC p_case
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    CURTOK x20
    ADVANCE
    mov  x21, #0
    mov  x22, #0
    CURKIND w10
    cmp  w10, #KW_WHEN
    b.eq 1f
    PCALL p_expr                    // simple CASE operand
    mov  x21, x0
1:  VEC_INIT 64, 8
    CURKIND w10                     // at least one WHEN
    cmp  w10, #KW_WHEN
    b.ne .Lcase_error
2:  ACCEPT KW_WHEN
    cbz  w0, 3f
    PCALL p_expr
    mov  x23, x0
    EXPECT KW_THEN
    PCALL p_expr
    mov  x24, x0
    VEC_PUSH 64
    str  x23, [x0]
    VEC_PUSH 64
    str  x24, [x0]
    b    2b
3:  ACCEPT KW_ELSE
    cbz  w0, 4f
    PCALL p_expr
    mov  x22, x0
4:  EXPECT KW_END
    mov  w0, #NK_CASE
    mov  x1, x20
    bl   node_new
    str  x21, [x0, #N_A]
    str  x22, [x0, #N_B]
    ldp  x9, x10, [sp, #64]
    str  x9, [x0, #N_C]
    lsr  x10, x10, #1
    str  x10, [x0, #N_VAL]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #96
    ret
.Lcase_error:
    mov  x0, x19
    bl   p_error
ENDF p_case

// -----------------------------------------------------------------------------
// p_funcall(x0 P) -> x0 Node*     (current token: ident, next: "(")
//   function_call = ident "(" [ "*" | [DISTINCT] expr {"," expr} ] ")"
// NK_FUNC: N_NAME, N_C Node** args, N_VAL argc, NF_STAR / NF_DISTINCT.
// Registers: x19 P, x20 name token, x21 node, x22 argument.
// Stack: argument vector at [sp,#48].
// -----------------------------------------------------------------------------
LFUNC p_funcall
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    CURTOK x20
    add  x10, x20, #(2 * TK_SIZE)   // consume name and "("
    str  x10, [x19, #PS_CUR]
    mov  w0, #NK_FUNC
    mov  x1, x20
    bl   node_new
    mov  x21, x0
    ldr  x9, [x20, #TK_STR]
    str  x9, [x21, #N_NAME]
    CURKIND w10
    cmp  w10, #TK_STAR              // f(*)
    b.ne 1f
    ADVANCE
    mov  w9, #NF_STAR
    str  w9, [x21, #N_FLAGS]
    EXPECT TK_RPAREN
    b    9f
1:  cmp  w10, #TK_RPAREN            // f()
    b.ne 2f
    ADVANCE
    b    9f
2:  ACCEPT KW_DISTINCT
    cbz  w0, 3f
    mov  w9, #NF_DISTINCT
    str  w9, [x21, #N_FLAGS]
3:  VEC_INIT 48, 8
4:  PCALL p_expr
    mov  x22, x0
    VEC_PUSH 48
    str  x22, [x0]
    ACCEPT TK_COMMA
    cbnz w0, 4b
    EXPECT TK_RPAREN
    ldp  x9, x10, [sp, #48]
    str  x9, [x21, #N_C]
    str  x10, [x21, #N_VAL]
9:  mov  x0, x21
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #80
    ret
ENDF p_funcall

// -----------------------------------------------------------------------------
// p_type_name(x0 P) -> w0 type
//   type_name = (ident | DATE | TIMESTAMP) [ "(" number [ "," number ] ")" ]
// Resolved with type_from_name; unknown name / invalid parameters raise
// SEMANTIC_ERROR at the type name. Parameters are encoded in the type value.
// Registers: x19 P, x20 name token, x21 name ptr, x22 name len, x23 nparams,
//            x24 first parameter, x25 second parameter.
// -----------------------------------------------------------------------------
LFUNC p_type_name
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    mov  x19, x0
    CURTOK x20
    ldr  w10, [x20, #TK_KIND]
    cmp  w10, #TK_IDENT
    b.eq 1f
    cmp  w10, #KW_DATE
    b.eq 2f
    cmp  w10, #KW_TIMESTAMP
    b.eq 2f
    mov  x0, x19
    bl   p_error
1:  ldr  x9, [x20, #TK_STR]         // identifier text
    add  x21, x9, #STR_DATA
    ldr  x22, [x9, #STR_LEN]
    b    3f
2:  ldr  x21, [x20, #TK_PTR]        // keyword spelling
    ldr  x22, [x20, #TK_LEN]
3:  ADVANCE
    mov  x23, #0
    mov  x24, #0
    mov  x25, #0
    ACCEPT TK_LPAREN
    cbz  w0, 4f
    PCALL p_type_param
    mov  x24, x0
    mov  x23, #1
    ACCEPT TK_COMMA
    cbz  w0, 5f
    PCALL p_type_param
    mov  x25, x0
    mov  x23, #2
5:  EXPECT TK_RPAREN
4:  mov  x0, x21
    mov  x1, x22
    mov  w2, w23
    mov  x3, x24
    mov  x4, x25
    bl   type_from_name
    cmn  w0, #1
    b.eq 6f
    cmn  w0, #2
    b.eq 7f
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x29, x30, [sp], #80
    ret
6:  ADR_L x1, msg_bad_type
    b    8f
7:  ADR_L x1, msg_bad_tparams
8:  mov  w0, #ERR_SEMANTIC
    mov  x2, x21
    mov  x3, x22
    ldr  w4, [x20, #TK_LINE]
    ldr  w5, [x20, #TK_COL]
    bl   lex_raise_text
ENDF p_type_name

// -----------------------------------------------------------------------------
// p_type_param(x0 P) -> x0 value     digits-only number, saturated at 2^32-1
// Registers: x19 P, x20 token.
// -----------------------------------------------------------------------------
LFUNC p_type_param
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    CURTOK x20
    ldr  w10, [x20, #TK_KIND]
    cmp  w10, #TK_NUMBER
    b.ne 9f
    ldr  w10, [x20, #TK_AUX]
    cbnz w10, 9f
    ldr  x0, [x20, #TK_PTR]
    ldr  x1, [x20, #TK_LEN]
    bl   parse_uint_digits
    mov  x9, #0xFFFFFFFF
    cbnz w1, 1f                     // overflow or > 2^32-1 -> saturate
    cmp  x0, x9
    b.ls 2f
1:  mov  x0, x9
2:  ADVANCE
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
9:  mov  x0, x19
    bl   p_error
ENDF p_type_param

// =============================================================================
// Literals
// =============================================================================

// -----------------------------------------------------------------------------
// lit_number(x0 Token*) -> x0 Node*   (NK_LIT for a TK_NUMBER token)
//   digits only            -> T_INT (> INT64_MAX: NUMERIC_OVERFLOW)
//   digits with '.'        -> DECIMAL(p,s): s = fraction digits,
//                             p = max(significant integer digits + s, 1),
//                             unscaled = all digits; p > 18 -> FLOAT64
//   with exponent          -> T_FLOAT via strtod (non-finite: NUMERIC_OVERFLOW)
// Registers: x19 token, x20 node, x21 text ptr, x22 text len,
//            x23 significant integer digits, x24 fraction digits.
// -----------------------------------------------------------------------------
LFUNC lit_number
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  w0, #NK_LIT
    mov  x1, x19
    bl   node_new
    mov  x20, x0
    ldr  x21, [x19, #TK_PTR]
    ldr  x22, [x19, #TK_LEN]
    ldr  w9, [x19, #TK_AUX]
    tbnz w9, #1, .Lln_float         // TKN_EXP
    tbnz w9, #0, .Lln_decimal       // TKN_DOT

    mov  x0, x21                    // integer
    mov  x1, x22
    bl   parse_uint_digits
    cbnz w1, .Lln_int_overflow
    tbnz x0, #63, .Lln_int_overflow
    mov  w9, #T_INT
    str  w9, [x20, #N_TYPE]
    str  x0, [x20, #N_VAL]
    b    .Lln_ret

.Lln_decimal:
    // pass 1: count significant integer digits (x23) and fraction digits (x24)
    mov  x23, #0
    mov  x10, #0                    // index
    mov  w12, #0                    // seen a non-zero integer digit
1:  ldrb w11, [x21, x10]
    cmp  w11, #'.'
    b.eq 3f
    cmp  w11, #'0'
    cset w13, ne
    orr  w12, w12, w13
    cbz  w12, 2f
    add  x23, x23, #1
2:  add  x10, x10, #1
    b    1b
3:  sub  x24, x22, x10
    sub  x24, x24, #1               // digits after the point
    add  x13, x23, x24              // p = max(int + frac, 1)
    cmp  x13, #1
    csinc x13, x13, xzr, hs
    cmp  x13, #18
    b.hi .Lln_float
    // pass 2: unscaled value = all digits (fits: at most 18 significant)
    mov  x0, #0
    mov  x10, #0
    mov  x14, #10
4:  cmp  x10, x22
    b.hs 5f
    ldrb w11, [x21, x10]
    add  x10, x10, #1
    cmp  w11, #'.'
    b.eq 4b
    sub  w11, w11, #'0'
    madd x0, x0, x14, x11
    b    4b
5:  str  x0, [x20, #N_VAL]
    mov  w9, #T_DEC                 // T_DEC | p << 8 | s << 16
    orr  w9, w9, w13, lsl #T_PREC_SHIFT
    orr  w9, w9, w24, lsl #T_SCALE_SHIFT
    str  w9, [x20, #N_TYPE]
    b    .Lln_ret

.Lln_float:
    mov  x0, x21                    // NUL-terminated copy for strtod
    mov  x1, x22
    bl   str_new
    add  x0, x0, #STR_DATA
    mov  x1, #0
    bl   strtod
    fmov x9, d0
    ubfx x10, x9, #52, #11          // exponent all ones: inf/nan
    cmp  x10, #0x7FF
    b.eq .Lln_num_overflow
    mov  w10, #T_FLOAT
    str  w10, [x20, #N_TYPE]
    str  x9, [x20, #N_VAL]

.Lln_ret:
    mov  x0, x20
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
.Lln_int_overflow:
    ADR_L x1, msg_int_range
    b    6f
.Lln_num_overflow:
    ADR_L x1, msg_num_range
6:  mov  w0, #ERR_NUMERIC_OVERFLOW
    mov  x2, x21
    mov  x3, x22
    ldr  w4, [x19, #TK_LINE]
    ldr  w5, [x19, #TK_COL]
    bl   lex_raise_text
ENDF lit_number

// -----------------------------------------------------------------------------
// parse_uint_digits(x0 ptr, x1 len) -> x0 value, w1 status (0 ok, 1 > 2^64-1)
// Leaf. The text consists of ASCII digits only (guaranteed by the lexer).
// Registers: x2 value, x3 constant 10, w4 digit, x5 high product.
// -----------------------------------------------------------------------------
LFUNC parse_uint_digits
    mov  x2, #0
    mov  x3, #10
1:  cbz  x1, 2f
    ldrb w4, [x0], #1
    sub  w4, w4, #'0'
    umulh x5, x2, x3
    cbnz x5, 3f
    mul  x2, x2, x3
    adds x2, x2, w4, uxtw
    b.cs 3f
    sub  x1, x1, #1
    b    1b
2:  mov  x0, x2
    mov  w1, #0
    ret
3:  mov  x0, #-1
    mov  w1, #1
    ret
ENDF parse_uint_digits

// =============================================================================
// Helpers
// =============================================================================

// p_accept(x0 P, w1 kind) -> w0 1 (consumed) / 0.  Leaf.
LFUNC p_accept
    ldr  x9, [x0, #PS_CUR]
    ldr  w10, [x9, #TK_KIND]
    cmp  w10, w1
    b.ne 1f
    add  x9, x9, #TK_SIZE
    str  x9, [x0, #PS_CUR]
    mov  w0, #1
    ret
1:  mov  w0, #0
    ret
ENDF p_accept

// p_expect(x0 P, w1 kind) -> x0 consumed Token*; raises PARSE_ERROR otherwise.
LFUNC p_expect
    ldr  x9, [x0, #PS_CUR]
    ldr  w10, [x9, #TK_KIND]
    cmp  w10, w1
    b.ne p_error                    // tail: x0 = P
    add  x10, x9, #TK_SIZE
    str  x10, [x0, #PS_CUR]
    mov  x0, x9
    ret
ENDF p_expect

// p_expect_ident(x0 P) -> x0 Str* of a (quoted or unquoted) identifier.
LFUNC p_expect_ident
    ldr  x9, [x0, #PS_CUR]
    ldr  w10, [x9, #TK_KIND]
    cmp  w10, #TK_IDENT
    b.ne p_error                    // tail: x0 = P
    add  x10, x9, #TK_SIZE
    str  x10, [x0, #PS_CUR]
    ldr  x0, [x9, #TK_STR]
    ret
ENDF p_expect_ident

// -----------------------------------------------------------------------------
// p_error(x0 P) — noreturn. Syntax error at the current token:
//   end of input        -> PARSE_ERROR "unexpected end of input"
//   FULL / RIGHT / UNION -> UNSUPPORTED (reserved for future use), except
//                          a misplaced UNION ALL -> PARSE_ERROR
//   otherwise           -> PARSE_ERROR "syntax error at or near '<token>'"
// Registers: x19 token.
// -----------------------------------------------------------------------------
LFUNC p_error
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    ldr  x19, [x0, #PS_CUR]
    ldr  w10, [x19, #TK_KIND]
    cbz  w10, 2f
    mov  w0, #ERR_PARSE
    ADR_L x1, msg_syntax
    cmp  w10, #KW_FULL
    b.eq 1f
    cmp  w10, #KW_RIGHT
    b.eq 1f
    cmp  w10, #KW_UNION
    b.ne 3f
    ldr  w9, [x19, #(TK_SIZE + TK_KIND)] // UNION ALL is valid syntax, only
    cmp  w9, #KW_ALL                // misplaced here (after ORDER BY /
    b.eq 3f                         // LIMIT, inside parentheses)
1:  mov  w0, #ERR_UNSUPPORTED
    ADR_L x1, msg_unsupported
3:  ldr  x2, [x19, #TK_PTR]
    ldr  x3, [x19, #TK_LEN]
    ldr  w4, [x19, #TK_LINE]
    ldr  w5, [x19, #TK_COL]
    bl   lex_raise_text
2:  mov  w0, #ERR_PARSE
    ADR_L x1, msg_eoi
    ldr  w2, [x19, #TK_LINE]
    ldr  w3, [x19, #TK_COL]
    bl   pq_raise_pos
    brk  #0                         // not reached
ENDF p_error

// p_too_deep(x0 P) — noreturn: RESOURCE_LIMIT at the current token.
LFUNC p_too_deep
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ldr  x9, [x0, #PS_CUR]
    mov  w0, #ERR_RESOURCE_LIMIT
    ADR_L x1, msg_too_deep
    ldr  w2, [x9, #TK_LINE]
    ldr  w3, [x9, #TK_COL]
    bl   pq_raise_pos
    brk  #0                         // not reached
ENDF p_too_deep

// -----------------------------------------------------------------------------
// node_new(w0 kind, x1 Token*) -> x0 zeroed Node with kind and the token's
// line/column.  Registers: w19 kind, x20 token.
// -----------------------------------------------------------------------------
LFUNC node_new
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  w19, w0
    mov  x20, x1
    mov  x0, #N_SIZE
    bl   arena_zalloc
    str  w19, [x0, #N_KIND]
    ldr  w9, [x20, #TK_LINE]
    str  w9, [x0, #N_LINE]
    ldr  w9, [x20, #TK_COL]
    str  w9, [x0, #N_COL]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF node_new

// -----------------------------------------------------------------------------
// node_binary(w0 op, x1 left, x2 right, x3 Token*) -> x0 NK_BINARY node
// Registers: w19 op, x20 left, x21 right.
// -----------------------------------------------------------------------------
LFUNC node_binary
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  w19, w0
    mov  x20, x1
    mov  x21, x2
    mov  w0, #NK_BINARY
    mov  x1, x3
    bl   node_new
    str  w19, [x0, #N_OP]
    str  x20, [x0, #N_A]
    str  x21, [x0, #N_B]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF node_binary

// -----------------------------------------------------------------------------
// fr_new(w0 FRK_* kind, x1 Token*) -> x0 zeroed FromItem with kind/position
// Registers: w19 kind, x20 token.
// -----------------------------------------------------------------------------
LFUNC fr_new
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  w19, w0
    mov  x20, x1
    mov  x0, #FR_SIZE
    bl   arena_zalloc
    str  w19, [x0, #FR_KIND]
    ldr  w9, [x20, #TK_LINE]
    str  w9, [x0, #FR_LINE]
    ldr  w9, [x20, #TK_COL]
    str  w9, [x0, #FR_COL]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF fr_new

// -----------------------------------------------------------------------------
// vec_push(x0 Vec*) -> x0 pointer to a new zeroed element (valid until the
// next push). Grows by doubling (minimum 4 elements) into a new arena block.
// Registers: x19 Vec*, x20 new data block.
// -----------------------------------------------------------------------------
LFUNC vec_push
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    ldr  x10, [x19, #V_COUNT]
    ldr  x11, [x19, #V_CAP]
    cmp  x10, x11
    b.lo 2f
    lsl  x11, x11, #1               // grow
    cmp  x11, #4
    mov  x9, #4
    csel x11, x11, x9, hs
    str  x11, [x19, #V_CAP]
    ldr  x12, [x19, #V_ESZ]
    mul  x0, x11, x12
    bl   arena_zalloc
    mov  x20, x0
    ldp  x1, x10, [x19, #V_DATA]
    ldr  x12, [x19, #V_ESZ]
    mul  x2, x10, x12
    cbz  x2, 1f
    bl   memcpy                     // x0 = new block
1:  str  x20, [x19, #V_DATA]
2:  ldp  x9, x10, [x19, #V_DATA]
    ldr  x12, [x19, #V_ESZ]
    madd x0, x10, x12, x9
    add  x10, x10, #1
    str  x10, [x19, #V_COUNT]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF vec_push

    NOTE_GNU_STACK
