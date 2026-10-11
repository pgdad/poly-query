// =============================================================================
// test_functions.S — unit tests for functions.S / strfuncs.S: scalar
// functions, CASE, LIKE, BETWEEN, IN lists and common_type.
//
// Each test case is a SQL text run through parse_sql -> bind_query; then the
// first output column is evaluated on the first row passing WHERE (or once,
// without FROM) and compared with the expected type / null flag / payload,
// or an expected error code is checked. Other modes inspect the bound tree.
// Queries with FROM use the hand-built table `t`:
//
//   row | i     d(10,2)  f     s         dt          ts
//   0   | 1     1.50     0.5   'abc'     1970-01-01  1970-01-01 00:00:00
//   1   | 2     -0.25    2.0   'héllo'   1969-12-31  1969-12-31 23:59:59.999999
//   2   | NULL  NULL     NULL  NULL      NULL        NULL
//   3   | -5    10.00    -1.5  '  x  '   2022-01-08  2024-02-29 12:34:56.789012
//
// A second table of (t1, t2, expected) triples checks common_type directly.
// Exit status 0 iff all cases pass.
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
#define M_KIND    2     // N_KIND of the bound output expression == val
#define M_CONST   3     // (N_FLAGS & NF_CONST) of the bound output expression == val
#define M_SHAPE   4     // bound output expression has N_A == 0 (CASE / IN)

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
// TCF: FLOAT64 payload (compared bit for bit)
.macro TCF sql, fval
    .section .rodata
9990: .asciz "\sql"
    .section .data.cases, "aw"
    .quad 9990b
    .word 0, T_FLOAT
    .double \fval
    .word 0, M_VAL
.endm
// TCS: STRING payload
.macro TCS sql, sval, type=T_STR
    .section .rodata
9990: .asciz "\sql"
9991: .asciz "\sval"
    .section .data.cases, "aw"
    .quad 9990b
    .word 0, \type
    .quad 9991b
    .word 0, M_STR
.endm
// TN sql, type — NULL result of the given type
.macro TN sql, type
    TC "\sql", 0, \type, 0, 1
.endm
// TE sql, code — expected error
.macro TE sql, code
    TC "\sql", \code, 0, 0, 0, M_VAL
.endm
// CT t1, t2, expected — common_type case
.macro CT t1, t2, res
    .section .data.ct, "aw"
    .word \t1, \t2, \res, 0
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
    .quad s_t, 6, 4, cols_t
    .skip AR_SIZE
cols_t:
    .quad s_i;   .word T_INT, 0;      .quad d_i,   nulls
    .quad s_d;   .word D(10,2), 0;    .quad d_d,   nulls
    .quad s_f;   .word T_FLOAT, 0;    .quad d_f,   nulls
    .quad s_s;   .word T_STR, 0;      .quad d_s,   nulls
    .quad s_dt;  .word T_DATE, 0;     .quad d_dt,  nulls
    .quad s_ts;  .word T_TS, 0;       .quad d_ts,  nulls
