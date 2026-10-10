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

// binder resolves and type-checks one expression tree.
type binder struct {
	a     *analyzer
	scope *scope
	// aggs collects aggregate calls; nil means aggregates are not allowed
	// (aggClause names the offending clause for the error message).
	aggs      *[]*plan.AggCall
	aggClause string
	inAgg     bool
	// bare is set when an input column is referenced outside aggregate
	// arguments.
	bare bool
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
		return nil, unsupportedAt(x.Pos, "CASE is not supported")
	case *ast.Between:
		return nil, unsupportedAt(x.Pos, "BETWEEN is not supported")
	case *ast.InList:
		return nil, unsupportedAt(x.Pos, "IN is not supported")
	case *ast.Like:
		return nil, unsupportedAt(x.Pos, "LIKE is not supported")
	case *ast.InSubquery:
		return nil, unsupportedAt(x.Pos, "subqueries are not supported")
	case *ast.Exists:
		return nil, unsupportedAt(x.Pos, "subqueries are not supported")
	case *ast.Subquery:
		return nil, unsupportedAt(x.Pos, "subqueries are not supported")
	}
	return nil, errs.New(errs.InternalError, "unknown expression %T", e)
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
	if strings.ContainsAny(text, "eE") {
		f, err := strconv.ParseFloat(text, 64)
		if err != nil && math.IsInf(f, 0) {
			return nil, overflow()
		}
		if negate {
			f = -f
		}
		return &plan.Literal{Val: types.FloatValue(f), T: types.Float64}, nil
	}
	if dot := strings.IndexByte(text, '.'); dot >= 0 {
		intPart := strings.TrimLeft(text[:dot], "0")
		frac := text[dot+1:]
		s := len(frac)
		p := max(len(intPart)+s, s, 1)
		if p > types.MaxDecimalPrecision {
			f, err := strconv.ParseFloat(text, 64)
			if err != nil && math.IsInf(f, 0) {
				return nil, overflow()
			}
			if negate {
				f = -f
			}
			return &plan.Literal{Val: types.FloatValue(f), T: types.Float64}, nil
		}
		var u int64
		if digits := intPart + frac; digits != "" {
			u, _ = strconv.ParseInt(digits, 10, 64) // at most 18 digits
		}
		if negate {
			u = -u
		}
		return &plan.Literal{Val: types.IntValue(u), T: types.Decimal(p, s)}, nil
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

func (b *binder) column(x *ast.ColumnRef) (plan.Expr, error) {
	var found *rangeVar
	col := -1
	for _, v := range b.scope.vars {
		if x.Qualifier != "" && !storage.EqualFold(v.name, x.Qualifier) {
			continue
		}
		if i := v.table.ColumnIndex(x.Name); i >= 0 {
			if found != nil {
				return nil, semanticAt(x.Pos, "column %q is ambiguous", x.Name)
			}
			found, col = v, i
		}
	}
	if found == nil {
		if x.Qualifier != "" {
			known := false
			for _, v := range b.scope.vars {
				known = known || storage.EqualFold(v.name, x.Qualifier)
			}
			if !known {
				return nil, semanticAt(x.Pos, "unknown table or alias %q", x.Qualifier)
			}
			return nil, semanticAt(x.Pos, "unknown column %s.%s", x.Qualifier, x.Name)
		}
		return nil, semanticAt(x.Pos, "unknown column %q", x.Name)
	}
	if !b.inAgg {
		b.bare = true
	}
	b.scope.markUsed(found, col)
	def := found.table.Columns[col]
	return &plan.ColumnRef{Index: found.offset + col, Name: def.Name, T: def.Type}, nil
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
		if t.Kind != types.KindBoolean && t.Kind != types.KindNull {
			return nil, typeAt(x.Pos, "NOT requires a BOOLEAN operand, not %s", t)
		}
		return &plan.Unary{Op: plan.OpNot, X: inner, T: types.Boolean}, nil
	case "+", "-":
		if !t.IsNumeric() && t.Kind != types.KindNull {
			return nil, typeAt(x.Pos, "unary %s requires a numeric operand, not %s", x.Op, t)
		}
		if x.Op == "+" {
			return inner, nil
		}
		return &plan.Unary{Op: plan.OpNeg, X: inner, T: t}, nil
	}
	return nil, errs.New(errs.InternalError, "unknown unary operator %s", x.Op)
}

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
			if t.Kind != types.KindBoolean && t.Kind != types.KindNull {
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

// promote wraps e in a cast to t unless it already has that type.
func promote(e plan.Expr, t types.Type) plan.Expr {
	et := e.Type()
	if et == t || et.Kind == types.KindNull {
		return e
	}
	if et.Kind == types.KindDecimal && t.Kind == types.KindDecimal {
		return e // decimal operators handle differing scales exactly
	}
	return &plan.Cast{X: e, To: t}
}

func comparison(pos ast.Pos, op plan.BinaryOp, l, r plan.Expr) (plan.Expr, error) {
	lt, rt := l.Type(), r.Type()
	if !types.Comparable(lt, rt) {
		return nil, typeAt(pos, "cannot compare %s with %s", lt, rt)
	}
	if lt.Kind != rt.Kind && lt.Kind != types.KindNull && rt.Kind != types.KindNull {
		common, _ := types.CommonType(lt, rt)
		l, r = promote(l, common), promote(r, common)
	}
	return &plan.Binary{Op: op, L: l, R: r, T: types.Boolean}, nil
}

func arithmetic(pos ast.Pos, op plan.BinaryOp, l, r plan.Expr) (plan.Expr, error) {
	lt, rt := l.Type(), r.Type()
	for _, t := range []types.Type{lt, rt} {
		if !t.IsNumeric() && t.Kind != types.KindNull {
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
	// DECIMAL: INT64 operands become DECIMAL(18,0); operand scales are kept.
	sl, sr := lt.Scale, rt.Scale
	l, r = promote(l, types.Decimal(18, sl)), promote(r, types.Decimal(18, sr))
	switch op {
	case plan.OpAdd, plan.OpSub:
		return &plan.Binary{Op: op, L: l, R: r, T: types.Decimal(18, max(sl, sr))}, nil
	case plan.OpMul:
		if sl+sr > types.MaxDecimalPrecision {
			return nil, typeAt(pos, "DECIMAL multiplication result scale %d exceeds 18", sl+sr)
		}
		return &plan.Binary{Op: op, L: l, R: r, T: types.Decimal(18, sl+sr)}, nil
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

// ---------------------------------------------------------------- functions

var aggregateFuncs = map[string]plan.AggFunc{
	"COUNT": plan.AggCount, "SUM": plan.AggSum, "AVG": plan.AggAvg, "MIN": plan.AggMin, "MAX": plan.AggMax,
}

// phase2Functions are valid scalar functions this engine does not implement
// yet; they are reported as UNSUPPORTED rather than unknown.
var phase2Functions = map[string]bool{
	"ABS": true, "ROUND": true, "FLOOR": true, "CEIL": true, "CEILING": true, "SQRT": true,
	"POWER": true, "MOD": true, "LENGTH": true, "UPPER": true, "LOWER": true, "SUBSTR": true,
	"SUBSTRING": true, "TRIM": true, "LTRIM": true, "RTRIM": true, "REPLACE": true, "CONCAT": true,
	"COALESCE": true, "NULLIF": true, "YEAR": true, "MONTH": true, "DAY": true, "HOUR": true,
	"MINUTE": true, "SECOND": true, "DATE_TRUNC": true, "DATE_DIFF": true,
}

func (b *binder) call(x *ast.FuncCall) (plan.Expr, error) {
	name := strings.ToUpper(x.Name)
	if fn, ok := aggregateFuncs[name]; ok {
		return b.aggregate(x, name, fn)
	}
	if x.Star || x.Distinct {
		return nil, semanticAt(x.Pos, "%s is not an aggregate function", name)
	}
	switch {
	case name == "PQ_SLEEP" && b.a.cfg.TestFunctions:
		if len(x.Args) != 1 {
			return nil, semanticAt(x.Pos, "PQ_SLEEP takes exactly one argument")
		}
		arg, err := b.bind(x.Args[0])
		if err != nil {
			return nil, err
		}
		if k := arg.Type().Kind; k != types.KindInt64 && k != types.KindNull {
			return nil, typeAt(x.Pos, "PQ_SLEEP requires an INT64 argument, not %s", arg.Type())
		}
		return &plan.Func{Name: name, Args: []plan.Expr{arg}, T: types.Int64}, nil
	case phase2Functions[name]:
		return nil, unsupportedAt(x.Pos, "function %s is not supported", name)
	}
	return nil, semanticAt(x.Pos, "unknown function %s", x.Name)
}

func (b *binder) aggregate(x *ast.FuncCall, name string, fn plan.AggFunc) (plan.Expr, error) {
	if b.aggs == nil {
		return nil, semanticAt(x.Pos, "aggregate function %s is not allowed in %s", name, b.aggClause)
	}
	if b.inAgg {
		return nil, semanticAt(x.Pos, "aggregate functions cannot be nested")
	}
	call := &plan.AggCall{Func: fn, Distinct: x.Distinct}
	if x.Star {
		if fn != plan.AggCount {
			return nil, semanticAt(x.Pos, "%s(*) is not allowed", name)
		}
		call.Func = plan.AggCountStar
		call.T = types.Int64
	} else {
		if len(x.Args) != 1 {
			return nil, semanticAt(x.Pos, "%s takes exactly one argument", name)
		}
		b.inAgg = true
		arg, err := b.bind(x.Args[0])
		b.inAgg = false
		if err != nil {
			return nil, err
		}
		call.Arg = arg
		t := arg.Type()
		switch fn {
		case plan.AggCount:
			call.T = types.Int64
		case plan.AggSum:
			switch t.Kind {
			case types.KindInt64, types.KindFloat64, types.KindNull:
				call.T = t
			case types.KindDecimal:
				call.T = types.Decimal(18, t.Scale)
			default:
				return nil, typeAt(x.Pos, "SUM requires a numeric argument, not %s", t)
			}
		case plan.AggAvg:
			if !t.IsNumeric() && t.Kind != types.KindNull {
				return nil, typeAt(x.Pos, "AVG requires a numeric argument, not %s", t)
			}
			call.T = types.Float64
		case plan.AggMin, plan.AggMax:
			call.T = t
		}
	}
	key := call.String()
	for i, existing := range *b.aggs {
		if existing.String() == key {
			return &plan.ColumnRef{Index: i, Name: key, T: existing.T}, nil
		}
	}
	*b.aggs = append(*b.aggs, call)
	return &plan.ColumnRef{Index: len(*b.aggs) - 1, Name: key, T: call.T}, nil
}
