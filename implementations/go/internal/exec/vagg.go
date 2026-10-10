package exec

import (
	"math"
	"slices"

	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Vectorized hash aggregation. Group IDs are resolved for a whole batch
// first (with specialized hash maps for a single integer, float or string
// key, and per-dictionary code→group caches for dictionary-encoded
// strings), then every aggregate updates a struct-of-arrays state in a
// tight loop over the batch. States are mergeable, so parallel workers
// aggregate morsels into private tables that are merged at the end.

// aggState holds one aggregate's state for every group.
type aggState interface {
	grow(groups int)
	// update folds rows sel (nil: 0..n-1) of v into groups gids[i]; v is
	// nil for COUNT(*).
	update(gids []int32, n int, sel []int32, v *Vec)
	// merge folds group sg of src (same concrete type) into group g.
	merge(g int32, src aggState, sg int32)
	result(g int) (types.Value, error)
}

func newAggState(call *plan.AggCall) aggState {
	if call.Func == plan.AggCountStar {
		return &countState{star: true}
	}
	t := call.Arg.Type()
	if call.Distinct && call.Func != plan.AggMin && call.Func != plan.AggMax {
		return &genericState{call: call, cls: classOf(t)}
	}
	switch call.Func {
	case plan.AggCount:
		return &countState{}
	case plan.AggSum:
		switch t.Kind {
		case types.KindInt64:
			return &exactSumState{}
		case types.KindDecimal:
			return &exactSumState{limit: types.MaxDecimalUnscaled}
		case types.KindFloat64:
			return &floatSumState{}
		}
	case plan.AggAvg:
		switch t.Kind {
		case types.KindInt64, types.KindDecimal:
			return &exactSumState{avg: true, scale: t.Scale}
		case types.KindFloat64:
			return &floatSumState{avg: true}
		}
	case plan.AggMin, plan.AggMax:
		sign := 1
		if call.Func == plan.AggMin {
			sign = -1
		}
		switch t.Kind {
		case types.KindNull:
		case types.KindFloat64:
			return &floatMinMax{sign: sign}
		case types.KindString:
			return &stringMinMax{sign: sign}
		default:
			// BOOLEAN, INT64, DATE, TIMESTAMP and DECIMAL (one scale per
			// column) order like their int64 representation.
			return &intMinMax{sign: sign}
		}
	}
	return &genericState{call: call, cls: classOf(t)}
}

// count of rows (COUNT(*)) or of non-NULL values.
type countState struct {
	star bool
	n    []int64
}

func (s *countState) grow(g int) { s.n = growZero(s.n, g) }

func (s *countState) update(gids []int32, n int, sel []int32, v *Vec) {
	cnt := s.n
	if s.star || v.Nulls == nil {
		if sel == nil {
			for _, g := range gids[:n] {
				cnt[g]++
			}
			return
		}
		for _, i := range sel {
			cnt[gids[i]]++
		}
		return
	}
	nulls := v.Nulls
	if sel == nil {
		for i, g := range gids[:n] {
			if !nulls[i] {
				cnt[g]++
			}
		}
		return
	}
	for _, i := range sel {
		if !nulls[i] {
			cnt[gids[i]]++
		}
	}
}

func (s *countState) merge(g int32, src aggState, sg int32) { s.n[g] += src.(*countState).n[sg] }
func (s *countState) result(g int) (types.Value, error)     { return types.IntValue(s.n[g]), nil }

// growZero extends a per-group slice to g entries (zero values).
func growZero[T any](s []T, g int) []T {
	if g <= len(s) {
		return s
	}
	if g <= cap(s) {
		var zero T
		old := len(s)
		s = s[:g]
		for i := old; i < g; i++ {
			s[i] = zero
		}
		return s
	}
	out := make([]T, g, max(2*cap(s), g, 16))
	copy(out, s)
	return out
}

// exactSumState is SUM/AVG over INT64 or DECIMAL: exact (wide) sums.
type exactSumState struct {
	sums  []types.BigDecimalSum
	n     []int64
	limit int64 // DECIMAL SUM: exclusive bound of the result
	avg   bool
	scale int
}

func (s *exactSumState) grow(g int) {
	s.sums = growZero(s.sums, g)
	s.n = growZero(s.n, g)
}

func (s *exactSumState) update(gids []int32, n int, sel []int32, v *Vec) {
	sums, cnt, vals, nulls := s.sums, s.n, v.I, v.Nulls
	if sel == nil && nulls == nil {
		for i, g := range gids[:n] {
			sums[g].Add(vals[i])
			cnt[g]++
		}
		return
	}
	forActive(n, sel, func(i int) {
		if nulls == nil || !nulls[i] {
			g := gids[i]
			sums[g].Add(vals[i])
			cnt[g]++
		}
	})
}

func (s *exactSumState) merge(g int32, src aggState, sg int32) {
	o := src.(*exactSumState)
	s.sums[g].Merge(&o.sums[sg])
	s.n[g] += o.n[sg]
}

func (s *exactSumState) result(g int) (types.Value, error) {
	if s.n[g] == 0 {
		return null, nil
	}
	if s.avg {
		return types.FloatValue(s.sums[g].RatioFloat(s.n[g], s.scale)), nil
	}
	v, ok := s.sums[g].Int64()
	if !ok || (s.limit > 0 && (v <= -s.limit || v >= s.limit)) {
		return null, errs.New(errs.NumericOverflow, "SUM overflow")
	}
	return types.IntValue(v), nil
}

// floatSumState is SUM/AVG over FLOAT64.
type floatSumState struct {
	sums []float64
	n    []int64
	avg  bool
}

func (s *floatSumState) grow(g int) {
	s.sums = growZero(s.sums, g)
	s.n = growZero(s.n, g)
}

func (s *floatSumState) update(gids []int32, n int, sel []int32, v *Vec) {
	sums, cnt, vals, nulls := s.sums, s.n, v.F, v.Nulls
	if sel == nil && nulls == nil {
		for i, g := range gids[:n] {
			sums[g] += vals[i]
			cnt[g]++
		}
		return
	}
	forActive(n, sel, func(i int) {
		if nulls == nil || !nulls[i] {
			g := gids[i]
			sums[g] += vals[i]
			cnt[g]++
		}
	})
}

func (s *floatSumState) merge(g int32, src aggState, sg int32) {
	o := src.(*floatSumState)
	s.sums[g] += o.sums[sg]
	s.n[g] += o.n[sg]
}

func (s *floatSumState) result(g int) (types.Value, error) {
	if s.n[g] == 0 {
		return null, nil
	}
	r := s.sums[g]
	if s.avg {
		r /= float64(s.n[g])
		if math.IsInf(r, 0) || math.IsNaN(r) {
			return null, errs.New(errs.NumericOverflow, "AVG is not finite")
		}
		return types.FloatValue(r), nil
	}
	if math.IsInf(r, 0) || math.IsNaN(r) {
		return null, errs.New(errs.NumericOverflow, "SUM is not finite")
	}
	return types.FloatValue(r), nil
}

// intMinMax is MIN/MAX over int-class values.
type intMinMax struct {
	sign int
	best []int64
	any  []bool
}

func (s *intMinMax) grow(g int) {
	s.best = growZero(s.best, g)
	s.any = growZero(s.any, g)
}

func (s *intMinMax) update(gids []int32, n int, sel []int32, v *Vec) {
	best, any, vals, nulls := s.best, s.any, v.I, v.Nulls
	lt := s.sign < 0
	forActive(n, sel, func(i int) {
		if nulls != nil && nulls[i] {
			return
		}
		g := gids[i]
		x := vals[i]
		if !any[g] || (lt && x < best[g]) || (!lt && x > best[g]) {
			best[g], any[g] = x, true
		}
	})
}

func (s *intMinMax) merge(g int32, src aggState, sg int32) {
	o := src.(*intMinMax)
	if !o.any[sg] {
		return
	}
	x := o.best[sg]
	if !s.any[g] || (s.sign < 0 && x < s.best[g]) || (s.sign > 0 && x > s.best[g]) {
		s.best[g], s.any[g] = x, true
	}
}

func (s *intMinMax) result(g int) (types.Value, error) {
	if !s.any[g] {
		return null, nil
	}
	return types.IntValue(s.best[g]), nil
}

// floatMinMax is MIN/MAX over FLOAT64.
type floatMinMax struct {
	sign int
	best []float64
	any  []bool
}

func (s *floatMinMax) grow(g int) {
	s.best = growZero(s.best, g)
	s.any = growZero(s.any, g)
}

func (s *floatMinMax) update(gids []int32, n int, sel []int32, v *Vec) {
	best, any, vals, nulls := s.best, s.any, v.F, v.Nulls
	lt := s.sign < 0
	forActive(n, sel, func(i int) {
		if nulls != nil && nulls[i] {
			return
		}
		g := gids[i]
		x := vals[i]
		if !any[g] || (lt && x < best[g]) || (!lt && x > best[g]) {
			best[g], any[g] = x, true
		}
	})
}

func (s *floatMinMax) merge(g int32, src aggState, sg int32) {
	o := src.(*floatMinMax)
	if !o.any[sg] {
		return
	}
	x := o.best[sg]
	if !s.any[g] || (s.sign < 0 && x < s.best[g]) || (s.sign > 0 && x > s.best[g]) {
		s.best[g], s.any[g] = x, true
	}
}

func (s *floatMinMax) result(g int) (types.Value, error) {
	if !s.any[g] {
		return null, nil
	}
	return types.FloatValue(s.best[g]), nil
}

// stringMinMax is MIN/MAX over STRING (byte order).
type stringMinMax struct {
	sign int
	best []string
	any  []bool
}

func (s *stringMinMax) grow(g int) {
	s.best = growZero(s.best, g)
	s.any = growZero(s.any, g)
}

func (s *stringMinMax) update(gids []int32, n int, sel []int32, v *Vec) {
	vals := v.strs(n)
	best, any, nulls := s.best, s.any, v.Nulls
	lt := s.sign < 0
	forActive(n, sel, func(i int) {
		if nulls != nil && nulls[i] {
			return
		}
		g := gids[i]
		x := vals[i]
		if !any[g] || (lt && x < best[g]) || (!lt && x > best[g]) {
			best[g], any[g] = x, true
		}
	})
}

func (s *stringMinMax) merge(g int32, src aggState, sg int32) {
	o := src.(*stringMinMax)
	if !o.any[sg] {
		return
	}
	x := o.best[sg]
	if !s.any[g] || (s.sign < 0 && x < s.best[g]) || (s.sign > 0 && x > s.best[g]) {
		s.best[g], s.any[g] = x, true
	}
}

func (s *stringMinMax) result(g int) (types.Value, error) {
	if !s.any[g] {
		return null, nil
	}
	return types.StringValue(s.best[g]), nil
}

// genericState keeps one row-mode accumulator per group (DISTINCT
// aggregates and other rare cases).
type genericState struct {
	call *plan.AggCall
	cls  vclass
	accs []accumulator
}

func (s *genericState) grow(g int) {
	for len(s.accs) < g {
		s.accs = append(s.accs, newAccumulator(s.call))
	}
}

func (s *genericState) update(gids []int32, n int, sel []int32, v *Vec) {
	forActive(n, sel, func(i int) {
		_ = s.accs[gids[i]].add(v.value(i, s.cls))
	})
}

func (s *genericState) merge(g int32, src aggState, sg int32) {
	s.accs[g].merge(src.(*genericState).accs[sg])
}

func (s *genericState) result(g int) (types.Value, error) { return s.accs[g].result() }

// ---------------------------------------------------------------- group table

// aggTable maps group keys to dense group IDs and holds the aggregate
// states. A table is used by one goroutine.
type aggTable struct {
	ec         *Context
	keyTypes   []types.Type
	keyClasses []vclass
	calls      []*plan.AggCall
	states     []aggState

	intMap    map[int64]int32
	floatMap  map[uint64]int32
	strMap    map[string]int32 // single STRING key, or encoded multi-column keys
	nullGroup int32            // group of the NULL key (single key)
	dict      []string         // dictionary of the code→group cache
	dictGids  []int32
	key       []byte

	keys  []types.Row // key values per group
	first []int64     // position of each group's first row (ordering)
	gids  []int32
}

func newAggTable(ec *Context, keyTypes []types.Type, calls []*plan.AggCall) *aggTable {
	t := &aggTable{ec: ec, keyTypes: keyTypes, calls: calls, nullGroup: -1,
		intMap: map[int64]int32{}, floatMap: map[uint64]int32{}, strMap: map[string]int32{}}
	for _, kt := range keyTypes {
		t.keyClasses = append(t.keyClasses, classOf(kt))
	}
	for _, c := range calls {
		t.states = append(t.states, newAggState(c))
	}
	return t
}

func (t *aggTable) groups() int { return len(t.keys) }

// newGroup creates a group with the given key values first seen at pos.
func (t *aggTable) newGroup(key types.Row, pos int64) (int32, error) {
	g := int32(len(t.keys))
	t.keys = append(t.keys, key)
	t.first = append(t.first, pos)
	for _, s := range t.states {
		s.grow(len(t.keys))
	}
	return g, t.ec.Mem.Reserve(RowSize(key) + int64(48*len(t.states)))
}

// keyRow extracts the key values of row i.
func (t *aggTable) keyRow(keys []*Vec, i int) types.Row {
	r := make(types.Row, len(keys))
	for k, v := range keys {
		r[k] = v.value(i, t.keyClasses[k])
	}
	return r
}

// resolve computes the group of every active row (creating groups). pos is
// the position of row 0 of the batch in the input (group ordering).
func (t *aggTable) resolve(keys []*Vec, n int, sel []int32, pos int64) error {
	t.gids = grow(t.gids, n)
	gids := t.gids
	if len(keys) == 0 {
		if len(t.keys) == 0 {
			if _, err := t.newGroup(types.Row{}, pos); err != nil {
				return err
			}
		}
		clear(gids)
		return nil
	}
	var err error
	lookup := func(i int, g int32, ok bool, put func(int32)) {
		if ok || err != nil {
			gids[i] = g
			return
		}
		g, err = t.newGroup(t.keyRow(keys, i), pos+int64(i))
		put(g)
		gids[i] = g
	}
	if len(keys) == 1 {
		v := keys[0]
		nulls := v.Nulls
		nullKey := func(i int) bool {
			if nulls == nil || !nulls[i] {
				return false
			}
			if t.nullGroup < 0 && err == nil {
				t.nullGroup, err = t.newGroup(types.Row{null}, pos+int64(i))
			}
			gids[i] = t.nullGroup
			return true
		}
		switch t.keyClasses[0] {
		case vInt:
			vals := v.I
			forActive(n, sel, func(i int) {
				if nullKey(i) {
					return
				}
				k := vals[i]
				g, ok := t.intMap[k]
				lookup(i, g, ok, func(g int32) { t.intMap[k] = g })
			})
		case vFloat:
			vals := v.F
			forActive(n, sel, func(i int) {
				if nullKey(i) {
					return
				}
				f := vals[i]
				if f == 0 {
					f = 0 // -0.0 groups with 0.0
				}
				k := math.Float64bits(f)
				g, ok := t.floatMap[k]
				lookup(i, g, ok, func(g int32) { t.floatMap[k] = g })
			})
		default:
			if v.Dict != nil {
				t.resolveDict(v, n, sel, pos, nullKey, &err)
				break
			}
			vals := v.S
			forActive(n, sel, func(i int) {
				if nullKey(i) {
					return
				}
				s := vals[i]
				g, ok := t.strMap[s]
				lookup(i, g, ok, func(g int32) { t.strMap[s] = g })
			})
		}
		return err
	}
	forActive(n, sel, func(i int) {
		t.key = t.key[:0]
		for k, v := range keys {
			t.key = appendKey(t.key, v.value(i, t.keyClasses[k]), t.keyTypes[k])
		}
		g, ok := t.strMap[string(t.key)]
		lookup(i, g, ok, func(g int32) { t.strMap[string(t.key)] = g })
	})
	return err
}

// resolveDict resolves a dictionary-encoded STRING key through a
// code→group cache kept per dictionary.
func (t *aggTable) resolveDict(v *Vec, n int, sel []int32, pos int64, nullKey func(int) bool, errp *error) {
	if !sameDict(t.dict, v.Dict) {
		t.dict = v.Dict
		t.dictGids = grow(t.dictGids, len(v.Dict))
		for i := range t.dictGids {
			t.dictGids[i] = -1
		}
	}
	cache, codes, gids := t.dictGids, v.Codes, t.gids
	forActive(n, sel, func(i int) {
		if nullKey(i) {
			return
		}
		c := codes[i]
		g := cache[c]
		if g < 0 {
			s := v.Dict[c]
			var ok bool
			if g, ok = t.strMap[s]; !ok {
				var err error
				if g, err = t.newGroup(types.Row{types.StringValue(s)}, pos+int64(i)); err != nil && *errp == nil {
					*errp = err
				}
				t.strMap[s] = g
			}
			cache[c] = g
		}
		gids[i] = g
	})
}

// update folds a batch into the table: keys and args are the evaluated key
// and argument vectors (args[i] nil for COUNT(*)).
func (t *aggTable) update(keys, args []*Vec, n int, sel []int32, pos int64) error {
	if err := t.resolve(keys, n, sel, pos); err != nil {
		return err
	}
	for i, s := range t.states {
		s.update(t.gids, n, sel, args[i])
	}
	return nil
}

// mergeFrom folds all groups of o into t.
func (t *aggTable) mergeFrom(o *aggTable) error {
	for sg, key := range o.keys {
		t.key = t.key[:0]
		for k, v := range key {
			t.key = appendKey(t.key, v, t.keyTypes[k])
		}
		g, ok := t.strMap[string(t.key)]
		if !ok {
			var err error
			if g, err = t.newGroup(key, o.first[sg]); err != nil {
				return err
			}
			t.strMap[string(t.key)] = g
		} else if o.first[sg] < t.first[g] {
			t.first[g] = o.first[sg]
		}
		for i, s := range t.states {
			s.merge(g, o.states[i], int32(sg))
		}
	}
	return nil
}

// rows computes the output rows (keys then aggregates) ordered by first
// appearance; without keys there is exactly one row.
func (t *aggTable) rows() ([]types.Row, error) {
	if len(t.keyTypes) == 0 && len(t.keys) == 0 {
		if _, err := t.newGroup(types.Row{}, 0); err != nil {
			return nil, err
		}
	}
	order := make([]int32, len(t.keys))
	for i := range order {
		order[i] = int32(i)
	}
	if !slices.IsSortedFunc(order, t.byFirst) {
		slices.SortFunc(order, t.byFirst)
	}
	out := make([]types.Row, len(order))
	width := len(t.keyTypes) + len(t.states)
	cells := make([]types.Value, len(order)*width)
	for i, g := range order {
		row := cells[i*width : (i+1)*width : (i+1)*width]
		copy(row, t.keys[g])
		for k, s := range t.states {
			v, err := s.result(int(g))
			if err != nil {
				return nil, err
			}
			row[len(t.keyTypes)+k] = v
		}
		out[i] = row
	}
	return out, nil
}

func (t *aggTable) byFirst(a, b int32) int {
	switch x, y := t.first[a], t.first[b]; {
	case x < y:
		return -1
	case x > y:
		return 1
	}
	return 0
}

// ---------------------------------------------------------------- operator

// vaggInput evaluates the key and argument expressions of an aggregation.
type vaggInput struct {
	exprs *exprSet // keys, then the arguments of non-COUNT(*) calls
	nkeys int
	argOf []int // per call: index into exprs, or -1 for COUNT(*)
	vals  []*Vec
	keys  []*Vec
	args  []*Vec
}

func newVAggInput(ec *Context, x *physical.HashAggregate) (*vaggInput, error) {
	in := &vaggInput{nkeys: len(x.Keys)}
	exprs := append([]plan.Expr(nil), x.Keys...)
	for _, c := range x.Aggs {
		if c.Arg == nil {
			in.argOf = append(in.argOf, -1)
			continue
		}
		in.argOf = append(in.argOf, len(exprs))
		exprs = append(exprs, c.Arg)
	}
	var err error
	if in.exprs, err = newExprSet(ec, x.Input.Schema(), exprs); err != nil {
		return nil, err
	}
	in.vals = make([]*Vec, len(exprs))
	in.args = make([]*Vec, len(x.Aggs))
	return in, nil
}

// fold evaluates a batch and folds it into t; on a vectorized failure the
// batch is evaluated row by row to report the first row's error.
func (in *vaggInput) fold(t *aggTable, b *Batch, pos int64) error {
	if err := in.exprs.eval(b, b.Sel, in.vals); err != nil {
		if rowErr := in.exprs.firstError(b); rowErr != nil {
			return rowErr
		}
		return errs.New(errs.InternalError, "vectorized aggregation failed: %v", err)
	}
	in.keys = in.vals[:in.nkeys]
	for i, a := range in.argOf {
		if a >= 0 {
			in.args[i] = in.vals[a]
		} else {
			in.args[i] = nil
		}
	}
	return t.update(in.keys, in.args, b.N, b.Sel, pos)
}

// vaggregateOp is a (serial) vectorized hash aggregation.
type vaggregateOp struct {
	ec    *Context
	node  *physical.HashAggregate
	input BatchOperator
	in    *vaggInput
	out   BatchOperator
}

func buildVAggregate(ec *Context, x *physical.HashAggregate) (BatchOperator, error) {
	if op, ok, err := parallelAggregate(ec, x, true); ok || err != nil {
		return op, err
	}
	input, err := BuildBatch(ec, x.Input)
	if err != nil {
		return nil, err
	}
	in, err := newVAggInput(ec, x)
	if err != nil {
		return nil, err
	}
	return &vaggregateOp{ec: ec, node: x, input: input, in: in}, nil
}

func (a *vaggregateOp) NextBatch() (*Batch, error) {
	if a.out == nil {
		rows, err := a.run()
		if err != nil {
			return nil, err
		}
		a.out = newBatchWriter(&replayOp{rows: rows}, schemaTypes(a.node.Schema()))
	}
	return a.out.NextBatch()
}

func (a *vaggregateOp) run() ([]types.Row, error) {
	t := newAggTable(a.ec, exprTypes(a.node.Keys), a.node.Aggs)
	var pos int64
	for {
		b, err := a.input.NextBatch()
		if err != nil {
			return nil, err
		}
		if b == nil {
			break
		}
		if err := a.ec.Check(); err != nil {
			return nil, err
		}
		if err := a.in.fold(t, b, pos); err != nil {
			return nil, err
		}
		pos += int64(b.N)
	}
	return t.rows()
}
