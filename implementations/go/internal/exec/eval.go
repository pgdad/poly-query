package exec

import (
	"context"
	"math"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// evalFn evaluates an expression against an input row.
type evalFn func(row types.Row) (types.Value, error)

var (
	null       = types.NullValue
	trueVal    = types.BoolValue(true)
	falseVal   = types.BoolValue(false)
	errDivZero = errs.New(errs.DivisionByZero, "division by zero")
)

func overflowErr(msg string) error { return errs.New(errs.NumericOverflow, "%s", msg) }

// compile turns a bound expression into an evaluator over rows with the
// given layout. Columns absent from the layout are outer references of a
// correlated subquery and read the current parameter cell.
func compile(ec *Context, lay layout, e plan.Expr) (evalFn, error) {
	switch x := e.(type) {
	case *plan.ColumnRef:
		if i, ok := lay[x.ID]; ok {
			return func(row types.Row) (types.Value, error) { return row[i], nil }, nil
		}
		if cell, ok := ec.params[x.ID]; ok {
			return func(types.Row) (types.Value, error) { return *cell, nil }, nil
		}
		return nil, errs.New(errs.InternalError, "unbound column %s", x)
	case *plan.Literal:
		v := x.Val
		return func(types.Row) (types.Value, error) { return v, nil }, nil
	case *plan.Unary:
		return compileUnary(ec, lay, x)
	case *plan.Binary:
		return compileBinary(ec, lay, x)
	case *plan.IsNull:
		f, err := compile(ec, lay, x.X)
		if err != nil {
			return nil, err
		}
		not := x.Not
		return func(row types.Row) (types.Value, error) {
			v, err := f(row)
			if err != nil {
				return v, err
			}
			return types.BoolValue(v.Null != not), nil
		}, nil
	case *plan.Cast:
		f, err := compile(ec, lay, x.X)
		if err != nil {
			return nil, err
		}
		from, to := x.X.Type(), x.To
		return func(row types.Row) (types.Value, error) {
			v, err := f(row)
			if err != nil || v.Null {
				return v, err
			}
			return types.Cast(v, from, to)
		}, nil
	case *plan.Func:
		return compileFunc(ec, lay, x)
	case *plan.Case:
		return compileCase(ec, lay, x)
	case *plan.Between:
		return compileBetween(ec, lay, x)
	case *plan.InList:
		return compileInList(ec, lay, x)
	case *plan.Like:
		return compileLike(ec, lay, x)
	case *plan.Subquery:
		return compileSubquery(ec, lay, x)
	}
	return nil, errs.New(errs.InternalError, "cannot evaluate %T", e)
}

func compileAll(ec *Context, lay layout, exprs []plan.Expr) ([]evalFn, error) {
	fns := make([]evalFn, len(exprs))
	for i, e := range exprs {
		f, err := compile(ec, lay, e)
		if err != nil {
			return nil, err
		}
		fns[i] = f
	}
	return fns, nil
}

func compileUnary(ec *Context, lay layout, x *plan.Unary) (evalFn, error) {
	f, err := compile(ec, lay, x.X)
	if err != nil {
		return nil, err
	}
	if x.Op == plan.OpNot {
		return func(row types.Row) (types.Value, error) {
			v, err := f(row)
			if err != nil || v.Null {
				return v, err
			}
			return types.BoolValue(v.I == 0), nil
		}, nil
	}
	switch x.T.Kind {
	case types.KindFloat64:
		return func(row types.Row) (types.Value, error) {
			v, err := f(row)
			if err != nil || v.Null {
				return v, err
			}
			return types.FloatValue(-v.F), nil
		}, nil
	case types.KindInt64, types.KindDecimal:
		return func(row types.Row) (types.Value, error) {
			v, err := f(row)
			if err != nil || v.Null {
				return v, err
			}
			if v.I == math.MinInt64 {
				return null, overflowErr("integer overflow in negation")
			}
			return types.IntValue(-v.I), nil
		}, nil
	}
	return func(row types.Row) (types.Value, error) {
		_, err := f(row)
		return null, err
	}, nil
}

func compileBinary(ec *Context, lay layout, x *plan.Binary) (evalFn, error) {
	lf, err := compile(ec, lay, x.L)
	if err != nil {
		return nil, err
	}
	rf, err := compile(ec, lay, x.R)
	if err != nil {
		return nil, err
	}
	switch x.Op {
	case plan.OpAnd:
		return func(row types.Row) (types.Value, error) {
			l, err := lf(row)
			if err != nil {
				return l, err
			}
			if !l.Null && l.I == 0 {
				return falseVal, nil
			}
			r, err := rf(row)
			if err != nil {
				return r, err
			}
			return and3(l, r), nil
		}, nil
	case plan.OpOr:
		return func(row types.Row) (types.Value, error) {
			l, err := lf(row)
			if err != nil {
				return l, err
			}
			if !l.Null && l.I != 0 {
				return trueVal, nil
			}
			r, err := rf(row)
			if err != nil {
				return r, err
			}
			switch {
			case !r.Null && r.I != 0:
				return trueVal, nil
			case l.Null || r.Null:
				return null, nil
			}
			return falseVal, nil
		}, nil
	case plan.OpConcat:
		return func(row types.Row) (types.Value, error) {
			l, r, err := both(lf, rf, row)
			if err != nil || l.Null || r.Null {
				return null, err
			}
			return types.StringValue(l.S + r.S), nil
		}, nil
	}
	if x.Op.IsComparison() {
		return compileComparison(x, lf, rf), nil
	}
	return compileArithmetic(x, lf, rf)
}

// and3 is three-valued AND of two BOOLEAN values.
func and3(l, r types.Value) types.Value {
	switch {
	case !l.Null && l.I == 0, !r.Null && r.I == 0:
		return falseVal
	case l.Null || r.Null:
		return null
	}
	return trueVal
}

// not3 is three-valued NOT.
func not3(v types.Value) types.Value {
	if v.Null {
		return v
	}
	return types.BoolValue(v.I == 0)
}

// both evaluates two operands.
func both(lf, rf evalFn, row types.Row) (types.Value, types.Value, error) {
	l, err := lf(row)
	if err != nil {
		return l, l, err
	}
	r, err := rf(row)
	return l, r, err
}

func compareTest(op plan.BinaryOp) func(c int) bool {
	switch op {
	case plan.OpEq:
		return func(c int) bool { return c == 0 }
	case plan.OpNe:
		return func(c int) bool { return c != 0 }
	case plan.OpLt:
		return func(c int) bool { return c < 0 }
	case plan.OpLe:
		return func(c int) bool { return c <= 0 }
	case plan.OpGt:
		return func(c int) bool { return c > 0 }
	}
	return func(c int) bool { return c >= 0 }
}

func compileComparison(x *plan.Binary, lf, rf evalFn) evalFn {
	lt, rt := x.L.Type(), x.R.Type()
	test := compareTest(x.Op)
	return func(row types.Row) (types.Value, error) {
		l, r, err := both(lf, rf, row)
		if err != nil || l.Null || r.Null {
			return null, err
		}
		return types.BoolValue(test(types.Compare(lt, l, rt, r))), nil
	}
}

// comparer compares a value of type ta with a value of type tb after
// promoting both to their common comparison type ct (types.md §2). Both
// values must be non-NULL.
func comparer(ta, tb, ct types.Type) func(a, b types.Value) (int, error) {
	ca, ea := caster(ta, ct)
	cb, eb := caster(tb, ct)
	return func(a, b types.Value) (int, error) {
		a, err := ca(a)
		if err != nil {
			return 0, err
		}
		if b, err = cb(b); err != nil {
			return 0, err
		}
		return types.Compare(ea, a, eb, b), nil
	}
}

// caster returns a conversion from type from to the comparison type to and
// the effective type of converted values. DECIMALs keep their own scale.
func caster(from, to types.Type) (func(types.Value) (types.Value, error), types.Type) {
	if from.Kind == to.Kind || from.Kind == types.KindNull {
		return func(v types.Value) (types.Value, error) { return v, nil }, from
	}
	return func(v types.Value) (types.Value, error) { return types.Cast(v, from, to) }, to
}

func compileArithmetic(x *plan.Binary, lf, rf evalFn) (evalFn, error) {
	op := x.Op
	switch x.T.Kind {
	case types.KindInt64:
		return func(row types.Row) (types.Value, error) {
			l, r, err := both(lf, rf, row)
			if err != nil || l.Null || r.Null {
				return null, err
			}
			v, err := intOp(op, l.I, r.I)
			return types.IntValue(v), err
		}, nil
	case types.KindFloat64:
		return func(row types.Row) (types.Value, error) {
			l, r, err := both(lf, rf, row)
			if err != nil || l.Null || r.Null {
				return null, err
			}
			v, err := floatOp(op, l.F, r.F)
			return types.FloatValue(v), err
		}, nil
	case types.KindDecimal:
		sl, sr := x.L.Type().Scale, x.R.Type().Scale
		return func(row types.Row) (types.Value, error) {
			l, r, err := both(lf, rf, row)
			if err != nil || l.Null || r.Null {
				return null, err
			}
			var v int64
			switch op {
			case plan.OpAdd:
				v, err = types.DecimalAdd(l.I, sl, r.I, sr)
			case plan.OpSub:
				v, err = types.DecimalSub(l.I, sl, r.I, sr)
			case plan.OpMul:
				v, err = types.DecimalMul(l.I, r.I)
			default:
				err = errs.New(errs.InternalError, "invalid DECIMAL operator %s", op)
			}
			return types.IntValue(v), err
		}, nil
	}
	return func(row types.Row) (types.Value, error) {
		_, _, err := both(lf, rf, row)
		return null, err
	}, nil
}

func intOp(op plan.BinaryOp, a, b int64) (int64, error) {
	switch op {
	case plan.OpAdd:
		return types.AddInt64(a, b)
	case plan.OpSub:
		return types.SubInt64(a, b)
	case plan.OpMul:
		return types.MulInt64(a, b)
	case plan.OpDiv:
		if b == 0 {
			return 0, errDivZero
		}
		if a == math.MinInt64 && b == -1 {
			return 0, overflowErr("integer overflow in division")
		}
		return a / b, nil
	case plan.OpMod:
		if b == 0 {
			return 0, errDivZero
		}
		if b == -1 {
			return 0, nil
		}
		return a % b, nil
	}
	return 0, errs.New(errs.InternalError, "invalid INT64 operator %s", op)
}

func floatOp(op plan.BinaryOp, a, b float64) (float64, error) {
	var v float64
	switch op {
	case plan.OpAdd:
		v = a + b
	case plan.OpSub:
		v = a - b
	case plan.OpMul:
		v = a * b
	case plan.OpDiv:
		if b == 0 {
			return 0, errDivZero
		}
		v = a / b
	default:
		return 0, errs.New(errs.InternalError, "invalid FLOAT64 operator %s", op)
	}
	return finite(v)
}

// finite rejects non-finite FLOAT64 results with NUMERIC_OVERFLOW.
func finite(v float64) (float64, error) {
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return 0, overflowErr("floating-point result is not finite")
	}
	return v, nil
}

