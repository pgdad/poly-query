package analyzer

import (
	"math"
	"strconv"
	"strings"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// binder resolves and type-checks one expression tree of a query block.
type binder struct {
	a   *analyzer
	sc  *scope
	env *cteEnv
	// aggs collects aggregate calls; nil means aggregates are not allowed
	// (clause names the offending clause for the error message).
	aggs   *[]*plan.AggCall
	clause string
	inAgg  bool
}

func (a *analyzer) newBinder(sc *scope, env *cteEnv, aggs *[]*plan.AggCall, clause string) *binder {
	return &binder{a: a, sc: sc, env: env, aggs: aggs, clause: clause}
}

func (b *binder) bind(e ast.Expr) (plan.Expr, error) {
	switch x := e.(type) {
	case *ast.Literal:
		return bindLiteral(x, false)
	case *ast.ColumnRef:
		return b.column(x)
	case *ast.Unary:
		return b.unary(x)
	case *ast.Binary:
		return b.binary(x)
	case *ast.IsNull:
		inner, err := b.bind(x.X)
		if err != nil {
			return nil, err
		}
		return &plan.IsNull{X: inner, Not: x.Not}, nil
	case *ast.Cast:
		return b.cast(x)
	case *ast.FuncCall:
		return b.call(x)
	case *ast.Case:
		return b.caseExpr(x)
	case *ast.Between:
		return b.between(x)
	case *ast.InList:
		return b.inList(x)
	case *ast.Like:
		return b.like(x)
	case *ast.InSubquery:
		return b.inSubquery(x)
	case *ast.Exists:
		return b.subquery(x.Pos, x.Query, plan.SubExists)
	case *ast.Subquery:
		return b.subquery(x.Pos, x.Query, plan.SubScalar)
	}
	return nil, errs.New(errs.InternalError, "unknown expression %T", e)
}

func (b *binder) bindAll(list []ast.Expr) ([]plan.Expr, error) {
	out := make([]plan.Expr, len(list))
	for i, e := range list {
		x, err := b.bind(e)
		if err != nil {
			return nil, err
		}
		out[i] = x
	}
	return out, nil
}

// ---------------------------------------------------------------- literals

func bindLiteral(x *ast.Literal, negate bool) (plan.Expr, error) {
	switch x.Kind {
	case ast.LitNumber:
		return numberLiteral(x, negate)
	case ast.LitString:
		return &plan.Literal{Val: types.StringValue(x.Text), T: types.String}, nil
	case ast.LitBool:
		return &plan.Literal{Val: types.BoolValue(x.Bool), T: types.Boolean}, nil
	case ast.LitNull:
		return &plan.Literal{Val: types.NullValue, T: types.Null}, nil
	case ast.LitDate:
		d, ok := types.ParseDate(x.Text)
		if !ok {
			return nil, errs.At(errs.ConversionError, x.Line, x.Col, "invalid DATE literal '%s'", x.Text)
		}
		return &plan.Literal{Val: types.IntValue(d), T: types.Date}, nil
	case ast.LitTimestamp:
		ts, ok := types.ParseTimestamp(x.Text)
		if !ok {
			return nil, errs.At(errs.ConversionError, x.Line, x.Col, "invalid TIMESTAMP literal '%s'", x.Text)
		}
		return &plan.Literal{Val: types.IntValue(ts), T: types.Timestamp}, nil
	}
	return nil, errs.New(errs.InternalError, "unknown literal kind")
}

// numberLiteral types a numeric literal per types.md §3. negate folds a
// preceding unary minus so that -9223372036854775808 is representable.
func numberLiteral(x *ast.Literal, negate bool) (plan.Expr, error) {
	text := x.Text
	overflow := func() error {
		return errs.At(errs.NumericOverflow, x.Line, x.Col, "numeric literal %s is out of range", text)
	}
	float := func() (plan.Expr, error) {
		f, err := strconv.ParseFloat(text, 64)
		if err != nil && math.IsInf(f, 0) {
			return nil, overflow()
		}
		if negate {
			f = -f
		}
		return &plan.Literal{Val: types.FloatValue(f), T: types.Float64}, nil
	}
	if strings.ContainsAny(text, "eE") {
		return float()
	}
	if dot := strings.IndexByte(text, '.'); dot >= 0 {
		intPart := strings.TrimLeft(text[:dot], "0")
		frac := text[dot+1:]
		s := len(frac)
		p := max(len(intPart)+s, s, 1)
		if p > types.MaxDecimalPrecision {
			return float()
		}
		t := types.Decimal(p, s)
		lit := "0" + intPart + "." + frac
		if negate {
			lit = "-" + lit
		}
		v, _ := types.ParseDecimalValue(lit, t, false) // fits t by construction
		return &plan.Literal{Val: v, T: t}, nil
	}
	if negate {
		text = "-" + text
	}
	i, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		return nil, overflow()
	}
	return &plan.Literal{Val: types.IntValue(i), T: types.Int64}, nil
}

