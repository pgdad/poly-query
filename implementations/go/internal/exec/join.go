package exec

import (
	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// joinCounter enforces --max-join-rows on a join's output.
type joinCounter struct {
	ec      *Context
	emitted int64
}

func (c *joinCounter) emit() error {
	c.emitted++
	if c.ec.MaxJoinRows > 0 && c.emitted > c.ec.MaxJoinRows {
		return errs.New(errs.ResourceLimit, "join produced more than %d rows", c.ec.MaxJoinRows)
	}
	return nil
}

// materialize copies all rows of an operator, accounting their memory.
func materialize(ec *Context, op Operator) ([]types.Row, error) {
	var rows []types.Row
	for n := 0; ; n++ {
		row, err := op.Next()
		if err != nil {
			return nil, err
		}
		if row == nil {
			return rows, nil
		}
		if n%checkEvery == 0 {
			if err := ec.Check(); err != nil {
				return nil, err
			}
		}
		cp := append(types.Row(nil), row...)
		if err := ec.Mem.Reserve(RowSize(cp)); err != nil {
			return nil, err
		}
		rows = append(rows, cp)
	}
}

// ---------------------------------------------------------------- hash join

// hashJoinOp implements INNER and LEFT equi-joins. The build input is
// materialized into a hash table keyed by the join keys (rows with a NULL
// key are dropped: NULL never matches); the probe input is streamed. Output
// rows are always left columns then right columns.
type hashJoinOp struct {
	joinCounter
	kind             plan.JoinKind
	build, probe     Operator
	buildKeys        []evalFn
	probeKeys        []evalFn
	buildTypes       []types.Type
	probeTypes       []types.Type
	residual         evalFn // over the combined row; nil if none
	buildLeft        bool
	leftW, rightW    int
	table            map[string][]int32
	rows             []types.Row
	built            bool
	cur              types.Row // current probe row
	matches          []int32
	mi               int
	matched, pending bool
	key              []byte
	out              types.Row
	steps            int
}

func (j *hashJoinOp) buildTable() error {
	j.table = map[string][]int32{}
	for n := 0; ; n++ {
		row, err := j.build.Next()
		if err != nil {
			return err
		}
		if row == nil {
			return nil
		}
		if n%checkEvery == 0 {
			if err := j.ec.Check(); err != nil {
				return err
			}
		}
		key, ok, err := joinKey(j.key[:0], j.buildKeys, j.buildTypes, row)
		j.key = key
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		cp := append(types.Row(nil), row...)
		if err := j.ec.Mem.Reserve(RowSize(cp) + int64(len(key)) + 16); err != nil {
			return err
		}
		j.rows = append(j.rows, cp)
		j.table[string(key)] = append(j.table[string(key)], int32(len(j.rows)-1))
	}
}

// joinKey encodes the key of a row; ok is false if any key value is NULL.
func joinKey(b []byte, fns []evalFn, ts []types.Type, row types.Row) ([]byte, bool, error) {
	for i, f := range fns {
		v, err := f(row)
		if err != nil {
			return b, false, err
		}
		if v.Null {
			return b, false, nil
		}
		b = appendKey(b, v, ts[i])
	}
	return b, true, nil
}

func (j *hashJoinOp) combine(probe, build types.Row) types.Row {
	if j.buildLeft {
		copy(j.out, build)
		copy(j.out[j.leftW:], probe)
	} else {
		copy(j.out, probe)
		copy(j.out[j.leftW:], build)
	}
	return j.out
}

func (j *hashJoinOp) Next() (types.Row, error) {
	if !j.built {
		j.built = true
		if err := j.buildTable(); err != nil {
			return nil, err
		}
	}
	for {
		if j.pending {
			for j.mi < len(j.matches) {
				b := j.rows[j.matches[j.mi]]
				j.mi++
				out := j.combine(j.cur, b)
				if j.residual != nil {
					j.steps++
					if j.steps%checkEvery == 0 {
						if err := j.ec.Check(); err != nil {
							return nil, err
						}
					}
					v, err := j.residual(out)
					if err != nil {
						return nil, err
					}
					if !v.IsTrue() {
						continue
					}
				}
				j.matched = true
				return out, j.emit()
			}
			j.pending = false
			if j.kind == plan.JoinLeft && !j.matched {
				copy(j.out, j.cur)
				for i := j.leftW; i < len(j.out); i++ {
					j.out[i] = null
				}
				return j.out, j.emit()
			}
		}
		row, err := j.probe.Next()
		if row == nil || err != nil {
			return nil, err
		}
		key, ok, err := joinKey(j.key[:0], j.probeKeys, j.probeTypes, row)
		j.key = key
		if err != nil {
			return nil, err
		}
		j.cur, j.mi, j.matched, j.pending = row, 0, false, true
		j.matches = nil
		if ok {
			j.matches = j.table[string(key)]
		}
	}
}

// ---------------------------------------------------------------- nested loop

// nestedLoopJoinOp implements INNER, LEFT and CROSS joins with an arbitrary
// condition by materializing the right input and scanning it for every left
// row.
type nestedLoopJoinOp struct {
	joinCounter
	kind          plan.JoinKind
	left, right   Operator
	cond          evalFn // nil = always true
	leftW, rightW int
	rows          []types.Row
	built         bool
	cur           types.Row
	ri            int
	matched       bool
	out           types.Row
	steps         int
}

func (j *nestedLoopJoinOp) Next() (types.Row, error) {
	if !j.built {
		j.built = true
		rows, err := materialize(j.ec, j.right)
		if err != nil {
			return nil, err
		}
		j.rows = rows
	}
	for {
		if j.cur != nil {
			for j.ri < len(j.rows) {
				r := j.rows[j.ri]
				j.ri++
				copy(j.out[j.leftW:], r)
				j.steps++
				if j.steps%checkEvery == 0 {
					if err := j.ec.Check(); err != nil {
						return nil, err
					}
				}
				if j.cond != nil {
					v, err := j.cond(j.out)
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
			unmatched := j.kind == plan.JoinLeft && !j.matched
			j.cur = nil
			if unmatched {
				for i := j.leftW; i < len(j.out); i++ {
					j.out[i] = null
				}
				return j.out, j.emit()
			}
		}
		row, err := j.left.Next()
		if row == nil || err != nil {
			return nil, err
		}
		j.cur, j.ri, j.matched = row, 0, false
		copy(j.out, row)
		if len(j.rows) == 0 && j.kind != plan.JoinLeft {
			// No right rows: inner/cross joins produce nothing; drain is
			// unnecessary.
			return nil, nil
		}
	}
}