// ---------------------------------------------------------------- CASE etc.

func compileCase(ec *Context, lay layout, x *plan.Case) (evalFn, error) {
	n := len(x.Whens)
	conds, results := make([]evalFn, n), make([]evalFn, n)
	for i, w := range x.Whens {
		var err error
		if conds[i], err = compile(ec, lay, w.Cond); err != nil {
			return nil, err
		}
		if results[i], err = compile(ec, lay, w.Result); err != nil {
			return nil, err
		}
	}
	elseFn := func(types.Row) (types.Value, error) { return null, nil }
	if x.Else != nil {
		var err error
		if elseFn, err = compile(ec, lay, x.Else); err != nil {
			return nil, err
		}
	}
	if x.Operand == nil {
		return func(row types.Row) (types.Value, error) {
			for i, c := range conds {
				v, err := c(row)
				if err != nil {
					return v, err
				}
				if v.IsTrue() {
					return results[i](row)
				}
			}
			return elseFn(row)
		}, nil
	}
	operand, err := compile(ec, lay, x.Operand)
	if err != nil {
		return nil, err
	}
	cmps := make([]func(a, b types.Value) (int, error), n)
	for i, w := range x.Whens {
		cmps[i] = comparer(x.Operand.Type(), w.Cond.Type(), x.CmpTypes[i])
	}
	return func(row types.Row) (types.Value, error) {
		o, err := operand(row)
		if err != nil {
			return o, err
		}
		if !o.Null {
			for i, c := range conds {
				v, err := c(row)
				if err != nil {
					return v, err
				}
				if v.Null {
					continue
				}
				r, err := cmps[i](o, v)
				if err != nil {
					return null, err
				}
				if r == 0 {
					return results[i](row)
				}
			}
		}
		return elseFn(row)
	}, nil
}

