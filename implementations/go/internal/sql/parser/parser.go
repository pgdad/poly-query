// Package parser implements a recursive-descent parser for the PolyQuery SQL
// grammar (spec/sql/grammar.md §2), producing an ast.Statement.
package parser

import (
	"strconv"

	"polyquery/internal/errs"
	"polyquery/internal/interrupt"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/lexer"
)

type parser struct {
	sc     *lexer.Scanner
	intr   *interrupt.Checker
	limits Limits
	buf    []lexer.Token // lookahead; buf[0] is the current token
	fatal  error         // ends the parse (see fail)

	open        int // nesting constructs being parsed (see enter)
	joinOpen    int // parenthesized FROM items being parsed
	operands    int // literals, column references and * arguments so far
	queryHeight int // largest nesting height in the current query so far
}

// Parse parses exactly one statement (with an optional trailing ';') under
// the default limits.
func Parse(sql string) (ast.Statement, error) {
	return ParseWith(sql, Options{Limits: DefaultLimits})
}

// ParseWith parses exactly one statement (with an optional trailing ';').
// Tokens are read lazily. A lexical error anywhere in the text is reported
// in preference to a syntax error, as if the whole text had been tokenized
// first; a limit, timeout or cancellation is reported as soon as it
// occurs.
func ParseWith(sql string, opts Options) (ast.Statement, error) {
	p := &parser{sc: lexer.NewScanner(sql), intr: opts.Interrupt, limits: opts.Limits}
	if err := p.textLimit(len(sql)); err != nil {
		return nil, err
	}
	stmt, err := p.statement()
	if err == nil {
		p.accept(";")
		if t := p.peek(); t.Kind != lexer.EOF {
			err = p.unexpected(t)
		}
	}
	if err != nil && p.fatal == nil {
		p.drain() // a later lexical error takes precedence
	}
	if p.fatal != nil {
		return nil, p.fatal
	}
	if err != nil {
		return nil, err
	}
	return stmt, nil
}

// ---------------------------------------------------------------- helpers

// scan reads the next token from the scanner; after a fatal error the
// stream is at its end.
func (p *parser) scan() lexer.Token {
	if p.fatal == nil {
		if err := p.intr.Tick(); err != nil {
			p.fail(err)
		}
	}
	if p.fatal == nil {
		t, err := p.sc.Next()
		if err == nil {
			return t
		}
		p.fail(err)
	}
	return lexer.Token{Kind: lexer.EOF}
}

// drain reads the rest of the text, recording a lexical error if any.
func (p *parser) drain() {
	for p.fatal == nil && p.scan().Kind != lexer.EOF {
	}
}

func (p *parser) fill(n int) {
	for len(p.buf) <= n {
		p.buf = append(p.buf, p.scan())
	}
}

func (p *parser) peek() lexer.Token {
	p.fill(0)
	return p.buf[0]
}

func (p *parser) peekAt(n int) lexer.Token {
	p.fill(n)
	return p.buf[n]
}

func (p *parser) next() lexer.Token {
	t := p.peek()
	if t.Kind != lexer.EOF {
		p.buf = p.buf[1:]
	}
	return t
}

func (p *parser) accept(text string) bool {
	if p.peek().Is(text) {
		p.next()
		return true
	}
	return false
}

func (p *parser) expect(text string) (lexer.Token, error) {
	t := p.peek()
	if !t.Is(text) {
		return t, errs.At(errs.ParseError, t.Line, t.Col, "expected %s but found %s", text, t.Describe())
	}
	p.next()
	return t, nil
}

func (p *parser) unexpected(t lexer.Token) error {
	return errs.At(errs.ParseError, t.Line, t.Col, "unexpected %s", t.Describe())
}

func (p *parser) unsupported(t lexer.Token, msg string) error {
	return errs.At(errs.Unsupported, t.Line, t.Col, "%s", msg)
}

func pos(t lexer.Token) ast.Pos { return ast.Pos{Line: t.Line, Col: t.Col} }

func (p *parser) ident() (string, lexer.Token, error) {
	t := p.peek()
	if t.Kind == lexer.Ident || t.Kind == lexer.QIdent {
		p.next()
		return t.Text, t, nil
	}
	return "", t, errs.At(errs.ParseError, t.Line, t.Col, "expected identifier but found %s", t.Describe())
}

