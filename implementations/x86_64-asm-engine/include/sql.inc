/*
 * sql.inc - layouts shared by the SQL pipeline:
 *   lexer (tokens) -> parser (AST) -> binder (typed AST, bound query block)
 *   -> logical plan (lplan.S) -> optimizer rules (optimizer.S, rule_*.S)
 *   -> physical planner (planner.S) -> executor (eval + operators).
 */
#ifndef SQL_INC
#define SQL_INC

/* ------------------------------------------------------------ tokens (32 bytes) */
#define TK_KIND 0      /* u32 TOK_* */
#define TK_ID   4      /* u32 keyword id / operator id / number flags */
#define TK_PTR  8      /* text (for STRING/QIDENT: decoded text, TK_PTR-8 is a pstr*) */
#define TK_LEN  16
#define TK_LINE 24     /* u32, 1-based */
#define TK_COL  28     /* u32, 1-based */
#define TK_SIZE 32

#define TOK_EOF     0
#define TOK_IDENT   1
#define TOK_QIDENT  2
#define TOK_NUMBER  3
#define TOK_STRING  4
#define TOK_KEYWORD 5
#define TOK_OP      6

/* number token flags (TK_ID) */
#define NUMF_DOT 1
#define NUMF_EXP 2

/* operators */
#define OP_PLUS    1
#define OP_MINUS   2
#define OP_STAR    3
#define OP_SLASH   4
#define OP_PERCENT 5
#define OP_CONCAT  6
#define OP_EQ      7
#define OP_NE      8
#define OP_LT      9
#define OP_LE      10
#define OP_GT      11
#define OP_GE      12
#define OP_LPAREN  13
#define OP_RPAREN  14
#define OP_COMMA   15
#define OP_DOT     16
#define OP_SEMI    17

/* reserved keywords (ids index the keyword table in lexer.S) */
#define KW_ALL 1
#define KW_AND 2
#define KW_AS 3
#define KW_ASC 4
#define KW_BETWEEN 5
#define KW_BY 6
#define KW_CASE 7
#define KW_CAST 8
#define KW_CREATE 9
#define KW_CROSS 10
#define KW_DATE 11
#define KW_DESC 12
#define KW_DISTINCT 13
#define KW_DROP 14
#define KW_ELSE 15
#define KW_END 16
#define KW_EXISTS 17
#define KW_EXPLAIN 18
#define KW_FALSE 19
#define KW_FIRST 20
#define KW_FROM 21
#define KW_FULL 22
#define KW_GROUP 23
#define KW_HAVING 24
#define KW_IF 25
#define KW_IN 26
#define KW_INDEX 27
#define KW_INNER 28
#define KW_IS 29
#define KW_JOIN 30
#define KW_LAST 31
#define KW_LEFT 32
#define KW_LIKE 33
#define KW_LIMIT 34
#define KW_NOT 35
#define KW_NULL 36
#define KW_NULLS 37
#define KW_OFFSET 38
#define KW_ON 39
#define KW_OR 40
#define KW_ORDER 41
#define KW_OUTER 42
#define KW_RIGHT 43
#define KW_SELECT 44
#define KW_THEN 45
#define KW_TIMESTAMP 46
#define KW_TRUE 47
#define KW_UNION 48
#define KW_USING 49
#define KW_WHEN 50
#define KW_WHERE 51
#define KW_WITH 52

/* ------------------------------------------------------------ parser state */
#define PS_TOKS  0     /* token array */
#define PS_NTOK  8
#define PS_POS   16
#define PS_DEPTH 24
#define PS_SIZE  32

/* ------------------------------------------------------------ AST / bound expression node (72 bytes) */
#define N_KIND  0      /* u32 EK_* */
#define N_OP    4      /* u32 operator / function id */
#define N_TYPE  8      /* u32 packed type (set by the binder) */
#define N_FLAGS 12     /* u32 NF_* */
#define N_A     16     /* child / qualifier / args */
#define N_B     24     /* child / name */
#define N_V1    32
#define N_V2    40
#define N_LINE  48     /* u32 */
#define N_COL   52     /* u32 */
#define N_V3    56
#define N_WRITTEN 64   /* 0, or a copy of the node as written in the query when
                          the optimizer rewrote it in place (rule_fold.S) */
