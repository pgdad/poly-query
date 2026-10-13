"""Recursive-descent parser for PolyQuery SQL v1 (spec/sql/grammar.md §2)."""

from __future__ import annotations

from collections import deque

from .. import errors
from ..limits import Check, StatementMeter, check_text_length, no_check
from . import ast
from .lexer import FUTURE_KEYWORDS, Lexer, Token, TokenKind

_COMPARISON_OPS = ("=", "<>", "!=", "<", "<=", ">", ">=")
# tokens that are operands (CR-6 §1): literals and column references
_OPERAND_KINDS = (TokenKind.NUMBER, TokenKind.STRING, TokenKind.IDENT)
_LITERAL_KEYWORDS = ("TRUE", "FALSE", "NULL", "DATE", "TIMESTAMP")
_PREDICATES = ("IS", "BETWEEN", "IN", "LIKE", "NOT")


class Parser:
    """Parses one statement, measuring it against the size limits of CR-6
    (``meter``): beyond them it fails with RESOURCE_LIMIT as soon as the
    limit is reached. Tokens are lexed on demand; ``check`` is the deadline
    check of the statement."""

    def __init__(self, text: str, check: Check = no_check):
        self.check = check
        self.meter = StatementMeter()
        self._stream = Lexer(text, check).tokens()
        self._buffer: deque[Token] = deque()
        self._fill(1)

    # ------------------------------------------------------------ helpers

    def _fill(self, count: int) -> None:
        buffer = self._buffer
        while len(buffer) < count and not (buffer and buffer[-1].kind is TokenKind.EOF):
            buffer.append(next(self._stream))

    @property
    def tok(self) -> Token:
        return self._buffer[0]

    def peek(self, offset: int = 1) -> Token:
        self._fill(offset + 1)
        return self._buffer[min(offset, len(self._buffer) - 1)]

    def advance(self) -> Token:
        t = self._buffer[0]
        if t.kind is not TokenKind.EOF:
            self._buffer.popleft()
            self._fill(1)
        return t

    def _lex_rest(self) -> None:
        """Lexes the remaining text (lexical errors are reported before
        UNSUPPORTED, as when the whole statement was lexed up front)."""
        for _ in self._stream:
            pass

    def error(self, message: str, tok: Token | None = None) -> errors.PolyQueryError:
        tok = tok or self.tok
        return errors.parse_error(
            f"{message} at line {tok.line}, column {tok.column} (found {tok.describe()})",
            line=tok.line,
            column=tok.column,
        )

    def unsupported(self, tok: Token) -> errors.PolyQueryError:
        self._lex_rest()
        return errors.unsupported(f"{tok.value} is not supported", line=tok.line, column=tok.column)

    def accept_keyword(self, *words: str) -> Token | None:
        if self.tok.is_keyword(*words):
            return self.advance()
        return None

    def expect_keyword(self, word: str) -> Token:
        if not self.tok.is_keyword(word):
            raise self.error(f"expected {word}")
        return self.advance()

    def accept_op(self, *ops: str) -> Token | None:
        if self.tok.is_op(*ops):
            return self.advance()
        return None

    def expect_op(self, op: str) -> Token:
        if not self.tok.is_op(op):
            raise self.error(f"expected '{op}'")
        return self.advance()

    def expect_ident(self, what: str = "identifier") -> str:
        if self.tok.kind is not TokenKind.IDENT:
            raise self.error(f"expected {what}")
        return self.advance().value

    def expect_alias(self, what: str) -> str:
        """The alias after an explicit AS: an identifier, or a keyword that
        is reserved only for future syntax (``AS full``)."""
        if self.tok.kind is TokenKind.KEYWORD and self.tok.value in FUTURE_KEYWORDS:
            return self.advance().text
        return self.expect_ident(what)

    @staticmethod
    def pos(tok: Token) -> ast.Pos:
        return (tok.line, tok.column)

    # ------------------------------------------------------------ statements

    def parse_statement(self) -> ast.Statement:
        start = self.tok
        if self.accept_keyword("EXPLAIN"):
            stmt: ast.Statement = ast.Explain(self.pos(start), self.parse_query())
        elif start.is_keyword("CREATE"):
            stmt = self.parse_create_index()
        elif start.is_keyword("DROP"):
            stmt = self.parse_drop_index()
        elif start.is_keyword("SELECT", "WITH"):
            stmt = ast.QueryStatement(self.pos(start), self.parse_query())
        else:
            raise self.error("expected SELECT, WITH, EXPLAIN, CREATE INDEX or DROP INDEX")
        self.accept_op(";")
        if self.tok.kind is not TokenKind.EOF:
            raise self.error("unexpected token after end of statement")
        return stmt

    def parse_create_index(self) -> ast.CreateIndex:
        start = self.expect_keyword("CREATE")
        self.expect_keyword("INDEX")
        if_not_exists = False
        if self.accept_keyword("IF"):
            self.expect_keyword("NOT")
            self.expect_keyword("EXISTS")
            if_not_exists = True
        name = self.expect_ident("index name")
        self.expect_keyword("ON")
        table = self.expect_ident("table name")
        self.expect_op("(")
        column = self.expect_ident("column name")
        self.expect_op(")")
        kind = "BTREE"
        if self.accept_keyword("USING"):
            tok = self.tok
            if tok.kind is not TokenKind.IDENT or tok.value.upper() not in ("HASH", "BTREE"):
                raise self.error("expected HASH or BTREE")
            kind = self.advance().value.upper()
        return ast.CreateIndex(self.pos(start), name, table, column, kind, if_not_exists)

    def parse_drop_index(self) -> ast.DropIndex:
        start = self.expect_keyword("DROP")
        self.expect_keyword("INDEX")
        if_exists = False
        if self.accept_keyword("IF"):
            self.expect_keyword("EXISTS")
            if_exists = True
        name = self.expect_ident("index name")
        return ast.DropIndex(self.pos(start), name, if_exists)

    # ------------------------------------------------------------ queries

    def parse_query(self) -> ast.Query:
        start = self.tok
        ctes: list[ast.CommonTableExpr] = []
        if self.accept_keyword("WITH"):
            ctes.append(self.parse_cte())
            while self.accept_op(","):
                ctes.append(self.parse_cte())
        body = self.parse_compound()
        query = ast.Query(self.pos(start), body, ctes)
        if self.accept_keyword("ORDER"):
            self.expect_keyword("BY")
            query.order_by.append(self.parse_order_item())
            while self.accept_op(","):
                query.order_by.append(self.parse_order_item())
        if self.accept_keyword("LIMIT"):
            query.limit = self.parse_expr()
            if self.accept_keyword("OFFSET"):
                query.offset = self.parse_expr()
        elif self.accept_keyword("OFFSET"):
            query.offset = self.parse_expr()
            if self.accept_keyword("LIMIT"):
                query.limit = self.parse_expr()
        return query

    def parse_cte(self) -> ast.CommonTableExpr:
        start = self.tok
        name = self.expect_ident("CTE name")
        columns = None
        if self.accept_op("("):
            columns = [self.expect_ident("column name")]
            while self.accept_op(","):
                columns.append(self.expect_ident("column name"))
            self.expect_op(")")
        self.expect_keyword("AS")
        self.expect_op("(")
        self.meter.enter()
        query = self.parse_query()
        self.meter.leave()
        self.expect_op(")")
        return ast.CommonTableExpr(self.pos(start), name, columns, query)

    def parse_compound(self) -> ast.Select | ast.Compound:
        """``select_core { UNION ALL select_core }``; branches are plain
        select cores (no ORDER BY / LIMIT, no parentheses). ``UNION`` without
        ``ALL`` is reserved."""
        first = self.parse_select_core()
        branches = [first]
        while self.tok.is_keyword("UNION"):
            if not self.peek().is_keyword("ALL"):
                raise self.unsupported(self.tok)
            self.advance()
            self.advance()
            if not self.tok.is_keyword("SELECT"):
                raise self.error("expected SELECT after UNION ALL")
            branches.append(self.parse_select_core())
        return first if len(branches) == 1 else ast.Compound(first.pos, branches)

    def parse_select_core(self) -> ast.Select:
        start = self.expect_keyword("SELECT")
        distinct = False
        if self.accept_keyword("DISTINCT"):
            distinct = True
        else:
            self.accept_keyword("ALL")
        items = [self.parse_select_item()]
        while self.accept_op(","):
            items.append(self.parse_select_item())
        select = ast.Select(self.pos(start), items, distinct)
        if self.accept_keyword("FROM"):
            select.from_ = self.parse_from_item()
        if self.accept_keyword("WHERE"):
            select.where = self.parse_expr()
        if self.accept_keyword("GROUP"):
            self.expect_keyword("BY")
            select.group_by.append(self.parse_expr())
            while self.accept_op(","):
                select.group_by.append(self.parse_expr())
        if self.accept_keyword("HAVING"):
            select.having = self.parse_expr()
        return select

    def parse_select_item(self) -> ast.SelectItem:
        start = self.tok
        if self.accept_op("*"):
            self.meter.operand()
            return ast.SelectItem(self.pos(start), None, is_star=True)
        if (
            start.kind is TokenKind.IDENT
            and self.peek().is_op(".")
            and self.peek(2).is_op("*")
        ):
            self.meter.operand()
            self.advance()
            self.advance()
            self.advance()
            return ast.SelectItem(self.pos(start), None, star_qualifier=start.value, is_star=True)
        expr = self.parse_expr()
        alias = None
        if self.accept_keyword("AS"):
            alias = self.expect_alias("alias")
        elif self.tok.kind is TokenKind.IDENT:
            alias = self.advance().value
        return ast.SelectItem(self.pos(start), expr, alias)

    def parse_from_item(self) -> ast.FromItem:
        item = self.parse_table_ref()
        while True:
            start = self.tok
            if self.accept_op(","):
                item = ast.Join(self.pos(start), "CROSS", item, self.parse_table_ref(), None)
            elif self.accept_keyword("CROSS"):
                self.expect_keyword("JOIN")
                item = ast.Join(self.pos(start), "CROSS", item, self.parse_table_ref(), None)
            elif self.tok.is_keyword("INNER", "JOIN"):
                if self.accept_keyword("INNER"):
                    self.expect_keyword("JOIN")
                else:
                    self.advance()
                right = self.parse_table_ref()
                self.expect_keyword("ON")
                item = ast.Join(self.pos(start), "INNER", item, right, self.parse_expr())
            elif self.accept_keyword("LEFT"):
                self.accept_keyword("OUTER")
                self.expect_keyword("JOIN")
                right = self.parse_table_ref()
                self.expect_keyword("ON")
                item = ast.Join(self.pos(start), "LEFT", item, right, self.parse_expr())
            elif self.tok.is_keyword("FULL", "RIGHT"):
                raise self.unsupported(self.tok)
            else:
                return item

    def parse_table_ref(self) -> ast.FromItem:
        start = self.tok
        if self.accept_op("("):
            self.meter.enter()  # a derived table or a parenthesized join
            if self.tok.is_keyword("SELECT", "WITH"):
                query = self.parse_query()
                self.expect_op(")")
                self.meter.leave()
                self.accept_keyword("AS")
                alias = self.expect_ident("derived table alias")
                return ast.DerivedTable(self.pos(start), query, alias)
            item = self.parse_from_item()
            self.expect_op(")")
            self.meter.leave()
            return item
        name = self.expect_ident("table name")
        self.meter.operand()  # a leaf of the FROM tree (see parse_function_call)
        alias = None
        if self.accept_keyword("AS"):
            alias = self.expect_alias("table alias")
        elif self.tok.kind is TokenKind.IDENT:
            alias = self.advance().value
        return ast.TableRef(self.pos(start), name, alias)

    def parse_order_item(self) -> ast.OrderItem:
        start = self.tok
        expr = self.parse_expr()
        item = ast.OrderItem(self.pos(start), expr)
        if self.accept_keyword("DESC"):
            item.descending = True
        else:
            self.accept_keyword("ASC")
        if self.accept_keyword("NULLS"):
            if self.accept_keyword("FIRST"):
                item.nulls_first = True
            else:
                self.expect_keyword("LAST")
                item.nulls_first = False
        return item

    # ------------------------------------------------------------ expressions

    def parse_expr(self) -> ast.Expr:
        return self.parse_or()

    def parse_or(self) -> ast.Expr:
        left = self.parse_and()
        if not self.tok.is_keyword("OR"):
            return left
        self.meter.enter()  # a chain of one operator is one level
        while self.tok.is_keyword("OR"):
            tok = self.advance()
            left = ast.BinaryOp(self.pos(tok), "OR", left, self.parse_and())
        self.meter.leave()
        return left

    def parse_and(self) -> ast.Expr:
        left = self.parse_not()
        if not self.tok.is_keyword("AND"):
            return left
        self.meter.enter()  # a chain of one operator is one level
        while self.tok.is_keyword("AND"):
            tok = self.advance()
            left = ast.BinaryOp(self.pos(tok), "AND", left, self.parse_not())
        self.meter.leave()
        return left

    def parse_not(self) -> ast.Expr:
        if self.tok.is_keyword("NOT"):
            tok = self.advance()
            self.meter.enter()
            operand = self.parse_not()
            self.meter.leave()
            return ast.UnaryOp(self.pos(tok), "NOT", operand)
        return self.parse_predicate()

    def parse_predicate(self) -> ast.Expr:
        left = self.parse_concat()
        tok = self.tok
        if not ((tok.kind is TokenKind.OP and tok.value in _COMPARISON_OPS) or tok.is_keyword(*_PREDICATES)):
            return left
        self.meter.enter()  # a comparison, IS, BETWEEN, IN or LIKE
        expr = self._parse_predicate_rest(left, tok)
        self.meter.leave()
        return expr

    def _parse_predicate_rest(self, left: ast.Expr, tok: Token) -> ast.Expr:
        pos = self.pos(tok)
        if tok.kind is TokenKind.OP and tok.value in _COMPARISON_OPS:
            self.advance()
            op = "<>" if tok.value == "!=" else tok.value
            return ast.BinaryOp(pos, op, left, self.parse_concat())
        if self.accept_keyword("IS"):
            negated = self.accept_keyword("NOT") is not None
            self.expect_keyword("NULL")
            return ast.IsNull(pos, left, negated)
        negated = False
        if tok.is_keyword("NOT") and self.peek().is_keyword("BETWEEN", "IN", "LIKE"):
            self.advance()
            negated = True
        if self.accept_keyword("BETWEEN"):
            low = self.parse_concat()
            self.expect_keyword("AND")
            high = self.parse_concat()
            return ast.Between(pos, left, low, high, negated)
        if self.accept_keyword("IN"):
            self.expect_op("(")
            if self.tok.is_keyword("SELECT", "WITH"):
                query = self.parse_query()
                self.expect_op(")")
                return ast.InSubquery(pos, left, query, negated)
            items = [self.parse_expr()]
            while self.accept_op(","):
                items.append(self.parse_expr())
            self.expect_op(")")
            return ast.InList(pos, left, items, negated)
        if self.accept_keyword("LIKE"):
            return ast.Like(pos, left, self.parse_concat(), negated)
        return left

    def parse_concat(self) -> ast.Expr:
        left = self.parse_additive()
        if not self.tok.is_op("||"):
            return left
        self.meter.enter()  # a chain of one operator is one level
        while self.tok.is_op("||"):
            tok = self.advance()
            left = ast.BinaryOp(self.pos(tok), "||", left, self.parse_additive())
        self.meter.leave()
        return left

    def parse_additive(self) -> ast.Expr:
        left = self.parse_multiplicative()
        if not self.tok.is_op("+", "-"):
            return left
        self.meter.enter()  # a chain of one operator is one level
        while self.tok.is_op("+", "-"):
            tok = self.advance()
            left = ast.BinaryOp(self.pos(tok), tok.value, left, self.parse_multiplicative())
        self.meter.leave()
        return left

    def parse_multiplicative(self) -> ast.Expr:
        left = self.parse_unary()
        if not self.tok.is_op("*", "/", "%"):
            return left
        self.meter.enter()  # a chain of one operator is one level
        while self.tok.is_op("*", "/", "%"):
            tok = self.advance()
            left = ast.BinaryOp(self.pos(tok), tok.value, left, self.parse_unary())
        self.meter.leave()
        return left

    def parse_unary(self) -> ast.Expr:
        tok = self.tok
        if tok.is_op("-", "+"):
            self.advance()
            if tok.value == "-" and self.tok.kind is TokenKind.NUMBER:
                # fold the sign into the literal so that INT64_MIN is accepted
                num = self.advance()
                self.meter.operand()
                return ast.NumberLit(self.pos(tok), "-" + num.value)
            self.meter.enter()
            operand = self.parse_unary()
            self.meter.leave()
            return ast.UnaryOp(self.pos(tok), tok.value, operand)
        return self.parse_primary()

    def parse_primary(self) -> ast.Expr:
        tok = self.tok
        kind = tok.kind
        if kind is TokenKind.IDENT and not tok.quoted and self.peek().is_op("("):
            nested = True  # a function call
        elif kind in _OPERAND_KINDS or tok.is_keyword(*_LITERAL_KEYWORDS):
            self.meter.operand()
            nested = False
        else:
            # a parenthesized expression or subquery, CAST, CASE, EXISTS
            nested = kind is TokenKind.OP or tok.is_keyword("CAST", "CASE", "EXISTS")
        if nested:
            self.meter.enter()
            expr = self._parse_primary(tok)
            self.meter.leave()
            return expr
        return self._parse_primary(tok)

    def _parse_primary(self, tok: Token) -> ast.Expr:
        pos = self.pos(tok)
        kind = tok.kind
        if kind is TokenKind.NUMBER:
            self.advance()
            return ast.NumberLit(pos, tok.value)
        if kind is TokenKind.STRING:
            self.advance()
            return ast.StringLit(pos, tok.value)
        if kind is TokenKind.KEYWORD:
            word = tok.value
            if word in ("TRUE", "FALSE"):
                self.advance()
                return ast.BoolLit(pos, word == "TRUE")
            if word == "NULL":
                self.advance()
                return ast.NullLit(pos)
            if word in ("DATE", "TIMESTAMP"):
                self.advance()
                if self.tok.kind is not TokenKind.STRING:
                    raise self.error(f"expected string literal after {word}")
                return ast.TypedLit(pos, word, self.advance().value)
            if word == "CAST":
                return self.parse_cast()
            if word == "CASE":
                return self.parse_case()
            if word == "EXISTS":
                self.advance()
                self.expect_op("(")
                query = self.parse_query()
                self.expect_op(")")
                return ast.Exists(pos, query)
            raise self.error("unexpected keyword in expression")
        if kind is TokenKind.IDENT:
            self.advance()
            if self.tok.is_op("(") and not tok.quoted:
                return self.parse_function_call(tok)
            if self.accept_op("."):
                name = self.expect_ident("column name")
                return ast.ColumnRef(pos, tok.value, name)
            return ast.ColumnRef(pos, None, tok.value)
        if tok.is_op("("):
            self.advance()
            if self.tok.is_keyword("SELECT", "WITH"):
                query = self.parse_query()
                self.expect_op(")")
                return ast.ScalarSubquery(pos, query)
            expr = self.parse_expr()
            self.expect_op(")")
            return expr
        raise self.error("expected expression")

    def parse_function_call(self, name_tok: Token) -> ast.FunctionCall:
        pos = self.pos(name_tok)
        self.expect_op("(")
        call = ast.FunctionCall(pos, name_tok.value, [])
        if self.accept_op("*"):
            self.meter.operand()
            call.star = True
            self.expect_op(")")
            return call
        if self.accept_op(")"):
            # counted like an operand: every leaf counts, so that the size
            # of a tree (e.g. a chain ``x + f() + f() …``) stays bounded
            self.meter.operand()
            return call
        if self.accept_keyword("DISTINCT"):
            call.distinct = True
        else:
            self.accept_keyword("ALL")
        call.args.append(self.parse_expr())
        while self.accept_op(","):
            call.args.append(self.parse_expr())
        self.expect_op(")")
        return call

    def parse_cast(self) -> ast.Cast:
        start = self.expect_keyword("CAST")
        self.expect_op("(")
        operand = self.parse_expr()
        self.expect_keyword("AS")
        type_tok = self.tok
        if type_tok.kind not in (TokenKind.IDENT, TokenKind.KEYWORD):
            raise self.error("expected type name")
        self.advance()
        params: list[int] = []
        if self.accept_op("("):
            params.append(self.parse_type_param())
            while self.accept_op(","):
                params.append(self.parse_type_param())
            self.expect_op(")")
        self.expect_op(")")
        target = ast.TypeName(self.pos(type_tok), type_tok.value, params)
        return ast.Cast(self.pos(start), operand, target)

    def parse_type_param(self) -> int:
        tok = self.tok
        if tok.kind is not TokenKind.NUMBER or not tok.value.isdigit():
            raise self.error("expected integer type parameter")
        self.advance()
        return int(tok.value)

    def parse_case(self) -> ast.Case:
        start = self.expect_keyword("CASE")
        operand = None
        if not self.tok.is_keyword("WHEN"):
            operand = self.parse_expr()
        whens = []
        while self.accept_keyword("WHEN"):
            cond = self.parse_expr()
            self.expect_keyword("THEN")
            whens.append((cond, self.parse_expr()))
        if not whens:
            raise self.error("expected WHEN")
        else_ = None
        if self.accept_keyword("ELSE"):
            else_ = self.parse_expr()
        self.expect_keyword("END")
        return ast.Case(self.pos(start), operand, whens, else_)


def parse(text: str, check: Check = no_check) -> ast.Statement:
    """Parses one SQL statement (optionally followed by a single ';').
    Statements beyond the size limits (``polyquery.limits``) fail with
    RESOURCE_LIMIT; ``check`` raises TIMEOUT / CANCELLED."""
    check_text_length(text)
    try:
        return Parser(text, check).parse_statement()
    except RecursionError:
        raise errors.resource_limit("statement is too deeply nested", measure="nesting_depth") from None