func (p *parser) isIdent() bool {
	k := p.peek().Kind
	return k == lexer.Ident || k == lexer.QIdent
}

// ---------------------------------------------------------------- statements

func (p *parser) statement() (ast.Statement, error) {
	t := p.peek()
	switch {
	case t.Is("SELECT"), t.Is("WITH"):
		return p.query()
	case t.Is("EXPLAIN"):
		p.next()
		q, err := p.query()
		if err != nil {
			return nil, err
		}
		return &ast.Explain{Pos: pos(t), Query: q}, nil
	case t.Is("CREATE"):
		return p.createIndex()
	case t.Is("DROP"):
		return p.dropIndex()
	case t.Is("("):
		return nil, errs.At(errs.ParseError, t.Line, t.Col, "unexpected '(' at start of statement")
	}
	return nil, errs.At(errs.ParseError, t.Line, t.Col, "expected SELECT, WITH, EXPLAIN, CREATE or DROP but found %s", t.Describe())
}

func (p *parser) createIndex() (ast.Statement, error) {
	start := p.next()
	if _, err := p.expect("INDEX"); err != nil {
		return nil, err
	}
	ci := &ast.CreateIndex{Pos: pos(start)}
	if p.accept("IF") {
		if _, err := p.expect("NOT"); err != nil {
			return nil, err
		}
		if _, err := p.expect("EXISTS"); err != nil {
			return nil, err
		}
		ci.IfNotExists = true
	}
	var err error
	if ci.Name, _, err = p.ident(); err != nil {
		return nil, err
	}
	if _, err = p.expect("ON"); err != nil {
		return nil, err
	}
	if ci.Table, _, err = p.ident(); err != nil {
		return nil, err
	}
	if _, err = p.expect("("); err != nil {
		return nil, err
	}
	if ci.Column, _, err = p.ident(); err != nil {
		return nil, err
	}
	if _, err = p.expect(")"); err != nil {
		return nil, err
	}
	if p.accept("USING") {
		name, t, err := p.ident()
		if err != nil {
			return nil, err
		}
		switch upper := asciiUpper(name); upper {
		case "HASH", "BTREE":
			ci.Using = upper
		default:
			return nil, errs.At(errs.ParseError, t.Line, t.Col, "expected HASH or BTREE but found %s", t.Describe())
		}
	}
	return ci, nil
}

func (p *parser) dropIndex() (ast.Statement, error) {
	start := p.next()
	if _, err := p.expect("INDEX"); err != nil {
		return nil, err
	}
	di := &ast.DropIndex{Pos: pos(start)}
	if p.accept("IF") {
		if _, err := p.expect("EXISTS"); err != nil {
			return nil, err
		}
		di.IfExists = true
	}
	var err error
	if di.Name, _, err = p.ident(); err != nil {
		return nil, err
	}
	return di, nil
}

func asciiUpper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}

// ---------------------------------------------------------------- queries

func (p *parser) query() (*ast.Query, error) {
	start := p.peek()
	var with []*ast.CTE
	if p.accept("WITH") {
		for {
			cte, err := p.cte()
			if err != nil {
				return nil, err
			}
			with = append(with, cte)
			if !p.accept(",") {
				break
			}
		}
	}
	q, err := p.selectCore()
	if err != nil {
		return nil, err
	}
	q.Pos = pos(start)
	q.With = with
	for p.peek().Is("UNION") {
		u := p.next()
		if !p.accept("ALL") {
			return nil, p.unsupported(u, "UNION without ALL is not supported")
		}
		branch, err := p.selectCore()
		if err != nil {
			return nil, err
		}
		branch.Pos = pos(u)
		q.Union = append(q.Union, branch)
	}
	if p.accept("ORDER") {
		if _, err := p.expect("BY"); err != nil {
			return nil, err
		}
		for {
			item, err := p.orderItem()
			if err != nil {
				return nil, err
			}
			q.OrderBy = append(q.OrderBy, item)
			if !p.accept(",") {
				break
			}
		}
	}
	switch {
	case p.accept("LIMIT"):
		if q.Limit, err = p.clause(); err != nil {
			return nil, err
		}
		if p.accept("OFFSET") {
			if q.Offset, err = p.clause(); err != nil {
				return nil, err
			}
		}
	case p.accept("OFFSET"):
		if q.Offset, err = p.clause(); err != nil {
			return nil, err
		}
		if p.accept("LIMIT") {
			if q.Limit, err = p.clause(); err != nil {
				return nil, err
			}
		}
	}
	return q, nil
}

