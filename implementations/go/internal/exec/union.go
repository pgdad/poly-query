package exec

import (
	"polyquery/internal/physical"
	"polyquery/internal/types"
)

// UNION ALL: the inputs are built one after the other, when the previous
// one is exhausted, so that at most one branch is running at a time.

// unionPositions returns, for every input, the positions in the input's
// rows of the columns feeding the union's outputs.
func unionPositions(x *physical.UnionAll) [][]int {
	pos := make([][]int, len(x.Inputs))
	for i, in := range x.Inputs {
		lay := layoutOf(in.Schema())
		pos[i] = make([]int, len(x.InputCols[i]))
		for j, c := range x.InputCols[i] {
			pos[i][j] = lay[c.ID]
		}
	}
	return pos
}

// unionOp concatenates the rows of its inputs.
type unionOp struct {
	ec    *Context
	node  *physical.UnionAll
	vec   bool
	pos   [][]int
	cur   int
	input Operator
	buf   types.Row
}

func newUnionOp(ec *Context, x *physical.UnionAll, vec bool) *unionOp {
	return &unionOp{ec: ec, node: x, vec: vec, pos: unionPositions(x), cur: -1, buf: make(types.Row, len(x.Cols))}
}

func (u *unionOp) Next() (types.Row, error) {
	for {
		if u.input != nil {
			row, err := u.input.Next()
			if err != nil {
				return nil, err
			}
			if row != nil {
				for j, p := range u.pos[u.cur] {
					u.buf[j] = row[p]
				}
				return u.buf, nil
			}
			u.input = nil
		}
		if u.cur+1 >= len(u.node.Inputs) {
			return nil, nil
		}
		u.cur++
		if err := u.ec.Check(); err != nil {
			return nil, err
		}
		in, err := input(u.ec, u.node.Inputs[u.cur], u.vec)
		if err != nil {
			return nil, err
		}
		u.input = in
	}
}

// vunionOp concatenates the batches of its inputs; output batches share
// the input's vectors.
type vunionOp struct {
	ec    *Context
	node  *physical.UnionAll
	pos   [][]int
	cur   int
	input BatchOperator
	out   Batch
}

func newVUnionOp(ec *Context, x *physical.UnionAll) *vunionOp {
	return &vunionOp{ec: ec, node: x, pos: unionPositions(x), cur: -1, out: Batch{Cols: make([]*Vec, len(x.Cols))}}
}

func (u *vunionOp) NextBatch() (*Batch, error) {
	for {
		if u.input != nil {
			b, err := u.input.NextBatch()
			if err != nil {
				return nil, err
			}
			if b != nil {
				u.out.N, u.out.Sel = b.N, b.Sel
				for j, p := range u.pos[u.cur] {
					u.out.Cols[j] = b.Cols[p]
				}
				return &u.out, nil
			}
			u.input = nil
		}
		if u.cur+1 >= len(u.node.Inputs) {
			return nil, nil
		}
		u.cur++
		if err := u.ec.Check(); err != nil {
			return nil, err
		}
		in, err := BuildBatch(u.ec, u.node.Inputs[u.cur])
		if err != nil {
			return nil, err
		}
		u.input = in
	}
}
