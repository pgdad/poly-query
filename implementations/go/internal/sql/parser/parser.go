// Package parser implements a recursive-descent parser for the PolyQuery SQL
// grammar (spec/sql/grammar.md §2), producing an ast.Statement.
package parser

import (
	"strconv"

	"polyquery/internal/errs"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/lexer"
)

type parser struct {
	toks []lexer.Token
	pos  int
}

// Parse parses exactly one statement (with an optional trailing ';').
func Parse(sql string) (ast.Statement, error) {
	toks, err := lexer.Tokenize(sql)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks}
	stmt, err := p.statement()
	if err != nil {
		return nil, err
	}
	p.accept(";")
	if t := p.peek(); t.Kind != lexer.EOF {
		return nil, p.unexpected(t)
	}
	return stmt, nil
}

// ---------------------------------------------------------------- helpers

func (p *parser) peek() lexer.Token { return p.toks[p.pos] }

func (p *parser) peekAt(n int) lexer.Token {
	if p.pos+n < len(p.toks) {
		return p.toks[p.pos+n]
	}
	return p.toks[len(p.toks)-1]
}

func (p *parser) next() lexer.Token {
	t := p.toks[p.pos]
	if t.Kind != lexer.EOF {
		p.pos++
	}
	return t
}

func (p *parser) accept(text string) bool {
	if p.peek().Is(text) {
		p.pos++
		return true
	}
	return false
}

