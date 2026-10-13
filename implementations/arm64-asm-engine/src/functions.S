// =============================================================================
// functions.S — scalar functions (functions.md §1), CASE, LIKE, BETWEEN and
// IN lists (semantics.md §11-13): binding (typing) and evaluation.
//
// Binding entry points (called from binder.S bind_expr / bind_func), all
//   (x0 BindCtx*, x1 Node*) -> x0 bound Node*:
//     bind_scalar_func  NK_FUNC that is not an aggregate
//     bind_case         NK_CASE
//     bind_between      NK_BETWEEN (rewritten to AND / NOT comparisons)
//     bind_inlist       NK_IN
//     bind_like         NK_LIKE
// Evaluation entry points (called from eval.S eval), all
//   (x0 Node*, x1 EvalCtx*) -> x0 payload, x1 isnull:
//     ev_func, ev_case, ev_inlist, ev_like
// Exported helper:
//   common_type(w0 t1, w1 t2) -> w0 common type, or -1 if incompatible
//     (CASE / COALESCE rule, semantics.md §13: the null type is neutral,
//     numeric promotion INT64 < DECIMAL(18,max s) < FLOAT64, otherwise the
//     types must be identical; DATE and TIMESTAMP do not mix)
//
// Bound shapes (see pq.inc):
//   NK_FUNC  N_OP = FN_* id (bits 0-7) | parameter << 8 (DATE_TRUNC unit),
//            N_C = Node** bound args, N_VAL = argc, N_TYPE result type.
//            NULLIF stores [a, (a = b)] so that the comparison carries the
//            implicit casts; COALESCE / SQRT / POWER / DATE_TRUNC args are
//            wrapped in implicit casts to the type the evaluator expects.
//   NK_CASE  searched form [w1,t1,...] with every ti / ELSE cast to the
//            result type; simple CASE rewritten to x = vi comparisons.
//   NK_IN    N_C = bound comparisons x = ei (x shared), N_A = 0.
//   NK_LIKE  N_A string, N_B pattern.
//   BETWEEN  x >= a AND x <= b  [wrapped in NOT].
// NF_CONST is set on a node iff all of its children are constant (PQ_SLEEP
// never is). Function names are matched case-insensitively.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// ------------------------------------------------------------ function ids ---
// Ids below FN_STRICT handle NULL arguments themselves; for all others any
// NULL argument makes the result NULL (checked once in ev_func).
#define FN_CONCAT      1
#define FN_COALESCE    2
#define FN_NULLIF      3
#define FN_STRICT      4
#define FN_PQ_SLEEP    4
#define FN_ABS         5
#define FN_ROUND       6
#define FN_FLOOR       7
#define FN_CEIL        8
#define FN_SQRT        9
#define FN_POWER       10
#define FN_MOD         11
#define FN_LENGTH      12
#define FN_UPPER       13
#define FN_LOWER       14
#define FN_SUBSTR      15
#define FN_TRIM        16
#define FN_LTRIM       17
#define FN_RTRIM       18
#define FN_REPLACE     19
#define FN_YEAR        20
#define FN_MONTH       21
#define FN_DAY         22
#define FN_HOUR        23
#define FN_MINUTE      24
#define FN_SECOND      25
#define FN_DATE_TRUNC  26
#define FN_DATE_DIFF   27
#define FN_COUNT       28      // one past the last id (table sizes)

#define FN_ID_MASK     0xff
#define FN_PARAM_SHIFT 8

// Date units (DATE_TRUNC parameter). DATE_DIFF accepts only U_DAY.
#define U_DAY     0
#define U_YEAR    1
#define U_MONTH   2
#define U_HOUR    3
#define U_MINUTE  4
#define U_COUNT   5

// Argument kind masks: bit k set = type kind k accepted (the null type is
// always accepted).
#define M_BOOL   (1 << T_BOOL)
#define M_INT    (1 << T_INT)
#define M_DEC    (1 << T_DEC)
#define M_FLT    (1 << T_FLOAT)
#define M_STR    (1 << T_STR)
#define M_DATE   (1 << T_DATE)
#define M_TS     (1 << T_TS)
#define M_NUM    (M_INT | M_DEC | M_FLT)
#define M_DT     (M_DATE | M_TS)
#define M_ANY    0xfe
#define M_NOFLT  (M_ANY & ~M_FLT)

#define RES_SPECIAL 0xff       // result type computed by the bind hook
#define DEC18       (T_DEC | (18 << T_PREC_SHIFT))

// Function table entry (24 bytes)
#define FD_NAME   0            // NUL padded upper-case name (<= 15 chars)
#define FD_ID     16           // u8 FN_*
#define FD_MIN    17           // u8 minimum argc
#define FD_MAX    18           // u8 maximum argc (0 = unbounded)
#define FD_M0     19           // u8 kind mask of argument 1
#define FD_M1     20           // u8 argument 2
#define FD_M2     21           // u8 arguments 3.. (variadic: all further ones)
#define FD_RES    22           // u8 result type, or RES_SPECIAL
#define FD_SIZE   24

#define US_PER_SEC   1000000
#define US_PER_MIN   60000000
#define US_PER_HOUR  3600000000
#define US_PER_DAY   86400000000

.macro FDEF name, id, min, max, m0, m1, m2, res
9998:
    .ascii "\name"
    .org 9998b + 16, 0
    .byte \id, \min, \max, \m0, \m1, \m2, \res, 0
.endm

    .section .rodata
    .p2align 3
