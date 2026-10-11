// =============================================================================
// eval.S — expression evaluator and aggregate accumulators.
//
//   eval(x0 Node*, x1 EvalCtx*)          -> x0 payload, x1 isnull (0/1)
//   agg_init(x0 BoundQuery*)             -> x0 state*
//   agg_step(x0 BoundQuery*, x1 state*, x2 EvalCtx*)
//   agg_finish(x0 BoundQuery*, x1 state*) -> x0 cells (16 bytes per slot)
//
// eval works on trees produced by binder.S: every node carries its static
// type in N_TYPE and the binder has inserted implicit casts, so binary
// operators see operands of the same type kind (DECIMAL operands of + - and
// comparisons may differ in scale; they are aligned here with exact 128-bit
// arithmetic). Semantics: types.md §4 (arithmetic), §5 (comparison),
// §6 (three-valued logic), functions.md §2 (aggregates).
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define INT64_MIN_HI   0x8000          // INT64_MIN = 0x8000 << 48

// Aggregate state record (one per slot)
#define AS_CNT      0       // u64 number of accumulated (non-NULL) inputs/rows
#define AS_LO       8       // SUM/AVG: i128 low word or f64 bits; MIN/MAX: value
#define AS_HI       16      // SUM/AVG: i128 high word
#define AS_SIZE     32