func (p *parser) cte() (*ast.CTE, error) {
	name, t, err := p.ident()
	if err != nil {
		return nil, err
	}
	cte := &ast.CTE{Pos: pos(t), Name: name}
	if p.accept("(") {
		for {
			col, _, err := p.ident()
			if err != nil {
				return nil, err
			}
			cte.Columns = append(cte.Columns, col)
			if !p.accept(",") {
				break
			}
		}
		if _, err := p.expect(")"); err != nil {
			return nil, err
		}
	}
	if _, err := p.expect("AS"); err != nil {
		return nil, err
	}
	if _, err := p.expect("("); err != nil {
		return nil, err
	}
	q, h, err := p.subquery()
	if err != nil {
		return nil, err
	}
	cte.Query = q
	p.note(h)
	if _, err := p.expect(")"); err != nil {
		return nil, err
	}
	return cte, nil
}

func (p *parser) selectCore() (*ast.Query, error) {
	if _, err := p.expect("SELECT"); err != nil {
		return nil, err
	}
	q := &ast.Query{}
	if p.accept("DISTINCT") {
		q.Distinct = true
	} else {
		p.accept("ALL")
	}
	for {
		item, err := p.selectItem()
		if err != nil {
			return nil, err
		}
		q.Items = append(q.Items, item)
		if !p.accept(",") {
			break
		}
	}
	var err error
	if p.accept("FROM") {
		if q.From, err = p.fromItem(); err != nil {
			return nil, err
		}
	}
	if p.accept("WHERE") {
		if q.Where, err = p.clause(); err != nil {
			return nil, err
		}
	}
	if p.accept("GROUP") {
		if _, err := p.expect("BY"); err != nil {
			return nil, err
		}
		for {
			e, err := p.clause()
			if err != nil {
				return nil, err
			}
			q.GroupBy = append(q.GroupBy, e)
			if !p.accept(",") {
				break
			}
		}
	}
	if p.accept("HAVING") {
		if q.Having, err = p.clause(); err != nil {
			return nil, err
		}
	}
	return q, nil
}

func (p *parser) selectItem() (*ast.SelectItem, error) {
	t := p.peek()
	if t.Is("*") {
		p.next()
		return &ast.SelectItem{Pos: pos(t), Star: true}, nil
	}
	if p.isIdent() && p.peekAt(1).Is(".") && p.peekAt(2).Is("*") {
		p.next()
		p.next()
		p.next()
		return &ast.SelectItem{Pos: pos(t), Star: true, Qualifier: t.Text}, nil
	}
	e, err := p.clause()
	if err != nil {
		return nil, err
	}
	item := &ast.SelectItem{Pos: pos(t), Expr: e}
	if p.accept("AS") {
		// After AS any word names the column, reserved keywords included
		// (e.g. `AS full`), as SQL column labels allow.
		if k := p.peek(); k.Kind == lexer.Keyword {
			p.next()
			item.Alias = k.Raw
		} else if item.Alias, _, err = p.ident(); err != nil {
			return nil, err
		}
		item.HasAlias = true
	} else if p.isIdent() {
		item.Alias = p.next().Text
		item.HasAlias = true
	}
	return item, nil
}

func (p *parser) orderItem() (*ast.OrderItem, error) {
	t := p.peek()
	e, err := p.clause()
	if err != nil {
		return nil, err
	}
	item := &ast.OrderItem{Pos: pos(t), Expr: e}
	if p.accept("DESC") {
		item.Desc = true
	} else {
		p.accept("ASC")
	}
	if p.accept("NULLS") {
		switch {
		case p.accept("FIRST"):
			v := true
			item.NullsFirst = &v
		case p.accept("LAST"):
			v := false
			item.NullsFirst = &v
		default:
			n := p.peek()
			return nil, errs.At(errs.ParseError, n.Line, n.Col, "expected FIRST or LAST but found %s", n.Describe())
		}
	}
	return item, nil
}

// ---------------------------------------------------------------- FROM

