// =============================================================================
// test_parser.S — unit tests for lexer.S / parser.S
//
// Every case parses one SQL string with parse_sql under setjmp(g_jmpbuf):
//   * OK cases render the resulting Statement as a compact S-expression
//     (see dump_* below) and compare it with the expected text;
//   * ERR cases expect pq_raise* with a given error code and, optionally,
//     a given line/column (g_err_line / g_err_col).
// One line is printed per failure; the exit status is 0 iff all cases pass.
//
// Dump format
//   statement  {query} | explain {query} | create index N on T(C) using U flags F
//              | drop index N flags F
//   query      {[with NAME[(c,..)]={q}, ... ]select [distinct ]ITEM, ...
//               [ from F][ where X][ group X ...][ having X]
//               [ order X[ desc][ nf| nl], ...][ limit X][ offset X]}
//   item       *  |  q.*  |  X  |  X as ALIAS
//   from       NAME[ as A] | {q} as A | (inner|left|cross L R[ on X])
//   expr       literals: 12  dec(p,s):unscaled  f:%.17g  'text'  TRUE FALSE
//              NULL  date:N  ts:N;  columns: name / q.name;
//              (neg X) (pos X) (not X) (OP L R) (isnull X) (isnotnull X)
//              (cast X tKIND.P.S) (fn NAME[ *][ distinct] ARGS...)
//              (case OPERAND|_ [W T]... ELSE|_) ([not]between X L H)
//              ([not]in X ITEMS...) ([not]insub X {q}) ([not]like X P)
//              (exists {q}) (subq {q});  "^" prefix = NF_PAREN;
//              "@line:col" suffix on every node in position mode.
// =============================================================================
#include "pq.inc"

#define OUTMAX 4096

// Test table entry: sql, expected dump (OK) or 0 (ERR), error code, position
// (ERR: line << 32 | col, 0 = unchecked; OK: 1 = dump node positions).
#define TE_SQL   0
#define TE_EXP   8
#define TE_CODE  16
#define TE_POS   24
#define TE_SIZE  32

#define OK(sql, exp) \
    .pushsection .rodata ; 1: .asciz sql ; 2: .asciz exp ; .popsection ; \
    .quad 1b, 2b, 0, 0
#define OKPOS(sql, exp) \
    .pushsection .rodata ; 1: .asciz sql ; 2: .asciz exp ; .popsection ; \
    .quad 1b, 2b, 0, 1
#define ERR(sql, code) \
    .pushsection .rodata ; 1: .asciz sql ; .popsection ; \
    .quad 1b, 0, code, 0
#define ERRAT(sql, code, line, col) \
    .pushsection .rodata ; 1: .asciz sql ; .popsection ; \
    .quad 1b, 0, code, ((line << 32) | col)

// ------------------------------------------------------------------ cases ----
    .data
    .p2align 3