d_i:    .quad 1, 2, 0, -5
d_d:    .quad 150, -25, 0, 1000
d_f:    .double 0.5, 2.0, 0.0, -1.5
d_s:    .quad s_abc, s_hello, 0, s_spaced
d_dt:   .quad 0, -1, 0, 19000
d_ts:   .quad 0, -1, 0, 1709210096789012
nulls:  .byte 0, 0, 1, 0
    PSTR s_t, "t"
    PSTR s_i, "i"
    PSTR s_d, "d"
    PSTR s_f, "f"
    PSTR s_s, "s"
    PSTR s_dt, "dt"
    PSTR s_ts, "ts"
    PSTR s_abc, "abc"
    PSTR s_hello, "héllo"
    PSTR s_spaced, "  x  "

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
    // --- name lookup, arity, * / DISTINCT
    TE  "SELECT NO_SUCH_FUNCTION(1)", ERR_SEMANTIC
    TE  "SELECT LENGTH()", ERR_SEMANTIC
    TE  "SELECT LENGTH('a', 'b')", ERR_SEMANTIC
    TE  "SELECT LENGTH(*)", ERR_SEMANTIC
    TE  "SELECT UPPER(DISTINCT 'a')", ERR_SEMANTIC
    TE  "SELECT CONCAT()", ERR_SEMANTIC
    TE  "SELECT ROUND(1, 2, 3)", ERR_SEMANTIC
    TC  "SELECT length('abc')", 0, T_INT, 3
    TC  "SELECT LeNgTh('abc')", 0, T_INT, 3
    // --- ABS
    TC  "SELECT ABS(-5)", 0, T_INT, 5
    TC  "SELECT ABS(-2.50)", 0, D(3,2), 250
    TCF "SELECT ABS(-1.5e0)", 1.5
    TCF "SELECT ABS(-0.0e0)", 0.0
    TC  "SELECT ABS(9223372036854775807)", 0, T_INT, 0x7fffffffffffffff
    TE  "SELECT ABS(-9223372036854775808)", ERR_NUMERIC_OVERFLOW
    TN  "SELECT ABS(NULL)", T_INT
    TC  "SELECT ABS(d) FROM t WHERE i = 2", 0, D(10,2), 25
    TE  "SELECT ABS('a')", ERR_TYPE
    TE  "SELECT ABS(TRUE)", ERR_TYPE
    // --- ROUND
    TC  "SELECT ROUND(2.5)", 0, D(18,0), 3
    TC  "SELECT ROUND(-2.5)", 0, D(18,0), -3
    TC  "SELECT ROUND(2.345, 2)", 0, D(18,2), 235
    TC  "SELECT ROUND(-2.345, 2)", 0, D(18,2), -235
    TC  "SELECT ROUND(2.5, 5)", 0, D(18,1), 25
    TC  "SELECT ROUND(1234.5678, -2)", 0, D(18,0), 1200
    TC  "SELECT ROUND(-1250.0, -2)", 0, D(18,0), -1300
    TC  "SELECT ROUND(5555.5, -4)", 0, D(18,0), 10000
    TC  "SELECT ROUND(0.5555, -3)", 0, D(18,0), 0
    TC  "SELECT ROUND(1.5, -40)", 0, D(18,0), 0
    TC  "SELECT ROUND(99999999999999999.9)", 0, D(18,0), 100000000000000000
    TE  "SELECT ROUND(999999999999999999., -1)", ERR_NUMERIC_OVERFLOW
    TC  "SELECT ROUND(15, -1)", 0, T_INT, 20
    TC  "SELECT ROUND(-15, -1)", 0, T_INT, -20
    TC  "SELECT ROUND(14, -1)", 0, T_INT, 10
    TC  "SELECT ROUND(7)", 0, T_INT, 7
    TC  "SELECT ROUND(7, 3)", 0, T_INT, 7
    TC  "SELECT ROUND(-9223372036854775808, -18)", 0, T_INT, -9000000000000000000
    TE  "SELECT ROUND(9223372036854775807, -1)", ERR_NUMERIC_OVERFLOW
    TE  "SELECT ROUND(-9223372036854775808, -19)", ERR_NUMERIC_OVERFLOW
    TC  "SELECT ROUND(4999999999999999999, -19)", 0, T_INT, 0
    TC  "SELECT ROUND(123, -25)", 0, T_INT, 0
    TCF "SELECT ROUND(1.26e0, 1)", 1.3
    TCF "SELECT ROUND(2.5e0)", 3.0
    TCF "SELECT ROUND(-2.5e0)", -3.0
    TCF "SELECT ROUND(1234.5678e0, -2)", 1200.0
    TCF "SELECT ROUND(1.5e300, 400)", 1.5e300
    TCF "SELECT ROUND(1e0, -400)", 0.0
    TE  "SELECT ROUND(1.7e308, -308)", ERR_NUMERIC_OVERFLOW
    TN  "SELECT ROUND(1.5, NULL)", D(18,0)
    TN  "SELECT ROUND(NULL, 2)", T_INT
    TC  "SELECT ROUND(1.55, 1 + 0)", 0, D(18,1), 16
    TE  "SELECT ROUND(1.5, i) FROM t", ERR_SEMANTIC
    TE  "SELECT ROUND(1.5, 1.0)", ERR_TYPE
    TE  "SELECT ROUND('a')", ERR_TYPE
    TC  "SELECT ROUND(d, 1) FROM t WHERE i = 2", 0, D(18,1), -3
    // --- FLOOR / CEIL
    TC  "SELECT FLOOR(2.7)", 0, D(18,0), 2
    TC  "SELECT FLOOR(-2.7)", 0, D(18,0), -3
    TC  "SELECT FLOOR(-1.00)", 0, D(18,0), -1
    TC  "SELECT CEIL(2.1)", 0, D(18,0), 3
    TC  "SELECT CEILING(-2.1)", 0, D(18,0), -2
    TC  "SELECT CEIL(-0.5)", 0, D(18,0), 0
    TC  "SELECT FLOOR(5)", 0, T_INT, 5
    TCF "SELECT FLOOR(2.5e0)", 2.0
    TCF "SELECT CEIL(-0.5e0)", -0.0
    TCF "SELECT CEIL(f) FROM t WHERE i = 1", 1.0
    TN  "SELECT FLOOR(NULL)", T_INT
    // --- SQRT / POWER / MOD
    TCF "SELECT SQRT(16)", 4.0
    TCF "SELECT SQRT(2.25)", 1.5
    TCF "SELECT SQRT(0)", 0.0
    TN  "SELECT SQRT(NULL)", T_FLOAT
    TE  "SELECT SQRT(-1)", ERR_INVALID_ARGUMENT
    TE  "SELECT SQRT(-0.01)", ERR_INVALID_ARGUMENT
    TE  "SELECT SQRT('4')", ERR_TYPE
    TCF "SELECT POWER(2, 10)", 1024.0
    TCF "SELECT POWER(2.0, -1)", 0.5
    TCF "SELECT POWER(-8, 3)", -512.0
    TCF "SELECT POWER(-2, -1)", -0.5
    TCF "SELECT POWER(0, 0)", 1.0
    TCF "SELECT POWER(4, 0.5)", 2.0
    TN  "SELECT POWER(NULL, 2)", T_FLOAT
    TE  "SELECT POWER(0, -1)", ERR_DIVISION_BY_ZERO
    TE  "SELECT POWER(0.0, -1.5)", ERR_DIVISION_BY_ZERO
    TE  "SELECT POWER(-8, 0.5)", ERR_INVALID_ARGUMENT
    TE  "SELECT POWER(10, 400)", ERR_NUMERIC_OVERFLOW
    TC  "SELECT MOD(17, 5)", 0, T_INT, 2
    TC  "SELECT MOD(-17, 5)", 0, T_INT, -2
    TC  "SELECT MOD(17, -5)", 0, T_INT, 2
    TC  "SELECT MOD(-9223372036854775808, -1)", 0, T_INT, 0
    TN  "SELECT MOD(NULL, 0)", T_INT
    TE  "SELECT MOD(1, 0)", ERR_DIVISION_BY_ZERO
    TE  "SELECT MOD(1.5, 1)", ERR_TYPE
    TE  "SELECT MOD(1e0, 1)", ERR_TYPE
    // --- LENGTH / UPPER / LOWER
    TC  "SELECT LENGTH('héllo')", 0, T_INT, 5
    TC  "SELECT LENGTH('日本語')", 0, T_INT, 3
    TC  "SELECT LENGTH('')", 0, T_INT, 0
    TC  "SELECT LENGTH(s) FROM t WHERE i = 2", 0, T_INT, 5
    TN  "SELECT LENGTH(s) FROM t WHERE i IS NULL", T_INT
    TE  "SELECT LENGTH(5)", ERR_TYPE
    TCS "SELECT UPPER('abc xyz_{')", "ABC XYZ_{"
    TCS "SELECT UPPER('aé')", "Aé"
    TCS "SELECT LOWER('ABC ÀÉ@[')", "abc ÀÉ@["
    TCS "SELECT UPPER(s) FROM t WHERE i = 2", "HéLLO"
    TN  "SELECT LOWER(NULL)", T_STR
    // --- SUBSTR
    TCS "SELECT SUBSTR('hello', 2, 3)", "ell"
    TCS "SELECT SUBSTR('hello', 3)", "llo"
    TCS "SELECT SUBSTR('hello', 0, 2)", "h"
    TCS "SELECT SUBSTR('hello', -1, 2)", ""
    TCS "SELECT SUBSTR('hello', 10)", ""
    TCS "SELECT SUBSTR('hello', 2, 0)", ""
    TCS "SELECT SUBSTRING('héllo', 2, 2)", "él"
    TCS "SELECT SUBSTR('日本語', 2)", "本語"
    TCS "SELECT SUBSTR('héllo', 5, 9223372036854775807)", "o"
    TCS "SELECT SUBSTR('abc', -9223372036854775808, 9223372036854775807)", ""
    TE  "SELECT SUBSTR('abc', 1, -1)", ERR_INVALID_ARGUMENT
    TN  "SELECT SUBSTR(NULL, 1, -1)", T_STR
    TN  "SELECT SUBSTR('abc', NULL)", T_STR
    TE  "SELECT SUBSTR('abc', '1')", ERR_TYPE
    TE  "SELECT SUBSTR('abc')", ERR_SEMANTIC
    // --- TRIM / REPLACE
    TCS "SELECT TRIM('  a b  ')", "a b"
    TCS "SELECT LTRIM('  a ')", "a "
    TCS "SELECT RTRIM('  a ')", "  a"
    TCS "SELECT TRIM('\tx\t')", "\tx\t"
    TCS "SELECT TRIM('   ')", ""
    TCS "SELECT TRIM(s) FROM t WHERE i = -5", "x"
    TCS "SELECT REPLACE('banana', 'an', 'AN')", "bANANa"
    TCS "SELECT REPLACE('aaa', 'aa', 'b')", "ba"
    TCS "SELECT REPLACE('abc', '', 'x')", "abc"
    TCS "SELECT REPLACE('aaaa', 'aa', '')", ""
    TCS "SELECT REPLACE('héhé', 'é', 'ee')", "heehee"
    TCS "SELECT REPLACE('', 'a', 'b')", ""
    TN  "SELECT REPLACE('abc', 'b', NULL)", T_STR
    TE  "SELECT REPLACE('abc', 'b', 1)", ERR_TYPE
    // --- CONCAT
    TCS "SELECT CONCAT('a', NULL, 1, TRUE, 2.50, DATE '2024-01-02')", "a1true2.502024-01-02"
    TCS "SELECT CONCAT(NULL)", ""
    TCS "SELECT CONCAT(NULL, NULL)", ""
    TCS "SELECT CONCAT(TIMESTAMP '2024-01-01 10:00:00.5', -1)", "2024-01-01 10:00:00.500000-1"
    TCS "SELECT CONCAT(s, i, d) FROM t WHERE i = 2", "héllo2-0.25"
    TCS "SELECT CONCAT(s, i) FROM t WHERE i IS NULL", ""
    TE  "SELECT CONCAT('a', 1.5e0)", ERR_TYPE
    // --- COALESCE / NULLIF
    TC  "SELECT COALESCE(NULL, 2, 3)", 0, T_INT, 2
    TN  "SELECT COALESCE(NULL, NULL)", T_NULL
    TC  "SELECT COALESCE(1, 2.5)", 0, D(18,1), 10
    TC  "SELECT COALESCE(NULL, 1.5, 2)", 0, D(18,1), 15
    TC  "SELECT COALESCE(1.5, 2.25)", 0, D(18,2), 150
    TC  "SELECT COALESCE(1.50, 2.75)", 0, D(3,2), 150
    TCF "SELECT COALESCE(2, 1.5e0)", 2.0
    TCS "SELECT COALESCE(s, 'none') FROM t WHERE i IS NULL", "none"
    TC  "SELECT COALESCE(i, -1) FROM t WHERE i IS NULL", 0, T_INT, -1
    TC  "SELECT COALESCE(d, 0) FROM t WHERE i IS NULL", 0, D(18,2), 0
    TE  "SELECT COALESCE(1, 'a')", ERR_TYPE
    TE  "SELECT COALESCE(DATE '2024-01-01', TIMESTAMP '2024-01-01 00:00:00')", ERR_TYPE
    TE  "SELECT COALESCE(TRUE, 1)", ERR_TYPE
    TN  "SELECT NULLIF(1, 1)", T_INT
    TC  "SELECT NULLIF(1, 2)", 0, T_INT, 1
    TN  "SELECT NULLIF(1, 1.0)", T_INT
    TC  "SELECT NULLIF(1.5, 2)", 0, D(2,1), 15
    TN  "SELECT NULLIF(NULL, 1)", T_NULL
    TCS "SELECT NULLIF('a', NULL)", "a"
    TN  "SELECT NULLIF(DATE '2024-01-01', TIMESTAMP '2024-01-01 00:00:00')", T_DATE
    TC  "SELECT COALESCE(NULLIF(LENGTH(''), 0), 99)", 0, T_INT, 99
    TE  "SELECT NULLIF(1, 'a')", ERR_TYPE
    // --- YEAR .. SECOND (incl. before 1970)
    TC  "SELECT YEAR(DATE '2024-02-29')", 0, T_INT, 2024
    TC  "SELECT MONTH(DATE '2024-02-29')", 0, T_INT, 2
    TC  "SELECT DAY(DATE '2024-02-29')", 0, T_INT, 29
    TC  "SELECT YEAR(TIMESTAMP '0001-12-31 00:00:00')", 0, T_INT, 1
    TC  "SELECT YEAR(DATE '9999-12-31')", 0, T_INT, 9999
    TC  "SELECT YEAR(dt) FROM t WHERE i = 2", 0, T_INT, 1969
    TC  "SELECT DAY(dt) FROM t WHERE i = 2", 0, T_INT, 31
    TC  "SELECT YEAR(ts) FROM t WHERE i = 2", 0, T_INT, 1969
    TC  "SELECT MONTH(ts) FROM t WHERE i = 2", 0, T_INT, 12
    TC  "SELECT DAY(ts) FROM t WHERE i = 2", 0, T_INT, 31
    TC  "SELECT HOUR(ts) FROM t WHERE i = 2", 0, T_INT, 23
    TC  "SELECT MINUTE(ts) FROM t WHERE i = 2", 0, T_INT, 59
    TC  "SELECT SECOND(ts) FROM t WHERE i = 2", 0, T_INT, 59
    TC  "SELECT HOUR(ts) FROM t WHERE i = -5", 0, T_INT, 12
    TC  "SELECT MINUTE(ts) FROM t WHERE i = -5", 0, T_INT, 34
    TC  "SELECT SECOND(ts) FROM t WHERE i = -5", 0, T_INT, 56
    TC  "SELECT DAY(ts) FROM t WHERE i = -5", 0, T_INT, 29
    TC  "SELECT HOUR(TIMESTAMP '2024-01-01 13:14:15.9')", 0, T_INT, 13
    TN  "SELECT HOUR(ts) FROM t WHERE i IS NULL", T_INT
    TN  "SELECT YEAR(NULL)", T_INT
    TE  "SELECT HOUR(DATE '2024-01-01')", ERR_TYPE
    TE  "SELECT YEAR('2024-01-01')", ERR_TYPE
    TE  "SELECT DAY(1)", ERR_TYPE
    // --- DATE_TRUNC (TIMESTAMP payloads in µs)
    TC  "SELECT DATE_TRUNC('month', DATE '2024-02-29')", 0, T_TS, 1706745600000000
    TC  "SELECT DATE_TRUNC('year', TIMESTAMP '2024-07-04 10:11:12')", 0, T_TS, 1704067200000000
    TC  "SELECT DATE_TRUNC('hour', TIMESTAMP '2024-07-04 10:11:12.5')", 0, T_TS, 1720087200000000
    TC  "SELECT DATE_TRUNC('minute', TIMESTAMP '2024-07-04 10:11:12')", 0, T_TS, 1720087860000000
    TC  "SELECT DATE_TRUNC('day', TIMESTAMP '2024-07-04 10:11:12')", 0, T_TS, 1720051200000000
    TC  "SELECT DATE_TRUNC('DAY', ts) FROM t WHERE i = 2", 0, T_TS, -86400000000
    TC  "SELECT DATE_TRUNC('Hour', ts) FROM t WHERE i = 2", 0, T_TS, -3600000000
    TC  "SELECT DATE_TRUNC('month', ts) FROM t WHERE i = 2", 0, T_TS, -2678400000000
    TC  "SELECT DATE_TRUNC('year', DATE '0001-12-31')", 0, T_TS, -62135596800000000
    TN  "SELECT DATE_TRUNC(NULL, DATE '2024-01-01')", T_TS
    TN  "SELECT DATE_TRUNC('day', NULL)", T_TS
    TE  "SELECT DATE_TRUNC('week', DATE '2024-01-01')", ERR_INVALID_ARGUMENT
    TE  "SELECT DATE_TRUNC(s, dt) FROM t", ERR_SEMANTIC
    TE  "SELECT DATE_TRUNC('day', 'x')", ERR_TYPE
    TE  "SELECT DATE_TRUNC(1, DATE '2024-01-01')", ERR_TYPE
    // --- DATE_DIFF
    TC  "SELECT DATE_DIFF('day', DATE '2024-01-01', DATE '2024-03-01')", 0, T_INT, 60
    TC  "SELECT DATE_DIFF('day', DATE '2024-03-01', DATE '2024-01-01')", 0, T_INT, -60
    TC  "SELECT DATE_DIFF('day', TIMESTAMP '2024-01-01 23:59:59', TIMESTAMP '2024-01-02 00:00:01')", 0, T_INT, 1
    TC  "SELECT DATE_DIFF('day', TIMESTAMP '1969-12-31 23:59:59', TIMESTAMP '1970-01-01 00:00:00')", 0, T_INT, 1
    TC  "SELECT DATE_DIFF('DAY', DATE '0001-01-01', DATE '9999-12-31')", 0, T_INT, 3652058
    TC  "SELECT DATE_DIFF('day', ts, dt) FROM t WHERE i = 2", 0, T_INT, 0
    TN  "SELECT DATE_DIFF('day', NULL, DATE '2024-01-01')", T_INT
    TE  "SELECT DATE_DIFF('month', DATE '2024-01-01', DATE '2024-01-01')", ERR_INVALID_ARGUMENT
    TE  "SELECT DATE_DIFF('day', 1, 2)", ERR_TYPE
    // --- CASE
    TC  "SELECT CASE WHEN FALSE THEN 1 WHEN NULL THEN 2 ELSE 3.5 END", 0, D(18,1), 35
    TN  "SELECT CASE WHEN TRUE THEN NULL ELSE 1 END", T_INT
    TCS "SELECT CASE 1 WHEN NULL THEN 'n' ELSE 'e' END", "e"
    TCF "SELECT CASE WHEN 1 = 1 THEN 1.5e0 ELSE 2 END", 1.5
    TC  "SELECT CASE WHEN TRUE THEN 1.5 ELSE 2.25 END", 0, D(18,2), 150
    TC  "SELECT CASE WHEN FALSE THEN 1.50 ELSE 2.25 END", 0, D(3,2), 225
    TCS "SELECT CASE 2 WHEN 1 THEN 'a' WHEN 2.0 THEN 'b' ELSE 'c' END", "b"
    TC  "SELECT CASE NULL WHEN NULL THEN 1 ELSE 2 END", 0, T_INT, 2
    TN  "SELECT CASE WHEN FALSE THEN 1 END", T_INT
    TN  "SELECT CASE WHEN TRUE THEN NULL END", T_NULL
    TC  "SELECT CASE WHEN TRUE THEN 1 ELSE 1 / 0 END", 0, T_INT, 1
    TCS "SELECT CASE WHEN i < 0 THEN 'neg' WHEN i < 2 THEN 'small' ELSE 'big' END FROM t WHERE i = 2", "big"
    TCS "SELECT CASE WHEN i < 0 THEN 'neg' ELSE 'pos' END FROM t WHERE i IS NULL", "pos"
    TC  "SELECT CASE s WHEN 'abc' THEN 1 WHEN 'héllo' THEN 2 END FROM t WHERE i = 2", 0, T_INT, 2
    TC  "SELECT CASE WHEN d > 0 THEN d ELSE 0 END FROM t WHERE i = 2", 0, D(18,2), 0
    TE  "SELECT CASE WHEN TRUE THEN 1 ELSE 'x' END", ERR_TYPE
    TE  "SELECT CASE WHEN 1 THEN 1 END", ERR_TYPE
    TE  "SELECT CASE 'a' WHEN 1 THEN 1 END", ERR_TYPE
    TE  "SELECT CASE WHEN TRUE THEN DATE '2024-01-01' ELSE TIMESTAMP '2024-01-01 00:00:00' END", ERR_TYPE
    TE  "SELECT CASE WHEN TRUE THEN 9223372036854775807 ELSE 1.5 END", ERR_NUMERIC_OVERFLOW
    // --- LIKE
    TC  "SELECT 'abc' LIKE 'ABC'", 0, T_BOOL, 0
    TC  "SELECT 'a%c' LIKE 'a%'", 0, T_BOOL, 1
    TC  "SELECT 'abc' LIKE 'a_c'", 0, T_BOOL, 1
    TC  "SELECT 'ac' LIKE 'a_c'", 0, T_BOOL, 0
    TC  "SELECT '' LIKE '%'", 0, T_BOOL, 1
    TC  "SELECT '' LIKE '_'", 0, T_BOOL, 0
    TC  "SELECT '' LIKE ''", 0, T_BOOL, 1
    TC  "SELECT 'éa' LIKE '_a'", 0, T_BOOL, 1
    TC  "SELECT '日本語' LIKE '_本_'", 0, T_BOOL, 1
    TC  "SELECT '日本語' LIKE '__'", 0, T_BOOL, 0
    TC  "SELECT 'a.c' LIKE 'a.c'", 0, T_BOOL, 1
    TC  "SELECT 'abc' LIKE 'b'", 0, T_BOOL, 0
    TC  "SELECT 'abc' LIKE '%%%'", 0, T_BOOL, 1
    TC  "SELECT 'mississippi' LIKE '%iss%ppi'", 0, T_BOOL, 1
    TC  "SELECT 'mississippi' LIKE 'm%s_s%i'", 0, T_BOOL, 1
    TC  "SELECT 'mississippi' LIKE '%iss%pp'", 0, T_BOOL, 0
    TC  "SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab' LIKE '%a%a%a%a%a%a%a%a%a%a%a%a%a%a%a%a%c'", 0, T_BOOL, 0
    TC  "SELECT 'abc' NOT LIKE 'a%'", 0, T_BOOL, 0
    TC  "SELECT 'abc' NOT LIKE 'b%'", 0, T_BOOL, 1
    TN  "SELECT NULL LIKE 'a'", T_BOOL
    TN  "SELECT 'a' NOT LIKE NULL", T_BOOL
    TC  "SELECT s LIKE '%ll%' FROM t WHERE i = 2", 0, T_BOOL, 1
    TN  "SELECT s LIKE '%' FROM t WHERE i IS NULL", T_BOOL
    TE  "SELECT 1 LIKE '1'", ERR_TYPE
    TE  "SELECT 'a' LIKE 1", ERR_TYPE
    // --- BETWEEN
    TC  "SELECT 1 BETWEEN 1 AND 1", 0, T_BOOL, 1
    TC  "SELECT 3 BETWEEN 5 AND 1", 0, T_BOOL, 0
    TC  "SELECT 1 NOT BETWEEN 2 AND 3", 0, T_BOOL, 1
    TC  "SELECT 1.5 BETWEEN 1 AND 2", 0, T_BOOL, 1
    TC  "SELECT 'b' BETWEEN 'a' AND 'c'", 0, T_BOOL, 1
    TN  "SELECT NULL BETWEEN 1 AND 2", T_BOOL
    TC  "SELECT 5 BETWEEN NULL AND 4", 0, T_BOOL, 0
    TC  "SELECT 5 NOT BETWEEN NULL AND 4", 0, T_BOOL, 1
    TC  "SELECT DATE '2024-01-02' BETWEEN TIMESTAMP '2024-01-01 00:00:00' AND DATE '2024-01-03'", 0, T_BOOL, 1
    TC  "SELECT i FROM t WHERE i BETWEEN 2 AND 5", 0, T_INT, 2
    TC  "SELECT i FROM t WHERE i NOT BETWEEN 0 AND 5", 0, T_INT, -5
    TE  "SELECT 'a' BETWEEN 1 AND 2", ERR_TYPE
    // --- IN lists
    TC  "SELECT 1 IN (1, NULL)", 0, T_BOOL, 1
    TN  "SELECT 2 IN (1, NULL)", T_BOOL
    TN  "SELECT 2 NOT IN (1, NULL)", T_BOOL
    TN  "SELECT NULL IN (1, 2)", T_BOOL
    TC  "SELECT 1 IN (1.0, 2)", 0, T_BOOL, 1
    TC  "SELECT 1 NOT IN (2, 3)", 0, T_BOOL, 1
    TC  "SELECT 1 NOT IN (1, NULL)", 0, T_BOOL, 0
    TC  "SELECT 2 IN (1e0, 2e0)", 0, T_BOOL, 1
    TC  "SELECT 'a' IN ('b', 'a')", 0, T_BOOL, 1
    TC  "SELECT i FROM t WHERE i IN (-5, 7)", 0, T_INT, -5
    TC  "SELECT i FROM t WHERE i NOT IN (1, 7)", 0, T_INT, 2
    TE  "SELECT 1 IN ('a', 'b')", ERR_TYPE
    // --- bound tree shapes and constness
    TC  "SELECT 1 BETWEEN 0 AND 2", 0, 0, NK_BINARY, 0, M_KIND
    TC  "SELECT 1 NOT BETWEEN 0 AND 2", 0, 0, NK_UNARY, 0, M_KIND
    TC  "SELECT 1 BETWEEN 0 AND 2", 0, 0, NF_CONST, 0, M_CONST
    TC  "SELECT i BETWEEN 0 AND 2 FROM t", 0, 0, 0, 0, M_CONST
    TC  "SELECT 1 IN (1, 2)", 0, 0, 0, 0, M_SHAPE
    TC  "SELECT 1 IN (1, 2)", 0, 0, NF_CONST, 0, M_CONST
    TC  "SELECT i IN (1, 2) FROM t", 0, 0, 0, 0, M_CONST
    TC  "SELECT CASE i WHEN 1 THEN 2 END FROM t", 0, 0, 0, 0, M_SHAPE
    TC  "SELECT CASE i WHEN 1 THEN 2 END FROM t", 0, 0, 0, 0, M_CONST
    TC  "SELECT CASE 1 WHEN 1 THEN 2 ELSE 3 END", 0, 0, NF_CONST, 0, M_CONST
    TC  "SELECT CASE WHEN TRUE THEN i END FROM t", 0, 0, 0, 0, M_CONST
    TC  "SELECT 'a' LIKE 'b'", 0, 0, NF_CONST, 0, M_CONST
    TC  "SELECT s LIKE 'b' FROM t", 0, 0, 0, 0, M_CONST
    TC  "SELECT LENGTH('a') + ABS(-1)", 0, 0, NF_CONST, 0, M_CONST
    TC  "SELECT LENGTH(s) FROM t", 0, 0, 0, 0, M_CONST
    TC  "SELECT CONCAT('a', s) FROM t", 0, 0, 0, 0, M_CONST
    TC  "SELECT PQ_SLEEP(0)", 0, 0, 0, 0, M_CONST
    TC  "SELECT PQ_SLEEP(0)", 0, 0, NK_FUNC, 0, M_KIND
    // --- nesting
    TC  "SELECT ABS(ROUND(-2.567, 1)) + LENGTH(UPPER(SUBSTR('abcdef', 2, 3)))", 0, D(18,1), 56
    TC  "SELECT LENGTH(CONCAT(REPLACE(TRIM('  ab  '), 'b', 'cd'), YEAR(DATE '2024-01-01')))", 0, T_INT, 7
