# SQL Grammar (PolyQuery SQL v1)

## 1. Lexical structure

* Input is UTF-8. Keywords and unquoted identifiers are ASCII case-insensitive.
* Whitespace: space, tab, CR, LF. Comments: `-- …` to end of line, `/* … */`
  (not nested). An unterminated block comment or string ⇒ `PARSE_ERROR`.
* **Identifiers**: unquoted `[A-Za-z_][A-Za-z0-9_]*` that is not a reserved
  keyword; or double-quoted `"…"` with `""` as an escaped quote (may contain any
  characters, may be a keyword). Identifier *matching* is ASCII
  case-insensitive in both forms (§semantics 1).
* **Reserved keywords** (cannot be unquoted identifiers):
  `ALL AND AS ASC BETWEEN BY CASE CAST CREATE CROSS DATE DESC DISTINCT DROP ELSE
  END EXISTS EXPLAIN FALSE FIRST FROM FULL GROUP HAVING IF IN INDEX INNER IS JOIN
  LAST LEFT LIKE LIMIT NOT NULL NULLS OFFSET ON OR ORDER OUTER RIGHT SELECT THEN
  TIMESTAMP TRUE UNION USING WHEN WHERE WITH`
  (`FULL`, `RIGHT`, `UNION` are reserved for future use; using them as syntax ⇒
  `UNSUPPORTED`.)
* Function names (`COUNT`, `UPPER`, …) and `HASH`, `BTREE` are **not** reserved.
* Numeric literals: `digits`, `digits.digits?`, `.digits`, optionally followed by
  an exponent `[eE][+-]?digits`. No sign is part of a literal (unary minus is an
  operator). Hex literals are not supported.
* String literals: `'…'` with `''` escaping a quote. No backslash escapes.
* Operators/punctuation: `+ - * / % || = <> != < <= > >= ( ) , . ;`
* A single trailing `;` is permitted. Multiple statements per request ⇒ `PARSE_ERROR`.

Errors SHOULD carry a 1-based `line`/`column` position of the offending token.

## 2. Grammar (EBNF)

```ebnf
statement      = ( query | create_index | drop_index | explain ) [ ";" ] ;

explain        = "EXPLAIN" query ;
create_index   = "CREATE" "INDEX" [ "IF" "NOT" "EXISTS" ] ident "ON" ident
                 "(" ident ")" [ "USING" ( "HASH" | "BTREE" ) ] ;
drop_index     = "DROP" "INDEX" [ "IF" "EXISTS" ] ident ;

query          = [ with_clause ] select_core
                 [ order_by ] [ limit_clause ] ;
with_clause    = "WITH" cte { "," cte } ;
cte            = ident [ "(" ident { "," ident } ")" ] "AS" "(" query ")" ;

select_core    = "SELECT" [ "DISTINCT" | "ALL" ] select_item { "," select_item }
                 [ "FROM" from_item ]
                 [ "WHERE" expr ]
                 [ "GROUP" "BY" expr { "," expr } ]
                 [ "HAVING" expr ] ;

select_item    = "*"
               | ident "." "*"
               | expr [ [ "AS" ] ident ] ;

from_item      = table_ref { join_clause } ;
table_ref      = ident [ [ "AS" ] ident ]                       (* base table or CTE *)
               | "(" query ")" [ "AS" ] ident                   (* derived table: alias required *)
               | "(" from_item ")" ;
join_clause    = [ "INNER" ] "JOIN" table_ref "ON" expr
               | "LEFT" [ "OUTER" ] "JOIN" table_ref "ON" expr
               | "CROSS" "JOIN" table_ref
               | "," table_ref ;                                 (* same as CROSS JOIN *)

order_by       = "ORDER" "BY" order_item { "," order_item } ;
order_item     = expr [ "ASC" | "DESC" ] [ "NULLS" ( "FIRST" | "LAST" ) ] ;
limit_clause   = "LIMIT" expr [ "OFFSET" expr ]
               | "OFFSET" expr [ "LIMIT" expr ] ;

(* Expressions, lowest to highest precedence *)
expr           = or_expr ;
or_expr        = and_expr { "OR" and_expr } ;
and_expr       = not_expr { "AND" not_expr } ;
not_expr       = "NOT" not_expr | predicate ;
predicate      = concat_expr [ comp_op concat_expr
                             | "IS" [ "NOT" ] "NULL"
                             | [ "NOT" ] "BETWEEN" concat_expr "AND" concat_expr
                             | [ "NOT" ] "IN" "(" ( query | expr { "," expr } ) ")"
                             | [ "NOT" ] "LIKE" concat_expr ] ;
comp_op        = "=" | "<>" | "!=" | "<" | "<=" | ">" | ">=" ;
concat_expr    = additive { "||" additive } ;
additive       = multiplicative { ( "+" | "-" ) multiplicative } ;
multiplicative = unary { ( "*" | "/" | "%" ) unary } ;
unary          = ( "-" | "+" ) unary | primary ;
primary        = literal
               | column_ref
               | function_call
               | "CAST" "(" expr "AS" type_name ")"
               | case_expr
               | "EXISTS" "(" query ")"
               | "(" query ")"                                   (* scalar subquery *)
               | "(" expr ")" ;
literal        = number | string | "TRUE" | "FALSE" | "NULL"
               | "DATE" string | "TIMESTAMP" string ;
column_ref     = ident [ "." ident ] ;
function_call  = ident "(" [ "*" | [ "DISTINCT" ] expr { "," expr } ] ")" ;
case_expr      = "CASE" [ expr ] ( "WHEN" expr "THEN" expr ) { "WHEN" expr "THEN" expr }
                 [ "ELSE" expr ] "END" ;
type_name      = ident [ "(" number [ "," number ] ")" ] ;
```

Notes:

* `predicate` is **non-associative**: `a = b = c` ⇒ `PARSE_ERROR`;
  `a < b IS NULL` ⇒ `PARSE_ERROR`. Use parentheses.
* `NOT` binds looser than comparison: `NOT a = b` is `NOT (a = b)`.
* In `BETWEEN x AND y` the `AND` belongs to the BETWEEN.
* `-2 * 3` parses as `(-2) * 3`; `- - 1` is valid.
* `||` binds tighter than comparison and looser than `+`/`-`.
* A `(` at a position where both a `query` and an `expr` could start is a
  subquery iff the next token is `SELECT` or `WITH`.
* `LIMIT`/`OFFSET` expressions MUST be constant INT64 expressions (literals,
  arithmetic on literals); value < 0 ⇒ `INVALID_ARGUMENT`; non-constant ⇒
  `SEMANTIC_ERROR`.
* `query` inside subqueries/CTEs/derived tables may have its own `ORDER BY`
  and `LIMIT`.

### Precedence summary (highest first)

| Level | Operators | Associativity |
|---|---|---|
| 1 | unary `+ -` | right |
| 2 | `* / %` | left |
| 3 | `+ -` | left |
| 4 | `\|\|` | left |
| 5 | `= <> != < <= > >= IS [NOT] NULL, [NOT] BETWEEN, [NOT] IN, [NOT] LIKE` | none |
| 6 | `NOT` | right |
| 7 | `AND` | left |
| 8 | `OR` | left |