func (p *parser) fromItem() (ast.FromItem, error) {
	left, err := p.tableRef()
	if err != nil {
		return nil, err
	}
	for {
		t := p.peek()
		var jt ast.JoinType
		switch {
		case t.Is(","):
			p.next()
			jt = ast.JoinCross
		case t.Is("CROSS"):
			p.next()
			if _, err := p.expect("JOIN"); err != nil {
				return nil, err
			}
			jt = ast.JoinCross
		case t.Is("JOIN"):
			p.next()
			jt = ast.JoinInner
		case t.Is("INNER"):
			p.next()
			if _, err := p.expect("JOIN"); err != nil {
				return nil, err
			}
			jt = ast.JoinInner
		case t.Is("LEFT"):
			p.next()
			p.accept("OUTER")
			if _, err := p.expect("JOIN"); err != nil {
				return nil, err
			}
			jt = ast.JoinLeft
		case t.Is("RIGHT"), t.Is("FULL"):
			return nil, p.unsupported(t, t.Text+" JOIN is not supported")
		default:
			return left, nil
		}
		right, err := p.tableRef()
		if err != nil {
			return nil, err
		}
		j := &ast.Join{Pos: pos(t), Type: jt, Left: left, Right: right}
		if jt != ast.JoinCross {
			if _, err := p.expect("ON"); err != nil {
				return nil, err
			}
			if j.On, err = p.clause(); err != nil {
				return nil, err
			}
		}
		left = j
	}
}

func (p *parser) tableRef() (ast.FromItem, error) {
	t := p.peek()
	if t.Is("(") {
		if n := p.peekAt(1); n.Is("SELECT") || n.Is("WITH") {
			p.next()
			q, h, err := p.subquery()
			if err != nil {
				return nil, err
			}
			p.note(h)
			if _, err := p.expect(")"); err != nil {
				return nil, err
			}
			p.accept("AS")
			alias, _, err := p.ident()
			if err != nil {
				return nil, err
			}
			return &ast.SubqueryRef{Pos: pos(t), Query: q, Alias: alias}, nil
		}
		p.next()
		if err := p.enterJoin(); err != nil {
			return nil, err
		}
		inner, err := p.fromItem()
		p.leaveJoin()
		if err != nil {
			return nil, err
		}
		if _, err := p.expect(")"); err != nil {
			return nil, err
		}
		return inner, nil
	}
	name, _, err := p.ident()
	if err != nil {
		return nil, err
	}
	ref := &ast.TableRef{Pos: pos(t), Name: name}
	if p.accept("AS") {
		if ref.Alias, _, err = p.ident(); err != nil {
			return nil, err
		}
	} else if p.isIdent() {
		ref.Alias = p.next().Text
	}
	return ref, nil
}

// ---------------------------------------------------------------- expressions

// The expression parsers also return the nesting height of what they
// parsed: the largest number of nesting constructs (CR-6 §1) enclosing an
// operand within it. A literal or column reference has height 0, a
// construct one more than its operands, a chain of binary operators of one
// precedence level one more than its tallest operand, whatever its length.

// clause parses a top-level expression of a query clause.
func (p *parser) clause() (ast.Expr, error) {
	e, h, err := p.expr()
	p.note(h)
	return e, err
}

func (p *parser) expr() (ast.Expr, int, error) { return p.orExpr() }

// chain parses `operand (op operand)*` for the binary operators of one
// precedence level, building a left-deep tree.
func (p *parser) chain(operand func() (ast.Expr, int, error), isOp func(lexer.Token) bool) (ast.Expr, int, error) {
	l, h, err := operand()
	if err != nil || !isOp(p.peek()) {
		return l, h, err
	}
	if err := p.enter(); err != nil {
		return nil, 0, err
	}
	defer p.leave()
	for isOp(p.peek()) {
		t := p.next()
		r, hr, err := operand()
		if err != nil {
			return nil, 0, err
		}
		op := t.Text
		l, h = &ast.Binary{Pos: pos(t), Op: op, L: l, R: r}, max(h, hr)
	}
	h, err = p.level(h)
	return l, h, err
}

func isOr(t lexer.Token) bool     { return t.Is("OR") }
func isAnd(t lexer.Token) bool    { return t.Is("AND") }
func isConcat(t lexer.Token) bool { return t.Is("||") }
func isAdd(t lexer.Token) bool    { return t.Is("+") || t.Is("-") }
func isMul(t lexer.Token) bool    { return t.Is("*") || t.Is("/") || t.Is("%") }

