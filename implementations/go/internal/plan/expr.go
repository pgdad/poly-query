// Package plan defines bound (name-resolved, typed) expressions and the
// logical query plan produced by semantic analysis and consumed by execution.
package plan

import (
	"strconv"
	"strings"

	"polyquery/internal/types"
)

// Expr is a bound, typed scalar expression.
type Expr interface {
	Type() types.Type
	// String renders the expression canonically; structurally equal
	// expressions render identically (used for EXPLAIN and equivalence).
	String() string
}

// ColumnRef reads column Index of the input row.
type ColumnRef struct {
	Index int
	Name  string
	T     types.Type
}

// Literal is a constant.
type Literal struct {
	Val types.Value
	T   types.Type
}

// UnaryOp enumerates unary operators.
type UnaryOp uint8

// Unary operators.
const (
	OpNeg UnaryOp = iota
	OpNot
)

// Unary applies a prefix operator.
type Unary struct {
	Op UnaryOp
	X  Expr
	T  types.Type
}

// BinaryOp enumerates binary operators.
type BinaryOp uint8

// Binary operators.
const (
	OpAdd BinaryOp = iota
	OpSub
	OpMul
	OpDiv
	OpMod
	OpConcat
	OpEq
	OpNe
	OpLt
	OpLe
	OpGt
	OpGe
	OpAnd
	OpOr
)

var binaryNames = [...]string{"+", "-", "*", "/", "%", "||", "=", "<>", "<", "<=", ">", ">=", "AND", "OR"}

func (op BinaryOp) String() string { return binaryNames[op] }

// IsComparison reports whether op is a comparison operator.
func (op BinaryOp) IsComparison() bool { return op >= OpEq && op <= OpGe }

// Binary applies an infix operator. Operands have already been promoted to a
// common type (DECIMAL operands may still differ in scale).
type Binary struct {
	Op   BinaryOp
	L, R Expr
	T    types.Type
}

// IsNull tests for NULL.
type IsNull struct {
	X   Expr
	Not bool
}

// Cast converts X to type To (explicit CAST or implicit promotion).
type Cast struct {
	X  Expr
	To types.Type
}

// Func is a scalar function call.
type Func struct {
	Name string // upper case
	Args []Expr
	T    types.Type
}

// AggFunc enumerates aggregate functions.
type AggFunc uint8

// Aggregate functions.
const (
	AggCountStar AggFunc = iota
	AggCount
	AggSum
	AggAvg
	AggMin
	AggMax
)

var aggNames = [...]string{"COUNT", "COUNT", "SUM", "AVG", "MIN", "MAX"}

func (f AggFunc) String() string { return aggNames[f] }

// AggCall is an aggregate computed by an Aggregate node.
type AggCall struct {
	Func     AggFunc
	Arg      Expr // nil for COUNT(*)
	Distinct bool
	T        types.Type
}

// Type implementations.
func (e *ColumnRef) Type() types.Type { return e.T }
func (e *Literal) Type() types.Type   { return e.T }
func (e *Unary) Type() types.Type     { return e.T }
func (e *Binary) Type() types.Type    { return e.T }
func (e *IsNull) Type() types.Type    { return types.Boolean }
func (e *Cast) Type() types.Type      { return e.To }
func (e *Func) Type() types.Type      { return e.T }
func (e *AggCall) Type() types.Type   { return e.T }

func (e *ColumnRef) String() string { return "#" + strconv.Itoa(e.Index) + ":" + e.Name }

func (e *Literal) String() string {
	if e.Val.Null {
		return "NULL"
	}
	s := types.FormatValue(e.Val, e.T)
	switch e.T.Kind {
	case types.KindString:
		return "'" + strings.ReplaceAll(s, "'", "''") + "'"
	case types.KindDate:
		return "DATE '" + s + "'"
	case types.KindTimestamp:
		return "TIMESTAMP '" + s + "'"
	case types.KindDecimal:
		return s + "::" + e.T.String()
	}
	return s
}

func (e *Unary) String() string {
	if e.Op == OpNot {
		return "(NOT " + e.X.String() + ")"
	}
	return "(-" + e.X.String() + ")"
}

func (e *Binary) String() string {
	return "(" + e.L.String() + " " + e.Op.String() + " " + e.R.String() + ")"
}

func (e *IsNull) String() string {
	if e.Not {
		return "(" + e.X.String() + " IS NOT NULL)"
	}
	return "(" + e.X.String() + " IS NULL)"
}

func (e *Cast) String() string { return "CAST(" + e.X.String() + " AS " + e.To.String() + ")" }

func (e *Func) String() string {
	parts := make([]string, len(e.Args))
	for i, a := range e.Args {
		parts[i] = a.String()
	}
	return e.Name + "(" + strings.Join(parts, ", ") + ")"
}

func (e *AggCall) String() string {
	if e.Arg == nil {
		return "COUNT(*)"
	}
	d := ""
	if e.Distinct {
		d = "DISTINCT "
	}
	return e.Func.String() + "(" + d + e.Arg.String() + ")"
}

// Walk calls fn for e and all its subexpressions (pre-order). AggCall
// arguments are visited too.
func Walk(e Expr, fn func(Expr)) {
	if e == nil {
		return
	}
	fn(e)
	switch x := e.(type) {
	case *Unary:
		Walk(x.X, fn)
	case *Binary:
		Walk(x.L, fn)
		Walk(x.R, fn)
	case *IsNull:
		Walk(x.X, fn)
	case *Cast:
		Walk(x.X, fn)
	case *Func:
		for _, a := range x.Args {
			Walk(a, fn)
		}
	case *AggCall:
		Walk(x.Arg, fn)
	}
}

// IsConstant reports whether e references no columns and no aggregates.
func IsConstant(e Expr) bool {
	ok := true
	Walk(e, func(x Expr) {
		switch x.(type) {
		case *ColumnRef, *AggCall:
			ok = false
		}
	})
	return ok
}