fn_table:
    FDEF "CONCAT",     FN_CONCAT,     1, 0, M_NOFLT, M_NOFLT, M_NOFLT, T_STR
    FDEF "COALESCE",   FN_COALESCE,   1, 0, M_ANY, M_ANY, M_ANY, RES_SPECIAL
    FDEF "NULLIF",     FN_NULLIF,     2, 2, M_ANY, M_ANY, 0, RES_SPECIAL
    FDEF "PQ_SLEEP",   FN_PQ_SLEEP,   1, 1, M_INT, 0, 0, T_INT
    FDEF "ABS",        FN_ABS,        1, 1, M_NUM, 0, 0, RES_SPECIAL
    FDEF "ROUND",      FN_ROUND,      1, 2, M_NUM, M_INT, 0, RES_SPECIAL
    FDEF "FLOOR",      FN_FLOOR,      1, 1, M_NUM, 0, 0, RES_SPECIAL
    FDEF "CEIL",       FN_CEIL,       1, 1, M_NUM, 0, 0, RES_SPECIAL
    FDEF "CEILING",    FN_CEIL,       1, 1, M_NUM, 0, 0, RES_SPECIAL
    FDEF "SQRT",       FN_SQRT,       1, 1, M_NUM, 0, 0, T_FLOAT
    FDEF "POWER",      FN_POWER,      2, 2, M_NUM, M_NUM, 0, T_FLOAT
    FDEF "MOD",        FN_MOD,        2, 2, M_INT, M_INT, 0, T_INT
    FDEF "LENGTH",     FN_LENGTH,     1, 1, M_STR, 0, 0, T_INT
    FDEF "UPPER",      FN_UPPER,      1, 1, M_STR, 0, 0, T_STR
    FDEF "LOWER",      FN_LOWER,      1, 1, M_STR, 0, 0, T_STR
    FDEF "SUBSTR",     FN_SUBSTR,     2, 3, M_STR, M_INT, M_INT, T_STR
    FDEF "SUBSTRING",  FN_SUBSTR,     2, 3, M_STR, M_INT, M_INT, T_STR
    FDEF "TRIM",       FN_TRIM,       1, 1, M_STR, 0, 0, T_STR
    FDEF "LTRIM",      FN_LTRIM,      1, 1, M_STR, 0, 0, T_STR
    FDEF "RTRIM",      FN_RTRIM,      1, 1, M_STR, 0, 0, T_STR
    FDEF "REPLACE",    FN_REPLACE,    3, 3, M_STR, M_STR, M_STR, T_STR
    FDEF "YEAR",       FN_YEAR,       1, 1, M_DT, 0, 0, T_INT
    FDEF "MONTH",      FN_MONTH,      1, 1, M_DT, 0, 0, T_INT
    FDEF "DAY",        FN_DAY,        1, 1, M_DT, 0, 0, T_INT
    FDEF "HOUR",       FN_HOUR,       1, 1, M_TS, 0, 0, T_INT
    FDEF "MINUTE",     FN_MINUTE,     1, 1, M_TS, 0, 0, T_INT
    FDEF "SECOND",     FN_SECOND,     1, 1, M_TS, 0, 0, T_INT
    FDEF "DATE_TRUNC", FN_DATE_TRUNC, 2, 2, M_STR, M_DT, 0, T_TS
    FDEF "DATE_DIFF",  FN_DATE_DIFF,  3, 3, M_STR, M_DT, M_DT, T_INT
    .byte 0                             // end marker (empty name)

    // unit names, indexed by U_*
    .p2align 3
unit_names:
    .quad s_day, s_year, s_month, s_hour, s_minute
s_day:      .asciz "day"
s_year:     .asciz "year"
s_month:    .asciz "month"
s_hour:     .asciz "hour"
s_minute:   .asciz "minute"
    .p2align 3
f64_two52:  .double 4503599627370496.0  // 2^52: larger doubles are integers
    .text

// =============================================================================
// common_type(w0 t1, w1 t2) -> w0 common type or -1                    (leaf)
// =============================================================================
FUNC common_type
    and  w9, w0, #T_KIND_MASK
    and  w10, w1, #T_KIND_MASK
    cbnz w9, 1f
    mov  w0, w1                         // null type is neutral
    ret
1:  cbz  w10, 9f                        // t2 null type: t1
    cmp  w9, w10
    b.ne 10f
    cmp  w9, #T_DEC                     // same kind: identical type, except
    b.ne 9f                             // DECIMALs -> DECIMAL(18, max s)
10:
    sub  w11, w9, #T_INT                // otherwise both must be numeric
    cmp  w11, #(T_FLOAT - T_INT)
    b.hi 8f
    sub  w11, w10, #T_INT
    cmp  w11, #(T_FLOAT - T_INT)
    b.hi 8f
    cmp  w9, #T_FLOAT
    ccmp w10, #T_FLOAT, #4, ne          // eq if either is FLOAT64
    b.ne 2f
    mov  w0, #T_FLOAT
    ret
2:  mov  w11, #0                        // INT64 / DECIMAL: DECIMAL(18, max s)
    cmp  w9, #T_DEC
    b.ne 3f
    ubfx w11, w0, #T_SCALE_SHIFT, #8
3:  mov  w12, #0
    cmp  w10, #T_DEC
    b.ne 4f
    ubfx w12, w1, #T_SCALE_SHIFT, #8
4:  cmp  w11, w12
    csel w11, w11, w12, hi
    mov  w12, #DEC_TYPE(DEC_MAX_PREC, 0) // W = 38 if a DECIMAL is wide
    BR_WIDE w0, w10, 5f
    BR_WIDE w1, w10, 5f
    mov  w12, #DEC18
5:  orr  w0, w12, w11, lsl #T_SCALE_SHIFT
    ret
8:  mov  w0, #-1
9:  ret
ENDF common_type

// =============================================================================
// Small binding helpers
// const_eval(x0 bound constant Node*) -> x0 payload, x1 isnull
// Evaluates with a zeroed EvalCtx (valid for NF_CONST expressions).
// =============================================================================
LFUNC const_eval
    ENTER 0
    sub  sp, sp, #EC_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    stp  xzr, xzr, [sp, #32]
    mov  x1, sp
    bl   eval
    add  sp, sp, #EC_SIZE
    LEAVE 0
ENDF const_eval

