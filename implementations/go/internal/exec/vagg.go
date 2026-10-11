package exec

import (
	"hash/maphash"
	"math"
	"slices"
	"sync"

	"polyquery/internal/errs"
	"polyquery/internal/native"
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
	switch {
	case call.Func == plan.AggCount:
		return &countState{}
	case t.IsWide():
		// SUM/AVG/MIN/MAX of wide DECIMALs use the row accumulators
		// (128-bit sums, exact comparisons).
		return &genericState{call: call, cls: classOf(t)}
	}
	switch call.Func {
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
// With native kernels, batches are first added to int64 partial sums
// (fast) by pqk_group_sum_i64; a group's sum is sums[g] + fast[g].
type exactSumState struct {
	sums  []types.BigDecimalSum
	n     []int64
	limit int64 // DECIMAL SUM: exclusive bound of the result
	avg   bool
	scale int

	lib  *native.Lib
	fast []int64
	mask []byte
}

func (s *exactSumState) grow(g int) {
	s.sums = growZero(s.sums, g)
	s.n = growZero(s.n, g)
	if s.lib != nil {
		s.fast = growZero(s.fast, g)
	}
}

func (s *exactSumState) update(gids []int32, n int, sel []int32, v *Vec) {
	if s.lib != nil && n > 0 && s.nativeUpdate(gids, n, sel, v) {
		return
	}
	sums, cnt, vals, nulls := s.sums, s.n, v.I, v.Nulls
	add := func(g int32, x int64) {
		if p := &sums[g]; !p.AddSmall(x) {
			p.Add(x)
		}
		cnt[g]++
	}
	switch {
	case sel == nil && nulls == nil:
		for i, g := range gids[:n] {
			add(g, vals[i])
		}
	case sel == nil:
		for i, g := range gids[:n] {
			if !nulls[i] {
				add(g, vals[i])
			}
		}
	case nulls == nil:
		for _, i := range sel {
			add(gids[i], vals[i])
		}
	default:
		for _, i := range sel {
			if !nulls[i] {
				add(gids[i], vals[i])
			}
		}
	}
}

// nativeUpdate adds a batch with pqk_group_sum_i64 into the fast sums and
// the counts. If the kernel reports a possible overflow the batch is
// subtracted again (wrapping arithmetic is exactly invertible) and false
// is returned: the caller then adds the batch exactly.
func (s *exactSumState) nativeUpdate(gids []int32, n int, sel []int32, v *Vec) bool {
	var valid []byte
	if sel != nil || v.Nulls != nil {
		s.mask = activeMask(s.mask, n, sel, v.Nulls)
		valid = s.mask
	}
	switch s.lib.GroupSumI64(asUint32(gids[:n]), v.I[:n], valid, s.fast, s.n) {
	case native.OK:
		return true
	case native.Overflow:
		for i, g := range gids[:n] {
			if valid == nil || valid[i>>3]&(1<<(i&7)) != 0 {
				s.fast[g] -= v.I[i]
				s.n[g]--
			}
		}
	}
	return false
}

// settle folds the fast partial sum of group g into its exact sum.
func (s *exactSumState) settle(g int) {
	if s.fast != nil && s.fast[g] != 0 {
		s.sums[g].Add(s.fast[g])
		s.fast[g] = 0
	}
}

func (s *exactSumState) merge(g int32, src aggState, sg int32) {
	o := src.(*exactSumState)
	s.sums[g].Merge(&o.sums[sg])
	if o.fast != nil {
		s.sums[g].Add(o.fast[sg])
	}
	s.n[g] += o.n[sg]
}

func (s *exactSumState) result(g int) (types.Value, error) {
	s.settle(g)
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
	switch {
	case sel == nil && nulls == nil:
		for i, g := range gids[:n] {
			sums[g] += vals[i]
			cnt[g]++
		}
	case sel == nil:
		for i, g := range gids[:n] {
			if !nulls[i] {
				sums[g] += vals[i]
				cnt[g]++
			}
		}
	default:
		for _, i := range sel {
			if nulls == nil || !nulls[i] {
				g := gids[i]
				sums[g] += vals[i]
				cnt[g]++
			}
		}
	}
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
	one := func(i int) {
		if nulls != nil && nulls[i] {
			return
		}
		g, x := gids[i], vals[i]
		if !any[g] || (lt && x < best[g]) || (!lt && x > best[g]) {
			best[g], any[g] = x, true
		}
	}
	if sel == nil {
		for i := 0; i < n; i++ {
			one(i)
		}
		return
	}
	for _, i := range sel {
		one(int(i))
	}
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
	one := func(i int) {
		if nulls != nil && nulls[i] {
			return
		}
		g, x := gids[i], vals[i]
		if !any[g] || (lt && x < best[g]) || (!lt && x > best[g]) {
			best[g], any[g] = x, true
		}
	}
	if sel == nil {
		for i := 0; i < n; i++ {
			one(i)
		}
		return
	}
	for _, i := range sel {
		one(int(i))
	}
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
	nmap      *nativeIntMap // replaces intMap with native kernels
	floatMap  map[uint64]int32
	strMap    map[string]int32 // single STRING key, or encoded multi-column keys
	nullGroup int32            // group of the NULL key (single key)
	dict      []string         // dictionary of the code→group cache
	dictGids  []int32
	key       []byte

	keys  []types.Row // key values per group
	first []int64     // position of each group's first row (ordering)
	gids  []int32

	slab       []types.Value // storage for key rows
	unreserved int64         // memory accounted but not yet reserved
}

func newAggTable(ec *Context, keyTypes []types.Type, calls []*plan.AggCall) *aggTable {
	t := &aggTable{ec: ec, keyTypes: keyTypes, calls: calls, nullGroup: -1,
		intMap: map[int64]int32{}, floatMap: map[uint64]int32{}, strMap: map[string]int32{}}
	for _, kt := range keyTypes {
		t.keyClasses = append(t.keyClasses, classOf(kt))
	}
	for _, c := range calls {
		st := newAggState(c)
		if s, ok := st.(*exactSumState); ok {
			s.lib = ec.Native
		}
		t.states = append(t.states, st)
	}
	if ec.Native != nil && len(keyTypes) == 1 && t.keyClasses[0] == vInt {
		t.nmap = newNativeIntMap(ec.Native)
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
	// Reservations are batched: the budget is shared (atomically) by
	// parallel workers.
	t.unreserved += RowSize(key) + int64(48*len(t.states))
	if t.unreserved >= reserveChunk {
		n := t.unreserved
		t.unreserved = 0
		return g, t.ec.Mem.Reserve(n)
	}
	return g, nil
}

// reserveChunk is the amount of memory a table accounts locally before
// reserving it from the query budget.
const reserveChunk = 64 << 10

// flushReservation reserves the locally accounted memory.
func (t *aggTable) flushReservation() error {
	n := t.unreserved
	t.unreserved = 0
	return t.ec.Mem.Reserve(n)
}

// newKey returns a key row of n values carved from a slab.
func (t *aggTable) newKey(n int) types.Row {
	if len(t.slab) < n {
		t.slab = make([]types.Value, max(256*n, n))
	}
	r := t.slab[:n:n]
	t.slab = t.slab[n:]
	return r
}

// key1 returns a single-value key row.
func (t *aggTable) key1(v types.Value) types.Row {
	r := t.newKey(1)
	r[0] = v
	return r
}

// keyRow extracts the key values of row i.
func (t *aggTable) keyRow(keys []*Vec, i int) types.Row {
	r := t.newKey(len(keys))
	for k, v := range keys {
		r[k] = v.value(i, t.keyClasses[k])
	}
	return r
}

// resolve computes the group of every active row (creating groups). pos is
// the position of row 0 of the batch in the input (group ordering).
func (t *aggTable) resolve(keys []*Vec, n int, sel []int32, pos int64) error {
	t.gids = grow(t.gids, n)
	if len(keys) == 0 {
		if len(t.keys) == 0 {
			if _, err := t.newGroup(types.Row{}, pos); err != nil {
				return err
			}
		}
		clear(t.gids)
		return nil
	}
	if len(keys) > 1 {
		return t.resolveEncoded(keys, n, sel, pos)
	}
	v := keys[0]
	switch {
	case t.keyClasses[0] == vInt:
		return t.resolveInt(v, n, sel, pos)
	case t.keyClasses[0] == vFloat || t.keyClasses[0] == vWide:
		return t.resolveEncoded(keys, n, sel, pos)
	case v.Dict != nil:
		return t.resolveDict(v, n, sel, pos)
	}
	return t.resolveString(v, n, sel, pos)
}

// nullKey returns the group of the NULL key (single key), creating it.
func (t *aggTable) nullKey(pos int64) (int32, error) {
	if t.nullGroup >= 0 {
		return t.nullGroup, nil
	}
	g, err := t.newGroup(types.Row{null}, pos)
	t.nullGroup = g
	return g, err
}

func (t *aggTable) resolveInt(v *Vec, n int, sel []int32, pos int64) error {
	if t.nmap != nil {
		return t.resolveIntNative(v, n, sel, pos)
	}
	gids, vals, nulls := t.gids, v.I, v.Nulls
	one := func(i int) error {
		if nulls != nil && nulls[i] {
			g, err := t.nullKey(pos + int64(i))
			gids[i] = g
			return err
		}
		k := vals[i]
		g, ok := t.intMap[k]
		if !ok {
			var err error
			if g, err = t.newGroup(t.key1(types.IntValue(k)), pos+int64(i)); err != nil {
				return err
			}
			t.intMap[k] = g
		}
		gids[i] = g
		return nil
	}
	if sel == nil {
		for i := 0; i < n; i++ {
			if err := one(i); err != nil {
				return err
			}
		}
		return nil
	}
	for _, i := range sel {
		if err := one(int(i)); err != nil {
			return err
		}
	}
	return nil
}

// resolveIntNative is resolveInt with keys hashed by pqk_hash_i64.
func (t *aggTable) resolveIntNative(v *Vec, n int, sel []int32, pos int64) error {
	gids, vals, nulls, m := t.gids, v.I, v.Nulls, t.nmap
	hashes := m.hashBatch(vals[:n])
	one := func(i int) error {
		if nulls != nil && nulls[i] {
			g, err := t.nullKey(pos + int64(i))
			gids[i] = g
			return err
		}
		k, h := vals[i], hashes[i]
		g, ok := m.get(k, h)
		if !ok {
			var err error
			if g, err = t.newGroup(t.key1(types.IntValue(k)), pos+int64(i)); err != nil {
				return err
			}
			m.put(k, h, g)
		}
		gids[i] = g
		return nil
	}
	if sel == nil {
		for i := 0; i < n; i++ {
			if err := one(i); err != nil {
				return err
			}
		}
		return nil
	}
	for _, i := range sel {
		if err := one(int(i)); err != nil {
			return err
		}
	}
	return nil
}

func (t *aggTable) resolveString(v *Vec, n int, sel []int32, pos int64) error {
	gids, vals, nulls := t.gids, v.S, v.Nulls
	one := func(i int) error {
		if nulls != nil && nulls[i] {
			g, err := t.nullKey(pos + int64(i))
			gids[i] = g
			return err
		}
		s := vals[i]
		g, ok := t.strMap[s]
		if !ok {
			var err error
			if g, err = t.newGroup(t.key1(types.StringValue(s)), pos+int64(i)); err != nil {
				return err
			}
			t.strMap[s] = g
		}
		gids[i] = g
		return nil
	}
	if sel == nil {
		for i := 0; i < n; i++ {
			if err := one(i); err != nil {
				return err
			}
		}
		return nil
	}
	for _, i := range sel {
		if err := one(int(i)); err != nil {
			return err
		}
	}
	return nil
}

// resolveDict resolves a dictionary-encoded STRING key through a
// code→group cache kept per dictionary.
func (t *aggTable) resolveDict(v *Vec, n int, sel []int32, pos int64) error {
	if !sameDict(t.dict, v.Dict) {
		t.dict = v.Dict
		t.dictGids = grow(t.dictGids, len(v.Dict))
		for i := range t.dictGids {
			t.dictGids[i] = -1
		}
	}
	cache, codes, gids, nulls := t.dictGids, v.Codes, t.gids, v.Nulls
	slow := func(i int) error {
		if nulls != nil && nulls[i] {
			g, err := t.nullKey(pos + int64(i))
			gids[i] = g
			return err
		}
		c := codes[i]
		s := v.Dict[c]
		g, ok := t.strMap[s]
		if !ok {
			var err error
			if g, err = t.newGroup(t.key1(types.StringValue(s)), pos+int64(i)); err != nil {
				return err
			}
			t.strMap[s] = g
		}
		cache[c] = g
		gids[i] = g
		return nil
	}
	if sel == nil {
		for i, c := range codes[:n] {
			if g := cache[c]; g >= 0 && (nulls == nil || !nulls[i]) {
				gids[i] = g
			} else if err := slow(i); err != nil {
				return err
			}
		}
		return nil
	}
	for _, i := range sel {
		if g := cache[codes[i]]; g >= 0 && (nulls == nil || !nulls[i]) {
			gids[i] = g
		} else if err := slow(int(i)); err != nil {
			return err
		}
	}
	return nil
}

// resolveEncoded resolves multi-column (and FLOAT64) keys by their
// canonical encoding.
func (t *aggTable) resolveEncoded(keys []*Vec, n int, sel []int32, pos int64) error {
	gids := t.gids
	one := func(i int) error {
		t.key = t.key[:0]
		for k, v := range keys {
			t.key = appendKey(t.key, v.value(i, t.keyClasses[k]), t.keyTypes[k])
		}
		if len(keys) == 1 && t.key[0] == 0 {
			g, err := t.nullKey(pos + int64(i))
			gids[i] = g
			return err
		}
		g, ok := t.strMap[string(t.key)]
		if !ok {
			var err error
			if g, err = t.newGroup(t.keyRow(keys, i), pos+int64(i)); err != nil {
				return err
			}
			t.strMap[string(t.key)] = g
		}
		gids[i] = g
		return nil
	}
	if sel == nil {
		for i := 0; i < n; i++ {
			if err := one(i); err != nil {
				return err
			}
		}
		return nil
	}
	for _, i := range sel {
		if err := one(int(i)); err != nil {
			return err
		}
	}
	return nil
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

// findOrAdd returns the group of a key (created at position pos if new;
// otherwise its first position is lowered to pos if earlier).
func (t *aggTable) findOrAdd(key types.Row, pos int64) (int32, error) {
	var g int32
	var ok bool
	var put func(int32)
	// Single wide keys are encoded like multi-column keys (the NULL key
	// has its own group, as in resolveEncoded).
	if len(key) == 1 && (t.keyClasses[0] != vWide || key[0].Null) {
		v := key[0]
		switch {
		case v.Null:
			g, ok = t.nullGroup, t.nullGroup >= 0
			put = func(g int32) { t.nullGroup = g }
		case t.keyClasses[0] == vInt && t.nmap != nil:
			h := fmix64(v.I)
			g, ok = t.nmap.get(v.I, h)
			put = func(g int32) { t.nmap.put(v.I, h, g) }
		case t.keyClasses[0] == vInt:
			g, ok = t.intMap[v.I]
			put = func(g int32) { t.intMap[v.I] = g }
		case t.keyClasses[0] == vFloat:
			f := v.F
			if f == 0 {
				f = 0
			}
			k := math.Float64bits(f)
			g, ok = t.floatMap[k]
			put = func(g int32) { t.floatMap[k] = g }
		default:
			g, ok = t.strMap[v.S]
			put = func(g int32) { t.strMap[v.S] = g }
		}
	} else {
		t.key = t.key[:0]
		for k, v := range key {
			t.key = appendKey(t.key, v, t.keyTypes[k])
		}
		g, ok = t.strMap[string(t.key)]
		k := string(t.key)
		put = func(g int32) { t.strMap[k] = g }
	}
	if ok {
		if pos < t.first[g] {
			t.first[g] = pos
		}
		return g, nil
	}
	g, err := t.newGroup(key, pos)
	put(g)
	return g, err
}

// mergeFrom folds the groups of o for which take(group) holds (nil: all)
// into t.
func (t *aggTable) mergeFrom(o *aggTable, take func(int) bool) error {
	for sg, key := range o.keys {
		if take != nil && !take(sg) {
			continue
		}
		g, err := t.findOrAdd(key, o.first[sg])
		if err != nil {
			return err
		}
		for i, s := range t.states {
			s.merge(g, o.states[i], int32(sg))
		}
	}
	return nil
}

// keyHashes hashes the key of every group (merge partitioning).
func (t *aggTable) keyHashes(seed maphash.Seed) []uint64 {
	out := make([]uint64, len(t.keys))
	var buf []byte
	for g, key := range t.keys {
		if len(key) == 1 && !key[0].Null && t.keyClasses[0] == vInt {
			out[g] = uint64(key[0].I) * 0x9E3779B97F4A7C15
			continue
		}
		buf = buf[:0]
		for k, v := range key {
			buf = appendKey(buf, v, t.keyTypes[k])
		}
		out[g] = maphash.Bytes(seed, buf)
	}
	return out
}

// results computes the output rows of all groups (keys then aggregates)
// with their first positions. If results fail, err is the failure of the
// group that appears first (as in serial execution) and errPos its
// position.
func (t *aggTable) results() (rows []types.Row, first []int64, errPos int64, err error) {
	if err := t.flushReservation(); err != nil {
		return nil, nil, math.MinInt64, err
	}
	width := len(t.keyTypes) + len(t.states)
	cells := make([]types.Value, len(t.keys)*width)
	rows = make([]types.Row, len(t.keys))
	errPos = math.MaxInt64
	for g := range t.keys {
		row := cells[g*width : (g+1)*width : (g+1)*width]
		copy(row, t.keys[g])
		for k, s := range t.states {
			v, e := s.result(g)
			if e != nil {
				if t.first[g] < errPos {
					errPos, err = t.first[g], e
				}
				break
			}
			row[len(t.keyTypes)+k] = v
		}
		rows[g] = row
	}
	return rows, t.first, errPos, err
}

// rows computes the output rows (keys then aggregates) ordered by first
// appearance; without keys there is exactly one row.
func (t *aggTable) rows() ([]types.Row, error) {
	if len(t.keyTypes) == 0 && len(t.keys) == 0 {
		if _, err := t.newGroup(types.Row{}, 0); err != nil {
			return nil, err
		}
	}
	rows, first, _, err := t.results()
	if err != nil {
		return nil, err
	}
	return orderByFirst(rows, first), nil
}

// orderByFirst sorts rows by their first positions (which it reorders
// accordingly).
func orderByFirst(rows []types.Row, first []int64) []types.Row {
	order := make([]int32, len(rows))
	for i := range order {
		order[i] = int32(i)
	}
	cmp := func(a, b int32) int {
		switch x, y := first[a], first[b]; {
		case x < y:
			return -1
		case x > y:
			return 1
		}
		return 0
	}
	if slices.IsSortedFunc(order, cmp) {
		return rows
	}
	slices.SortFunc(order, cmp)
	out := make([]types.Row, len(rows))
	firsts := make([]int64, len(rows))
	for i, g := range order {
		out[i], firsts[i] = rows[g], first[g]
	}
	copy(first, firsts)
	return out
}

// mergeByFirst merges row lists that are each ordered by first position.
func mergeByFirst(rows [][]types.Row, first [][]int64) []types.Row {
	total := 0
	for _, r := range rows {
		total += len(r)
	}
	out := make([]types.Row, 0, total)
	pos := make([]int, len(rows))
	for len(out) < total {
		best := -1
		for p := range rows {
			if pos[p] < len(rows[p]) && (best < 0 || first[p][pos[p]] < first[best][pos[best]]) {
				best = p
			}
		}
		out = append(out, rows[best][pos[best]])
		pos[best]++
	}
	return out
}

// minPartitionedMerge is the number of partial groups from which partial
// tables are merged by several goroutines.
const minPartitionedMerge = 1 << 13

// mergeTables merges the partial tables of parallel workers and returns
// the result rows in first-appearance order. Large merges are partitioned
// by key hash: partition p of every partial table is merged into final
// table p by its own goroutine.
func mergeTables(ec *Context, tables []*aggTable, keyTypes []types.Type, calls []*plan.AggCall) ([]types.Row, error) {
	total := 0
	for _, t := range tables {
		total += t.groups()
	}
	parts := min(ec.Threads, len(tables))
	if parts <= 1 || total < minPartitionedMerge || len(keyTypes) == 0 {
		final := newAggTable(ec, keyTypes, calls)
		for _, t := range tables {
			if err := final.mergeFrom(t, nil); err != nil {
				return nil, err
			}
		}
		return final.rows()
	}
	seed := maphash.MakeSeed()
	hashes := make([][]uint64, len(tables))
	var wg sync.WaitGroup
	for i, t := range tables {
		wg.Add(1)
		go func() {
			defer wg.Done()
			hashes[i] = t.keyHashes(seed)
		}()
	}
	wg.Wait()
	type partResult struct {
		rows   []types.Row
		first  []int64
		errPos int64
		err    error
	}
	results := make([]partResult, parts)
	for p := 0; p < parts; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			final := newAggTable(ec, keyTypes, calls)
			for i, t := range tables {
				h := hashes[i]
				if err := final.mergeFrom(t, func(g int) bool { return int(h[g]%uint64(parts)) == p }); err != nil {
					results[p] = partResult{errPos: math.MinInt64, err: err}
					return
				}
			}
			r := &results[p]
			r.rows, r.first, r.errPos, r.err = final.results()
			if r.err == nil {
				r.rows = orderByFirst(r.rows, r.first)
			}
		}()
	}
	wg.Wait()
	var err error
	errPos := int64(math.MaxInt64)
	rows := make([][]types.Row, parts)
	first := make([][]int64, parts)
	for p, r := range results {
		if r.err != nil && r.errPos < errPos {
			errPos, err = r.errPos, r.err
		}
		rows[p], first[p] = r.rows, r.first
	}
	if err != nil {
		return nil, err
	}
	return mergeByFirst(rows, first), nil
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
	if p, ok := planNativeAggregate(ec, x); ok {
		return &nativeAggOp{ec: ec, p: p}, nil
	}
	if op, ok, err := parallelAggregate(ec, x); ok || err != nil {
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
