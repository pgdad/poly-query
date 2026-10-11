package physical

import (
	"math"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Build creates the physical plan for an optimized logical plan.
func Build(root plan.Node, opts Options) (*Plan, error) {
	p := &planner{opts: opts, subplans: map[*plan.Subquery]Node{}}
	r, err := p.node(root, idSet(root.Schema()))
	if err != nil {
		return nil, err
	}
	out := &Plan{Root: r, Subplans: p.subplans}
	out.Exec = chooseExecution(out, opts)
	return out, nil
}

type planner struct {
	opts     Options
	subplans map[*plan.Subquery]Node
	// params holds the outer columns available while planning a correlated
	// subquery (empty at top level).
	params idset
}

type idset = map[plan.ColumnID]bool

func idSet(cols []plan.Column) idset {
	m := make(idset, len(cols))
	for _, c := range cols {
		m[c.ID] = true
	}
	return m
}

// with returns req extended by the columns referenced by exprs.
func with(req idset, exprs ...plan.Expr) idset {
	out := make(idset, len(req))
	for id := range req {
		out[id] = true
	}
	for _, e := range exprs {
		if e != nil {
			plan.Refs(e, out)
		}
	}
	return out
}

// subqueries plans the subqueries referenced by exprs.
func (p *planner) subqueries(exprs ...plan.Expr) error {
	var err error
	for _, e := range exprs {
		plan.Walk(e, func(x plan.Expr) {
			sq, ok := x.(*plan.Subquery)
			if !ok || err != nil {
				return
			}
			if _, done := p.subplans[sq]; done {
				return
			}
			saved := p.params
			p.params = nil
			if len(sq.Correlated) > 0 {
				p.params = with(saved)
				for _, c := range sq.Correlated {
					p.params[c.ID] = true
				}
			}
			var n Node
			if n, err = p.node(sq.Plan, idSet(sq.Plan.Schema())); err == nil {
				p.subplans[sq] = n
			}
			p.params = saved
		})
	}
	return err
}

// node plans n; req is the set of n's output columns its consumer needs.
func (p *planner) node(n plan.Node, req idset) (Node, error) {
	if len(p.params) > 0 {
		// Inside a correlated subquery: compute uncorrelated subtrees once
		// and turn correlation equalities into hash lookups.
		if _, isScan := n.(*plan.Scan); !isScan && len(plan.FreeColumns(n)) == 0 {
			saved := p.params
			p.params = nil
			in, err := p.node(n, req)
			p.params = saved
			if err != nil {
				return nil, err
			}
			if _, isValues := n.(*plan.Values); isValues {
				return in, nil
			}
			return &Materialize{Input: in}, nil
		}
		if f, ok := n.(*plan.Filter); ok {
			if lookup, err := p.paramLookup(f, req); lookup != nil || err != nil {
				return lookup, err
			}
		}
	}
	if err := p.subqueries(plan.NodeExprs(n)...); err != nil {
		return nil, err
	}
	switch x := n.(type) {
	case *plan.Scan:
		ords, cols := scanColumns(x, req)
		return &TableScan{Table: x.Table, Ords: ords, Cols: cols}, nil
	case *plan.Values:
		return &Values{Rows: x.Rows, Cols: x.Cols}, nil
	case *plan.Filter:
		if scan, ok := x.Input.(*plan.Scan); ok {
			return p.scanFilter(x, scan, req), nil
		}
		in, err := p.node(x.Input, with(req, x.Pred))
		if err != nil {
			return nil, err
		}
		return &Filter{Input: in, Pred: x.Pred}, nil
	case *plan.Project:
		out := &Project{}
		for i, c := range x.Cols {
			if req[c.ID] {
				out.Exprs = append(out.Exprs, x.Exprs[i])
				out.Cols = append(out.Cols, c)
			}
		}
		in, err := p.node(x.Input, with(nil, out.Exprs...))
		if err != nil {
			return nil, err
		}
		out.Input = in
		return out, nil
	case *plan.Aggregate:
		exprs := plan.NodeExprs(x)
		in, err := p.node(x.Input, with(nil, exprs...))
		if err != nil {
			return nil, err
		}
		return &HashAggregate{Input: in, Keys: x.Keys, KeyCols: x.KeyCols, Aggs: x.Aggs, AggCols: x.AggCols}, nil
	case *plan.Join:
		return p.join(x, req)
	case *plan.Sort:
		in, err := p.node(x.Input, with(req, plan.NodeExprs(x)...))
		if err != nil {
			return nil, err
		}
		return &Sort{Input: in, Keys: x.Keys, Limit: -1}, nil
	case *plan.Limit:
		in, err := p.node(x.Input, req)
		if err != nil {
			return nil, err
		}
		if s, ok := in.(*Sort); ok {
			s.Limit = topN(x)
		}
		return &Limit{Input: in, Count: x.Count, Offset: x.Offset}, nil
	case *plan.Distinct:
		in, err := p.node(x.Input, idSet(x.Input.Schema()))
		if err != nil {
			return nil, err
		}
		return &HashDistinct{Input: in}, nil
	case *plan.UnionAll:
		return p.unionAll(x, req)
	}
	return nil, errs.New(errs.InternalError, "cannot plan logical node %T", n)
}

// unionAll plans a UNION ALL: only the required output columns are kept,
// and each branch is asked for the columns that feed them.
func (p *planner) unionAll(u *plan.UnionAll, req idset) (Node, error) {
	out := &UnionAll{InputCols: make([][]plan.Column, len(u.Inputs))}
	var keep []int
	for j, c := range u.Cols {
		if req[c.ID] {
			keep = append(keep, j)
			out.Cols = append(out.Cols, c)
		}
	}
	for i, in := range u.Inputs {
		schema := in.Schema()
		need := idset{}
		for _, j := range keep {
			out.InputCols[i] = append(out.InputCols[i], schema[j])
			need[schema[j].ID] = true
		}
		n, err := p.node(in, need)
		if err != nil {
			return nil, err
		}
		out.Inputs = append(out.Inputs, n)
	}
	return out, nil
}

// paramLookup plans a filter of a correlated subquery whose input is
// uncorrelated and whose predicate equates input expressions with outer
// values; it returns nil if the filter does not have that shape.
func (p *planner) paramLookup(f *plan.Filter, req idset) (Node, error) {
	if len(plan.FreeColumns(f.Input)) > 0 {
		return nil, nil
	}
	inputIDs := idSet(f.Input.Schema())
	pl := &ParamLookup{}
	var residual []plan.Expr
	for _, c := range plan.Conjuncts(f.Pred) {
		if in, out, ok := paramKey(c, inputIDs, p.params); ok {
			pl.InnerKeys = append(pl.InnerKeys, in)
			pl.OuterKeys = append(pl.OuterKeys, out)
		} else {
			residual = append(residual, c)
		}
	}
	if len(pl.InnerKeys) == 0 {
		return nil, nil
	}
	pl.Residual = plan.And(residual)
	if err := p.subqueries(f.Pred); err != nil {
		return nil, err
	}
	saved := p.params
	p.params = nil
	in, err := p.node(f.Input, with(req, f.Pred))
	p.params = saved
	if err != nil {
		return nil, err
	}
	pl.Input = in
	return pl, nil
}

// paramKey recognizes `a = b` where one side references only input columns
// and the other only outer parameters.
func paramKey(c plan.Expr, input, params idset) (plan.Expr, plan.Expr, bool) {
	b, ok := c.(*plan.Binary)
	if !ok || b.Op != plan.OpEq || b.L.Type().Kind == types.KindNull || b.R.Type().Kind == types.KindNull {
		return nil, nil, false
	}
	only := func(e plan.Expr, set idset) bool {
		refs := plan.RefSet(e)
		for id := range refs {
			if !set[id] {
				return false
			}
		}
		return len(refs) > 0 && !hasSubquery(e)
	}
	switch {
	case only(b.L, input) && only(b.R, params):
		return b.L, b.R, true
	case only(b.R, input) && only(b.L, params):
		return b.R, b.L, true
	}
	return nil, nil, false
}

func hasSubquery(e plan.Expr) bool {
	found := false
	plan.Walk(e, func(x plan.Expr) {
		if _, ok := x.(*plan.Subquery); ok {
			found = true
		}
	})
	return found
}

// topN returns count+offset when both are literal (the number of sorted rows
// a LIMIT needs), else -1.
func topN(l *plan.Limit) int64 {
	lit := func(e plan.Expr, def int64) (int64, bool) {
		if e == nil {
			return def, true
		}
		if v, ok := e.(*plan.Literal); ok && v.T.Kind == types.KindInt64 && !v.Val.Null && v.Val.I >= 0 {
			return v.Val.I, true
		}
		return 0, false
	}
	count, ok1 := lit(l.Count, -1)
	offset, ok2 := lit(l.Offset, 0)
	if !ok1 || !ok2 || count < 0 || count > math.MaxInt64-offset {
		return -1
	}
	return count + offset
}

func (p *planner) join(j *plan.Join, req idset) (Node, error) {
	leftIDs, rightIDs := idSet(j.Left.Schema()), idSet(j.Right.Schema())
	need := with(req, j.Cond)
	split := func(ids idset) idset {
		out := idset{}
		for id := range need {
			if ids[id] {
				out[id] = true
			}
		}
		return out
	}
	left, err := p.node(j.Left, split(leftIDs))
	if err != nil {
		return nil, err
	}
	right, err := p.node(j.Right, split(rightIDs))
	if err != nil {
		return nil, err
	}
	if j.Cond == nil || p.opts.Join == "nested_loop" {
		return &NestedLoopJoin{Kind: j.Kind, Left: left, Right: right, Cond: j.Cond}, nil
	}
	var leftKeys, rightKeys, residual []plan.Expr
	for _, c := range plan.Conjuncts(j.Cond) {
		if l, r, ok := equiKey(c, leftIDs, rightIDs); ok {
			leftKeys = append(leftKeys, l)
			rightKeys = append(rightKeys, r)
		} else {
			residual = append(residual, c)
		}
	}
	if len(leftKeys) == 0 {
		return &NestedLoopJoin{Kind: j.Kind, Left: left, Right: right, Cond: j.Cond}, nil
	}
	if p.opts.Join == "merge" {
		return &MergeJoin{Kind: j.Kind, Left: left, Right: right,
			LeftKeys: leftKeys, RightKeys: rightKeys, Residual: plan.And(residual)}, nil
	}
	// "hash" and the cost-based default: a hash join (build O(n), probe
	// O(m)) beats sorting both inputs for unsorted equi-join inputs.
	hj := &HashJoin{Kind: j.Kind, Left: left, Right: right,
		LeftKeys: leftKeys, RightKeys: rightKeys, Residual: plan.And(residual)}
	hj.BuildLeft = j.Kind == plan.JoinInner && p.estimate(j.Left) < p.estimate(j.Right)
	return hj, nil
}

// equiKey recognizes `l = r` where one operand references only left columns
// and the other only right columns.
func equiKey(c plan.Expr, left, right idset) (plan.Expr, plan.Expr, bool) {
	b, ok := c.(*plan.Binary)
	if !ok || b.Op != plan.OpEq {
		return nil, nil, false
	}
	if b.L.Type().Kind == types.KindNull || b.R.Type().Kind == types.KindNull {
		return nil, nil, false
	}
	sl, sr := sideOf(b.L, left, right), sideOf(b.R, left, right)
	switch {
	case sl == 1 && sr == 2:
		return b.L, b.R, true
	case sl == 2 && sr == 1:
		return b.R, b.L, true
	}
	return nil, nil, false
}

// sideOf returns 1 if e references only left columns, 2 if only right
// columns, 0 otherwise (none or both).
func sideOf(e plan.Expr, left, right idset) int {
	l, r := false, false
	for id := range plan.RefSet(e) {
		l = l || left[id]
		r = r || right[id]
	}
	switch {
	case l && !r:
		return 1
	case r && !l:
		return 2
	}
	return 0
}

// estimate is a coarse cardinality estimate used to pick the hash join
// build side; filters directly above scans are estimated from statistics.
func (p *planner) estimate(n plan.Node) float64 {
	switch x := n.(type) {
	case *plan.Scan:
		return float64(x.Table.Rows)
	case *plan.Values:
		return float64(len(x.Rows))
	case *plan.Filter:
		if s, ok := x.Input.(*plan.Scan); ok {
			conj := plan.Conjuncts(x.Pred)
			sel := p.filterSelectivity(s.Table, conj, p.sargs(conj, scanOrds(s)))
			return float64(s.Table.Rows) * sel
		}
		return p.estimate(x.Input) * defaultSelectivity
	case *plan.Join:
		l, r := p.estimate(x.Left), p.estimate(x.Right)
		if x.Kind == plan.JoinCross {
			return l * r
		}
		return max(l, r)
	case *plan.Aggregate:
		if len(x.Keys) == 0 {
			return 1
		}
		return p.estimate(x.Input) / 2
	case *plan.UnionAll:
		sum := 0.0
		for _, in := range x.Inputs {
			sum += p.estimate(in)
		}
		return sum
	}
	if c := n.Children(); len(c) == 1 {
		return p.estimate(c[0])
	}
	return 1
}

// scanOrds maps a scan's column IDs to table column ordinals.
func scanOrds(s *plan.Scan) map[plan.ColumnID]int {
	ords := make(map[plan.ColumnID]int, len(s.Cols))
	for i, c := range s.Cols {
		ords[c.ID] = s.Ords[i]
	}
	return ords
}

// scanColumns selects the table columns of a scan that are in req (column
// pruning).
func scanColumns(s *plan.Scan, req idset) ([]int, []plan.Column) {
	var ords []int
	var cols []plan.Column
	for i, c := range s.Cols {
		if req[c.ID] {
			ords = append(ords, s.Ords[i])
			cols = append(cols, c)
		}
	}
	return ords, cols
}

// scanFilter plans a filter directly above a table scan: it uses an index
// when one is selective enough (the conjuncts the lookup answers are
// dropped, the rest stay in a filter above the index scan); otherwise the
// table is scanned with row-group skipping driven by the search arguments.
func (p *planner) scanFilter(f *plan.Filter, s *plan.Scan, req idset) Node {
	conj := plan.Conjuncts(f.Pred)
	sargs := p.sargs(conj, scanOrds(s))
	if a := p.chooseIndex(s.Table, sargs); a != nil {
		var residual, used []plan.Expr
		for i, c := range conj {
			if a.consumed[i] {
				used = append(used, c)
			} else {
				residual = append(residual, c)
			}
		}
		// The index scan reads the columns of the whole predicate (the
		// indexed column through the index) plus those required above.
		ords, cols := scanColumns(s, with(req, f.Pred))
		var out Node = &IndexScan{
			Table: s.Table, Index: a.ix, Ords: ords, Cols: cols,
			Point: a.point, Points: a.points, Range: a.rng, Empty: a.empty, Cond: plan.And(used),
		}
		if len(residual) > 0 {
			out = &Filter{Input: out, Pred: plan.And(residual)}
		}
		return out
	}
	ords, cols := scanColumns(s, with(req, f.Pred))
	scan := &TableScan{Table: s.Table, Ords: ords, Cols: cols, Filters: columnFilters(sargs, s.Table)}
	return &Filter{Input: scan, Pred: f.Pred}
}
