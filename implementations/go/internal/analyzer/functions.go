package analyzer

import (
	"strings"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/types"
)

var aggregateFuncs = map[string]plan.AggFunc{
	"COUNT": plan.AggCount, "SUM": plan.AggSum, "AVG": plan.AggAvg, "MIN": plan.AggMin, "MAX": plan.AggMax,
}

// scalarFunc describes a scalar function's arity and typing rule.
type scalarFunc struct {
	minArgs, maxArgs int // maxArgs < 0: variadic
	check            func(b *binder, x *ast.FuncCall, f *plan.Func) error
}

// aliases maps alternative function names to canonical ones.
var aliases = map[string]string{"CEILING": "CEIL", "SUBSTRING": "SUBSTR"}

var scalarFuncs map[string]scalarFunc

func init() {
	scalarFuncs = map[string]scalarFunc{
		"ABS":        {1, 1, checkAbs},
		"ROUND":      {1, 2, checkRound},
		"FLOOR":      {1, 1, checkFloorCeil},
		"CEIL":       {1, 1, checkFloorCeil},
		"SQRT":       {1, 1, checkFloatFunc},
		"POWER":      {2, 2, checkFloatFunc},
		"MOD":        {2, 2, checkMod},
		"LENGTH":     {1, 1, stringFunc(types.Int64)},
		"UPPER":      {1, 1, stringFunc(types.String)},
		"LOWER":      {1, 1, stringFunc(types.String)},
		"TRIM":       {1, 1, stringFunc(types.String)},
		"LTRIM":      {1, 1, stringFunc(types.String)},
		"RTRIM":      {1, 1, stringFunc(types.String)},
		"REPLACE":    {3, 3, stringFunc(types.String)},
		"SUBSTR":     {2, 3, checkSubstr},
		"CONCAT":     {1, -1, checkConcat},
		"COALESCE":   {1, -1, checkCoalesce},
		"NULLIF":     {2, 2, checkNullif},
		"YEAR":       {1, 1, datePartFunc(false)},
		"MONTH":      {1, 1, datePartFunc(false)},
		"DAY":        {1, 1, datePartFunc(false)},
		"HOUR":       {1, 1, datePartFunc(true)},
		"MINUTE":     {1, 1, datePartFunc(true)},
		"SECOND":     {1, 1, datePartFunc(true)},
		"DATE_TRUNC": {2, 2, checkDateTrunc},
		"DATE_DIFF":  {3, 3, checkDateDiff},
		"PQ_SLEEP":   {1, 1, checkSleep},
	}
}

func (b *binder) call(x *ast.FuncCall) (plan.Expr, error) {
	name := strings.ToUpper(x.Name)
	if fn, ok := aggregateFuncs[name]; ok {
		return b.aggregate(x, name, fn)
	}
	if canon, ok := aliases[name]; ok {
		name = canon
	}
	spec, ok := scalarFuncs[name]
	if !ok || (name == "PQ_SLEEP" && !b.a.cfg.TestFunctions) {
		return nil, semanticAt(x.Pos, "unknown function %s", x.Name)
	}
	if x.Star || x.Distinct {
		return nil, semanticAt(x.Pos, "%s is not an aggregate function", name)
	}
	if n := len(x.Args); n < spec.minArgs || (spec.maxArgs >= 0 && n > spec.maxArgs) {
		return nil, semanticAt(x.Pos, "wrong number of arguments for %s", name)
	}
	args, err := b.bindAll(x.Args)
	if err != nil {
		return nil, err
	}
	f := &plan.Func{Name: name, Args: args}
	if err := spec.check(b, x, f); err != nil {
		return nil, err
	}
	return f, nil
}

func argTypeError(x *ast.FuncCall, i int, t types.Type) error {
	return typeAt(x.Args[i].Position(), "invalid argument type %s for %s", t, strings.ToUpper(x.Name))
}

func isKind(t types.Type, kinds ...types.Kind) bool {
	if t.Kind == types.KindNull {
		return true
	}
	for _, k := range kinds {
		if t.Kind == k {
			return true
		}
	}
	return false
}

// requireKinds checks that every argument has one of the given kinds (or is
// NULL-typed).
func requireKinds(x *ast.FuncCall, f *plan.Func, kinds ...types.Kind) error {
	for i, a := range f.Args {
		if !isKind(a.Type(), kinds...) {
			return argTypeError(x, i, a.Type())
		}
	}
	return nil
}

func checkAbs(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	t := f.Args[0].Type()
	if !isNumericOrNull(t) {
		return argTypeError(x, 0, t)
	}
	f.T = t
	return nil
}

// constParam evaluates a constant parameter argument of the given kind.
func (b *binder) constParam(x *ast.FuncCall, f *plan.Func, i int, kind types.Kind) (types.Value, error) {
	arg := f.Args[i]
	if !plan.IsConstant(arg) {
		return types.Value{}, semanticAt(x.Args[i].Position(), "argument %d of %s must be a constant", i+1, f.Name)
	}
	if !isKind(arg.Type(), kind) {
		return types.Value{}, argTypeError(x, i, arg.Type())
	}
	if b.a.cfg.EvalConst == nil {
		return types.Value{}, errs.New(errs.InternalError, "constant evaluation is not configured")
	}
	v, err := b.a.cfg.EvalConst(arg)
	if err != nil {
		return types.Value{}, err
	}
	if v.Null {
		f.NullParam = true
	}
	return v, nil
}

