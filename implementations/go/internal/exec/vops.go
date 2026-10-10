package exec

import (
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// ---------------------------------------------------------------- scan ranges

// scanRange is a range of rows [Start, End) of one row group; Seq orders
// ranges in table order.
type scanRange struct {
	group      int
	start, end int
	seq        int
}

// rangeSource yields the ranges a scan reads.
type rangeSource interface {
	next() (scanRange, bool)
}

// groupRanges yields every row group not excluded by the scan's filters.
type groupRanges struct {
	table   *storage.Table
	filters []physical.ColumnFilter
	group   int
}

func (s *groupRanges) next() (scanRange, bool) {
	for s.group < len(s.table.Groups) {
		g := s.table.Groups[s.group]
		s.group++
		if !skipGroup(g, s.filters) {
			return scanRange{group: s.group - 1, start: 0, end: g.Rows, seq: s.group - 1}, true
		}
	}
	return scanRange{}, false
}

func skipGroup(g *storage.RowGroup, filters []physical.ColumnFilter) bool {
	for i := range filters {
		f := &filters[i]
		if f.Skips(g.Stats[f.Ord], g.Rows) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- vectorized scan

// vscanOp reads the selected columns of a table as batches. Column-layout
// vectors are sliced without copying (dictionary-encoded STRING chunks
// stay encoded); row-layout groups are gathered into owned vectors.
type vscanOp struct {
	ec      *Context
	table   *storage.Table
	ords    []int
	classes []vclass
	src     rangeSource

	cur     scanRange
	active  bool
	pos     int
	vecs    []*storage.Vector // column layout
	tuples  []types.Row       // row layout
	cols    []Vec
	nulls   [][]bool
	decoded [][]string // owned decode buffers of dictionary columns
	wasDict []bool
	bufs    []vecBuf // row layout
	batch   Batch
}

func newVScan(ec *Context, x *physical.TableScan, src rangeSource) *vscanOp {
	s := &vscanOp{ec: ec, table: x.Table, ords: x.Ords, src: src}
	if s.src == nil {
		s.src = &groupRanges{table: x.Table, filters: x.Filters}
	}
	n := len(x.Ords)
	for _, o := range x.Ords {
		s.classes = append(s.classes, classOf(x.Table.Columns[o].Type))
	}
	s.cols = make([]Vec, n)
	s.nulls = make([][]bool, n)
	s.decoded = make([][]string, n)
	s.wasDict = make([]bool, n)
	s.bufs = make([]vecBuf, n)
	s.batch.Cols = make([]*Vec, n)
	return s
}

func (s *vscanOp) open(r scanRange) error {
	g := s.table.Groups[r.group]
	s.cur, s.pos, s.active = r, r.start, true
	if t := g.Tuples(); t != nil {
		s.tuples, s.vecs = t, nil
		return nil
	}
	s.tuples = nil
	s.vecs = s.vecs[:0]
	for _, o := range s.ords {
		v, err := g.Column(o)
		if err != nil {
			return err
		}
		s.vecs = append(s.vecs, v)
	}
	return nil
}

func (s *vscanOp) NextBatch() (*Batch, error) {
	for !s.active || s.pos >= s.cur.end {
		r, ok := s.src.next()
		if !ok {
			return nil, nil
		}
		if err := s.ec.Check(); err != nil {
			return nil, err
		}
		if err := s.open(r); err != nil {
			return nil, err
		}
	}
	lo := s.pos
	hi := min(lo+BatchSize, s.cur.end)
	s.pos = hi
	n := hi - lo
	if s.tuples != nil {
		s.gatherTuples(lo, hi)
	} else {
		for k, v := range s.vecs {
			s.sliceColumn(k, v, lo, hi)
		}
	}
	s.batch.N, s.batch.Sel = n, nil
	return &s.batch, nil
}

func (s *vscanOp) sliceColumn(k int, v *storage.Vector, lo, hi int) {
	c := &s.cols[k]
	if s.wasDict[k] && c.Dict == nil && c.S != nil {
		s.decoded[k] = c.S // keep the buffer a consumer decoded into
	}
	*c = Vec{}
	switch s.classes[k] {
	case vInt:
		c.I = v.Ints[lo:hi]
	case vFloat:
		c.F = v.Floats[lo:hi]
	default:
		if v.Dict != nil {
			c.Dict, c.Codes, c.S = v.Dict, v.Codes[lo:hi], s.decoded[k][:0]
			s.wasDict[k] = true
		} else {
			c.S = v.Strs[lo:hi]
			s.wasDict[k] = false
		}
	}
	if v.Valid != nil {
		nulls := grow(s.nulls[k], hi-lo)
		s.nulls[k] = nulls
		valid := v.Valid
		for i := range nulls {
			j := lo + i
			nulls[i] = valid[j>>6]&(1<<uint(j&63)) == 0
		}
		c.Nulls = nulls
	}
	s.batch.Cols[k] = c
}

func (s *vscanOp) gatherTuples(lo, hi int) {
	n := hi - lo
	for k, o := range s.ords {
		out := s.bufs[k].reset(n, s.classes[k])
		var nulls []bool
		for i := 0; i < n; i++ {
			v := s.tuples[lo+i][o]
			if v.Null {
				if nulls == nil {
					nulls = s.bufs[k].withNulls(n)
				}
				nulls[i] = true
				continue
			}
			switch s.classes[k] {
			case vInt:
				out.I[i] = v.I
			case vFloat:
				out.F[i] = v.F
			default:
				out.S[i] = v.S
			}
		}
		s.batch.Cols[k] = out
	}
}

// ---------------------------------------------------------------- expression sets

// exprSet evaluates expressions over batches: vectorized, and — when that
// fails — row by row with the row-mode evaluators of the same expressions,
// which determines the exact result and error.
type exprSet struct {
	vec     []vexpr
	row     []evalFn
	classes []vclass // input column classes
	out     []vclass // result classes
	buf     types.Row
}

func newExprSet(ec *Context, cols []plan.Column, exprs []plan.Expr) (*exprSet, error) {
	vc := newVCompiler(ec, cols)
	s := &exprSet{classes: vc.classes, buf: make(types.Row, len(cols))}
	for _, e := range exprs {
		v, err := vc.compile(e)
		if err != nil {
			return nil, err
		}
		s.vec = append(s.vec, v)
		s.out = append(s.out, classOf(e.Type()))
	}
	var err error
	if s.row, err = compileAll(ec, vc.lay, exprs); err != nil {
		return nil, err
	}
	return s, nil
}

// eval evaluates all expressions vectorized into dst.
func (s *exprSet) eval(b *Batch, sel []int32, dst []*Vec) error {
	for k, e := range s.vec {
		v, err := e.eval(b, sel)
		if err != nil {
			return err
		}
		dst[k] = v
	}
	return nil
}

// row materializes row i of b.
func (s *exprSet) loadRow(b *Batch, i int) types.Row {
	batchRow(b, i, s.classes, s.buf)
	return s.buf
}

// evalRow evaluates all expressions for row i of b row-at-a-time.
func (s *exprSet) evalRow(b *Batch, i int, dst types.Row) error {
	row := s.loadRow(b, i)
	for k, f := range s.row {
		v, err := f(row)
		if err != nil {
			return err
		}
		dst[k] = v
	}
	return nil
}

// firstError evaluates the expressions row by row over the active rows of
// b and returns the first error (nil if row-at-a-time evaluation
// succeeds).
func (s *exprSet) firstError(b *Batch) error {
	dst := make(types.Row, len(s.row))
	n := b.Len()
	for k := 0; k < n; k++ {
		i := k
		if b.Sel != nil {
			i = int(b.Sel[k])
		}
		if err := s.evalRow(b, i, dst); err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------- filter

type vfilterOp struct {
	ec      *Context
	input   BatchOperator
	pred    *exprSet
	res     []*Vec
	sel     []int32
	out     Batch
	pending error
}

func (f *vfilterOp) NextBatch() (*Batch, error) {
	if f.pending != nil {
		err := f.pending
		f.pending = nil
		return nil, err
	}
	for {
		b, err := f.input.NextBatch()
		if b == nil || err != nil {
			return nil, err
		}
		if err := f.ec.Check(); err != nil {
			return nil, err
		}
		sel := f.sel[:0]
		if err := f.pred.eval(b, b.Sel, f.res); err != nil {
			sel, f.pending = f.filterRows(b, sel)
		} else {
			v := f.res[0]
			if v.Nulls == nil {
				if b.Sel == nil {
					for i, x := range v.I[:b.N] {
						if x != 0 {
							sel = append(sel, int32(i))
						}
					}
				} else {
					for _, i := range b.Sel {
						if v.I[i] != 0 {
							sel = append(sel, i)
						}
					}
				}
			} else {
				forActive(b.N, b.Sel, func(i int) {
					if !v.Nulls[i] && v.I[i] != 0 {
						sel = append(sel, int32(i))
					}
				})
			}
		}
		f.sel = sel
		if len(sel) == 0 {
			if f.pending != nil {
				err := f.pending
				f.pending = nil
				return nil, err
			}
			continue
		}
		f.out.N, f.out.Cols, f.out.Sel = b.N, b.Cols, sel
		if b.Sel == nil && len(sel) == b.N {
			f.out.Sel = nil
		}
		return &f.out, nil
	}
}

// filterRows evaluates the predicate row by row, stopping at the first
// error (returned as pending).
func (f *vfilterOp) filterRows(b *Batch, sel []int32) ([]int32, error) {
	var v types.Row = make(types.Row, 1)
	n := b.Len()
	for k := 0; k < n; k++ {
		i := k
		if b.Sel != nil {
			i = int(b.Sel[k])
		}
		if err := f.pred.evalRow(b, i, v); err != nil {
			return sel, err
		}
		if v[0].IsTrue() {
			sel = append(sel, int32(i))
		}
	}
	return sel, nil
}

// ---------------------------------------------------------------- project

type vprojectOp struct {
	ec      *Context
	input   BatchOperator
	exprs   *exprSet
	out     Batch
	bufs    []vecBuf // row-wise results after a vectorized failure
	sel     []int32
	pending error
}

func (p *vprojectOp) NextBatch() (*Batch, error) {
	if p.pending != nil {
		err := p.pending
		p.pending = nil
		return nil, err
	}
	b, err := p.input.NextBatch()
	if b == nil || err != nil {
		return nil, err
	}
	p.out.N, p.out.Sel = b.N, b.Sel
	if err := p.exprs.eval(b, b.Sel, p.out.Cols); err == nil {
		return &p.out, nil
	}
	return p.projectRows(b)
}

// projectRows computes the batch row by row up to the first error, which
// is reported after the rows before it.
func (p *vprojectOp) projectRows(b *Batch) (*Batch, error) {
	for k := range p.out.Cols {
		p.out.Cols[k] = p.bufs[k].reset(b.N, p.exprs.out[k])
		p.bufs[k].withNulls(b.N)
	}
	vals := make(types.Row, len(p.out.Cols))
	sel := p.sel[:0]
	n := b.Len()
	for k := 0; k < n; k++ {
		i := k
		if b.Sel != nil {
			i = int(b.Sel[k])
		}
		if err := p.exprs.evalRow(b, i, vals); err != nil {
			p.pending = err
			break
		}
		for c, v := range vals {
			p.out.Cols[c].set(i, v, p.exprs.out[c])
		}
		sel = append(sel, int32(i))
	}
	p.sel = sel
	if len(sel) == 0 {
		err := p.pending
		p.pending = nil
		return nil, err
	}
	p.out.Sel = sel
	return &p.out, nil
}

// ---------------------------------------------------------------- limit

type vlimitOp struct {
	input  BatchOperator
	offset int64
	count  int64 // < 0 = unlimited
	seen   int64
	sel    []int32
	out    Batch
}

func (l *vlimitOp) NextBatch() (*Batch, error) {
	for {
		if l.count >= 0 && l.seen >= l.count {
			return nil, nil
		}
		b, err := l.input.NextBatch()
		if b == nil || err != nil {
			return nil, err
		}
		n := int64(b.Len())
		skip := min(l.offset, n)
		l.offset -= skip
		take := n - skip
		if l.count >= 0 {
			take = min(take, l.count-l.seen)
		}
		if take <= 0 {
			continue
		}
		l.seen += take
		if skip == 0 && take == n {
			return b, nil
		}
		sel := l.sel[:0]
		for k := skip; k < skip+take; k++ {
			i := int32(k)
			if b.Sel != nil {
				i = b.Sel[k]
			}
			sel = append(sel, i)
		}
		l.sel = sel
		l.out.N, l.out.Cols, l.out.Sel = b.N, b.Cols, sel
		return &l.out, nil
	}
}

// ---------------------------------------------------------------- distinct

type vdistinctOp struct {
	ec      *Context
	input   BatchOperator
	types   []types.Type
	classes []vclass
	seen    map[string]struct{}
	key     []byte
	sel     []int32
	out     Batch
}

func (d *vdistinctOp) NextBatch() (*Batch, error) {
	for {
		b, err := d.input.NextBatch()
		if b == nil || err != nil {
			return nil, err
		}
		if err := d.ec.Check(); err != nil {
			return nil, err
		}
		sel := d.sel[:0]
		var memErr error
		forActive(b.N, b.Sel, func(i int) {
			d.key = d.key[:0]
			for k, v := range b.Cols {
				d.key = appendKey(d.key, v.value(i, d.classes[k]), d.types[k])
			}
			if _, ok := d.seen[string(d.key)]; ok {
				return
			}
			d.seen[string(d.key)] = struct{}{}
			if memErr == nil {
				memErr = d.ec.Mem.Reserve(int64(len(d.key)) + 48)
			}
			sel = append(sel, int32(i))
		})
		if memErr != nil {
			return nil, memErr
		}
		d.sel = sel
		if len(sel) == 0 {
			continue
		}
		d.out.N, d.out.Cols, d.out.Sel = b.N, b.Cols, sel
		return &d.out, nil
	}
}

// ---------------------------------------------------------------- builder

func schemaTypes(cols []plan.Column) []types.Type {
	ts := make([]types.Type, len(cols))
	for i, c := range cols {
		ts[i] = c.Type
	}
	return ts
}

// BuildBatch turns a physical plan node into a vectorized operator tree.
// Nodes without a batch implementation run row-at-a-time over batch
// inputs (through adapters).
func BuildBatch(ec *Context, n physical.Node) (BatchOperator, error) {
	switch x := n.(type) {
	case *physical.TableScan:
		if op, ok, err := parallelBatchPipeline(ec, x); ok || err != nil {
			return op, err
		}
		return newVScan(ec, x, nil), nil
	case *physical.Filter:
		if op, ok, err := parallelBatchPipeline(ec, x); ok || err != nil {
			return op, err
		}
		return buildVFilter(ec, x, nil)
	case *physical.Project:
		if op, ok, err := parallelBatchPipeline(ec, x); ok || err != nil {
			return op, err
		}
		return buildVProject(ec, x, nil)
	case *physical.HashAggregate:
		return buildVAggregate(ec, x)
	case *physical.HashJoin:
		return buildVHashJoin(ec, x)
	case *physical.Limit:
		count, err := limitValue(ec, x.Count, -1)
		if err != nil {
			return nil, err
		}
		offset, err := limitValue(ec, x.Offset, 0)
		if err != nil {
			return nil, err
		}
		in, err := BuildBatch(ec, x.Input)
		if err != nil {
			return nil, err
		}
		return &vlimitOp{input: in, offset: offset, count: count}, nil
	case *physical.HashDistinct:
		in, err := BuildBatch(ec, x.Input)
		if err != nil {
			return nil, err
		}
		d := &vdistinctOp{ec: ec, input: in, types: schemaTypes(x.Schema()), seen: map[string]struct{}{}}
		for _, t := range d.types {
			d.classes = append(d.classes, classOf(t))
		}
		return d, nil
	}
	// Row-at-a-time island (sort, nested-loop and merge joins, index scans,
	// VALUES, correlated-subquery nodes).
	op, err := build(ec, n, true)
	if err != nil {
		return nil, err
	}
	return newBatchWriter(op, schemaTypes(n.Schema())), nil
}

// buildVFilter builds a filter; leaf (if non-nil) builds the operator of
// the scan at the bottom of a parallel pipeline.
func buildVFilter(ec *Context, x *physical.Filter, leaf func(physical.Node) (BatchOperator, error)) (BatchOperator, error) {
	in, err := buildPipelineInput(ec, x.Input, leaf)
	if err != nil {
		return nil, err
	}
	pred, err := newExprSet(ec, x.Input.Schema(), []plan.Expr{x.Pred})
	if err != nil {
		return nil, err
	}
	return &vfilterOp{ec: ec, input: in, pred: pred, res: make([]*Vec, 1)}, nil
}

func buildVProject(ec *Context, x *physical.Project, leaf func(physical.Node) (BatchOperator, error)) (BatchOperator, error) {
	in, err := buildPipelineInput(ec, x.Input, leaf)
	if err != nil {
		return nil, err
	}
	exprs, err := newExprSet(ec, x.Input.Schema(), x.Exprs)
	if err != nil {
		return nil, err
	}
	p := &vprojectOp{ec: ec, input: in, exprs: exprs, bufs: make([]vecBuf, len(x.Exprs))}
	p.out.Cols = make([]*Vec, len(x.Exprs))
	return p, nil
}

func buildPipelineInput(ec *Context, n physical.Node, leaf func(physical.Node) (BatchOperator, error)) (BatchOperator, error) {
	if leaf == nil {
		return BuildBatch(ec, n)
	}
	switch x := n.(type) {
	case *physical.Filter:
		return buildVFilter(ec, x, leaf)
	case *physical.Project:
		return buildVProject(ec, x, leaf)
	}
	return leaf(n)
}