func (p *parser) orExpr() (ast.Expr, int, error)  { return p.chain(p.andExpr, isOr) }
func (p *parser) andExpr() (ast.Expr, int, error) { return p.chain(p.notExpr, isAnd) }

func (p *parser) notExpr() (ast.Expr, int, error) {
	if t := p.peek(); t.Is("NOT") {
		p.next()
		if err := p.enter(); err != nil {
			return nil, 0, err
		}
		x, h, err := p.notExpr()
		p.leave()
		if err != nil {
			return nil, 0, err
		}
		h, err = p.level(h)
		return &ast.Unary{Pos: pos(t), Op: "NOT", X: x}, h, err
	}
	return p.predicate()
}

func isCompOp(t lexer.Token) bool {
	if t.Kind != lexer.Op {
		return false
	}
	switch t.Text {
	case "=", "<>", "!=", "<", "<=", ">", ">=":
		return true
	}
	return false
}

func (p *parser) predicate() (ast.Expr, int, error) {
	l, h, err := p.concatExpr()
	if err != nil {
		return nil, 0, err
	}
	t := p.peek()
	switch {
	case isCompOp(t):
		p.next()
		if err := p.enter(); err != nil {
			return nil, 0, err
		}
		r, hr, err := p.concatExpr()
		p.leave()
		if err != nil {
			return nil, 0, err
		}
		op := t.Text
		if op == "!=" {
			op = "<>"
		}
		h, err = p.level(max(h, hr))
		return &ast.Binary{Pos: pos(t), Op: op, L: l, R: r}, h, err
	case t.Is("IS"):
		p.next()
		not := p.accept("NOT")
		if _, err := p.expect("NULL"); err != nil {
			return nil, 0, err
		}
		return &ast.IsNull{Pos: pos(t), X: l, Not: not}, h, nil
	case t.Is("NOT"):
		n := p.peekAt(1)
		if n.Is("BETWEEN") || n.Is("IN") || n.Is("LIKE") {
			p.next()
			return p.predicateTail(l, h, true)
		}
	case t.Is("BETWEEN"), t.Is("IN"), t.Is("LIKE"):
		return p.predicateTail(l, h, false)
	}
	return l, h, nil
}

// predicateTail parses BETWEEN, LIKE or IN after its left operand l of
// height h.
func (p *parser) predicateTail(l ast.Expr, h int, not bool) (ast.Expr, int, error) {
	t := p.next()
	if err := p.enter(); err != nil {
		return nil, 0, err
	}
	e, inner, err := p.predicateOperands(t, l, not)
	p.leave()
	if err != nil {
		return nil, 0, err
	}
	h, err = p.level(max(h, inner))
	return e, h, err
}

func (p *parser) predicateOperands(t lexer.Token, l ast.Expr, not bool) (ast.Expr, int, error) {
	switch t.Text {
	case "BETWEEN":
		lo, hl, err := p.concatExpr()
		if err != nil {
			return nil, 0, err
		}
		if _, err := p.expect("AND"); err != nil {
			return nil, 0, err
		}
		hi, hh, err := p.concatExpr()
		if err != nil {
			return nil, 0, err
		}
		return &ast.Between{Pos: pos(t), X: l, Lo: lo, Hi: hi, Not: not}, max(hl, hh), nil
	case "LIKE":
		pat, h, err := p.concatExpr()
		if err != nil {
			return nil, 0, err
		}
		return &ast.Like{Pos: pos(t), X: l, Pattern: pat, Not: not}, h, nil
	}
	// IN
	if _, err := p.expect("("); err != nil {
		return nil, 0, err
	}
	if n := p.peek(); n.Is("SELECT") || n.Is("WITH") {
		// The IN construct and its subquery are one level.
		q, h, err := p.nestedQuery()
		if err != nil {
			return nil, 0, err
		}
		if _, err := p.expect(")"); err != nil {
			return nil, 0, err
		}
		return &ast.InSubquery{Pos: pos(t), X: l, Query: q, Not: not}, h, nil
	}
	in := &ast.InList{Pos: pos(t), X: l, Not: not}
	h := 0
	for {
		e, he, err := p.expr()
		if err != nil {
			return nil, 0, err
		}
		in.List = append(in.List, e)
		h = max(h, he)
		if !p.accept(",") {
			break
		}
	}
	if _, err := p.expect(")"); err != nil {
		return nil, 0, err
	}
	return in, h, nil
}