func checkRound(b *binder, x *ast.FuncCall, f *plan.Func) error {
	t := f.Args[0].Type()
	if !isNumericOrNull(t) {
		return argTypeError(x, 0, t)
	}
	if len(f.Args) == 2 {
		v, err := b.constParam(x, f, 1, types.KindInt64)
		if err != nil {
			return err
		}
		f.Digits = v.I
	}
	f.T = t
	if t.Kind == types.KindDecimal {
		s := int64(t.Scale)
		if !f.NullParam {
			s = max(0, min(f.Digits, s))
		}
		f.T = types.Decimal(types.ResultPrecision(t), int(s))
	}
	return nil
}

func checkFloorCeil(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	t := f.Args[0].Type()
	if !isNumericOrNull(t) {
		return argTypeError(x, 0, t)
	}
	f.T = t
	if t.Kind == types.KindDecimal {
		f.T = types.Decimal(types.ResultPrecision(t), 0)
	}
	return nil
}

// checkFloatFunc types SQRT and POWER: numeric arguments evaluated in FLOAT64.
func checkFloatFunc(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	for i, a := range f.Args {
		if !isNumericOrNull(a.Type()) {
			return argTypeError(x, i, a.Type())
		}
		f.Args[i] = promote(a, types.Float64)
	}
	f.T = types.Float64
	return nil
}

func checkMod(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	f.T = types.Int64
	return requireKinds(x, f, types.KindInt64)
}

func stringFunc(result types.Type) func(*binder, *ast.FuncCall, *plan.Func) error {
	return func(_ *binder, x *ast.FuncCall, f *plan.Func) error {
		f.T = result
		return requireKinds(x, f, types.KindString)
	}
}

func checkSubstr(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	f.T = types.String
	if t := f.Args[0].Type(); !isKind(t, types.KindString) {
		return argTypeError(x, 0, t)
	}
	for i := 1; i < len(f.Args); i++ {
		if t := f.Args[i].Type(); !isKind(t, types.KindInt64) {
			return argTypeError(x, i, t)
		}
	}
	return nil
}

func checkConcat(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	f.T = types.String
	for i, a := range f.Args {
		if a.Type().Kind == types.KindFloat64 {
			return argTypeError(x, i, a.Type())
		}
	}
	return nil
}

func checkCoalesce(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	ts := make([]types.Type, len(f.Args))
	for i, a := range f.Args {
		ts[i] = a.Type()
	}
	t, err := unify(x.Pos, "COALESCE", ts)
	if err != nil {
		return err
	}
	for i, a := range f.Args {
		f.Args[i] = coerce(a, t)
	}
	f.T = t
	return nil
}

func checkNullif(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	at, bt := f.Args[0].Type(), f.Args[1].Type()
	if _, err := comparisonType(x.Pos, at, bt); err != nil {
		return err
	}
	if needsPromotion(at, bt) {
		common, _ := types.CommonType(at, bt)
		f.Args = []plan.Expr{f.Args[0], promote(f.Args[1], common)}
		if at.Kind != common.Kind {
			// Compare in the common type but return the original value.
			f.Args = append(f.Args, promote(f.Args[0], common))
		}
	}
	f.T = at
	return nil
}

func datePartFunc(timeOnly bool) func(*binder, *ast.FuncCall, *plan.Func) error {
	return func(_ *binder, x *ast.FuncCall, f *plan.Func) error {
		f.T = types.Int64
		if timeOnly {
			return requireKinds(x, f, types.KindTimestamp)
		}
		return requireKinds(x, f, types.KindDate, types.KindTimestamp)
	}
}

// unitParam validates a constant unit argument against the allowed units.
func (b *binder) unitParam(x *ast.FuncCall, f *plan.Func, allowed ...string) error {
	v, err := b.constParam(x, f, 0, types.KindString)
	if err != nil || v.Null {
		return err
	}
	unit := strings.ToLower(v.S)
	for _, u := range allowed {
		if unit == u {
			f.Unit = unit
			return nil
		}
	}
	p := x.Args[0].Position()
	return errs.At(errs.InvalidArgument, p.Line, p.Col, "unsupported unit '%s' for %s", v.S, f.Name)
}

func checkDateTrunc(b *binder, x *ast.FuncCall, f *plan.Func) error {
	f.T = types.Timestamp
	if t := f.Args[1].Type(); !isKind(t, types.KindDate, types.KindTimestamp) {
		return argTypeError(x, 1, t)
	}
	return b.unitParam(x, f, "year", "month", "day", "hour", "minute")
}

func checkDateDiff(b *binder, x *ast.FuncCall, f *plan.Func) error {
	f.T = types.Int64
	for i := 1; i < 3; i++ {
		if t := f.Args[i].Type(); !isKind(t, types.KindDate, types.KindTimestamp) {
			return argTypeError(x, i, t)
		}
	}
	return b.unitParam(x, f, "day")
}

func checkSleep(_ *binder, x *ast.FuncCall, f *plan.Func) error {
	f.T = types.Int64
	return requireKinds(x, f, types.KindInt64)
}

// ---------------------------------------------------------------- aggregates

func (b *binder) aggregate(x *ast.FuncCall, name string, fn plan.AggFunc) (plan.Expr, error) {
	if b.aggs == nil {
		return nil, semanticAt(x.Pos, "aggregate function %s is not allowed in %s", name, b.clause)
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
				call.T = types.Decimal(types.ResultPrecision(t), t.Scale)
			default:
				return nil, typeAt(x.Pos, "SUM requires a numeric argument, not %s", t)
			}
		case plan.AggAvg:
			if !isNumericOrNull(t) {
				return nil, typeAt(x.Pos, "AVG requires a numeric argument, not %s", t)
			}
			call.T = types.Float64
		case plan.AggMin, plan.AggMax:
			call.T = t
		}
	}
	*b.aggs = append(*b.aggs, call)
	return call, nil
}