#define N_SIZE  72

#define EK_LIT    1    /* V1 payload; NF_NULL for NULL */
#define EK_COL    2    /* A qualifier pstr|0, B name pstr; bound: V1 column index */
#define EK_UNARY  3    /* OP U_*, A operand */
#define EK_BINARY 4    /* OP B_*, A left, B right */
#define EK_ISNULL 5    /* OP 0 = IS NULL, 1 = IS NOT NULL; A operand */
#define EK_CAST   6    /* A operand, V1 target packed type */
#define EK_FUNC   7    /* B name pstr, A node*[] args, V1 nargs; NF_STAR, NF_DISTINCT; bound: OP = F_* */
#define EK_AGG    8    /* bound aggregate: OP AGG_*, A argument (0 for COUNT(*)), V2 slot */
#define EK_CASE    9   /* A operand (simple CASE) or 0; B node*[2*V1] = when1,then1,when2,then2..;
                          V1 number of WHEN pairs; V2 ELSE expr or 0 */
#define EK_BETWEEN 10  /* A x, B low, V1 high; OP 1 = NOT BETWEEN */
#define EK_INLIST  11  /* A x, B node*[V1] list items; OP 1 = NOT IN */
#define EK_LIKE    12  /* A string, B pattern; OP 1 = NOT LIKE */
#define EK_SUBQ    13  /* scalar subquery: V1 SelectStmt*; bound: V2 plan*, V3 cached value */
#define EK_INSUBQ  14  /* A x, V1 SelectStmt*; OP 1 = NOT IN; bound: V2 plan*, V3 cached set */
#define EK_EXISTS  15  /* V1 SelectStmt*; bound: V2 plan*, V3 cached result */
#define EK_OUTER   16  /* bound correlated column: V1 column, V2 range variable, V3 scope levels up */

#define NF_NULL     1  /* literal NULL */
#define NF_STAR     2  /* f(*) */
#define NF_DISTINCT 4  /* f(DISTINCT x) */
#define NF_MINLIT   8  /* integer literal 9223372036854775808 awaiting unary minus */
#define NF_PAREN    16 /* expression was parenthesised */
#define NF_CACHED   32 /* subquery result cached in V3 */
#define NF_CORR     64 /* subquery references an enclosing query */

#define U_NEG 1
#define U_POS 2
#define U_NOT 3

#define B_ADD 1
#define B_SUB 2
#define B_MUL 3
#define B_DIV 4
#define B_MOD 5
#define B_CONCAT 6
#define B_EQ 7
#define B_NE 8
#define B_LT 9
#define B_LE 10
#define B_GT 11
#define B_GE 12
#define B_AND 13
#define B_OR 14

/* scalar functions (EK_FUNC N_OP after binding) */
#define F_PQ_SLEEP 1
#define F_ABS 2
#define F_ROUND 3
#define F_FLOOR 4
#define F_CEIL 5
#define F_SQRT 6
#define F_POWER 7
#define F_MOD 8
#define F_LENGTH 9
#define F_UPPER 10
#define F_LOWER 11
#define F_SUBSTR 12
#define F_TRIM 13
#define F_LTRIM 14
#define F_RTRIM 15
#define F_REPLACE 16
#define F_CONCAT 17
#define F_COALESCE 18
#define F_NULLIF 19
#define F_YEAR 20
#define F_MONTH 21
#define F_DAY 22
#define F_HOUR 23
#define F_MINUTE 24
#define F_SECOND 25
#define F_DATE_TRUNC 26
#define F_DATE_DIFF 27

/* aggregates */
#define AGG_COUNT_STAR 1
#define AGG_COUNT 2
#define AGG_SUM 3
#define AGG_AVG 4
#define AGG_MIN 5
#define AGG_MAX 6