// ---------------------------------------------------------------- columns

// column resolves a column reference in the current query block, then in
// enclosing blocks (correlation, semantics.md §1).
func (b *binder) column(x *ast.ColumnRef) (plan.Expr, error) {
	for s := b.sc; s != nil; s = s.parent {
		col, found, err := s.resolve(x)
		if err != nil {
			return nil, err
		}
		if found {
			return col.Ref(), nil
		}
	}
	if x.Qualifier != "" {
		return nil, semanticAt(x.Pos, "unknown table or alias %q", x.Qualifier)
	}
	return nil, semanticAt(x.Pos, "unknown column %q", x.Name)
}

func (s *scope) resolve(x *ast.ColumnRef) (plan.Column, bool, error) {
	var found []plan.Column
	qualified := false
	for _, v := range s.vars {
		if x.Qualifier != "" {
			if !storage.EqualFold(v.name, x.Qualifier) {
				continue
			}
			qualified = true
		}
		for _, c := range v.cols {
			if storage.EqualFold(c.Name, x.Name) {
				found = append(found, c)
			}
		}
	}
	switch {
	case len(found) > 1:
		return plan.Column{}, false, semanticAt(x.Pos, "column %q is ambiguous", x.Name)
	case len(found) == 1:
		return found[0], true, nil
	case qualified:
		return plan.Column{}, false, semanticAt(x.Pos, "unknown column %s.%s", x.Qualifier, x.Name)
	}
	return plan.Column{}, false, nil
}

// ---------------------------------------------------------------- operators

func (b *binder) unary(x *ast.Unary) (plan.Expr, error) {
	if x.Op == "-" {
		if lit, ok := x.X.(*ast.Literal); ok && lit.Kind == ast.LitNumber {
			return bindLiteral(lit, true)
		}
	}
	inner, err := b.bind(x.X)
	if err != nil {
		return nil, err
	}
	t := inner.Type()
	switch x.Op {
	case "NOT":
		if !isBoolish(t) {
			return nil, typeAt(x.Pos, "NOT requires a BOOLEAN operand, not %s", t)
		}
		return &plan.Unary{Op: plan.OpNot, X: inner, T: types.Boolean}, nil
	case "+", "-":
		if !isNumericOrNull(t) {
			return nil, typeAt(x.Pos, "unary %s requires a numeric operand, not %s", x.Op, t)
		}
		if x.Op == "+" {
			return inner, nil
		}
		return &plan.Unary{Op: plan.OpNeg, X: inner, T: t}, nil
	}
	return nil, errs.New(errs.InternalError, "unknown unary operator %s", x.Op)
}

func isNumericOrNull(t types.Type) bool { return t.IsNumeric() || t.Kind == types.KindNull }

var binaryOps = map[string]plan.BinaryOp{
	"+": plan.OpAdd, "-": plan.OpSub, "*": plan.OpMul, "/": plan.OpDiv, "%": plan.OpMod,
	"||": plan.OpConcat, "=": plan.OpEq, "<>": plan.OpNe, "<": plan.OpLt, "<=": plan.OpLe,
	">": plan.OpGt, ">=": plan.OpGe, "AND": plan.OpAnd, "OR": plan.OpOr,
}

