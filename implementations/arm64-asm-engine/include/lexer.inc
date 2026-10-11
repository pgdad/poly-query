// =============================================================================
// lexer.inc — private definitions shared by lexer.S and parser.S
//
// The lexer turns the whole SQL text into a contiguous array of Token records
// (allocated in the request arena) terminated by one TK_EOF token. The parser
// walks that array with a cursor, so arbitrary lookahead is a pointer add.
// =============================================================================

#ifndef LEXER_INC
#define LEXER_INC

// ------------------------------------------------------------ token record ---
// Token (40 bytes)
#define TK_KIND   0        // u32 TK_* or KW_* (keywords have their own kinds)
#define TK_AUX    4        // u32 TK_IDENT: 1 = quoted identifier
                           //     TK_NUMBER: TKN_* form bits
#define TK_PTR    8        // ptr  first byte of the token in the source text
#define TK_LEN    16       // u64  length of the token text (incl. quotes)
#define TK_STR    24       // Str* TK_IDENT: identifier (unquoted: as written;
                           //      quoted: "" collapsed), TK_STRING: decoded
                           //      contents ('' collapsed); 0 otherwise
#define TK_LINE   32       // u32  1-based line of the first byte
#define TK_COL    36       // u32  1-based column (counted in UTF-8 characters)
#define TK_SIZE   40

// TK_AUX bits for TK_NUMBER
#define TKN_DOT   1        // literal contains a '.'
#define TKN_EXP   2        // literal has an exponent part

// ------------------------------------------------------------- token kinds ---
// Operator token kinds deliberately coincide with the OP_* codes of pq.inc
// (TK_PLUS == OP_ADD ... TK_CONCAT == OP_CONCAT, TK_EQ == OP_EQ ... TK_GE ==
// OP_GE) so the parser can use the token kind directly as the operator code.
#define TK_EOF      0
#define TK_IDENT    1
#define TK_NUMBER   2
#define TK_STRING   3
#define TK_PLUS     10     // +   (OP_ADD)
#define TK_MINUS    11     // -   (OP_SUB)
#define TK_STAR     12     // *   (OP_MUL)
#define TK_SLASH    13     // /   (OP_DIV)
#define TK_PERCENT  14     // %   (OP_MOD)
#define TK_CONCAT   15     // ||  (OP_CONCAT)
#define TK_EQ       20     // =   (OP_EQ)
#define TK_NE       21     // <> or !=  (OP_NE)
#define TK_LT       22     // <   (OP_LT)
#define TK_LE       23     // <=  (OP_LE)
#define TK_GT       24     // >   (OP_GT)
#define TK_GE       25     // >=  (OP_GE)
#define TK_LPAREN   30
#define TK_RPAREN   31
#define TK_COMMA    32
#define TK_DOT      33
#define TK_SEMI     34

// --------------------------------------------------------------- keywords ----
// Reserved keywords (grammar.md §1), in alphabetical order. The keyword table
// in lexer.S lists the spellings in exactly this order: KW_BASE + index.
#define KW_BASE      64
#define KW_ALL       64
#define KW_AND       65
#define KW_AS        66
#define KW_ASC       67
#define KW_BETWEEN   68
#define KW_BY        69
#define KW_CASE      70
#define KW_CAST      71
#define KW_CREATE    72
#define KW_CROSS     73
#define KW_DATE      74
#define KW_DESC      75
#define KW_DISTINCT  76
#define KW_DROP      77
#define KW_ELSE      78
#define KW_END       79
#define KW_EXISTS    80
#define KW_EXPLAIN   81
#define KW_FALSE     82
#define KW_FIRST     83
#define KW_FROM      84
#define KW_FULL      85
#define KW_GROUP     86
#define KW_HAVING    87
#define KW_IF        88
#define KW_IN        89
#define KW_INDEX     90
#define KW_INNER     91
#define KW_IS        92
#define KW_JOIN      93
#define KW_LAST      94
#define KW_LEFT      95
#define KW_LIKE      96
#define KW_LIMIT     97
#define KW_NOT       98
#define KW_NULL      99
#define KW_NULLS     100
#define KW_OFFSET    101
#define KW_ON        102
#define KW_OR        103
#define KW_ORDER     104
#define KW_OUTER     105
#define KW_RIGHT     106
#define KW_SELECT    107
#define KW_THEN      108
#define KW_TIMESTAMP 109
#define KW_TRUE      110
#define KW_UNION     111
#define KW_USING     112
#define KW_WHEN      113
#define KW_WHERE     114
#define KW_WITH      115
#define KW_LAST_ID   115

// ---------------------------------------------------------------- lexer API --
// lex_tokenize(x0 ptr, x1 len) -> x0 Token* (array ending with TK_EOF),
//                                 x1 number of tokens before the EOF token
//   raises PARSE_ERROR (unterminated comment/string/identifier, bad character,
//   malformed number) with line/column.
// lex_raise_text(w0 code, x1 prefix cstr, x2 ptr, x3 len, w4 line, w5 col)
//   noreturn: raises with message  prefix + "'" + text (max 64 bytes) + "'".

#endif
