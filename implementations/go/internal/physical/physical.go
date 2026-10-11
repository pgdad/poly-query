// Package physical is the physical planner: it maps an (optimized) logical
// plan to physical operators and alone takes every execution decision —
// access paths (table scan with row-group skipping vs index scan, the
// table columns a scan reads), join algorithms (hash with build side /
// sort-merge / nested loop, honouring the join option), hash aggregation
// and distinct, top-N sort, the operators of correlated subqueries
// (parameter lookups, materialization), and the execution mode, thread
// count and use of native kernels. It also renders plans as EXPLAIN JSON
// (spec/storage/indexes-and-planning.md §4).
package physical

import (
	"polyquery/internal/index"
	"polyquery/internal/plan"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Node is a physical plan operator. Its output rows follow Schema().
type Node interface {
	Schema() []plan.Column
	Children() []Node
}

// TableScan reads the listed table columns (by ordinal) of every row. Row
// groups whose statistics show that they cannot satisfy one of Filters
// (derived from the WHERE conjuncts evaluated directly above the scan) are
// skipped.
type TableScan struct {
	Table   *storage.Table
	Ords    []int
	Cols    []plan.Column
	Filters []ColumnFilter
}

// IndexScan reads the listed columns of the rows an index lookup returns,
// in row-ID order: rows equal to one of Points (Point lookups) or within
// Range (BTREE range lookups). Cond is the predicate the lookup answers.
type IndexScan struct {
	Table  *storage.Table
	Index  *index.Index
	Ords   []int
	Cols   []plan.Column
	Point  bool
	Points []types.Value
	Range  index.Range
	Empty  bool // the lookup provably returns no rows
	Cond   plan.Expr
}

// Values produces constant rows.
type Values struct {
	Rows [][]plan.Expr
	Cols []plan.Column
}

// Filter keeps rows for which Pred is TRUE.
type Filter struct {
	Input Node
	Pred  plan.Expr
}

// Project computes output expressions.
type Project struct {
	Input Node
	Exprs []plan.Expr
	Cols  []plan.Column
}

// HashAggregate groups rows by Keys in a hash table and computes Aggs.
// Without keys it produces exactly one row.
type HashAggregate struct {
	Input   Node
	Keys    []plan.Expr
	KeyCols []plan.Column
	Aggs    []*plan.AggCall
	AggCols []plan.Column
}

// HashJoin is an equi-join: rows match when LeftKeys equal RightKeys (NULL
// keys never match) and Residual (if any) is TRUE. The build side is the
// right input unless BuildLeft is set (INNER joins only). Output rows are
// left columns then right columns.
type HashJoin struct {
	Kind        plan.JoinKind
	Left, Right Node
	LeftKeys    []plan.Expr
	RightKeys   []plan.Expr
	Residual    plan.Expr
	BuildLeft   bool
}

// MergeJoin is a sort-merge equi-join: both inputs are sorted by their
// join keys and merged; rows match when LeftKeys equal RightKeys (NULL keys
// never match) and Residual (if any) is TRUE. Output rows are left columns
// then right columns.
type MergeJoin struct {
	Kind        plan.JoinKind
	Left, Right Node
	LeftKeys    []plan.Expr
	RightKeys   []plan.Expr
	Residual    plan.Expr
}

// NestedLoopJoin evaluates Cond (nil: always true) for every pair of rows;
// the right input is materialized.
type NestedLoopJoin struct {
	Kind        plan.JoinKind
	Left, Right Node
	Cond        plan.Expr
}

// Sort orders its input; Limit ≥ 0 means only the first Limit rows are
// needed (top-N).
type Sort struct {
	Input Node
	Keys  []plan.SortKey
	Limit int64
}

// Limit skips Offset rows and returns at most Count rows (constant
// expressions; nil means absent).
type Limit struct {
	Input  Node
	Count  plan.Expr
	Offset plan.Expr
}

// HashDistinct removes duplicate rows.
type HashDistinct struct {
	Input Node
}

// UnionAll concatenates the rows of its inputs in order. Output column j is
// read from column InputCols[i][j] of input i (inputs may produce further
// columns, which are ignored).
type UnionAll struct {
	Inputs    []Node
	InputCols [][]plan.Column
	Cols      []plan.Column
}

// ParamLookup appears inside correlated subquery plans: it returns the rows
// of its uncorrelated input whose InnerKeys equal the OuterKeys (expressions
// over outer-query values) and that satisfy Residual. The input is hashed
// by InnerKeys once per query and probed on every evaluation.
type ParamLookup struct {
	Input     Node
	InnerKeys []plan.Expr
	OuterKeys []plan.Expr
	Residual  plan.Expr
}

// Materialize appears inside correlated subquery plans: its uncorrelated
// input is computed once per query and replayed on every evaluation.
type Materialize struct {
	Input Node
}

// Schema implementations.
func (n *TableScan) Schema() []plan.Column { return n.Cols }
func (n *IndexScan) Schema() []plan.Column { return n.Cols }
func (n *Values) Schema() []plan.Column    { return n.Cols }
func (n *Filter) Schema() []plan.Column    { return n.Input.Schema() }
func (n *Project) Schema() []plan.Column   { return n.Cols }
func (n *HashAggregate) Schema() []plan.Column {
	return append(append([]plan.Column(nil), n.KeyCols...), n.AggCols...)
}
func (n *HashJoin) Schema() []plan.Column {
	return append(append([]plan.Column(nil), n.Left.Schema()...), n.Right.Schema()...)
}
func (n *MergeJoin) Schema() []plan.Column {
	return append(append([]plan.Column(nil), n.Left.Schema()...), n.Right.Schema()...)
}
func (n *NestedLoopJoin) Schema() []plan.Column {
	return append(append([]plan.Column(nil), n.Left.Schema()...), n.Right.Schema()...)
}
func (n *Sort) Schema() []plan.Column         { return n.Input.Schema() }
func (n *Limit) Schema() []plan.Column        { return n.Input.Schema() }
func (n *HashDistinct) Schema() []plan.Column { return n.Input.Schema() }
func (n *UnionAll) Schema() []plan.Column     { return n.Cols }
func (n *ParamLookup) Schema() []plan.Column  { return n.Input.Schema() }
func (n *Materialize) Schema() []plan.Column  { return n.Input.Schema() }

// Children implementations.
func (n *TableScan) Children() []Node      { return nil }
func (n *IndexScan) Children() []Node      { return nil }
func (n *Values) Children() []Node         { return nil }
func (n *Filter) Children() []Node         { return []Node{n.Input} }
func (n *Project) Children() []Node        { return []Node{n.Input} }
func (n *HashAggregate) Children() []Node  { return []Node{n.Input} }
func (n *HashJoin) Children() []Node       { return []Node{n.Left, n.Right} }
func (n *NestedLoopJoin) Children() []Node { return []Node{n.Left, n.Right} }
func (n *MergeJoin) Children() []Node      { return []Node{n.Left, n.Right} }
func (n *Sort) Children() []Node           { return []Node{n.Input} }
func (n *Limit) Children() []Node          { return []Node{n.Input} }
func (n *HashDistinct) Children() []Node   { return []Node{n.Input} }
func (n *UnionAll) Children() []Node       { return n.Inputs }
func (n *ParamLookup) Children() []Node    { return []Node{n.Input} }
func (n *Materialize) Children() []Node    { return []Node{n.Input} }

// Exprs returns the expressions evaluated by node n itself.
func Exprs(n Node) []plan.Expr {
	switch x := n.(type) {
	case *Values:
		var out []plan.Expr
		for _, r := range x.Rows {
			out = append(out, r...)
		}
		return out
	case *Filter:
		return []plan.Expr{x.Pred}
	case *Project:
		return x.Exprs
	case *HashAggregate:
		out := append([]plan.Expr(nil), x.Keys...)
		for _, a := range x.Aggs {
			out = append(out, a)
		}
		return out
	case *HashJoin:
		out := append(append([]plan.Expr(nil), x.LeftKeys...), x.RightKeys...)
		if x.Residual != nil {
			out = append(out, x.Residual)
		}
		return out
	case *MergeJoin:
		out := append(append([]plan.Expr(nil), x.LeftKeys...), x.RightKeys...)
		if x.Residual != nil {
			out = append(out, x.Residual)
		}
		return out
	case *NestedLoopJoin:
		if x.Cond != nil {
			return []plan.Expr{x.Cond}
		}
	case *Sort:
		out := make([]plan.Expr, len(x.Keys))
		for i, k := range x.Keys {
			out[i] = k.Expr
		}
		return out
	case *ParamLookup:
		out := append(append([]plan.Expr(nil), x.InnerKeys...), x.OuterKeys...)
		if x.Residual != nil {
			out = append(out, x.Residual)
		}
		return out
	case *Limit:
		var out []plan.Expr
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

// Plan is a physical plan: the root operator plus the physical plans of all
// subqueries referenced by its expressions (and theirs, transitively), and
// how they are executed.
type Plan struct {
	Root     Node
	Subplans map[*plan.Subquery]Node
	Exec     Execution
}

// Options influence physical planning.
type Options struct {
	// Join forces a join algorithm: "", "auto", "hash", "merge" or
	// "nested_loop". Joins without an equality conjunct between the inputs
	// always use a nested loop.
	Join string
	// UseIndexes enables index selection.
	UseIndexes bool
	// Indexes returns the indexes of a table version (nil: none).
	Indexes func(*storage.Table) []*index.Index
	// EvalConst evaluates constant expressions (search arguments).
	EvalConst func(plan.Expr) (types.Value, error)
	// Mode is the requested execution model: "", "auto", "row" or
	// "vectorized".
	Mode string
	// Threads is the requested number of worker threads (≤ 0: use
	// DefaultThreads).
	Threads, DefaultThreads int
	// Native requests the native kernels (only set when they are loaded).
	Native bool
}
