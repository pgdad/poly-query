/*
 * sql.inc - layouts shared by the SQL pipeline:
 *   lexer (tokens) -> parser (AST) -> binder (typed AST + query plan)
 *   -> executor (eval + operators).
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

/* ------------------------------------------------------------ AST / bound expression node (64 bytes) */
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
#define N_SIZE  64

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
#define SS_SIZE     88

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

/* ------------------------------------------------------------ bound query plan (binder output) */
#define QP_TABLE  0    /* Table* or 0 (SELECT without FROM) */
#define QP_WHERE  8    /* bound predicate or 0 */
#define QP_NOUT   16
#define QP_OUT    24   /* OutCol[nout] */
#define QP_NKEYS  32
#define QP_KEYS   40   /* SortKey[nkeys] */
#define QP_AGG    48   /* 1 = aggregated (single group) */
#define QP_NAGGS  56
#define QP_AGGS   64   /* EK_AGG node*[] */
#define QP_LIMIT  72   /* -1 = none */
#define QP_OFFSET 80
#define QP_RANGE  88   /* range variable name pstr */
#define QP_SIZE   96

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

/* runtime value cell (rows, aggregate results) */
#define VAL_P    0
#define VAL_NULL 8
#define VAL_SIZE 16

#endif
