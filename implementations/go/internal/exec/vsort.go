package exec

import (
	"container/heap"
	"math"
	"slices"
	"strings"
	"sync/atomic"

	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Vectorized sorting. A full sort materializes its input column-wise,
// sorts a permutation with comparators specialized per key column (no
// boxing of values), in parallel runs that are then merged when threads
// are available, and emits batches gathered in permutation order. Ties are
// broken by input position, so the order equals that of the row-mode
// stable sort. ORDER BY … LIMIT n keeps only the best n rows in a heap
// (per parallel worker, merged at the end).

// colStore materializes batches column-wise.
type colStore struct {
	classes []vclass
	cols    []Vec
	n       int
}

func newColStore(classes []vclass) *colStore {
	return &colStore{classes: classes, cols: make([]Vec, len(classes))}
}

// append adds the active rows of b and returns the bytes of string data
// added.
func (s *colStore) append(b *Batch) int64 {
	var bytes int64
	n, sel := b.N, b.Sel
	for k, v := range b.Cols {
		c := &s.cols[k]
		switch s.classes[k] {
		case vInt:
			c.I = appendActive(c.I, v.I, n, sel)
		case vFloat:
			c.F = appendActive(c.F, v.F, n, sel)
		case vWide:
			c.W = appendActive(c.W, v.W, n, sel)
		default:
			old := len(c.S)
			c.S = appendActive(c.S, v.strs(n), n, sel)
			for _, str := range c.S[old:] {
				bytes += int64(len(str))
			}
		}
		if v.Nulls != nil && c.Nulls == nil {
			c.Nulls = make([]bool, s.n, max(s.n, 16))
		}
		if c.Nulls != nil {
			if v.Nulls != nil {
				c.Nulls = appendActive(c.Nulls, v.Nulls, n, sel)
			} else {
				c.Nulls = append(c.Nulls, make([]bool, b.Len())...)
			}
		}
	}
	s.n += b.Len()
	return bytes
}

// appendActive appends the rows sel (nil: 0..n-1) of src to dst.
func appendActive[T any](dst, src []T, n int, sel []int32) []T {
	if sel == nil {
		return append(dst, src[:n]...)
	}
	dst = slices.Grow(dst, len(sel))
	for _, i := range sel {
		dst = append(dst, src[i])
	}
	return dst
}

// gather fills out with the rows idx (in that order).
func (s *colStore) gather(idx []int32, bufs []vecBuf, out *Batch) {
	n := len(idx)
	for k := range s.cols {
		c := &s.cols[k]
		v := bufs[k].reset(n, s.classes[k])
		switch s.classes[k] {
		case vInt:
			for o, i := range idx {
				v.I[o] = c.I[i]
			}
		case vFloat:
			for o, i := range idx {
				v.F[o] = c.F[i]
			}
		case vWide:
			for o, i := range idx {
				v.W[o] = c.W[i]
			}
		default:
			for o, i := range idx {
				v.S[o] = c.S[i]
			}
		}
		if c.Nulls != nil {
			nulls := bufs[k].withNulls(n)
			for o, i := range idx {
				nulls[o] = c.Nulls[i]
			}
		}
		out.Cols[k] = v
	}
	out.N, out.Sel = n, nil
}

// sortKeys compiles the keys of a sort node (column references).
func sortKeys(x *physical.Sort) ([]sortKey, error) {
	lay := layoutOf(x.Input.Schema())
	keys := make([]sortKey, len(x.Keys))
	for i, k := range x.Keys {
		ref, ok := k.Expr.(*plan.ColumnRef)
		if !ok {
			return nil, errs.New(errs.InternalError, "sort key is not a column")
		}
		idx, ok := lay[ref.ID]
		if !ok {
			return nil, errs.New(errs.InternalError, "unbound sort key %s", ref)
		}
		keys[i] = sortKey{index: idx, typ: ref.T, desc: k.Desc, nullsFirst: k.NullsFirst}
	}
	return keys, nil
}

// ---------------------------------------------------------------- full sort

type vsortOp struct {
	ec      *Context
	input   BatchOperator
	keys    []sortKey
	store   *colStore
	perm    []int32
	pos     int
	done    bool
	bufs    []vecBuf
	out     Batch
	threads int
	emit    *sortEmitter // parallel output gathering (large sorts)
	par     *sortInput   // parallel input (instead of input)
}

func buildVSort(ec *Context, x *physical.Sort) (BatchOperator, error) {
	keys, err := sortKeys(x)
	if err != nil {
		return nil, err
	}
	if x.Limit >= 0 {
		return buildVTopN(ec, x, keys)
	}
	ts := schemaTypes(x.Schema())
	classes := make([]vclass, len(ts))
	for i, t := range ts {
		classes[i] = classOf(t)
	}
	threads := ec.Threads
	if ec.serial > 0 {
		threads = 1
	}
	op := &vsortOp{ec: ec, keys: keys, store: newColStore(classes), bufs: make([]vecBuf, len(ts)), threads: threads}
	op.out.Cols = make([]*Vec, len(ts))
	if ranges, ok := parallelMorsels(ec, x.Input); ok {
		nw := workers(ec, len(ranges))
		ops, srcs, err := batchPipelines(ec, x.Input, nw)
		if err != nil {
			return nil, err
		}
		op.par = &sortInput{ranges: ranges, ops: ops, srcs: srcs}
		return op, nil
	}
	in, err := BuildBatch(ec, x.Input)
	if err != nil {
		return nil, err
	}
	op.input = in
	return op, nil
}

// sortInput is the parallel input pipeline of a sort: every worker
// materializes the morsels it takes into a column store of their own, and
// the stores are concatenated in morsel (table) order.
type sortInput struct {
	ranges []scanRange
	ops    []BatchOperator
	srcs   []*singleRange
}

// materialize runs the input pipelines and returns the concatenated store.
func (p *sortInput) materialize(ec *Context, classes []vclass) (*colStore, error) {
	stores := make([]*colStore, len(p.ranges))
	width := int64(len(classes))
	err := runMorsels(ec, p.ranges, len(p.ops), func(w, i int) error {
		p.srcs[w].set(p.ranges[i])
		st := newColStore(classes)
		stores[i] = st
		for {
			b, err := p.ops[w].NextBatch()
			if b == nil || err != nil {
				return err
			}
			if err := ec.Check(); err != nil {
				return err
			}
			bytes := st.append(b)
			if err := ec.Mem.Reserve(int64(b.Len())*(28+16*width) + bytes); err != nil {
				return err
			}
		}
	})
	if err != nil {
		return nil, err
	}
	return concatStores(stores, classes, len(p.ops)), nil
}

// concatStores concatenates column stores (copying with up to workers
// goroutines).
func concatStores(stores []*colStore, classes []vclass, workers int) *colStore {
	out := newColStore(classes)
	offs := make([]int, len(stores)+1)
	for i, st := range stores {
		offs[i+1] = offs[i] + st.n
	}
	out.n = offs[len(stores)]
	for k, cls := range classes {
		c := &out.cols[k]
		switch cls {
		case vInt:
			c.I = make([]int64, out.n)
		case vFloat:
			c.F = make([]float64, out.n)
		case vWide:
			c.W = make([]types.Int128, out.n)
		default:
			c.S = make([]string, out.n)
		}
		for _, st := range stores {
			if st.cols[k].Nulls != nil {
				c.Nulls = make([]bool, out.n)
				break
			}
		}
	}
	parallelDo(min(workers, len(stores)), func(w int) {
		for i := w; i < len(stores); i += workers {
			st, off := stores[i], offs[i]
			for k := range classes {
				src, dst := &st.cols[k], &out.cols[k]
				switch classes[k] {
				case vInt:
					copy(dst.I[off:], src.I)
				case vFloat:
					copy(dst.F[off:], src.F)
				case vWide:
					copy(dst.W[off:], src.W)
				default:
					copy(dst.S[off:], src.S)
				}
				if src.Nulls != nil {
					copy(dst.Nulls[off:], src.Nulls)
				}
			}
		}
	})
	return out
}

func (s *vsortOp) NextBatch() (*Batch, error) {
	if !s.done {
		s.done = true
		if err := s.run(); err != nil {
			return nil, err
		}
	}
	if s.emit != nil {
		return s.emit.next()
	}
	if s.pos >= len(s.perm) {
		return nil, nil
	}
	end := min(s.pos+BatchSize, len(s.perm))
	s.store.gather(s.perm[s.pos:end], s.bufs, &s.out)
	s.pos = end
	return &s.out, nil
}

// minParallelEmit is the number of sorted rows from which output batches
// are gathered by parallel workers.
const minParallelEmit = 1 << 15

// sortEmitter gathers the output batches of a sort with parallel workers,
// a bounded window of batches ahead of the consumer; batches are returned
// in order. Each window slot owns its vectors, which are reused once the
// consumer has moved past the slot's batch.
type sortEmitter struct {
	ec      *Context
	store   *colStore
	perm    []int32
	batches int
	taken   atomic.Int64 // batches taken by workers
	slots   []emitSlot
	cur     int // batch returned last (-1: none)
	started bool
	workers int
}

type emitSlot struct {
	out   Batch
	bufs  []vecBuf
	ready chan struct{} // the slot's batch is gathered
	free  chan struct{} // the consumer has released the slot
}

func newSortEmitter(ec *Context, store *colStore, perm []int32, workers int) *sortEmitter {
	e := &sortEmitter{ec: ec, store: store, perm: perm, cur: -1, workers: workers,
		batches: (len(perm) + BatchSize - 1) / BatchSize}
	e.slots = make([]emitSlot, 2*workers)
	for i := range e.slots {
		sl := &e.slots[i]
		sl.out.Cols = make([]*Vec, len(store.classes))
		sl.bufs = make([]vecBuf, len(store.classes))
		sl.ready = make(chan struct{}, 1)
		sl.free = make(chan struct{}, 1)
		sl.free <- struct{}{}
	}
	return e
}

func (e *sortEmitter) start() {
	done := e.ec.Ctx.Done()
	for w := 0; w < e.workers; w++ {
		go func() {
			for {
				j := int(e.taken.Add(1) - 1)
				if j >= e.batches {
					return
				}
				sl := &e.slots[j%len(e.slots)]
				select {
				case <-sl.free:
				case <-done:
					return
				}
				lo := j * BatchSize
				e.store.gather(e.perm[lo:min(lo+BatchSize, len(e.perm))], sl.bufs, &sl.out)
				sl.ready <- struct{}{}
			}
		}()
	}
}

func (e *sortEmitter) next() (*Batch, error) {
	if !e.started {
		e.started = true
		e.start()
	}
	if e.cur >= 0 {
		e.slots[e.cur%len(e.slots)].free <- struct{}{}
	}
	e.cur++
	if e.cur >= e.batches {
		return nil, nil
	}
	sl := &e.slots[e.cur%len(e.slots)]
	select {
	case <-sl.ready:
	case <-e.ec.Ctx.Done():
		return nil, ContextError(e.ec.Ctx.Err())
	}
	return &sl.out, nil
}

func (s *vsortOp) run() error {
	if s.par != nil {
		st, err := s.par.materialize(s.ec, s.store.classes)
		if err != nil {
			return err
		}
		s.store = st
		return s.sort()
	}
	width := int64(len(s.store.classes))
	for {
		b, err := s.input.NextBatch()
		if err != nil {
			return err
		}
		if b == nil {
			break
		}
		if err := s.ec.Check(); err != nil {
			return err
		}
		bytes := s.store.append(b)
		if err := s.ec.Mem.Reserve(int64(b.Len())*(28+16*width) + bytes); err != nil {
			return err
		}
	}
	return s.sort()
}

// sort sorts the materialized input.
func (s *vsortOp) sort() error {
	cmp := newColComparator(s.store, s.keys, s.threads)
	items := cmp.items(s.store.n, s.threads)
	sorted, err := parallelSort(s.ec, items, cmp, s.threads)
	if err != nil {
		return err
	}
	s.perm = make([]int32, len(sorted))
	for i, it := range sorted {
		s.perm[i] = it.row
	}
	if s.threads > 1 && len(s.perm) >= minParallelEmit {
		s.emit = newSortEmitter(s.ec, s.store, s.perm, min(s.threads, len(s.perm)/BatchSize))
	}
	return nil
}

// sortItem is a row to sort with its first sort key normalized to an
// unsigned integer whose order is the key order (contiguous, so most
// comparisons touch no other memory); equal normalized keys are resolved
// by the full comparator.
type sortItem struct {
	key uint64
	row int32
}

// items builds the sort items of rows 0..n-1.
func (c *colComparator) items(n, threads int) []sortItem {
	items := make([]sortItem, n)
	parallelChunks(n, threads, func(lo, hi int) {
		for i := lo; i < hi; i++ {
			items[i] = sortItem{key: c.norm(0, int32(i)), row: int32(i)}
		}
	})
	return items
}

// norm returns the normalized value of sort key k for row i: an unsigned
// integer whose order is the key order (NULLs first or last as the key
// requires); equal normalized values need the full comparison.
func (c *colComparator) norm(k int, i int32) uint64 {
	key := &c.keys[k]
	if key.nulls != nil && key.nulls[i] {
		if key.nullsFirst {
			return 0
		}
		return math.MaxUint64
	}
	var u uint64
	switch key.cls {
	case vInt:
		u = uint64(key.ints[i]) ^ 1<<63
	case vWide:
		u = uint64(clampInt64(key.wides[i])) ^ 1<<63
	case vFloat:
		f := key.floats[i]
		if f == 0 {
			f = 0 // -0 equals 0
		}
		u = math.Float64bits(f)
		if u&(1<<63) != 0 {
			u = ^u
		} else {
			u |= 1 << 63
		}
	default:
		u = key.prefix[i]
	}
	if key.desc {
		u = ^u
	}
	return u
}

// equal reports whether rows a and b have equal values (or are both NULL)
// for sort key k.
func (c *colComparator) equal(k int, a, b int32) bool {
	key := &c.keys[k]
	if key.nulls != nil {
		an, bn := key.nulls[a], key.nulls[b]
		if an || bn {
			return an && bn
		}
	}
	switch key.cls {
	case vInt:
		return key.ints[a] == key.ints[b]
	case vWide:
		return key.wides[a] == key.wides[b]
	case vFloat:
		return key.floats[a] == key.floats[b]
	}
	return key.strs[a] == key.strs[b]
}

func (c *colComparator) compareItems(a, b sortItem) int {
	switch {
	case a.key < b.key:
		return -1
	case a.key > b.key:
		return 1
	}
	return c.compare(a.row, b.row)
}

// colComparator compares rows of a colStore by the sort keys, ties broken
// by row index.
type colComparator struct {
	keys []colKey
}

type colKey struct {
	cls        vclass
	ints       []int64
	wides      []types.Int128
	floats     []float64
	strs       []string
	prefix     []uint64 // STRING keys: first 8 bytes, big-endian (byte order)
	nulls      []bool
	desc       bool
	nullsFirst bool
}

func newColComparator(s *colStore, keys []sortKey, threads int) *colComparator {
	c := &colComparator{}
	for _, k := range keys {
		col := &s.cols[k.index]
		ck := colKey{cls: s.classes[k.index], ints: col.I, wides: col.W, floats: col.F, strs: col.S,
			nulls: col.Nulls, desc: k.desc, nullsFirst: k.nullsFirst}
		if ck.cls == vStr {
			ck.prefix = make([]uint64, len(col.S))
			parallelChunks(len(col.S), threads, func(lo, hi int) {
				for i, str := range col.S[lo:hi] {
					ck.prefix[lo+i] = stringPrefix(str)
				}
			})
		}
		c.keys = append(c.keys, ck)
	}
	return c
}

// clampInt64 saturates a 128-bit value to the int64 range: an
// order-preserving (not strictly) sort prefix for wide DECIMAL keys.
func clampInt64(x types.Int128) int64 {
	switch {
	case x.IsInt64():
		return x.Int64()
	case x.Hi < 0:
		return math.MinInt64
	}
	return math.MaxInt64
}

// stringPrefix packs the first 8 bytes of s big-endian, zero-padded:
// prefixes order like the strings, and equal prefixes need a full
// comparison.
func stringPrefix(s string) uint64 {
	var p uint64
	for i := 0; i < 8; i++ {
		p <<= 8
		if i < len(s) {
			p |= uint64(s[i])
		}
	}
	return p
}

func (c *colComparator) compare(a, b int32) int {
	for i := range c.keys {
		k := &c.keys[i]
		if k.nulls != nil {
			an, bn := k.nulls[a], k.nulls[b]
			if an || bn {
				if an && bn {
					continue
				}
				if an == k.nullsFirst {
					return -1
				}
				return 1
			}
		}
		var r int
		switch k.cls {
		case vInt:
			x, y := k.ints[a], k.ints[b]
			if x < y {
				r = -1
			} else if x > y {
				r = 1
			}
		case vWide:
			r = k.wides[a].Cmp(k.wides[b])
		case vFloat:
			x, y := k.floats[a], k.floats[b]
			if x < y {
				r = -1
			} else if x > y {
				r = 1
			}
		default:
			if x, y := k.prefix[a], k.prefix[b]; x < y {
				r = -1
			} else if x > y {
				r = 1
			} else {
				r = strings.Compare(k.strs[a], k.strs[b])
			}
		}
		if r != 0 {
			if k.desc {
				return -r
			}
			return r
		}
	}
	return int(a) - int(b)
}

// parallelSort sorts items by cmp: a radix sort by the normalized first
// key, then the full comparator for runs of equal normalized keys (unless
// the normalized key decides the order alone). Both phases use up to
// threads goroutines.
func parallelSort(ec *Context, items []sortItem, c *colComparator, threads int) ([]sortItem, error) {
	sorted, err := radixSortItems(ec, items, threads)
	if err != nil {
		return nil, err
	}
	if k := &c.keys[0]; len(c.keys) == 1 && k.cls == vInt && k.nulls == nil {
		// Distinct INT-class values have distinct normalized keys, and the
		// stable radix sort kept equal ones in input order.
		return sorted, nil
	}
	if err := sortTies(ec, sorted, c, threads); err != nil {
		return nil, err
	}
	return sorted, nil
}

func sortRun(ec *Context, run []sortItem, c *colComparator) (err error) {
	defer func() {
		if r := recover(); r != nil {
			abort, ok := r.(sortAborted)
			if !ok {
				panic(r)
			}
			err = abort.err
		}
	}()
	n := 0
	slices.SortFunc(run, func(a, b sortItem) int {
		if n++; n%checkEvery == 0 {
			if err := ec.Check(); err != nil {
				panic(sortAborted{err})
			}
		}
		return c.compareItems(a, b)
	})
	return nil
}

// ---------------------------------------------------------------- top-N

// topNHeap keeps the best limit rows by (sort keys, input position): a
// max-heap whose root is the worst kept row.
type topNHeap struct {
	keys  []sortKey
	limit int
	rows  []types.Row
	pos   []int64
}

func (h *topNHeap) Len() int { return len(h.rows) }
func (h *topNHeap) Less(i, j int) bool {
	return h.before(h.rows[j], h.pos[j], h.rows[i], h.pos[i])
}
func (h *topNHeap) Swap(i, j int) {
	h.rows[i], h.rows[j] = h.rows[j], h.rows[i]
	h.pos[i], h.pos[j] = h.pos[j], h.pos[i]
}
func (h *topNHeap) Push(any) { panic("unused") }
func (h *topNHeap) Pop() any { panic("unused") }

// before reports whether row a (at position pa) sorts before row b.
func (h *topNHeap) before(a types.Row, pa int64, b types.Row, pb int64) bool {
	if c := compareRows(h.keys, a, b); c != 0 {
		return c < 0
	}
	return pa < pb
}

// offer adds a row (copied) if it belongs to the best limit rows; it
// reports whether the row was taken.
func (h *topNHeap) offer(row types.Row, pos int64) bool {
	if h.limit == 0 {
		return false
	}
	if len(h.rows) < h.limit {
		h.rows = append(h.rows, append(types.Row(nil), row...))
		h.pos = append(h.pos, pos)
		if len(h.rows) == h.limit {
			heap.Init(h)
		}
		return true
	}
	if !h.before(row, pos, h.rows[0], h.pos[0]) {
		return false
	}
	copy(h.rows[0], row)
	h.pos[0] = pos
	heap.Fix(h, 0)
	return true
}

// rejects reports whether row i of b would be rejected without copying it: the
// heap is full and the row does not sort before the root (rows offered
// later always have greater positions).
func (h *topNHeap) rejects(b *Batch, i int, classes []vclass) bool {
	if len(h.rows) < h.limit || h.limit == 0 {
		return h.limit == 0
	}
	root := h.rows[0]
	for _, k := range h.keys {
		x, y := b.Cols[k.index].value(i, classes[k.index]), root[k.index]
		var c int
		switch {
		case x.Null && y.Null:
			continue
		case x.Null:
			c = 1
			if k.nullsFirst {
				c = -1
			}
			return c >= 0
		case y.Null:
			c = -1
			if k.nullsFirst {
				c = 1
			}
			return c >= 0
		}
		c = types.Compare(k.typ, x, k.typ, y)
		if k.desc {
			c = -c
		}
		if c != 0 {
			return c > 0
		}
	}
	return true // equal keys: the earlier root wins
}

// sorted returns the kept rows in order.
func (h *topNHeap) sorted() []types.Row {
	idx := make([]int, len(h.rows))
	for i := range idx {
		idx[i] = i
	}
	slices.SortFunc(idx, func(a, b int) int {
		if h.before(h.rows[a], h.pos[a], h.rows[b], h.pos[b]) {
			return -1
		}
		return 1
	})
	out := make([]types.Row, len(idx))
	for i, k := range idx {
		out[i] = h.rows[k]
	}
	return out
}

// foldTopN offers the active rows of a batch whose first row is at
// position pos.
func foldTopN(ec *Context, h *topNHeap, b *Batch, classes []vclass, row types.Row, pos int64) error {
	var err error
	forActive(b.N, b.Sel, func(i int) {
		if err != nil || h.rejects(b, i, classes) {
			return
		}
		batchRow(b, i, classes, row)
		grows := len(h.rows) < h.limit
		if h.offer(row, pos+int64(i)) && grows {
			err = ec.Mem.Reserve(RowSize(row))
		}
	})
	return err
}

func buildVTopN(ec *Context, x *physical.Sort, keys []sortKey) (BatchOperator, error) {
	ts := schemaTypes(x.Schema())
	classes := make([]vclass, len(ts))
	for i, t := range ts {
		classes[i] = classOf(t)
	}
	limit := int(min(x.Limit, int64(1<<30)))
	if ranges, ok := parallelMorsels(ec, x.Input); ok {
		nw := workers(ec, len(ranges))
		ops, srcs, err := batchPipelines(ec, x.Input, nw)
		if err != nil {
			return nil, err
		}
		heaps := make([]*topNHeap, nw)
		for w := range heaps {
			heaps[w] = &topNHeap{keys: keys, limit: limit}
		}
		run := func() ([]types.Row, error) {
			err := runMorsels(ec, ranges, nw, func(w, i int) error {
				srcs[w].set(ranges[i])
				row := make(types.Row, len(ts))
				var k int64
				for {
					b, err := ops[w].NextBatch()
					if b == nil || err != nil {
						return err
					}
					if err := foldTopN(ec, heaps[w], b, classes, row, morselPos(i, k)); err != nil {
						return err
					}
					k += int64(b.N)
				}
			})
			if err != nil {
				return nil, err
			}
			final := &topNHeap{keys: keys, limit: limit}
			for _, h := range heaps {
				for i, r := range h.rows {
					final.offerMerged(r, h.pos[i])
				}
			}
			return final.sorted(), nil
		}
		return &lazyRows{run: run, types: ts}, nil
	}
	in, err := BuildBatch(ec, x.Input)
	if err != nil {
		return nil, err
	}
	run := func() ([]types.Row, error) {
		h := &topNHeap{keys: keys, limit: limit}
		row := make(types.Row, len(ts))
		var pos int64
		for {
			b, err := in.NextBatch()
			if err != nil {
				return nil, err
			}
			if b == nil {
				return h.sorted(), nil
			}
			if err := ec.Check(); err != nil {
				return nil, err
			}
			if err := foldTopN(ec, h, b, classes, row, pos); err != nil {
				return nil, err
			}
			pos += int64(b.N)
		}
	}
	return &lazyRows{run: run, types: ts}, nil
}

// offerMerged adds a row of another heap (positions are not ordered).
func (h *topNHeap) offerMerged(row types.Row, pos int64) {
	if h.limit == 0 {
		return
	}
	if len(h.rows) < h.limit {
		h.rows = append(h.rows, row)
		h.pos = append(h.pos, pos)
		if len(h.rows) == h.limit {
			heap.Init(h)
		}
		return
	}
	if h.before(row, pos, h.rows[0], h.pos[0]) {
		h.rows[0], h.pos[0] = row, pos
		heap.Fix(h, 0)
	}
}