cases:
    // --- precedence and associativity
    OK("SELECT 2 + 3 * 4", "{select (+ 2 (* 3 4))}")
    OK("SELECT (2 + 3) * 4", "{select (* ^(+ 2 3) 4)}")
    OK("SELECT -2 * 3", "{select (* (neg 2) 3)}")
    OK("SELECT - - 1", "{select (neg (neg 1))}")
    OK("SELECT +a", "{select (pos a)}")
    OK("SELECT NOT a = b", "{select (not (= a b))}")
    OK("SELECT NOT NOT a", "{select (not (not a))}")
    OK("SELECT a OR b AND c", "{select (OR a (AND b c))}")
    OK("SELECT NOT a AND b", "{select (AND (not a) b)}")
    OK("SELECT a || b + c", "{select (|| a (+ b c))}")
    OK("SELECT a = b || c", "{select (= a (|| b c))}")
    OK("SELECT a || b || c", "{select (|| (|| a b) c)}")
    OK("SELECT 1 - 2 - 3", "{select (- (- 1 2) 3)}")
    OK("SELECT 8 / 2 % 3 * 1", "{select (* (% (/ 8 2) 3) 1)}")
    OK("SELECT a <> b, a != b, a <= b, a >= b, a < b, a > b",
       "{select (<> a b), (<> a b), (<= a b), (>= a b), (< a b), (> a b)}")
    OK("SELECT * FROM t WHERE a = 1 AND b BETWEEN 1 AND 2 OR c",
       "{select * from t where (OR (AND (= a 1) (between b 1 2)) c)}")
    // --- predicates
    OK("SELECT x BETWEEN 1 AND 2 AND y", "{select (AND (between x 1 2) y)}")
    OK("SELECT x NOT BETWEEN a + 1 AND b", "{select (notbetween x (+ a 1) b)}")
    OK("SELECT x IS NULL, y IS NOT NULL", "{select (isnull x), (isnotnull y)}")
    OK("SELECT x IN (1, 2, 3), y NOT IN ('a')", "{select (in x 1 2 3), (notin y 'a')}")
    OK("SELECT x IN (SELECT y FROM t)", "{select (insub x {select y from t})}")
    OK("SELECT a NOT IN (WITH q AS (SELECT 1) SELECT * FROM q)",
       "{select (notinsub a {with q={select 1} select * from q})}")
    OK("SELECT name LIKE 'A%', name NOT LIKE '%z'",
       "{select (like name 'A%'), (notlike name '%z')}")
    OK("SELECT EXISTS (SELECT 1), NOT EXISTS (SELECT 2)",
       "{select (exists {select 1}), (not (exists {select 2}))}")
    OK("SELECT (SELECT MAX(x) FROM t) + 1", "{select (+ (subq {select (fn MAX x) from t}) 1)}")
    OK("SELECT ((SELECT 1))", "{select ^(subq {select 1})}")
    OK("SELECT (WITH q AS (SELECT 1) SELECT * FROM q)",
       "{select (subq {with q={select 1} select * from q})}")
    // --- literals
    OK("SELECT 1, 1.50, 0.05, .5, 00012.5, 3., 0.0, 00.",
       "{select 1, dec(3,2):150, dec(2,2):5, dec(1,1):5, dec(3,1):125, dec(1,0):3, dec(1,1):0, dec(1,0):0}")
    OK("SELECT 12345678901234567.8, 1234567890.1234567890",
       "{select dec(18,1):123456789012345678, dec(20,10):12345678901234567890}")
    OK("SELECT 0.12345678901234567890123456789012345678, 1234567890.12345678901234567890123456789",
       "{select dec(38,38):12345678901234567890123456789012345678, f:1234567890.1234567}")
    OK("SELECT 1e3, 1.e2, .5e1, 1E-2, 2.5e+3",
       "{select f:1000, f:100, f:5, f:0.01, f:2500}")
    OK("SELECT 'it''s', '', TRUE, FALSE, NULL", "{select 'it's', '', TRUE, FALSE, NULL}")
    OK("SELECT '\303\234n\303\257''code'", "{select '\303\234n\303\257'code'}")
    OK("SELECT DATE '2024-02-29', TIMESTAMP '2024-02-29 13:14:15.5', TIMESTAMP '2024-01-01T00:00:00'",
       "{select date:19782, ts:1709212455500000, ts:1704067200000000}")
    OK("SELECT -9223372036854775808, 9223372036854775807",
       "{select -9223372036854775808, 9223372036854775807}")
    OK("SELECT - 9223372036854775808 * 2", "{select (* -9223372036854775808 2)}")
    OK("SELECT -(-9223372036854775808)", "{select (neg ^-9223372036854775808)}")
    OK("SELECT CAST(x AS DECIMAL(10, 2)), CAST('1' AS int), CAST(d AS DATE), CAST(t AS timestamp), CAST(1 AS numeric), CAST(1 AS decimal(5))",
       "{select (cast x t3.10.2), (cast '1' t2.0.0), (cast d t6.0.0), (cast t t7.0.0), (cast 1 t3.18.0), (cast 1 t3.5.0)}")
    // --- functions, CASE
    OK("SELECT COUNT(*), COUNT(DISTINCT x), f(), g(a, b + 1)",
       "{select (fn COUNT *), (fn COUNT distinct x), (fn f), (fn g a (+ b 1))}")
    OK("SELECT CASE WHEN a THEN 1 WHEN b THEN 2 ELSE 3 END, CASE x WHEN 1 THEN 'a' END",
       "{select (case _ [a 1] [b 2] 3), (case x [1 'a'] _)}")
    // --- select items, identifiers
    OK("SELECT *, t.*, a AS x, b y, c \"Quoted Alias\", t.d FROM t",
       "{select *, t.*, a as x, b as y, c as Quoted Alias, t.d from t}")
    OK("SELECT \"select\", \"a \"\"b\"\"\" FROM \"FROM\"", "{select select, a \"b\" from FROM}")
    OK("SELECT 1 AS \"end\", hash, btree", "{select 1 as end, hash, btree}")
    // --- clauses
    OK("select distinct a from t where a > 1 group by a, b having count(*) > 1 order by a desc nulls first, b asc, c nulls last limit 10 offset 5",
       "{select distinct a from t where (> a 1) group a b having (> (fn count *) 1) order a desc nf, b, c nl limit 10 offset 5}")
    OK("SELECT a FROM t OFFSET 2 LIMIT 3", "{select a from t limit 3 offset 2}")
    OK("SELECT a FROM t OFFSET 2", "{select a from t offset 2}")
    OK("SELECT ALL a FROM t AS u ORDER BY 1", "{select a from t as u order 1}")
    // --- FROM / joins
    OK("SELECT * FROM a JOIN b ON a.id = b.id LEFT OUTER JOIN c ON c.x = b.x CROSS JOIN d, e INNER JOIN f AS ff ON TRUE",
       "{select * from (inner (cross (cross (left (inner a b on (= a.id b.id)) c on (= c.x b.x)) d) e) f as ff on TRUE)}")
    OK("SELECT * FROM t1 x, (SELECT 1 AS one) AS s, (a LEFT JOIN b ON TRUE)",
       "{select * from (cross (cross t1 as x {select 1 as one} as s) (left a b on TRUE))}")
    OK("SELECT * FROM (SELECT 1) sub", "{select * from {select 1} as sub}")
    OK("SELECT * FROM ((SELECT 1) AS s1)", "{select * from {select 1} as s1}")
    OK("WITH c1 AS (SELECT 1), c2 (x, y) AS (SELECT 1, 2 ORDER BY 1 LIMIT 1) SELECT * FROM c1, c2",
       "{with c1={select 1}, c2(x,y)={select 1, 2 order 1 limit 1} select * from (cross c1 c2)}")
    // --- statements
    OK("EXPLAIN SELECT 1", "explain {select 1}")
    OK("CREATE INDEX idx ON t (c)", "create index idx on t(c) using 0 flags 0")
    OK("CREATE INDEX IF NOT EXISTS i2 ON t(c) USING hash", "create index i2 on t(c) using 1 flags 1")
    OK("create index i3 on t (c) using BTREE;", "create index i3 on t(c) using 2 flags 0")
    OK("DROP INDEX idx", "drop index idx flags 0")
    OK("drop index if exists idx ;", "drop index idx flags 1")
    // --- lexical
    OK("SELECT 1; ", "{select 1}")
    OK("sElEcT   id\n  -- comment\n  FrOm /* inline */ people\n  wHeRe id\n   <= 2 OrDeR bY id -- end",
       "{select id from people where (<= id 2) order id}")
    OK("SELECT 1--2", "{select 1}")
    OK("SELECT 1/**/+/* *\n*/2", "{select (+ 1 2)}")
    // --- positions
    OKPOS("SELECT\n  a +\n b, 'x'", "{select (+ a@2:3 b@3:2)@2:3, 'x'@3:5}")
    OKPOS("SELECT '\303\234n\303\257', x", "{select '\303\234n\303\257'@1:8, x@1:15}")
    OKPOS("SELECT -1, (b), NOT c", "{select (neg 1@1:9)@1:8, ^b@1:13, (not c@1:21)@1:17}")

    // --- errors: literals
    ERRAT("SELECT 9223372036854775808", ERR_NUMERIC_OVERFLOW, 1, 8)
    ERR("SELECT 99999999999999999999", ERR_NUMERIC_OVERFLOW)
    ERR("SELECT -(9223372036854775808)", ERR_NUMERIC_OVERFLOW)
    ERR("SELECT 1e999", ERR_NUMERIC_OVERFLOW)
    ERRAT("SELECT DATE '2023-02-29'", ERR_CONVERSION, 1, 13)
    ERR("SELECT TIMESTAMP '2023-01-01 25:00:00'", ERR_CONVERSION)
    ERR("SELECT TIMESTAMP '2023-01-01'", ERR_CONVERSION)
    ERR("SELECT DATE 5", ERR_PARSE)
    ERRAT("SELECT CAST(1 AS foo)", ERR_SEMANTIC, 1, 18)
    ERR("SELECT CAST(1 AS DECIMAL(39, 2))", ERR_SEMANTIC)
    ERR("SELECT CAST(1 AS DECIMAL(0, 0))", ERR_SEMANTIC)
    ERR("SELECT CAST(1 AS DECIMAL(5, 6))", ERR_SEMANTIC)
    ERR("SELECT CAST(1 AS INT(3))", ERR_SEMANTIC)
    ERR("SELECT CAST(1 AS DECIMAL(99999999999999999999))", ERR_SEMANTIC)
    ERR("SELECT CAST(1 AS)", ERR_PARSE)
    ERR("SELECT CAST(1 AS DECIMAL(1.5))", ERR_PARSE)
    // --- errors: syntax
    ERRAT("SELECT a = b = c", ERR_PARSE, 1, 14)
    ERR("SELECT a < b IS NULL", ERR_PARSE)
    ERR("SELECT a IS NULL IS NULL", ERR_PARSE)
    ERR("SELECT a LIKE b LIKE c", ERR_PARSE)
    ERRAT("SELECT 1; SELECT 2", ERR_PARSE, 1, 11)
    ERR("SELECT 1;;", ERR_PARSE)
    ERRAT("SELECT 1 +", ERR_PARSE, 1, 11)
    ERR("SELECT (1 + 2", ERR_PARSE)
    ERR("SELECT 1 + 2)", ERR_PARSE)
    ERR("SELECT id FROM people WHERE id = = 1", ERR_PARSE)
    ERRAT("SELECT id\nFROM people\nWHERE id = = 1", ERR_PARSE, 3, 12)
    ERR("SELECT id, FROM people", ERR_PARSE)
    ERR("SELECT id FROM people ORDER id", ERR_PARSE)
    ERR("SELECT id FROM people GROUP id", ERR_PARSE)
    ERR("SELECT id FROM people ORDER BY id NULLS", ERR_PARSE)
    ERR("FROM people SELECT id", ERR_PARSE)
    ERR("SELECT CASE WHEN TRUE THEN 1", ERR_PARSE)
    ERR("SELECT CASE END", ERR_PARSE)
    ERR("SELECT CASE x ELSE 1 END", ERR_PARSE)
    ERR("SELECT id FROM people LIMIT 1 LIMIT 2", ERR_PARSE)
    ERR("SELECT id FROM people OFFSET 1 OFFSET 2", ERR_PARSE)
    ERR("SELECT id FROM people WHERE id BETWEEN 1", ERR_PARSE)
    ERR("SELECT id FROM people WHERE id IN ()", ERR_PARSE)
    ERR("INSERT INTO people VALUES (1)", ERR_PARSE)
    ERR("SELECT select FROM q", ERR_PARSE)
    ERR("SELECT COUNT(*, id) FROM t", ERR_PARSE)
    ERR("SELECT COUNT(DISTINCT *) FROM t", ERR_PARSE)
    ERR("SELECT * FROM (SELECT 1)", ERR_PARSE)
    ERR("SELECT t. FROM t", ERR_PARSE)
    ERR("SELECT * FROM t JOIN u", ERR_PARSE)
    ERR("SELECT a FROM t CROSS JOIN u ON TRUE", ERR_PARSE)
    ERR("SELECT NOT", ERR_PARSE)
    ERR("SELECT a NOT b", ERR_PARSE)
    ERR("SELECT 'x' 'y'", ERR_PARSE)
    ERR("SELECT a AS", ERR_PARSE)
    ERR("SELECT", ERR_PARSE)
    ERRAT("", ERR_PARSE, 1, 1)
    ERR("   -- only a comment", ERR_PARSE)
    ERR(";", ERR_PARSE)
    ERR("WITH SELECT 1", ERR_PARSE)
    ERR("WITH q AS SELECT 1 SELECT 2", ERR_PARSE)
    ERR("SELECT * FROM", ERR_PARSE)
    ERR("SELECT a FROM t WHERE", ERR_PARSE)
    ERR("SELECT f(a,)", ERR_PARSE)
    ERR("SELECT (SELECT 1", ERR_PARSE)
    ERR("SELECT EXISTS 1", ERR_PARSE)
    ERR("CREATE INDEX bad ON tx (tx_id) USING BITMAP", ERR_PARSE)
    ERR("CREATE INDEX bad ON tx (a, b)", ERR_PARSE)
    ERR("CREATE INDEX IF EXISTS bad ON tx (a)", ERR_PARSE)
    ERR("CREATE TABLE t", ERR_PARSE)
    ERR("DROP INDEX", ERR_PARSE)
    ERR("DROP INDEX a b", ERR_PARSE)
    ERR("EXPLAIN", ERR_PARSE)
    // --- errors: lexical
    ERRAT("SELECT * FROM people /* unterminated", ERR_PARSE, 1, 22)
    ERRAT("SELECT @ FROM people", ERR_PARSE, 1, 8)
    ERRAT("SELECT\n  \"unterminated FROM people", ERR_PARSE, 2, 3)
    ERRAT("SELECT 'a', 'abc", ERR_PARSE, 1, 13)
    ERR("SELECT 12abc", ERR_PARSE)
    ERR("SELECT 1e", ERR_PARSE)
    ERR("SELECT 1.2.3", ERR_PARSE)
    ERR("SELECT a | b", ERR_PARSE)
    ERR("SELECT a ! b", ERR_PARSE)
    ERR("SELECT \303\234", ERR_PARSE)
    ERR("SELECT [a]", ERR_PARSE)
    // --- errors: reserved-for-future syntax
    ERRAT("SELECT id FROM people UNION SELECT id FROM people", ERR_UNSUPPORTED, 1, 23)
    ERR("SELECT 1 UNION DISTINCT SELECT 2", ERR_UNSUPPORTED)
    // --- UNION ALL (CR-1)
    OK("SELECT 1 UNION ALL SELECT 2", "{select 1 union all select 2}")
    OK("WITH q AS (SELECT a FROM t) SELECT a FROM q UNION ALL SELECT DISTINCT b FROM t WHERE c GROUP BY b UNION ALL SELECT 3 ORDER BY 1 DESC LIMIT 2", "{with q={select a from t} select a from q union all select distinct b from t where c group b union all select 3 order 1 desc limit 2}")
    OK("SELECT * FROM (SELECT 1 UNION ALL SELECT 2) s WHERE x IN (SELECT y FROM t UNION ALL SELECT 1)", "{select * from {select 1 union all select 2} as s where (insub x {select y from t union all select 1})}")
    ERRAT("SELECT a FROM t ORDER BY a UNION ALL SELECT 1", ERR_PARSE, 1, 28)
    ERRAT("SELECT 1 LIMIT 1 UNION ALL SELECT 1", ERR_PARSE, 1, 18)
    ERR("(SELECT 1) UNION ALL (SELECT 2)", ERR_PARSE)
    ERR("SELECT 1 UNION ALL (SELECT 2)", ERR_PARSE)
    ERR("SELECT 1 UNION ALL", ERR_PARSE)
    ERR("SELECT 1 UNION ALL SELECT 2 UNION SELECT 3", ERR_UNSUPPORTED)
    ERR("SELECT * FROM (SELECT 1 ORDER BY 1 UNION ALL SELECT 2) s", ERR_PARSE)
    ERR("SELECT * FROM (SELECT 1 UNION SELECT 2) s", ERR_UNSUPPORTED)
    ERRAT("SELECT * FROM a FULL JOIN b ON TRUE", ERR_UNSUPPORTED, 1, 17)
    ERR("SELECT * FROM a RIGHT JOIN b ON TRUE", ERR_UNSUPPORTED)
    ERR("SELECT * FROM a RIGHT OUTER JOIN b ON TRUE", ERR_UNSUPPORTED)
    .quad 0, 0, 0, 0

