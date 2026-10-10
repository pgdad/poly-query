package exec

import (
	"slices"

	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// ---------------------------------------------------------------- merge join

// keyedRows is one materialized merge-join input: its rows and their join
// key values (flattened, nk per row), sorted by key.
type keyedRows struct {
	rows []types.Row
	keys []types.Value
	nk   int
}

func (k *keyedRows) key(i int) []types.Value { return k.keys[i*k.nk : (i+1)*k.nk] }

// mergeJoinOp implements INNER and LEFT equi-joins by sorting both inputs on
// their join keys and merging equal-key runs. Rows with a NULL key never
// match; for LEFT joins the left ones are emitted NULL-extended. Output rows
// are left columns then right columns, in key order.
type mergeJoinOp struct {
	joinCounter
	kind          plan.JoinKind
	left, right   Operator
	leftKeys      []evalFn
	rightKeys     []evalFn
	leftTypes     []types.Type
	rightTypes    []types.Type
	residual      evalFn
	leftW, rightW int
	out           types.Row

	started    bool
	l, r       keyedRows
	unmatchedL []types.Row // left rows with NULL keys (LEFT joins)
	ui         int
	li, ri     int // merge cursors
	l0, l1     int // current left run
	r0, r1     int // current right run
	cl, cr     int // position inside the run
	matched    bool
	inRun      bool
	steps      int
}

func buildMergeJoin(ec *Context, x *physical.MergeJoin) (Operator, error) {
	left, err := Build(ec, x.Left)
	if err != nil {
		return nil, err
	}
	right, err := Build(ec, x.Right)
	if err != nil {
		return nil, err
	}
	op := &mergeJoinOp{
		joinCounter: joinCounter{ec: ec}, kind: x.Kind, left: left, right: right,
		leftW: len(x.Left.Schema()), rightW: len(x.Right.Schema()),
		leftTypes: exprTypes(x.LeftKeys), rightTypes: exprTypes(x.RightKeys),
	}
	if op.leftKeys, err = compileAll(ec, layoutOf(x.Left.Schema()), x.LeftKeys); err != nil {
		return nil, err
	}
	if op.rightKeys, err = compileAll(ec, layoutOf(x.Right.Schema()), x.RightKeys); err != nil {
		return nil, err
	}
	if x.Residual != nil {
		if op.residual, err = compile(ec, layoutOf(x.Schema()), x.Residual); err != nil {
			return nil, err
		}
	}
	op.out = make(types.Row, op.leftW+op.rightW)
	return op, nil
}

func exprTypes(es []plan.Expr) []types.Type {
	ts := make([]types.Type, len(es))
	for i, e := range es {
		ts[i] = e.Type()
	}
	return ts
}

// sortedInput materializes an input with its keys, drops rows with a NULL
// key (returning them separately) and sorts the rest by key.
func sortedInput(ec *Context, op Operator, fns []evalFn, ts []types.Type) (keyedRows, []types.Row, error) {
	rows, err := materialize(ec, op)
	if err != nil {
		return keyedRows{}, nil, err
	}
	nk := len(fns)
	in := keyedRows{nk: nk, keys: make([]types.Value, 0, len(rows)*nk)}
	var nulls []types.Row
	kept := rows[:0]
	for n, row := range rows {
		if n%checkEvery == 0 {
			if err := ec.Check(); err != nil {
				return keyedRows{}, nil, err
			}
		}
		start := len(in.keys)
		hasNull := false
		for _, f := range fns {
			v, err := f(row)
			if err != nil {
				return keyedRows{}, nil, err
			}
			hasNull = hasNull || v.Null
			in.keys = append(in.keys, v)
		}
		if hasNull {
			in.keys = in.keys[:start]
			nulls = append(nulls, row)
			continue
		}
		kept = append(kept, row)
	}
	in.rows = kept
	idx := make([]int32, len(kept))
	for i := range idx {
		idx[i] = int32(i)
	}
	compareKeys := func(a, b []types.Value) int {
		for k := range a {
			if c := types.Compare(ts[k], a[k], ts[k], b[k]); c != 0 {
				return c
			}
		}
		return 0
	}
	comparisons := 0
	var aborted error
	func() {
		defer func() {
			if r := recover(); r != nil {
				abort, ok := r.(sortAborted)
				if !ok {
					panic(r)
				}
				aborted = abort.err
			}
		}()
		slices.SortStableFunc(idx, func(a, b int32) int {
			if comparisons++; comparisons%checkEvery == 0 {
				if err := ec.Check(); err != nil {
					panic(sortAborted{err})
				}
			}
			return compareKeys(in.key(int(a)), in.key(int(b)))
		})
	}()
	if aborted != nil {
		return keyedRows{}, nil, aborted
	}
	sorted := keyedRows{nk: nk, rows: make([]types.Row, len(idx)), keys: make([]types.Value, len(in.keys))}
	for i, k := range idx {
		sorted.rows[i] = in.rows[k]
		copy(sorted.key(i), in.key(int(k)))
	}
	return sorted, nulls, nil
}

func (j *mergeJoinOp) start() error {
	var err error
	var nulls []types.Row
	if j.l, nulls, err = sortedInput(j.ec, j.left, j.leftKeys, j.leftTypes); err != nil {
		return err
	}
	if j.kind == plan.JoinLeft {
		j.unmatchedL = nulls
	}
	j.r, _, err = sortedInput(j.ec, j.right, j.rightKeys, j.rightTypes)
	return err
}

// cross compares a left key with a right key (operands were promoted to a
// common type by analysis; DECIMAL scales may differ).
func (j *mergeJoinOp) cross(a, b []types.Value) int {
	for k := range a {
		if c := types.Compare(j.leftTypes[k], a[k], j.rightTypes[k], b[k]); c != 0 {
			return c
		}
	}
	return 0
}

// runEnd returns the end of the run of rows equal to row from (by key).
func runEnd(rows *keyedRows, ts []types.Type, from int) int {
	keys := rows.key(from)
	to := from + 1
	for ; to < len(rows.rows); to++ {
		next := rows.key(to)
		for k := range keys {
			if types.Compare(ts[k], keys[k], ts[k], next[k]) != 0 {
				return to
			}
		}
	}
	return to
}

func (j *mergeJoinOp) nullExtended(row types.Row) (types.Row, error) {
	copy(j.out, row)
	for i := j.leftW; i < len(j.out); i++ {
		j.out[i] = null
	}
	return j.out, j.emit()
}

func (j *mergeJoinOp) Next() (types.Row, error) {
	if !j.started {
		j.started = true
		if err := j.start(); err != nil {
			return nil, err
		}
	}
	if j.ui < len(j.unmatchedL) {
		j.ui++
		return j.nullExtended(j.unmatchedL[j.ui-1])
	}
	for {
		if j.steps++; j.steps%checkEvery == 0 {
			if err := j.ec.Check(); err != nil {
				return nil, err
			}
		}
		if j.inRun {
			if j.cl >= j.l1 {
				j.inRun = false
				j.li, j.ri = j.l1, j.r1
				continue
			}
			if j.cr < j.r1 {
				lrow, rrow := j.l.rows[j.cl], j.r.rows[j.cr]
				j.cr++
				copy(j.out, lrow)
				copy(j.out[j.leftW:], rrow)
				if j.residual != nil {
					v, err := j.residual(j.out)
					if err != nil {
						return nil, err
					}
					if !v.IsTrue() {
						continue
					}
				}
				j.matched = true
				return j.out, j.emit()
			}
			// The current left row is done.
			unmatched := j.kind == plan.JoinLeft && !j.matched
			lrow := j.l.rows[j.cl]
			j.cl++
			j.cr, j.matched = j.r0, false
			if unmatched {
				return j.nullExtended(lrow)
			}
			continue
		}
		if j.li >= len(j.l.rows) {
			return nil, nil
		}
		if j.ri >= len(j.r.rows) {
			if j.kind != plan.JoinLeft {
				return nil, nil
			}
			j.li++
			return j.nullExtended(j.l.rows[j.li-1])
		}
		lk, rk := j.l.key(j.li), j.r.key(j.ri)
		switch c := j.cross(lk, rk); {
		case c < 0:
			j.li++
			if j.kind == plan.JoinLeft {
				return j.nullExtended(j.l.rows[j.li-1])
			}
		case c > 0:
			j.ri++
		default:
			j.l0, j.l1 = j.li, runEnd(&j.l, j.leftTypes, j.li)
			j.r0, j.r1 = j.ri, runEnd(&j.r, j.rightTypes, j.ri)
			j.cl, j.cr, j.matched, j.inRun = j.l0, j.r0, false, true
		}
	}
}