/* ------------------------------------------------------------ SELECT statement (parser output) */
#define SS_ITEMS    0  /* Vec* of SelectItem* */
#define SS_FROM     8  /* table name pstr or 0 */
#define SS_ALIAS    16 /* alias pstr or 0 */
#define SS_WHERE    24
#define SS_GROUPBY  32 /* Vec* of expr or 0 */
#define SS_HAVING   40
#define SS_ORDER    48 /* Vec* of OrderItem* or 0 */
#define SS_LIMIT    56
#define SS_OFFSET   64
#define SS_DISTINCT 72
#define SS_WITH     80 /* Vec* of Cte* or 0 */
#define SS_UNION    88 /* compound (UNION ALL): Vec* of branch SelectStmt* (select
                          cores), else 0.  A compound statement only carries
                          SS_WITH, SS_ORDER, SS_LIMIT, SS_OFFSET itself. */
#define SS_SIZE     96

/* ------------------------------------------------------------ statement (sql_parse output) */
#define STMT_QUERY        1
#define STMT_EXPLAIN      2
#define STMT_CREATE_INDEX 3
#define STMT_DROP_INDEX   4
#define ST_KIND   0
#define ST_QUERY  8    /* SelectStmt* (query / explain) */
#define ST_NAME   16   /* index name pstr */
#define ST_TABLE  24   /* table pstr (create index) */
#define ST_COLUMN 32   /* column pstr (create index) */
#define ST_IFX    40   /* IF [NOT] EXISTS given */
#define ST_USING  48   /* 0 default, 1 HASH, 2 BTREE */
#define ST_SIZE   56

/* ------------------------------------------------------------ FROM items (parser output) */
#define FK_TABLE   1
#define FK_DERIVED 2
#define FK_JOIN    3
#define FI_KIND  0
#define FI_NAME  8     /* table / CTE name pstr (FK_TABLE) */
#define FI_ALIAS 16    /* alias pstr or 0 (FK_TABLE, FK_DERIVED) */
#define FI_QUERY 24    /* SelectStmt* (FK_DERIVED) */
#define FI_LEFT  32    /* FK_JOIN */
#define FI_RIGHT 40
#define FI_JTYPE 48    /* JT_* */
#define FI_ON    56    /* expr or 0 */
#define FI_SIZE  64

#define JT_INNER 1
#define JT_LEFT  2
#define JT_CROSS 3

/* CTE */
#define CTE_NAME  0    /* pstr */
#define CTE_COLS  8    /* Vec* of pstr or 0 */
#define CTE_QUERY 16   /* SelectStmt* */
#define CTE_PLAN  24   /* bound plan (binder) */
#define CTE_SIZE  32

#define SI_EXPR  0
#define SI_ALIAS 8     /* pstr or 0 */
#define SI_KIND  16    /* 0 expr, 1 '*', 2 'q.*' */
#define SI_QUAL  24    /* pstr for q.* */
#define SI_SIZE  32

#define OI_EXPR  0
#define OI_DESC  8
#define OI_NULLS 16    /* 0 default, 1 NULLS FIRST, 2 NULLS LAST */
#define OI_SIZE  24

/* ------------------------------------------------------------ query block
 * One per SELECT (top level, subquery, derived table, CTE).  The binder
 * fills the semantic part (range variables, outputs with names and types,
 * bound WHERE / GROUP BY / HAVING / ORDER BY / LIMIT, correlation and the
 * logical FROM tree QP_LFROM); lp_build turns it into the logical plan
 * QP_LOGICAL, the optimizer rewrites that, and the physical planner derives
 * the executable fields (marked "physical") from the optimized logical plan:
 * the physical FROM tree, residual WHERE, HAVING, outputs, keys, limits. */
#define QP_FROM     0    /* physical: FromPlan* or 0 (SELECT without FROM) */
#define QP_WHERE    8    /* bound predicate; physical: residual WHERE or 0 */
#define QP_NOUT     16
#define QP_OUT      24   /* OutCol[nout] */
#define QP_NKEYS    32
#define QP_KEYS     40   /* SortKey[nkeys] */
#define QP_AGG      48   /* 1 = aggregated query */
#define QP_NAGGS    56
#define QP_AGGS     64   /* EK_AGG node*[] */
#define QP_LIMIT    72   /* -1 = none */
#define QP_OFFSET   80
#define QP_NRV      88   /* number of range variables */
#define QP_RVS      96   /* RangeVar*[nrv] */
#define QP_NGROUP   104
#define QP_GROUP    112  /* bound GROUP BY expressions node*[] */
#define QP_HAVING   120
#define QP_DISTINCT 128
#define QP_CORR     136  /* references an enclosing query: never cached */
#define QP_CACHE    144  /* cached Result* of an uncorrelated plan */
/* compound (UNION ALL) plan: QP_NUNION > 0.  Only QP_NOUT/QP_OUT (names of
 * the first branch, common types; OC_EXPR = first branch's expression),
 * QP_NKEYS/QP_KEYS (SK_OUT >= 0 only), QP_LIMIT/QP_OFFSET, QP_CORR and
 * QP_CACHE are meaningful; QP_NRV = 0, QP_FROM = 0. */
