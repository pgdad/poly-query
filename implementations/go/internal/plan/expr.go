// Package plan defines bound (name-resolved, typed) expressions and the
// logical query plan produced by semantic analysis. Every column produced by a
// plan node carries a ColumnID that is unique within a statement; expressions
// reference columns by ID, which keeps plan rewrites (predicate pushdown,
// column pruning, decorrelation of grouped columns) free of index bookkeeping.
package plan

import (
	"strconv"
	"strings"

	"polyquery/internal/types"
)

// ColumnID identifies a column produced by a plan node.
type ColumnID int

// Expr is a bound, typed scalar expression.
type Expr interface {
	Type() types.Type
	// String renders the expression canonically including column IDs;
	// structurally equal expressions render identically (semantics.md §5).
	String() string
}

// ColumnRef reads a column produced by an input node (or, inside a correlated
// subquery, by an enclosing query).
type ColumnRef struct {
	ID   ColumnID
	Name string
	T    types.Type
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

// Binary applies an infix operator. Operands of arithmetic and comparison
// operators have been promoted to a common type (DECIMAL operands may still
// differ in scale).
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

// Func is a scalar function call (functions.md §1). Constant parameters
// that influence typing or evaluation are pre-evaluated during analysis:
// Digits for ROUND's second argument, Unit for DATE_TRUNC/DATE_DIFF.
// NullParam marks a constant parameter that is NULL (the result is NULL).
type Func struct {
	Name      string // upper case, aliases resolved (CEILING → CEIL, SUBSTRING → SUBSTR)
	Args      []Expr
	T         types.Type
	Digits    int64
	Unit      string
	NullParam bool
}

// When is one CASE branch.
type When struct {
	Cond, Result Expr
}

// Case is a searched CASE, or a simple CASE when Operand is set; then each
// Cond is a value compared with the operand in type CmpTypes[i].
type Case struct {
	Operand  Expr
	Whens    []When
	Else     Expr
	CmpTypes []types.Type
	T        types.Type
}

// Between is `X [NOT] BETWEEN Lo AND Hi`; LoType/HiType are the common types
// of the two comparisons.
type Between struct {
	X, Lo, Hi      Expr
	Not            bool
	LoType, HiType types.Type
}

// InList is `X [NOT] IN (List…)`; CmpTypes[i] is the comparison type of X and
// List[i].
type InList struct {
	X        Expr
	List     []Expr
	Not      bool
	CmpTypes []types.Type
}

// Like is `X [NOT] LIKE Pattern`.
type Like struct {
	X, Pattern Expr
	Not        bool
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

// AggCall is an aggregate function call. It only appears in expressions
// during analysis; the analyzer replaces it by a reference to the output
// column of an Aggregate node.
type AggCall struct {
	Func     AggFunc
	Arg      Expr // nil for COUNT(*)
	Distinct bool
	T        types.Type
}

// SubqueryKind enumerates subquery expression forms.
type SubqueryKind uint8

// Subquery kinds.
const (
	SubScalar SubqueryKind = iota
	SubExists
	SubIn
)

// Subquery is a scalar, EXISTS or IN subquery. Correlated lists the columns of
// enclosing queries the subquery references (empty if uncorrelated).
type Subquery struct {
	Kind       SubqueryKind
	Plan       Node
	X          Expr // IN only: the tested value
	Not        bool // IN only
	CmpType    types.Type
	Correlated []Column
	Seq        int // unique per statement; identifies the subquery in String()
	T          types.Type
}

// Type implementations.
func (e *ColumnRef) Type() types.Type { return e.T }
func (e *Literal) Type() types.Type   { return e.T }
func (e *Unary) Type() types.Type     { return e.T }
func (e *Binary) Type() types.Type    { return e.T }
func (e *IsNull) Type() types.Type    { return types.Boolean }
func (e *Cast) Type() types.Type      { return e.To }
func (e *Func) Type() types.Type      { return e.T }
func (e *Case) Type() types.Type      { return e.T }
func (e *Between) Type() types.Type   { return types.Boolean }
func (e *InList) Type() types.Type    { return types.Boolean }
func (e *Like) Type() types.Type      { return types.Boolean }
func (e *AggCall) Type() types.Type   { return e.T }
func (e *Subquery) Type() types.Type  { return e.T }

// String implementations (canonical form with column IDs).
func (e *ColumnRef) String() string { return render(e, true) }
func (e *Literal) String() string   { return render(e, true) }
func (e *Unary) String() string     { return render(e, true) }
func (e *Binary) String() string    { return render(e, true) }
func (e *IsNull) String() string    { return render(e, true) }
func (e *Cast) String() string      { return render(e, true) }
func (e *Func) String() string      { return render(e, true) }
func (e *Case) String() string      { return render(e, true) }
func (e *Between) String() string   { return render(e, true) }
func (e *InList) String() string    { return render(e, true) }
func (e *Like) String() string      { return render(e, true) }
func (e *AggCall) String() string   { return render(e, true) }
func (e *Subquery) String() string  { return render(e, true) }

// Display renders an expression for humans (EXPLAIN): columns by name only.
func Display(e Expr) string {
	if e == nil {
		return ""
	}
	return render(e, false)
}

func render(e Expr, ids bool) string {
	var sb strings.Builder
	writeExpr(&sb, e, ids)
	return sb.String()
}

func writeList(sb *strings.Builder, list []Expr, ids bool) {
	for i, a := range list {
		if i > 0 {
			sb.WriteString(", ")
		}
		writeExpr(sb, a, ids)
	}
}

func not(sb *strings.Builder, b bool) {
	if b {
		sb.WriteString(" NOT")
	}
}

func writeExpr(sb *strings.Builder, e Expr, ids bool) {
	switch x := e.(type) {
	case *ColumnRef:
		if ids {
			sb.WriteString("#" + strconv.Itoa(int(x.ID)) + ":")
		}
		sb.WriteString(x.Name)
	case *Literal:
		sb.WriteString(literalText(x))
	case *Unary:
		if x.Op == OpNot {
			sb.WriteString("(NOT ")
		} else {
			sb.WriteString("(-")
		}
		writeExpr(sb, x.X, ids)
		sb.WriteString(")")
	case *Binary:
		sb.WriteString("(")
		writeExpr(sb, x.L, ids)
		sb.WriteString(" " + x.Op.String() + " ")
		writeExpr(sb, x.R, ids)
		sb.WriteString(")")
	case *IsNull:
		sb.WriteString("(")
		writeExpr(sb, x.X, ids)
		sb.WriteString(" IS")
		not(sb, x.Not)
		sb.WriteString(" NULL)")
	case *Cast:
		sb.WriteString("CAST(")
		writeExpr(sb, x.X, ids)
		sb.WriteString(" AS " + x.To.String() + ")")
	case *Func:
		sb.WriteString(x.Name + "(")
		writeList(sb, x.Args, ids)
		sb.WriteString(")")
	case *Case:
		sb.WriteString("CASE")
		if x.Operand != nil {
			sb.WriteString(" ")
			writeExpr(sb, x.Operand, ids)
		}
		for _, w := range x.Whens {
			sb.WriteString(" WHEN ")
			writeExpr(sb, w.Cond, ids)
			sb.WriteString(" THEN ")
			writeExpr(sb, w.Result, ids)
		}
		if x.Else != nil {
			sb.WriteString(" ELSE ")
			writeExpr(sb, x.Else, ids)
		}
		sb.WriteString(" END")
	case *Between:
		sb.WriteString("(")
		writeExpr(sb, x.X, ids)
		not(sb, x.Not)
		sb.WriteString(" BETWEEN ")
		writeExpr(sb, x.Lo, ids)
		sb.WriteString(" AND ")
		writeExpr(sb, x.Hi, ids)
		sb.WriteString(")")
	case *InList:
		sb.WriteString("(")
		writeExpr(sb, x.X, ids)
		not(sb, x.Not)
		sb.WriteString(" IN (")
		writeList(sb, x.List, ids)
		sb.WriteString("))")
	case *Like:
		sb.WriteString("(")
		writeExpr(sb, x.X, ids)
		not(sb, x.Not)
		sb.WriteString(" LIKE ")
		writeExpr(sb, x.Pattern, ids)
		sb.WriteString(")")
	case *AggCall:
		sb.WriteString(x.Func.String() + "(")
		if x.Arg == nil {
			sb.WriteString("*")
		} else {
			if x.Distinct {
				sb.WriteString("DISTINCT ")
			}
			writeExpr(sb, x.Arg, ids)
		}
		sb.WriteString(")")
	case *Subquery:
		tag := "$subquery" + strconv.Itoa(x.Seq)
		switch x.Kind {
		case SubExists:
			sb.WriteString("EXISTS(" + tag + ")")
		case SubIn:
			sb.WriteString("(")
			writeExpr(sb, x.X, ids)
			not(sb, x.Not)
			sb.WriteString(" IN " + tag + ")")
		default:
			sb.WriteString(tag)
		}
	default:
		sb.WriteString("?")
	}
}

func literalText(e *Literal) string {
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

// Children returns the direct subexpressions of e (subquery plans excluded).
func Children(e Expr) []Expr {
	switch x := e.(type) {
	case *Unary:
		return []Expr{x.X}
	case *Binary:
		return []Expr{x.L, x.R}
	case *IsNull:
		return []Expr{x.X}
	case *Cast:
		return []Expr{x.X}
	case *Func:
		return x.Args
	case *Case:
		var out []Expr
		if x.Operand != nil {
			out = append(out, x.Operand)
		}
		for _, w := range x.Whens {
			out = append(out, w.Cond, w.Result)
		}
		if x.Else != nil {
			out = append(out, x.Else)
		}
		return out
	case *Between:
		return []Expr{x.X, x.Lo, x.Hi}
	case *InList:
		return append([]Expr{x.X}, x.List...)
	case *Like:
		return []Expr{x.X, x.Pattern}
	case *AggCall:
		if x.Arg != nil {
			return []Expr{x.Arg}
		}
	case *Subquery:
		if x.X != nil {
			return []Expr{x.X}
		}
	}
	return nil
}

// Walk calls fn for e and all its subexpressions in pre-order (subquery
// plans are not entered).
func Walk(e Expr, fn func(Expr)) {
	if e == nil {
		return
	}
	fn(e)
	for _, c := range Children(e) {
		Walk(c, fn)
	}
}

// Map rewrites an expression tree. f is called in pre-order; a non-nil result
// replaces the visited expression (which is then not descended into),
// otherwise children are mapped and the node is copied if any changed.
func Map(e Expr, f func(Expr) Expr) Expr {
	if e == nil {
		return nil
	}
	if r := f(e); r != nil {
		return r
	}
	m := func(x Expr) Expr { return Map(x, f) }
	switch x := e.(type) {
	case *Unary:
		c := *x
		c.X = m(x.X)
		return &c
	case *Binary:
		c := *x
		c.L, c.R = m(x.L), m(x.R)
		return &c
	case *IsNull:
		c := *x
		c.X = m(x.X)
		return &c
	case *Cast:
		c := *x
		c.X = m(x.X)
		return &c
	case *Func:
		c := *x
		c.Args = mapList(x.Args, m)
		return &c
	case *Case:
		c := *x
		c.Operand = m(x.Operand)
		c.Whens = make([]When, len(x.Whens))
		for i, w := range x.Whens {
			c.Whens[i] = When{Cond: m(w.Cond), Result: m(w.Result)}
		}
		c.Else = m(x.Else)
		return &c
	case *Between:
		c := *x
		c.X, c.Lo, c.Hi = m(x.X), m(x.Lo), m(x.Hi)
		return &c
	case *InList:
		c := *x
		c.X = m(x.X)
		c.List = mapList(x.List, m)
		return &c
	case *Like:
		c := *x
		c.X, c.Pattern = m(x.X), m(x.Pattern)
		return &c
	case *AggCall:
		c := *x
		c.Arg = m(x.Arg)
		return &c
	case *Subquery:
		c := *x
		c.X = m(x.X)
		return &c
	}
	return e
}

func mapList(list []Expr, m func(Expr) Expr) []Expr {
	out := make([]Expr, len(list))
	for i, a := range list {
		out[i] = m(a)
	}
	return out
}

// Refs adds to set every column ID referenced by e, including the outer
// columns referenced by correlated subqueries.
func Refs(e Expr, set map[ColumnID]bool) {
	Walk(e, func(x Expr) {
		switch y := x.(type) {
		case *ColumnRef:
			set[y.ID] = true
		case *Subquery:
			for _, c := range y.Correlated {
				set[c.ID] = true
			}
		}
	})
}

// RefSet returns the set of column IDs referenced by e.
func RefSet(e Expr) map[ColumnID]bool {
	set := map[ColumnID]bool{}
	Refs(e, set)
	return set
}

// IsConstant reports whether e references no columns, aggregates or
// subqueries.
func IsConstant(e Expr) bool {
	ok := true
	Walk(e, func(x Expr) {
		switch x.(type) {
		case *ColumnRef, *AggCall, *Subquery:
			ok = false
		}
	})
	return ok
}

// ContainsAgg reports whether e contains an aggregate call.
func ContainsAgg(e Expr) bool {
	found := false
	Walk(e, func(x Expr) {
		if _, ok := x.(*AggCall); ok {
			found = true
		}
	})
	return found
}

// Conjuncts splits a predicate into its top-level AND operands.
func Conjuncts(e Expr) []Expr {
	if e == nil {
		return nil
	}
	if b, ok := e.(*Binary); ok && b.Op == OpAnd {
		return append(Conjuncts(b.L), Conjuncts(b.R)...)
	}
	return []Expr{e}
}

// And combines predicates with AND (nil if none).
func And(preds []Expr) Expr {
	var out Expr
	for _, p := range preds {
		if out == nil {
			out = p
		} else {
			out = &Binary{Op: OpAnd, L: out, R: p, T: types.Boolean}
		}
	}
	return out
}
