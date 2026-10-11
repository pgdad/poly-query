package exec

import (
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Vector kernels for correlated subqueries whose plan probes a ParamLookup
// with a single key of the same INT-class or STRING type on both sides and
// whose residual, if any, depends only on the inner input (so that the
// lookup table is pre-checked, see lookupTable):
//
//   - EXISTS (SELECT <columns or constants> FROM … WHERE key = outer …): a
//     probe of the lookup table per row (a semi-join);
//   - (SELECT f(AGG(…), …) FROM … WHERE key = outer …): the aggregates of a
//     group, computed once per group with the row-mode accumulators.
//
// Both compute exactly what the subquery evaluated per outer row returns;
// whenever that evaluation could fail (a pre-check failed for a row of the
// group, an aggregate or expression fails), they return errVector and the
// batch is evaluated row by row.

// correlatedKernel compiles a correlated subquery of a supported shape, or
// returns nil.
func (c *vcompiler) correlatedKernel(x *plan.Subquery) (vexpr, error) {
	sub, ok := c.ec.Plan.Subplans[x]
	if !ok || x.Kind == plan.SubIn {
		return nil, nil
	}
	var agg *physical.HashAggregate
	var proj *physical.Project
	n := sub
	if x.Kind == plan.SubScalar {
		p, ok := n.(*physical.Project)
		if !ok || len(p.Exprs) != 1 {
			return nil, nil
		}
		a, ok := p.Input.(*physical.HashAggregate)
		if !ok || len(a.Keys) > 0 || !refsWithin(p.Exprs[0], a.Schema()) {
			return nil, nil
		}
		for _, call := range a.Aggs {
			if call.Arg != nil && (volatile(call.Arg) || !refsWithin(call.Arg, a.Input.Schema())) {
				return nil, nil
			}
		}
		proj, agg, n = p, a, a.Input
	} else {
		// EXISTS only reads whether a row exists; projections of columns
		// and constants cannot fail.
		for {
			p, ok := n.(*physical.Project)
			if !ok {
				break
			}
			for _, e := range p.Exprs {
				switch e.(type) {
				case *plan.ColumnRef, *plan.Literal:
				default:
					return nil, nil
				}
				if !refsWithin(e, p.Input.Schema()) {
					return nil, nil
				}
			}
			n = p.Input
		}
	}
	pl, ok := n.(*physical.ParamLookup)
	if !ok {
		return nil, nil
	}
	cls, ok := directLookupKey(pl)
	if !ok || (pl.Residual != nil && (volatile(pl.Residual) || !refsWithin(pl.Residual, pl.Input.Schema()))) {
		return nil, nil
	}
	for id := range plan.RefSet(pl.OuterKeys[0]) {
		if _, ok := c.lay[id]; !ok {
			return nil, nil // refers to values outside this batch
		}
	}
	key, err := c.compile(pl.OuterKeys[0])
	if err != nil {
		return nil, err
	}
	k := &vlookupKernel{ec: c.ec, node: pl, key: key, cls: cls}
	if ref, ok := pl.InnerKeys[0].(*plan.ColumnRef); ok {
		k.groupKey = ref
		if agg != nil {
			k.aggs, k.aggCols = agg.Aggs, agg.AggCols
		}
	}
	if agg == nil {
		return &vexistsKernel{vlookupKernel: k}, nil
	}
	lay := layoutOf(agg.Input.Schema())
	v := &vcorrAggKernel{vlookupKernel: k, calls: agg.Aggs, out: classOf(x.T), cache: map[int32]types.Value{}}
	for _, call := range agg.Aggs {
		var f evalFn
		if call.Arg != nil {
			if f, err = compile(c.ec, lay, call.Arg); err != nil {
				return nil, err
			}
		}
		v.args = append(v.args, f)
	}
	if v.project, err = compile(c.ec, layoutOf(agg.Schema()), proj.Exprs[0]); err != nil {
		return nil, err
	}
	return v, nil
}

// vlookupKernel finds the group of each row's outer key: in the result
// of grouping the inner rows that satisfy the residual by the inner key
// (grouped: computed once, vectorized, with the aggregates if any), or,
// if that computation fails (an error of the residual or of an aggregate
// in a group the outer rows may never ask for), in the lookup table whose
// groups are evaluated on demand.
type vlookupKernel struct {
	ec   *Context
	node *physical.ParamLookup
	key  vexpr
	cls  vclass
	t    *lookupTable

	groupKey *plan.ColumnRef // inner key, if a column (else no grouped)
	aggs     []*plan.AggCall
	aggCols  []plan.Column
	grouped  *corrGroups
	tried    bool
}

// corrGroups maps inner keys to the aggregate values of their rows.
type corrGroups struct {
	ints *intGroupMap
	strs *strGroupMap
	aggs []types.Row
}

// group computes the grouped inner rows (see vlookupKernel).
func (k *vlookupKernel) group() (*corrGroups, error) {
	pl := k.node
	input := pl.Input
	if pl.Residual != nil {
		input = &physical.Filter{Input: input, Pred: pl.Residual}
	}
	var keyCol plan.Column
	for _, c := range input.Schema() {
		if c.ID == k.groupKey.ID {
			keyCol = c
		}
	}
	node := &physical.HashAggregate{Input: input, Keys: []plan.Expr{k.groupKey},
		KeyCols: []plan.Column{keyCol}, Aggs: k.aggs, AggCols: k.aggCols}
	op, err := BuildBatch(k.ec, node)
	if err != nil {
		return nil, err
	}
	rows, err := materialize(k.ec, newRowReader(op, schemaTypes(node.Schema())))
	if err != nil {
		return nil, err
	}
	cg := &corrGroups{}
	if k.cls == vInt {
		cg.ints = newIntGroupMap()
	} else {
		cg.strs = newStrGroupMap()
	}
	for _, r := range rows {
		key := r[0]
		if key.Null {
			continue // NULL keys never match
		}
		g := int32(len(cg.aggs))
		if k.cls == vInt {
			_, slot, _ := cg.ints.find(key.I)
			cg.ints.insert(slot, key.I, g)
		} else {
			h := strKeyHash(key.S)
			_, slot, _ := cg.strs.find(key.S, h)
			cg.strs.insert(slot, key.S, h, g)
		}
		cg.aggs = append(cg.aggs, r[1:])
	}
	return cg, nil
}

// groups evaluates the outer keys and returns, per needed row, its group
// (-1: no rows), in k.grouped if set, else in the lookup table.
func (k *vlookupKernel) groups(b *Batch, sel []int32, out []int32) ([]int32, error) {
	kv, err := k.key.eval(b, sel)
	if err != nil {
		return nil, err
	}
	if !k.tried && k.groupKey != nil {
		k.tried = true
		mark := k.ec.Mem.Mark()
		if k.grouped, err = k.group(); err != nil {
			k.ec.Mem.Reset(mark)
			if k.grouped = nil; k.ec.Check() != nil {
				return nil, errVector
			}
		}
	}
	ints, strs := (*intGroupMap)(nil), (*strGroupMap)(nil)
	if k.grouped != nil {
		ints, strs = k.grouped.ints, k.grouped.strs
	} else {
		if k.t == nil {
			if k.t, err = k.ec.lookupTable(k.node); err != nil {
				return nil, errVector
			}
		}
		ints, strs = k.t.ints, k.t.strs
	}
	out = grow(out, b.N)
	forNeeded(b.N, sel, nil, func(i int) {
		out[i] = -1
		if kv.isNull(i) {
			return
		}
		var g int32
		var ok bool
		switch {
		case k.cls == vInt:
			g, _, ok = ints.find(kv.I[i])
		case kv.Dict != nil:
			s := kv.Dict[kv.Codes[i]]
			g, _, ok = strs.find(s, strKeyHash(s))
		default:
			g, _, ok = strs.find(kv.S[i], strKeyHash(kv.S[i]))
		}
		if ok {
			out[i] = g
		}
	})
	return out, nil
}

// vexistsKernel is a correlated EXISTS.
type vexistsKernel struct {
	*vlookupKernel
	gids []int32
	out  vecBuf
}

func (v *vexistsKernel) eval(b *Batch, sel []int32) (*Vec, error) {
	gids, err := v.groups(b, sel, v.gids)
	if err != nil {
		return nil, err
	}
	v.gids = gids
	t := v.t
	out := v.out.reset(b.N, vInt)
	if v.grouped != nil {
		forNeeded(b.N, sel, nil, func(i int) { out.I[i] = b2i(gids[i] >= 0) })
		return out, nil
	}
	failed := false
	forNeeded(b.N, sel, nil, func(i int) {
		out.I[i] = 0
		if g := gids[i]; g >= 0 {
			// The first row of the group decides (the subquery stops
			// there), unless its residual failed.
			first := t.order[t.offsets[g]]
			failed = failed || (t.checked && t.recheck[first])
			out.I[i] = 1
		}
	})
	if failed {
		return nil, errVector
	}
	return out, nil
}

// vcorrAggKernel is a correlated scalar subquery computing aggregates
// (without GROUP BY) of the matching rows.
type vcorrAggKernel struct {
	*vlookupKernel
	calls   []*plan.AggCall
	args    []evalFn // per call; nil for COUNT(*)
	project evalFn   // over the aggregate's output row
	out     vclass
	cache   map[int32]types.Value // per group (-1: no rows)
	gids    []int32
	buf     vecBuf
}

// value computes the subquery's value for the rows of group g (-1: none).
func (v *vcorrAggKernel) value(g int32) (types.Value, bool) {
	if r, ok := v.cache[g]; ok {
		return r, true
	}
	if v.grouped != nil && g >= 0 {
		r, err := v.project(v.grouped.aggs[g])
		if err != nil {
			return null, false
		}
		v.cache[g] = r
		return r, true
	}
	accs := make([]accumulator, len(v.calls))
	for i, call := range v.calls {
		accs[i] = newAccumulator(call)
	}
	t := v.t
	if g >= 0 {
		for _, r := range t.order[t.offsets[g]:t.offsets[g+1]] {
			if t.checked && t.recheck[r] {
				return null, false
			}
			row := t.rows[r]
			for i, acc := range accs {
				a := types.Value{I: 1} // COUNT(*) counts every row
				if f := v.args[i]; f != nil {
					var err error
					if a, err = f(row); err != nil {
						return null, false
					}
				}
				if err := acc.add(a); err != nil {
					return null, false
				}
			}
		}
	}
	aggRow := make(types.Row, len(accs))
	for i, acc := range accs {
		var err error
		if aggRow[i], err = acc.result(); err != nil {
			return null, false
		}
	}
	r, err := v.project(aggRow)
	if err != nil {
		return null, false
	}
	v.cache[g] = r
	return r, true
}

func (v *vcorrAggKernel) eval(b *Batch, sel []int32) (*Vec, error) {
	gids, err := v.groups(b, sel, v.gids)
	if err != nil {
		return nil, err
	}
	v.gids = gids
	out := v.buf.reset(b.N, v.out)
	v.buf.withNulls(b.N)
	failed := false
	forNeeded(b.N, sel, nil, func(i int) {
		if failed {
			return
		}
		r, ok := v.value(gids[i])
		if !ok {
			failed = true
			return
		}
		out.set(i, r, v.out)
	})
	if failed {
		return nil, errVector
	}
	return out, nil
}