#define QP_NUNION   152  /* number of branches, 0 = ordinary query block */
#define QP_UNION    160  /* plan*[nunion] branch plans, in order */
#define QP_LFROM    168  /* bound FROM clause: logical Scan / Join tree or 0 */
#define QP_LOGICAL  176  /* optimized logical plan (lplan.S) */
#define QP_SIZE     184

/* range variable */
#define RV_NAME  0     /* pstr: alias or table/CTE name */
#define RV_TABLE 8     /* base Table* or 0 */
#define RV_PLAN  16    /* plan of a derived table / CTE */
#define RV_NCOLS 24
#define RV_COLS  32    /* RVC entries: pstr name, u64 packed type */
#define RV_USED  40    /* u8[ncols], 1 = column referenced by the query */
#define RV_SIZE  48
#define RVC_NAME 0
#define RVC_TYPE 8
#define RVC_SIZE 16

/* physical FROM plan node (planner.S builds it from the logical FROM tree) */
#define FP_KIND  0     /* FK_TABLE (scan of range variable FP_RV) or FK_JOIN */
#define FP_RV    8
#define FP_LEFT  16
#define FP_RIGHT 24
#define FP_JTYPE 32    /* JT_* */
#define FP_ON    40    /* bound join condition or 0 */
#define FP_LKEY  48    /* equi-join key over the left input (hash / merge join) or 0 */
#define FP_RKEY  56    /* matching key over the right input */
#define FP_RLO   64    /* range variables [RLO, RHI) come from the right input */
#define FP_RHI   72
#define FP_FILTER 80   /* scan: pushed-down WHERE conjuncts (AND chain) or 0 */
#define FP_INDEX  88   /* scan: Index* of an IndexScan or 0 */
#define FP_IMODE  96   /* IM_EQ or IM_RANGE */
#define FP_IVALS  104  /* IM_EQ: u64 values[FP_INV]; IM_RANGE: lower bound */
#define FP_INV    112  /* IM_EQ: value count; IM_RANGE: upper bound */
#define FP_IFLAGS 120  /* IM_RANGE: RF_* */
#define FP_RGSKIP 128  /* scan of a PQCF-backed table: u8[nrg], 1 = skip, or 0 */
#define FP_NSKIP  136  /* number of skipped row groups */
#define FP_EST    144  /* estimated output rows */
#define FP_BUILDL 152  /* hash join: 1 = build on the left input */
#define FP_ALGO   160  /* join: JA_* physical algorithm (planner.S) */
#define FP_SIZE   168

/* ------------------------------------------------------------ logical plan (lplan.S)
 * A tree of relational operators, independent of execution strategy, one per
 * query block.  Built by lp_build as
 *   [Limit] > [Sort] > [Distinct] > Project > [Filter (HAVING)] > [Aggregate]
 *   > [Filter (WHERE)] > FROM tree (Scan | SubqueryScan | Join) or Values,
 * or for a UNION ALL compound [Limit] > [Sort] > UnionAll.
 * Expressions are the binder's typed nodes (shared, rewritten in place by
 * constant folding).  Nested query blocks (derived tables, CTEs, subqueries,
 * UNION ALL branches) are referenced by their query block; rules never
 * descend into them (each block is optimized when it is planned). */
#define LP_KIND 0      /* LK_* */
#define LP_IN   8      /* input (left input of a Join) or 0 */
#define LP_IN2  16     /* right input of a Join */
#define LP_A    24     /* kind-specific fields */
#define LP_B    32
#define LP_C    40
#define LP_D    48
#define LP_SIZE 56