func (p *parser) concatExpr() (ast.Expr, int, error)     { return p.chain(p.additive, isConcat) }
func (p *parser) additive() (ast.Expr, int, error)       { return p.chain(p.multiplicative, isAdd) }
func (p *parser) multiplicative() (ast.Expr, int, error) { return p.chain(p.unary, isMul) }

func (p *parser) unary() (ast.Expr, int, error) {
	if t := p.peek(); t.Is("-") || t.Is("+") {
		p.next()
		if err := p.enter(); err != nil {
			return nil, 0, err
		}
		x, h, err := p.unary()
		p.leave()
		if err != nil {
			return nil, 0, err
		}
		h, err = p.level(h)
		return &ast.Unary{Pos: pos(t), Op: t.Text, X: x}, h, err
	}
	return p.primary()
}

func (p *parser) primary() (ast.Expr, int, error) {
	t := p.peek()
	switch t.Kind {
	case lexer.Number:
		p.next()
		return &ast.Literal{Pos: pos(t), Kind: ast.LitNumber, Text: t.Text}, 0, p.operand()
	case lexer.String:
		p.next()
		return &ast.Literal{Pos: pos(t), Kind: ast.LitString, Text: t.Text}, 0, p.operand()
	case lexer.Ident, lexer.QIdent:
		p.next()
		if t.Kind == lexer.Ident && p.peek().Is("(") {
			return p.funcCall(t)
		}
		if p.accept(".") {
			name, _, err := p.ident()
			if err != nil {
				return nil, 0, err
			}
			return &ast.ColumnRef{Pos: pos(t), Qualifier: t.Text, Name: name}, 0, p.operand()
		}
		return &ast.ColumnRef{Pos: pos(t), Name: t.Text}, 0, p.operand()
	case lexer.Keyword:
		switch t.Text {
		case "TRUE", "FALSE":
			p.next()
			return &ast.Literal{Pos: pos(t), Kind: ast.LitBool, Bool: t.Text == "TRUE"}, 0, p.operand()
		case "NULL":
			p.next()
			return &ast.Literal{Pos: pos(t), Kind: ast.LitNull}, 0, p.operand()
		case "DATE", "TIMESTAMP":
			p.next()
			s := p.peek()
			if s.Kind != lexer.String {
				return nil, 0, errs.At(errs.ParseError, s.Line, s.Col, "expected string literal after %s", t.Text)
			}
			p.next()
			kind := ast.LitDate
			if t.Text == "TIMESTAMP" {
				kind = ast.LitTimestamp
			}
			return &ast.Literal{Pos: pos(t), Kind: kind, Text: s.Text}, 0, p.operand()
		case "CAST":
			return p.nested(p.cast)
		case "CASE":
			return p.nested(p.caseExpr)
		case "EXISTS":
			p.next()
			if _, err := p.expect("("); err != nil {
				return nil, 0, err
			}
			q, h, err := p.subquery()
			if err != nil {
				return nil, 0, err
			}
			if _, err := p.expect(")"); err != nil {
				return nil, 0, err
			}
			return &ast.Exists{Pos: pos(t), Query: q}, h, nil
		}
	case lexer.Op:
		if t.Text == "(" {
			p.next()
			if n := p.peek(); n.Is("SELECT") || n.Is("WITH") {
				q, h, err := p.subquery()
				if err != nil {
					return nil, 0, err
				}
				if _, err := p.expect(")"); err != nil {
					return nil, 0, err
				}
				return &ast.Subquery{Pos: pos(t), Query: q}, h, nil
			}
			e, h, err := p.nested(p.expr)
			if err != nil {
				return nil, 0, err
			}
			if _, err := p.expect(")"); err != nil {
				return nil, 0, err
			}
			return e, h, nil
		}
	}
	return nil, 0, p.unexpected(t)
}

// nested parses a construct that adds one nesting level around what parse
// parses.
func (p *parser) nested(parse func() (ast.Expr, int, error)) (ast.Expr, int, error) {
	if err := p.enter(); err != nil {
		return nil, 0, err
	}
	e, h, err := parse()
	p.leave()
	if err != nil {
		return nil, 0, err
	}
	h, err = p.level(h)
	return e, h, err
}

// subquery parses a query nested in the current one (one nesting level)
// and returns its height.
func (p *parser) subquery() (*ast.Query, int, error) {
	if err := p.enter(); err != nil {
		return nil, 0, err
	}
	q, h, err := p.nestedQuery()
	p.leave()
	if err != nil {
		return nil, 0, err
	}
	h, err = p.level(h)
	return q, h, err
}