cases_end:

    // ---- common_type(t1, t2) -> expected ------------------------------------
    .section .data.ct, "aw"
    .p2align 3
ct_start:
    CT  T_NULL, T_NULL, T_NULL
    CT  T_NULL, T_INT, T_INT
    CT  T_STR, T_NULL, T_STR
    CT  T_INT, T_INT, T_INT
    CT  T_INT, D(5,2), D(18,2)
    CT  D(5,2), T_INT, D(18,2)
    CT  D(5,2), D(10,4), D(18,4)
    CT  D(10,4), D(5,2), D(18,4)
    CT  D(5,2), D(5,2), D(5,2)
    CT  T_INT, T_FLOAT, T_FLOAT
    CT  D(3,1), T_FLOAT, T_FLOAT
    CT  T_FLOAT, T_FLOAT, T_FLOAT
    CT  T_DATE, T_DATE, T_DATE
    CT  T_TS, T_NULL, T_TS
    CT  T_DATE, T_TS, -1
    CT  T_STR, T_INT, -1
    CT  T_BOOL, T_INT, -1
    CT  T_BOOL, T_BOOL, T_BOOL
    CT  T_STR, T_DATE, -1
ct_end:

    .section .rodata
fmt_fail1:  .asciz "FAIL: %s\n"
fmt_fail2:  .asciz "   expected code=%d type=%#x null=%d val=%#llx\n"
fmt_fail3:  .asciz "   got      code=%d type=%#x null=%d val=%#llx\n"
fmt_ctfail: .asciz "FAIL: common_type(%#x, %#x) = %#x, expected %#x\n"
fmt_sum:    .asciz "test_functions: %d/%d passed\n"
    .text