func (p *parser) expect(text string) (lexer.Token, error) {
	t := p.peek()
	if !t.Is(text) {
		return t, errs.At(errs.ParseError, t.Line, t.Col, "expected %s but found %s", text, t.Describe())
	}
	p.pos++
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
		p.pos++
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
		if q.Limit, err = p.expr(); err != nil {
			return nil, err
		}
		if p.accept("OFFSET") {
			if q.Offset, err = p.expr(); err != nil {
				return nil, err
			}
		}
	case p.accept("OFFSET"):
		if q.Offset, err = p.expr(); err != nil {
			return nil, err
		}
		if p.accept("LIMIT") {
			if q.Limit, err = p.expr(); err != nil {
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
	if cte.Query, err = p.query(); err != nil {
		return nil, err
	}
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
		if q.Where, err = p.expr(); err != nil {
			return nil, err
		}
	}
	if p.accept("GROUP") {
		if _, err := p.expect("BY"); err != nil {
			return nil, err
		}
		for {
			e, err := p.expr()
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
		if q.Having, err = p.expr(); err != nil {
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
		p.pos += 3
		return &ast.SelectItem{Pos: pos(t), Star: true, Qualifier: t.Text}, nil
	}
	e, err := p.expr()
	if err != nil {
		return nil, err
	}
	item := &ast.SelectItem{Pos: pos(t), Expr: e}
	if p.accept("AS") {
		if item.Alias, _, err = p.ident(); err != nil {
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
	e, err := p.expr()
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
			if j.On, err = p.expr(); err != nil {
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
			q, err := p.query()
			if err != nil {
				return nil, err
			}
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
		inner, err := p.fromItem()
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

func (p *parser) expr() (ast.Expr, error) { return p.orExpr() }

func (p *parser) orExpr() (ast.Expr, error) {
	l, err := p.andExpr()
	if err != nil {
		return nil, err
	}
	for p.peek().Is("OR") {
		t := p.next()
		r, err := p.andExpr()
		if err != nil {
			return nil, err
		}
		l = &ast.Binary{Pos: pos(t), Op: "OR", L: l, R: r}
	}
	return l, nil
}

func (p *parser) andExpr() (ast.Expr, error) {
	l, err := p.notExpr()
	if err != nil {
		return nil, err
	}
	for p.peek().Is("AND") {
		t := p.next()
		r, err := p.notExpr()
		if err != nil {
			return nil, err
		}
		l = &ast.Binary{Pos: pos(t), Op: "AND", L: l, R: r}
	}
	return l, nil
}

func (p *parser) notExpr() (ast.Expr, error) {
	if t := p.peek(); t.Is("NOT") {
		p.next()
		x, err := p.notExpr()
		if err != nil {
			return nil, err
		}
		return &ast.Unary{Pos: pos(t), Op: "NOT", X: x}, nil
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

func (p *parser) predicate() (ast.Expr, error) {
	l, err := p.concatExpr()
	if err != nil {
		return nil, err
	}
	t := p.peek()
	switch {
	case isCompOp(t):
		p.next()
		r, err := p.concatExpr()
		if err != nil {
			return nil, err
		}
		op := t.Text
		if op == "!=" {
			op = "<>"
		}
		return &ast.Binary{Pos: pos(t), Op: op, L: l, R: r}, nil
	case t.Is("IS"):
		p.next()
		not := p.accept("NOT")
		if _, err := p.expect("NULL"); err != nil {
			return nil, err
		}
		return &ast.IsNull{Pos: pos(t), X: l, Not: not}, nil
	case t.Is("NOT"):
		n := p.peekAt(1)
		if n.Is("BETWEEN") || n.Is("IN") || n.Is("LIKE") {
			p.next()
			return p.predicateTail(l, true)
		}
	case t.Is("BETWEEN"), t.Is("IN"), t.Is("LIKE"):
		return p.predicateTail(l, false)
	}
	return l, nil
}

func (p *parser) predicateTail(l ast.Expr, not bool) (ast.Expr, error) {
	t := p.next()
	switch t.Text {
	case "BETWEEN":
		lo, err := p.concatExpr()
		if err != nil {
			return nil, err
		}
		if _, err := p.expect("AND"); err != nil {
			return nil, err
		}
		hi, err := p.concatExpr()
		if err != nil {
			return nil, err
		}
		return &ast.Between{Pos: pos(t), X: l, Lo: lo, Hi: hi, Not: not}, nil
	case "LIKE":
		pat, err := p.concatExpr()
		if err != nil {
			return nil, err
		}
		return &ast.Like{Pos: pos(t), X: l, Pattern: pat, Not: not}, nil
	}
	// IN
	if _, err := p.expect("("); err != nil {
		return nil, err
	}
	if n := p.peek(); n.Is("SELECT") || n.Is("WITH") {
		q, err := p.query()
		if err != nil {
			return nil, err
		}
		if _, err := p.expect(")"); err != nil {
			return nil, err
		}
		return &ast.InSubquery{Pos: pos(t), X: l, Query: q, Not: not}, nil
	}
	in := &ast.InList{Pos: pos(t), X: l, Not: not}
	for {
		e, err := p.expr()
		if err != nil {
			return nil, err
		}
		in.List = append(in.List, e)
		if !p.accept(",") {
			break
		}
	}
	if _, err := p.expect(")"); err != nil {
		return nil, err
	}
	return in, nil
}

func (p *parser) concatExpr() (ast.Expr, error) {
	l, err := p.additive()
	if err != nil {
		return nil, err
	}
	for p.peek().Is("||") {
		t := p.next()
		r, err := p.additive()
		if err != nil {
			return nil, err
		}
		l = &ast.Binary{Pos: pos(t), Op: "||", L: l, R: r}
	}
	return l, nil
}

func (p *parser) additive() (ast.Expr, error) {
	l, err := p.multiplicative()
	if err != nil {
		return nil, err
	}
	for p.peek().Is("+") || p.peek().Is("-") {
		t := p.next()
		r, err := p.multiplicative()
		if err != nil {
			return nil, err
		}
		l = &ast.Binary{Pos: pos(t), Op: t.Text, L: l, R: r}
	}
	return l, nil
}

func (p *parser) multiplicative() (ast.Expr, error) {
	l, err := p.unary()
	if err != nil {
		return nil, err
	}
	for p.peek().Is("*") || p.peek().Is("/") || p.peek().Is("%") {
		t := p.next()
		r, err := p.unary()
		if err != nil {
			return nil, err
		}
		l = &ast.Binary{Pos: pos(t), Op: t.Text, L: l, R: r}
	}
	return l, nil
}

func (p *parser) unary() (ast.Expr, error) {
	if t := p.peek(); t.Is("-") || t.Is("+") {
		p.next()
		x, err := p.unary()
		if err != nil {
			return nil, err
		}
		return &ast.Unary{Pos: pos(t), Op: t.Text, X: x}, nil
	}
	return p.primary()
}

func (p *parser) primary() (ast.Expr, error) {
	t := p.peek()
	switch t.Kind {
	case lexer.Number:
		p.next()
		return &ast.Literal{Pos: pos(t), Kind: ast.LitNumber, Text: t.Text}, nil
	case lexer.String:
		p.next()
		return &ast.Literal{Pos: pos(t), Kind: ast.LitString, Text: t.Text}, nil
	case lexer.Ident, lexer.QIdent:
		p.next()
		if t.Kind == lexer.Ident && p.peek().Is("(") {
			return p.funcCall(t)
		}
		if p.accept(".") {
			name, _, err := p.ident()
			if err != nil {
				return nil, err
			}
			return &ast.ColumnRef{Pos: pos(t), Qualifier: t.Text, Name: name}, nil
		}
		return &ast.ColumnRef{Pos: pos(t), Name: t.Text}, nil
	case lexer.Keyword:
		switch t.Text {
		case "TRUE", "FALSE":
			p.next()
			return &ast.Literal{Pos: pos(t), Kind: ast.LitBool, Bool: t.Text == "TRUE"}, nil
		case "NULL":
			p.next()
			return &ast.Literal{Pos: pos(t), Kind: ast.LitNull}, nil
		case "DATE", "TIMESTAMP":
			p.next()
			s := p.peek()
			if s.Kind != lexer.String {
				return nil, errs.At(errs.ParseError, s.Line, s.Col, "expected string literal after %s", t.Text)
			}
			p.next()
			kind := ast.LitDate
			if t.Text == "TIMESTAMP" {
				kind = ast.LitTimestamp
			}
			return &ast.Literal{Pos: pos(t), Kind: kind, Text: s.Text}, nil
		case "CAST":
			return p.cast()
		case "CASE":
			return p.caseExpr()
		case "EXISTS":
			p.next()
			if _, err := p.expect("("); err != nil {
				return nil, err
			}
			q, err := p.query()
			if err != nil {
				return nil, err
			}
			if _, err := p.expect(")"); err != nil {
				return nil, err
			}
			return &ast.Exists{Pos: pos(t), Query: q}, nil
		}
	case lexer.Op:
		if t.Text == "(" {
			p.next()
			if n := p.peek(); n.Is("SELECT") || n.Is("WITH") {
				q, err := p.query()
				if err != nil {
					return nil, err
				}
				if _, err := p.expect(")"); err != nil {
					return nil, err
				}
				return &ast.Subquery{Pos: pos(t), Query: q}, nil
			}
			e, err := p.expr()
			if err != nil {
				return nil, err
			}
			if _, err := p.expect(")"); err != nil {
				return nil, err
			}
			return e, nil
		}
	}
	return nil, p.unexpected(t)
}

func (p *parser) funcCall(name lexer.Token) (ast.Expr, error) {
	p.next() // (
	fc := &ast.FuncCall{Pos: pos(name), Name: name.Text}
	if p.accept("*") {
		fc.Star = true
		if _, err := p.expect(")"); err != nil {
			return nil, err
		}
		return fc, nil
	}
	if p.accept(")") {
		return fc, nil
	}
	if p.accept("DISTINCT") {
		fc.Distinct = true
	} else {
		p.accept("ALL")
	}
	for {
		e, err := p.expr()
		if err != nil {
			return nil, err
		}
		fc.Args = append(fc.Args, e)
		if !p.accept(",") {
			break
		}
	}
	if _, err := p.expect(")"); err != nil {
		return nil, err
	}
	return fc, nil
}

func (p *parser) cast() (ast.Expr, error) {
	t := p.next()
	if _, err := p.expect("("); err != nil {
		return nil, err
	}
	x, err := p.expr()
	if err != nil {
		return nil, err
	}
	if _, err := p.expect("AS"); err != nil {
		return nil, err
	}
	nt := p.peek()
	if nt.Kind != lexer.Ident && nt.Kind != lexer.QIdent && nt.Kind != lexer.Keyword {
		return nil, errs.At(errs.ParseError, nt.Line, nt.Col, "expected type name but found %s", nt.Describe())
	}
	p.next()
	tn := &ast.TypeName{Pos: pos(nt), Name: nt.Text}
	if p.accept("(") {
		for {
			n := p.peek()
			if n.Kind != lexer.Number {
				return nil, errs.At(errs.ParseError, n.Line, n.Col, "expected type parameter but found %s", n.Describe())
			}
			p.next()
			v, err := strconv.Atoi(n.Text)
			if err != nil {
				return nil, errs.At(errs.SemanticError, n.Line, n.Col, "invalid type parameter %s", n.Text)
			}
			tn.Params = append(tn.Params, v)
			if !p.accept(",") {
				break
			}
		}
		if _, err := p.expect(")"); err != nil {
			return nil, err
		}
	}
	if _, err := p.expect(")"); err != nil {
		return nil, err
	}
	return &ast.Cast{Pos: pos(t), X: x, Type: tn}, nil
}

func (p *parser) caseExpr() (ast.Expr, error) {
	t := p.next()
	c := &ast.Case{Pos: pos(t)}
	var err error
	if !p.peek().Is("WHEN") {
		if c.Operand, err = p.expr(); err != nil {
			return nil, err
		}
	}
	for p.accept("WHEN") {
		cond, err := p.expr()
		if err != nil {
			return nil, err
		}
		if _, err := p.expect("THEN"); err != nil {
			return nil, err
		}
		res, err := p.expr()
		if err != nil {
			return nil, err
		}
		c.Whens = append(c.Whens, ast.When{Cond: cond, Result: res})
	}
	if len(c.Whens) == 0 {
		n := p.peek()
		return nil, errs.At(errs.ParseError, n.Line, n.Col, "expected WHEN but found %s", n.Describe())
	}
	if p.accept("ELSE") {
		if c.Else, err = p.expr(); err != nil {
			return nil, err
		}
	}
	if _, err := p.expect("END"); err != nil {
		return nil, err
	}
	return c, nil
}
