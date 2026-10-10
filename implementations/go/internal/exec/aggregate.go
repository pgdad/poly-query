package exec

import (
	"math"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// accumulator computes one aggregate over a group.
type accumulator interface {
	add(v types.Value) error
	result() (types.Value, error)
}

// newAccumulator creates the accumulator for an aggregate call.
func newAccumulator(call *plan.AggCall) accumulator {
	var argType types.Type
	if call.Arg != nil {
		argType = call.Arg.Type()
	}
	var acc accumulator
	switch call.Func {
	case plan.AggCountStar, plan.AggCount:
		acc = &countAcc{}
	case plan.AggSum:
		switch argType.Kind {
		case types.KindInt64:
			acc = &exactSumAcc{limit: 0}
		case types.KindDecimal:
			acc = &exactSumAcc{limit: types.MaxDecimalUnscaled}
		case types.KindFloat64:
			acc = &floatSumAcc{}
		default:
			acc = &nullAcc{}
		}
	case plan.AggAvg:
		switch argType.Kind {
		case types.KindInt64, types.KindDecimal:
			acc = &exactAvgAcc{scale: argType.Scale}
		case types.KindFloat64:
			acc = &floatAvgAcc{}
		default:
			acc = &nullAcc{}
		}
	case plan.AggMin:
		acc = &minMaxAcc{typ: argType, sign: -1}
	case plan.AggMax:
		acc = &minMaxAcc{typ: argType, sign: 1}
	}
	if call.Distinct && call.Func != plan.AggMin && call.Func != plan.AggMax {
		acc = &distinctAcc{inner: acc, seen: map[types.Value]struct{}{}}
	}
	return acc
}

type countAcc struct{ n int64 }

func (a *countAcc) add(v types.Value) error {
	if !v.Null {
		a.n++
	}
	return nil
}
func (a *countAcc) result() (types.Value, error) { return types.IntValue(a.n), nil }

type nullAcc struct{}

func (nullAcc) add(types.Value) error        { return nil }
func (nullAcc) result() (types.Value, error) { return types.NullValue, nil }

// exactSumAcc sums INT64 values or unscaled DECIMALs without intermediate
// overflow. limit > 0 bounds |result| (exclusive) for DECIMAL; 0 means the
// INT64 range.
type exactSumAcc struct {
	sum   types.BigDecimalSum
	any   bool
	limit int64
}

func (a *exactSumAcc) add(v types.Value) error {
	if !v.Null {
		a.sum.Add(v.I)
		a.any = true
	}
	return nil
}

func (a *exactSumAcc) result() (types.Value, error) {
	if !a.any {
		return types.NullValue, nil
	}
	s, ok := a.sum.Int64()
	if !ok || (a.limit > 0 && (s <= -a.limit || s >= a.limit)) {
		return types.NullValue, errs.New(errs.NumericOverflow, "SUM overflow")
	}
	return types.IntValue(s), nil
}

type floatSumAcc struct {
	sum float64
	any bool
}

func (a *floatSumAcc) add(v types.Value) error {
	if !v.Null {
		a.sum += v.F
		a.any = true
	}
	return nil
}

func (a *floatSumAcc) result() (types.Value, error) {
	if !a.any {
		return types.NullValue, nil
	}
	if math.IsInf(a.sum, 0) || math.IsNaN(a.sum) {
		return types.NullValue, errs.New(errs.NumericOverflow, "SUM is not finite")
	}
	return types.FloatValue(a.sum), nil
}

type exactAvgAcc struct {
	sum   types.BigDecimalSum
	n     int64
	scale int
}

func (a *exactAvgAcc) add(v types.Value) error {
	if !v.Null {
		a.sum.Add(v.I)
		a.n++
	}
	return nil
}

func (a *exactAvgAcc) result() (types.Value, error) {
	if a.n == 0 {
		return types.NullValue, nil
	}
	return types.FloatValue(a.sum.RatioFloat(a.n, a.scale)), nil
}

type floatAvgAcc struct {
	sum float64
	n   int64
}

func (a *floatAvgAcc) add(v types.Value) error {
	if !v.Null {
		a.sum += v.F
		a.n++
	}
	return nil
}

func (a *floatAvgAcc) result() (types.Value, error) {
	if a.n == 0 {
		return types.NullValue, nil
	}
	avg := a.sum / float64(a.n)
	if math.IsInf(avg, 0) || math.IsNaN(avg) {
		return types.NullValue, errs.New(errs.NumericOverflow, "AVG is not finite")
	}
	return types.FloatValue(avg), nil
}

type minMaxAcc struct {
	typ  types.Type
	sign int
	best types.Value
	any  bool
}

func (a *minMaxAcc) add(v types.Value) error {
	if v.Null {
		return nil
	}
	if !a.any || types.Compare(a.typ, v, a.typ, a.best)*a.sign > 0 {
		a.best = v
		a.any = true
	}
	return nil
}

func (a *minMaxAcc) result() (types.Value, error) {
	if !a.any {
		return types.NullValue, nil
	}
	return a.best, nil
}

// distinctAcc feeds each distinct non-NULL value to its inner accumulator once.
type distinctAcc struct {
	inner accumulator
	seen  map[types.Value]struct{}
}

func (a *distinctAcc) add(v types.Value) error {
	if v.Null {
		return nil
	}
	if v.F == 0 {
		v.F = 0 // fold -0.0 into 0.0
	}
	if _, ok := a.seen[v]; ok {
		return nil
	}
	a.seen[v] = struct{}{}
	return a.inner.add(v)
}

func (a *distinctAcc) result() (types.Value, error) { return a.inner.result() }

// hashAggregateOp groups its input by the key expressions in a hash table
// and computes the aggregates per group. Groups are emitted in order of first
// appearance; without keys exactly one row is produced, even for empty input.
type hashAggregateOp struct {
	ec       *Context
	input    Operator
	keys     []evalFn
	keyTypes []types.Type
	calls    []*plan.AggCall
	args     []evalFn // nil for COUNT(*)
	out      []types.Row
	pos      int
	done     bool
}

func (a *hashAggregateOp) Next() (types.Row, error) {
	if !a.done {
		a.done = true
		if err := a.run(); err != nil {
			return nil, err
		}
	}
	if a.pos >= len(a.out) {
		return nil, nil
	}
	row := a.out[a.pos]
	a.out[a.pos] = nil
	a.pos++
	return row, nil
}

func (a *hashAggregateOp) newGroup(keys types.Row) ([]accumulator, error) {
	accs := make([]accumulator, len(a.calls))
	for i, c := range a.calls {
		accs[i] = newAccumulator(c)
	}
	return accs, a.ec.Mem.Reserve(RowSize(keys) + int64(64*len(accs)))
}

func (a *hashAggregateOp) run() error {
	groups := map[string]int{}
	var keyRows []types.Row
	var accs [][]accumulator
	var key []byte
	vals := make(types.Row, len(a.keys))
	one := types.IntValue(1)
	for n := 0; ; n++ {
		row, err := a.input.Next()
		if err != nil {
			return err
		}
		if row == nil {
			break
		}
		if n%checkEvery == 0 {
			if err := a.ec.Check(); err != nil {
				return err
			}
		}
		key = key[:0]
		for i, f := range a.keys {
			if vals[i], err = f(row); err != nil {
				return err
			}
			key = appendKey(key, vals[i], a.keyTypes[i])
		}
		g, ok := groups[string(key)]
		if !ok {
			g = len(keyRows)
			groups[string(key)] = g
			kr := append(types.Row(nil), vals...)
			ga, err := a.newGroup(kr)
			if err != nil {
				return err
			}
			keyRows = append(keyRows, kr)
			accs = append(accs, ga)
		}
		for i, f := range a.args {
			v := one
			if f != nil {
				if v, err = f(row); err != nil {
					return err
				}
			}
			if err := accs[g][i].add(v); err != nil {
				return err
			}
		}
	}
	if len(a.keys) == 0 && len(keyRows) == 0 {
		ga, err := a.newGroup(nil)
		if err != nil {
			return err
		}
		keyRows = append(keyRows, types.Row{})
		accs = append(accs, ga)
	}
	a.out = make([]types.Row, len(keyRows))
	for g, kr := range keyRows {
		out := make(types.Row, len(kr), len(kr)+len(a.calls))
		copy(out, kr)
		for _, acc := range accs[g] {
			v, err := acc.result()
			if err != nil {
				return err
			}
			out = append(out, v)
		}
		a.out[g] = out
	}
	return nil
}
