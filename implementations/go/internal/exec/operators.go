package exec

import (
	"container/heap"
	"slices"
	"sort"

	"polyquery/internal/physical"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Operator is a pull-based iterator. Next returns nil at end of input. A
// returned row is only valid until the following call to Next; consumers that
// retain rows must copy them.
type Operator interface {
	Next() (types.Row, error)
}

// ---------------------------------------------------------------- scan

// scanOp reads the selected columns (ords) of a table row by row from the
// ranges its source yields (by default every row group not excluded by the
// scan's column filters); output rows contain only the selected columns.
type scanOp struct {
	ec     *Context
	table  *storage.Table
	ords   []int
	src    rangeSource
	reader *storage.GroupReader
	pos    int
	end    int
	n      int
	buf    types.Row
}

func newScan(ec *Context, x *physical.TableScan, src rangeSource) *scanOp {
	if src == nil {
		src = &groupRanges{table: x.Table, filters: x.Filters}
	}
	return &scanOp{ec: ec, table: x.Table, ords: x.Ords, src: src, buf: make(types.Row, len(x.Ords))}
}

func (s *scanOp) Next() (types.Row, error) {
	for s.reader == nil || s.pos >= s.end {
		r, ok := s.src.next()
		if !ok {
			return nil, nil
		}
		g := s.table.Groups[r.group]
		reader, err := g.Reader(s.ords)
		if err != nil {
			return nil, err
		}
		s.reader, s.pos, s.end = reader, r.start, r.end
	}
	if s.n%checkEvery == 0 {
		if err := s.ec.Check(); err != nil {
			return nil, err
		}
	}
	s.n++
	s.reader.Read(s.pos, s.buf)
	s.pos++
	return s.buf, nil
}

// indexScanOp returns the selected columns of the rows found by an index
// lookup, in row-ID order.
type indexScanOp struct {
	ec      *Context
	node    *physical.IndexScan
	ids     []uint32
	started bool
	pos     int
	group   int
	reader  *storage.GroupReader
	buf     types.Row
}

func (s *indexScanOp) Next() (types.Row, error) {
	if !s.started {
		s.started = true
		n := s.node
		switch {
		case n.Empty:
		case n.Point:
			s.ids = n.Index.Lookup(n.Points)
		default:
			s.ids = n.Index.Range(n.Range)
		}
		s.group = -1
	}
	if s.pos >= len(s.ids) {
		return nil, nil
	}
	if s.pos%checkEvery == 0 {
		if err := s.ec.Check(); err != nil {
			return nil, err
		}
	}
	t := s.node.Table
	id := int(s.ids[s.pos])
	s.pos++
	if s.group < 0 || id >= t.Groups[s.group].Start+t.Groups[s.group].Rows || id < t.Groups[s.group].Start {
		s.group = t.GroupOf(id)
		r, err := t.Groups[s.group].Reader(s.node.Ords)
		if err != nil {
			return nil, err
		}
		s.reader = r
	}
	s.reader.Read(id-t.Groups[s.group].Start, s.buf)
	return s.buf, nil
}

// ---------------------------------------------------------------- values

type valuesOp struct {
	rows [][]evalFn
	pos  int
	buf  types.Row
}

func (v *valuesOp) Next() (types.Row, error) {
	if v.pos >= len(v.rows) {
		return nil, nil
	}
	row := v.rows[v.pos]
	v.pos++
	v.buf = v.buf[:0]
	for _, f := range row {
		val, err := f(nil)
		if err != nil {
			return nil, err
		}
		v.buf = append(v.buf, val)
	}
	return v.buf, nil
}

// ---------------------------------------------------------------- filter

type filterOp struct {
	ec    *Context
	input Operator
	pred  evalFn
	n     int
}

func (f *filterOp) Next() (types.Row, error) {
	for {
		row, err := f.input.Next()
		if row == nil || err != nil {
			return nil, err
		}
		f.n++
		if f.n%checkEvery == 0 {
			if err := f.ec.Check(); err != nil {
				return nil, err
			}
		}
		v, err := f.pred(row)
		if err != nil {
			return nil, err
		}
		if v.IsTrue() {
			return row, nil
		}
	}
}

// ---------------------------------------------------------------- project

type projectOp struct {
	input Operator
	exprs []evalFn
	buf   types.Row
}

func (p *projectOp) Next() (types.Row, error) {
	row, err := p.input.Next()
	if row == nil || err != nil {
		return nil, err
	}
	for i, f := range p.exprs {
		if p.buf[i], err = f(row); err != nil {
			return nil, err
		}
	}
	return p.buf, nil
}

// ---------------------------------------------------------------- limit

type limitOp struct {
	input  Operator
	offset int64
	count  int64 // < 0 = unlimited
	seen   int64
}

func (l *limitOp) Next() (types.Row, error) {
	if l.count >= 0 && l.seen >= l.count {
		return nil, nil
	}
	for l.offset > 0 {
		row, err := l.input.Next()
		if row == nil || err != nil {
			return nil, err
		}
		l.offset--
	}
	row, err := l.input.Next()
	if row == nil || err != nil {
		return nil, err
	}
	l.seen++
	return row, nil
}

// ---------------------------------------------------------------- distinct

// distinctOp streams rows whose full-row key has not been seen before.
type distinctOp struct {
	ec    *Context
	input Operator
	types []types.Type
	seen  map[string]struct{}
	key   []byte
	n     int
}

func (d *distinctOp) Next() (types.Row, error) {
	for {
		row, err := d.input.Next()
		if row == nil || err != nil {
			return nil, err
		}
		d.n++
		if d.n%checkEvery == 0 {
			if err := d.ec.Check(); err != nil {
				return nil, err
			}
		}
		d.key = d.key[:0]
		for i, v := range row {
			d.key = appendKey(d.key, v, d.types[i])
		}
		if _, ok := d.seen[string(d.key)]; ok {
			continue
		}
		d.seen[string(d.key)] = struct{}{}
		if err := d.ec.Mem.Reserve(int64(len(d.key)) + 48); err != nil {
			return nil, err
		}
		return row, nil
	}
}

// ---------------------------------------------------------------- sort

// sortKey is a compiled ORDER BY key.
type sortKey struct {
	index      int
	typ        types.Type
	desc       bool
	nullsFirst bool
}

func compareRows(keys []sortKey, a, b types.Row) int {
	for _, k := range keys {
		x, y := a[k.index], b[k.index]
		var c int
		switch {
		case x.Null && y.Null:
			continue
		case x.Null:
			if k.nullsFirst {
				return -1
			}
			return 1
		case y.Null:
			if k.nullsFirst {
				return 1
			}
			return -1
		}
		c = types.Compare(k.typ, x, k.typ, y)
		if c != 0 {
			if k.desc {
				return -c
			}
			return c
		}
	}
	return 0
}

type sortOp struct {
	ec    *Context
	input Operator
	keys  []sortKey
	limit int64 // ≥ 0: only the first limit rows are needed (top-N)
	rows  []types.Row
	pos   int
	done  bool
}

func (s *sortOp) Next() (types.Row, error) {
	if !s.done {
		s.done = true
		var err error
		if s.limit >= 0 {
			err = s.topN()
		} else {
			err = s.sortAll()
		}
		if err != nil {
			return nil, err
		}
	}
	if s.pos >= len(s.rows) {
		return nil, nil
	}
	r := s.rows[s.pos]
	s.rows[s.pos] = nil
	s.pos++
	return r, nil
}

func (s *sortOp) sortAll() error {
	for n := 0; ; n++ {
		row, err := s.input.Next()
		if err != nil {
			return err
		}
		if row == nil {
			break
		}
		if n%checkEvery == 0 {
			if err := s.ec.Check(); err != nil {
				return err
			}
		}
		cp := append(types.Row(nil), row...)
		if err := s.ec.Mem.Reserve(RowSize(cp)); err != nil {
			return err
		}
		s.rows = append(s.rows, cp)
	}
	sorted, err := sortStable(s.ec, s.keys, s.rows)
	s.rows = sorted
	return err
}

// sortAborted carries a cancellation out of a running sort.
type sortAborted struct{ err error }

// sortStable sorts rows by keys, keeping arrival order among equal rows. It
// uses pattern-defeating quicksort over row positions (O(n log n)) with the
// original position as the final tie-breaker. The sort checks for
// cancellation every checkEvery comparisons.
func sortStable(ec *Context, keys []sortKey, rows []types.Row) (out []types.Row, err error) {
	idx := make([]int32, len(rows))
	for i := range idx {
		idx[i] = int32(i)
	}
	defer func() {
		if r := recover(); r != nil {
			abort, ok := r.(sortAborted)
			if !ok {
				panic(r)
			}
			out, err = nil, abort.err
		}
	}()
	comparisons := 0
	slices.SortFunc(idx, func(a, b int32) int {
		if comparisons++; comparisons%checkEvery == 0 {
			if err := ec.Check(); err != nil {
				panic(sortAborted{err})
			}
		}
		if c := compareRows(keys, rows[a], rows[b]); c != 0 {
			return c
		}
		return int(a - b)
	})
	out = make([]types.Row, len(rows))
	for i, k := range idx {
		out[i] = rows[k]
	}
	return out, nil
}

// topHeap is a max-heap (by sort order, ties broken by arrival) holding the
// best N rows seen so far.
type topHeap struct {
	keys []sortKey
	rows []types.Row
	seq  []int
}

func (h *topHeap) Len() int { return len(h.rows) }
func (h *topHeap) Less(i, j int) bool {
	c := compareRows(h.keys, h.rows[i], h.rows[j])
	if c != 0 {
		return c > 0
	}
	return h.seq[i] > h.seq[j]
}
func (h *topHeap) Swap(i, j int) {
	h.rows[i], h.rows[j] = h.rows[j], h.rows[i]
	h.seq[i], h.seq[j] = h.seq[j], h.seq[i]
}
func (h *topHeap) Push(x any) { panic("unused") }
func (h *topHeap) Pop() any   { panic("unused") }

func (s *sortOp) topN() error {
	h := &topHeap{keys: s.keys}
	for n := 0; ; n++ {
		row, err := s.input.Next()
		if err != nil {
			return err
		}
		if row == nil {
			break
		}
		if n%checkEvery == 0 {
			if err := s.ec.Check(); err != nil {
				return err
			}
		}
		if int64(len(h.rows)) < s.limit {
			cp := append(types.Row(nil), row...)
			if err := s.ec.Mem.Reserve(RowSize(cp)); err != nil {
				return err
			}
			h.rows = append(h.rows, cp)
			h.seq = append(h.seq, n)
			if int64(len(h.rows)) == s.limit {
				heap.Init(h)
			}
			continue
		}
		if s.limit == 0 || compareRows(s.keys, row, h.rows[0]) >= 0 {
			continue
		}
		copy(h.rows[0], row)
		h.seq[0] = n
		heap.Fix(h, 0)
	}
	idx := make([]int, len(h.rows))
	for i := range idx {
		idx[i] = i
	}
	sort.Slice(idx, func(a, b int) bool {
		c := compareRows(s.keys, h.rows[idx[a]], h.rows[idx[b]])
		if c != 0 {
			return c < 0
		}
		return h.seq[idx[a]] < h.seq[idx[b]]
	})
	s.rows = make([]types.Row, len(idx))
	for i, k := range idx {
		s.rows[i] = h.rows[k]
	}
	return nil
}
