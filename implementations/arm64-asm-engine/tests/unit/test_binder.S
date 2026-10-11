// =============================================================================
// test_binder.S — unit tests for binder.S and eval.S.
//
// Each test case is a SQL text run through parse_sql -> bind_query and then
// checked according to its mode (value of the first output column, LIMIT,
// output names, ORDER BY keys, ...) or an expected error code. Queries with
// FROM use the hand-built table `t` registered with catalog_add:
//
//   row | i    d(10,2)  f     s      b      dt     big        ts
//   0   | 1    1.50     0.5   'abc'  true   0      INT64_MAX  0
//   1   | 2    -0.25    2.0   'b'    false  1      1          86400000000
//   2   | NULL NULL     NULL  NULL   NULL   NULL   NULL       NULL
//   3   | -5   10.00    -1.5  ''     true   19000  -1         -1
//
// Queries are planned (plan_statement) and executed (exec_plan); the first
// result row is checked. Exit status 0 iff all pass.
// =============================================================================
#include "pq.inc"

#define D(p,s) (3|((p)<<8)|((s)<<16))

// Case record
#define TC_SQL    0
#define TC_CODE   8
#define TC_TYPE   12
#define TC_VAL    16
#define TC_NULL   24
#define TC_MODE   28
#define TC_SIZE   32

// Modes
#define M_VAL     0     // first output column: type, isnull, payload
#define M_STR     1     // like M_VAL, payload compared as string (cstr)
#define M_LIMIT   2     // BQ_LIMIT == val
#define M_OFFSET  3     // BQ_OFFSET == val
#define M_NAME0   4     // name of output column 1 == cstr
#define M_NAMEL   5     // name of the last output column == cstr
#define M_NOUT    6     // BQ_NOUT == val
#define M_KEY0    7     // ORDER BY key 0: cell == val, nulls-first == null field
#define M_TIMEOUT 8     // run with a 30 ms deadline (expects ERR_TIMEOUT)

// TC sql, code, type, val, isnull, mode — integer payload
.macro TC sql, code=0, type=0, val=0, isnull=0, mode=M_VAL
    .section .rodata
9990: .asciz "\sql"
    .section .data.cases, "aw"
    .quad 9990b
    .word \code, \type
    .quad \val
    .word \isnull, \mode
.endm
// TCF: FLOAT64 payload
.macro TCF sql, fval
    .section .rodata
9990: .asciz "\sql"
    .section .data.cases, "aw"
    .quad 9990b
    .word 0, T_FLOAT
    .double \fval
    .word 0, M_VAL
.endm
// TCS: string payload (modes M_STR / M_NAME0 / M_NAMEL)
.macro TCS sql, sval, mode=M_STR, type=T_STR
    .section .rodata
9990: .asciz "\sql"
9991: .asciz "\sval"
    .section .data.cases, "aw"
    .quad 9990b
    .word 0, \type
    .quad 9991b
    .word 0, \mode
.endm
// TE sql, code — expected error
.macro TE sql, code
    TC "\sql", \code, 0, 0, 0, M_VAL
.endm

// ------------------------------------------------------------- test table ---
.macro PSTR label, text
    .p2align 3
\label: .quad 9992f - 9993f
9993: .ascii "\text"
9992: .byte 0
.endm

    .data
    .p2align 4
tbl_t:
    .quad s_t, 8, 4, cols_t
    .skip TBL_SIZE - TBL_ARENA
cols_t:
    .quad s_i;   .word T_INT, 0;      .quad d_i,   nulls
    .quad s_d;   .word D(10,2), 0;    .quad d_d,   nulls
    .quad s_f;   .word T_FLOAT, 0;    .quad d_f,   nulls
    .quad s_s;   .word T_STR, 0;      .quad d_s,   nulls
    .quad s_b;   .word T_BOOL, 0;     .quad d_b,   nulls
    .quad s_dt;  .word T_DATE, 0;     .quad d_dt,  nulls
    .quad s_big; .word T_INT, 0;      .quad d_big, nulls
    .quad s_ts;  .word T_TS, 0;       .quad d_ts,  nulls
