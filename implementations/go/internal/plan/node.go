package plan

import (
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Column describes an output column of a plan node.
type Column struct {
	Name string
	Type types.Type
}

// Node is a logical plan operator.
type Node interface {
	Columns() []Column
	Children() []Node
}

// Scan reads a base table. Rows have the table's full width; only the
// columns listed in Needed are materialised (column pruning).
type Scan struct {
	Table  *storage.Table
	Needed []int
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

// Aggregate groups its input by GroupBy (none = a single group over the whole
// input, which always yields one row) and computes Aggs. Output rows are the
// group keys followed by the aggregate values.
type Aggregate struct {
	Input   Node
	GroupBy []Expr
	Aggs    []*AggCall
}

// SortKey is an ORDER BY key over the input columns.
type SortKey struct {
	Index      int
	Desc       bool
	NullsFirst bool
}

// Sort orders its input.
type Sort struct {
	Input Node
	Keys  []SortKey
	// Limit, if ≥ 0, is a hint that only the first Limit rows are consumed
	// (enables top-N sorting).
	Limit int64
}

// Limit skips Offset rows and returns at most Count rows. Both are constant
// expressions evaluated at execution start; nil means absent.
type Limit struct {
	Input  Node
	Count  Expr
	Offset Expr
}

// Columns implementations.
func (n *Scan) Columns() []Column {
	cols := make([]Column, len(n.Table.Columns))
	for i, c := range n.Table.Columns {
		cols[i] = Column{Name: c.Name, Type: c.Type}
	}
	return cols
}
func (n *Values) Columns() []Column  { return n.Cols }
func (n *Filter) Columns() []Column  { return n.Input.Columns() }
func (n *Project) Columns() []Column { return n.Cols }
func (n *Aggregate) Columns() []Column {
	cols := make([]Column, 0, len(n.GroupBy)+len(n.Aggs))
	for _, g := range n.GroupBy {
		cols = append(cols, Column{Name: g.String(), Type: g.Type()})
	}
	for _, a := range n.Aggs {
		cols = append(cols, Column{Name: a.String(), Type: a.T})
	}
	return cols
}
func (n *Sort) Columns() []Column  { return n.Input.Columns() }
func (n *Limit) Columns() []Column { return n.Input.Columns() }

// Children implementations.
func (n *Scan) Children() []Node      { return nil }
func (n *Values) Children() []Node    { return nil }
func (n *Filter) Children() []Node    { return []Node{n.Input} }
func (n *Project) Children() []Node   { return []Node{n.Input} }
func (n *Aggregate) Children() []Node { return []Node{n.Input} }
func (n *Sort) Children() []Node      { return []Node{n.Input} }
func (n *Limit) Children() []Node     { return []Node{n.Input} }
