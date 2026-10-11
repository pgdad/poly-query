package exec

import (
	"polyquery/internal/native"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Native scan aggregation (option native: true). An aggregation without
// GROUP BY whose input is a table scan — possibly below filters that are
// entirely native (nfilter.go) and projections that only pass columns
// through — and whose aggregates all read scan columns directly is computed
// from the storage vectors, window by window, without materializing rows:
//
//   - COUNT(*): row count, pqk_bitmap_popcount of the filter bitmap, or
//     pqk_count_i64 when the filter is a single comparison;
//   - COUNT(col): popcount of the validity bitmap (ANDed with the filter
//     bitmap by pqk_bitmap_and);
//   - SUM/AVG of INT64/DECIMAL: pqk_sum_i64 under that mask; when it
//     reports overflow the window is summed exactly in Go (128-bit/big
//     sums), so overflow is decided on the exact total as without kernels;
//   - MIN/MAX of int-class columns: pqk_minmax_i64; of FLOAT64:
//     pqk_minmax_f64 (exact; FLOAT64 values are finite).
//
// Partial results are folded into the regular aggregate states, so result
// computation (DECIMAL bounds, AVG rounding, overflow errors) is shared
// with the other execution paths. With threads > 1 morsels are aggregated
// by parallel workers into private states that are merged (all supported
// aggregates are exact, hence order independent).

// nativeAggWindow is the maximum number of rows per kernel call.
const nativeAggWindow = 1 << 16

// naggCall is one aggregate of a native scan aggregation.
type naggCall struct {
	fn  plan.AggFunc
	ord int // table ordinal of the argument (-1 for COUNT(*))
	cls vclass
}

// naggPlan is a native scan aggregation.
type naggPlan struct {
	node   *physical.HashAggregate
	scan   *physical.TableScan
	filter *npred // nil: no filter
	calls  []naggCall
}

// planNativeAggregate checks whether x can run as a native scan
// aggregation.
func planNativeAggregate(ec *Context, x *physical.HashAggregate) (*naggPlan, bool) {
	if ec.Native == nil || len(x.Keys) > 0 {
		return nil, false
	}
	// Walk down to the scan, mapping columns through projections.
	alias := map[plan.ColumnID]plan.ColumnID{}
	resolve := func(id plan.ColumnID) plan.ColumnID {
		for {
			to, ok := alias[id]
			if !ok {
				return id
			}
			id = to
		}
	}
	var preds []plan.Expr
	n := x.Input
	var scan *physical.TableScan
	for scan == nil {
		switch y := n.(type) {
		case *physical.TableScan:
			scan = y
		case *physical.Filter:
			preds = append(preds, y.Pred)
			n = y.Input
		case *physical.Project:
			for i, e := range y.Exprs {
				ref, ok := e.(*plan.ColumnRef)
				if !ok {
					return nil, false
				}
				if y.Cols[i].ID != ref.ID {
					alias[y.Cols[i].ID] = ref.ID
				}
			}
			n = y.Input
		default:
			return nil, false
		}
	}
	if !columnGroups(scan.Table) {
		return nil, false
	}
	p := &naggPlan{node: x, scan: scan}
	comp := newNativeCompiler(ec, scan)
	for id := range alias {
		if ord, ok := comp.ords[resolve(id)]; ok {
			comp.ords[id] = ord
		}
	}
	var kids []*npred
	for _, pred := range preds {
		root, rest := comp.split(pred)
		if root == nil || len(rest) > 0 {
			return nil, false
		}
		kids = append(kids, root)
	}
	switch len(kids) {
	case 0:
	case 1:
		p.filter = kids[0]
	default:
		p.filter = &npred{kind: nAnd, kids: kids}
	}
	for _, c := range x.Aggs {
		call := naggCall{fn: c.Func, ord: -1}
		if c.Func != plan.AggCountStar {
			ref, ok := c.Arg.(*plan.ColumnRef)
			if !ok {
				return nil, false
			}
			ord, ok := comp.ords[ref.ID]
			if !ok {
				return nil, false
			}
			call.ord, call.cls = ord, classOf(ref.T)
			t := ref.T
			switch c.Func {
			case plan.AggCount:
				if c.Distinct {
					return nil, false
				}
			case plan.AggSum, plan.AggAvg:
				if c.Distinct || (t.Kind != types.KindInt64 && t.Kind != types.KindDecimal) {
					return nil, false
				}
			case plan.AggMin, plan.AggMax:
				if !intClass(t) && t.Kind != types.KindFloat64 {
					return nil, false
				}
			}
		}
		p.calls = append(p.calls, call)
	}
	return p, true
}

// columnGroups reports whether every row group of t is column-oriented.
func columnGroups(t *storage.Table) bool {
	for _, g := range t.Groups {
		if g.Tuples() != nil {
			return false
		}
	}
	return true
}

// naggWorker aggregates windows into a private aggregate table.
type naggWorker struct {
	ec     *Context
	lib    *native.Lib
	p      *naggPlan
	table  *aggTable
	filter *nfilter
	// countOnly is set when every aggregate is COUNT(*) and there is a
	// filter.
	countOnly bool
	fbits     []byte
	mask      []byte
	valid     []byte
}

func newNaggWorker(ec *Context, p *naggPlan) (*naggWorker, error) {
	w := &naggWorker{ec: ec, lib: ec.Native, p: p, table: newAggTable(ec, nil, p.node.Aggs)}
	if p.filter != nil {
		w.filter = newNFilter(ec.Native, p.filter)
		w.countOnly = true
		for _, c := range p.calls {
			w.countOnly = w.countOnly && c.fn == plan.AggCountStar
		}
	}
	_, err := w.table.newGroup(types.Row{}, 0)
	return w, err
}

// rangeRows aggregates the rows [start, end) of a row group.
func (w *naggWorker) rangeRows(r scanRange) error {
	g := w.p.scan.Table.Groups[r.group]
	for lo := r.start; lo < r.end; lo += nativeAggWindow {
		if err := w.ec.Check(); err != nil {
			return err
		}
		if err := w.window(g, lo, min(lo+nativeAggWindow, r.end)); err != nil {
			return err
		}
	}
	return nil
}

func (w *naggWorker) window(g *storage.RowGroup, lo, hi int) error {
	n := hi - lo
	var fb []byte // filter bitmap (nil: every row)
	rows := n     // number of qualifying rows
	if w.countOnly && w.p.filter.kind == nConst {
		// COUNT(*) … WHERE <one comparison>: count without a bitmap.
		f := w.p.filter
		c, err := w.filter.column(g, f.ord, lo, hi)
		if err != nil {
			return err
		}
		for _, s := range w.table.states {
			s.(*countState).n[0] += int64(w.lib.CountI64(c.ints, c.valid, f.op, f.a, f.b))
		}
		return nil
	}
	if w.filter != nil {
		var err error
		if fb, err = w.filter.bitmap(g, lo, hi, &w.fbits); err != nil {
			return err
		}
		if rows = w.lib.Popcount(fb, n); rows == 0 {
			return nil
		}
	}
	for k, c := range w.p.calls {
		state := w.table.states[k]
		if c.fn == plan.AggCountStar {
			state.(*countState).n[0] += int64(rows)
			continue
		}
		v, err := g.Column(c.ord)
		if err != nil {
			return err
		}
		mask := fb
		if v.Valid != nil {
			vb := validWindow(v.Valid, lo, n, &w.valid)
			if fb == nil {
				mask = vb
			} else {
				w.mask = grow(w.mask, len(fb))
				w.lib.BitmapAnd(fb, vb, w.mask)
				mask = w.mask
			}
		}
		count := func() int64 {
			if v.Valid == nil {
				return int64(rows)
			}
			return int64(w.lib.Popcount(mask, n))
		}
		switch s := state.(type) {
		case *countState:
			s.n[0] += count()
		case *exactSumState:
			vals := v.Ints[lo:hi]
			if sum, ok := w.lib.SumI64(vals, mask); ok {
				s.sums[0].Add(sum)
			} else {
				exactMaskedSum(&s.sums[0], vals, mask)
			}
			s.n[0] += count()
		case *intMinMax:
			cnt, mn, mx := w.lib.MinMaxI64(v.Ints[lo:hi], mask)
			if cnt > 0 {
				s.fold(mn, mx)
			}
		case *floatMinMax:
			cnt, mn, mx := w.lib.MinMaxF64(v.Floats[lo:hi], mask)
			if cnt > 0 {
				s.fold(mn, mx)
			}
		}
	}
	return nil
}

// exactMaskedSum adds the values selected by mask (nil: all) exactly.
func exactMaskedSum(sum *types.BigDecimalSum, vals []int64, mask []byte) {
	for i, x := range vals {
		if mask == nil || mask[i>>3]&(1<<(i&7)) != 0 {
			if !sum.AddSmall(x) {
				sum.Add(x)
			}
		}
	}
}

// fold merges the minimum and maximum of a window into group 0.
func (s *intMinMax) fold(mn, mx int64) {
	x := mx
	if s.sign < 0 {
		x = mn
	}
	if !s.any[0] || (s.sign < 0 && x < s.best[0]) || (s.sign > 0 && x > s.best[0]) {
		s.best[0], s.any[0] = x, true
	}
}

func (s *floatMinMax) fold(mn, mx float64) {
	x := mx
	if s.sign < 0 {
		x = mn
	}
	if !s.any[0] || (s.sign < 0 && x < s.best[0]) || (s.sign > 0 && x > s.best[0]) {
		s.best[0], s.any[0] = x, true
	}
}

// run computes the aggregation's single output row.
func (p *naggPlan) run(ec *Context) ([]types.Row, error) {
	var ranges []scanRange
	if ec.Threads > 1 && ec.serial == 0 {
		ranges = morsels(ec, p.scan)
	}
	if len(ranges) < 2 {
		w, err := newNaggWorker(ec, p)
		if err != nil {
			return nil, err
		}
		src := &groupRanges{table: p.scan.Table, filters: p.scan.Filters}
		for r, ok := src.next(); ok; r, ok = src.next() {
			if err := w.rangeRows(r); err != nil {
				return nil, err
			}
		}
		return w.table.rows()
	}
	nw := workers(ec, len(ranges))
	ws := make([]*naggWorker, nw)
	for i := range ws {
		w, err := newNaggWorker(ec, p)
		if err != nil {
			return nil, err
		}
		ws[i] = w
	}
	if err := runMorsels(ec, ranges, nw, func(w, i int) error { return ws[w].rangeRows(ranges[i]) }); err != nil {
		return nil, err
	}
	t := ws[0].table
	for _, o := range ws[1:] {
		for k, s := range t.states {
			s.merge(0, o.table.states[k], 0)
		}
	}
	return t.rows()
}

// nativeAggOp is the operator of a native scan aggregation (row and batch
// interfaces); it computes its row on first use.
type nativeAggOp struct {
	ec   *Context
	p    *naggPlan
	rows *replayOp
	out  BatchOperator
}

func (a *nativeAggOp) compute() error {
	if a.rows != nil {
		return nil
	}
	rows, err := a.p.run(a.ec)
	if err != nil {
		return err
	}
	a.rows = &replayOp{rows: rows}
	return nil
}

func (a *nativeAggOp) Next() (types.Row, error) {
	if err := a.compute(); err != nil {
		return nil, err
	}
	return a.rows.Next()
}

func (a *nativeAggOp) NextBatch() (*Batch, error) {
	if err := a.compute(); err != nil {
		return nil, err
	}
	if a.out == nil {
		a.out = newBatchWriter(a.rows, schemaTypes(a.p.node.Schema()))
	}
	return a.out.NextBatch()
}