func compileBetween(ec *Context, lay layout, x *plan.Between) (evalFn, error) {
	fns, err := compileAll(ec, lay, []plan.Expr{x.X, x.Lo, x.Hi})
	if err != nil {
		return nil, err
	}
	xt := x.X.Type()
	cmpLo := comparer(xt, x.Lo.Type(), x.LoType)
	cmpHi := comparer(xt, x.Hi.Type(), x.HiType)
	not := x.Not
	return func(row types.Row) (types.Value, error) {
		v, err := fns[0](row)
		if err != nil {
			return v, err
		}
		lo, err := fns[1](row)
		if err != nil {
			return lo, err
		}
		hi, err := fns[2](row)
		if err != nil {
			return hi, err
		}
		ge, le := null, null
		if !v.Null && !lo.Null {
			c, err := cmpLo(v, lo)
			if err != nil {
				return null, err
			}
			ge = types.BoolValue(c >= 0)
		}
		if !v.Null && !hi.Null {
			c, err := cmpHi(v, hi)
			if err != nil {
				return null, err
			}
			le = types.BoolValue(c <= 0)
		}
		r := and3(ge, le)
		if not {
			r = not3(r)
		}
		return r, nil
	}, nil
}

func compileInList(ec *Context, lay layout, x *plan.InList) (evalFn, error) {
	vf, err := compile(ec, lay, x.X)
	if err != nil {
		return nil, err
	}
	list, err := compileAll(ec, lay, x.List)
	if err != nil {
		return nil, err
	}
	cmps := make([]func(a, b types.Value) (int, error), len(x.List))
	for i, e := range x.List {
		cmps[i] = comparer(x.X.Type(), e.Type(), x.CmpTypes[i])
	}
	not := x.Not
	return func(row types.Row) (types.Value, error) {
		v, err := vf(row)
		if err != nil {
			return v, err
		}
		result := falseVal
		for i, f := range list {
			e, err := f(row)
			if err != nil {
				return e, err
			}
			if v.Null || e.Null {
				result = null
				continue
			}
			c, err := cmps[i](v, e)
			if err != nil {
				return null, err
			}
			if c == 0 {
				result = trueVal
				break
			}
		}
		if not {
			result = not3(result)
		}
		return result, nil
	}, nil
}

// evalConstant evaluates a constant expression.
func evalConstant(ec *Context, e plan.Expr) (types.Value, error) {
	f, err := compile(ec, nil, e)
	if err != nil {
		return null, err
	}
	return f(nil)
}

// EvalConstant evaluates a constant expression outside of a query (used by
// semantic analysis for constant function parameters).
func EvalConstant(e plan.Expr) (types.Value, error) {
	return evalConstant(&Context{Ctx: context.Background()}, e)
}