// ------------------------------------------------------------------- data ----
    .section .data.rel.ro
    .p2align 3
op_names:                           // indexed by OP_* code (0 = unused)
    .quad 0, s_neg, s_pos, s_not, 0, 0, 0, 0, 0, 0
    .quad s_add, s_sub, s_mul, s_div, s_mod, s_cat, 0, 0, 0, 0
    .quad s_eq, s_ne, s_lt, s_le, s_gt, s_ge, 0, 0, 0, 0
    .quad s_and, s_or
    .section .rodata
s_neg: .asciz "neg"
s_pos: .asciz "pos"
s_not: .asciz "not"
s_add: .asciz "+"
s_sub: .asciz "-"
s_mul: .asciz "*"
s_div: .asciz "/"
s_mod: .asciz "%"
s_cat: .asciz "||"
s_eq:  .asciz "="
s_ne:  .asciz "<>"
s_lt:  .asciz "<"
s_le:  .asciz "<="
s_gt:  .asciz ">"
s_ge:  .asciz ">="
s_and: .asciz "AND"
s_or:  .asciz "OR"

f_lld:      .asciz "%lld"
f_llu:      .asciz "%llu"
f_g17:      .asciz "f:%.17g"
s_null:     .asciz "NULL"
s_true:     .asciz "TRUE"
s_false:    .asciz "FALSE"
s_dec:      .asciz "dec("
s_paren_colon: .asciz "):"
s_date:     .asciz "date:"
s_ts:       .asciz "ts:"
s_open:     .asciz "("
s_close:    .asciz ")"
s_space:    .asciz " "
s_comma_sp: .asciz ", "
s_under:    .asciz "_"
s_isnull:   .asciz "(isnull "
s_isnotnull: .asciz "(isnotnull "
s_cast:     .asciz "(cast "
s_t:        .asciz " t"
s_fn:       .asciz "(fn "
s_star_sp:  .asciz " *"
s_distinct_sp: .asciz " distinct"
s_case:     .asciz "(case "
s_lbr:      .asciz " ["
s_rbr:      .asciz "]"
s_between:  .asciz "(between "
s_notbetween: .asciz "(notbetween "
s_in:       .asciz "(in "
s_notin:    .asciz "(notin "
s_insub:    .asciz "(insub "
s_notinsub: .asciz "(notinsub "
s_like:     .asciz "(like "
s_notlike:  .asciz "(notlike "
s_exists:   .asciz "(exists "
s_subq:     .asciz "(subq "
s_unknown:  .asciz "<?>"
s_qopen:    .asciz "{"
s_with:     .asciz "with "
s_select:   .asciz "select "
s_union_all: .asciz " union all "
s_distinct: .asciz "distinct "
s_as:       .asciz " as "
s_qstar:    .asciz ".*"
s_from:     .asciz " from "
s_where:    .asciz " where "
s_group:    .asciz " group"
s_having:   .asciz " having "
s_order:    .asciz " order "
s_desc:     .asciz " desc"
s_nf:       .asciz " nf"
s_nl:       .asciz " nl"
s_limit:    .asciz " limit "
s_offset:   .asciz " offset "
s_qclose:   .asciz "}"
s_inner:    .asciz "(inner "
s_left:     .asciz "(left "
s_cross:    .asciz "(cross "
s_on:       .asciz " on "
s_explain:  .asciz "explain "
s_create:   .asciz "create index "
s_on2:      .asciz " on "
s_using:    .asciz ") using "
s_flags:    .asciz " flags "
s_drop:     .asciz "drop index "

