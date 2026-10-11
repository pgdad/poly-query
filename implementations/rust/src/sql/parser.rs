//! Recursive-descent parser producing the AST (grammar.md §2).

use super::ast::*;
use super::lexer::{Keyword, Pos, Symbol, Token, TokenKind, tokenize};
use crate::error::{Error, Result};

/// Maximum expression/query nesting depth (protects the stack).
const MAX_DEPTH: usize = 10_000;

/// Parses one SQL statement (an optional single trailing `;` is allowed).
pub fn parse_statement(sql: &str) -> Result<Statement> {
    let tokens = tokenize(sql)?;
    let mut p = Parser {
        tokens,
        i: 0,
        depth: 0,
    };
    let stmt = p.statement()?;
    p.eat_symbol(Symbol::Semicolon);
    if !p.at_eof() {
        return Err(p.unexpected("end of statement"));
    }
    Ok(stmt)
}

struct Parser {
    tokens: Vec<Token>,
    i: usize,
    depth: usize,
}

impl Parser {
    fn peek(&self) -> &TokenKind {
        &self.tokens[self.i].kind
    }

    fn peek_at(&self, k: usize) -> &TokenKind {
        let idx = (self.i + k).min(self.tokens.len() - 1);
        &self.tokens[idx].kind
    }

    fn pos(&self) -> Pos {
        self.tokens[self.i].pos
    }

    fn advance(&mut self) -> Token {
        let t = self.tokens[self.i].clone();
        if self.i < self.tokens.len() - 1 {
            self.i += 1;
        }
        t
    }

    fn at_eof(&self) -> bool {
        matches!(self.peek(), TokenKind::Eof)
    }

    fn is_keyword(&self, k: Keyword) -> bool {
        matches!(self.peek(), TokenKind::Keyword(x) if *x == k)
    }

    fn is_symbol(&self, s: Symbol) -> bool {
        matches!(self.peek(), TokenKind::Symbol(x) if *x == s)
    }