func (b *binder) binary(x *ast.Binary) (plan.Expr, error) {
	op, ok := binaryOps[x.Op]
	if !ok {
		return nil, errs.New(errs.InternalError, "unknown operator %s", x.Op)
	}
	l, err := b.bind(x.L)
	if err != nil {
		return nil, err
	}
	r, err := b.bind(x.R)
	if err != nil {
		return nil, err
	}
	lt, rt := l.Type(), r.Type()
	switch {
	case op == plan.OpAnd || op == plan.OpOr:
		for _, t := range []types.Type{lt, rt} {
			if !isBoolish(t) {
				return nil, typeAt(x.Pos, "%s requires BOOLEAN operands, not %s", x.Op, t)
			}
		}
		return &plan.Binary{Op: op, L: l, R: r, T: types.Boolean}, nil
	case op == plan.OpConcat:
		for _, t := range []types.Type{lt, rt} {
			if t.Kind != types.KindString && t.Kind != types.KindNull {
				return nil, typeAt(x.Pos, "|| requires STRING operands, not %s", t)
			}
		}
		return &plan.Binary{Op: op, L: l, R: r, T: types.String}, nil
	case op.IsComparison():
		return comparison(x.Pos, op, l, r)
	}
	return arithmetic(x.Pos, op, l, r)
}

// promote wraps e in a cast to t unless it already has that type. DECIMAL
// operands keep their scale (operators handle differing scales exactly).
func promote(e plan.Expr, t types.Type) plan.Expr {
	et := e.Type()
	if et == t || et.Kind == types.KindNull {
		return e
	}
	if et.Kind == types.KindDecimal && t.Kind == types.KindDecimal {
		return e
	}
	return &plan.Cast{X: e, To: t}
}

// coerce converts e to exactly type t (used for CASE/COALESCE results).
func coerce(e plan.Expr, t types.Type) plan.Expr {
	if et := e.Type(); et == t || et.Kind == types.KindNull {
		return e
	}
	return &plan.Cast{X: e, To: t}
}

// comparisonType checks that two types are comparable and returns the type in
// which they are compared (types.md §2).
func comparisonType(pos ast.Pos, lt, rt types.Type) (types.Type, error) {
	if !types.Comparable(lt, rt) {
		return types.Type{}, typeAt(pos, "cannot compare %s with %s", lt, rt)
	}
	common, _ := types.CommonType(lt, rt)
	return common, nil
}

func comparison(pos ast.Pos, op plan.BinaryOp, l, r plan.Expr) (plan.Expr, error) {
	lt, rt := l.Type(), r.Type()
	common, err := comparisonType(pos, lt, rt)
	if err != nil {
		return nil, err
	}
	if needsPromotion(lt, rt) {
		l, r = promote(l, common), promote(r, common)
	}
	return &plan.Binary{Op: op, L: l, R: r, T: types.Boolean}, nil
}

// needsPromotion reports whether comparing values of types lt and rt
// requires converting them to their common type first. INT64 and DECIMAL
// operands are compared by exact value without conversion (CR-2 §4), so a
// conversion cannot overflow.
func needsPromotion(lt, rt types.Type) bool {
	if lt.Kind == rt.Kind || lt.Kind == types.KindNull || rt.Kind == types.KindNull {
		return false
	}
	return !(isExactNumeric(lt) && isExactNumeric(rt))
}

func isExactNumeric(t types.Type) bool {
	return t.Kind == types.KindInt64 || t.Kind == types.KindDecimal
}

