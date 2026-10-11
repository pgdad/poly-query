package exec

import (
	"math"
	"sync"
	"sync/atomic"

	"polyquery/internal/errs"
	"polyquery/internal/native"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Intra-query parallelism (option "threads"): morsel-driven execution of
// pipelines — a table scan with the filters and projections directly above
// it. The scan's row groups are cut into morsels (row ranges); worker
// goroutines, each with a private instance of the pipeline, take morsels
// in table order from a shared counter.
//
//   - Parallel scans gather the workers' output per morsel and return it in
//     morsel order, so results (and errors) are exactly those of a serial
//     scan; a bounded window of morsels in flight limits buffering.
//   - Parallel aggregation folds each worker's morsels into a private
//     partial hash table; the partial tables are merged at the end and
//     groups are ordered by the position of their first row, again as in
//     serial execution. If a morsel fails, the error of the first failing
//     morsel (in table order) is reported.

// DefaultMorselRows is the number of rows per morsel.
const DefaultMorselRows = 16384

// singleRange is a range source yielding one range (set per morsel).
type singleRange struct {
	r    scanRange
	done bool
}

func (s *singleRange) set(r scanRange) { s.r, s.done = r, false }

func (s *singleRange) next() (scanRange, bool) {
	if s.done {
		return scanRange{}, false
	}
	s.done = true
	return s.r, true
}

// morsels splits the ranges of a scan into morsels.
func morsels(ec *Context, scan *physical.TableScan) []scanRange {
	size := ec.MorselRows
	if size <= 0 {
		size = DefaultMorselRows
	}
	var out []scanRange
	src := &groupRanges{table: scan.Table, filters: scan.Filters}
	for {
		r, ok := src.next()
		if !ok {
			return out
		}
		for lo := r.start; lo < r.end; lo += size {
			out = append(out, scanRange{group: r.group, start: lo, end: min(lo+size, r.end), seq: len(out)})
		}
	}
}

// parallelSafe reports whether an expression can be evaluated by parallel
// workers: no subqueries (their caches are per query), no PQ_SLEEP and no
// references outside the input (outer references of correlated
// subqueries).
func parallelSafe(e plan.Expr, input map[plan.ColumnID]bool) bool {
	ok := true
	plan.Walk(e, func(x plan.Expr) {
		switch y := x.(type) {
		case *plan.Subquery:
			ok = false
		case *plan.Func:
			if y.Name == "PQ_SLEEP" {
				ok = false
			}
		case *plan.ColumnRef:
			if !input[y.ID] {
				ok = false
			}
		}
	})
	return ok
}

func columnIDs(cols []plan.Column) map[plan.ColumnID]bool {
	m := make(map[plan.ColumnID]bool, len(cols))
	for _, c := range cols {
		m[c.ID] = true
	}
	return m
}

// pipelineScan returns the table scan at the bottom of a pipeline: a
// chain of filters, projections and hash join probes over a scan, whose
// expressions are parallel safe. (The build sides of the joins are
// computed once and shared; they must not evaluate subqueries either,
// since they are consumed by a worker.)
func pipelineScan(n physical.Node) (*physical.TableScan, bool) {
	switch x := n.(type) {
	case *physical.TableScan:
		return x, true
	case *physical.Filter:
		if !parallelSafe(x.Pred, columnIDs(x.Input.Schema())) {
			return nil, false
		}
		return pipelineScan(x.Input)
	case *physical.Project:
		ids := columnIDs(x.Input.Schema())
		for _, e := range x.Exprs {
			if !parallelSafe(e, ids) {
				return nil, false
			}
		}
		return pipelineScan(x.Input)
	case *physical.HashJoin:
		ids := columnIDs(x.Schema())
		for _, e := range physical.Exprs(x) {
			if !parallelSafe(e, ids) {
				return nil, false
			}
		}
		build, probe, _, _ := buildSide(x)
		if !subtreeParallelSafe(build) {
			return nil, false
		}
		return pipelineScan(probe)
	}
	return nil, false
}

// subtreeParallelSafe reports whether no operator of a subtree evaluates
// subqueries or PQ_SLEEP.
func subtreeParallelSafe(n physical.Node) bool {
	for _, e := range physical.Exprs(n) {
		ok := true
		plan.Walk(e, func(x plan.Expr) {
			switch y := x.(type) {
			case *plan.Subquery:
				ok = false
			case *plan.Func:
				if y.Name == "PQ_SLEEP" {
					ok = false
				}
			}
		})
		if !ok {
			return false
		}
	}
	for _, c := range n.Children() {
		if !subtreeParallelSafe(c) {
			return false
		}
	}
	return true
}

// parallelMorsels decides whether the pipeline rooted at n runs in
// parallel and returns its morsels.
func parallelMorsels(ec *Context, n physical.Node) ([]scanRange, bool) {
	if ec.Threads <= 1 || ec.serial > 0 {
		return nil, false
	}
	scan, ok := pipelineScan(n)
	if !ok {
		return nil, false
	}
	ms := morsels(ec, scan)
	return ms, len(ms) >= 2
}

// morselQueue hands out morsels in table order. Once a morsel failed,
// later morsels are not started.
type morselQueue struct {
	ranges []scanRange
	next   atomic.Int64
	failed atomic.Int64 // lowest failed morsel index (MaxInt64: none)
}

func newMorselQueue(ranges []scanRange) *morselQueue {
	q := &morselQueue{ranges: ranges}
	q.failed.Store(math.MaxInt64)
	return q
}

func (q *morselQueue) take() (int, bool) {
	i := q.next.Add(1) - 1
	if i >= int64(len(q.ranges)) || i > q.failed.Load() {
		return 0, false
	}
	return int(i), true
}

func (q *morselQueue) fail(i int) {
	for {
		cur := q.failed.Load()
		if int64(i) >= cur || q.failed.CompareAndSwap(cur, int64(i)) {
			return
		}
	}
}

func workers(ec *Context, morsels int) int { return min(ec.Threads, morsels) }

// ---------------------------------------------------------------- ordered gather

// gatherResult is the output of one morsel.
type gatherResult[T any] struct {
	items []T
	err   error
}

// gather runs a pipeline over morsels with parallel workers and returns
// the outputs in morsel order. run(w, r) executes worker w's pipeline
// instance over range r.
type gather[T any] struct {
	ec      *Context
	queue   *morselQueue
	run     func(w int, r scanRange) ([]T, error)
	nw      int
	slots   []chan gatherResult[T]
	window  chan struct{}
	started bool
	cur     int
	items   []T
	pos     int
	err     error
}

func newGather[T any](ec *Context, ranges []scanRange, nw int, run func(int, scanRange) ([]T, error)) *gather[T] {
	g := &gather[T]{ec: ec, queue: newMorselQueue(ranges), run: run, nw: nw}
	g.slots = make([]chan gatherResult[T], len(ranges))
	for i := range g.slots {
		g.slots[i] = make(chan gatherResult[T], 1)
	}
	g.window = make(chan struct{}, 2*nw)
	return g
}

func (g *gather[T]) start() {
	done := g.ec.Ctx.Done()
	for w := 0; w < g.nw; w++ {
		go func() {
			for {
				select {
				case g.window <- struct{}{}:
				case <-done:
					return
				}
				i, ok := g.queue.take()
				if !ok {
					return
				}
				items, err := g.run(w, g.queue.ranges[i])
				if err != nil {
					g.queue.fail(i)
				}
				g.slots[i] <- gatherResult[T]{items: items, err: err}
			}
		}()
	}
}

// next returns the next item in morsel order; ok is false at the end.
func (g *gather[T]) next() (item T, ok bool, err error) {
	if !g.started {
		g.started = true
		g.start()
	}
	for g.pos >= len(g.items) {
		var zero T
		if g.err != nil {
			err, g.err = g.err, nil
			return zero, false, err
		}
		if g.cur >= len(g.slots) {
			return zero, false, nil
		}
		select {
		case r := <-g.slots[g.cur]:
			g.cur++
			<-g.window
			g.items, g.pos, g.err = r.items, 0, r.err
			if r.err != nil {
				g.cur = len(g.slots) // nothing after a failed morsel
			}
		case <-g.ec.Ctx.Done():
			return zero, false, ContextError(g.ec.Ctx.Err())
		}
	}
	item = g.items[g.pos]
	g.pos++
	return item, true, nil
}

// gatherBatchOp is a parallel vectorized pipeline.
type gatherBatchOp struct{ g *gather[*Batch] }

func (o *gatherBatchOp) NextBatch() (*Batch, error) {
	b, ok, err := o.g.next()
	if !ok {
		return nil, err
	}
	return b, nil
}

// gatherRowOp is a parallel row-mode pipeline.
type gatherRowOp struct{ g *gather[types.Row] }

func (o *gatherRowOp) Next() (types.Row, error) {
	r, ok, err := o.g.next()
	if !ok {
		return nil, err
	}
	return r, nil
}

// batchPipelines builds one vectorized pipeline instance per worker, each
// reading from its own single-range source; hash join builds are shared.
func batchPipelines(ec *Context, n physical.Node, nw int) ([]BatchOperator, []*singleRange, error) {
	ops := make([]BatchOperator, nw)
	srcs := make([]*singleRange, nw)
	joins := map[*physical.HashJoin]*joinBuild{}
	for w := range ops {
		src := &singleRange{done: true}
		pc := &pipelineCtx{joins: joins, leaf: func(m *physical.TableScan) (BatchOperator, error) {
			return newVScan(ec, m, src), nil
		}}
		op, err := buildPipelineInput(ec, n, pc)
		if err != nil {
			return nil, nil, err
		}
		ops[w], srcs[w] = op, src
	}
	return ops, srcs, nil
}

// rowPipelines builds one row-mode pipeline instance per worker.
func rowPipelines(ec *Context, n physical.Node, nw int) ([]Operator, []*singleRange, error) {
	ops := make([]Operator, nw)
	srcs := make([]*singleRange, nw)
	joins := map[*physical.HashJoin]*rowJoinBuild{}
	for w := range ops {
		src := &singleRange{done: true}
		pc := &pipelineCtx{rowJoins: joins, rowLeaf: func(m *physical.TableScan) Operator {
			return newScan(ec, m, src)
		}}
		op, err := rowPipeline(ec, n, pc)
		if err != nil {
			return nil, nil, err
		}
		ops[w], srcs[w] = op, src
	}
	return ops, srcs, nil
}

// rowPipeline builds the row operators of a pipeline instance.
func rowPipeline(ec *Context, n physical.Node, pc *pipelineCtx) (Operator, error) {
	switch x := n.(type) {
	case *physical.TableScan:
		return pc.rowLeaf(x), nil
	case *physical.Filter:
		if scan, root, rest, ok := nativeScanFilter(ec, x); ok {
			if s, isScan := pc.rowLeaf(scan).(*scanOp); isScan {
				return nativeRowFilter(ec, x, s, root, rest)
			}
		}
		in, err := rowPipeline(ec, x.Input, pc)
		if err != nil {
			return nil, err
		}
		return newFilterOp(ec, in, x.Input.Schema(), x.Pred)
	case *physical.Project:
		in, err := rowPipeline(ec, x.Input, pc)
		if err != nil {
			return nil, err
		}
		fns, err := compileAll(ec, layoutOf(x.Input.Schema()), x.Exprs)
		if err != nil {
			return nil, err
		}
		return &projectOp{input: in, exprs: fns, buf: make(types.Row, len(fns))}, nil
	case *physical.HashJoin:
		shared, err := pc.rowJoinBuild(ec, x)
		if err != nil {
			return nil, err
		}
		_, probeNode, _, _ := buildSide(x)
		probe, err := rowPipeline(ec, probeNode, pc)
		if err != nil {
			return nil, err
		}
		return newHashJoinProbe(ec, x, shared, probe)
	}
	return nil, errs.New(errs.InternalError, "%T is not a pipeline operator", n)
}

// parallelBatchPipeline builds a parallel scan pipeline for n if
// parallelism applies (ok reports whether it does).
func parallelBatchPipeline(ec *Context, n physical.Node) (BatchOperator, bool, error) {
	ranges, ok := parallelMorsels(ec, n)
	if !ok {
		return nil, false, nil
	}
	nw := workers(ec, len(ranges))
	ops, srcs, err := batchPipelines(ec, n, nw)
	if err != nil {
		return nil, true, err
	}
	classes := make([]vclass, 0, len(n.Schema()))
	for _, c := range n.Schema() {
		classes = append(classes, classOf(c.Type))
	}
	run := func(w int, r scanRange) ([]*Batch, error) {
		srcs[w].set(r)
		var out []*Batch
		for {
			b, err := ops[w].NextBatch()
			if b == nil || err != nil {
				return out, err
			}
			out = append(out, compactBatch(b, classes, ec.Native))
		}
	}
	return &gatherBatchOp{g: newGather(ec, ranges, nw, run)}, true, nil
}

// parallelRowPipeline is the row-mode counterpart of parallelBatchPipeline.
func parallelRowPipeline(ec *Context, n physical.Node) (Operator, bool, error) {
	ranges, ok := parallelMorsels(ec, n)
	if !ok {
		return nil, false, nil
	}
	nw := workers(ec, len(ranges))
	ops, srcs, err := rowPipelines(ec, n, nw)
	if err != nil {
		return nil, true, err
	}
	width := len(n.Schema())
	run := func(w int, r scanRange) ([]types.Row, error) {
		srcs[w].set(r)
		var out []types.Row
		var arena []types.Value
		for {
			row, err := ops[w].Next()
			if row == nil || err != nil {
				return out, err
			}
			if len(arena) < width || width == 0 {
				arena = make([]types.Value, max(width*256, 1)) // never a nil row
			}
			cp := arena[:width:width]
			arena = arena[width:]
			copy(cp, row)
			out = append(out, cp)
		}
	}
	return &gatherRowOp{g: newGather(ec, ranges, nw, run)}, true, nil
}

// compactBatch copies the active rows of a batch into newly allocated,
// dense vectors (dictionary vectors keep their immutable dictionary); int
// columns are gathered with pqk_gather_i64 if lib is non-nil.
func compactBatch(b *Batch, classes []vclass, lib *native.Lib) *Batch {
	n := b.Len()
	out := &Batch{N: n, Cols: make([]*Vec, len(b.Cols))}
	idx := func(k int) int {
		if b.Sel != nil {
			return int(b.Sel[k])
		}
		return k
	}
	for c, v := range b.Cols {
		nv := &Vec{}
		switch {
		case classes[c] == vInt && b.Sel != nil:
			nv.I = make([]int64, n)
			gatherInts(lib, v.I, b.Sel, nv.I)
		case classes[c] == vInt:
			nv.I = append([]int64(nil), v.I[:n]...)
		case classes[c] == vFloat:
			nv.F = make([]float64, n)
			for k := range nv.F {
				nv.F[k] = v.F[idx(k)]
			}
		case classes[c] == vWide:
			nv.W = make([]types.Int128, n)
			for k := range nv.W {
				nv.W[k] = v.W[idx(k)]
			}
		case v.Dict != nil:
			nv.Dict = v.Dict
			nv.Codes = make([]uint32, n)
			for k := range nv.Codes {
				nv.Codes[k] = v.Codes[idx(k)]
			}
		default:
			nv.S = make([]string, n)
			for k := range nv.S {
				nv.S[k] = v.S[idx(k)]
			}
		}
		if v.Nulls != nil {
			nv.Nulls = make([]bool, n)
			for k := range nv.Nulls {
				nv.Nulls[k] = v.Nulls[idx(k)]
			}
		}
		out.Cols[c] = nv
	}
	return out
}

// ---------------------------------------------------------------- parallel aggregation

// runMorsels runs fn(w, i) for every morsel i on nw workers and returns
// the error of the first failing morsel (in table order).
func runMorsels(ec *Context, ranges []scanRange, nw int, fn func(w, i int) error) error {
	q := newMorselQueue(ranges)
	errsByMorsel := make([]error, len(ranges))
	var wg sync.WaitGroup
	for w := 0; w < nw; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i, ok := q.take()
				if !ok {
					return
				}
				if err := fn(w, i); err != nil {
					errsByMorsel[i] = err
					q.fail(i)
				}
			}
		}()
	}
	wg.Wait()
	if f := q.failed.Load(); f != math.MaxInt64 {
		return errsByMorsel[f]
	}
	return ec.Check()
}