#define LK_SCAN      1 /* base table:  A range variable index, B RangeVar*,
                          C u8[ncols] output columns (1 = produced) */
#define LK_SUBQUERY  2 /* derived table / CTE reference: A, B, C as Scan,
                          D query block of the derived table */
#define LK_JOIN      3 /* A JT_*, B ON condition or 0, C/D range variables
                          [C, D) come from the right input */
#define LK_FILTER    4 /* A predicate, B LFF_* placement flags */
#define LK_PROJECT   5 /* A number of outputs, B OutCol[] */
#define LK_AGGREGATE 6 /* A number of GROUP BY keys, B node*[], C number of
                          aggregate calls, D EK_AGG node*[] */
#define LK_SORT      7 /* A number of keys, B SortKey[] */
#define LK_LIMIT     8 /* A limit (-1 = none), B offset */
#define LK_DISTINCT  9
#define LK_UNION     10 /* A number of branches, B query block*[] */
#define LK_VALUES    11 /* SELECT without FROM: one empty row */

/* Filter placement, decided by the pushdown rule; a Filter without these
 * flags has not been placed (optimize: false) and the physical planner
 * places its conjuncts itself (indexes-and-planning.md section 3). */
#define LFF_PUSHED   1 /* evaluated at the scan directly below */
#define LFF_RESIDUAL 2 /* conjuncts that must stay above the FROM tree */

#define JA_NL    0     /* nested loop (any condition, CROSS joins) */
#define JA_HASH  1     /* hash join on FP_LKEY = FP_RKEY */
#define JA_MERGE 2     /* sort-merge join on FP_LKEY = FP_RKEY */

/* Phase 5 execution options (protocol.S parses them into g_opt_*; the
 * physical planner resolves g_exec_mode / g_exec_threads, which the
 * executor follows) */
#define MODE_AUTO 0
#define MODE_ROW  1
#define MODE_VEC  2
#define JOIN_AUTO 0
#define JOIN_HASH 1
#define JOIN_MERGE 2
#define JOIN_NL   3
#define MAX_THREADS 64

#define IM_EQ    1
#define IM_RANGE 2

/* materialised query result */
#define RS_NCOLS 0
#define RS_NROWS 8
#define RS_ROWS  16    /* row*[]; a row is VAL cells (outputs, then sort keys) */
#define RS_PLAN  24
#define RS_SIZE  32

#define OC_EXPR 0
#define OC_NAME 8      /* pstr */
#define OC_TYPE 16
#define OC_SIZE 24

#define SK_EXPR   0    /* bound expr (when SK_OUT = -1) */
#define SK_OUT    8    /* output column index or -1 */
#define SK_DESC   16
#define SK_NFIRST 24   /* 1 = nulls first */
#define SK_TYPE   32
#define SK_SIZE   40

/* ------------------------------------------------------------ evaluation context
 * A zero-filled context is valid for constant expressions. */
#define EC_TUPLE  0    /* u64 row index per range variable (-1 = NULL-padded) */
#define EC_TABLES 8    /* Table*[] per range variable */
#define EC_AGGV   16   /* aggregate values: 16 bytes per slot (payload, null) */
#define EC_OUTER  24   /* enclosing query's context (correlated subqueries) or 0 */
#define EC_SIZE   64

/* ------------------------------------------------------------ hash table over value-cell keys (hash.S) */
#define HT_NB    0     /* bucket count (power of two) */
#define HT_BKT   8     /* Entry*[nb] */
#define HT_N     16    /* entries */
#define HT_NK    24    /* key cells per entry */
#define HT_TYPES 32    /* u64 packed type per key cell (low 32 bits used) */
#define HT_FAST  40    /* hash join: FastTable* replacing the chains, or 0 (pexec.S) */
#define HT_SIZE  48
#define EN_NEXT  0
#define EN_HASH  8
#define EN_KEY   16    /* VAL cells[nk] (owned by the caller, must stay alive) */
#define EN_D0    24    /* user data */
#define EN_D1    32
#define EN_SIZE  40

/* runtime value cell (rows, aggregate results) */
#define VAL_P    0
#define VAL_NULL 8
#define VAL_SIZE 16

#endif