d_i:    .quad 1, 2, 0, -5
d_d:    .quad 150, -25, 0, 1000
d_f:    .double 0.5, 2.0, 0.0, -1.5
d_s:    .quad s_abc, s_b1, 0, s_empty
d_b:    .quad 1, 0, 0, 1
d_dt:   .quad 0, 1, 0, 19000
d_big:  .quad 0x7fffffffffffffff, 1, 0, -1
d_ts:   .quad 0, 86400000000, 0, -1
nulls:  .byte 0x04, 0, 0, 0     // null bitmap: row 2 is NULL
    PSTR s_t, "t"
    PSTR s_i, "i"
    PSTR s_d, "d"
    PSTR s_f, "f"
    PSTR s_s, "s"
    PSTR s_b, "b"
    PSTR s_dt, "dt"
    PSTR s_big, "big"
    PSTR s_ts, "ts"
    PSTR s_abc, "abc"
    PSTR s_b1, "b"
    PSTR s_empty, ""

// --------------------------------------------------------------- results ----
    .bss
    .p2align 3
r_code: .skip 8         // error code raised (0 none, -1 no qualifying row)
r_val:  .skip 8
r_null: .skip 8
r_type: .skip 8

// ------------------------------------------------------------------ cases ---
    .section .data.cases, "aw"
    .p2align 3