// morselPos is the input position of row k of morsel i (group ordering).
func morselPos(i int, k int64) int64 { return int64(i)<<32 | k }

// parallelAggregate builds a parallel vectorized aggregation if
// parallelism applies to its input.
func parallelAggregate(ec *Context, x *physical.HashAggregate) (BatchOperator, bool, error) {
	if !aggParallelSafe(x) {
		return nil, false, nil
	}
	ranges, ok := parallelMorsels(ec, x.Input)
	if !ok {
		return nil, false, nil
	}
	nw := workers(ec, len(ranges))
	ops, srcs, err := batchPipelines(ec, x.Input, nw)
	if err != nil {
		return nil, true, err
	}
	inputs := make([]*vaggInput, nw)
	tables := make([]*aggTable, nw)
	keyTypes := exprTypes(x.Keys)
	for w := range inputs {
		if inputs[w], err = newVAggInput(ec, x); err != nil {
			return nil, true, err
		}
		tables[w] = newAggTable(ec, keyTypes, x.Aggs)
	}
	run := func() ([]types.Row, error) {
		mark := ec.Mem.Mark()
		err := runMorsels(ec, ranges, nw, func(w, i int) error {
			srcs[w].set(ranges[i])
			var k int64
			for {
				b, err := ops[w].NextBatch()
				if b == nil || err != nil {
					return err
				}
				if err := inputs[w].fold(tables[w], b, morselPos(i, k)); err != nil {
					return err
				}
				k += int64(b.N)
			}
		})
		if err != nil {
			return nil, err
		}
		rows, err := mergeTables(ec, tables, keyTypes, x.Aggs)
		if err != nil {
			return nil, err
		}
		ec.Mem.Reset(mark)
		if err := ec.Mem.Reserve(int64(len(rows)) * int64(64+48*len(x.Aggs))); err != nil {
			return nil, err
		}
		return rows, nil
	}
	return &lazyRows{run: run, types: schemaTypes(x.Schema())}, true, nil
}

