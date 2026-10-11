// =============================================================================
// vexec.S — vectorized (batch) expression evaluation (Phase 5, mode
// "vectorized").
//
//   vb_new(x0 EvalCtx*, x1 tuple width) -> x0 VBatch*
//   veval(x0 Node*, x1 VBatch*, x2 u16* sel, x3 nsel, x4 Vec* out)
//       evaluates the expression for the selected batch positions:
//       out[p] / out.nulls[p] for every p in sel (other positions untouched)
//   vfilter(x0 Node* predicate, x1 VBatch*, x2 u16* out sel) -> x0 count
//       positions 0..VB_N-1 of the batch for which the predicate is TRUE
//   vpool_get(x0 VBatch*) -> x0 Vec*  /  vpool_put(x0 VBatch*)
//       scratch vectors (stack discipline)
//
// Kernels work column-at-a-time over the selection vector: column reads
// (PLAIN / DICT columns with null bitmaps), literals, constant
// subexpressions (evaluated once and broadcast), comparisons, + - * / % on
// INT64 / FLOAT64 and + - * on DECIMAL (same exact arithmetic routines as
// eval.S), unary - and NOT, IS [NOT] NULL, the implicit casts, and AND / OR.
// AND / OR evaluate their right operand only for the positions the left
// operand does not decide (the same short circuit as the row evaluator).
// Every other node (functions, CASE, LIKE, IN, subqueries, outer
// references, row-layout tables) falls back to the row evaluator for each
// selected position, so every expression is supported and both modes
// compute identical values and raise identical errors.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .section .rodata
    .p2align 4
    .global vsel_ident
vsel_ident:                             // identity selection 0..VBATCH-1
    .set vi, 0
    .rept VBATCH
    .hword vi
    .set vi, vi + 1
    .endr
// comparison truth masks, indexed by op - OP_EQ: bit (c + 1) set = TRUE for
// comparison result c in {-1, 0, 1}
cmp_masks:
    .byte 2, 5, 1, 3, 4, 6
    .text

