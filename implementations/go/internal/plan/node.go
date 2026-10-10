package plan

import (
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Column describes an output column of a plan node.
type Column struct {
	ID   ColumnID
	Name string
	Type types.Type
}

// Ref returns a reference expression for the column.
func (c Column) Ref() *ColumnRef { return &ColumnRef{ID: c.ID, Name: c.Name, T: c.Type} }

// Node is a logical plan operator.
type Node interface {
	// Schema lists the output columns in row order.
	Schema() []Column
	Children() []Node
}

// Scan reads a base table; Cols has one entry per table column.
type Scan struct {
	Table *storage.Table
	Cols  []Column
}

// Values produces constant rows (a single empty row for SELECT without FROM).
type Values struct {
	Rows [][]Expr
	Cols []Column
}

// Filter keeps rows for which Pred is TRUE.
type Filter struct {
	Input Node
	Pred  Expr
}

// Project computes output expressions.
type Project struct {
	Input Node
	Exprs []Expr
	Cols  []Column
}

// Aggregate groups its input by Keys (none = a single group over the whole
// input, which always yields one row) and computes Aggs. Output rows are the
// group keys followed by the aggregate values.
type Aggregate struct {
	Input   Node
	Keys    []Expr
	KeyCols []Column
	Aggs    []*AggCall
	AggCols []Column
}

// JoinKind enumerates join types.
type JoinKind uint8

// Join kinds.
const (
	JoinInner JoinKind = iota
	JoinLeft
	JoinCross
)

func (k JoinKind) String() string {
	switch k {
	case JoinLeft:
		return "LEFT"
	case JoinCross:
		return "CROSS"
	}
	return "INNER"
}

// Join combines two inputs; output rows are left columns then right columns.
// Cond is nil for CROSS joins.
type Join struct {
	Kind        JoinKind
	Left, Right Node
	Cond        Expr
}

// SortKey is an ORDER BY key.
type SortKey struct {
	Expr       Expr
	Desc       bool
	NullsFirst bool
}

// Sort orders its input.
type Sort struct {
	Input Node
	Keys  []SortKey
}

// Limit skips Offset rows and returns at most Count rows. Both are constant
// expressions; nil means absent.
type Limit struct {
	Input  Node
	Count  Expr
	Offset Expr
}

// Distinct removes duplicate rows (NULLs compare equal).
type Distinct struct {
	Input Node
}

// Schema implementations.
func (n *Scan) Schema() []Column    { return n.Cols }
func (n *Values) Schema() []Column  { return n.Cols }
func (n *Filter) Schema() []Column  { return n.Input.Schema() }
func (n *Project) Schema() []Column { return n.Cols }
func (n *Aggregate) Schema() []Column {
	return append(append([]Column(nil), n.KeyCols...), n.AggCols...)
}
func (n *Join) Schema() []Column {
	return append(append([]Column(nil), n.Left.Schema()...), n.Right.Schema()...)
}
func (n *Sort) Schema() []Column     { return n.Input.Schema() }
func (n *Limit) Schema() []Column    { return n.Input.Schema() }
func (n *Distinct) Schema() []Column { return n.Input.Schema() }

// Children implementations.
func (n *Scan) Children() []Node      { return nil }
func (n *Values) Children() []Node    { return nil }
func (n *Filter) Children() []Node    { return []Node{n.Input} }
func (n *Project) Children() []Node   { return []Node{n.Input} }
func (n *Aggregate) Children() []Node { return []Node{n.Input} }
func (n *Join) Children() []Node      { return []Node{n.Left, n.Right} }
func (n *Sort) Children() []Node      { return []Node{n.Input} }
func (n *Limit) Children() []Node     { return []Node{n.Input} }
func (n *Distinct) Children() []Node  { return []Node{n.Input} }

// NodeExprs returns the expressions evaluated by node n itself.
func NodeExprs(n Node) []Expr {
	switch x := n.(type) {
	case *Values:
		var out []Expr
		for _, r := range x.Rows {
			out = append(out, r...)
		}
		return out
	case *Filter:
		return []Expr{x.Pred}
	case *Project:
		return x.Exprs
	case *Aggregate:
		out := append([]Expr(nil), x.Keys...)
		for _, a := range x.Aggs {
			out = append(out, a)
		}
		return out
	case *Join:
		if x.Cond != nil {
			return []Expr{x.Cond}
		}
	case *Sort:
		out := make([]Expr, len(x.Keys))
		for i, k := range x.Keys {
			out[i] = k.Expr
		}
		return out
	case *Limit:
		var out []Expr
		if x.Count != nil {
			out = append(out, x.Count)
		}
		if x.Offset != nil {
			out = append(out, x.Offset)
		}
		return out
	}
	return nil
}

// FreeColumns returns the columns referenced inside the plan (including
// nested subqueries) that no node of the plan produces: the outer references
// of a correlated subquery.
func FreeColumns(n Node) []Column {
	defined := map[ColumnID]bool{}
	var refs []*ColumnRef
	var visit func(Node)
	visit = func(n Node) {
		for _, c := range n.Schema() {
			defined[c.ID] = true
		}
		for _, e := range NodeExprs(n) {
			Walk(e, func(x Expr) {
				switch y := x.(type) {
				case *ColumnRef:
					refs = append(refs, y)
				case *Subquery:
					for _, c := range y.Correlated {
						refs = append(refs, c.Ref())
					}
				}
			})
		}
		for _, c := range n.Children() {
			visit(c)
		}
	}
	visit(n)
	var out []Column
	seen := map[ColumnID]bool{}
	for _, r := range refs {
		if !defined[r.ID] && !seen[r.ID] {
			seen[r.ID] = true
			out = append(out, Column{ID: r.ID, Name: r.Name, Type: r.T})
		}
	}
	return out
}

// MapExprs returns a copy of the plan tree in which every expression
// (including those of nested subquery plans) has been rewritten with Map(e, f).
func MapExprs(n Node, f func(Expr) Expr) Node {
	var mapExpr func(Expr) Expr
	mapExpr = func(e Expr) Expr {
		return Map(e, func(x Expr) Expr {
			if r := f(x); r != nil {
				return r
			}
			if sq, ok := x.(*Subquery); ok {
				c := *sq
				c.X = mapExpr(sq.X)
				c.Plan = MapExprs(sq.Plan, f)
				c.Correlated = FreeColumns(c.Plan)
				return &c
			}
			return nil
		})
	}
	list := func(es []Expr) []Expr {
		out := make([]Expr, len(es))
		for i, e := range es {
			out[i] = mapExpr(e)
		}
		return out
	}
	switch x := n.(type) {
	case *Scan:
		return x
	case *Values:
		c := *x
		c.Rows = make([][]Expr, len(x.Rows))
		for i, r := range x.Rows {
			c.Rows[i] = list(r)
		}
		return &c
	case *Filter:
		return &Filter{Input: MapExprs(x.Input, f), Pred: mapExpr(x.Pred)}
	case *Project:
		return &Project{Input: MapExprs(x.Input, f), Exprs: list(x.Exprs), Cols: x.Cols}
	case *Aggregate:
		c := *x
		c.Input = MapExprs(x.Input, f)
		c.Keys = list(x.Keys)
		c.Aggs = make([]*AggCall, len(x.Aggs))
		for i, a := range x.Aggs {
			c.Aggs[i] = mapExpr(a).(*AggCall)
		}
		return &c
	case *Join:
		return &Join{Kind: x.Kind, Left: MapExprs(x.Left, f), Right: MapExprs(x.Right, f), Cond: mapExpr(x.Cond)}
	case *Sort:
		c := &Sort{Input: MapExprs(x.Input, f), Keys: make([]SortKey, len(x.Keys))}
		for i, k := range x.Keys {
			k.Expr = mapExpr(k.Expr)
			c.Keys[i] = k
		}
		return c
	case *Limit:
		return &Limit{Input: MapExprs(x.Input, f), Count: mapExpr(x.Count), Offset: mapExpr(x.Offset)}
	case *Distinct:
		return &Distinct{Input: MapExprs(x.Input, f)}
	}
	return n
}