// aggParallelSafe reports whether the aggregation's own expressions can be
// evaluated by workers.
func aggParallelSafe(x *physical.HashAggregate) bool {
	ids := columnIDs(x.Input.Schema())
	for _, e := range physical.Exprs(x) {
		if !parallelSafe(e, ids) {
			return false
		}
	}
	return true
}

// parallelRowAggregate is the row-mode counterpart of parallelAggregate.
func parallelRowAggregate(ec *Context, x *physical.HashAggregate) (Operator, bool, error) {
	if !aggParallelSafe(x) {
		return nil, false, nil
	}
	ranges, ok := parallelMorsels(ec, x.Input)
	if !ok {
		return nil, false, nil
	}
	nw := workers(ec, len(ranges))
	ops, srcs, err := rowPipelines(ec, x.Input, nw)
	if err != nil {
		return nil, true, err
	}
	inputs := make([]*rowAggInput, nw)
	tables := make([]*rowAggTable, nw)
	keyTypes := exprTypes(x.Keys)
	for w := range inputs {
		if inputs[w], err = newRowAggInput(ec, x); err != nil {
			return nil, true, err
		}
		tables[w] = newRowAggTable(ec, keyTypes, x.Aggs)
	}
	run := func() ([]types.Row, error) {
		mark := ec.Mem.Mark()
		err := runMorsels(ec, ranges, nw, func(w, i int) error {
			srcs[w].set(ranges[i])
			for k := int64(0); ; k++ {
				row, err := ops[w].Next()
				if row == nil || err != nil {
					return err
				}
				if err := inputs[w].add(tables[w], row, morselPos(i, k)); err != nil {
					return err
				}
			}
		})
		if err != nil {
			return nil, err
		}
		final := newRowAggTable(ec, keyTypes, x.Aggs)
		for _, t := range tables {
			if err := final.mergeFrom(t); err != nil {
				return nil, err
			}
		}
		ec.Mem.Reset(mark)
		if err := ec.Mem.Reserve(int64(len(final.keyRows)) * int64(64+64*len(x.Aggs))); err != nil {
			return nil, err
		}
		return final.rows()
	}
	return &lazyRowsOp{run: run}, true, nil
}

// lazyRows is a batch operator over rows computed on first use.
type lazyRows struct {
	run   func() ([]types.Row, error)
	types []types.Type
	out   BatchOperator
}

func (l *lazyRows) NextBatch() (*Batch, error) {
	if l.out == nil {
		rows, err := l.run()
		if err != nil {
			return nil, err
		}
		l.out = newBatchWriter(&replayOp{rows: rows}, l.types)
	}
	return l.out.NextBatch()
}

// lazyRowsOp is a row operator over rows computed on first use.
type lazyRowsOp struct {
	run  func() ([]types.Row, error)
	rows []types.Row
	done bool
	pos  int
}

func (l *lazyRowsOp) Next() (types.Row, error) {
	if !l.done {
		l.done = true
		rows, err := l.run()
		if err != nil {
			return nil, err
		}
		l.rows = rows
	}
	if l.pos >= len(l.rows) {
		return nil, nil
	}
	l.pos++
	return l.rows[l.pos-1], nil
}