m_fail_dump:  .asciz "FAIL: %s\n  expected: %s\n  got:      %s\n"
m_fail_raise: .asciz "FAIL: %s\n  expected: %s\n  got error %u (%s) at %u:%u\n"
m_fail_ok:    .asciz "FAIL: %s\n  expected error %u, but parsing succeeded: %s\n"
m_fail_code:  .asciz "FAIL: %s\n  expected error %u, got error %u (%s)\n"
m_fail_pos:   .asciz "FAIL: %s\n  expected error at %u:%u, got %u:%u (%s)\n"
m_fail_deep:  .asciz "FAIL: nesting depth %u: got status %u, expected %u\n"
m_fail_abi:   .asciz "FAIL: parse_sql clobbered %u callee-saved register(s)\n"
abi_sql:      .asciz "WITH c(x) AS (SELECT 1) SELECT DISTINCT a.x, CASE WHEN x IN (1, 2) THEN CAST(x AS DECIMAL(5,2)) ELSE -1.5 END AS y, COUNT(*) FROM c a LEFT JOIN (SELECT 1 AS x) b ON a.x = b.x WHERE NOT EXISTS (SELECT 1) AND x BETWEEN 1 AND 9 GROUP BY 1 HAVING SUM(x) > 0 ORDER BY 1 DESC NULLS LAST LIMIT 5 OFFSET 1"
m_summary:    .asciz "test_parser: %u cases, %u failures\n"

    .bss
    .p2align 4
g_outbuf:   .skip OUTMAX
g_outpos:   .skip 8
g_dumppos:  .skip 8
g_deepbuf:  .skip 16384

    .text

// =============================================================================
// main — run the table, then the nesting-depth checks.
// Registers: x19 case pointer, w20 failures, w21 cases run, x22 statement.
// =============================================================================
FUNC main
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    ADR_L x19, cases
    mov  w20, #0
    mov  w21, #0