    fn eat_keyword(&mut self, k: Keyword) -> bool {
        if self.is_keyword(k) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn eat_symbol(&mut self, s: Symbol) -> bool {
        if self.is_symbol(s) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn unexpected(&self, expected: &str) -> Error {
        let t = &self.tokens[self.i];
        t.pos.error(Error::parse(format!(
            "expected {expected}, found {}",
            t.kind.describe()
        )))
    }

    fn expect_keyword(&mut self, k: Keyword) -> Result<()> {
        if self.eat_keyword(k) {
            Ok(())
        } else {
            Err(self.unexpected(k.as_str()))
        }
    }

    fn expect_symbol(&mut self, s: Symbol) -> Result<()> {
        if self.eat_symbol(s) {
            Ok(())
        } else {
            Err(self.unexpected(&format!("'{}'", s.as_str())))
        }
    }

    fn unsupported(&self, what: &str) -> Error {
        self.pos()
            .error(Error::unsupported(format!("{what} is not supported")))
    }

    fn ident(&mut self) -> Result<Ident> {
        match self.peek().clone() {
            TokenKind::Ident { name, quoted } => {
                let pos = self.pos();
                self.advance();
                Ok(Ident {
                    value: name,
                    quoted,
                    pos,
                })
            }
            _ => Err(self.unexpected("identifier")),
        }
    }

    fn enter(&mut self) -> Result<()> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self
                .pos()
                .error(Error::parse("statement is nested too deeply")));
        }
        Ok(())
    }

    fn leave(&mut self) {
        self.depth -= 1;
    }

    // ---------------------------------------------------------------- statements

    fn statement(&mut self) -> Result<Statement> {
        if self.eat_keyword(Keyword::EXPLAIN) {
            return Ok(Statement::Explain(Box::new(self.query()?)));
        }
        if self.eat_keyword(Keyword::CREATE) {
            self.expect_keyword(Keyword::INDEX)?;
            let if_not_exists = if self.eat_keyword(Keyword::IF) {
                self.expect_keyword(Keyword::NOT)?;
                self.expect_keyword(Keyword::EXISTS)?;
                true
            } else {
                false
            };
            let name = self.ident()?;
            self.expect_keyword(Keyword::ON)?;
            let table = self.ident()?;
            self.expect_symbol(Symbol::LParen)?;
            let column = self.ident()?;
            self.expect_symbol(Symbol::RParen)?;
            let using = if self.eat_keyword(Keyword::USING) {
                let kind = self.ident()?;
                if !kind.matches("HASH") && !kind.matches("BTREE") {
                    return Err(kind.pos.error(Error::parse("expected HASH or BTREE")));
                }
                Some(kind)
            } else {
                None
            };
            return Ok(Statement::CreateIndex {
                name,
                if_not_exists,
                table,
                column,
                using,
            });
        }
        if self.eat_keyword(Keyword::DROP) {
            self.expect_keyword(Keyword::INDEX)?;
            let if_exists = if self.eat_keyword(Keyword::IF) {
                self.expect_keyword(Keyword::EXISTS)?;
                true
            } else {
                false
            };
            let name = self.ident()?;
            return Ok(Statement::DropIndex { name, if_exists });
        }
        Ok(Statement::Query(Box::new(self.query()?)))
    }

    fn query(&mut self) -> Result<Query> {
        self.enter()?;
        let pos = self.pos();
        let mut with = Vec::new();
        if self.eat_keyword(Keyword::WITH) {
            loop {
                let name = self.ident()?;
                let mut columns = Vec::new();
                if self.eat_symbol(Symbol::LParen) {
                    loop {
                        columns.push(self.ident()?);
                        if !self.eat_symbol(Symbol::Comma) {
                            break;
                        }
                    }
                    self.expect_symbol(Symbol::RParen)?;
                }
                self.expect_keyword(Keyword::AS)?;
                self.expect_symbol(Symbol::LParen)?;
                let query = Box::new(self.query()?);
                self.expect_symbol(Symbol::RParen)?;
                with.push(Cte {
                    name,
                    columns,
                    query,
                });
                if !self.eat_symbol(Symbol::Comma) {
                    break;
                }
            }
        }
        let body = self.select_core()?;
        let mut union_all = Vec::new();
        while self.is_keyword(Keyword::UNION) {
            if !matches!(self.peek_at(1), TokenKind::Keyword(Keyword::ALL)) {
                return Err(self.unsupported("UNION without ALL"));
            }
            self.advance();
            self.advance();
            union_all.push(self.select_core()?);
        }
        let mut order_by = Vec::new();
        if self.eat_keyword(Keyword::ORDER) {
            self.expect_keyword(Keyword::BY)?;
            loop {
                let expr = self.expr()?;
                let descending = if self.eat_keyword(Keyword::DESC) {
                    true
                } else {
                    self.eat_keyword(Keyword::ASC);
                    false
                };
                let nulls_first = if self.eat_keyword(Keyword::NULLS) {
                    if self.eat_keyword(Keyword::FIRST) {
                        Some(true)
                    } else if self.eat_keyword(Keyword::LAST) {
                        Some(false)
                    } else {
                        return Err(self.unexpected("FIRST or LAST"));
                    }
                } else {
                    None
                };
                order_by.push(OrderItem {
                    expr,
                    descending,
                    nulls_first,
                });
                if !self.eat_symbol(Symbol::Comma) {
                    break;
                }
            }
        }
        let (mut limit, mut offset) = (None, None);
        if self.eat_keyword(Keyword::LIMIT) {
            limit = Some(self.expr()?);
            if self.eat_keyword(Keyword::OFFSET) {
                offset = Some(self.expr()?);
            }
        } else if self.eat_keyword(Keyword::OFFSET) {
            offset = Some(self.expr()?);
            if self.eat_keyword(Keyword::LIMIT) {
                limit = Some(self.expr()?);
            }
        }
        if self.is_keyword(Keyword::UNION) {
            // A branch cannot carry its own ORDER BY / LIMIT (CR-1 §1).
            if matches!(self.peek_at(1), TokenKind::Keyword(Keyword::ALL)) {
                return Err(self.unexpected("end of query"));
            }
            return Err(self.unsupported("UNION without ALL"));
        }
        self.leave();
        Ok(Query {
            with,
            body,
            union_all,
            order_by,
            limit,
            offset,
            pos,
        })
    }

    fn select_core(&mut self) -> Result<SelectCore> {
        self.expect_keyword(Keyword::SELECT)?;
        let distinct = if self.eat_keyword(Keyword::DISTINCT) {
            true
        } else {
            self.eat_keyword(Keyword::ALL);
            false
        };
        let mut items = Vec::new();
        loop {
            items.push(self.select_item()?);
            if !self.eat_symbol(Symbol::Comma) {
                break;
            }
        }
        let from = if self.eat_keyword(Keyword::FROM) {
            Some(self.parse_from()?)
        } else {
            None
        };
        let where_clause = if self.eat_keyword(Keyword::WHERE) {
            Some(self.expr()?)
        } else {
            None
        };
        let mut group_by = Vec::new();
        if self.eat_keyword(Keyword::GROUP) {
            self.expect_keyword(Keyword::BY)?;
            loop {
                group_by.push(self.expr()?);
                if !self.eat_symbol(Symbol::Comma) {
                    break;
                }
            }
        }
        let having = if self.eat_keyword(Keyword::HAVING) {
            Some(self.expr()?)
        } else {
            None
        };
        Ok(SelectCore {
            distinct,
            items,
            from,
            where_clause,
            group_by,
            having,
        })
    }

    fn select_item(&mut self) -> Result<SelectItem> {
        if self.is_symbol(Symbol::Star) {
            let pos = self.pos();
            self.advance();
            return Ok(SelectItem::Wildcard(pos));
        }
        if matches!(self.peek(), TokenKind::Ident { .. })
            && matches!(self.peek_at(1), TokenKind::Symbol(Symbol::Dot))
            && matches!(self.peek_at(2), TokenKind::Symbol(Symbol::Star))
        {
            let q = self.ident()?;
            self.advance();
            self.advance();
            return Ok(SelectItem::QualifiedWildcard(q));
        }
        let expr = self.expr()?;
        let alias = self.optional_alias()?;
        Ok(SelectItem::Expr { expr, alias })
    }

    fn optional_alias(&mut self) -> Result<Option<Ident>> {
        if self.eat_keyword(Keyword::AS) {
            return Ok(Some(self.ident()?));
        }
        if matches!(self.peek(), TokenKind::Ident { .. }) {
            Ok(Some(self.ident()?))
        } else {
            Ok(None)
        }
    }

    fn parse_from(&mut self) -> Result<FromItem> {
        let mut left = self.table_ref()?;
        loop {
            let pos = self.pos();
            let kind = if self.eat_symbol(Symbol::Comma) {
                JoinKind::Cross
            } else if self.eat_keyword(Keyword::CROSS) {
                self.expect_keyword(Keyword::JOIN)?;
                JoinKind::Cross
            } else if self.eat_keyword(Keyword::INNER) {
                self.expect_keyword(Keyword::JOIN)?;
                JoinKind::Inner
            } else if self.eat_keyword(Keyword::JOIN) {
                JoinKind::Inner
            } else if self.eat_keyword(Keyword::LEFT) {
                self.eat_keyword(Keyword::OUTER);
                self.expect_keyword(Keyword::JOIN)?;
                JoinKind::Left
            } else if self.is_keyword(Keyword::RIGHT) || self.is_keyword(Keyword::FULL) {
                return Err(self.unsupported("RIGHT/FULL JOIN"));
            } else {
                break;
            };
            let right = self.table_ref()?;
            let on = if kind == JoinKind::Cross {
                None
            } else {
                self.expect_keyword(Keyword::ON)?;
                Some(self.expr()?)
            };
            left = FromItem::Join {
                left: Box::new(left),
                right: Box::new(right),
                kind,
                on,
                pos,
            };
        }
        Ok(left)
    }

    fn table_ref(&mut self) -> Result<FromItem> {
        if self.eat_symbol(Symbol::LParen) {
            self.enter()?;
            let item = if self.is_keyword(Keyword::SELECT) || self.is_keyword(Keyword::WITH) {
                let query = Box::new(self.query()?);
                self.expect_symbol(Symbol::RParen)?;
                self.eat_keyword(Keyword::AS);
                let alias = self.ident()?;
                FromItem::Derived { query, alias }
            } else {
                let inner = self.parse_from()?;
                self.expect_symbol(Symbol::RParen)?;
                inner
            };
            self.leave();
            return Ok(item);
        }
        let name = self.ident()?;
        let alias = self.optional_alias()?;
        Ok(FromItem::Table { name, alias })
    }

    // ---------------------------------------------------------------- expressions

    pub fn expr(&mut self) -> Result<Expr> {
        self.enter()?;
        let e = self.or_expr();
        self.leave();
        e
    }

    fn or_expr(&mut self) -> Result<Expr> {
        let mut left = self.and_expr()?;
        // Each chained operator deepens the (left-leaning) tree.
        let saved = self.depth;
        while self.is_keyword(Keyword::OR) {
            let pos = self.pos();
            self.advance();
            self.enter()?;
            let right = self.and_expr()?;
            left = Expr {
                kind: ExprKind::Binary {
                    op: BinaryOp::Or,
                    left: Box::new(left),
                    right: Box::new(right),
                },
                pos,
            };
        }
        self.depth = saved;
        Ok(left)
    }

    fn and_expr(&mut self) -> Result<Expr> {
        let mut left = self.not_expr()?;
        // Each chained operator deepens the (left-leaning) tree.
        let saved = self.depth;
        while self.is_keyword(Keyword::AND) {
            let pos = self.pos();
            self.advance();
            self.enter()?;
            let right = self.not_expr()?;
            left = Expr {
                kind: ExprKind::Binary {
                    op: BinaryOp::And,
                    left: Box::new(left),
                    right: Box::new(right),
                },
                pos,
            };
        }
        self.depth = saved;
        Ok(left)
    }

    fn not_expr(&mut self) -> Result<Expr> {
        if self.is_keyword(Keyword::NOT) {
            let pos = self.pos();
            self.advance();
            self.enter()?;
            let inner = self.not_expr()?;
            self.leave();
            return Ok(Expr {
                kind: ExprKind::Unary {
                    op: UnaryOp::Not,
                    expr: Box::new(inner),
                },
                pos,
            });
        }
        self.predicate()
    }

    fn predicate(&mut self) -> Result<Expr> {
        let left = self.concat_expr()?;
        let pos = self.pos();
        let comp = match self.peek() {
            TokenKind::Symbol(Symbol::Eq) => Some(BinaryOp::Eq),
            TokenKind::Symbol(Symbol::NotEq) => Some(BinaryOp::NotEq),
            TokenKind::Symbol(Symbol::Lt) => Some(BinaryOp::Lt),
            TokenKind::Symbol(Symbol::LtEq) => Some(BinaryOp::LtEq),
            TokenKind::Symbol(Symbol::Gt) => Some(BinaryOp::Gt),
            TokenKind::Symbol(Symbol::GtEq) => Some(BinaryOp::GtEq),
            _ => None,
        };
        if let Some(op) = comp {
            self.advance();
            let right = self.concat_expr()?;
            return Ok(Expr {
                kind: ExprKind::Binary {
                    op,
                    left: Box::new(left),
                    right: Box::new(right),
                },
                pos,
            });
        }
        if self.eat_keyword(Keyword::IS) {
            let negated = self.eat_keyword(Keyword::NOT);
            self.expect_keyword(Keyword::NULL)?;
            return Ok(Expr {
                kind: ExprKind::IsNull {
                    expr: Box::new(left),
                    negated,
                },
                pos,
            });
        }
        let negated = if self.is_keyword(Keyword::NOT)
            && matches!(
                self.peek_at(1),
                TokenKind::Keyword(Keyword::BETWEEN | Keyword::IN | Keyword::LIKE)
            ) {
            self.advance();
            true
        } else {
            false
        };
        if self.eat_keyword(Keyword::BETWEEN) {
            let low = self.concat_expr()?;
            self.expect_keyword(Keyword::AND)?;
            let high = self.concat_expr()?;
            return Ok(Expr {
                kind: ExprKind::Between {
                    expr: Box::new(left),
                    low: Box::new(low),
                    high: Box::new(high),
                    negated,
                },
                pos,
            });
        }
        if self.eat_keyword(Keyword::IN) {
            self.expect_symbol(Symbol::LParen)?;
            if self.is_keyword(Keyword::SELECT) || self.is_keyword(Keyword::WITH) {
                let query = Box::new(self.query()?);
                self.expect_symbol(Symbol::RParen)?;
                return Ok(Expr {
                    kind: ExprKind::InSubquery {
                        expr: Box::new(left),
                        query,
                        negated,
                    },
                    pos,
                });
            }
            let mut list = Vec::new();
            loop {
                list.push(self.expr()?);
                if !self.eat_symbol(Symbol::Comma) {
                    break;
                }
            }
            self.expect_symbol(Symbol::RParen)?;
            return Ok(Expr {
                kind: ExprKind::InList {
                    expr: Box::new(left),
                    list,
                    negated,
                },
                pos,
            });
        }
        if self.eat_keyword(Keyword::LIKE) {
            let pattern = self.concat_expr()?;
            return Ok(Expr {
                kind: ExprKind::Like {
                    expr: Box::new(left),
                    pattern: Box::new(pattern),
                    negated,
                },
                pos,
            });
        }
        Ok(left)
    }

    fn concat_expr(&mut self) -> Result<Expr> {
        let mut left = self.additive()?;
        // Each chained operator deepens the (left-leaning) tree.
        let saved = self.depth;
        while self.is_symbol(Symbol::Concat) {
            let pos = self.pos();
            self.advance();
            self.enter()?;
            let right = self.additive()?;
            left = Expr {
                kind: ExprKind::Binary {
                    op: BinaryOp::Concat,
                    left: Box::new(left),
                    right: Box::new(right),
                },
                pos,
            };
        }
        self.depth = saved;
        Ok(left)
    }

    fn additive(&mut self) -> Result<Expr> {
        let mut left = self.multiplicative()?;
        // Each chained operator deepens the (left-leaning) tree.
        let saved = self.depth;
        loop {
            let op = match self.peek() {
                TokenKind::Symbol(Symbol::Plus) => BinaryOp::Add,
                TokenKind::Symbol(Symbol::Minus) => BinaryOp::Sub,
                _ => {
                    self.depth = saved;
                    return Ok(left);
                }
            };
            let pos = self.pos();
            self.advance();
            self.enter()?;
            let right = self.multiplicative()?;
            left = Expr {
                kind: ExprKind::Binary {
                    op,
                    left: Box::new(left),
                    right: Box::new(right),
                },
                pos,
            };
        }
    }

    fn multiplicative(&mut self) -> Result<Expr> {
        let mut left = self.unary()?;
        // Each chained operator deepens the (left-leaning) tree.
        let saved = self.depth;
        loop {
            let op = match self.peek() {
                TokenKind::Symbol(Symbol::Star) => BinaryOp::Mul,
                TokenKind::Symbol(Symbol::Slash) => BinaryOp::Div,
                TokenKind::Symbol(Symbol::Percent) => BinaryOp::Mod,
                _ => {
                    self.depth = saved;
                    return Ok(left);
                }
            };
            let pos = self.pos();
            self.advance();
            self.enter()?;
            let right = self.unary()?;
            left = Expr {
                kind: ExprKind::Binary {
                    op,
                    left: Box::new(left),
                    right: Box::new(right),
                },
                pos,
            };
        }
    }

    fn unary(&mut self) -> Result<Expr> {
        let op = match self.peek() {
            TokenKind::Symbol(Symbol::Minus) => UnaryOp::Neg,
            TokenKind::Symbol(Symbol::Plus) => UnaryOp::Plus,
            _ => return self.primary(),
        };
        let pos = self.pos();
        self.advance();
        self.enter()?;
        let inner = self.unary()?;
        self.leave();
        Ok(Expr {
            kind: ExprKind::Unary {
                op,
                expr: Box::new(inner),
            },
            pos,
        })
    }

    fn primary(&mut self) -> Result<Expr> {
        let pos = self.pos();
        let kind = match self.peek().clone() {
            TokenKind::Number(n) => {
                self.advance();
                ExprKind::Literal(Literal::Number(n))
            }
            TokenKind::Str(s) => {
                self.advance();
                ExprKind::Literal(Literal::String(s))
            }
            TokenKind::Keyword(Keyword::TRUE) => {
                self.advance();
                ExprKind::Literal(Literal::Bool(true))
            }
            TokenKind::Keyword(Keyword::FALSE) => {
                self.advance();
                ExprKind::Literal(Literal::Bool(false))
            }
            TokenKind::Keyword(Keyword::NULL) => {
                self.advance();
                ExprKind::Literal(Literal::Null)
            }
            TokenKind::Keyword(k @ (Keyword::DATE | Keyword::TIMESTAMP)) => {
                self.advance();
                match self.peek().clone() {
                    TokenKind::Str(s) => {
                        self.advance();
                        ExprKind::Literal(if k == Keyword::DATE {
                            Literal::Date(s)
                        } else {
                            Literal::Timestamp(s)
                        })
                    }
                    _ => return Err(self.unexpected("string literal")),
                }
            }
            TokenKind::Keyword(Keyword::CAST) => {
                self.advance();
                self.expect_symbol(Symbol::LParen)?;
                let expr = self.expr()?;
                self.expect_keyword(Keyword::AS)?;
                let type_name = self.type_name()?;
                self.expect_symbol(Symbol::RParen)?;
                ExprKind::Cast {
                    expr: Box::new(expr),
                    type_name,
                }
            }
            TokenKind::Keyword(Keyword::CASE) => {
                self.advance();
                self.case_expr()?
            }
            TokenKind::Keyword(Keyword::EXISTS) => {
                self.advance();
                self.expect_symbol(Symbol::LParen)?;
                let q = self.query()?;
                self.expect_symbol(Symbol::RParen)?;
                ExprKind::Exists(Box::new(q))
            }
            TokenKind::Symbol(Symbol::LParen) => {
                self.advance();
                if self.is_keyword(Keyword::SELECT) || self.is_keyword(Keyword::WITH) {
                    let q = self.query()?;
                    self.expect_symbol(Symbol::RParen)?;
                    ExprKind::Subquery(Box::new(q))
                } else {
                    let e = self.expr()?;
                    self.expect_symbol(Symbol::RParen)?;
                    return Ok(e);
                }
            }
            TokenKind::Ident { .. } => {
                let name = self.ident()?;
                if self.eat_symbol(Symbol::LParen) {
                    self.function_call(name)?
                } else if self.is_symbol(Symbol::Dot) {
                    self.advance();
                    let col = self.ident()?;
                    ExprKind::Column {
                        qualifier: Some(name),
                        name: col,
                    }
                } else {
                    ExprKind::Column {
                        qualifier: None,
                        name,
                    }
                }
            }
            _ => return Err(self.unexpected("expression")),
        };
        Ok(Expr { kind, pos })
    }

    fn function_call(&mut self, name: Ident) -> Result<ExprKind> {
        if self.eat_symbol(Symbol::Star) {
            self.expect_symbol(Symbol::RParen)?;
            return Ok(ExprKind::Function {
                name,
                args: Vec::new(),
                distinct: false,
                star: true,
            });
        }
        if self.eat_symbol(Symbol::RParen) {
            return Ok(ExprKind::Function {
                name,
                args: Vec::new(),
                distinct: false,
                star: false,
            });
        }
        let distinct = self.eat_keyword(Keyword::DISTINCT);
        let mut args = Vec::new();
        loop {
            args.push(self.expr()?);
            if !self.eat_symbol(Symbol::Comma) {
                break;
            }
        }
        self.expect_symbol(Symbol::RParen)?;
        Ok(ExprKind::Function {
            name,
            args,
            distinct,
            star: false,
        })
    }

    fn case_expr(&mut self) -> Result<ExprKind> {
        let operand = if self.is_keyword(Keyword::WHEN) {
            None
        } else {
            Some(Box::new(self.expr()?))
        };
        let mut whens = Vec::new();
        while self.eat_keyword(Keyword::WHEN) {
            let cond = self.expr()?;
            self.expect_keyword(Keyword::THEN)?;
            let result = self.expr()?;
            whens.push((cond, result));
        }
        if whens.is_empty() {
            return Err(self.unexpected("WHEN"));
        }
        let else_expr = if self.eat_keyword(Keyword::ELSE) {
            Some(Box::new(self.expr()?))
        } else {
            None
        };
        self.expect_keyword(Keyword::END)?;
        Ok(ExprKind::Case {
            operand,
            whens,
            else_expr,
        })
    }

    fn type_name(&mut self) -> Result<TypeName> {
        let pos = self.pos();
        let name = match self.peek().clone() {
            TokenKind::Ident { name, .. } => name,
            TokenKind::Keyword(k @ (Keyword::DATE | Keyword::TIMESTAMP)) => k.as_str().to_string(),
            _ => return Err(self.unexpected("type name")),
        };
        self.advance();
        let mut params = Vec::new();
        if self.eat_symbol(Symbol::LParen) {
            loop {
                match self.peek().clone() {
                    TokenKind::Number(n) => {
                        self.advance();
                        params.push(n);
                    }
                    _ => return Err(self.unexpected("number")),
                }
                if !self.eat_symbol(Symbol::Comma) {
                    break;
                }
            }
            if params.len() > 2 {
                return Err(pos.error(Error::parse("too many type parameters")));
            }
            self.expect_symbol(Symbol::RParen)?;
        }
        Ok(TypeName { name, params, pos })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn q(sql: &str) -> Query {
        match parse_statement(sql).unwrap() {
            Statement::Query(q) => *q,
            other => panic!("not a query: {other:?}"),
        }
    }

    fn code(sql: &str) -> ErrorCode {
        parse_statement(sql).unwrap_err().code
    }

    #[test]
    fn simple_select() {
        let q = q(
            "SELECT a, b AS c, t.* FROM t x WHERE a > 1 ORDER BY 1 DESC NULLS FIRST LIMIT 3 OFFSET 1;",
        );
        assert_eq!(q.body.items.len(), 3);
        assert!(q.body.where_clause.is_some());
        assert_eq!(q.order_by.len(), 1);
        assert!(q.order_by[0].descending);
        assert_eq!(q.order_by[0].nulls_first, Some(true));
        assert!(q.limit.is_some() && q.offset.is_some());
    }

    #[test]
    fn precedence() {
        let q = q("SELECT -2 * 3 + 4");
        let SelectItem::Expr { expr, .. } = &q.body.items[0] else {
            panic!()
        };
        let ExprKind::Binary {
            op: BinaryOp::Add,
            left,
            ..
        } = &expr.kind
        else {
            panic!("{expr:?}")
        };
        let ExprKind::Binary {
            op: BinaryOp::Mul,
            left: neg,
            ..
        } = &left.kind
        else {
            panic!()
        };
        assert!(matches!(
            neg.kind,
            ExprKind::Unary {
                op: UnaryOp::Neg,
                ..
            }
        ));
    }

    #[test]
    fn not_binds_looser_than_comparison() {
        let q = q("SELECT NOT a = b");
        let SelectItem::Expr { expr, .. } = &q.body.items[0] else {
            panic!()
        };
        assert!(matches!(
            expr.kind,
            ExprKind::Unary {
                op: UnaryOp::Not,
                ..
            }
        ));
    }

    #[test]
    fn errors() {
        assert_eq!(code("SELECT 1 = 1 = 1"), ErrorCode::ParseError);
        assert_eq!(code("SELEC name FROM people"), ErrorCode::ParseError);
        assert_eq!(code("SELECT name FROM people WHERE"), ErrorCode::ParseError);
        assert_eq!(code("SELECT 1; SELECT 2"), ErrorCode::ParseError);
        assert_eq!(
            code("SELECT COUNT(*, id) FROM people"),
            ErrorCode::ParseError
        );
        assert_eq!(code("SELECT a < b IS NULL"), ErrorCode::ParseError);
        assert_eq!(code("SELECT 1 UNION SELECT 2"), ErrorCode::Unsupported);
        assert_eq!(
            code("SELECT 1 UNION DISTINCT SELECT 2"),
            ErrorCode::Unsupported
        );
        assert_eq!(
            code("SELECT 1 UNION ALL SELECT 2 UNION SELECT 3"),
            ErrorCode::Unsupported
        );
        assert_eq!(
            code("SELECT 1 AS a ORDER BY a UNION ALL SELECT 2"),
            ErrorCode::ParseError
        );
        assert_eq!(
            code("SELECT 1 LIMIT 1 UNION ALL SELECT 2"),
            ErrorCode::ParseError
        );
        assert_eq!(
            code("(SELECT 1) UNION ALL (SELECT 2)"),
            ErrorCode::ParseError
        );
        assert_eq!(code("SELECT 1 UNION ALL (SELECT 2)"), ErrorCode::ParseError);
        assert_eq!(
            code("SELECT * FROM a RIGHT JOIN b ON a.x = b.x"),
            ErrorCode::Unsupported
        );
    }

    #[test]
    fn union_all_branches() {
        let q =
            q("SELECT a FROM t UNION ALL SELECT b FROM u UNION ALL SELECT 1 ORDER BY 1 LIMIT 2");
        assert_eq!(q.union_all.len(), 2);
        assert!(q.is_compound());
        assert_eq!(q.branches().count(), 3);
        assert_eq!(q.order_by.len(), 1);
        assert!(q.limit.is_some());
        assert!(q.union_all[0].from.is_some());
    }

    #[test]
    fn deep_nesting_is_an_error_not_a_crash() {
        // The engine parses on a thread with a large stack; mirror that here.
        std::thread::Builder::new()
            .stack_size(256 * 1024 * 1024)
            .spawn(|| {
                let sql = format!("SELECT {}1{}", "(".repeat(20_000), ")".repeat(20_000));
                assert_eq!(code(&sql), ErrorCode::ParseError);
                let sql = format!("SELECT {}1", "-".repeat(20_000));
                assert_eq!(code(&sql), ErrorCode::ParseError);
                let sql = format!("SELECT 1{}", " + 1".repeat(100_000));
                assert_eq!(code(&sql), ErrorCode::ParseError);
                let sql = format!("SELECT 1{}", " + 1".repeat(5_000));
                assert!(parse_statement(&sql).is_ok());
            })
            .unwrap()
            .join()
            .unwrap();
    }

    #[test]
    fn full_grammar_parses() {
        for sql in [
            "WITH a(x) AS (SELECT 1) SELECT DISTINCT x FROM a",
            "SELECT a.x, COUNT(DISTINCT b.y) FROM a LEFT JOIN b ON a.id = b.id GROUP BY a.x HAVING COUNT(*) > 1",
            "SELECT * FROM (SELECT 1 AS one) AS d CROSS JOIN t, u",
            "SELECT CASE WHEN x BETWEEN 1 AND 2 THEN 'a' ELSE 'b' END FROM t WHERE y NOT IN (1, 2) AND z LIKE 'a%'",
            "SELECT EXISTS (SELECT 1), (SELECT 2), x IN (SELECT y FROM t) FROM t",
            "CREATE INDEX IF NOT EXISTS i ON t (c) USING HASH",
            "DROP INDEX IF EXISTS i",
            "EXPLAIN SELECT 1",
            "SELECT CAST(x AS DECIMAL(10, 2)), CAST(y AS DATE) FROM t",
            "WITH u AS (SELECT 1 UNION ALL SELECT 2) SELECT * FROM (SELECT x FROM u UNION ALL SELECT 3) d",
            "SELECT 1 WHERE 1 IN (SELECT 1 UNION ALL SELECT 2) AND EXISTS (SELECT 1 UNION ALL SELECT 2)",
            "EXPLAIN SELECT 1 UNION ALL SELECT 2",
        ] {
            parse_statement(sql).unwrap_or_else(|e| panic!("{sql}: {e}"));
        }
    }
}