// cast_slot(x0 Node** slot, w1 type): *slot = implicit CAST(*slot AS type)
// unless it already has that type (null-typed nodes stay as they are).
//   x19 slot
LFUNC cast_slot
    ldr  x9, [x0]
    ldr  w10, [x9, #N_TYPE]
    cmp  w10, w1
    b.ne 1f
    ret
1:  ENTER 1
    mov  x19, x0
    mov  x0, x9
    bl   mk_cast
    str  x0, [x19]
    LEAVE 1
ENDF cast_slot

// const_flag(x0 Node*, w1 acc) -> w1 acc & (node flags & NF_CONST)      (leaf)
.macro ACC_CONST acc, node, tmp
    ldr  \tmp, [\node, #N_FLAGS]
    and  \acc, \acc, \tmp
.endm

// set_const(node, acc): node flags = (flags & ~NF_CONST) | (acc & NF_CONST)
.macro SET_CONST node, acc, tmp
    and  \acc, \acc, #NF_CONST
    ldr  \tmp, [\node, #N_FLAGS]
    bic  \tmp, \tmp, #NF_CONST
    orr  \tmp, \tmp, \acc
    str  \tmp, [\node, #N_FLAGS]
.endm

// bind_unit(x0 bound unit Node*, w1 number of accepted units) -> w0 U_* index
// The unit must be a constant STRING expression (SEMANTIC_ERROR otherwise;
// the type was checked by the caller). A NULL unit returns 0: the function
// then evaluates to NULL anyway. Unknown names raise INVALID_ARGUMENT.
//   x19 node, w20 accepted units, x21 unit Str*, w22 index
LFUNC bind_unit
    ENTER 3
    mov  x19, x0
    mov  w20, w1
    ldr  w9, [x19, #N_FLAGS]
    tbz  w9, #3, .Lbu_notconst          // NF_CONST == 8
    ldrb w9, [x19, #N_TYPE]
    cbz  w9, .Lbu_zero
    bl   const_eval
    cbnz x1, .Lbu_zero
    mov  x21, x0
    mov  w22, #0
1:  cmp  w22, w20
    b.hs .Lbu_unknown
    ADR_L x9, unit_names
    ldr  x1, [x9, w22, uxtw #3]
    mov  x0, x21
    bl   str_ieq_c
    cbnz w0, 2f
    add  w22, w22, #1
    b    1b
2:  mov  w0, w22
    LEAVE 3
.Lbu_zero:
    mov  w0, #0
    LEAVE 3
.Lbu_notconst:
    RAISE ERR_SEMANTIC, "date unit must be a constant"
.Lbu_unknown:
    RAISE_S ERR_INVALID_ARGUMENT, "unsupported date unit ", x21
ENDF bind_unit

// =============================================================================
// bind_scalar_func(x0 ctx, x1 Node*) -> x0 Node*
// Looks the function up, checks arity, binds and type-checks the arguments
// against the table masks, then runs the function specific hook (result
// type, constant arguments, implicit casts).
//   x19 ctx, x20 node, x21 table entry, x22 index, x23 argc, w24 NF_CONST
//   accumulator, x25 Node** args, w26 id / scratch, w27/x28 scratch
// =============================================================================
FUNC bind_scalar_func
    STACK_GUARD                         // CR-6: recursive
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    // ---- look the name up --------------------------------------------------
    ADR_L x21, fn_table
1:  ldrb w9, [x21]
    cbz  w9, .Lbsf_unknown
    ldr  x0, [x20, #N_NAME]
    mov  x1, x21
    bl   str_ieq_c
    cbnz w0, 2f
    add  x21, x21, #FD_SIZE
    b    1b
2:  ldrb w26, [x21, #FD_ID]
    cmp  w26, #FN_PQ_SLEEP              // test-only function
    b.ne 3f
    adrp x9, g_test_functions
    ldr  w9, [x9, :lo12:g_test_functions]
    cbz  w9, .Lbsf_unknown
3:  ldr  w9, [x20, #N_FLAGS]            // f(*) / f(DISTINCT ...)
    tst  w9, #(NF_STAR | NF_DISTINCT)
    b.ne .Lbsf_badargs
    ldr  x23, [x20, #N_VAL]             // arity
    ldrb w9, [x21, #FD_MIN]
    cmp  x23, x9
    b.lo .Lbsf_arity
    ldrb w9, [x21, #FD_MAX]
    cbz  w9, 4f
    cmp  x23, x9
    b.hi .Lbsf_arity
    // ---- bind and type-check the arguments ---------------------------------
4:  ldr  x25, [x20, #N_C]
    mov  w24, #NF_CONST
    mov  x22, #0
5:  cmp  x22, x23
    b.hs 7f
    mov  x0, x19
    ldr  x1, [x25, x22, lsl #3]
    bl   bind_expr
    str  x0, [x25, x22, lsl #3]
    ACC_CONST w24, x0, w9
    ldrb w9, [x0, #N_TYPE]              // kind
    cbz  w9, 6f                         // the null type fits everywhere
    mov  x10, #2                        // mask index min(i, 2)
    cmp  x22, x10
    csel x10, x22, x10, lo
    add  x10, x10, #FD_M0
    ldrb w10, [x21, x10]
    lsr  w10, w10, w9
    tbz  w10, #0, .Lbsf_argtype
6:  add  x22, x22, #1
    b    5b
7:  str  w26, [x20, #N_OP]
    ldrb w9, [x21, #FD_RES]
    str  w9, [x20, #N_TYPE]             // RES_SPECIAL is replaced by the hook
    // ---- function specific hook (indexed by id) ----------------------------
    adr  x9, .Lbsf_hooks
    add  x9, x9, x26, lsl #2
    br   x9
.Lbsf_hooks:
    b    .Lbsf_done                     // 0 (unused)
    b    .Lbsf_done                     // CONCAT
    b    .Lbsf_coalesce                 // COALESCE
    b    .Lbsf_nullif                   // NULLIF
    b    .Lbsf_sleep                    // PQ_SLEEP
    b    .Lbsf_abs                      // ABS
    b    .Lbsf_round                    // ROUND
    b    .Lbsf_floor                    // FLOOR
    b    .Lbsf_floor                    // CEIL
    b    .Lbsf_float1                   // SQRT
    b    .Lbsf_float2                   // POWER
    b    .Lbsf_done                     // MOD
    b    .Lbsf_done                     // LENGTH
    b    .Lbsf_done                     // UPPER
    b    .Lbsf_done                     // LOWER
    b    .Lbsf_done                     // SUBSTR
    b    .Lbsf_done                     // TRIM
    b    .Lbsf_done                     // LTRIM
    b    .Lbsf_done                     // RTRIM
    b    .Lbsf_done                     // REPLACE
    b    .Lbsf_done                     // YEAR
    b    .Lbsf_done                     // MONTH
    b    .Lbsf_done                     // DAY
    b    .Lbsf_done                     // HOUR
    b    .Lbsf_done                     // MINUTE
    b    .Lbsf_done                     // SECOND
    b    .Lbsf_date_trunc               // DATE_TRUNC
    b    .Lbsf_date_diff                // DATE_DIFF

.Lbsf_done:
    SET_CONST x20, w24, w9
    mov  x0, x20
    LEAVE 5

    // ---- COALESCE: common type of all arguments, each cast to it ----------
.Lbsf_coalesce:
    mov  w26, #T_NULL
    mov  x22, #0
1:  cmp  x22, x23
    b.hs 2f
    ldr  x9, [x25, x22, lsl #3]
    ldr  w1, [x9, #N_TYPE]
    mov  w0, w26
    bl   common_type
    tbnz w0, #31, .Lbsf_common
    mov  w26, w0
    add  x22, x22, #1
    b    1b
2:  str  w26, [x20, #N_TYPE]
    mov  x22, #0
3:  cmp  x22, x23
    b.hs .Lbsf_done
    add  x0, x25, x22, lsl #3
    mov  w1, w26
    bl   cast_slot
    add  x22, x22, #1
    b    3b

    // ---- NULLIF(a, b): args become [a, a = b]; result type of a ------------
.Lbsf_nullif:
    mov  w0, #OP_EQ
    ldr  x1, [x25]
    ldr  x2, [x25, #8]
    bl   make_compare                   // TYPE_ERROR if not comparable
    str  x0, [x25, #8]
    ldr  x9, [x25]
    ldr  w9, [x9, #N_TYPE]
    str  w9, [x20, #N_TYPE]
    b    .Lbsf_done

    // ---- PQ_SLEEP: has a side effect, never constant -----------------------
.Lbsf_sleep:
    mov  w24, #0
    b    .Lbsf_done

    // ---- ABS: same type (also the null type) ---------------------------------
.Lbsf_abs:
    ldr  x9, [x25]
    ldr  w9, [x9, #N_TYPE]
    str  w9, [x20, #N_TYPE]
    b    .Lbsf_done

    // ---- FLOOR / CEIL: INT64 -> INT64, DECIMAL -> DECIMAL(18,0), FLOAT64 ---
.Lbsf_floor:
    ldr  x9, [x25]
    ldrb w9, [x9, #N_TYPE]
    mov  w10, #T_INT
    cbnz w9, 0f
    mov  w10, #T_NULL                   // FLOOR(NULL): null type
0:  cmp  w9, #T_FLOAT
    b.ne 1f
    mov  w10, #T_FLOAT
1:  cmp  w9, #T_DEC
    b.ne 2f
    ldr  x9, [x25]                      // DECIMAL(p,s) -> DECIMAL(W,0)
    ldr  w0, [x9, #N_TYPE]
    mov  w1, w0
    bl   dec_wtype
    mov  w10, w0
2:  str  w10, [x20, #N_TYPE]
    b    .Lbsf_done

    // ---- ROUND(x [, n]): n constant; DECIMAL(p,s) -> DECIMAL(18, clamp(n,0,s))
.Lbsf_round:
    cmp  x23, #2
    b.lo 1f
    ldr  x9, [x25, #8]
    ldr  w10, [x9, #N_FLAGS]
    tbz  w10, #3, .Lbsf_notconst        // NF_CONST == 8
1:  ldr  x9, [x25]
    ldr  w27, [x9, #N_TYPE]
    and  w10, w27, #T_KIND_MASK
    cmp  w10, #T_DEC
    b.eq 2f
    mov  w11, #T_INT                    // INT64 -> INT64
    mov  w12, #T_FLOAT
    cmp  w10, #T_FLOAT
    csel w11, w12, w11, eq
    cmp  w10, #T_NULL                   // ROUND(NULL): null type
    csel w11, wzr, w11, eq
    str  w11, [x20, #N_TYPE]
    b    .Lbsf_done
2:  mov  x28, #0                        // n (NULL n: result is NULL anyway)
    cmp  x23, #2
    b.lo 3f
    ldr  x0, [x25, #8]
    bl   const_eval
    cbnz x1, 3f
    mov  x28, x0
3:  ubfx x9, x27, #T_SCALE_SHIFT, #8    // s
    cmp  x28, #0
    csel x10, xzr, x28, lt              // max(n, 0)
    cmp  x10, x9
    csel x10, x10, x9, lt               // min(.., s)
    str  x10, [sp, #-16]!
    mov  w0, w27                        // DECIMAL(W, ..)
    mov  w1, w27
    bl   dec_wtype
    ldr  x10, [sp], #16
    orr  w11, w0, w10, lsl #T_SCALE_SHIFT
    str  w11, [x20, #N_TYPE]
    b    .Lbsf_done

    // ---- SQRT / POWER: numeric arguments are evaluated as FLOAT64 ----------
.Lbsf_float2:
    add  x0, x25, #8
    mov  w1, #T_FLOAT
    bl   cast_slot
.Lbsf_float1:
    mov  x0, x25
    mov  w1, #T_FLOAT
    bl   cast_slot
    b    .Lbsf_done

    // ---- DATE_TRUNC(unit, t): unit constant; t evaluated as TIMESTAMP ------
.Lbsf_date_trunc:
    ldr  x0, [x25]
    mov  w1, #U_COUNT
    bl   bind_unit
    lsl  w0, w0, #FN_PARAM_SHIFT
    mov  w9, #FN_DATE_TRUNC
    orr  w0, w0, w9
    str  w0, [x20, #N_OP]
    add  x0, x25, #8
    mov  w1, #T_TS
    bl   cast_slot
    b    .Lbsf_done

    // ---- DATE_DIFF(unit, a, b): only 'day' --------------------------------
.Lbsf_date_diff:
    ldr  x0, [x25]
    mov  w1, #1                         // U_DAY only
    bl   bind_unit
    b    .Lbsf_done

.Lbsf_unknown:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "unknown function ", x9
.Lbsf_badargs:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "* and DISTINCT are not allowed in ", x9
.Lbsf_arity:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "wrong number of arguments for ", x9
.Lbsf_argtype:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_TYPE, "invalid argument type for ", x9
.Lbsf_common:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_TYPE, "arguments have no common type in ", x9
.Lbsf_notconst:
    ldr  x9, [x20, #N_NAME]
    RAISE_S ERR_SEMANTIC, "argument must be a constant in ", x9
ENDF bind_scalar_func

// =============================================================================
// bind_case(x0 ctx, x1 Node*) -> x0 Node*
//   x19 ctx, x20 node, x21 bound simple-CASE operand or 0, x22 pair index,
//   x23 pair count, x24 Node** [w1,t1,...], w25 NF_CONST accumulator,
//   w26 result type
// =============================================================================
FUNC bind_case
    STACK_GUARD                         // CR-6: recursive
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  w25, #NF_CONST
    ldr  x21, [x20, #N_A]
    cbz  x21, 1f
    mov  x1, x21                        // simple CASE: bind x once
    bl   bind_expr
    mov  x21, x0
1:  ldr  x24, [x20, #N_C]
    ldr  x23, [x20, #N_VAL]
    mov  x22, #0
.Lbcase_pair:
    cmp  x22, x23
    b.hs .Lbcase_else
    mov  x0, x19                        // WHEN
    add  x9, x24, x22, lsl #4
    ldr  x1, [x9]
    bl   bind_expr
    cbz  x21, 2f
    mov  x2, x0                         // simple form: x = vi
    mov  x1, x21
    mov  w0, #OP_EQ
    bl   make_compare
    b    3f
2:  ldrb w9, [x0, #N_TYPE]              // searched form: BOOLEAN or null type
    cmp  w9, #T_NULL
    ccmp w9, #T_BOOL, #4, ne
    b.ne .Lbcase_when_type
3:  add  x9, x24, x22, lsl #4
    str  x0, [x9]
    ACC_CONST w25, x0, w9
    add  x9, x24, x22, lsl #4           // THEN
    ldr  x1, [x9, #8]
    mov  x0, x19
    bl   bind_expr
    add  x9, x24, x22, lsl #4
    str  x0, [x9, #8]
    ACC_CONST w25, x0, w9
    add  x22, x22, #1
    b    .Lbcase_pair
.Lbcase_else:
    ldr  x1, [x20, #N_B]
    cbz  x1, 4f
    mov  x0, x19
    bl   bind_expr
    str  x0, [x20, #N_B]
    ACC_CONST w25, x0, w9
    // ---- result type: common type of all THEN results and ELSE -------------
4:  mov  w26, #T_NULL
    mov  x22, #0
5:  cmp  x22, x23
    b.hs 6f
    add  x9, x24, x22, lsl #4
    ldr  x9, [x9, #8]
    ldr  w1, [x9, #N_TYPE]
    mov  w0, w26
    bl   common_type
    tbnz w0, #31, .Lbcase_type
    mov  w26, w0
    add  x22, x22, #1
    b    5b
6:  ldr  x9, [x20, #N_B]
    cbz  x9, 7f
    ldr  w1, [x9, #N_TYPE]
    mov  w0, w26
    bl   common_type
    tbnz w0, #31, .Lbcase_type
    mov  w26, w0
    // ---- cast every result to the common type ------------------------------
7:  mov  x22, #0
8:  cmp  x22, x23
    b.hs 9f
    add  x0, x24, x22, lsl #4
    add  x0, x0, #8
    mov  w1, w26
    bl   cast_slot
    add  x22, x22, #1
    b    8b
9:  ldr  x9, [x20, #N_B]
    cbz  x9, 10f
    add  x0, x20, #N_B
    mov  w1, w26
    bl   cast_slot
10: str  xzr, [x20, #N_A]
    str  w26, [x20, #N_TYPE]
    SET_CONST x20, w25, w9
    mov  x0, x20
    LEAVE 5
.Lbcase_when_type:
    RAISE ERR_TYPE, "CASE WHEN condition must be BOOLEAN"
.Lbcase_type:
    RAISE ERR_TYPE, "CASE results have no common type"
ENDF bind_case

// =============================================================================
// new_logic(w0 kind, w1 op, x2 child A, x3 child B or 0, x4 position node)
//   -> x0 bound BOOLEAN node (NK_BINARY AND / NK_UNARY NOT); NF_CONST iff all
//   children are constant; line/column copied from the position node.
//   x19 A, x20 B, x21 position node, w22 kind, w23 op
// =============================================================================
LFUNC new_logic
    ENTER 3
    mov  w22, w0
    mov  w23, w1
    mov  x19, x2
    mov  x20, x3
    mov  x21, x4
    mov  x0, #N_SIZE
    bl   arena_zalloc
    str  w22, [x0, #N_KIND]
    str  w23, [x0, #N_OP]
    mov  w9, #T_BOOL
    str  w9, [x0, #N_TYPE]
    str  x19, [x0, #N_A]
    str  x20, [x0, #N_B]
    ldr  w9, [x19, #N_FLAGS]
    cbz  x20, 1f
    ldr  w10, [x20, #N_FLAGS]
    and  w9, w9, w10
1:  and  w9, w9, #NF_CONST
    str  w9, [x0, #N_FLAGS]
    ldr  x9, [x21, #N_LINE]             // line + column
    str  x9, [x0, #N_LINE]
    LEAVE 3
ENDF new_logic

// =============================================================================
// bind_between(x0 ctx, x1 Node*) -> x0 Node*
// x [NOT] BETWEEN a AND b  =>  [NOT] (x >= a AND x <= b), x bound once.
//   x19 ctx, x20 node, x21 x, x22 a / x >= a, x23 b / x <= b
// =============================================================================
FUNC bind_between
    STACK_GUARD                         // CR-6: recursive
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    mov  x21, x0
    mov  x0, x19
    ldr  x1, [x20, #N_B]
    bl   bind_expr
    mov  x22, x0
    mov  x0, x19
    ldr  x1, [x20, #N_C]
    bl   bind_expr
    mov  x23, x0
    mov  w0, #OP_GE
    mov  x1, x21
    mov  x2, x22
    bl   make_compare
    mov  x22, x0
    mov  w0, #OP_LE
    mov  x1, x21
    mov  x2, x23
    bl   make_compare
    mov  x3, x0
    mov  w0, #NK_BINARY
    mov  w1, #OP_AND
    mov  x2, x22
    mov  x4, x20
    bl   new_logic
    ldr  w9, [x20, #N_OP]
    cbz  w9, 1f
    mov  x2, x0                         // NOT BETWEEN
    mov  w0, #NK_UNARY
    mov  w1, #OP_NOT
    mov  x3, #0
    mov  x4, x20
    bl   new_logic
1:  LEAVE 3
ENDF bind_between

// =============================================================================
// bind_inlist(x0 ctx, x1 Node*) -> x0 Node*
// x [NOT] IN (e1, ...): N_C[i] becomes the bound comparison x = ei.
//   x19 ctx, x20 node, x21 bound x, x22 index, x23 count, x24 Node**,
//   w25 NF_CONST accumulator
// =============================================================================
FUNC bind_inlist
    STACK_GUARD                         // CR-6: recursive
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    mov  x21, x0
    ldr  x24, [x20, #N_C]
    ldr  x23, [x20, #N_VAL]
    mov  w25, #NF_CONST
    ACC_CONST w25, x21, w9
    mov  x22, #0
1:  cmp  x22, x23
    b.hs 2f
    mov  x0, x19
    ldr  x1, [x24, x22, lsl #3]
    bl   bind_expr
    mov  x2, x0
    mov  x1, x21
    mov  w0, #OP_EQ
    bl   make_compare                   // TYPE_ERROR if not comparable
    str  x0, [x24, x22, lsl #3]
    ACC_CONST w25, x0, w9
    add  x22, x22, #1
    b    1b
2:  str  xzr, [x20, #N_A]
    mov  w9, #T_BOOL
    str  w9, [x20, #N_TYPE]
    SET_CONST x20, w25, w9
    mov  x0, x20
    LEAVE 4
ENDF bind_inlist

// =============================================================================
// bind_like(x0 ctx, x1 Node*) -> x0 Node*   (STRING / null type operands)
//   x19 ctx, x20 node, x21 bound string
// =============================================================================
FUNC bind_like
    STACK_GUARD                         // CR-6: recursive
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x1, [x20, #N_A]
    bl   bind_expr
    mov  x21, x0
    str  x21, [x20, #N_A]
    mov  x0, x19
    ldr  x1, [x20, #N_B]
    bl   bind_expr
    str  x0, [x20, #N_B]
    ldrb w9, [x21, #N_TYPE]
    cmp  w9, #T_NULL
    ccmp w9, #T_STR, #4, ne
    b.ne .Lblike_type
    ldrb w9, [x0, #N_TYPE]
    cmp  w9, #T_NULL
    ccmp w9, #T_STR, #4, ne
    b.ne .Lblike_type
    mov  w9, #T_BOOL
    str  w9, [x20, #N_TYPE]
    ldr  w10, [x21, #N_FLAGS]
    ldr  w11, [x0, #N_FLAGS]
    and  w10, w10, w11
    SET_CONST x20, w10, w9
    mov  x0, x20
    LEAVE 2
.Lblike_type:
    RAISE ERR_TYPE, "LIKE requires STRING operands"
ENDF bind_like

// =============================================================================
// Evaluation helpers
// floor_divmod(x0 a, x1 d > 0) -> x0 floor(a / d), x1 a - q*d in [0, d) (leaf)
// =============================================================================
LFUNC floor_divmod
    sdiv x2, x0, x1
    msub x3, x2, x1, x0
    tbz  x3, #63, 1f
    sub  x2, x2, #1
    add  x3, x3, x1
1:  mov  x0, x2
    mov  x1, x3
    ret
ENDF floor_divmod

// day_number(x0 payload, w1 type) -> x0 days since epoch of a DATE or the
// date part of a TIMESTAMP (floor division, also before 1970).
LFUNC day_number
    and  w9, w1, #T_KIND_MASK
    cmp  w9, #T_TS
    b.eq 1f
    ret
1:  ldr  x1, =US_PER_DAY
    b    floor_divmod
ENDF day_number

// =============================================================================
// round_int(x0 v, x1 n) -> x0   ROUND(INT64, n): n >= 0 is the identity,
// otherwise round half away from zero to a multiple of 10^-n.
//   x19 m = -n, x20 rounded quotient
// =============================================================================
LFUNC round_int
    tbz  x1, #63, 9f                    // n >= 0
    neg  x1, x1                         // m (INT64_MIN stays "huge" unsigned)
    cmp  x1, #20
    b.hs 8f                             // |v| < 0.5 * 10^20: always 0
    cmp  x1, #19
    b.ne 1f
    cmp  x0, #0                         // 10^19: |v| >= 5*10^18 overflows
    cneg x9, x0, lt
    ldr  x10, =5000000000000000000
    cmp  x9, x10
    b.hs raise_overflow
    b    8f
1:  ENTER 2
    mov  x19, x1
    mov  w2, #0                         // q = v / 10^m rounded
    bl   dec_rescale
    mov  x20, x0
    mov  w0, w19
    bl   pow10_i64
    mul  x10, x20, x0                   // q * 10^m, overflow checked
    smulh x11, x20, x0
    cmp  x11, x10, asr #63
    b.ne raise_overflow
    mov  x0, x10
    LEAVE 2
8:  mov  x0, #0
9:  ret
ENDF round_int

// =============================================================================
// round_dec(x0 v, w1 s, x2 n) -> x0 unscaled at scale max(0, min(n, s))
//   x19 m = -n (n < 0)
// =============================================================================
LFUNC round_dec
    uxtw x1, w1
    cmp  x2, x1
    b.ge 9f                             // n >= s: unchanged
    tbnz x2, #63, 1f
    b    dec_rescale                    // 0 <= n < s (scale down, no overflow)
1:  neg  x9, x2                         // m
    add  x10, x1, x9                    // k = s + m: divide by 10^k
    cmp  x9, #40                        // (also guards INT64_MIN)
    b.hi 8f
    cmp  x10, #18
    b.hi 8f                             // |v| < 10^18 <= 0.5 * 10^k
    ENTER 1
    mov  x19, x9
    mov  w1, w10
    mov  w2, #0
    bl   dec_rescale
    cbz  x0, 2f
    mov  w1, #0                         // * 10^m (at most 18 digits)
    mov  w2, w19
    bl   dec_rescale
    cbnz w1, raise_overflow
2:  LEAVE 1
8:  mov  x0, #0
9:  ret
ENDF round_dec

// =============================================================================
// round_f64(d0 x, x0 n) -> d0   ROUND(FLOAT64, n), half away from zero
// (frinta). n is clamped to [-400, 400]; requested digits beyond the
// precision of x leave it unchanged; a non-finite result raises overflow.
// Stack: [sp] x, [sp+8] power of ten
// =============================================================================
LFUNC round_f64
    cbnz x0, 1f
    frinta d0, d0
    ret
1:  ENTER 0
    sub  sp, sp, #16
    str  d0, [sp]
    mov  x9, #400
    cmp  x0, x9
    csel x0, x0, x9, lt
    neg  x9, x9
    cmp  x0, x9
    csel x0, x0, x9, gt
    tbnz x0, #63, 3f
    // ---- n > 0: round(x * 10^n) / 10^n
    fabs d1, d0
    ADR_L x9, f64_two52
    ldr  d2, [x9]
    fcmp d1, d2
    b.ge 9f                             // already an integer
    scvtf d1, x0
    fmov d0, #10.0
    bl   pow
    ldr  d1, [sp]
    fmul d1, d1, d0
    fmov x9, d1
    ubfx x9, x9, #52, #11
    cmp  x9, #0x7ff
    b.eq 9f                             // more digits than x has: unchanged
    frinta d1, d1
    fdiv d0, d1, d0
    b    10f
    // ---- n < 0: round(x / 10^-n) * 10^-n
3:  neg  x0, x0
    scvtf d1, x0
    fmov d0, #10.0
    bl   pow
    fmov x9, d0
    ubfx x9, x9, #52, #11
    cmp  x9, #0x7ff
    b.eq 8f                             // 10^m = inf: |x| rounds to 0
    ldr  d1, [sp]
    fdiv d1, d1, d0
    frinta d1, d1
    fmul d0, d1, d0
    fmov x9, d0
    ubfx x9, x9, #52, #11
    cmp  x9, #0x7ff
    b.eq raise_overflow
    b    10f
8:  movi d0, #0
    b    10f
9:  ldr  d0, [sp]
10: add  sp, sp, #16
    LEAVE 0
ENDF round_f64

// =============================================================================
// ev_func(x0 Node*, x1 EvalCtx*) -> x0 payload, x1 isnull
// Strict functions get their (at most three) arguments evaluated up front;
// any NULL makes the result NULL. Then a branch table dispatches on the id.
//   x19 node, x20 ctx, x21/x22/x23 argument payloads, x24 scratch,
//   x25 Node** args, w26 id, x27 argc, x28 scratch
// Stack: 16 bytes scratch (struct timespec for PQ_SLEEP)
// =============================================================================
FUNC ev_func
    ENTER 5
    sub  sp, sp, #16
    mov  x19, x0
    mov  x20, x1
    ldr  w26, [x19, #N_OP]
    and  w26, w26, #FN_ID_MASK
    cmp  w26, #FN_COUNT
    b.hs .Lev_bad
    ldr  x25, [x19, #N_C]
    ldr  x27, [x19, #N_VAL]
    cmp  w26, #FN_STRICT
    b.lo .Lev_dispatch
    mov  x22, #0
    mov  x23, #0
    ldr  x0, [x25]
    mov  x1, x20
    bl   eval
    cbnz x1, .Lev_null
    mov  x21, x0
    cmp  x27, #2
    b.lo .Lev_dispatch
    ldr  x0, [x25, #8]
    mov  x1, x20
    bl   eval
    cbnz x1, .Lev_null
    mov  x22, x0
    cmp  x27, #3
    b.lo .Lev_dispatch
    ldr  x0, [x25, #16]
    mov  x1, x20
    bl   eval
    cbnz x1, .Lev_null
    mov  x23, x0
.Lev_dispatch:
    adr  x9, .Lev_table
    add  x9, x9, x26, lsl #2
    br   x9
.Lev_table:
    b    .Lev_bad                       // 0 (unused)
    b    .Lev_concat
    b    .Lev_coalesce
    b    .Lev_nullif
    b    .Lev_sleep
    b    .Lev_abs
    b    .Lev_round
    b    .Lev_floor
    b    .Lev_ceil
    b    .Lev_sqrt
    b    .Lev_power
    b    .Lev_mod
    b    .Lev_length
    b    .Lev_upper
    b    .Lev_lower
    b    .Lev_substr
    b    .Lev_trim
    b    .Lev_ltrim
    b    .Lev_rtrim
    b    .Lev_replace
    b    .Lev_ymd                       // YEAR
    b    .Lev_ymd                       // MONTH
    b    .Lev_ymd                       // DAY
    b    .Lev_hms                       // HOUR
    b    .Lev_hms                       // MINUTE
    b    .Lev_hms                       // SECOND
    b    .Lev_date_trunc
    b    .Lev_date_diff

.Lev_ret:                               // x0 = payload
    mov  x1, #0
    add  sp, sp, #16
    LEAVE 5
.Lev_null:
    mov  x0, #0
    mov  x1, #1
    add  sp, sp, #16
    LEAVE 5
.Lev_bad:
    RAISE ERR_INTERNAL, "eval: unknown function"

// arg kind of argument i into w9
.macro ARG_KIND i
    ldr  x9, [x25, #(8 * \i)]
    ldrb w9, [x9, #N_TYPE]
.endm

    // ---- CONCAT: STRING casts of the non-NULL arguments --------------------
.Lev_concat:
    lsl  x0, x27, #3
    bl   arena_alloc
    mov  x24, x0                        // Str* per argument (0 = NULL)
    mov  x28, #0
1:  cmp  x28, x27
    b.hs 3f
    ldr  x0, [x25, x28, lsl #3]
    mov  x1, x20
    bl   eval
    cbnz x1, 2f
    ldr  x9, [x25, x28, lsl #3]
    ldr  w1, [x9, #N_TYPE]
    bl   value_to_str
    str  x0, [x24, x28, lsl #3]
    add  x28, x28, #1
    b    1b
2:  str  xzr, [x24, x28, lsl #3]
    add  x28, x28, #1
    b    1b
3:  mov  x0, x24
    mov  x1, x27
    bl   str_concat_n
    b    .Lev_ret

    // ---- COALESCE: first non-NULL argument ---------------------------------
.Lev_coalesce:
    mov  x28, #0
1:  cmp  x28, x27
    b.hs .Lev_null
    ldr  x0, [x25, x28, lsl #3]
    mov  x1, x20
    bl   eval
    cbz  x1, .Lev_ret
    add  x28, x28, #1
    b    1b

    // ---- NULLIF: args [a, a = b] -------------------------------------------
.Lev_nullif:
    ldr  x0, [x25, #8]
    mov  x1, x20
    bl   eval
    cbnz x1, 1f
    cbnz x0, .Lev_null                  // a = b is TRUE
1:  ldr  x0, [x25]
    mov  x1, x20
    bl   eval
    add  sp, sp, #16
    LEAVE 5

    // ---- PQ_SLEEP(ms): sleeps in slices of at most 10 ms, calling
    // check_deadline between slices; returns ms. x24 ms, x28 target (µs)
.Lev_sleep:
    mov  x24, x21
    cmp  x24, #0
    b.le 2f
    ldr  x9, =1000000000000             // clamp to ~31 years (no overflow)
    cmp  x24, x9
    csel x28, x24, x9, lt
    mov  x9, #1000
    mul  x28, x28, x9                   // duration in µs
    bl   now_us
    add  x28, x28, x0                   // target
1:  bl   check_deadline                 // raises TIMEOUT
    bl   now_us
    cmp  x0, x28
    b.hs 2f
    sub  x9, x28, x0                    // remaining µs, at most 10 000 per slice
    mov  x10, #10000
    cmp  x9, x10
    csel x9, x9, x10, lo
    mov  x10, #1000
    mul  x9, x9, x10                    // ns
    stp  xzr, x9, [sp]                  // tv_sec = 0, tv_nsec
    mov  x0, sp
    mov  x1, #0
    bl   nanosleep
    b    1b
2:  mov  x0, x24
    b    .Lev_ret

    // ---- ABS ----------------------------------------------------------------
.Lev_abs:
    ARG_KIND 0
    cmp  w9, #T_FLOAT
    b.ne 1f
    and  x0, x21, #0x7fffffffffffffff   // clear the sign bit
    b    .Lev_ret
1:  ldr  x9, [x25]
    ldr  w1, [x9, #N_TYPE]
    mov  x0, x21
    BR_WIDE w1, w9, 3f
    cmp  x21, #0                        // INT64 / DECIMAL
    cneg x0, x21, lt
    tbnz x0, #63, 2f                    // |INT64_MIN|
    b    .Lev_ret
2:  b    raise_overflow
3:  bl   dec_abs                        // wide DECIMAL
    b    .Lev_ret

    // ---- ROUND(x [, n]) -----------------------------------------------------
.Lev_round:
    cmp  x27, #2
    csel x1, x22, xzr, eq               // n (default 0)
    ldr  x9, [x25]
    ldr  w10, [x9, #N_TYPE]
    and  w9, w10, #T_KIND_MASK
    cmp  w9, #T_FLOAT
    b.eq 1f
    cmp  w9, #T_DEC
    b.eq 2f
    mov  x0, x21                        // INT64
    bl   round_int
    b    .Lev_ret
1:  fmov d0, x21
    mov  x0, x1
    bl   round_f64
    fmov x0, d0
    b    .Lev_ret
2:  mov  x2, x1
    BR_WIDE w10, w9, 3f
    ldr  w9, [x19, #N_TYPE]
    BR_WIDE w9, w11, 3f
    ubfx w1, w10, #T_SCALE_SHIFT, #8
    mov  x0, x21
    bl   round_dec
    b    .Lev_ret
3:  mov  x0, x21                        // wide argument or result
    mov  w1, w10
    ldr  w3, [x19, #N_TYPE]
    bl   dec_round
    b    .Lev_ret

    // ---- FLOOR / CEIL (w28 = 1 for CEIL) -----------------------------------
.Lev_floor:
    mov  w28, #0
    b    1f
.Lev_ceil:
    mov  w28, #1
1:  ldr  x9, [x25]
    ldr  w10, [x9, #N_TYPE]
    and  w9, w10, #T_KIND_MASK
    cmp  w9, #T_FLOAT
    b.eq 3f
    mov  x0, x21
    cmp  w9, #T_DEC
    b.ne .Lev_ret                       // INT64: identity
    BR_WIDE w10, w9, 6f
    ubfx w0, w10, #T_SCALE_SHIFT, #8    // DECIMAL(p,s) -> DECIMAL(18,0)
    bl   pow10_i64
    sdiv x9, x21, x0                    // truncated quotient
    msub x10, x9, x0, x21               // remainder (sign of x)
    cbnz w28, 2f
    cmp  x10, #0                        // floor: negative remainder => -1
    cinc x9, x9, ge
    sub  x0, x9, #1
    b    .Lev_ret
2:  cmp  x10, #0                        // ceil: positive remainder => +1
    cinc x0, x9, gt
    b    .Lev_ret
3:  fmov d0, x21
    cbnz w28, 4f
    frintm d0, d0
    b    5f
4:  frintp d0, d0
5:  fmov x0, d0
    b    .Lev_ret
6:  mov  x0, x21                        // wide: DECIMAL(38,0)
    mov  w1, w10
    mov  w2, w28
    ldr  w3, [x19, #N_TYPE]
    bl   dec_floorceil
    b    .Lev_ret

    // ---- SQRT (argument cast to FLOAT64 by the binder) ---------------------
.Lev_sqrt:
    fmov d0, x21
    fcmp d0, #0.0
    b.mi .Lev_sqrt_neg
    fsqrt d0, d0
    fmov x0, d0
    b    .Lev_ret
.Lev_sqrt_neg:
    RAISE ERR_INVALID_ARGUMENT, "SQRT of a negative number"

    // ---- POWER(x, y) (both FLOAT64) ----------------------------------------
.Lev_power:
    fmov d0, x21
    fmov d1, x22
    fcmp d0, #0.0
    b.ne 1f
    fcmp d1, #0.0                       // 0 ^ negative
    b.mi raise_div0
    b    2f
1:  b.pl 2f                             // positive base
    frintz d2, d1                       // negative base: integral exponent
    fcmp d2, d1
    b.ne .Lev_power_arg
2:  bl   pow
    fmov x0, d0
    ubfx x9, x0, #52, #11
    cmp  x9, #0x7ff
    b.eq raise_overflow                 // non-finite result
    b    .Lev_ret
.Lev_power_arg:
    RAISE ERR_INVALID_ARGUMENT, "POWER of a negative base with a non-integral exponent"

    // ---- MOD(a, b) == a % b ------------------------------------------------
.Lev_mod:
    mov  x0, x21
    mov  x1, x22
    mov  w2, #OP_MOD
    bl   arith_int
    b    .Lev_ret

    // ---- string functions --------------------------------------------------
.Lev_length:
    add  x0, x21, #STR_DATA
    ldr  x1, [x21, #STR_LEN]
    bl   utf8_len
    b    .Lev_ret
.Lev_upper:
    mov  w1, #1
    b    1f
.Lev_lower:
    mov  w1, #0
1:  mov  x0, x21
    bl   str_casemap
    b    .Lev_ret
.Lev_substr:
    cmp  x27, #3
    cset w3, eq
    mov  x0, x21
    mov  x1, x22
    mov  x2, x23
    bl   str_substr
    b    .Lev_ret
.Lev_trim:
    mov  w1, #3
    b    1f
.Lev_ltrim:
    mov  w1, #1
    b    1f
.Lev_rtrim:
    mov  w1, #2
1:  mov  x0, x21
    bl   str_trim
    b    .Lev_ret
.Lev_replace:
    mov  x0, x21
    mov  x1, x22
    mov  x2, x23
    bl   str_replace
    b    .Lev_ret

    // ---- YEAR / MONTH / DAY (DATE or TIMESTAMP) ----------------------------
.Lev_ymd:
    mov  x0, x21
    ldr  x9, [x25]
    ldr  w1, [x9, #N_TYPE]
    bl   day_number
    bl   civil_from_days                // x0 y, x1 m, x2 d
    cmp  w26, #FN_MONTH
    csel x0, x1, x0, eq
    cmp  w26, #FN_DAY
    csel x0, x2, x0, eq
    b    .Lev_ret

    // ---- HOUR / MINUTE / SECOND (TIMESTAMP) --------------------------------
.Lev_hms:
    mov  x0, x21
    ldr  x1, =US_PER_DAY
    bl   floor_divmod                   // x1 = µs since midnight
    ldr  x9, =US_PER_HOUR
    cmp  w26, #FN_HOUR
    b.eq 1f
    ldr  x9, =US_PER_MIN
    cmp  w26, #FN_MINUTE
    b.eq 1f
    ldr  x9, =US_PER_SEC
1:  udiv x0, x1, x9
    mov  x10, #60                       // minutes / seconds: modulo 60
    udiv x11, x0, x10
    msub x11, x11, x10, x0
    cmp  w26, #FN_HOUR
    csel x0, x0, x11, eq
    b    .Lev_ret

    // ---- DATE_TRUNC(unit, t): t is a TIMESTAMP (cast by the binder) --------
.Lev_date_trunc:
    ldr  w9, [x19, #N_OP]
    ubfx w28, w9, #FN_PARAM_SHIFT, #8
    cmp  w28, #U_YEAR
    b.eq 2f
    cmp  w28, #U_MONTH
    b.eq 2f
    ldr  x24, =US_PER_DAY               // day / hour / minute: floor to unit
    cmp  w28, #U_HOUR
    b.ne 1f
    ldr  x24, =US_PER_HOUR
1:  cmp  w28, #U_MINUTE
    b.ne 11f
    ldr  x24, =US_PER_MIN
11: mov  x0, x22
    mov  x1, x24
    bl   floor_divmod
    mul  x0, x0, x24
    b    .Lev_ret
2:  mov  x0, x22                        // year / month: via the calendar
    ldr  x1, =US_PER_DAY
    bl   floor_divmod
    bl   civil_from_days
    cmp  w28, #U_YEAR
    mov  x9, #1
    csel x1, x9, x1, eq                 // January for 'year'
    mov  x2, #1
    bl   days_from_civil
    ldr  x9, =US_PER_DAY
    mul  x0, x0, x9
    b    .Lev_ret

    // ---- DATE_DIFF('day', a, b) = days(b) - days(a) ------------------------
.Lev_date_diff:
    mov  x0, x22
    ldr  x9, [x25, #8]
    ldr  w1, [x9, #N_TYPE]
    bl   day_number
    mov  x24, x0
    mov  x0, x23
    ldr  x9, [x25, #16]
    ldr  w1, [x9, #N_TYPE]
    bl   day_number
    sub  x0, x0, x24
    b    .Lev_ret
ENDF ev_func

// =============================================================================
// ev_case: first WHEN that is TRUE selects its result; else ELSE or NULL.
//   x19 node, x20 ctx, x21 pair index, x22 pair count, x23 Node** pairs
// =============================================================================
FUNC ev_case
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x23, [x19, #N_C]
    ldr  x22, [x19, #N_VAL]
    mov  x21, #0
1:  cmp  x21, x22
    b.hs 3f
    add  x9, x23, x21, lsl #4
    ldr  x0, [x9]
    mov  x1, x20
    bl   eval
    cbnz x1, 2f                         // NULL is not TRUE
    cbnz x0, 4f
2:  add  x21, x21, #1
    b    1b
3:  ldr  x0, [x19, #N_B]                // ELSE
    cbz  x0, 5f
    b    6f
4:  add  x9, x23, x21, lsl #4           // THEN i
    ldr  x0, [x9, #8]
6:  mov  x1, x20
    LEAVE_NORET 3
    b    eval                           // tail call
5:  mov  x1, #1
    LEAVE 3
ENDF ev_case

// =============================================================================
// ev_inlist: any comparison TRUE => TRUE; else any NULL => NULL; else FALSE.
// NOT IN negates a non-NULL result.
//   x19 node, x20 ctx, x21 index, x22 count, x23 saw NULL, x24 Node**
// =============================================================================
FUNC ev_inlist
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ldr  x24, [x19, #N_C]
    ldr  x22, [x19, #N_VAL]
    mov  x21, #0
    mov  x23, #0
1:  cmp  x21, x22
    b.hs 3f
    ldr  x0, [x24, x21, lsl #3]
    mov  x1, x20
    bl   eval
    orr  x23, x23, x1
    cbnz x1, 2f
    cbnz x0, 4f                         // found
2:  add  x21, x21, #1
    b    1b
3:  cbnz x23, 5f
    mov  x0, #0
    b    6f
4:  mov  x0, #1
6:  ldr  w9, [x19, #N_OP]               // NOT IN
    eor  x0, x0, x9
    mov  x1, #0
    LEAVE 4
5:  mov  x0, #0
    mov  x1, #1
    LEAVE 4
ENDF ev_inlist

// =============================================================================
// ev_like: s [NOT] LIKE p (NULL operand => NULL)
//   x19 node, x20 ctx, x21 string
// =============================================================================
FUNC ev_like
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #N_A]
    bl   eval
    cbnz x1, 1f
    mov  x21, x0
    ldr  x0, [x19, #N_B]
    mov  x1, x20
    bl   eval
    cbnz x1, 1f
    add  x2, x0, #STR_DATA
    ldr  x3, [x0, #STR_LEN]
    add  x0, x21, #STR_DATA
    ldr  x1, [x21, #STR_LEN]
    bl   like_match
    ldr  w9, [x19, #N_OP]               // NOT LIKE
    eor  w0, w0, w9
    mov  x1, #0
    LEAVE 2
1:  mov  x0, #0
    mov  x1, #1
    LEAVE 2
ENDF ev_like

    .ltorg
    NOTE_GNU_STACK
