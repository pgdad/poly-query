package optimizer

import (
	"polyquery/internal/interrupt"
	"polyquery/internal/plan"
)

// ColumnPruning (projection pushdown) removes columns that no operator
// above needs: scans list only the table columns referenced by the plan,
// and projections compute only the outputs their consumer reads (so
// expressions that are never used are never evaluated). The plan's output
// columns, the inputs of DISTINCT and UNION ALL, and aggregation outputs
// are kept as they are.
//
// Inside a correlated subquery, projection outputs that reference outer
// columns are kept, so the correlation of every subtree — which the
// physical planner uses to decide what is computed once per query and what
// per outer row — is unchanged.
type ColumnPruning struct {
	// Interrupt aborts the rule at the query's deadline (nil: never).
	Interrupt *interrupt.Checker
}

// Name implements Rule.
func (ColumnPruning) Name() string { return "column_pruning" }

// Apply implements Rule.
func (r ColumnPruning) Apply(n plan.Node) plan.Node {
	return everyPlan(n, func(n plan.Node) plan.Node {
		p := pruner{outer: idSet(plan.FreeColumns(n)), intr: r.Interrupt}
		return p.prune(n, idSet(n.Schema()))
	})
}

type pruner struct {
	// outer holds the outer columns the plan references (correlated
	// subqueries).
	outer map[plan.ColumnID]bool
	intr  *interrupt.Checker
}

// prune returns n restricted to the output columns in req (and those it
// cannot drop). req may contain IDs n does not produce.
func (p pruner) prune(n plan.Node, req map[plan.ColumnID]bool) plan.Node {
	tick(p.intr)
	switch x := n.(type) {
	case *plan.Scan:
		out := &plan.Scan{Table: x.Table}
		for i, c := range x.Cols {
			if req[c.ID] {
				out.Ords = append(out.Ords, x.Ords[i])
				out.Cols = append(out.Cols, c)
			}
		}
		return out
	case *plan.Filter:
		return &plan.Filter{Input: p.prune(x.Input, with(req, x.Pred)), Pred: x.Pred}
	case *plan.Project:
		out := &plan.Project{}
		for i, c := range x.Cols {
			if req[c.ID] || p.correlated(x.Exprs[i]) {
				out.Exprs = append(out.Exprs, x.Exprs[i])
				out.Cols = append(out.Cols, c)
			}
		}
		out.Input = p.prune(x.Input, with(nil, out.Exprs...))
		return out
	case *plan.Aggregate:
		c := *x
		c.Input = p.prune(x.Input, with(nil, plan.NodeExprs(x)...))
		return &c
	case *plan.Join:
		need := with(req, x.Cond)
		return &plan.Join{Kind: x.Kind, Left: p.prune(x.Left, need), Right: p.prune(x.Right, need), Cond: x.Cond}
	case *plan.Sort:
		return &plan.Sort{Input: p.prune(x.Input, with(req, plan.NodeExprs(x)...)), Keys: x.Keys}
	case *plan.Limit:
		return &plan.Limit{Input: p.prune(x.Input, req), Count: x.Count, Offset: x.Offset}
	case *plan.Distinct:
		return &plan.Distinct{Input: p.prune(x.Input, idSet(x.Input.Schema()))}
	case *plan.UnionAll:
		c := &plan.UnionAll{Inputs: make([]plan.Node, len(x.Inputs)), Cols: x.Cols}
		for i, in := range x.Inputs {
			c.Inputs[i] = p.prune(in, idSet(in.Schema()))
		}
		return c
	}
	return n
}

// correlated reports whether e references an outer column.
func (p pruner) correlated(e plan.Expr) bool {
	for id := range plan.RefSet(e) {
		if p.outer[id] {
			return true
		}
	}
	return false
}

// with returns req extended by the columns referenced by exprs (including
// the outer columns of correlated subqueries).
func with(req map[plan.ColumnID]bool, exprs ...plan.Expr) map[plan.ColumnID]bool {
	out := make(map[plan.ColumnID]bool, len(req))
	for id := range req {
		out[id] = true
	}
	for _, e := range exprs {
		if e != nil {
			plan.Refs(e, out)
		}
	}
	return out
}
