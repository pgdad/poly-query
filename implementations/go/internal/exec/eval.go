package exec

import (
	"math"
	"time"

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

// compile turns a bound expression into an evaluator.
func compile(ec *Context, e plan.Expr) (evalFn, error) {
	switch x := e.(type) {
	case *plan.ColumnRef:
		i := x.Index
		return func(row types.Row) (types.Value, error) { return row[i], nil }, nil
	case *plan.Literal:
		v := x.Val
		return func(types.Row) (types.Value, error) { return v, nil }, nil
	case *plan.Unary:
		return compileUnary(ec, x)
	case *plan.Binary:
		return compileBinary(ec, x)
	case *plan.IsNull:
		f, err := compile(ec, x.X)
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
		f, err := compile(ec, x.X)
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
		return compileFunc(ec, x)
	}
	return nil, errs.New(errs.InternalError, "cannot evaluate %T", e)
}

func compileUnary(ec *Context, x *plan.Unary) (evalFn, error) {
	f, err := compile(ec, x.X)
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
	return func(types.Row) (types.Value, error) { return null, nil }, nil
}

func compileBinary(ec *Context, x *plan.Binary) (evalFn, error) {
	lf, err := compile(ec, x.L)
	if err != nil {
		return nil, err
	}
	rf, err := compile(ec, x.R)
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
			switch {
			case !r.Null && r.I == 0:
				return falseVal, nil
			case l.Null || r.Null:
				return null, nil
			}
			return trueVal, nil
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

// both evaluates two operands.
func both(lf, rf evalFn, row types.Row) (types.Value, types.Value, error) {
	l, err := lf(row)
	if err != nil {
		return l, l, err
	}
	r, err := rf(row)
	return l, r, err
}

func compileComparison(x *plan.Binary, lf, rf evalFn) evalFn {
	lt, rt := x.L.Type(), x.R.Type()
	var test func(c int) bool
	switch x.Op {
	case plan.OpEq:
		test = func(c int) bool { return c == 0 }
	case plan.OpNe:
		test = func(c int) bool { return c != 0 }
	case plan.OpLt:
		test = func(c int) bool { return c < 0 }
	case plan.OpLe:
		test = func(c int) bool { return c <= 0 }
	case plan.OpGt:
		test = func(c int) bool { return c > 0 }
	default:
		test = func(c int) bool { return c >= 0 }
	}
	return func(row types.Row) (types.Value, error) {
		l, r, err := both(lf, rf, row)
		if err != nil || l.Null || r.Null {
			return null, err
		}
		return types.BoolValue(test(types.Compare(lt, l, rt, r))), nil
	}
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
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return 0, overflowErr("floating-point result is not finite")
	}
	return v, nil
}

func compileFunc(ec *Context, x *plan.Func) (evalFn, error) {
	args := make([]evalFn, len(x.Args))
	for i, a := range x.Args {
		f, err := compile(ec, a)
		if err != nil {
			return nil, err
		}
		args[i] = f
	}
	switch x.Name {
	case "PQ_SLEEP":
		return func(row types.Row) (types.Value, error) {
			v, err := args[0](row)
			if err != nil || v.Null {
				return v, err
			}
			if v.I < 0 {
				return null, errs.New(errs.InvalidArgument, "PQ_SLEEP requires a non-negative duration")
			}
			timer := time.NewTimer(time.Duration(v.I) * time.Millisecond)
			defer timer.Stop()
			select {
			case <-timer.C:
				return v, nil
			case <-ec.Ctx.Done():
				return null, ContextError(ec.Ctx.Err())
			}
		}, nil
	}
	return nil, errs.New(errs.InternalError, "unknown function %s", x.Name)
}

// evalConstant evaluates a constant expression.
func evalConstant(ec *Context, e plan.Expr) (types.Value, error) {
	f, err := compile(ec, e)
	if err != nil {
		return null, err
	}
	return f(nil)
}