cases_start:
    // --- literals and integer arithmetic
    TC  "SELECT 1", 0, T_INT, 1
    TC  "SELECT 1.50", 0, D(3,2), 150
    TC  "SELECT NULL", 0, T_NULL, 0, 1
    TC  "SELECT 2 + 3 * 4", 0, T_INT, 14
    TC  "SELECT (2 + 3) * 4", 0, T_INT, 20
    TC  "SELECT 7 / 2", 0, T_INT, 3
    TC  "SELECT -7 / 2", 0, T_INT, -3
    TC  "SELECT 7 % 3", 0, T_INT, 1
    TC  "SELECT -7 % 3", 0, T_INT, -1
    TC  "SELECT 7 % -3", 0, T_INT, 1
    TC  "SELECT - - 1", 0, T_INT, 1
    TC  "SELECT -2 * 3", 0, T_INT, -6
    TE  "SELECT 1 / 0", ERR_DIVISION_BY_ZERO
    TE  "SELECT 1 % 0", ERR_DIVISION_BY_ZERO
    TE  "SELECT 9223372036854775807 + 1", ERR_NUMERIC_OVERFLOW
    TE  "SELECT -9223372036854775808 - 1", ERR_NUMERIC_OVERFLOW
    TE  "SELECT 4611686018427387904 * 2", ERR_NUMERIC_OVERFLOW
    TE  "SELECT 3037000500 * 3037000500", ERR_NUMERIC_OVERFLOW
    TC  "SELECT -3037000499 * 3037000499", 0, T_INT, -9223372030926249001
    TC  "SELECT -4611686018427387904 * 2", 0, T_INT, 0x8000000000000000
    TE  "SELECT -9223372036854775808 / -1", ERR_NUMERIC_OVERFLOW
    TE  "SELECT -(-9223372036854775808)", ERR_NUMERIC_OVERFLOW
    TC  "SELECT -9223372036854775808 % -1", 0, T_INT, 0
    TC  "SELECT NULL / 0", 0, T_INT, 0, 1
    TC  "SELECT 1 + NULL", 0, T_INT, 0, 1
    TC  "SELECT NULL + NULL", 0, T_INT, 0, 1
    TC  "SELECT -NULL", 0, T_NULL, 0, 1
    // --- decimal arithmetic
    TC  "SELECT 1.25 + 2.5", 0, D(18,2), 375
    TC  "SELECT 1.25 - 2.5", 0, D(18,2), -125
    TC  "SELECT 1.25 * 2.5", 0, D(18,3), 3125
    TC  "SELECT 1.5 * 2", 0, D(18,1), 30
    TC  "SELECT 2 - 0.75", 0, D(18,2), 125
    TC  "SELECT -2.50", 0, D(3,2), -250
    TCF "SELECT 10.00 / 4", 2.5
    TC  "SELECT 0.1 + 0.2 = 0.3", 0, T_BOOL, 1
    TC  "SELECT 0.10 = 0.1", 0, T_BOOL, 1
    TC  "SELECT 999999999999999999. > 0.5", 0, T_BOOL, 1
    TC  "SELECT 100000000000000000. - 99999999999999999.9", 0, D(18,1), 1
    TC  "SELECT NULL + 1.5", 0, D(18,1), 0, 1
    TE  "SELECT 999999999999999999 * 10.0", ERR_NUMERIC_OVERFLOW
    TE  "SELECT 99999999999999999.9 + 0.1", ERR_NUMERIC_OVERFLOW
    TE  "SELECT 1.5 / 0", ERR_DIVISION_BY_ZERO
    TE  "SELECT 1.5 % 2", ERR_TYPE
    TE  "SELECT 0.000000001 * 0.0000000001", ERR_TYPE
    // --- float arithmetic
    TCF "SELECT 1e0 / 4", 0.25
    TCF "SELECT 1.5 + 1e0", 2.5
    TCF "SELECT 2 * 1e1", 20.0
    TCF "SELECT -1e0", -1.0
    TE  "SELECT 1e0 / 0", ERR_DIVISION_BY_ZERO
    TE  "SELECT 0e0 / 0e0", ERR_DIVISION_BY_ZERO
    TE  "SELECT 1e308 * 10", ERR_NUMERIC_OVERFLOW
    TE  "SELECT 1e0 % 2", ERR_TYPE
    // --- comparisons
    TC  "SELECT 1 = 1.0", 0, T_BOOL, 1
    TC  "SELECT 1 < 1.5", 0, T_BOOL, 1
    TC  "SELECT 2 > 1e0", 0, T_BOOL, 1
    TC  "SELECT 'a' < 'b'", 0, T_BOOL, 1
    TC  "SELECT 'B' < 'a'", 0, T_BOOL, 1
    TC  "SELECT 'ab' < 'abc'", 0, T_BOOL, 1
    TC  "SELECT 'abc' >= 'abd'", 0, T_BOOL, 0
    TC  "SELECT FALSE < TRUE", 0, T_BOOL, 1
    TC  "SELECT 3 <> 3", 0, T_BOOL, 0
    TC  "SELECT 3 <= 3", 0, T_BOOL, 1
    TC  "SELECT DATE '2024-01-01' < TIMESTAMP '2024-01-01 00:00:01'", 0, T_BOOL, 1
    TC  "SELECT DATE '2024-01-01' = TIMESTAMP '2024-01-01 00:00:00'", 0, T_BOOL, 1
    TC  "SELECT NULL = 'x'", 0, T_BOOL, 0, 1
    TE  "SELECT 1 = '1'", ERR_TYPE
    TE  "SELECT 'a' + 1", ERR_TYPE
    TE  "SELECT TRUE + 1", ERR_TYPE
    TE  "SELECT DATE '2024-01-01' + 1", ERR_TYPE
    TE  "SELECT DATE '2024-01-01' = '2024-01-01'", ERR_TYPE
    TE  "SELECT TRUE < 1", ERR_TYPE
    TE  "SELECT 1 AND TRUE", ERR_TYPE
    TE  "SELECT NOT 'x'", ERR_TYPE
    TE  "SELECT 'a' || 1", ERR_TYPE
    TE  "SELECT -'a'", ERR_TYPE
    // --- three-valued logic
    TC  "SELECT NULL AND FALSE", 0, T_BOOL, 0
    TC  "SELECT FALSE AND NULL", 0, T_BOOL, 0
    TC  "SELECT NULL AND TRUE", 0, T_BOOL, 0, 1
    TC  "SELECT NULL OR TRUE", 0, T_BOOL, 1
    TC  "SELECT TRUE OR NULL", 0, T_BOOL, 1
    TC  "SELECT NULL OR FALSE", 0, T_BOOL, 0, 1
    TC  "SELECT TRUE AND TRUE", 0, T_BOOL, 1
    TC  "SELECT FALSE OR FALSE", 0, T_BOOL, 0
    TC  "SELECT NOT NULL", 0, T_BOOL, 0, 1
    TC  "SELECT NOT FALSE", 0, T_BOOL, 1
    TC  "SELECT NULL = NULL", 0, T_BOOL, 0, 1
    TC  "SELECT NULL IS NULL", 0, T_BOOL, 1
    TC  "SELECT 1 IS NULL", 0, T_BOOL, 0
    TC  "SELECT 1 IS NOT NULL", 0, T_BOOL, 1
    // --- strings and CAST
    TCS "SELECT 'ab' || 'cd'", "abcd"
    TC  "SELECT 'ab' || NULL", 0, T_STR, 0, 1
    TC  "SELECT CAST(TRUE AS INT64)", 0, T_INT, 1
    TC  "SELECT CAST(2 AS DECIMAL(5,2))", 0, D(5,2), 200
    TC  "SELECT CAST(NULL AS INT64)", 0, T_INT, 0, 1
    TCS "SELECT CAST(42 AS STRING)", "42"
    TE  "SELECT CAST(1000 AS DECIMAL(3,0))", ERR_NUMERIC_OVERFLOW
    TE  "SELECT CAST(DATE '2024-01-01' AS INT64)", ERR_TYPE
    TE  "SELECT CAST(1 AS DATE)", ERR_TYPE
    // --- functions
    TE  "SELECT FOO(1)", ERR_SEMANTIC
    TC  "SELECT PQ_SLEEP(5)", 0, T_INT, 5
    TC  "SELECT pq_sleep(NULL)", 0, T_INT, 0, 1
    TE  "SELECT PQ_SLEEP('a')", ERR_TYPE
    TE  "SELECT PQ_SLEEP(1, 2)", ERR_SEMANTIC
    TC  "SELECT PQ_SLEEP(5000)", ERR_TIMEOUT, 0, 0, 0, M_TIMEOUT
    TC  "SELECT (SELECT 1)", 0, T_INT, 1
    TC  "SELECT DISTINCT 1", 0, T_INT, 1
    TC  "SELECT i FROM t GROUP BY i", 0, T_INT, 0, 1
    TC  "SELECT COUNT(DISTINCT i) FROM t", 0, T_INT, 3
    TE  "SELECT i FROM t a JOIN t b ON TRUE", ERR_SEMANTIC
    TE  "SELECT *", ERR_SEMANTIC
    // --- WHERE / LIMIT / OFFSET
    TC  "SELECT 2 WHERE TRUE", 0, T_INT, 2
    TC  "SELECT 2 WHERE 1 = 2", -1, T_INT, 0
    TE  "SELECT 1 WHERE 1", ERR_TYPE
    TC  "SELECT 1 LIMIT 2 + 1", 0, 0, 3, 0, M_LIMIT
    TC  "SELECT 1", 0, 0, -1, 0, M_LIMIT
    TC  "SELECT 1 LIMIT NULL", 0, 0, -1, 0, M_LIMIT
    TC  "SELECT 1 OFFSET 5", 0, 0, 5, 0, M_OFFSET
    TC  "SELECT 1 LIMIT 3", 0, 0, 0, 0, M_OFFSET
    TE  "SELECT 1 LIMIT -1", ERR_INVALID_ARGUMENT
    TE  "SELECT 1 OFFSET -1", ERR_INVALID_ARGUMENT
    TE  "SELECT i FROM t LIMIT i", ERR_SEMANTIC
    TE  "SELECT 1 LIMIT COUNT(*)", ERR_SEMANTIC
    TE  "SELECT 1 LIMIT 1.5", ERR_TYPE
    TE  "SELECT 1 LIMIT 1 / 0", ERR_DIVISION_BY_ZERO
    // --- table queries: resolution and row values
    TC  "SELECT i FROM t", 0, T_INT, 1
    TC  "SELECT i FROM t WHERE i < 0", 0, T_INT, -5
    TC  "SELECT t.i FROM t WHERE t.i = 2", 0, T_INT, 2
    TC  "SELECT x.i FROM t x WHERE x.i = 2", 0, T_INT, 2
    TC  "SELECT I FROM T WHERE I IS NULL", 0, T_INT, 0, 1
    TE  "SELECT t.i FROM t x", ERR_SEMANTIC
    TE  "SELECT q FROM t", ERR_SEMANTIC
    TE  "SELECT i FROM nope", ERR_SEMANTIC
    TE  "SELECT q.* FROM t", ERR_SEMANTIC
    TE  "SELECT i FROM t WHERE s", ERR_TYPE
    TE  "SELECT i FROM t WHERE s = 1", ERR_TYPE
    TE  "SELECT i FROM t WHERE COUNT(*) > 1", ERR_SEMANTIC
    TC  "SELECT d + 1 FROM t", 0, D(18,2), 250
    TC  "SELECT d * d FROM t", 0, D(18,4), 22500
    TC  "SELECT d < 1 FROM t", 0, T_BOOL, 0
    TCF "SELECT f * 2 FROM t", 1.0
    TCF "SELECT i + f FROM t", 1.5
    TCF "SELECT d + f FROM t", 2.0
    TCS "SELECT s FROM t WHERE s = 'b'", "b"
    TCS "SELECT s || s FROM t", "abcabc"
    TC  "SELECT b AND i > 0 FROM t WHERE i IS NULL", 0, T_BOOL, 0, 1
    TC  "SELECT b OR i > 0 FROM t WHERE i = 2", 0, T_BOOL, 1
    TC  "SELECT dt FROM t WHERE dt > DATE '2000-01-01'", 0, T_DATE, 19000
    TC  "SELECT dt = TIMESTAMP '1970-01-02 00:00:00' FROM t WHERE i = 2", 0, T_BOOL, 1
    TC  "SELECT ts = dt FROM t WHERE i = 2", 0, T_BOOL, 1
    TC  "SELECT ts < dt FROM t WHERE i = -5", 0, T_BOOL, 1
    TC  "SELECT -i FROM t WHERE i = -5", 0, T_INT, 5
    // --- output names / expansion
    TCS "SELECT I FROM T", "i", M_NAME0
    TCS "SELECT i AS foo FROM t", "foo", M_NAME0
    TCS "SELECT t.big FROM t", "big", M_NAME0
    TCS "SELECT i + 1 FROM t", "_col1", M_NAME0
    TCS "SELECT *, i + 1 FROM t", "_col9", M_NAMEL
    TCS "SELECT t.*, 1 FROM t", "_col9", M_NAMEL
    TCS "SELECT 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12", "_col12", M_NAMEL
    TCS "SELECT * FROM t", "ts", M_NAMEL
    TC  "SELECT * FROM t", 0, 0, 8, 0, M_NOUT
    TC  "SELECT *, * FROM t", 0, 0, 16, 0, M_NOUT
    // --- aggregates
    TC  "SELECT COUNT(*) FROM t", 0, T_INT, 4
    TC  "SELECT COUNT(i) FROM t", 0, T_INT, 3
    TC  "SELECT SUM(i) FROM t", 0, T_INT, -2
    TC  "SELECT MIN(i) FROM t", 0, T_INT, -5
    TC  "SELECT MAX(i) FROM t", 0, T_INT, 2
    TCF "SELECT AVG(i) FROM t", -0.6666666666666666
    TC  "SELECT SUM(d) FROM t", 0, D(18,2), 1125
    TC  "SELECT MIN(d) FROM t", 0, D(10,2), -25
    TCF "SELECT AVG(d) FROM t", 3.75
    TCF "SELECT SUM(f) FROM t", 1.0
    TCF "SELECT AVG(f) FROM t", 0.3333333333333333
    TCS "SELECT MAX(s) FROM t", "b"
    TCS "SELECT MIN(s) FROM t", ""
    TC  "SELECT MIN(b) FROM t", 0, T_BOOL, 0
    TC  "SELECT MAX(b) FROM t", 0, T_BOOL, 1
    TC  "SELECT MAX(ts) FROM t", 0, T_TS, 86400000000
    TC  "SELECT SUM(big) FROM t", 0, T_INT, 0x7fffffffffffffff
    TE  "SELECT SUM(big) FROM t WHERE i > 0", ERR_NUMERIC_OVERFLOW
    TC  "SELECT COUNT(*) FROM t WHERE i > 100", 0, T_INT, 0
    TC  "SELECT SUM(i) FROM t WHERE i > 100", 0, T_INT, 0, 1
    TC  "SELECT AVG(i) FROM t WHERE i > 100", 0, T_FLOAT, 0, 1
    TC  "SELECT MIN(s) FROM t WHERE i > 100", 0, T_STR, 0, 1
    TC  "SELECT MAX(i) - MIN(i) FROM t", 0, T_INT, 7
    TC  "SELECT COUNT(*) + 1 FROM t", 0, T_INT, 5
    TC  "SELECT SUM(i * 2) FROM t", 0, T_INT, -4
    TC  "SELECT SUM(d) * 2 FROM t", 0, D(18,2), 2250
    TC  "SELECT COUNT(*)", 0, T_INT, 1
    TC  "SELECT SUM(NULL)", 0, T_INT, 0, 1
    TCS "SELECT COUNT(*), MAX(i) FROM t", "_col2", M_NAMEL
    TE  "SELECT i, COUNT(*) FROM t", ERR_SEMANTIC
    TE  "SELECT SUM(COUNT(*)) FROM t", ERR_SEMANTIC
    TE  "SELECT SUM(s) FROM t", ERR_TYPE
    TE  "SELECT AVG(dt) FROM t", ERR_TYPE
    TE  "SELECT SUM(*) FROM t", ERR_SEMANTIC
    TE  "SELECT COUNT() FROM t", ERR_SEMANTIC
    TE  "SELECT COUNT(i, i) FROM t", ERR_SEMANTIC
    TE  "SELECT COUNT(*) FROM t ORDER BY i", ERR_SEMANTIC
    TE  "SELECT i FROM t ORDER BY COUNT(*)", ERR_SEMANTIC
    // --- ORDER BY
    TE  "SELECT i FROM t ORDER BY 2", ERR_SEMANTIC
    TE  "SELECT i FROM t ORDER BY 0", ERR_SEMANTIC
    TC  "SELECT i, s FROM t ORDER BY 2", 0, 0, 1, 1, M_KEY0
    TC  "SELECT i AS x FROM t ORDER BY x DESC", 0, 0, 0, 0, M_KEY0
    TC  "SELECT i FROM t ORDER BY s", 0, 0, 1, 1, M_KEY0
    TC  "SELECT i FROM t ORDER BY t.i", 0, 0, 0, 1, M_KEY0      // same as output column
    TC  "SELECT i, i FROM t ORDER BY I", 0, 0, 0, 1, M_KEY0
    TC  "SELECT i FROM t ORDER BY i NULLS LAST", 0, 0, 0, 0, M_KEY0
    TC  "SELECT i FROM t ORDER BY i DESC NULLS FIRST", 0, 0, 0, 1, M_KEY0
    TC  "SELECT COUNT(*) AS n FROM t ORDER BY n", 0, 0, 0, 1, M_KEY0
    TC  "SELECT COUNT(*) FROM t ORDER BY SUM(i)", 0, 0, 1, 1, M_KEY0
    TE  "SELECT i AS a, s AS a FROM t ORDER BY a", ERR_SEMANTIC
    TE  "SELECT i FROM t ORDER BY nope", ERR_SEMANTIC
