package exec

import (
	"container/heap"
	"math"
	"slices"
	"strings"
	"sync"

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
	for k, v := range b.Cols {
		c := &s.cols[k]
		cls := s.classes[k]
		var strs []string
		if cls == vStr {
			strs = v.strs(b.N)
		}
		if v.Nulls != nil && c.Nulls == nil {
			c.Nulls = make([]bool, s.n, max(s.n, 16))
		}
		forActive(b.N, b.Sel, func(i int) {
			switch cls {
			case vInt:
				c.I = append(c.I, v.I[i])
			case vFloat:
				c.F = append(c.F, v.F[i])
			case vWide:
				c.W = append(c.W, v.W[i])
			default:
				c.S = append(c.S, strs[i])
				bytes += int64(len(strs[i]))
			}
			if c.Nulls != nil {
				c.Nulls = append(c.Nulls, v.isNull(i))
			}
		})
	}
	s.n += b.Len()
	return bytes
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
}

// totalOrderAggregate returns the aggregation below a sort (through
// projections and filters) whose output order the sort makes irrelevant:
// every group key is a sort key, so no two rows tie (FLOAT64 keys are
// excluded: NaNs of different payloads are separate groups but compare
// equal), or nil.
func totalOrderAggregate(x *physical.Sort) *physical.HashAggregate {
	ids := map[plan.ColumnID]bool{}
	for _, k := range x.Keys {
		if ref, ok := k.Expr.(*plan.ColumnRef); ok {
			ids[ref.ID] = true
		}
	}
	for n := x.Input; ; {
		switch y := n.(type) {
		case *physical.Filter:
			n = y.Input
		case *physical.Project:
			next := map[plan.ColumnID]bool{}
			for i, c := range y.Cols {
				if ref, ok := y.Exprs[i].(*plan.ColumnRef); ok && ids[c.ID] {
					next[ref.ID] = true
				}
			}
			ids, n = next, y.Input
		case *physical.HashAggregate:
			if len(y.Keys) == 0 {
				return nil
			}
			for _, c := range y.KeyCols {
				if !ids[c.ID] || c.Type.Kind == types.KindFloat64 {
					return nil
				}
			}
			return y
		default:
			return nil
		}
	}
}

// maxTopN is the largest LIMIT (plus OFFSET) sorted with a bounded heap;
// beyond it, sorting all rows (normalized keys, parallel runs) is faster
// than maintaining the heap, with the same (stable) order.
const maxTopN = 1 << 14

func buildVSort(ec *Context, x *physical.Sort) (BatchOperator, error) {
	keys, err := sortKeys(x)
	if err != nil {
		return nil, err
	}
	if agg := totalOrderAggregate(x); agg != nil {
		if ec.unordered == nil {
			ec.unordered = map[*physical.HashAggregate]bool{}
		}
		ec.unordered[agg] = true
	}
	if x.Limit >= 0 && x.Limit <= maxTopN {
		return buildVTopN(ec, x, keys)
	}
	in, err := BuildBatch(ec, x.Input)
	if err != nil {
		return nil, err
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
	op := &vsortOp{ec: ec, input: in, keys: keys, store: newColStore(classes), bufs: make([]vecBuf, len(ts)), threads: threads}
	op.out.Cols = make([]*Vec, len(ts))
	return op, nil
}

func (s *vsortOp) NextBatch() (*Batch, error) {
	if !s.done {
		s.done = true
		if err := s.run(); err != nil {
			return nil, err
		}
	}
	if s.pos >= len(s.perm) {
		return nil, nil
	}
	end := min(s.pos+BatchSize, len(s.perm))
	s.store.gather(s.perm[s.pos:end], s.bufs, &s.out)
	s.pos = end
	return &s.out, nil
}

func (s *vsortOp) run() error {
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
	cmp := newColComparator(s.store, s.keys)
	items := cmp.items(s.store.n)
	sorted, err := parallelSort(s.ec, items, cmp, s.threads)
	if err != nil {
		return err
	}
	s.perm = make([]int32, len(sorted))
	for i, it := range sorted {
		s.perm[i] = it.row
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
func (c *colComparator) items(n int) []sortItem {
	items := make([]sortItem, n)
	k := &c.keys[0]
	for i := range items {
		items[i].row = int32(i)
		if k.nulls != nil && k.nulls[i] {
			if !k.nullsFirst {
				items[i].key = math.MaxUint64
			}
			continue
		}
		var u uint64
		switch k.cls {
		case vInt:
			u = uint64(k.ints[i]) ^ 1<<63
		case vWide:
			u = uint64(clampInt64(k.wides[i])) ^ 1<<63
		case vFloat:
			f := k.floats[i]
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
			u = k.prefix[i]
		}
		if k.desc {
			u = ^u
		}
		items[i].key = u
	}
	return items
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

func newColComparator(s *colStore, keys []sortKey) *colComparator {
	c := &colComparator{}
	for _, k := range keys {
		col := &s.cols[k.index]
		ck := colKey{cls: s.classes[k.index], ints: col.I, wides: col.W, floats: col.F, strs: col.S,
			nulls: col.Nulls, desc: k.desc, nullsFirst: k.nullsFirst}
		if ck.cls == vStr {
			ck.prefix = make([]uint64, len(col.S))
			for i, str := range col.S {
				ck.prefix[i] = stringPrefix(str)
			}
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

// minParallelSort is the input size from which sorting uses several
// goroutines.
const minParallelSort = 1 << 14

// parallelSort sorts items by cmp: in parallel runs merged pairwise when
// threads > 1. It checks for cancellation every checkEvery comparisons.
func parallelSort(ec *Context, perm []sortItem, c *colComparator, threads int) ([]sortItem, error) {
	runs := 1
	if threads > 1 && len(perm) >= minParallelSort {
		runs = min(threads, len(perm)/(minParallelSort/2))
	}
	bounds := make([]int, runs+1)
	for i := range bounds {
		bounds[i] = len(perm) * i / runs
	}
	errs := make([]error, runs)
	var wg sync.WaitGroup
	for r := 0; r < runs; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[r] = sortRun(ec, perm[bounds[r]:bounds[r+1]], c)
		}()
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			return nil, err
		}
	}
	// Merge rounds: runs (lo, mid, hi) pairs merged in parallel.
	src, dst := perm, make([]sortItem, len(perm))
	for len(bounds) > 2 {
		var next []int
		var wg sync.WaitGroup
		for i := 0; i+1 < len(bounds); i += 2 {
			lo := bounds[i]
			next = append(next, lo)
			if i+2 >= len(bounds) {
				copy(dst[lo:], src[lo:bounds[i+1]])
				continue
			}
			mid, hi := bounds[i+1], bounds[i+2]
			wg.Add(1)
			go func() {
				defer wg.Done()
				mergeRuns(dst[lo:hi], src[lo:mid], src[mid:hi], c)
			}()
		}
		next = append(next, len(perm))
		wg.Wait()
		if err := ec.Check(); err != nil {
			return nil, err
		}
		src, dst, bounds = dst, src, next
	}
	return src, nil
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

func mergeRuns(dst, a, b []sortItem, c *colComparator) {
	i, j, k := 0, 0, 0
	for i < len(a) && j < len(b) {
		if c.compareItems(a[i], b[j]) <= 0 {
			dst[k] = a[i]
			i++
		} else {
			dst[k] = b[j]
			j++
		}
		k++
	}
	k += copy(dst[k:], a[i:])
	copy(dst[k:], b[j:])
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