// SCALE128 lo, hi, v, n: (hi:lo) = v * 10^n (signed 128-bit), n register (w)
// Clobbers x16.
.macro SCALE128 lo, hi, v, n
    ADR_L x16, p10tab
    ldr  x16, [x16, \n, uxtw #3]
    smulh \hi, \v, x16
    mul  \lo, \v, x16
.endm

// CHECK_DEC128 lo, hi: raise NUMERIC_OVERFLOW unless |hi:lo| <= 10^18-1.
// Clobbers x16.
.macro CHECK_DEC128 lo, hi
    cmp  \hi, \lo, asr #63
    b.ne raise_overflow
    ldr  x16, =MAX_DEC_UNSCALED
    cmp  \lo, x16
    b.gt raise_overflow
    cmn  \lo, x16
    b.lt raise_overflow
.endm

    .section .rodata
    .p2align 3
p10tab:
    .quad 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000
    .quad 1000000000, 10000000000, 100000000000, 1000000000000
    .quad 10000000000000, 100000000000000, 1000000000000000
    .quad 10000000000000000, 100000000000000000, 1000000000000000000
    .text

// Shared error exits (branch targets; never return).
FUNC raise_overflow
    RAISE ERR_NUMERIC_OVERFLOW, "numeric overflow"
ENDF raise_overflow

FUNC raise_div0
    RAISE ERR_DIVISION_BY_ZERO, "division by zero"
ENDF raise_div0

// =============================================================================
// eval(x0 Node*, x1 EvalCtx*) -> x0 payload, x1 isnull
// Dispatcher: tail-calls the evaluator of the node kind (no frame of its own).
// =============================================================================
FUNC eval
    ldr  w9, [x0, #N_KIND]
    cmp  w9, #NK_COL
    b.eq ev_col
    cmp  w9, #NK_LIT
    b.eq ev_lit
    cmp  w9, #NK_BINARY
    b.eq ev_binary
    cmp  w9, #NK_CAST
    b.eq ev_cast
    cmp  w9, #NK_AGG
    b.eq ev_agg
    cmp  w9, #NK_UNARY
    b.eq ev_unary
    cmp  w9, #NK_ISNULL
    b.eq ev_isnull
    cmp  w9, #NK_FUNC
    b.eq ev_func                        // functions.S
    cmp  w9, #NK_CASE
    b.eq ev_case                        // functions.S
    cmp  w9, #NK_IN
    b.eq ev_inlist                      // functions.S
    cmp  w9, #NK_LIKE
    b.eq ev_like                        // functions.S
    cmp  w9, #NK_GKEY
    b.eq ev_gkey
    cmp  w9, #NK_SUBQ
    b.eq ev_subq                        // exec.S
    cmp  w9, #NK_EXISTS
    b.eq ev_exists                      // exec.S
    cmp  w9, #NK_INSUB
    b.eq ev_insub                       // exec.S
    RAISE ERR_INTERNAL, "eval: unexpected node kind"
ENDF eval

// ev_lit: literal payload; NULL literal (NF_NULL or null type) is NULL. (leaf)
LFUNC ev_lit
    ldr  w9, [x0, #N_FLAGS]
    and  w1, w9, #NF_NULL
    ldrb w10, [x0, #N_TYPE]
    cbnz w10, 1f
    mov  w1, #1
1:  ldr  x0, [x0, #N_VAL]
    ret
ENDF ev_lit

// ev_col: column N_VAL of range variable N_B, N_OP query levels up (outer
// reference): row = EC_TUPLE[rv] of that level's context, table =
// EC_TABLES[rv]; ROW_NULL (NULL-padded LEFT JOIN side) => NULL. (leaf)
LFUNC ev_col
    ldr  w9, [x0, #N_OP]
1:  cbz  w9, 2f
    ldr  x1, [x1, #EC_OUTER]
    sub  w9, w9, #1
    b    1b
2:  ldr  x10, [x1, #EC_TUPLE]
    ldr  x11, [x0, #N_B]
    ldr  w10, [x10, x11, lsl #2]        // row id
    cmn  w10, #1
    b.eq 4f                             // ROW_NULL
    ldr  x9, [x1, #EC_TABLES]
    ldr  x9, [x9, x11, lsl #3]
    ldr  x11, [x0, #N_VAL]
    ldr  x9, [x9, #TBL_COLS]
    add  x9, x9, x11, lsl #5            // COL_SIZE = 32
    ldr  x12, [x9, #COL_NULLS]
    ldr  x13, [x9, #COL_DATA]
    mov  x1, #0
    cbz  x12, 3f
    ldrb w1, [x12, x10]
3:  ldr  x0, [x13, x10, lsl #3]
    ret
4:  mov  x0, #0
    mov  x1, #1
    ret
ENDF ev_col

// ev_gkey: GROUP BY key N_VAL of the current group (EC_GKEYS). (leaf)
LFUNC ev_gkey
    ldr  x9, [x1, #EC_GKEYS]
    ldr  x10, [x0, #N_VAL]
    add  x9, x9, x10, lsl #4
    ldp  x0, x1, [x9]
    ret
ENDF ev_gkey

// ev_agg: finished aggregate value from cell N_B of EC_AGGV. (leaf)
LFUNC ev_agg
    ldr  x9, [x1, #EC_AGGV]
    ldr  x10, [x0, #N_B]
    add  x9, x9, x10, lsl #4
    ldp  x0, x1, [x9]
    ret
ENDF ev_agg

// =============================================================================
// ev_cast: NULL => NULL; identical types pass through; the implicit casts the
// binder inserts (INT64 -> FLOAT64 / DECIMAL, DATE -> TIMESTAMP) are done
// inline, everything else goes to cast_value.
//   x19 node
// =============================================================================
LFUNC ev_cast
    ENTER 1
    mov  x19, x0
    ldr  x0, [x19, #N_A]
    bl   eval
    cbnz x1, .Lcast_null
    ldr  x9, [x19, #N_A]
    ldr  w1, [x9, #N_TYPE]              // from
    ldr  w2, [x19, #N_TYPE]             // to
    cmp  w1, w2
    b.eq .Lcast_done
    and  w10, w2, #T_KIND_MASK
    cmp  w1, #T_INT
    b.ne 2f
    cmp  w10, #T_FLOAT                  // INT64 -> FLOAT64: nearest
    b.ne 1f
    scvtf d0, x0
    fmov x0, d0
    b    .Lcast_done
1:  cmp  w10, #T_DEC                    // INT64 -> DECIMAL(p,s): exact
    b.ne .Lcast_lib
    ubfx w11, w2, #T_SCALE_SHIFT, #8
    SCALE128 x12, x13, x0, w11
    cmp  x13, x12, asr #63
    b.ne raise_overflow
    ubfx w11, w2, #T_PREC_SHIFT, #8     // |v| < 10^p
    ADR_L x16, p10tab
    ldr  x16, [x16, w11, uxtw #3]
    sub  x16, x16, #1
    cmp  x12, x16
    b.gt raise_overflow
    cmn  x12, x16
    b.lt raise_overflow
    mov  x0, x12
    b    .Lcast_done
2:  cmp  w1, #T_DATE                    // DATE -> TIMESTAMP: midnight
    ccmp w2, #T_TS, #0, eq
    b.ne .Lcast_lib
    mov  x9, #0x6000
    movk x9, #0x1dd7, lsl #16
    movk x9, #0x14, lsl #32             // 86 400 000 000 µs per day
    mul  x0, x0, x9
    b    .Lcast_done
.Lcast_lib:
    bl   cast_value
.Lcast_done:
    mov  x1, #0
    LEAVE 1
.Lcast_null:
    mov  x0, #0
    mov  x1, #1
    LEAVE 1
ENDF ev_cast

// =============================================================================
// ev_unary: - + NOT  (NULL => NULL)
//   x19 node
// =============================================================================
LFUNC ev_unary
    ENTER 1
    mov  x19, x0
    ldr  x0, [x19, #N_A]
    bl   eval
    cbnz x1, .Lun_null
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_NOT
    b.ne 1f
    eor  x0, x0, #1
    b    .Lun_done
1:  cmp  w9, #OP_NEG
    b.ne .Lun_done                      // unary +: identity
    ldrb w10, [x19, #N_TYPE]
    cmp  w10, #T_FLOAT
    b.ne 2f
    eor  x0, x0, #0x8000000000000000    // flip the sign bit
    b    .Lun_done
2:  negs x0, x0                         // INT64 / DECIMAL
    b.vs raise_overflow                 // -INT64_MIN
.Lun_done:
    mov  x1, #0
    LEAVE 1
.Lun_null:
    mov  x0, #0
    mov  x1, #1
    LEAVE 1
ENDF ev_unary

// ev_isnull: IS [NOT] NULL, never NULL.
//   x19 node
LFUNC ev_isnull
    ENTER 1
    mov  x19, x0
    ldr  x0, [x19, #N_A]
    bl   eval
    cmp  x1, #0
    cset x0, ne
    ldr  w9, [x19, #N_OP]               // 1 = IS NOT NULL
    eor  x0, x0, x9
    mov  x1, #0
    LEAVE 1
ENDF ev_isnull

// =============================================================================
// ev_binary: arithmetic, ||, comparisons, AND/OR.
//   x19 node, x20 ctx, x21 left payload, x22 left isnull, w23 op
// =============================================================================
LFUNC ev_binary
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  w23, [x19, #N_OP]
    cmp  w23, #OP_AND
    b.hs .Lbin_logic
    ldr  x0, [x19, #N_A]
    bl   eval
    mov  x21, x0
    mov  x22, x1
    ldr  x0, [x19, #N_B]
    mov  x1, x20
    bl   eval
    orr  x9, x22, x1                    // any NULL operand => NULL
    cbnz x9, .Lbin_null
    mov  x1, x0                         // x0 = left, x1 = right
    mov  x0, x21
    cmp  w23, #OP_CONCAT
    b.lo .Lbin_arith
    b.eq .Lbin_concat

    // ---- comparison ----------------------------------------------------------
    ldr  x9, [x19, #N_A]
    ldr  w2, [x9, #N_TYPE]
    ldr  x9, [x19, #N_B]
    ldr  w3, [x9, #N_TYPE]
    bl   cmp_typed
    cmp  w23, #OP_EQ
    b.ne 1f
    cmp  w0, #0
    cset x0, eq
    b    .Lbin_ok
1:  cmp  w23, #OP_NE
    b.ne 2f
    cmp  w0, #0
    cset x0, ne
    b    .Lbin_ok
2:  cmp  w23, #OP_LT
    b.ne 3f
    cmp  w0, #0
    cset x0, lt
    b    .Lbin_ok
3:  cmp  w23, #OP_LE
    b.ne 4f
    cmp  w0, #0
    cset x0, le
    b    .Lbin_ok
4:  cmp  w23, #OP_GT
    b.ne 5f
    cmp  w0, #0
    cset x0, gt
    b    .Lbin_ok
5:  cmp  w0, #0                         // OP_GE
    cset x0, ge
    b    .Lbin_ok

    // ---- arithmetic: dispatch on the result type ---------------------------
.Lbin_arith:
    mov  w2, w23
    ldrb w9, [x19, #N_TYPE]
    cmp  w9, #T_INT
    b.ne 1f
    bl   arith_int
    b    .Lbin_ok
1:  cmp  w9, #T_FLOAT
    b.ne 2f
    bl   arith_float
    b    .Lbin_ok
2:  ldr  x9, [x19, #N_A]                // DECIMAL
    ldr  w3, [x9, #N_TYPE]
    ldr  x9, [x19, #N_B]
    ldr  w4, [x9, #N_TYPE]
    ldr  w5, [x19, #N_TYPE]
    bl   arith_dec
    b    .Lbin_ok

    // ---- || ------------------------------------------------------------------
.Lbin_concat:
    mov  x21, x0                        // left Str*
    mov  x22, x1                        // right Str*
    ldr  x9, [x21, #STR_LEN]
    ldr  x10, [x22, #STR_LEN]
    add  x0, x9, x10
    add  x0, x0, #(STR_DATA + 1)
    bl   arena_alloc
    mov  x23, x0
    ldr  x9, [x21, #STR_LEN]
    ldr  x10, [x22, #STR_LEN]
    add  x9, x9, x10
    str  x9, [x23, #STR_LEN]
    add  x0, x23, #STR_DATA
    add  x1, x21, #STR_DATA
    ldr  x2, [x21, #STR_LEN]
    bl   memcpy
    ldr  x9, [x21, #STR_LEN]
    add  x0, x23, #STR_DATA
    add  x0, x0, x9
    add  x1, x22, #STR_DATA
    ldr  x2, [x22, #STR_LEN]
    bl   memcpy
    ldr  x9, [x23, #STR_LEN]            // NUL terminator after the bytes
    add  x10, x23, #STR_DATA
    strb wzr, [x10, x9]
    mov  x0, x23
    b    .Lbin_ok

    // ---- AND / OR (three-valued, short-circuit on the deciding value) ------
.Lbin_logic:
    ldr  x0, [x19, #N_A]
    bl   eval
    mov  x21, x0
    mov  x22, x1
    cbnz x22, 1f
    cmp  w23, #OP_AND
    b.ne 2f
    cbz  x21, .Lbin_false               // FALSE AND x
    b    1f
2:  cbnz x21, .Lbin_true                // TRUE OR x
1:  ldr  x0, [x19, #N_B]
    mov  x1, x20
    bl   eval
    cmp  w23, #OP_AND
    b.ne 3f
    cbnz x1, 4f
    cbz  x0, .Lbin_false                // x AND FALSE
4:  orr  x9, x22, x1
    cbnz x9, .Lbin_null
    b    .Lbin_true
3:  cbnz x1, 5f
    cbnz x0, .Lbin_true                 // x OR TRUE
5:  orr  x9, x22, x1
    cbnz x9, .Lbin_null
.Lbin_false:
    mov  x0, #0
    b    .Lbin_ok
.Lbin_true:
    mov  x0, #1
.Lbin_ok:
    mov  x1, #0
    LEAVE 3
.Lbin_null:
    mov  x0, #0
    mov  x1, #1
    LEAVE 3
ENDF ev_binary

// =============================================================================
// arith_int(x0 a, x1 b, w2 op) -> x0   INT64 + - * / %   (leaf)
// =============================================================================
FUNC arith_int
    cmp  w2, #OP_ADD
    b.ne 1f
    adds x0, x0, x1
    b.vs raise_overflow
    ret
1:  cmp  w2, #OP_SUB
    b.ne 2f
    subs x0, x0, x1
    b.vs raise_overflow
    ret
2:  cmp  w2, #OP_MUL
    b.ne 3f
    mul  x9, x0, x1
    smulh x10, x0, x1
    cmp  x10, x9, asr #63               // high word must be the sign extension
    b.ne raise_overflow
    mov  x0, x9
    ret
3:  cbz  x1, raise_div0
    cmn  x1, #1
    b.eq 5f
    sdiv x9, x0, x1                     // truncates toward zero
    cmp  w2, #OP_DIV
    b.ne 4f
    mov  x0, x9
    ret
4:  msub x0, x9, x1, x0                 // remainder has the dividend's sign
    ret
5:  cmp  w2, #OP_DIV                    // divisor -1
    b.ne 6f
    negs x0, x0                         // INT64_MIN / -1 overflows
    b.vs raise_overflow
    ret
6:  mov  x0, #0                         // x % -1 = 0 (incl. INT64_MIN)
    ret
ENDF arith_int

// =============================================================================
// arith_float(x0 a, x1 b, w2 op) -> x0   FLOAT64 + - * /   (leaf)
// Division by zero (also 0/0) => DIVISION_BY_ZERO; non-finite => overflow.
// =============================================================================
FUNC arith_float
    fmov d0, x0
    fmov d1, x1
    cmp  w2, #OP_ADD
    b.ne 1f
    fadd d0, d0, d1
    b    9f
1:  cmp  w2, #OP_SUB
    b.ne 2f
    fsub d0, d0, d1
    b    9f
2:  cmp  w2, #OP_MUL
    b.ne 3f
    fmul d0, d0, d1
    b    9f
3:  fcmp d1, #0.0
    b.eq raise_div0
    fdiv d0, d0, d1
9:  fmov x0, d0
    ubfx x9, x0, #52, #11
    cmp  x9, #0x7ff
    b.eq raise_overflow
    ret
ENDF arith_float

// =============================================================================
// arith_dec(x0 a, x1 b, w2 op, w3 type a, w4 type b, w5 result type) -> x0
// DECIMAL + - * with exact 128-bit intermediates.   (leaf)
// + -: operands are aligned to the result scale max(s1,s2).
// *  : product of the unscaled values, result scale s1+s2.
// =============================================================================
FUNC arith_dec
    cmp  w2, #OP_MUL
    b.ne 1f
    mul  x9, x0, x1
    smulh x10, x0, x1
    b    9f
1:  ubfx w6, w5, #T_SCALE_SHIFT, #8     // result scale
    ubfx w7, w3, #T_SCALE_SHIFT, #8
    sub  w7, w6, w7
    SCALE128 x9, x10, x0, w7
    ubfx w7, w4, #T_SCALE_SHIFT, #8
    sub  w7, w6, w7
    SCALE128 x11, x12, x1, w7
    cmp  w2, #OP_SUB
    b.ne 2f
    negs x11, x11                       // negate the 128-bit right operand
    ngc  x12, x12
2:  adds x9, x9, x11
    adc  x10, x10, x12
9:  CHECK_DEC128 x9, x10
    mov  x0, x9
    ret
ENDF arith_dec

// =============================================================================
// cmp_typed(x0 a, x1 b, w2 type a, w3 type b) -> w0 -1/0/1
// Compares two non-NULL values of the same type kind (DECIMAL scales may
// differ; they are compared exactly). Also used by MIN/MAX.   (leaf, or tail
// call to bytes_cmp)
// =============================================================================
FUNC cmp_typed
    and  w9, w2, #T_KIND_MASK
    cmp  w9, #T_FLOAT
    b.eq .Lct_float
    cmp  w9, #T_STR
    b.eq .Lct_str
    cmp  w9, #T_BOOL
    b.eq .Lct_bool
    cmp  w9, #T_DEC
    b.ne .Lct_signed
    ubfx w10, w2, #T_SCALE_SHIFT, #8
    ubfx w11, w3, #T_SCALE_SHIFT, #8
    cmp  w10, w11
    b.eq .Lct_signed
    // align to the larger scale in 128 bits
    cmp  w10, w11
    csel w12, w10, w11, hi              // max scale
    sub  w13, w12, w10
    SCALE128 x4, x5, x0, w13
    sub  w13, w12, w11
    SCALE128 x6, x7, x1, w13
    cmp  x5, x7
    b.ne .Lct_signed_flags
    cmp  x4, x6                         // equal high words: unsigned low words
    cset w0, hi
    csinv w0, w0, wzr, hs
    ret
.Lct_signed:
    cmp  x0, x1
.Lct_signed_flags:
    cset w0, gt
    csinv w0, w0, wzr, ge
    ret
.Lct_bool:
    cmp  x0, x1
    cset w0, hi
    csinv w0, w0, wzr, hs
    ret
.Lct_float:
    fmov d0, x0
    fmov d1, x1
    fcmp d0, d1                         // -0.0 == 0.0; no NaNs exist
    cset w0, gt
    csinv w0, w0, wzr, ge
    ret
.Lct_str:
    ldr  x3, [x1, #STR_LEN]
    add  x2, x1, #STR_DATA
    ldr  x1, [x0, #STR_LEN]
    add  x0, x0, #STR_DATA
    b    bytes_cmp                      // code point order == byte order
ENDF cmp_typed

// =============================================================================
// Aggregates
// agg_init(x0 BoundQuery*) -> x0 zeroed state (AS_SIZE bytes per slot)
// =============================================================================
FUNC agg_init
    ldr  x0, [x0, #BQ_NAGG]
    add  x0, x0, #1                     // never a zero-sized allocation
    lsl  x0, x0, #5                     // AS_SIZE = 32
    b    arena_zalloc
ENDF agg_init

// =============================================================================
// agg_step(x0 BoundQuery*, x1 state*, x2 EvalCtx*) — accumulate one row into
// every non-DISTINCT slot (DISTINCT slots are fed by the executor through
// agg_accum with de-duplicated values).
//   x19 slot node cursor, x20 state record cursor, x21 ctx, x22 slots left,
//   x23 node
// =============================================================================
FUNC agg_step
    ENTER 3
    ldr  x19, [x0, #BQ_AGGS]
    ldr  x22, [x0, #BQ_NAGG]
    mov  x20, x1
    mov  x21, x2
.Last_loop:
    cbz  x22, .Last_end
    ldr  x23, [x19]
    ldr  w9, [x23, #N_FLAGS]
    tbnz w9, #1, .Last_next             // NF_DISTINCT
    ldr  w9, [x23, #N_OP]
    cmp  w9, #F_COUNT_STAR
    b.eq .Last_count
    ldr  x0, [x23, #N_A]
    mov  x1, x21
    bl   eval
    cbnz x1, .Last_next                 // NULL inputs are ignored
    mov  x2, x0
    mov  x0, x23
    mov  x1, x20
    bl   agg_accum
    b    .Last_next
.Last_count:
    ldr  x9, [x20, #AS_CNT]
    add  x9, x9, #1
    str  x9, [x20, #AS_CNT]
.Last_next:
    add  x19, x19, #8
    add  x20, x20, #AS_SIZE
    sub  x22, x22, #1
    b    .Last_loop
.Last_end:
    LEAVE 3
ENDF agg_step

// =============================================================================
// agg_accum(x0 NK_AGG node, x1 state record, x2 non-NULL payload)
// Adds one input value to an aggregate's state.
//   x19 node, x20 state record, x21 value, w24 argument type, w25 function id
// =============================================================================
FUNC agg_accum
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  w25, [x19, #N_OP]
    ldr  x9, [x19, #N_A]
    ldr  w24, [x9, #N_TYPE]
    ldr  x9, [x20, #AS_CNT]
    add  x9, x9, #1
    str  x9, [x20, #AS_CNT]
    cmp  w25, #F_COUNT
    b.eq .Lacc_end
    cmp  w25, #F_MIN
    b.eq .Lacc_minmax
    cmp  w25, #F_MAX
    b.eq .Lacc_minmax
    // SUM / AVG
    and  w10, w24, #T_KIND_MASK
    cmp  w10, #T_FLOAT
    b.ne 1f
    ldr  d0, [x20, #AS_LO]
    fmov d1, x21
    fadd d0, d0, d1
    str  d0, [x20, #AS_LO]
    b    .Lacc_end
1:  ldp  x10, x11, [x20, #AS_LO]        // exact 128-bit sum
    asr  x12, x21, #63                  // sign extension of the input
    adds x10, x10, x21
    adc  x11, x11, x12
    stp  x10, x11, [x20, #AS_LO]
    b    .Lacc_end
.Lacc_minmax:
    cmp  x9, #1
    b.eq 2f                             // first value
    mov  x0, x21
    ldr  x1, [x20, #AS_LO]
    mov  w2, w24
    mov  w3, w24
    bl   cmp_typed
    cmp  w25, #F_MIN
    b.ne 3f
    tbz  w0, #31, .Lacc_end             // MIN: replace if new < current
    b    2f
3:  cmp  w0, #1                         // MAX: replace if new > current
    b.ne .Lacc_end
2:  str  x21, [x20, #AS_LO]
.Lacc_end:
    LEAVE 4
ENDF agg_accum

// =============================================================================
// agg_finish(x0 BoundQuery*, x1 state*) -> x0 cells (16 bytes per slot)
// COUNT => count; others NULL without inputs; SUM INT64/DECIMAL range checked
// (NUMERIC_OVERFLOW); AVG = exact sum / count in FLOAT64.
//   x19 slot node cursor, x20 state cursor, x21 cell cursor, x22 slots left,
//   x23 cells base, x24 node
// =============================================================================
FUNC agg_finish
    ENTER 3
    ldr  x19, [x0, #BQ_AGGS]
    ldr  x22, [x0, #BQ_NAGG]
    mov  x20, x1
    add  x0, x22, #1
    lsl  x0, x0, #4
    bl   arena_zalloc
    mov  x23, x0
    mov  x21, x0
.Lafi_loop:
    cbz  x22, .Lafi_end
    ldr  x24, [x19]
    ldr  w9, [x24, #N_OP]
    ldr  x10, [x20, #AS_CNT]
    cmp  w9, #F_COUNT
    ccmp w9, #F_COUNT_STAR, #4, ne
    b.ne 1f
    mov  x0, x10                        // COUNT / COUNT(*)
    b    .Lafi_val
1:  cbz  x10, .Lafi_null                // no non-NULL input
    cmp  w9, #F_SUM
    b.eq .Lafi_sum
    cmp  w9, #F_AVG
    b.eq .Lafi_avg
    ldr  x0, [x20, #AS_LO]              // MIN / MAX
    b    .Lafi_val

.Lafi_sum:
    ldr  x11, [x24, #N_A]
    ldrb w11, [x11, #N_TYPE]
    ldp  x0, x1, [x20, #AS_LO]
    cmp  w11, #T_FLOAT
    b.eq .Lafi_fcheck
    cmp  x1, x0, asr #63                // must fit INT64
    b.ne raise_overflow
    cmp  w11, #T_DEC
    b.ne .Lafi_val
    CHECK_DEC128 x0, x1                 // DECIMAL: at most 18 digits
    b    .Lafi_val

.Lafi_avg:
    ldr  x11, [x24, #N_A]
    ldr  w11, [x11, #N_TYPE]
    and  w12, w11, #T_KIND_MASK
    ucvtf d2, x10                       // count
    ldp  x0, x1, [x20, #AS_LO]
    cmp  w12, #T_FLOAT
    b.ne 2f
    fmov d0, x0
    fdiv d0, d0, d2
    fmov x0, d0
    b    .Lafi_fcheck
2:  // i128 -> f64
    cmp  x1, x0, asr #63
    b.ne 3f
    scvtf d0, x0
    b    4f
3:  scvtf d0, x1                        // hi * 2^64 + (unsigned) lo
    mov  x13, #0x43f0000000000000       // 2^64
    fmov d1, x13
    fmul d0, d0, d1
    ucvtf d1, x0
    fadd d0, d0, d1
4:  cmp  w12, #T_DEC
    b.ne 5f
    ubfx w13, w11, #T_SCALE_SHIFT, #8   // divide by count * 10^s in one step
    ADR_L x14, p10tab
    ldr  x14, [x14, w13, uxtw #3]
    ucvtf d1, x14
    fmul d2, d2, d1
5:  fdiv d0, d0, d2
    fmov x0, d0
.Lafi_fcheck:
    ubfx x9, x0, #52, #11               // FLOAT64 results must be finite
    cmp  x9, #0x7ff
    b.eq raise_overflow
.Lafi_val:
    stp  x0, xzr, [x21]
    b    .Lafi_next
.Lafi_null:
    mov  x9, #1
    stp  xzr, x9, [x21]
.Lafi_next:
    add  x19, x19, #8
    add  x20, x20, #AS_SIZE
    add  x21, x21, #16
    sub  x22, x22, #1
    b    .Lafi_loop
.Lafi_end:
    mov  x0, x23
    LEAVE 3
ENDF agg_finish

    .ltorg
    NOTE_GNU_STACK