cases_end:

    .section .rodata
fmt_fail1:  .asciz "FAIL: %s\n"
fmt_fail2:  .asciz "   expected code=%d type=%#x null=%d val=%#llx\n"
fmt_fail3:  .asciz "   got      code=%d type=%#x null=%d val=%#llx\n"
fmt_sum:    .asciz "test_binder: %d/%d passed\n"
    .text

// =============================================================================

// str_eq_c(x0 Str*, x1 cstr) -> w0 1 if byte-equal
//   x19 Str*, x20 cstr
LFUNC str_eq_c
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
    mov  x0, x1
    bl   strlen
    ldr  x9, [x19, #STR_LEN]
    cmp  x0, x9
    b.ne 1f
    mov  x2, x0
    add  x0, x19, #STR_DATA
    mov  x1, x20
    bl   memcmp
    cmp  w0, #0
    cset w0, eq
    b    2f
1:  mov  w0, #0
2:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF str_eq_c

// =============================================================================
// run_case(x0 case*) -> w0 1 pass / 0 fail
// setjmp(g_jmpbuf) catches errors raised anywhere below. Only x19 (set before
// setjmp and never modified afterwards) is used after a longjmp.
//   x19 case, x20 BoundQuery*, x21 row index, x22 row count, x23 agg state,
//   x24 out column 0
// Stack: EvalCtx at [sp, #0]
// =============================================================================
LFUNC run_case
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    sub  sp, sp, #32
    mov  x19, x0
    ADR_L x9, r_code
    stp  xzr, xzr, [x9]
    stp  xzr, xzr, [x9, #16]
    ldr  w9, [x19, #TC_MODE]
    cmp  w9, #M_TIMEOUT
    b.ne 1f
    bl   now_us
    mov  x9, #30000
    add  x0, x0, x9
    TLS_ADDR x9, g_deadline
    str  x0, [x9]
1:  TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lrc_error

    ldr  x20, [x19, #TC_SQL]
    mov  x0, x20
    bl   strlen
    mov  x1, x0
    mov  x0, x20
    bl   parse_sql
    ldr  x0, [x0, #ST_QUERY]
    bl   bind_query
    mov  x20, x0

    ldr  w9, [x19, #TC_MODE]
    cmp  w9, #M_LIMIT
    b.eq .Lrc_limit
    cmp  w9, #M_OFFSET
    b.eq .Lrc_offset
    cmp  w9, #M_NAME0
    b.eq .Lrc_name0
    cmp  w9, #M_NAMEL
    b.eq .Lrc_namel
    cmp  w9, #M_NOUT
    b.eq .Lrc_nout
    cmp  w9, #M_KEY0
    b.eq .Lrc_key0

    // ---- plan and execute; check output column 0 of the first row ---------
    ldr  x9, [x20, #BQ_OUT]
    ldr  w9, [x9, #OC_TYPE]
    ADR_L x10, r_type
    str  x9, [x10]
    mov  x0, x20
    bl   plan_statement
    mov  x1, #0
    bl   exec_plan
    ldr  x9, [x0, #RS_NROWS]
    cbz  x9, .Lrc_norow
    ldr  x9, [x0, #RS_ROWS]
    ldr  x9, [x9]
    ldp  x0, x1, [x9]
    ADR_L x9, r_val
    str  x0, [x9]
    ADR_L x9, r_null
    str  x1, [x9]
    b    .Lrc_check_value
.Lrc_norow:
    mov  x9, #-1
    ADR_L x10, r_code
    str  x9, [x10]
    b    .Lrc_check_code

    // ---- error raised --------------------------------------------------------
.Lrc_error:
    TLS_ADDR x9, g_err_code
    ldr  w9, [x9]
    ADR_L x10, r_code
    str  x9, [x10]
.Lrc_check_code:                        // pass iff the code matches
    ADR_L x10, r_code
    ldr  x9, [x10]
    ldrsw x10, [x19, #TC_CODE]
    cmp  x9, x10
    b.ne .Lrc_fail
    b    .Lrc_pass

.Lrc_check_value:
    ldr  w10, [x19, #TC_CODE]
    cbnz w10, .Lrc_fail                 // expected an error
    ADR_L x9, r_type
    ldr  x9, [x9]
    ldr  w10, [x19, #TC_TYPE]
    cmp  x9, x10
    b.ne .Lrc_fail
    ADR_L x9, r_null
    ldr  x9, [x9]
    ldr  w10, [x19, #TC_NULL]
    cmp  x9, x10
    b.ne .Lrc_fail
    cbnz x9, .Lrc_pass                  // NULL: payload irrelevant
    ADR_L x9, r_val
    ldr  x0, [x9]
    ldr  x1, [x19, #TC_VAL]
    ldr  w9, [x19, #TC_MODE]
    cmp  w9, #M_STR
    b.eq .Lrc_cmp_str
    cmp  x0, x1
    b.ne .Lrc_fail
    b    .Lrc_pass

.Lrc_limit:
    ldr  x0, [x20, #BQ_LIMIT]
    b    .Lrc_cmp_int
.Lrc_offset:
    ldr  x0, [x20, #BQ_OFFSET]
    b    .Lrc_cmp_int
.Lrc_nout:
    ldr  x0, [x20, #BQ_NOUT]
    b    .Lrc_cmp_int
.Lrc_key0:
    ldr  x9, [x20, #BQ_ORDER]
    ldr  x0, [x9, #OK_CELL]
    ldr  w10, [x9, #OK_NFIRST]
    ADR_L x11, r_null
    str  x10, [x11]
    ldr  w11, [x19, #TC_NULL]
    cmp  w10, w11
    b.ne .Lrc_fail
.Lrc_cmp_int:
    ADR_L x9, r_val
    str  x0, [x9]
    ldr  w10, [x19, #TC_CODE]
    cbnz w10, .Lrc_fail
    ldr  x1, [x19, #TC_VAL]
    cmp  x0, x1
    b.ne .Lrc_fail
    b    .Lrc_pass
.Lrc_name0:
    ldr  x9, [x20, #BQ_OUT]
    ldr  x0, [x9, #OC_NAME]
    b    .Lrc_name
.Lrc_namel:
    ldr  x9, [x20, #BQ_OUT]
    ldr  x10, [x20, #BQ_NOUT]
    sub  x10, x10, #1
    add  x9, x9, x10, lsl #5
    ldr  x0, [x9, #OC_NAME]
.Lrc_name:
    ldr  w10, [x19, #TC_CODE]
    cbnz w10, .Lrc_fail
    ldr  x1, [x19, #TC_VAL]
.Lrc_cmp_str:
    ADR_L x9, r_val
    str  x0, [x9]
    bl   str_eq_c
    cbz  w0, .Lrc_fail
.Lrc_pass:
    mov  w0, #1
    b    .Lrc_ret
.Lrc_fail:
    ADR_L x0, fmt_fail1
    ldr  x1, [x19, #TC_SQL]
    bl   printf
    ADR_L x0, fmt_fail2
    ldr  w1, [x19, #TC_CODE]
    ldr  w2, [x19, #TC_TYPE]
    ldr  w3, [x19, #TC_NULL]
    ldr  x4, [x19, #TC_VAL]
    bl   printf
    ADR_L x0, fmt_fail3
    ADR_L x9, r_code
    ldr  x1, [x9]
    ldr  x2, [x9, #24]                  // r_type
    ldr  x3, [x9, #16]                  // r_null
    ldr  x4, [x9, #8]                   // r_val
    bl   printf
    mov  w0, #0
.Lrc_ret:
    add  sp, sp, #32
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret
ENDF run_case

// =============================================================================
// main — runs every case; exit status 0 iff all pass.
//   x19 case cursor, x20 end, x21 failures, x22 total
// =============================================================================
FUNC main
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    ADR_L x9, g_test_functions
    mov  w10, #1
    str  w10, [x9]
    ADR_L x0, tbl_t
    bl   catalog_add
    ADR_L x19, cases_start
    ADR_L x20, cases_end
    mov  x21, #0
    mov  x22, #0
1:  cmp  x19, x20
    b.hs 2f
    mov  x0, x19
    bl   run_case
    cmp  w0, #0
    cinc x21, x21, eq
    add  x22, x22, #1
    TLS_ADDR x9, g_deadline
    str  xzr, [x9]
    TLS_ADDR x0, g_arena
    bl   arena_free
    add  x19, x19, #TC_SIZE
    b    1b
2:  ADR_L x0, fmt_sum
    sub  x1, x22, x21
    mov  x2, x22
    bl   printf
    mov  x0, #0                         // fflush(NULL): all streams
    bl   fflush
    cmp  x21, #0
    cset w0, ne
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret
ENDF main

    NOTE_GNU_STACK
