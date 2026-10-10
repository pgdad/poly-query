package exec

import (
	"math"
	"sort"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// accumulator computes one aggregate over a group.
type accumulator interface {
	add(v types.Value) error
	// merge folds another accumulator of the same aggregate (partial
	// aggregation of parallel workers) into this one.
	merge(o accumulator)
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
func (a *countAcc) merge(o accumulator)          { a.n += o.(*countAcc).n }
func (a *countAcc) result() (types.Value, error) { return types.IntValue(a.n), nil }

type nullAcc struct{}

func (nullAcc) add(types.Value) error        { return nil }
func (nullAcc) merge(accumulator)            {}
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

func (a *exactSumAcc) merge(o accumulator) {
	b := o.(*exactSumAcc)
	if b.any {
		a.sum.Merge(&b.sum)
		a.any = true
	}
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

func (a *floatSumAcc) merge(o accumulator) {
	b := o.(*floatSumAcc)
	if b.any {
		a.sum += b.sum
		a.any = true
	}
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

func (a *exactAvgAcc) merge(o accumulator) {
	b := o.(*exactAvgAcc)
	a.sum.Merge(&b.sum)
	a.n += b.n
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

func (a *floatAvgAcc) merge(o accumulator) {
	b := o.(*floatAvgAcc)
	a.sum += b.sum
	a.n += b.n
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

func (a *minMaxAcc) merge(o accumulator) {
	if b := o.(*minMaxAcc); b.any {
		_ = a.add(b.best)
	}
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
	order []types.Value // distinct values in insertion order
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
	a.order = append(a.order, v)
	return a.inner.add(v)
}

// merge adds the other accumulator's distinct values in their insertion
// order (so FLOAT64 sums do not depend on map iteration order).
func (a *distinctAcc) merge(o accumulator) {
	for _, v := range o.(*distinctAcc).order {
		_ = a.add(v)
	}
}

func (a *distinctAcc) result() (types.Value, error) { return a.inner.result() }

// rowAggTable is the hash table of row-mode aggregation: groups by
// encoded key, with one accumulator per aggregate and group. Groups
// remember the position of their first row so that partial tables of
// parallel workers can be merged into first-appearance order.
type rowAggTable struct {
	ec       *Context
	keyTypes []types.Type
	calls    []*plan.AggCall
	groups   map[string]int
	keyRows  []types.Row
	accs     [][]accumulator
	first    []int64
	key      []byte
}

func newRowAggTable(ec *Context, keyTypes []types.Type, calls []*plan.AggCall) *rowAggTable {
	return &rowAggTable{ec: ec, keyTypes: keyTypes, calls: calls, groups: map[string]int{}}
}

// group returns the group of the given key values (encoded in t.key),
// creating it if necessary.
func (t *rowAggTable) group(vals types.Row, pos int64) (int, error) {
	g, ok := t.groups[string(t.key)]
	if ok {
		if pos < t.first[g] {
			t.first[g] = pos
		}
		return g, nil
	}
	g = len(t.keyRows)
	t.groups[string(t.key)] = g
	kr := append(types.Row(nil), vals...)
	accs := make([]accumulator, len(t.calls))
	for i, c := range t.calls {
		accs[i] = newAccumulator(c)
	}
	t.keyRows = append(t.keyRows, kr)
	t.accs = append(t.accs, accs)
	t.first = append(t.first, pos)
	return g, t.ec.Mem.Reserve(RowSize(kr) + int64(64*len(accs)))
}

// mergeFrom folds the groups of o into t.
func (t *rowAggTable) mergeFrom(o *rowAggTable) error {
	for g, kr := range o.keyRows {
		t.key = t.key[:0]
		for i, v := range kr {
			t.key = appendKey(t.key, v, t.keyTypes[i])
		}
		dst, err := t.group(kr, o.first[g])
		if err != nil {
			return err
		}
		for i, acc := range o.accs[g] {
			t.accs[dst][i].merge(acc)
		}
	}
	return nil
}

// rows computes the result rows in first-appearance order; without keys
// there is exactly one row, even for empty input.
func (t *rowAggTable) rows() ([]types.Row, error) {
	if len(t.keyTypes) == 0 && len(t.keyRows) == 0 {
		t.key = t.key[:0]
		if _, err := t.group(types.Row{}, 0); err != nil {
			return nil, err
		}
	}
	order := make([]int, len(t.keyRows))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool { return t.first[order[a]] < t.first[order[b]] })
	out := make([]types.Row, len(order))
	for i, g := range order {
		kr := t.keyRows[g]
		row := make(types.Row, len(kr), len(kr)+len(t.calls))
		copy(row, kr)
		for _, acc := range t.accs[g] {
			v, err := acc.result()
			if err != nil {
				return nil, err
			}
			row = append(row, v)
		}
		out[i] = row
	}
	return out, nil
}

// rowAggInput evaluates the keys and arguments of an aggregation for one
// row and folds it into a table.
type rowAggInput struct {
	keys []evalFn
	args []evalFn // nil for COUNT(*)
	vals types.Row
}

var one = types.IntValue(1)

func (in *rowAggInput) add(t *rowAggTable, row types.Row, pos int64) error {
	t.key = t.key[:0]
	for i, f := range in.keys {
		v, err := f(row)
		if err != nil {
			return err
		}
		in.vals[i] = v
		t.key = appendKey(t.key, v, t.keyTypes[i])
	}
	g, err := t.group(in.vals, pos)
	if err != nil {
		return err
	}
	for i, f := range in.args {
		v := one
		if f != nil {
			if v, err = f(row); err != nil {
				return err
			}
		}
		if err := t.accs[g][i].add(v); err != nil {
			return err
		}
	}
	return nil
}

// hashAggregateOp groups its input by the key expressions in a hash table
// and computes the aggregates per group. Groups are emitted in order of first
// appearance; without keys exactly one row is produced, even for empty input.
type hashAggregateOp struct {
	ec       *Context
	input    Operator
	in       *rowAggInput
	keyTypes []types.Type
	calls    []*plan.AggCall
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

func (a *hashAggregateOp) run() error {
	t := newRowAggTable(a.ec, a.keyTypes, a.calls)
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
		if err := a.in.add(t, row, int64(n)); err != nil {
			return err
		}
	}
	var err error
	a.out, err = t.rows()
	return err
}