// =============================================================================
// vb_new(x0 EvalCtx*, x1 width) -> x0 VBatch*
// =============================================================================
FUNC vb_new
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x0, #VB_SIZE
    bl   arena_zalloc
    str  x19, [x0, #VB_EC]
    str  x20, [x0, #VB_W]
    mov  x19, x0
    mov  x0, #(VPOOL_MAX * 8)
    bl   arena_zalloc
    str  x0, [x19, #VB_POOL]
    mov  x0, x19
    LEAVE 2
ENDF vb_new

// vpool_get(x0 VBatch*) -> x0 Vec*
//   x19 slot
FUNC vpool_get
    ldr  x9, [x0, #VB_POOLN]
    add  x10, x9, #1
    str  x10, [x0, #VB_POOLN]
    cmp  x9, #VPOOL_MAX
    b.hs 2f
    ldr  x10, [x0, #VB_POOL]
    add  x10, x10, x9, lsl #3
    ldr  x0, [x10]
    cbz  x0, 1f
    ret
1:  ENTER 1
    mov  x19, x10
    mov  x0, #VEC_SIZE
    bl   arena_alloc
    str  x0, [x19]
    LEAVE 1
2:  mov  x0, #VEC_SIZE                  // very deep expression: unpooled
    b    arena_alloc
ENDF vpool_get

// vpool_put(x0 VBatch*)   (leaf)
FUNC vpool_put
    ldr  x9, [x0, #VB_POOLN]
    sub  x9, x9, #1
    str  x9, [x0, #VB_POOLN]
    ret
ENDF vpool_put

// =============================================================================
// is_pure_const(x0 Node*) -> w0 1 if the tree consists only of literals,
// casts, unary and binary operators (constant, no side effects)
//   x19 node
// =============================================================================
LFUNC is_pure_const
    ENTER 1
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq 1f
    cmp  w9, #NK_CAST
    b.eq 2f
    cmp  w9, #NK_UNARY
    b.eq 2f
    cmp  w9, #NK_BINARY
    b.ne 3f
    ldr  x0, [x19, #N_B]
    bl   is_pure_const
    cbz  w0, 4f
2:  ldr  x0, [x19, #N_A]
    bl   is_pure_const
    LEAVE 1
1:  mov  w0, #1
    LEAVE 1
3:  mov  w0, #0
4:  LEAVE 1
ENDF is_pure_const

// =============================================================================
// veval(x0 Node*, x1 VBatch*, x2 u16* sel, x3 nsel, x4 Vec* out)
//   x19 node, x20 vb, x21 sel, x22 nsel, x23 out, x24 op / mask / scratch,
//   x25 index, x26 vector a, x27 vector b, x28 scratch
// Stack: [sp] u32 AND flag / scratch
// =============================================================================
FUNC veval
    ENTER 5
    sub  sp, sp, #16
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x23, x4
    cbz  x22, .Lve_ret
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_COL
    b.eq .Lve_col
    cmp  w9, #NK_LIT
    b.eq .Lve_lit
    ldr  w10, [x19, #N_FLAGS]
    tbz  w10, #3, 1f                    // NF_CONST
    mov  x0, x19
    bl   is_pure_const
    cbnz w0, .Lve_const
    ldr  w9, [x19, #N_KIND]
1:  cmp  w9, #NK_BINARY
    b.eq .Lve_binary
    cmp  w9, #NK_UNARY
    b.eq .Lve_unary
    cmp  w9, #NK_ISNULL
    b.eq .Lve_isnull
    cmp  w9, #NK_CAST
    b.eq .Lve_cast
    // ---- fallback: the row evaluator for every selected position ------------
.Lve_fallback:
    ldr  x24, [x20, #VB_EC]
    mov  x25, #0
1:  cmp  x25, x22
    b.hs .Lve_ret
    ldrh w26, [x21, x25, lsl #1]
    ldr  x9, [x20, #VB_TUP]
    ldr  x10, [x20, #VB_W]
    mul  x10, x10, x26
    add  x9, x9, x10, lsl #2
    str  x9, [x24, #EC_TUPLE]
    mov  x0, x19
    mov  x1, x24
    bl   eval
    str  x0, [x23, x26, lsl #3]
    add  x9, x23, #VEC_NULLS
    strb w1, [x9, x26]
    add  x25, x25, #1
    b    1b
.Lve_ret:
    add  sp, sp, #16
    LEAVE 5

    // ---- constants -------------------------------------------------------------
.Lve_lit:
    ldr  w9, [x19, #N_FLAGS]
    and  w1, w9, #NF_NULL
    ldrb w10, [x19, #N_TYPE]
    cmp  w10, #0
    csinc w1, w1, wzr, ne               // null type => NULL
    ldr  x0, [x19, #N_VAL]
    b    .Lve_fill
.Lve_const:                             // evaluate once, broadcast
    ldr  x24, [x20, #VB_EC]
    ldrh w9, [x21]
    ldr  x10, [x20, #VB_TUP]
    ldr  x11, [x20, #VB_W]
    mul  x11, x11, x9
    add  x10, x10, x11, lsl #2
    str  x10, [x24, #EC_TUPLE]
    mov  x0, x19
    mov  x1, x24
    bl   eval
.Lve_fill:                              // x0 payload, w1 null for all of sel
    add  x9, x23, #VEC_NULLS
    mov  x10, #0
1:  cmp  x10, x22
    b.hs .Lve_ret
    ldrh w11, [x21, x10, lsl #1]
    str  x0, [x23, x11, lsl #3]
    strb w1, [x9, x11]
    add  x10, x10, #1
    b    1b

    // ---- column of this query level ------------------------------------------
.Lve_col:
    ldr  w9, [x19, #N_OP]
    cbnz w9, .Lve_fallback              // outer reference
    ldr  x24, [x19, #N_B]               // rv
    ldr  x9, [x20, #VB_EC]
    ldr  x9, [x9, #EC_TABLES]
    ldr  x10, [x9, x24, lsl #3]         // Table*
    ldr  w11, [x10, #TBL_LAYOUT]
    cbnz w11, .Lve_fallback             // row layout: generic access
    ldr  x11, [x10, #TBL_COLS]
    ldr  x12, [x19, #N_VAL]
    add  x11, x11, x12, lsl #5          // Column*
    ldr  w13, [x11, #COL_ENC]
    ldr  x14, [x11, #COL_DATA]
    ldr  x15, [x11, #COL_NULLS]
    mov  x16, #0
    cbz  w13, 1f
    ldr  x16, [x14, #DC_DICT]
    ldr  x14, [x14, #DC_CODES]
1:  ldr  x9, [x20, #VB_TUP]
    ldr  x10, [x20, #VB_W]
    add  x9, x9, x24, lsl #2            // &tuple[0][rv]
    lsl  x10, x10, #2                   // tuple stride in bytes
    add  x17, x23, #VEC_NULLS
    mov  x0, #0
2:  cmp  x0, x22
    b.hs .Lve_ret
    ldrh w1, [x21, x0, lsl #1]          // position
    madd x2, x1, x10, x9
    ldr  w2, [x2]                       // row id
    add  x0, x0, #1
    cmn  w2, #1
    b.eq 5f                             // ROW_NULL (LEFT JOIN padding)
    mov  w3, #0
    cbz  x15, 3f
    lsr  x4, x2, #3
    ldrb w3, [x15, x4]
    and  w4, w2, #7
    lsr  w3, w3, w4
    and  w3, w3, #1
3:  strb w3, [x17, x1]
    cbnz w13, 4f
    ldr  x4, [x14, x2, lsl #3]
    str  x4, [x23, x1, lsl #3]
    b    2b
4:  ldr  w4, [x14, x2, lsl #2]          // dictionary code -> Str*
    ldr  x4, [x16, x4, lsl #3]
    str  x4, [x23, x1, lsl #3]
    b    2b
5:  mov  w3, #1
    strb w3, [x17, x1]
    str  xzr, [x23, x1, lsl #3]
    b    2b

    // ---- binary operators ----------------------------------------------------
.Lve_binary:
    ldr  w24, [x19, #N_OP]
    cmp  w24, #OP_AND
    b.hs .Lve_logic
    cmp  w24, #OP_CONCAT
    b.eq .Lve_fallback
    b.hi .Lve_cmp
    ldrb w9, [x19, #N_TYPE]             // arithmetic: by result kind
    cmp  w9, #T_INT
    b.eq 1f
    cmp  w9, #T_FLOAT
    b.eq 1f
    cmp  w9, #T_DEC
    b.ne .Lve_fallback
    cmp  w24, #OP_MUL                   // DECIMAL + - * only
    b.hi .Lve_fallback
1:  bl   .Lve_operands
    ldrb w9, [x19, #N_TYPE]
    str  w9, [sp]
    mov  x25, #0
2:  cmp  x25, x22
    b.hs .Lve_release2
    ldrh w28, [x21, x25, lsl #1]
    add  x25, x25, #1
    add  x9, x26, #VEC_NULLS
    ldrb w10, [x9, x28]
    add  x9, x27, #VEC_NULLS
    ldrb w11, [x9, x28]
    orr  w10, w10, w11
    add  x9, x23, #VEC_NULLS
    strb w10, [x9, x28]
    cbnz w10, 2b
    ldr  x0, [x26, x28, lsl #3]
    ldr  x1, [x27, x28, lsl #3]
    mov  w2, w24
    ldr  w9, [sp]
    cmp  w9, #T_INT
    b.ne 3f
    bl   arith_int
    b    5f
3:  cmp  w9, #T_FLOAT
    b.ne 4f
    bl   arith_float
    b    5f
4:  ldr  x9, [x19, #N_A]
    ldr  w3, [x9, #N_TYPE]
    ldr  x9, [x19, #N_B]
    ldr  w4, [x9, #N_TYPE]
    ldr  w5, [x19, #N_TYPE]
    bl   arith_dec
5:  str  x0, [x23, x28, lsl #3]
    b    2b

.Lve_cmp:
    ldr  x9, [x19, #N_A]
    ldr  w10, [x9, #N_TYPE]
    ldr  x9, [x19, #N_B]
    ldr  w11, [x9, #N_TYPE]
    and  w12, w10, #T_KIND_MASK
    and  w13, w11, #T_KIND_MASK
    cmp  w12, w13
    b.ne .Lve_fallback
    cbz  w12, .Lve_fallback             // null type
    cmp  w12, #T_DEC
    b.ne 1f
    cmp  w10, w11                       // DECIMAL: equal scales only
    b.ne .Lve_fallback
1:  mov  w9, #0                         // class: 0 signed, 1 float, 2 string
    cmp  w12, #T_FLOAT
    b.ne 2f
    mov  w9, #1
2:  cmp  w12, #T_STR
    b.ne 3f
    mov  w9, #2
3:  str  w9, [sp]
    ADR_L x9, cmp_masks
    sub  w10, w24, #OP_EQ
    ldrb w24, [x9, x10]
    bl   .Lve_operands
    mov  x25, #0
4:  cmp  x25, x22
    b.hs .Lve_release2
    ldrh w28, [x21, x25, lsl #1]
    add  x25, x25, #1
    add  x9, x26, #VEC_NULLS
    ldrb w10, [x9, x28]
    add  x9, x27, #VEC_NULLS
    ldrb w11, [x9, x28]
    orr  w10, w10, w11
    add  x9, x23, #VEC_NULLS
    strb w10, [x9, x28]
    cbnz w10, 4b
    ldr  x0, [x26, x28, lsl #3]
    ldr  x1, [x27, x28, lsl #3]
    ldr  w9, [sp]
    cbnz w9, 5f
    cmp  x0, x1                         // signed payloads
    b    6f
5:  cmp  w9, #1
    b.ne 7f
    fmov d0, x0                         // FLOAT64 (-0.0 == 0.0)
    fmov d1, x1
    fcmp d0, d1
6:  cset w0, gt
    csinv w0, w0, wzr, ge
    b    8f
7:  mov  w2, #T_STR
    mov  w3, #T_STR
    bl   cmp_typed
8:  add  w0, w0, #1
    lsr  w0, w24, w0
    and  x0, x0, #1
    str  x0, [x23, x28, lsl #3]
    b    4b

    // AND / OR: the right operand only where the left one does not decide
.Lve_logic:
    cmp  w24, #OP_AND
    cset w9, eq
    str  w9, [sp]
    mov  x0, x20
    bl   vpool_get
    mov  x26, x0
    ldr  x0, [x19, #N_A]
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x26
    bl   veval
    mov  x0, x20
    bl   vpool_get
    mov  x27, x0                        // undecided positions (u16)
    mov  x28, #0
    ldr  w12, [sp]
    add  x13, x26, #VEC_NULLS
    mov  x9, #0
1:  cmp  x9, x22
    b.hs 3f
    ldrh w10, [x21, x9, lsl #1]
    add  x9, x9, #1
    ldrb w11, [x13, x10]
    cbnz w11, 2f                        // NULL: undecided
    ldr  x11, [x26, x10, lsl #3]
    cmp  x11, #0
    cset w11, eq                        // w11 = left is FALSE
    cmp  w11, w12                       // AND: FALSE decides; OR: TRUE
    b.eq 1b
2:  strh w10, [x27, x28, lsl #1]
    add  x28, x28, #1
    b    1b
3:  mov  x0, x20
    bl   vpool_get
    mov  x24, x0                        // right values
    ldr  x0, [x19, #N_B]
    mov  x1, x20
    mov  x2, x27
    mov  x3, x28
    mov  x4, x24
    bl   veval
    ldr  w12, [sp]
    add  x13, x26, #VEC_NULLS
    add  x14, x24, #VEC_NULLS
    add  x15, x23, #VEC_NULLS
    mov  x9, #0
4:  cmp  x9, x22
    b.hs 9f
    ldrh w10, [x21, x9, lsl #1]
    add  x9, x9, #1
    ldrb w1, [x13, x10]                 // left null
    ldr  x2, [x26, x10, lsl #3]         // left value
    mov  w0, #0
    cbz  w12, 6f
    // AND
    cbnz w1, 5f
    cbz  x2, 8f                         // FALSE AND x
5:  ldrb w3, [x14, x10]
    ldr  x4, [x24, x10, lsl #3]
    cbnz w3, 51f
    cbz  x4, 8f                         // x AND FALSE
51: orr  w3, w3, w1
    cbnz w3, 7f
    mov  w0, #1
    b    8f
6:  // OR
    mov  w0, #1
    cbnz w1, 61f
    cbnz x2, 8f                         // TRUE OR x
61: ldrb w3, [x14, x10]
    ldr  x4, [x24, x10, lsl #3]
    cbnz w3, 62f
    cbnz x4, 8f                         // x OR TRUE
62: mov  w0, #0
    orr  w3, w3, w1
    cbz  w3, 8f
7:  str  xzr, [x23, x10, lsl #3]        // NULL
    mov  w3, #1
    strb w3, [x15, x10]
    b    4b
8:  str  x0, [x23, x10, lsl #3]
    strb wzr, [x15, x10]
    b    4b
9:  mov  x0, x20
    bl   vpool_put
    b    .Lve_release2

    // ---- unary operators -------------------------------------------------------
.Lve_unary:
    ldr  w24, [x19, #N_OP]
    ldr  x0, [x19, #N_A]
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x23
    bl   veval
    cmp  w24, #OP_POS
    b.eq .Lve_ret
    ldrb w25, [x19, #N_TYPE]
    add  x9, x23, #VEC_NULLS
    mov  x10, #0
1:  cmp  x10, x22
    b.hs .Lve_ret
    ldrh w11, [x21, x10, lsl #1]
    add  x10, x10, #1
    ldrb w12, [x9, x11]
    cbnz w12, 1b
    ldr  x0, [x23, x11, lsl #3]
    cmp  w24, #OP_NOT
    b.ne 2f
    eor  x0, x0, #1
    b    4f
2:  cmp  w25, #T_FLOAT                  // OP_NEG
    b.ne 3f
    eor  x0, x0, #0x8000000000000000
    b    4f
3:  negs x0, x0
    b.vs raise_overflow
4:  str  x0, [x23, x11, lsl #3]
    b    1b

.Lve_isnull:
    ldr  x0, [x19, #N_A]
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x23
    bl   veval
    ldr  w24, [x19, #N_OP]              // 1 = IS NOT NULL
    add  x9, x23, #VEC_NULLS
    mov  x10, #0
1:  cmp  x10, x22
    b.hs .Lve_ret
    ldrh w11, [x21, x10, lsl #1]
    add  x10, x10, #1
    ldrb w12, [x9, x11]
    eor  w12, w12, w24
    str  x12, [x23, x11, lsl #3]
    strb wzr, [x9, x11]
    b    1b

.Lve_cast:
    ldr  x9, [x19, #N_A]
    ldr  w24, [x9, #N_TYPE]             // from
    ldr  w25, [x19, #N_TYPE]            // to
    cmp  w24, w25
    b.eq 1f
    and  w9, w25, #T_KIND_MASK
    cmp  w24, #T_INT
    ccmp w9, #T_FLOAT, #0, eq
    b.eq 1f
    cmp  w24, #T_DATE
    ccmp w25, #T_TS, #0, eq
    b.ne .Lve_fallback
1:  ldr  x0, [x19, #N_A]
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x23
    bl   veval
    cmp  w24, w25
    b.eq .Lve_ret
    mov  x13, #0x6000                   // 86 400 000 000 µs per day
    movk x13, #0x1dd7, lsl #16
    movk x13, #0x14, lsl #32
    add  x9, x23, #VEC_NULLS
    mov  x10, #0
2:  cmp  x10, x22
    b.hs .Lve_ret
    ldrh w11, [x21, x10, lsl #1]
    add  x10, x10, #1
    ldrb w12, [x9, x11]
    cbnz w12, 2b
    ldr  x0, [x23, x11, lsl #3]
    cmp  w24, #T_INT
    b.ne 3f
    scvtf d0, x0                        // INT64 -> FLOAT64
    fmov x0, d0
    b    4f
3:  mul  x0, x0, x13                    // DATE -> TIMESTAMP
4:  str  x0, [x23, x11, lsl #3]
    b    2b

    // local helper: both operands into fresh vectors x26 (N_A), x27 (N_B)
.Lve_operands:
    stp  x29, x30, [sp, #-16]!
    mov  x0, x20
    bl   vpool_get
    mov  x26, x0
    mov  x0, x20
    bl   vpool_get
    mov  x27, x0
    ldr  x0, [x19, #N_A]
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x26
    bl   veval
    ldr  x0, [x19, #N_B]
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x27
    bl   veval
    ldp  x29, x30, [sp], #16
    ret
.Lve_release2:
    mov  x0, x20
    bl   vpool_put
    mov  x0, x20
    bl   vpool_put
    b    .Lve_ret
ENDF veval

// =============================================================================
// vfilter(x0 predicate, x1 VBatch*, x2 u16* out) -> x0 count
//   x19 predicate, x20 vb, x21 out, x22 vector
// =============================================================================
FUNC vfilter
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x0, x20
    bl   vpool_get
    mov  x22, x0
    mov  x0, x19
    mov  x1, x20
    ADR_L x2, vsel_ident
    ldr  x3, [x20, #VB_N]
    mov  x4, x22
    bl   veval
    ldr  x9, [x20, #VB_N]
    add  x10, x22, #VEC_NULLS
    mov  x11, #0                        // position
    mov  x0, #0                         // count
1:  cmp  x11, x9
    b.hs 2f
    ldrb w12, [x10, x11]
    ldr  x13, [x22, x11, lsl #3]
    cmp  w12, #0
    ccmp x13, #0, #4, eq                // ne iff not NULL and TRUE
    b.eq 11f
    strh w11, [x21, x0, lsl #1]
    add  x0, x0, #1
11: add  x11, x11, #1
    b    1b
2:  mov  x19, x0
    mov  x0, x20
    bl   vpool_put
    mov  x0, x19
    LEAVE 3
ENDF vfilter

// =============================================================================
// vkey_cells(x0 TupleSet*, x1 Node** keys, x2 nkeys (<= VKEY_MAX), x3 ctx,
//            x4 cells out, x5 u64* hashes out, x6 u8* NULL flags out)
// The key cells of every tuple (nkeys cells each), evaluated in batches,
// with the hash and NULL flag of join.S eval_keys (same hash function).
//   x19 ts, x20 keys, x21 nkeys, x22 vb, x23 cells, x24 hashes, x25 flags,
//   x26 batch start, x27 batch size, x28 key vectors
// Stack: [sp] position, [sp+8] key, [sp+16] hash, [sp+24] any NULL
// =============================================================================
FUNC vkey_cells
    ENTER 5
    sub  sp, sp, #32
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x23, x4
    mov  x24, x5
    mov  x25, x6
    mov  x0, x3
    ldr  x1, [x19, #TS_W]
    bl   vb_new
    mov  x22, x0
    lsl  x0, x21, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x28, x0
    str  xzr, [sp, #8]
1:  ldr  x9, [sp, #8]
    cmp  x9, x21
    b.hs 2f
    mov  x0, x22
    bl   vpool_get
    ldr  x9, [sp, #8]
    str  x0, [x28, x9, lsl #3]
    add  x9, x9, #1
    str  x9, [sp, #8]
    b    1b
2:  mov  x26, #0
.Lvk_batch:
    ldr  x9, [x19, #TS_N]
    cmp  x26, x9
    b.hs .Lvk_end
    bl   check_deadline
    ldr  x9, [x19, #TS_N]
    sub  x27, x9, x26
    mov  x10, #VBATCH
    cmp  x27, x10
    csel x27, x27, x10, lo
    ldr  x9, [x19, #TS_DATA]
    ldr  x10, [x19, #TS_W]
    mul  x10, x10, x26
    add  x9, x9, x10, lsl #2
    str  x9, [x22, #VB_TUP]
    str  x27, [x22, #VB_N]
    str  xzr, [sp, #8]
3:  ldr  x9, [sp, #8]                   // key vectors
    cmp  x9, x21
    b.hs 4f
    ldr  x0, [x20, x9, lsl #3]
    mov  x1, x22
    ADR_L x2, vsel_ident
    mov  x3, x27
    ldr  x4, [x28, x9, lsl #3]
    bl   veval
    ldr  x9, [sp, #8]
    add  x9, x9, #1
    str  x9, [sp, #8]
    b    3b
4:  str  xzr, [sp]
5:  ldr  x9, [sp]                       // per tuple: cells, hash, flag
    cmp  x9, x27
    b.hs 8f
    stp  xzr, xzr, [sp, #16]
    str  xzr, [sp, #8]
6:  ldr  x10, [sp, #8]
    cmp  x10, x21
    b.hs 7f
    ldr  x9, [sp]
    ldr  x11, [x28, x10, lsl #3]        // vector of key k
    ldr  x0, [x11, x9, lsl #3]
    add  x11, x11, #VEC_NULLS
    ldrb w1, [x11, x9]
    add  x12, x26, x9                   // tuple index
    mul  x12, x12, x21
    add  x12, x12, x10
    add  x12, x23, x12, lsl #4
    stp  x0, x1, [x12]
    add  x10, x10, #1
    str  x10, [sp, #8]
    cbz  w1, 61f
    mov  x9, #1
    str  x9, [sp, #24]
    b    6b
61: sub  x10, x10, #1
    ldr  x10, [x20, x10, lsl #3]
    ldr  w1, [x10, #N_TYPE]
    bl   hash_cell
    ldr  x9, [sp, #16]
    eor  x9, x9, x0
    ldr  x10, =0x9e3779b97f4a7c15
    mul  x9, x9, x10
    add  x9, x9, #1
    str  x9, [sp, #16]
    b    6b
7:  ldr  x9, [sp]
    add  x10, x26, x9
    ldp  x11, x12, [sp, #16]
    str  x11, [x24, x10, lsl #3]
    strb w12, [x25, x10]
    add  x9, x9, #1
    str  x9, [sp]
    b    5b
8:  add  x26, x26, x27
    b    .Lvk_batch
.Lvk_end:
    add  sp, sp, #32
    LEAVE 5
ENDF vkey_cells

    .ltorg
    NOTE_GNU_STACK
