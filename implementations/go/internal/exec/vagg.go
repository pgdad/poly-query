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
		if distinctArg(t) {
			return newDistinctState(call)
		}
		return &genericState{call: call, cls: classOf(t)}
	}
	switch {
	case call.Func == plan.AggCount:
		return &countState{}
	case t.IsWide():
		switch call.Func {
		case plan.AggSum, plan.AggAvg:
			return &wideSumState{avg: call.Func == plan.AggAvg, scale: t.Scale}
		case plan.AggMin:
			return &wideMinMax{sign: -1}
		}
		return &wideMinMax{sign: 1}
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

// exactSumState is SUM/AVG over INT64 or DECIMAL: exact sums. A group's
// sum is kept in an int64 (small); when adding to it would overflow, the
// int64 part moves to an unbounded spill sum, so the sum is spill[g] +
// small[g]. With native kernels, batches are first added to int64 partial
// sums (fast) by pqk_group_sum_i64; they are settled into the exact sum
// at the end.
type exactSumState struct {
	small []int64
	spill map[int32]*types.BigDecimalSum
	n     []int64
	limit int64 // DECIMAL SUM: exclusive bound of the result
	avg   bool
	scale int

	lib  *native.Lib
	fast []int64
	mask []byte
}

func (s *exactSumState) grow(g int) {
	s.small = growZero(s.small, g)
	s.n = growZero(s.n, g)
	if s.lib != nil {
		s.fast = growZero(s.fast, g)
	}
}

// add adds x to the sum of group g.
func (s *exactSumState) add(g int32, x int64) {
	c := s.small[g] + x
	if (c > s.small[g]) == (x > 0) {
		s.small[g] = c
		return
	}
	s.spillAdd(g, s.small[g])
	s.small[g] = x
}

// spillAdd adds x to the spill sum of group g.
func (s *exactSumState) spillAdd(g int32, x int64) {
	b := s.spill[g]
	if b == nil {
		if s.spill == nil {
			s.spill = map[int32]*types.BigDecimalSum{}
		}
		b = &types.BigDecimalSum{}
		s.spill[g] = b
	}
	b.Add(x)
}

func (s *exactSumState) update(gids []int32, n int, sel []int32, v *Vec) {
	if s.lib != nil && n > 0 && s.nativeUpdate(gids, n, sel, v) {
		return
	}
	sums, cnt, vals, nulls := s.small, s.n, v.I, v.Nulls
	add := func(g int32, x int64) {
		if c := sums[g] + x; (c > sums[g]) == (x > 0) {
			sums[g] = c
		} else {
			s.add(g, x)
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
func (s *exactSumState) settle(g int32) {
	if s.fast != nil && s.fast[g] != 0 {
		s.add(g, s.fast[g])
		s.fast[g] = 0
	}
}

func (s *exactSumState) merge(g int32, src aggState, sg int32) {
	o := src.(*exactSumState)
	s.add(g, o.small[sg])
	if o.fast != nil {
		s.add(g, o.fast[sg])
	}
	if b := o.spill[sg]; b != nil {
		s.spillAdd(g, 0)
		s.spill[g].Merge(b)
	}
	s.n[g] += o.n[sg]
}

// total returns the exact sum of group g.
func (s *exactSumState) total(g int32) types.BigDecimalSum {
	var t types.BigDecimalSum
	if b := s.spill[g]; b != nil {
		t.Merge(b)
	}
	t.Add(s.small[g])
	return t
}

func (s *exactSumState) result(g int) (types.Value, error) {
	s.settle(int32(g))
	if s.n[g] == 0 {
		return null, nil
	}
	if s.spill[int32(g)] == nil {
		v := s.small[g]
		if s.avg {
			return types.FloatValue(types.RatioFloat64(v, s.n[g], s.scale)), nil
		}
		if s.limit > 0 && (v <= -s.limit || v >= s.limit) {
			return null, errs.New(errs.NumericOverflow, "SUM overflow")
		}
		return types.IntValue(v), nil
	}
	t := s.total(int32(g))
	if s.avg {
		return types.FloatValue(t.RatioFloat(s.n[g], s.scale)), nil
	}
	v, ok := t.Int64()
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

	imap      *intGroupMap           // single INT-class key
	wideMap   map[types.Int128]int32 // single wide DECIMAL key
	nmap      *nativeIntMap          // replaces imap with native kernels
	smap      *strGroupMap           // single STRING key
	hashes    []uint64               // per group: hash of its single STRING key
	strMap    map[string]int32       // encoded multi-column (and FLOAT64) keys
	nullGroup int32                  // group of the NULL key (single key)
	dict      []string               // dictionary of the code→group cache
	dictGids  []int32
	key       []byte

	keys  []types.Row // key values per group
	first []int64     // position of each group's first row (ordering)
	gids  []int32
	// rowPos, if set, holds the positions of the rows of the batch being
	// folded (partitioned aggregation, whose batches gather rows from
	// anywhere in the input); else row i of a batch at pos is at pos+i.
	rowPos []int64
	// rowHash, if set, holds the strKeyHash of each row's single STRING key
	// (computed when the rows were partitioned).
	rowHash []uint64

	slab       []types.Value // storage for key rows
	unreserved int64         // memory accounted but not yet reserved
}

func newAggTable(ec *Context, keyTypes []types.Type, calls []*plan.AggCall) *aggTable {
	t := &aggTable{ec: ec, keyTypes: keyTypes, calls: calls, nullGroup: -1,
		imap: newIntGroupMap(), smap: newStrGroupMap(),
		wideMap: map[types.Int128]int32{}, strMap: map[string]int32{}}
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
	case t.keyClasses[0] == vWide:
		return t.resolveWide(v, n, sel, pos)
	case t.keyClasses[0] == vFloat:
		return t.resolveEncoded(keys, n, sel, pos)
	case v.Dict != nil:
		return t.resolveDict(v, n, sel, pos)
	}
	return t.resolveString(v, n, sel, pos)
}

// posAt returns the input position of row i of a batch at pos.
func (t *aggTable) posAt(pos int64, i int) int64 {
	if t.rowPos != nil {
		return t.rowPos[i]
	}
	return pos + int64(i)
}

// strHashAt returns the strKeyHash of s, the single STRING key of row i.
func (t *aggTable) strHashAt(s string, i int) uint64 {
	if t.rowHash != nil {
		return t.rowHash[i]
	}
	return strKeyHash(s)
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
			g, err := t.nullKey(t.posAt(pos, i))
			gids[i] = g
			return err
		}
		k := vals[i]
		g, slot, ok := t.imap.find(k)
		if !ok {
			var err error
			if g, err = t.newGroup(t.key1(types.IntValue(k)), t.posAt(pos, i)); err != nil {
				return err
			}
			t.imap.insert(slot, k, g)
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
			g, err := t.nullKey(t.posAt(pos, i))
			gids[i] = g
			return err
		}
		k, h := vals[i], hashes[i]
		g, ok := m.get(k, h)
		if !ok {
			var err error
			if g, err = t.newGroup(t.key1(types.IntValue(k)), t.posAt(pos, i)); err != nil {
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
			g, err := t.nullKey(t.posAt(pos, i))
			gids[i] = g
			return err
		}
		g, err := t.findOrAddStr(vals[i], t.strHashAt(vals[i], i), t.posAt(pos, i))
		gids[i] = g
		return err
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
			g, err := t.nullKey(t.posAt(pos, i))
			gids[i] = g
			return err
		}
		c := codes[i]
		g, err := t.findOrAddStr(v.Dict[c], strKeyHash(v.Dict[c]), t.posAt(pos, i))
		if err != nil {
			return err
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
			g, err := t.nullKey(t.posAt(pos, i))
			gids[i] = g
			return err
		}
		g, ok := t.strMap[string(t.key)]
		if !ok {
			var err error
			if g, err = t.newGroup(t.keyRow(keys, i), t.posAt(pos, i)); err != nil {
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
	if t.rowPos != nil {
		// Rows do not arrive in input order: an existing group may first
		// appear at an earlier row.
		forActive(n, sel, func(i int) {
			if g := t.gids[i]; t.rowPos[i] < t.first[g] {
				t.first[g] = t.rowPos[i]
			}
		})
	}
	for i, s := range t.states {
		s.update(t.gids, n, sel, args[i])
	}
	return nil
}

// findOrAdd returns the group of a key (created at position pos if new;
// otherwise its first position is lowered to pos if earlier). Keys are
// looked up in the same maps as resolve uses.
func (t *aggTable) findOrAdd(key types.Row, pos int64) (int32, error) {
	if len(key) == 1 && (key[0].Null || t.keyClasses[0] != vFloat) {
		v := key[0]
		switch {
		case v.Null:
			if t.nullGroup >= 0 {
				return t.found(t.nullGroup, pos), nil
			}
			g, err := t.newGroup(key, pos)
			t.nullGroup = g
			return g, err
		case t.keyClasses[0] == vInt && t.nmap != nil:
			h := fmix64(v.I)
			if g, ok := t.nmap.get(v.I, h); ok {
				return t.found(g, pos), nil
			}
			g, err := t.newGroup(key, pos)
			t.nmap.put(v.I, h, g)
			return g, err
		case t.keyClasses[0] == vInt:
			g, slot, ok := t.imap.find(v.I)
			if ok {
				return t.found(g, pos), nil
			}
			g, err := t.newGroup(key, pos)
			t.imap.insert(slot, v.I, g)
			return g, err
		case t.keyClasses[0] == vWide:
			if g, ok := t.wideMap[v.Wide()]; ok {
				return t.found(g, pos), nil
			}
			g, err := t.newGroup(key, pos)
			t.wideMap[v.Wide()] = g
			return g, err
		}
		return t.findOrAddStr(v.S, strKeyHash(v.S), pos)
	}
	// Several keys, or a FLOAT64 key: canonical encoding (resolveEncoded).
	t.key = t.key[:0]
	for k, v := range key {
		t.key = appendKey(t.key, v, t.keyTypes[k])
	}
	if g, ok := t.strMap[string(t.key)]; ok {
		return t.found(g, pos), nil
	}
	k := string(t.key)
	g, err := t.newGroup(key, pos)
	t.strMap[k] = g
	return g, err
}

// found returns the existing group g, lowering its first position to pos
// if earlier.
func (t *aggTable) found(g int32, pos int64) int32 {
	if pos < t.first[g] {
		t.first[g] = pos
	}
	return g
}

// findOrAddStr is findOrAdd for a non-NULL single STRING key s with hash h.
func (t *aggTable) findOrAddStr(s string, h uint64, pos int64) (int32, error) {
	g, slot, ok := t.smap.find(s, h)
	if ok {
		if pos < t.first[g] {
			t.first[g] = pos
		}
		return g, nil
	}
	g, err := t.newGroup(t.key1(types.StringValue(s)), pos)
	t.smap.insert(slot, s, h, g)
	t.hashes = growZero(t.hashes, int(g)+1)
	t.hashes[g] = h
	return g, err
}

// mergeFrom folds the groups of o into t.
func (t *aggTable) mergeFrom(o *aggTable) error {
	for sg := range o.keys {
		if err := t.mergeGroup(o, int32(sg)); err != nil {
			return err
		}
	}
	return nil
}

// mergeGroup folds group sg of o into t.
func (t *aggTable) mergeGroup(o *aggTable, sg int32) error {
	key := o.keys[sg]
	var g int32
	var err error
	if len(key) == 1 && !key[0].Null && t.keyClasses[0] == vStr {
		g, err = t.findOrAddStr(key[0].S, o.hashes[sg], o.first[sg])
	} else {
		g, err = t.findOrAdd(key, o.first[sg])
	}
	if err != nil {
		return err
	}
	for i, s := range t.states {
		s.merge(g, o.states[i], sg)
	}
	return nil
}

// mergeWork estimates the cost of merging t: its groups plus the values
// of its DISTINCT aggregates.
func (t *aggTable) mergeWork() int {
	n := t.groups()
	for _, s := range t.states {
		if d, ok := s.(*distinctState); ok {
			n += len(d.gids)
		}
	}
	return n
}

// partitionGroups splits the groups of t by key hash into parts lists
// (merge partitioning, see groupPartHash).
func (t *aggTable) partitionGroups(seed maphash.Seed, parts int) [][]int32 {
	out := make([][]int32, parts)
	for p := range out {
		out[p] = make([]int32, 0, len(t.keys)/parts+len(t.keys)/(4*parts)+8)
	}
	var buf []byte
	for g := range t.keys {
		var h uint64
		h, buf = t.groupPartHash(seed, int32(g), buf)
		p := h % uint64(parts)
		out[p] = append(out[p], int32(g))
	}
	return out
}

// groupPartHash is the partitioning hash of group g's key; rowPartHash
// computes the same for the keys of a row. buf is scratch space.
func (t *aggTable) groupPartHash(seed maphash.Seed, g int32, buf []byte) (uint64, []byte) {
	key := t.keys[g]
	switch {
	case len(key) == 1 && !key[0].Null && t.keyClasses[0] == vInt:
		return intPartHash(key[0].I), buf
	case len(key) == 1 && !key[0].Null && t.keyClasses[0] == vStr:
		return strPartHash(t.hashes[g]), buf
	}
	buf = buf[:0]
	for k, v := range key {
		buf = appendKey(buf, v, t.keyTypes[k])
	}
	return maphash.Bytes(seed, buf), buf
}

// intPartHash and strPartHash partition single INT-class and STRING keys
// (STRING by strKeyHash). They use other bits than the group tables'
// slot selection.
func intPartHash(k int64) uint64  { return (uint64(k) * 0x9E3779B97F4A7C15) >> 32 }
func strPartHash(h uint64) uint64 { return h >> 40 }

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

// mergeByFirst merges row lists that are each ordered by first position
// (positions are distinct), with a binary heap of the lists' heads.
func mergeByFirst(rows [][]types.Row, first [][]int64) []types.Row {
	total := 0
	for _, r := range rows {
		total += len(r)
	}
	out := make([]types.Row, 0, total)
	pos := make([]int, len(rows))
	heap := make([]int, 0, len(rows)) // list indexes, ordered by their head
	head := func(p int) int64 { return first[p][pos[p]] }
	down := func(i int) {
		for {
			l, m := 2*i+1, i
			if l < len(heap) && head(heap[l]) < head(heap[m]) {
				m = l
			}
			if r := l + 1; r < len(heap) && head(heap[r]) < head(heap[m]) {
				m = r
			}
			if m == i {
				return
			}
			heap[i], heap[m] = heap[m], heap[i]
			i = m
		}
	}
	for p := range rows {
		if len(rows[p]) > 0 {
			heap = append(heap, p)
		}
	}
	for i := len(heap)/2 - 1; i >= 0; i-- {
		down(i)
	}
	for len(heap) > 0 {
		p := heap[0]
		out = append(out, rows[p][pos[p]])
		if pos[p]++; pos[p] == len(rows[p]) {
			heap[0] = heap[len(heap)-1]
			heap = heap[:len(heap)-1]
		}
		down(0)
	}
	return out
}

// minPartitionedMerge is the merge work (partial groups and DISTINCT
// values, see mergeWork) from which partial tables are merged by several
// goroutines.
const minPartitionedMerge = 1 << 13

// mergeTables merges the partial tables of parallel workers and returns
// the result rows in first-appearance order. Large merges are partitioned
// by key hash: partition p of every partial table is merged into final
// table p by its own goroutine.
func mergeTables(ec *Context, tables []*aggTable, keyTypes []types.Type, calls []*plan.AggCall) ([]types.Row, error) {
	total := 0
	for _, t := range tables {
		total += t.mergeWork()
	}
	parts := min(ec.Threads, len(tables))
	if parts <= 1 || total < minPartitionedMerge || len(keyTypes) == 0 {
		final := newAggTable(ec, keyTypes, calls)
		for _, t := range tables {
			if err := final.mergeFrom(t); err != nil {
				return nil, err
			}
		}
		return final.rows()
	}
	seed := maphash.MakeSeed()
	partGroups := make([][][]int32, len(tables)) // table → partition → groups
	var wg sync.WaitGroup
	for i, t := range tables {
		wg.Add(1)
		go func() {
			defer wg.Done()
			partGroups[i] = t.partitionGroups(seed, parts)
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
				for _, g := range partGroups[i][p] {
					if err := final.mergeGroup(t, g); err != nil {
						results[p] = partResult{errPos: math.MinInt64, err: err}
						return
					}
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

// fold evaluates a batch and folds it into t.
func (in *vaggInput) fold(t *aggTable, b *Batch, pos int64) error {
	if err := in.evalBatch(b); err != nil {
		return err
	}
	return t.update(in.keys, in.args, b.N, b.Sel, pos)
}

// evalBatch evaluates the keys and arguments of a batch (into in.keys and
// in.args); on a vectorized failure the batch is evaluated row by row to
// report the first row's error.
func (in *vaggInput) evalBatch(b *Batch) error {
	if err := in.exprs.eval(b, b.Sel, in.vals); err != nil {
		if _, err := in.exprs.evalRows(b, b.Sel, in.vals); err != nil {
			return err
		}
	}
	in.keys = in.vals[:in.nkeys]
	for i, a := range in.argOf {
		if a >= 0 {
			in.args[i] = in.vals[a]
		} else {
			in.args[i] = nil
		}
	}
	return nil
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