.Lm_loop:
    ldr  x0, [x19, #TE_SQL]
    cbz  x0, .Lm_deep
    add  w21, w21, #1
    TLS_ADDR x0, g_arena
    bl   arena_free
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lm_raised
    ldr  x0, [x19, #TE_SQL]
    bl   strlen
    mov  x1, x0
    ldr  x0, [x19, #TE_SQL]
    bl   parse_sql
    mov  x22, x0
    // parsed: render it
    ADR_L x9, g_outpos
    str  xzr, [x9]
    ADR_L x9, g_outbuf
    strb wzr, [x9]
    ldr  x10, [x19, #TE_EXP]
    cbz  x10, 1f
    ldr  x10, [x19, #TE_POS]
    ADR_L x9, g_dumppos
    str  x10, [x9]
1:  mov  x0, x22
    bl   dump_stmt
    ADR_L x9, g_dumppos
    str  xzr, [x9]
    ldr  x1, [x19, #TE_EXP]
    cbz  x1, .Lm_unexpected_ok
    ADR_L x0, g_outbuf
    bl   strcmp
    cbz  w0, .Lm_next
    ADR_L x0, m_fail_dump
    ldr  x1, [x19, #TE_SQL]
    ldr  x2, [x19, #TE_EXP]
    ADR_L x3, g_outbuf
    bl   printf
    add  w20, w20, #1
    b    .Lm_next
.Lm_unexpected_ok:
    ADR_L x0, m_fail_ok
    ldr  x1, [x19, #TE_SQL]
    ldr  x2, [x19, #TE_CODE]
    ADR_L x3, g_outbuf
    bl   printf
    add  w20, w20, #1
    b    .Lm_next

.Lm_raised:                         // pq_raise* longjmp'ed here
    ldr  x10, [x19, #TE_EXP]
    cbz  x10, 2f
    ADR_L x0, m_fail_raise          // an OK case raised
    ldr  x1, [x19, #TE_SQL]
    mov  x2, x10
    TLS_ADDR x9, g_err_code
    ldr  w3, [x9]
    TLS_ADDR x4, g_err_msg
    TLS_ADDR x9, g_err_line
    ldr  w5, [x9]
    TLS_ADDR x9, g_err_col
    ldr  w6, [x9]
    bl   printf
    add  w20, w20, #1
    b    .Lm_next
2:  TLS_ADDR x9, g_err_code
    ldr  w3, [x9]
    ldr  x2, [x19, #TE_CODE]
    cmp  x2, x3
    b.eq 3f
    ADR_L x0, m_fail_code
    ldr  x1, [x19, #TE_SQL]
    TLS_ADDR x4, g_err_msg
    bl   printf
    add  w20, w20, #1
    b    .Lm_next
3:  ldr  x10, [x19, #TE_POS]        // optional position check
    cbz  x10, .Lm_next
    TLS_ADDR x9, g_err_line
    ldr  w3, [x9]
    TLS_ADDR x9, g_err_col
    ldr  w4, [x9]
    lsr  x11, x10, #32
    mov  w12, w10
    cmp  w11, w3
    ccmp w12, w4, #0, eq
    b.eq .Lm_next
    ADR_L x0, m_fail_pos
    ldr  x1, [x19, #TE_SQL]
    mov  w2, w11
    mov  w5, w4
    mov  w4, w3
    mov  w3, w12
    TLS_ADDR x6, g_err_msg
    bl   printf
    add  w20, w20, #1
.Lm_next:
    add  x19, x19, #TE_SIZE
    b    .Lm_loop

.Lm_deep:                           // nesting (CR-6): 1000 levels ok (the
    mov  w0, #1000                  // minimum), 5000 beyond PARSE_MAX_DEPTH
    mov  w1, #0
    bl   check_depth
    add  w20, w20, w0
    mov  w0, #5000
    mov  w1, #ERR_RESOURCE_LIMIT
    bl   check_depth
    add  w20, w20, w0
    add  w21, w21, #2
    bl   check_abi                  // callee-saved registers preserved
    add  w20, w20, w0
    add  w21, w21, #1

    ADR_L x0, m_summary
    mov  w1, w21
    mov  w2, w20
    bl   printf
    cmp  w20, #0
    cset w0, ne
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF main

// -----------------------------------------------------------------------------
// check_depth(w0 depth, w1 expected status) -> w0 failures (0/1)
// Parses "SELECT " + "(" * depth + "1" + ")" * depth and "SELECT " + "-" *
// depth + "1"; status is 0 on success or the raised error code.
// Registers: w19 depth, w20 expected, x21 write pointer, w22 failures,
//            w23 pass (0 = parens, 1 = minus signs).
// -----------------------------------------------------------------------------
LFUNC check_depth
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  w19, w0
    mov  w20, w1
    mov  w22, #0
    mov  w23, #0
.Lcd_pass:
    ADR_L x21, g_deepbuf
    mov  w9, #'S'
    strb w9, [x21], #1
    mov  w9, #' '
    strb w9, [x21], #1
    mov  w10, w19
    mov  w9, #'('
    cbz  w23, 1f
    mov  w9, #'+'
1:  strb w9, [x21], #1
    subs w10, w10, #1
    b.ne 1b
    mov  w9, #'1'
    strb w9, [x21], #1
    cbnz w23, 3f
    mov  w10, w19
    mov  w9, #')'
2:  strb w9, [x21], #1
    subs w10, w10, #1
    b.ne 2b
3:  strb wzr, [x21]
    // "S " is not SQL: patch in "SELECT" by parsing from a prefix buffer
    TLS_ADDR x0, g_arena
    bl   arena_free
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 4f
    bl   build_select_prefixed      // x0 ptr, x1 len
    bl   parse_sql
    mov  w0, #0
    b    5f
4:  TLS_ADDR x9, g_err_code
    ldr  w0, [x9]
5:  cmp  w0, w20
    b.eq 6f
    mov  w2, w0
    ADR_L x0, m_fail_deep
    mov  w1, w19
    mov  w3, w20
    bl   printf
    add  w22, w22, #1
6:  add  w23, w23, #1
    cmp  w23, #2
    b.lo .Lcd_pass
    cmp  w22, #0
    cset w0, ne
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF check_depth

// -----------------------------------------------------------------------------
// check_abi() -> w0 failures (0/1)
// Loads recognisable values into x19-x28 and d8-d15, parses a query that
// exercises most of the grammar and verifies that all of them survived.
// Registers: all callee-saved registers are saved in the frame and restored;
//            w11 counts clobbered registers.
// -----------------------------------------------------------------------------
.macro ABI_SET_X reg, val
    mov  \reg, #\val
.endm
.macro ABI_CHK_X reg, val
    mov  x10, #\val
    cmp  \reg, x10
    cinc w11, w11, ne
.endm
.macro ABI_SET_D reg, val
    mov  x9, #\val
    fmov \reg, x9
.endm
.macro ABI_CHK_D reg, val
    fmov x9, \reg
    mov  x10, #\val
    cmp  x9, x10
    cinc w11, w11, ne
.endm
LFUNC check_abi
    stp  x29, x30, [sp, #-176]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    stp  d8, d9, [sp, #96]
    stp  d10, d11, [sp, #112]
    stp  d12, d13, [sp, #128]
    stp  d14, d15, [sp, #144]
    TLS_ADDR x0, g_arena
    bl   arena_free
    ADR_L x0, abi_sql
    bl   strlen
    str  x0, [sp, #160]
    ABI_SET_X x19, 0x1919
    ABI_SET_X x20, 0x2020
    ABI_SET_X x21, 0x2121
    ABI_SET_X x22, 0x2222
    ABI_SET_X x23, 0x2323
    ABI_SET_X x24, 0x2424
    ABI_SET_X x25, 0x2525
    ABI_SET_X x26, 0x2626
    ABI_SET_X x27, 0x2727
    ABI_SET_X x28, 0x2828
    ABI_SET_D d8, 0x0808
    ABI_SET_D d9, 0x0909
    ABI_SET_D d10, 0x1010
    ABI_SET_D d11, 0x1111
    ABI_SET_D d12, 0x1212
    ABI_SET_D d13, 0x1313
    ABI_SET_D d14, 0x1414
    ABI_SET_D d15, 0x1515
    ADR_L x0, abi_sql
    ldr  x1, [sp, #160]
    bl   parse_sql
    mov  w11, #0
    ABI_CHK_X x19, 0x1919
    ABI_CHK_X x20, 0x2020
    ABI_CHK_X x21, 0x2121
    ABI_CHK_X x22, 0x2222
    ABI_CHK_X x23, 0x2323
    ABI_CHK_X x24, 0x2424
    ABI_CHK_X x25, 0x2525
    ABI_CHK_X x26, 0x2626
    ABI_CHK_X x27, 0x2727
    ABI_CHK_X x28, 0x2828
    ABI_CHK_D d8, 0x0808
    ABI_CHK_D d9, 0x0909
    ABI_CHK_D d10, 0x1010
    ABI_CHK_D d11, 0x1111
    ABI_CHK_D d12, 0x1212
    ABI_CHK_D d13, 0x1313
    ABI_CHK_D d14, 0x1414
    ABI_CHK_D d15, 0x1515
    mov  w19, w11                   // (x19 is restored below)
    cbz  w19, 1f
    ADR_L x0, m_fail_abi
    mov  w1, w19
    bl   printf
1:  cmp  w19, #0
    cset w0, ne
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  d8, d9, [sp, #96]
    ldp  d10, d11, [sp, #112]
    ldp  d12, d13, [sp, #128]
    ldp  d14, d15, [sp, #144]
    ldp  x29, x30, [sp], #176
    ret
ENDF check_abi

// build_select_prefixed() -> x0 ptr, x1 len: copies g_deepbuf (which starts
// with "S ") into the arena with "SELECT" in place of "S".
// Registers: x19 source, x20 source length, x21 destination.
LFUNC build_select_prefixed
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    ADR_L x19, g_deepbuf
    mov  x0, x19
    bl   strlen
    mov  x20, x0
    add  x0, x0, #8
    bl   arena_alloc
    mov  w9, #'S'
    strb w9, [x0]
    mov  w9, #'E'
    strb w9, [x0, #1]
    mov  w9, #'L'
    strb w9, [x0, #2]
    mov  w9, #'E'
    strb w9, [x0, #3]
    mov  w9, #'C'
    strb w9, [x0, #4]
    mov  w9, #'T'
    strb w9, [x0, #5]
    stp  x0, xzr, [sp, #-16]!       // keep the buffer across memcpy
    add  x0, x0, #6
    add  x1, x19, #1
    sub  x2, x20, #1
    bl   memcpy
    ldp  x0, xzr, [sp], #16
    add  x1, x20, #5
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF build_select_prefixed

// =============================================================================
// Output helpers (append to g_outbuf, NUL terminated, silently truncated)
// =============================================================================

// out_c(w0 byte)  leaf
LFUNC out_c
    ADR_L x1, g_outpos
    ldr  x2, [x1]
    cmp  x2, #(OUTMAX - 1)
    b.hs 1f
    ADR_L x3, g_outbuf
    strb w0, [x3, x2]
    add  x2, x2, #1
    strb wzr, [x3, x2]
    str  x2, [x1]
1:  ret
ENDF out_c

// out_n(x0 ptr, x1 len)   Registers: x19 ptr, x20 remaining.
LFUNC out_n
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
1:  cbz  x20, 2f
    ldrb w0, [x19], #1
    bl   out_c
    sub  x20, x20, #1
    b    1b
2:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF out_n

// out_s(x0 cstr)   Registers: x19 string.
LFUNC out_s
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x19, x0
    bl   strlen
    mov  x1, x0
    mov  x0, x19
    bl   out_n
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF out_s

// out_str(x0 Str*)
LFUNC out_str
    ldr  x1, [x0, #STR_LEN]
    add  x0, x0, #STR_DATA
    b    out_n
ENDF out_str

// out_fmt(x0 format, x1 integer)  — snprintf into a stack buffer
LFUNC out_fmt
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    mov  x3, x1
    mov  x2, x0
    mov  x1, #64
    add  x0, sp, #16
    bl   snprintf
    add  x0, sp, #16
    bl   out_s
    ldp  x29, x30, [sp], #80
    ret
ENDF out_fmt

// out_i(x0 i64), out_u(x0 u64)
LFUNC out_i
    mov  x1, x0
    ADR_L x0, f_lld
    b    out_fmt
ENDF out_i
LFUNC out_u
    mov  x1, x0
    ADR_L x0, f_llu
    b    out_fmt
ENDF out_u

// out_f(d0 value) — "f:%.17g"
LFUNC out_f
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    ADR_L x2, f_g17
    mov  x1, #64
    add  x0, sp, #16
    bl   snprintf
    add  x0, sp, #16
    bl   out_s
    ldp  x29, x30, [sp], #80
    ret
ENDF out_f

// =============================================================================
// AST dumpers
// =============================================================================

// dump_list(x0 Node** array, x1 count): " X" for each element.
// Registers: x19 cursor, x20 remaining.
LFUNC dump_list
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
1:  cbz  x20, 2f
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19], #8
    bl   dump_node
    sub  x20, x20, #1
    b    1b
2:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF dump_list

// dump_node(x0 Node* or 0)
// Registers: x19 node, w20 kind, w21 type / scratch, x22 scratch.
LFUNC dump_node
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    cbnz x19, 1f
    ADR_L x0, s_under
    bl   out_s
    b    .Ldn_ret
1:  ldr  w9, [x19, #N_FLAGS]
    tbz  w9, #4, 2f                 // NF_PAREN == 16
    mov  w0, #'^'
    bl   out_c
2:  ldr  w20, [x19, #N_KIND]
    cmp  w20, #NK_LIT
    b.eq .Ldn_lit
    cmp  w20, #NK_COL
    b.eq .Ldn_col
    cmp  w20, #NK_UNARY
    b.eq .Ldn_unary
    cmp  w20, #NK_BINARY
    b.eq .Ldn_binary
    cmp  w20, #NK_ISNULL
    b.eq .Ldn_isnull
    cmp  w20, #NK_CAST
    b.eq .Ldn_cast
    cmp  w20, #NK_FUNC
    b.eq .Ldn_func
    cmp  w20, #NK_CASE
    b.eq .Ldn_case
    cmp  w20, #NK_BETWEEN
    b.eq .Ldn_between
    cmp  w20, #NK_IN
    b.eq .Ldn_in
    cmp  w20, #NK_INSUB
    b.eq .Ldn_insub
    cmp  w20, #NK_LIKE
    b.eq .Ldn_like
    cmp  w20, #NK_EXISTS
    b.eq .Ldn_exists
    cmp  w20, #NK_SUBQ
    b.eq .Ldn_subq
    ADR_L x0, s_unknown
    bl   out_s
    b    .Ldn_pos

.Ldn_lit:
    ldr  w9, [x19, #N_FLAGS]
    tbz  w9, #0, 3f                 // NF_NULL
    ADR_L x0, s_null
    bl   out_s
    b    .Ldn_pos
3:  ldr  w21, [x19, #N_TYPE]
    and  w9, w21, #T_KIND_MASK
    ldr  x0, [x19, #N_VAL]
    cmp  w9, #T_INT
    b.eq .Ldn_int
    cmp  w9, #T_DEC
    b.eq .Ldn_dec
    cmp  w9, #T_FLOAT
    b.eq .Ldn_float
    cmp  w9, #T_STR
    b.eq .Ldn_str
    cmp  w9, #T_BOOL
    b.eq .Ldn_bool
    cmp  w9, #T_DATE
    b.eq .Ldn_date
    cmp  w9, #T_TS
    b.eq .Ldn_ts
    ADR_L x0, s_unknown
    bl   out_s
    b    .Ldn_pos
.Ldn_int:
    bl   out_i
    b    .Ldn_pos
.Ldn_dec:
    ADR_L x0, s_dec
    bl   out_s
    ubfx w0, w21, #T_PREC_SHIFT, #8
    bl   out_u
    mov  w0, #','
    bl   out_c
    ubfx w0, w21, #T_SCALE_SHIFT, #8
    bl   out_u
    ADR_L x0, s_paren_colon
    bl   out_s
    ldr  x0, [x19, #N_VAL]
    BR_WIDE w21, w9, 1f
    bl   out_i
    b    .Ldn_pos
1:  and  w1, w21, #~(0xff << T_SCALE_SHIFT) // wide: unscaled digits
    bl   value_to_str
    bl   out_str
    b    .Ldn_pos
.Ldn_float:
    fmov d0, x0
    bl   out_f
    b    .Ldn_pos
.Ldn_str:
    mov  x22, x0
    mov  w0, #'\''
    bl   out_c
    mov  x0, x22
    bl   out_str
    mov  w0, #'\''
    bl   out_c
    b    .Ldn_pos
.Ldn_bool:
    ADR_L x1, s_true
    ADR_L x2, s_false
    cmp  x0, #0
    csel x0, x1, x2, ne
    bl   out_s
    b    .Ldn_pos
.Ldn_date:
    mov  x22, x0
    ADR_L x0, s_date
    bl   out_s
    mov  x0, x22
    bl   out_i
    b    .Ldn_pos
.Ldn_ts:
    mov  x22, x0
    ADR_L x0, s_ts
    bl   out_s
    mov  x0, x22
    bl   out_i
    b    .Ldn_pos

.Ldn_col:
    ldr  x0, [x19, #N_C]
    cbz  x0, 4f
    bl   out_str
    mov  w0, #'.'
    bl   out_c
4:  ldr  x0, [x19, #N_NAME]
    bl   out_str
    b    .Ldn_pos

.Ldn_unary:
.Ldn_binary:
    ADR_L x0, s_open
    bl   out_s
    ldr  w9, [x19, #N_OP]
    ADR_L x10, op_names
    ldr  x0, [x10, x9, lsl #3]
    bl   out_s
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #N_A]
    bl   dump_node
    cmp  w20, #NK_UNARY
    b.eq .Ldn_close
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #N_B]
    bl   dump_node
    b    .Ldn_close

.Ldn_isnull:
    ADR_L x0, s_isnull
    ldr  w9, [x19, #N_OP]
    cbz  w9, 5f
    ADR_L x0, s_isnotnull
5:  bl   out_s
    ldr  x0, [x19, #N_A]
    bl   dump_node
    b    .Ldn_close

.Ldn_cast:
    ADR_L x0, s_cast
    bl   out_s
    ldr  x0, [x19, #N_A]
    bl   dump_node
    ADR_L x0, s_t
    bl   out_s
    ldr  w21, [x19, #N_VAL]
    ldr  w9, [x19, #N_TYPE]
    cmp  w9, w21                    // N_TYPE must equal N_VAL
    b.eq 6f
    ADR_L x0, s_unknown
    bl   out_s
6:  and  w0, w21, #T_KIND_MASK
    bl   out_u
    mov  w0, #'.'
    bl   out_c
    ubfx w0, w21, #T_PREC_SHIFT, #8
    bl   out_u
    mov  w0, #'.'
    bl   out_c
    ubfx w0, w21, #T_SCALE_SHIFT, #8
    bl   out_u
    b    .Ldn_close

.Ldn_func:
    ADR_L x0, s_fn
    bl   out_s
    ldr  x0, [x19, #N_NAME]
    bl   out_str
    ldr  w9, [x19, #N_FLAGS]
    tbz  w9, #2, 7f                 // NF_STAR
    ADR_L x0, s_star_sp
    bl   out_s
7:  ldr  w9, [x19, #N_FLAGS]
    tbz  w9, #1, 8f                 // NF_DISTINCT
    ADR_L x0, s_distinct_sp
    bl   out_s
8:  ldr  x0, [x19, #N_C]
    ldr  x1, [x19, #N_VAL]
    bl   dump_list
    b    .Ldn_close

.Ldn_case:
    ADR_L x0, s_case
    bl   out_s
    ldr  x0, [x19, #N_A]
    bl   dump_node
    ldr  x21, [x19, #N_C]
    ldr  x22, [x19, #N_VAL]
9:  cbz  x22, 10f
    ADR_L x0, s_lbr
    bl   out_s
    ldr  x0, [x21], #8
    bl   dump_node
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x21], #8
    bl   dump_node
    ADR_L x0, s_rbr
    bl   out_s
    sub  x22, x22, #1
    b    9b
10: mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #N_B]
    bl   dump_node
    b    .Ldn_close

.Ldn_between:
    ADR_L x0, s_between
    ADR_L x1, s_notbetween
    bl   .Ldn_negprefix_helper
    ldr  x0, [x19, #N_A]
    bl   dump_node
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #N_B]
    bl   dump_node
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #N_C]
    bl   dump_node
    b    .Ldn_close

.Ldn_in:
    ADR_L x0, s_in
    ADR_L x1, s_notin
    bl   .Ldn_negprefix_helper
    ldr  x0, [x19, #N_A]
    bl   dump_node
    ldr  x0, [x19, #N_C]
    ldr  x1, [x19, #N_VAL]
    bl   dump_list
    b    .Ldn_close

.Ldn_insub:
    ADR_L x0, s_insub
    ADR_L x1, s_notinsub
    bl   .Ldn_negprefix_helper
    ldr  x0, [x19, #N_A]
    bl   dump_node
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #N_C]
    bl   dump_query
    b    .Ldn_close

.Ldn_like:
    ADR_L x0, s_like
    ADR_L x1, s_notlike
    bl   .Ldn_negprefix_helper
    ldr  x0, [x19, #N_A]
    bl   dump_node
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #N_B]
    bl   dump_node
    b    .Ldn_close

.Ldn_exists:
    ADR_L x0, s_exists
    b    11f
.Ldn_subq:
    ADR_L x0, s_subq
11: bl   out_s
    ldr  x0, [x19, #N_C]
    bl   dump_query

.Ldn_close:
    ADR_L x0, s_close
    bl   out_s
.Ldn_pos:
    LDR_G x9, g_dumppos
    cbz  x9, .Ldn_ret
    mov  w0, #'@'
    bl   out_c
    ldr  w0, [x19, #N_LINE]
    bl   out_u
    mov  w0, #':'
    bl   out_c
    ldr  w0, [x19, #N_COL]
    bl   out_u
.Ldn_ret:
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret

// Local subroutine of dump_node (called with bl, own frame): prints x0, or x1
// when the node in x19 has N_OP != 0. Reads the caller's x19 (not modified).
.Ldn_negprefix_helper:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ldr  w9, [x19, #N_OP]
    cmp  w9, #0
    csel x0, x0, x1, eq
    bl   out_s
    ldp  x29, x30, [sp], #16
    ret
ENDF dump_node

// dump_from(x0 FromItem*)    Registers: x19 item.
LFUNC dump_from
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    ldr  w9, [x19, #FR_KIND]
    cmp  w9, #FRK_TABLE
    b.eq 1f
    cmp  w9, #FRK_SUBQUERY
    b.eq 2f
    ldr  w9, [x19, #FR_JOIN]        // join
    ADR_L x0, s_inner
    cmp  w9, #JT_LEFT
    b.ne 5f
    ADR_L x0, s_left
5:  cmp  w9, #JT_CROSS
    b.ne 6f
    ADR_L x0, s_cross
6:  bl   out_s
    ldr  x0, [x19, #FR_LEFT]
    bl   dump_from
    mov  w0, #' '
    bl   out_c
    ldr  x0, [x19, #FR_RIGHT]
    bl   dump_from
    ldr  x9, [x19, #FR_ON]
    cbz  x9, 7f
    ADR_L x0, s_on
    bl   out_s
    ldr  x0, [x19, #FR_ON]
    bl   dump_node
7:  ADR_L x0, s_close
    bl   out_s
    b    9f
1:  ldr  x0, [x19, #FR_NAME]
    bl   out_str
    b    3f
2:  ldr  x0, [x19, #FR_LEFT]
    bl   dump_query
3:  ldr  x9, [x19, #FR_ALIAS]
    cbz  x9, 9f
    ADR_L x0, s_as
    bl   out_s
    ldr  x0, [x19, #FR_ALIAS]
    bl   out_str
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF dump_from

// dump_core(x0 Query*) — select_core part of a query (SELECT ... HAVING)
// Registers: x19 query, x20 cursor, x21 remaining.
LFUNC dump_core
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #-16]!
    mov  x19, x0
    ADR_L x0, s_select
    bl   out_s
    ldr  w9, [x19, #Q_DISTINCT]
    cbz  w9, 5f
    ADR_L x0, s_distinct
    bl   out_s
5:  ldr  x20, [x19, #Q_ITEMS]       // items
    ldr  x21, [x19, #Q_NITEMS]
6:  ldr  w9, [x20, #SI_KIND]
    cmp  w9, #SIK_STAR
    b.ne 7f
    mov  w0, #'*'
    bl   out_c
    b    9f
7:  cmp  w9, #SIK_QSTAR
    b.ne 8f
    ldr  x0, [x20, #SI_QUAL]
    bl   out_str
    ADR_L x0, s_qstar
    bl   out_s
    b    9f
8:  ldr  x0, [x20, #SI_EXPR]
    bl   dump_node
    ldr  x9, [x20, #SI_ALIAS]
    cbz  x9, 9f
    ADR_L x0, s_as
    bl   out_s
    ldr  x0, [x20, #SI_ALIAS]
    bl   out_str
9:  add  x20, x20, #SI_SIZE
    subs x21, x21, #1
    b.eq 10f
    ADR_L x0, s_comma_sp
    bl   out_s
    b    6b
10: ldr  x9, [x19, #Q_FROM]
    cbz  x9, 11f
    ADR_L x0, s_from
    bl   out_s
    ldr  x0, [x19, #Q_FROM]
    bl   dump_from
11: ldr  x9, [x19, #Q_WHERE]
    cbz  x9, 12f
    ADR_L x0, s_where
    bl   out_s
    ldr  x0, [x19, #Q_WHERE]
    bl   dump_node
12: ldr  x9, [x19, #Q_NGROUP]
    cbz  x9, 13f
    ADR_L x0, s_group
    bl   out_s
    ldr  x0, [x19, #Q_GROUP]
    ldr  x1, [x19, #Q_NGROUP]
    bl   dump_list
13: ldr  x9, [x19, #Q_HAVING]
    cbz  x9, 14f
    ADR_L x0, s_having
    bl   out_s
    ldr  x0, [x19, #Q_HAVING]
    bl   dump_node
14: ldr  x21, [sp], #16
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF dump_core

// dump_query(x0 Query*)
// Registers: x19 query, x20 cursor, x21 remaining, x22 scratch.
LFUNC dump_query
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    ADR_L x0, s_qopen
    bl   out_s
    // WITH
    ldr  x21, [x19, #Q_NCTES]
    cbz  x21, .Ldq_select
    ADR_L x0, s_with
    bl   out_s
    ldr  x20, [x19, #Q_CTES]
1:  ldr  x0, [x20, #CTE_NAME]
    bl   out_str
    ldr  x22, [x20, #CTE_NCOLS]
    cbz  x22, 3f
    mov  w0, #'('
    bl   out_c
    mov  x22, #0
2:  cbz  x22, 21f
    mov  w0, #','
    bl   out_c
21: ldr  x9, [x20, #CTE_COLS]
    ldr  x0, [x9, x22, lsl #3]
    bl   out_str
    add  x22, x22, #1
    ldr  x9, [x20, #CTE_NCOLS]
    cmp  x22, x9
    b.lo 2b
    mov  w0, #')'
    bl   out_c
3:  mov  w0, #'='
    bl   out_c
    ldr  x0, [x20, #CTE_QUERY]
    bl   dump_query
    add  x20, x20, #CTE_SIZE
    subs x21, x21, #1
    b.eq 4f
    ADR_L x0, s_comma_sp
    bl   out_s
    b    1b
4:  mov  w0, #' '
    bl   out_c
.Ldq_select:
    ldr  x21, [x19, #Q_NUNION]      // UNION ALL compound: the branches
    cbnz x21, 1f
    mov  x0, x19
    bl   dump_core
    b    14f
1:  ldr  x20, [x19, #Q_UNION]
2:  ldr  x0, [x20], #8
    bl   dump_core
    subs x21, x21, #1
    b.eq 14f
    ADR_L x0, s_union_all
    bl   out_s
    b    2b
14: ldr  x21, [x19, #Q_NORDER]
    cbz  x21, 18f
    ADR_L x0, s_order
    bl   out_s
    ldr  x20, [x19, #Q_ORDER]
15: ldr  x0, [x20, #OI_EXPR]
    bl   dump_node
    ldr  w9, [x20, #OI_DESC]
    cbz  w9, 16f
    ADR_L x0, s_desc
    bl   out_s
16: ldr  w9, [x20, #OI_NULLS]
    cbz  w9, 17f
    ADR_L x0, s_nf
    cmp  w9, #1
    b.eq 161f
    ADR_L x0, s_nl
161: bl  out_s
17: add  x20, x20, #OI_SIZE
    subs x21, x21, #1
    b.eq 18f
    ADR_L x0, s_comma_sp
    bl   out_s
    b    15b
18: ldr  x9, [x19, #Q_LIMIT]
    cbz  x9, 19f
    ADR_L x0, s_limit
    bl   out_s
    ldr  x0, [x19, #Q_LIMIT]
    bl   dump_node
19: ldr  x9, [x19, #Q_OFFSET]
    cbz  x9, 20f
    ADR_L x0, s_offset
    bl   out_s
    ldr  x0, [x19, #Q_OFFSET]
    bl   dump_node
20: ADR_L x0, s_qclose
    bl   out_s
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF dump_query

// dump_stmt(x0 Statement*)   Registers: x19 statement.
LFUNC dump_stmt
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    ldr  w9, [x19, #ST_KIND]
    cmp  w9, #SK_QUERY
    b.eq 2f
    cmp  w9, #SK_EXPLAIN
    b.eq 1f
    cmp  w9, #SK_CREATE_INDEX
    b.eq 3f
    ADR_L x0, s_drop                // SK_DROP_INDEX
    bl   out_s
    ldr  x0, [x19, #ST_INDEX]
    bl   out_str
    b    4f
1:  ADR_L x0, s_explain
    bl   out_s
2:  ldr  x0, [x19, #ST_QUERY]
    bl   dump_query
    b    9f
3:  ADR_L x0, s_create
    bl   out_s
    ldr  x0, [x19, #ST_INDEX]
    bl   out_str
    ADR_L x0, s_on2
    bl   out_s
    ldr  x0, [x19, #ST_TABLE]
    bl   out_str
    mov  w0, #'('
    bl   out_c
    ldr  x0, [x19, #ST_COLUMN]
    bl   out_str
    ADR_L x0, s_using
    bl   out_s
    ldr  w0, [x19, #ST_USING]
    bl   out_u
4:  ADR_L x0, s_flags
    bl   out_s
    ldr  w0, [x19, #ST_FLAGS]
    bl   out_u
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF dump_stmt

    NOTE_GNU_STACK
