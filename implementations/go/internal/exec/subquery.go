package exec

import (
	"encoding/binary"
	"math"

	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// appendKey appends a canonical, type-aware encoding of v to b, used as
// hash key for grouping, DISTINCT, hash joins and IN sets. Values that are
// equal per types.md §7 encode identically (DECIMALs are normalized by
// stripping trailing fractional zeros, -0.0 equals 0.0, NULLs are equal).
func appendKey(b []byte, v types.Value, t types.Type) []byte {
	if v.Null {
		return append(b, 0)
	}
	switch t.Kind {
	case types.KindFloat64:
		f := v.F
		if f == 0 {
			f = 0
		}
		b = append(b, 1)
		return binary.LittleEndian.AppendUint64(b, math.Float64bits(f))
	case types.KindString:
		b = append(b, 2)
		b = binary.AppendUvarint(b, uint64(len(v.S)))
		return append(b, v.S...)
	case types.KindDecimal:
		u, s := v.I, t.Scale
		for s > 0 && u%10 == 0 {
			u /= 10
			s--
		}
		b = append(b, 3, byte(s))
		return binary.LittleEndian.AppendUint64(b, uint64(u))
	}
	b = append(b, 4)
	return binary.LittleEndian.AppendUint64(b, uint64(v.I))
}

// subResult is the evaluated result of a subquery.
type subResult struct {
	value   types.Value         // scalar subquery
	exists  bool                // EXISTS / IN: at least one row
	set     map[string]struct{} // IN: keys of the non-NULL values
	hasNull bool                // IN: some value is NULL
}

// maxMemo bounds the number of memoized results per correlated subquery.
const maxMemo = 1 << 14

// compileSubquery compiles a subquery expression. Uncorrelated subqueries
// are evaluated once per statement; correlated ones once per distinct
// combination of outer values (semantics.md §8: logically once per row).
func compileSubquery(ec *Context, lay layout, x *plan.Subquery) (evalFn, error) {
	sub, ok := ec.Plan.Subplans[x]
	if !ok {
		return nil, errs.New(errs.InternalError, "subquery has no physical plan")
	}
	var get func(types.Row) (*subResult, error)
	if len(x.Correlated) == 0 {
		get = func(types.Row) (*subResult, error) {
			if r, ok := ec.subCache[x]; ok {
				return r, nil
			}
			r, err := runSubquery(ec, x, sub)
			if err != nil {
				return nil, err
			}
			if ec.subCache == nil {
				ec.subCache = map[*plan.Subquery]*subResult{}
			}
			ec.subCache[x] = r
			return r, nil
		}
	} else {
		getters := make([]evalFn, len(x.Correlated))
		for i, c := range x.Correlated {
			f, err := compile(ec, lay, c.Ref())
			if err != nil {
				return nil, err
			}
			getters[i] = f
		}
		cells := make([]types.Value, len(x.Correlated))
		memo := map[string]*subResult{}
		var key []byte
		get = func(row types.Row) (*subResult, error) {
			key = key[:0]
			for i, g := range getters {
				v, err := g(row)
				if err != nil {
					return nil, err
				}
				cells[i] = v
				key = appendKey(key, v, x.Correlated[i].Type)
			}
			if r, ok := memo[string(key)]; ok {
				return r, nil
			}
			if ec.params == nil {
				ec.params = map[plan.ColumnID]*types.Value{}
			}
			saved := make([]*types.Value, len(cells))
			for i, c := range x.Correlated {
				saved[i] = ec.params[c.ID]
				ec.params[c.ID] = &cells[i]
			}
			r, err := runSubquery(ec, x, sub)
			for i, c := range x.Correlated {
				if saved[i] == nil {
					delete(ec.params, c.ID)
				} else {
					ec.params[c.ID] = saved[i]
				}
			}
			if err != nil {
				return nil, err
			}
			if len(memo) >= maxMemo {
				clear(memo)
			}
			memo[string(key)] = r
			return r, nil
		}
	}

	switch x.Kind {
	case plan.SubScalar:
		return func(row types.Row) (types.Value, error) {
			r, err := get(row)
			if err != nil {
				return null, err
			}
			return r.value, nil
		}, nil
	case plan.SubExists:
		return func(row types.Row) (types.Value, error) {
			r, err := get(row)
			if err != nil {
				return null, err
			}
			return types.BoolValue(r.exists), nil
		}, nil
	}
	xf, err := compile(ec, lay, x.X)
	if err != nil {
		return nil, err
	}
	cast, eff := caster(x.X.Type(), x.CmpType)
	not := x.Not
	var key []byte
	return func(row types.Row) (types.Value, error) {
		v, err := xf(row)
		if err != nil {
			return null, err
		}
		r, err := get(row)
		if err != nil {
			return null, err
		}
		result := falseVal
		switch {
		case !r.exists:
		case v.Null:
			result = null
		default:
			if v, err = cast(v); err != nil {
				return null, err
			}
			key = appendKey(key[:0], v, eff)
			if _, ok := r.set[string(key)]; ok {
				result = trueVal
			} else if r.hasNull {
				result = null
			}
		}
		if not {
			result = not3(result)
		}
		return result, nil
	}, nil
}

// runSubquery executes a subquery plan and collects the result its kind
// needs.
func runSubquery(ec *Context, x *plan.Subquery, sub physical.Node) (*subResult, error) {
	// Operator state is garbage once the result is collected: give its
	// memory back, then account for what the result retains.
	mark := ec.Mem.Mark()
	r, err := collectSubquery(ec, x, sub)
	ec.Mem.Reset(mark)
	if err == nil && len(r.set) > 0 && len(x.Correlated) == 0 {
		err = ec.Mem.Reserve(int64(len(r.set)) * 64)
	}
	return r, err
}

func collectSubquery(ec *Context, x *plan.Subquery, sub physical.Node) (*subResult, error) {
	if len(x.Correlated) > 0 {
		// Evaluated per outer row: never worth parallel workers.
		ec.serial++
		defer func() { ec.serial-- }()
	}
	op, err := Build(ec, sub)
	if err != nil {
		return nil, err
	}
	r := &subResult{value: null}
	row, err := op.Next()
	if err != nil {
		return nil, err
	}
	switch x.Kind {
	case plan.SubScalar:
		if row != nil {
			r.value = row[0]
			if more, err := op.Next(); err != nil {
				return nil, err
			} else if more != nil {
				return nil, errs.New(errs.SubqueryCardinality, "scalar subquery returned more than one row")
			}
		}
	case plan.SubExists:
		r.exists = row != nil
	case plan.SubIn:
		r.set = map[string]struct{}{}
		et := sub.Schema()[0].Type
		cast, eff := caster(et, x.CmpType)
		var key []byte
		for n := 0; row != nil; n++ {
			r.exists = true
			v := row[0]
			if v.Null {
				r.hasNull = true
			} else {
				if v, err = cast(v); err != nil {
					return nil, err
				}
				key = appendKey(key[:0], v, eff)
				r.set[string(key)] = struct{}{}
			}
			if n%checkEvery == 0 {
				if err := ec.Check(); err != nil {
					return nil, err
				}
			}
			if row, err = op.Next(); err != nil {
				return nil, err
			}
		}
	}
	return r, nil
}

// ---------------------------------------------------------------- correlated subplans

// lookupTable is the hashed input of a ParamLookup, built once per query.
type lookupTable struct {
	rows  []types.Row
	index map[string][]int32
}

// paramLookupOp returns the cached input rows matching the current outer
// values (see physical.ParamLookup).
type paramLookupOp struct {
	ec       *Context
	node     *physical.ParamLookup
	outer    []evalFn
	outTypes []types.Type
	residual evalFn
	matches  []int32
	table    *lookupTable
	pos      int
	started  bool
}

func (o *paramLookupOp) Next() (types.Row, error) {
	if !o.started {
		o.started = true
		t, err := o.ec.lookupTable(o.node)
		if err != nil {
			return nil, err
		}
		o.table = t
		key, ok, err := joinKey(nil, o.outer, o.outTypes, nil)
		if err != nil {
			return nil, err
		}
		if ok {
			o.matches = t.index[string(key)]
		}
	}
	for o.pos < len(o.matches) {
		row := o.table.rows[o.matches[o.pos]]
		o.pos++
		if o.residual != nil {
			v, err := o.residual(row)
			if err != nil {
				return nil, err
			}
			if !v.IsTrue() {
				continue
			}
		}
		return row, nil
	}
	return nil, nil
}

func (ec *Context) lookupTable(n *physical.ParamLookup) (*lookupTable, error) {
	if t, ok := ec.lookups[n]; ok {
		return t, nil
	}
	in, err := Build(ec, n.Input)
	if err != nil {
		return nil, err
	}
	keys, err := compileAll(ec, layoutOf(n.Input.Schema()), n.InnerKeys)
	if err != nil {
		return nil, err
	}
	ts := make([]types.Type, len(n.InnerKeys))
	for i, k := range n.InnerKeys {
		ts[i] = k.Type()
	}
	rows, err := materialize(ec, in)
	if err != nil {
		return nil, err
	}
	t := &lookupTable{index: map[string][]int32{}}
	var key []byte
	for _, row := range rows {
		k, ok, err := joinKey(key[:0], keys, ts, row)
		key = k
		if err != nil {
			return nil, err
		}
		if ok {
			t.rows = append(t.rows, row)
			t.index[string(k)] = append(t.index[string(k)], int32(len(t.rows)-1))
		}
	}
	if ec.lookups == nil {
		ec.lookups = map[*physical.ParamLookup]*lookupTable{}
	}
	ec.lookups[n] = t
	return t, nil
}

// replayOp returns the cached rows of a Materialize node.
type replayOp struct {
	rows []types.Row
	pos  int
}

func (r *replayOp) Next() (types.Row, error) {
	if r.pos >= len(r.rows) {
		return nil, nil
	}
	r.pos++
	return r.rows[r.pos-1], nil
}

func (ec *Context) materialized(n *physical.Materialize) ([]types.Row, error) {
	if rows, ok := ec.cached[n]; ok {
		return rows, nil
	}
	in, err := Build(ec, n.Input)
	if err != nil {
		return nil, err
	}
	rows, err := materialize(ec, in)
	if err != nil {
		return nil, err
	}
	if ec.cached == nil {
		ec.cached = map[*physical.Materialize][]types.Row{}
	}
	ec.cached[n] = rows
	return rows, nil
}