// nestedQuery parses a query and returns the largest nesting height in it,
// restoring the current query's height afterwards.
func (p *parser) nestedQuery() (*ast.Query, int, error) {
	saved := p.queryHeight
	p.queryHeight = 0
	q, err := p.query()
	h := p.queryHeight
	p.queryHeight = saved
	return q, h, err
}

func (p *parser) funcCall(name lexer.Token) (ast.Expr, int, error) {
	return p.nested(func() (ast.Expr, int, error) { return p.funcArgs(name) })
}

func (p *parser) funcArgs(name lexer.Token) (ast.Expr, int, error) {
	p.next() // (
	fc := &ast.FuncCall{Pos: pos(name), Name: name.Text}
	if p.accept("*") {
		fc.Star = true
		if _, err := p.expect(")"); err != nil {
			return nil, 0, err
		}
		return fc, 0, p.operand()
	}
	if p.accept(")") {
		return fc, 0, nil
	}
	if p.accept("DISTINCT") {
		fc.Distinct = true
	} else {
		p.accept("ALL")
	}
	h := 0
	for {
		e, he, err := p.expr()
		if err != nil {
			return nil, 0, err
		}
		fc.Args = append(fc.Args, e)
		h = max(h, he)
		if !p.accept(",") {
			break
		}
	}
	if _, err := p.expect(")"); err != nil {
		return nil, 0, err
	}
	return fc, h, nil
}

func (p *parser) cast() (ast.Expr, int, error) {
	t := p.next()
	if _, err := p.expect("("); err != nil {
		return nil, 0, err
	}
	x, h, err := p.expr()
	if err != nil {
		return nil, 0, err
	}
	if _, err := p.expect("AS"); err != nil {
		return nil, 0, err
	}
	nt := p.peek()
	if nt.Kind != lexer.Ident && nt.Kind != lexer.QIdent && nt.Kind != lexer.Keyword {
		return nil, 0, errs.At(errs.ParseError, nt.Line, nt.Col, "expected type name but found %s", nt.Describe())
	}
	p.next()
	tn := &ast.TypeName{Pos: pos(nt), Name: nt.Text}
	if p.accept("(") {
		for {
			n := p.peek()
			if n.Kind != lexer.Number {
				return nil, 0, errs.At(errs.ParseError, n.Line, n.Col, "expected type parameter but found %s", n.Describe())
			}
			p.next()
			v, err := strconv.Atoi(n.Text)
			if err != nil {
				return nil, 0, errs.At(errs.SemanticError, n.Line, n.Col, "invalid type parameter %s", n.Text)
			}
			tn.Params = append(tn.Params, v)
			if !p.accept(",") {
				break
			}
		}
		if _, err := p.expect(")"); err != nil {
			return nil, 0, err
		}
	}
	if _, err := p.expect(")"); err != nil {
		return nil, 0, err
	}
	return &ast.Cast{Pos: pos(t), X: x, Type: tn}, h, nil
}

func (p *parser) caseExpr() (ast.Expr, int, error) {
	t := p.next()
	c := &ast.Case{Pos: pos(t)}
	h := 0
	sub := func() (ast.Expr, error) {
		e, he, err := p.expr()
		h = max(h, he)
		return e, err
	}
	var err error
	if !p.peek().Is("WHEN") {
		if c.Operand, err = sub(); err != nil {
			return nil, 0, err
		}
	}
	for p.accept("WHEN") {
		cond, err := sub()
		if err != nil {
			return nil, 0, err
		}
		if _, err := p.expect("THEN"); err != nil {
			return nil, 0, err
		}
		res, err := sub()
		if err != nil {
			return nil, 0, err
		}
		c.Whens = append(c.Whens, ast.When{Cond: cond, Result: res})
	}
	if len(c.Whens) == 0 {
		n := p.peek()
		return nil, 0, errs.At(errs.ParseError, n.Line, n.Col, "expected WHEN but found %s", n.Describe())
	}
	if p.accept("ELSE") {
		if c.Else, err = sub(); err != nil {
			return nil, 0, err
		}
	}
	if _, err := p.expect("END"); err != nil {
		return nil, 0, err
	}
	return c, h, nil
}