func arithmetic(pos ast.Pos, op plan.BinaryOp, l, r plan.Expr) (plan.Expr, error) {
	lt, rt := l.Type(), r.Type()
	for _, t := range []types.Type{lt, rt} {
		if !isNumericOrNull(t) {
			return nil, typeAt(pos, "operator %s requires numeric operands, not %s", op, t)
		}
	}
	if lt.Kind == types.KindNull && rt.Kind == types.KindNull {
		return &plan.Binary{Op: op, L: l, R: r, T: types.Null}, nil
	}
	if lt.Kind == types.KindNull {
		lt = rt
	}
	if rt.Kind == types.KindNull {
		rt = lt
	}
	common := types.CommonNumeric(lt, rt)
	switch common.Kind {
	case types.KindInt64:
		return &plan.Binary{Op: op, L: l, R: r, T: types.Int64}, nil
	case types.KindFloat64:
		if op == plan.OpMod {
			return nil, typeAt(pos, "%% is only defined for INT64 operands")
		}
		return &plan.Binary{Op: op, L: promote(l, types.Float64), R: promote(r, types.Float64), T: types.Float64}, nil
	}
	// DECIMAL: INT64 operands become DECIMAL(W,0); operand scales are kept.
	// W is 38 if an operand is a wide DECIMAL, else 18 (CR-2 §2).
	sl, sr := lt.Scale, rt.Scale
	w := types.ResultPrecision(lt, rt)
	l, r = promote(l, types.Decimal(w, sl)), promote(r, types.Decimal(w, sr))
	switch op {
	case plan.OpAdd, plan.OpSub:
		return &plan.Binary{Op: op, L: l, R: r, T: types.Decimal(w, max(sl, sr))}, nil
	case plan.OpMul:
		if sl+sr > w {
			return nil, typeAt(pos, "DECIMAL multiplication result scale %d exceeds %d", sl+sr, w)
		}
		return &plan.Binary{Op: op, L: l, R: r, T: types.Decimal(w, sl+sr)}, nil
	case plan.OpDiv:
		return &plan.Binary{Op: op, L: promote(l, types.Float64), R: promote(r, types.Float64), T: types.Float64}, nil
	}
	return nil, typeAt(pos, "%% is only defined for INT64 operands")
}

// ---------------------------------------------------------------- CAST

func (b *binder) cast(x *ast.Cast) (plan.Expr, error) {
	inner, err := b.bind(x.X)
	if err != nil {
		return nil, err
	}
	to, err := types.Resolve(x.Type.Name, x.Type.Params)
	if err != nil {
		e := errs.From(err)
		return nil, errs.At(e.Code, x.Type.Line, x.Type.Col, "%s", e.Message)
	}
	if !types.CastAllowed(inner.Type(), to) {
		return nil, typeAt(x.Pos, "cannot cast %s to %s", inner.Type(), to)
	}
	return &plan.Cast{X: inner, To: to}, nil
}

// ---------------------------------------------------------------- CASE etc.

// unify computes the common result type of CASE branches / COALESCE
// arguments (semantics.md §13): numeric promotion, otherwise identical types;
// NULLs are ignored.
func unify(pos ast.Pos, what string, ts []types.Type) (types.Type, error) {
	t := types.Null
	for _, u := range ts {
		switch {
		case u.Kind == types.KindNull || u == t:
		case t.Kind == types.KindNull:
			t = u
		case t.IsNumeric() && u.IsNumeric():
			t = types.CommonNumeric(t, u)
		default:
			return types.Type{}, typeAt(pos, "%s has incompatible types %s and %s", what, t, u)
		}
	}
	return t, nil
}

