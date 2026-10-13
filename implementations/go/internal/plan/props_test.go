package plan

import (
	"testing"

	"polyquery/internal/types"
)

func lit(i int64) Expr { return &Literal{Val: types.IntValue(i), T: types.Int64} }

func chain(op BinaryOp, n int, leaf func(int) Expr) Expr {
	e := leaf(0)
	for i := 1; i < n; i++ {
		e = &Binary{Op: op, L: e, R: leaf(i), T: types.Int64}
	}
	return e
}

func TestPropsLinearChain(t *testing.T) {
	col := &ColumnRef{ID: 1, Name: "x", T: types.Int64}
	e := chain(OpAdd, 100_000, func(i int) Expr {
		if i == 0 {
			return col
		}
		return lit(int64(i))
	})
	p := NewProps()
	if p.IsConstant(e) || !p.Movable(e) || p.Volatile(e) {
		t.Fatal("x + 1 + … is not constant, movable and not volatile")
	}
	if got := p.Size(e); got != 199_999 {
		t.Fatalf("size %d", got)
	}
	right := e.(*Binary).R
	if !p.IsConstant(right) || p.Size(right) != 1 {
		t.Fatal("a literal is constant of size 1")
	}
	sleep := &Func{Name: "PQ_SLEEP", Args: []Expr{lit(1)}, T: types.Int64}
	if !p.IsConstant(sleep) || !p.Volatile(sleep) || p.Movable(sleep) {
		t.Fatal("PQ_SLEEP(1) is constant, volatile and not movable")
	}
}

func TestChainOperands(t *testing.T) {
	e := chain(OpConcat, 5, func(i int) Expr { return lit(int64(i)) })
	// a right-nested concatenation is part of the same chain
	e = &Binary{Op: OpConcat, L: e, R: &Binary{Op: OpConcat, L: lit(5), R: lit(6)}}
	ops := ChainOperands(e, OpConcat)
	if len(ops) != 7 {
		t.Fatalf("%d operands", len(ops))
	}
	for i, op := range ops {
		if op.(*Literal).Val.I != int64(i) {
			t.Fatalf("operand %d is %v", i, op)
		}
	}
	if ops := ChainOperands(lit(1), OpConcat); len(ops) != 1 {
		t.Fatal("a non-chain is its own single operand")
	}
}
