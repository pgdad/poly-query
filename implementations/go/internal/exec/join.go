package exec

import (
	"sync"
	"sync/atomic"

	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// joinCounter enforces --max-join-rows on a join's output (shared by the
// probe instances of a parallel hash join).
type joinCounter struct {
	ec      *Context
	emitted *atomic.Int64
}

func newJoinCounter(ec *Context) joinCounter { return joinCounter{ec: ec, emitted: new(atomic.Int64)} }

func (c *joinCounter) emit() error {
	if n := c.emitted.Add(1); c.ec.MaxJoinRows > 0 && n > c.ec.MaxJoinRows {
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

// rowJoinBuild is the build side of a row-mode hash join: materialized
// into a hash table keyed by the join keys (rows with a NULL key are
// dropped: NULL never matches) on first use, then shared read-only by all
// probe instances.
type rowJoinBuild struct {
	ec      *Context
	input   Operator
	keys    []evalFn
	types   []types.Type
	once    sync.Once
	table   map[string][]int32
	rows    []types.Row
	err     error
	emitted atomic.Int64
}

func newRowJoinBuild(ec *Context, x *physical.HashJoin, vec bool) (*rowJoinBuild, error) {
	buildNode, _, buildKeys, _ := buildSide(x)
	in, err := input(ec, buildNode, vec)
	if err != nil {
		return nil, err
	}
	s := &rowJoinBuild{ec: ec, input: in, types: exprTypes(buildKeys)}
	if s.keys, err = compileAll(ec, layoutOf(buildNode.Schema()), buildKeys); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *rowJoinBuild) get() error {
	s.once.Do(func() { s.err = s.build() })
	return s.err
}

func (s *rowJoinBuild) build() error {
	s.table = map[string][]int32{}
	var key []byte
	for n := 0; ; n++ {
		row, err := s.input.Next()
		if err != nil {
			return err
		}
		if row == nil {
			return nil
		}
		if n%checkEvery == 0 {
			if err := s.ec.Check(); err != nil {
				return err
			}
		}
		k, ok, err := joinKey(key[:0], s.keys, s.types, row)
		key = k
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		cp := append(types.Row(nil), row...)
		if err := s.ec.Mem.Reserve(RowSize(cp) + int64(len(key)) + 16); err != nil {
			return err
		}
		s.rows = append(s.rows, cp)
		s.table[string(key)] = append(s.table[string(key)], int32(len(s.rows)-1))
	}
}

// hashJoinOp implements INNER and LEFT equi-joins by probing the build
// table with every row of the streamed probe input. Output rows are always
// left columns then right columns.
type hashJoinOp struct {
	joinCounter
	kind             plan.JoinKind
	shared           *rowJoinBuild
	probe            Operator
	probeKeys        []evalFn
	probeTypes       []types.Type
	residual         evalFn // over the combined row; nil if none
	buildLeft        bool
	leftW, rightW    int
	built            bool
	cur              types.Row // current probe row
	matches          []int32
	mi               int
	matched, pending bool
	key              []byte
	out              types.Row
	steps            int
}

func newHashJoinProbe(ec *Context, x *physical.HashJoin, shared *rowJoinBuild, probe Operator) (*hashJoinOp, error) {
	_, probeNode, _, probeKeys := buildSide(x)
	op := &hashJoinOp{
		joinCounter: joinCounter{ec: ec, emitted: &shared.emitted}, kind: x.Kind, buildLeft: x.BuildLeft,
		shared: shared, probe: probe, probeTypes: exprTypes(probeKeys),
		leftW: len(x.Left.Schema()), rightW: len(x.Right.Schema()),
	}
	op.out = make(types.Row, op.leftW+op.rightW)
	var err error
	if op.probeKeys, err = compileAll(ec, layoutOf(probeNode.Schema()), probeKeys); err != nil {
		return nil, err
	}
	if x.Residual != nil {
		if op.residual, err = compile(ec, layoutOf(x.Schema()), x.Residual); err != nil {
			return nil, err
		}
	}
	return op, nil
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
		if err := j.shared.get(); err != nil {
			return nil, err
		}
	}
	for {
		if j.pending {
			for j.mi < len(j.matches) {
				b := j.shared.rows[j.matches[j.mi]]
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
			j.matches = j.shared.table[string(key)]
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
