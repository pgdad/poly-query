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
//       (conjunctions narrow the selection conjunct by conjunct)
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

#define DC_ENTRIES  8                   // dictionary truth tables per batch ctx

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
    mov  x0, #(DC_ENTRIES * 24 + 16)
    bl   arena_zalloc
    str  x0, [x19, #VB_DCACHE]
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
// Stack: [sp] u32 AND flag / comparison class, [sp+4] / [sp+8] u32
//        operand types of a comparison
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
    stp  w10, w11, [sp, #4]
    mov  w9, #3                         // class 3: DECIMALs of different
    cmp  w12, #T_DEC                    // scales (exact, cmp_typed)
    b.ne 1f
    cmp  w10, w11
    b.ne 3f
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
    ldr  w9, [sp]
    cmp  w9, #2
    b.ne 31f
    bl   .Lve_dict_cmp                  // STRING column vs literal?
    cbnz w0, .Lve_ret
31: bl   .Lve_operands
    ldr  w9, [sp]
    cbnz w9, 32f
    ADR_L x9, vsel_ident
    cmp  x21, x9
    b.eq .Lve_cmp_simd                  // dense signed comparison: NEON
32: mov  x25, #0
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
7:  ldp  w2, w3, [sp, #4]              // STRING / mixed-scale DECIMAL
    bl   cmp_typed
8:  add  w0, w0, #1
    lsr  w0, w24, w0
    and  x0, x0, #1
    str  x0, [x23, x28, lsl #3]
    b    4b

    // Explicit SIMD (NEON, 2 x 64-bit lanes) for a dense selection:
    // result = (a<b & mask_lt) | (a==b & mask_eq) | (a>b & mask_gt), the
    // NULL flags are OR-ed 16 bytes at a time. Positions past nsel (up to
    // the rounded-up count, inside the vectors) receive don't-care values.
.Lve_cmp_simd:
    tst  w24, #1
    csetm x9, ne
    dup  v20.2d, x9                     // lanes for "a < b is TRUE"
    tst  w24, #2
    csetm x9, ne
    dup  v21.2d, x9                     // "a = b"
    tst  w24, #4
    csetm x9, ne
    dup  v22.2d, x9                     // "a > b"
    mov  x10, #0
1:  cmp  x10, x22
    b.hs 2f
    lsl  x11, x10, #3
    ldr  q0, [x26, x11]
    ldr  q1, [x27, x11]
    cmgt v2.2d, v0.2d, v1.2d
    cmgt v3.2d, v1.2d, v0.2d
    cmeq v4.2d, v0.2d, v1.2d
    and  v2.16b, v2.16b, v22.16b
    and  v3.16b, v3.16b, v20.16b
    and  v4.16b, v4.16b, v21.16b
    orr  v2.16b, v2.16b, v3.16b
    orr  v2.16b, v2.16b, v4.16b
    ushr v2.2d, v2.2d, #63
    str  q2, [x23, x11]
    add  x10, x10, #2
    b    1b
2:  add  x12, x26, #VEC_NULLS
    add  x13, x27, #VEC_NULLS
    add  x14, x23, #VEC_NULLS
    mov  x10, #0
3:  cmp  x10, x22
    b.hs .Lve_release2
    ldr  q0, [x12, x10]
    ldr  q1, [x13, x10]
    orr  v0.16b, v0.16b, v1.16b
    str  q0, [x14, x10]
    add  x10, x10, #16
    b    3b

    // local helper: STRING column (DICT encoding, column layout) compared
    // with a non-NULL literal: the comparison is evaluated once per
    // dictionary entry (dict_truth) and looked up by code per row.
    // -> w0 1 if done (out filled), 0 if not applicable
.Lve_dict_cmp:
    stp  x29, x30, [sp, #-16]!
    ldr  x9, [x19, #N_A]
    ldr  w10, [x9, #N_KIND]
    cmp  w10, #NK_COL
    b.ne 9f
    ldr  w10, [x9, #N_OP]
    cbnz w10, 9f
    ldr  x10, [x19, #N_B]
    ldr  w11, [x10, #N_KIND]
    cmp  w11, #NK_LIT
    b.ne 9f
    ldr  w11, [x10, #N_FLAGS]
    tbnz w11, #0, 9f                    // NULL literal
    ldr  x11, [x9, #N_B]                // rv
    ldr  x12, [x20, #VB_EC]
    ldr  x12, [x12, #EC_TABLES]
    ldr  x12, [x12, x11, lsl #3]        // Table*
    ldr  w13, [x12, #TBL_LAYOUT]
    cbnz w13, 9f
    ldr  x13, [x12, #TBL_COLS]
    ldr  x14, [x9, #N_VAL]
    add  x13, x13, x14, lsl #5          // Column*
    ldr  w14, [x13, #COL_ENC]
    cmp  w14, #CENC_DICT
    b.ne 9f
    ldr  x14, [x13, #COL_DATA]          // DictCol*
    ldr  x15, [x14, #DC_NDICT]
    ldr  x16, [x12, #TBL_NROWS]
    cmp  x16, x15, lsl #2               // worth it: ndict <= nrows / 4
    b.lo 9f
    stp  x13, x11, [sp, #-16]!
    mov  x0, x19
    mov  x1, x20
    mov  x2, x14
    ldr  x3, [x10, #N_VAL]              // literal Str*
    mov  w4, w24
    bl   dict_truth
    ldp  x13, x11, [sp], #16
    ldr  x14, [x13, #COL_DATA]
    ldr  x14, [x14, #DC_CODES]
    ldr  x15, [x13, #COL_NULLS]
    ldr  x9, [x20, #VB_TUP]
    ldr  x10, [x20, #VB_W]
    add  x9, x9, x11, lsl #2            // &tuple[0][rv]
    lsl  x10, x10, #2
    add  x17, x23, #VEC_NULLS
    mov  x16, #0
1:  cmp  x16, x22
    b.hs 8f
    ldrh w1, [x21, x16, lsl #1]
    add  x16, x16, #1
    madd x2, x1, x10, x9
    ldr  w2, [x2]                       // row id
    mov  w3, #1
    cmn  w2, #1
    b.eq 3f                             // ROW_NULL
    cbz  x15, 2f
    lsr  x4, x2, #3
    ldrb w3, [x15, x4]
    and  w4, w2, #7
    lsr  w3, w3, w4
    and  w3, w3, #1
    cbnz w3, 3f
2:  ldr  w4, [x14, x2, lsl #2]          // code -> truth
    ldrb w4, [x0, x4]
    str  x4, [x23, x1, lsl #3]
    strb wzr, [x17, x1]
    b    1b
3:  str  xzr, [x23, x1, lsl #3]
    strb w3, [x17, x1]
    b    1b
8:  mov  w0, #1
    ldp  x29, x30, [sp], #16
    ret
9:  mov  w0, #0
    ldp  x29, x30, [sp], #16
    ret

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
// dict_truth(x0 comparison Node*, x1 VBatch*, x2 DictCol*, x3 literal Str*,
//            w4 truth mask) -> x0 u8* truth per dictionary code
// Cached per (node, dictionary) in the batch context (DC_ENTRIES entries,
// replaced round robin).
//   x19 node, x20 dict, x21 literal, w22 mask, x23 table, x24 index,
//   x25 cache
// =============================================================================
LFUNC dict_truth
    ENTER 5
    mov  x19, x0
    mov  x20, x2
    mov  x21, x3
    mov  w22, w4
    ldr  x25, [x1, #VB_DCACHE]
    mov  x24, #0
1:  cmp  x24, #DC_ENTRIES               // cached?
    b.hs 2f
    mov  x9, #24
    madd x9, x24, x9, x25
    add  x9, x9, #16
    ldp  x10, x11, [x9]
    cmp  x10, x19
    ccmp x11, x20, #0, eq
    b.ne 11f
    ldr  x0, [x9, #16]
    LEAVE 5
11: add  x24, x24, #1
    b    1b
2:  ldr  x0, [x20, #DC_NDICT]
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    mov  x24, #0
3:  ldr  x9, [x20, #DC_NDICT]
    cmp  x24, x9
    b.hs 4f
    ldr  x9, [x20, #DC_DICT]
    ldr  x9, [x9, x24, lsl #3]
    add  x0, x9, #STR_DATA
    ldr  x1, [x9, #STR_LEN]
    add  x2, x21, #STR_DATA
    ldr  x3, [x21, #STR_LEN]
    bl   bytes_cmp
    add  w0, w0, #1
    lsr  w0, w22, w0
    and  w0, w0, #1
    strb w0, [x23, x24]
    add  x24, x24, #1
    b    3b
4:  ldr  x9, [x25]                      // insert (round robin)
    add  x10, x9, #1
    str  x10, [x25]
    and  x9, x9, #(DC_ENTRIES - 1)
    mov  x10, #24
    madd x9, x9, x10, x25
    add  x9, x9, #16
    stp  x19, x20, [x9]
    str  x23, [x9, #16]
    mov  x0, x23
    LEAVE 5
ENDF dict_truth

// =============================================================================
// vfilter(x0 predicate, x1 VBatch*, x2 u16* out) -> x0 count
// Positions 0..VB_N-1 for which the predicate is TRUE.
// =============================================================================
FUNC vfilter
    mov  x4, x2
    mov  x2, x1
    mov  x1, x0
    ldr  x3, [x2, #VB_N]
    ADR_L x0, vsel_ident
    mov  x9, x0
    mov  x0, x1
    mov  x1, x2
    mov  x2, x9
    b    vfilter_sel
ENDF vfilter

// =============================================================================
// vfilter_sel(x0 predicate, x1 VBatch*, x2 u16* sel, x3 nsel, x4 u16* out)
//   -> x0 count of selected positions for which the predicate is TRUE
// For a conjunction the left operand is evaluated (three-valued, veval) and
// the right one only at the positions where the left one is not FALSE —
// exactly the operands the row evaluator evaluates — and the right one is
// filtered recursively, so nested conjunctions narrow conjunct by conjunct.
//   x19 predicate, x20 vb, x21 sel, x22 nsel, x23 out, x24 left vector,
//   x25 positions where the left operand is not FALSE
// =============================================================================
FUNC vfilter_sel
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x23, x4
    mov  x0, #0
    cbz  x22, 9f
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_BINARY
    b.ne 1f
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_AND
    b.ne 1f
    mov  x0, x20                        // AND: the left operand
    bl   vpool_get
    mov  x24, x0
    ldr  x0, [x19, #N_A]
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x24
    bl   veval
    mov  x0, x20
    bl   vpool_get
    mov  x25, x0
    add  x10, x24, #VEC_NULLS           // positions where it is not FALSE
    mov  x11, #0
    mov  x3, #0
11: cmp  x11, x22
    b.hs 12f
    ldrh w9, [x21, x11, lsl #1]
    add  x11, x11, #1
    ldrb w12, [x10, x9]
    ldr  x13, [x24, x9, lsl #3]
    cmp  w12, #0
    ccmp x13, #0, #0, eq                // eq iff not NULL and FALSE
    b.eq 11b
    strh w9, [x25, x3, lsl #1]
    add  x3, x3, #1
    b    11b
12: ldr  x0, [x19, #N_B]                // the right operand there
    mov  x1, x20
    mov  x2, x25
    mov  x4, x23
    bl   vfilter_sel
    add  x10, x24, #VEC_NULLS           // keep those where the left is TRUE
    mov  x11, #0
    mov  x12, #0
13: cmp  x11, x0
    b.hs 14f
    ldrh w9, [x23, x11, lsl #1]
    add  x11, x11, #1
    ldrb w13, [x10, x9]
    cbnz w13, 13b
    strh w9, [x23, x12, lsl #1]
    add  x12, x12, #1
    b    13b
14: mov  x19, x12
    mov  x0, x20
    bl   vpool_put
    mov  x0, x20
    bl   vpool_put
    mov  x0, x19
    b    9f
1:  mov  x0, x20
    bl   vpool_get
    mov  x24, x0
    mov  x0, x19
    mov  x1, x20
    mov  x2, x21
    mov  x3, x22
    mov  x4, x24
    bl   veval
    add  x10, x24, #VEC_NULLS
    mov  x11, #0                        // index into sel
    mov  x0, #0                         // count
2:  cmp  x11, x22
    b.hs 3f
    ldrh w9, [x21, x11, lsl #1]
    add  x11, x11, #1
    ldrb w12, [x10, x9]
    ldr  x13, [x24, x9, lsl #3]
    cmp  w12, #0
    ccmp x13, #0, #4, eq                // ne iff not NULL and TRUE
    b.eq 2b
    strh w9, [x23, x0, lsl #1]
    add  x0, x0, #1
    b    2b
3:  mov  x19, x0
    mov  x0, x20
    bl   vpool_put
    mov  x0, x19
9:  LEAVE 4
ENDF vfilter_sel

// =============================================================================
// vkey_cells(x0 VKeyTask*) — the key cells of the tuples [VK_LO, VK_HI)
// (nkeys cells each, at the tuple's index in VK_CELLS), evaluated in
// batches, with the hash and NULL flag of join.S eval_keys (same hash
// function). A task function: join.S runs windows of one input in parallel.
//   x19 ts, x20 keys, x21 nkeys, x22 vb, x23 cells, x24 hashes, x25 flags,
//   x26 batch start, x27 batch size, x28 key vectors
// Stack: [sp] position, [sp+8] key, [sp+16] hash, [sp+24] any NULL,
//        [sp+32] end of the window
// =============================================================================
FUNC vkey_cells
    ENTER 5
    sub  sp, sp, #48
    ldr  x19, [x0, #VK_TS]
    ldr  x20, [x0, #VK_KEYS]
    ldr  x21, [x0, #VK_NKEYS]
    ldr  x23, [x0, #VK_CELLS]
    ldr  x24, [x0, #VK_HASH]
    ldr  x25, [x0, #VK_FLAGS]
    ldr  x26, [x0, #VK_LO]
    ldr  x9, [x0, #VK_HI]
    str  x9, [sp, #32]
    ldr  x0, [x0, #VK_CTX]
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
    b.hs .Lvk_batch
    mov  x0, x22
    bl   vpool_get
    ldr  x9, [sp, #8]
    str  x0, [x28, x9, lsl #3]
    add  x9, x9, #1
    str  x9, [sp, #8]
    b    1b
.Lvk_batch:
    ldr  x9, [sp, #32]
    cmp  x26, x9
    b.hs .Lvk_end
    bl   check_deadline
    ldr  x9, [sp, #32]
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
    add  sp, sp, #48
    LEAVE 5
ENDF vkey_cells

    .ltorg
    NOTE_GNU_STACK
