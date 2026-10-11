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

#define NF_NULL     1  /* literal NULL */
#define NF_STAR     2  /* f(*) */
#define NF_DISTINCT 4  /* f(DISTINCT x) */
#define NF_MINLIT   8  /* integer literal 9223372036854775808 awaiting unary minus */
#define NF_PAREN    16 /* expression was parenthesised */

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

/* scalar functions */
#define F_PQ_SLEEP 1

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
#define SS_SIZE     80

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

/* ------------------------------------------------------------ evaluation context */
#define EC_TABLE 0     /* Table* */
#define EC_ROW   8     /* current row index */
#define EC_AGGV  16    /* aggregate values: 16 bytes per slot (payload, null) */
#define EC_SIZE  24

/* runtime value cell (rows, aggregate results) */
#define VAL_P    0
#define VAL_NULL 8
#define VAL_SIZE 16

#endif