// =============================================================================
// where_ok(x0 BoundQuery*, x1 EvalCtx*) -> w0 1 if the row passes WHERE
// =============================================================================
LFUNC where_ok
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ldr  x0, [x0, #BQ_WHERE]
    cbz  x0, 1f
    bl   eval
    cbnz x1, 2f
    cmp  x0, #0
    cset w0, ne
    ldp  x29, x30, [sp], #16
    ret
1:  mov  w0, #1
    ldp  x29, x30, [sp], #16
    ret
2:  mov  w0, #0
    ldp  x29, x30, [sp], #16
    ret
ENDF where_ok

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
//   x19 case, x20 BoundQuery*, x21 row index, x22 row count, x24 out expr
// Stack: EvalCtx at [sp, #0] (EC_SIZE bytes)
// =============================================================================
LFUNC run_case
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    sub  sp, sp, #EC_SIZE
    mov  x19, x0
    ADR_L x9, r_code
    stp  xzr, xzr, [x9]
    stp  xzr, xzr, [x9, #16]
    ADR_L x0, g_jmpbuf
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
    ldr  x9, [x20, #BQ_OUT]
    ldr  x24, [x9, #OC_EXPR]

    ldr  w9, [x19, #TC_MODE]
    cmp  w9, #M_KIND
    b.eq .Lrc_kind
    cmp  w9, #M_CONST
    b.eq .Lrc_const
    cmp  w9, #M_SHAPE
    b.eq .Lrc_shape

    // ---- evaluate output column 0 on the first qualifying row --------------
    ldr  x9, [x20, #BQ_OUT]
    ldr  w9, [x9, #OC_TYPE]
    ADR_L x10, r_type
    str  x9, [x10]
    mov  x0, sp
    mov  w1, #0
    mov  x2, #EC_SIZE
    bl   memset
    ldr  x9, [x20, #BQ_TABLE]
    str  x9, [sp, #EC_TABLE]
    mov  x22, #1
    cbz  x9, 2f
    ldr  x22, [x9, #TBL_NROWS]
2:  mov  x21, #0
3:  cmp  x21, x22
    b.hs .Lrc_norow
    str  x21, [sp, #EC_ROW]
    mov  x0, x20
    mov  x1, sp
    bl   where_ok
    add  x21, x21, #1
    cbz  w0, 3b
    mov  x0, x24
    mov  x1, sp
    bl   eval
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
    ADR_L x9, g_err_code
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

.Lrc_kind:
    ldr  w0, [x24, #N_KIND]
    b    .Lrc_cmp_int
.Lrc_const:
    ldr  w0, [x24, #N_FLAGS]
    and  w0, w0, #NF_CONST
    b    .Lrc_cmp_int
.Lrc_shape:
    ldr  x0, [x24, #N_A]
.Lrc_cmp_int:
    ADR_L x9, r_val
    str  x0, [x9]
    ldr  w10, [x19, #TC_CODE]
    cbnz w10, .Lrc_fail
    ldr  x1, [x19, #TC_VAL]
    cmp  x0, x1
    b.ne .Lrc_fail
    b    .Lrc_pass
.Lrc_cmp_str:
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
    add  sp, sp, #EC_SIZE
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret
ENDF run_case

// =============================================================================
// run_ct() -> w0 number of failed common_type cases, w1 number of cases
//   x19 cursor, x20 end, x21 failures, x22 count
// =============================================================================
LFUNC run_ct
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    ADR_L x19, ct_start
    ADR_L x20, ct_end
    mov  x21, #0
    mov  x22, #0
1:  cmp  x19, x20
    b.hs 3f
    ldp  w0, w1, [x19]
    bl   common_type
    add  x22, x22, #1
    ldr  w9, [x19, #8]
    cmp  w0, w9
    b.eq 2f
    add  x21, x21, #1
    mov  w3, w0
    ADR_L x0, fmt_ctfail
    ldp  w1, w2, [x19]
    ldr  w4, [x19, #8]
    bl   printf
2:  add  x19, x19, #16
    b    1b
3:  mov  w0, w21
    mov  w1, w22
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret
ENDF run_ct

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
    ADR_L x0, g_arena
    bl   arena_free
    add  x19, x19, #TC_SIZE
    b    1b
2:  bl   run_ct
    add  x21, x21, x0
    add  x22, x22, x1
    ADR_L x0, fmt_sum
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