func (b *binder) caseExpr(x *ast.Case) (plan.Expr, error) {
	c := &plan.Case{}
	var err error
	if x.Operand != nil {
		if c.Operand, err = b.bind(x.Operand); err != nil {
			return nil, err
		}
	}
	var results []types.Type
	for _, w := range x.Whens {
		cond, err := b.bind(w.Cond)
		if err != nil {
			return nil, err
		}
		if c.Operand != nil {
			ct, err := comparisonType(w.Cond.Position(), c.Operand.Type(), cond.Type())
			if err != nil {
				return nil, err
			}
			c.CmpTypes = append(c.CmpTypes, ct)
		} else if !isBoolish(cond.Type()) {
			return nil, typeAt(w.Cond.Position(), "CASE WHEN condition must be BOOLEAN, not %s", cond.Type())
		}
		res, err := b.bind(w.Result)
		if err != nil {
			return nil, err
		}
		c.Whens = append(c.Whens, plan.When{Cond: cond, Result: res})
		results = append(results, res.Type())
	}
	if x.Else != nil {
		if c.Else, err = b.bind(x.Else); err != nil {
			return nil, err
		}
		results = append(results, c.Else.Type())
	}
	if c.T, err = unify(x.Pos, "CASE", results); err != nil {
		return nil, err
	}
	for i := range c.Whens {
		c.Whens[i].Result = coerce(c.Whens[i].Result, c.T)
	}
	if c.Else != nil {
		c.Else = coerce(c.Else, c.T)
	}
	return c, nil
}

func (b *binder) between(x *ast.Between) (plan.Expr, error) {
	v, err := b.bind(x.X)
	if err != nil {
		return nil, err
	}
	lo, err := b.bind(x.Lo)
	if err != nil {
		return nil, err
	}
	hi, err := b.bind(x.Hi)
	if err != nil {
		return nil, err
	}
	bt := &plan.Between{X: v, Lo: lo, Hi: hi, Not: x.Not}
	if bt.LoType, err = comparisonType(x.Pos, v.Type(), lo.Type()); err != nil {
		return nil, err
	}
	if bt.HiType, err = comparisonType(x.Pos, v.Type(), hi.Type()); err != nil {
		return nil, err
	}
	return bt, nil
}

func (b *binder) inList(x *ast.InList) (plan.Expr, error) {
	v, err := b.bind(x.X)
	if err != nil {
		return nil, err
	}
	list, err := b.bindAll(x.List)
	if err != nil {
		return nil, err
	}
	in := &plan.InList{X: v, List: list, Not: x.Not}
	for _, e := range list {
		ct, err := comparisonType(x.Pos, v.Type(), e.Type())
		if err != nil {
			return nil, err
		}
		in.CmpTypes = append(in.CmpTypes, ct)
	}
	return in, nil
}

func (b *binder) like(x *ast.Like) (plan.Expr, error) {
	v, err := b.bind(x.X)
	if err != nil {
		return nil, err
	}
	p, err := b.bind(x.Pattern)
	if err != nil {
		return nil, err
	}
	for _, t := range []types.Type{v.Type(), p.Type()} {
		if t.Kind != types.KindString && t.Kind != types.KindNull {
			return nil, typeAt(x.Pos, "LIKE requires STRING operands, not %s", t)
		}
	}
	return &plan.Like{X: v, Pattern: p, Not: x.Not}, nil
}

// ---------------------------------------------------------------- subqueries

// subquery analyzes a nested query whose enclosing scope is the current one.
func (b *binder) subquery(pos ast.Pos, q *ast.Query, kind plan.SubqueryKind) (*plan.Subquery, error) {
	node, err := b.a.query(q, b.sc, b.env)
	if err != nil {
		return nil, err
	}
	b.a.subSeq++
	sq := &plan.Subquery{Kind: kind, Plan: node, Seq: b.a.subSeq, Correlated: plan.FreeColumns(node), T: types.Boolean}
	if kind != plan.SubExists {
		if n := len(node.Schema()); n != 1 {
			return nil, semanticAt(pos, "subquery must return exactly one column, not %d", n)
		}
		if kind == plan.SubScalar {
			sq.T = node.Schema()[0].Type
		}
	}
	return sq, nil
}

func (b *binder) inSubquery(x *ast.InSubquery) (plan.Expr, error) {
	v, err := b.bind(x.X)
	if err != nil {
		return nil, err
	}
	sq, err := b.subquery(x.Pos, x.Query, plan.SubIn)
	if err != nil {
		return nil, err
	}
	sq.X, sq.Not = v, x.Not
	if sq.CmpType, err = comparisonType(x.Pos, v.Type(), sq.Plan.Schema()[0].Type); err != nil {
		return nil, err
	}
	return sq, nil
}
