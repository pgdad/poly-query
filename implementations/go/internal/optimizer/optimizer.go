// Package optimizer is the rule-based logical optimizer: it rewrites
// logical plans (package plan) into equivalent, cheaper logical plans. It
// is composed of separately named rules, each in its own file and
// individually testable:
//
//   - constant_folding (fold.go): constant folding and boolean predicate
//     simplification;
//   - predicate_pushdown (pushdown.go): filters move below joins,
//     projections, sorts, DISTINCT and into UNION ALL branches;
//   - join_reorder (reorder.go): chains of inner joins are rebuilt
//     left-deep, smallest estimated input first;
//   - column_pruning (prune.go): scans and projections keep only the
//     columns some operator needs.
//
// Rules see only the logical plan: access paths, join algorithms,
// execution mode and native kernels are chosen afterwards by the physical
// planner (package physical). With the query option optimize: false no
// rule is applied.
package optimizer

import (
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Rule is a named, result-preserving rewrite of a logical plan. Rules
// process the plans of nested subqueries too and never modify their input.
type Rule interface {
	Name() string
	Apply(plan.Node) plan.Node
}

// EvalFunc evaluates a constant expression.
type EvalFunc func(plan.Expr) (types.Value, error)

// Options configure the optimizer.
type Options struct {
	// Disabled applies no rule at all (query option optimize: false).
	Disabled bool
	// EvalConst evaluates constant expressions (nil disables folding).
	EvalConst EvalFunc
}

// Optimizer applies its rules in order.
type Optimizer struct {
	Rules []Rule
}

// New returns the optimizer configured by opts: the default rule sequence,
// or no rules when optimization is disabled.
func New(opts Options) *Optimizer {
	if opts.Disabled {
		return &Optimizer{}
	}
	return &Optimizer{Rules: []Rule{
		ConstantFolding{Eval: opts.EvalConst},
		PredicatePushdown{},
		JoinReorder{},
		ColumnPruning{},
	}}
}

// Optimize applies every rule to the plan in order.
func (o *Optimizer) Optimize(n plan.Node) plan.Node {
	for _, r := range o.Rules {
		n = r.Apply(n)
	}
	return n
}

// Optimize returns the plan optimized with the rules selected by opts.
func Optimize(n plan.Node, opts Options) plan.Node { return New(opts).Optimize(n) }

// everyPlan applies a plan rewrite to n and then to the plans of all
// subqueries nested in the result's expressions (recursively).
func everyPlan(n plan.Node, f func(plan.Node) plan.Node) plan.Node {
	return plan.MapExprs(f(n), func(e plan.Expr) plan.Expr { return subqueryPlans(e, f) })
}

// subqueryPlans returns a copy of subquery e whose plan (and those of the
// subqueries in its tested value) is rewritten by everyPlan; nil if e is
// not a subquery.
func subqueryPlans(e plan.Expr, f func(plan.Node) plan.Node) plan.Expr {
	sq, ok := e.(*plan.Subquery)
	if !ok {
		return nil
	}
	c := *sq
	c.X = plan.Map(sq.X, func(x plan.Expr) plan.Expr { return subqueryPlans(x, f) })
	c.Plan = everyPlan(sq.Plan, f)
	return &c
}

func hasSubquery(e plan.Expr) bool {
	found := false
	plan.Walk(e, func(x plan.Expr) {
		if _, ok := x.(*plan.Subquery); ok {
			found = true
		}
	})
	return found
}

// movable reports whether an expression may be evaluated an additional
// time below a projection.
func movable(e plan.Expr) bool {
	ok := true
	plan.Walk(e, func(x plan.Expr) {
		switch y := x.(type) {
		case *plan.Subquery, *plan.AggCall:
			ok = false
		case *plan.Func:
			if y.Name == "PQ_SLEEP" {
				ok = false
			}
		}
	})
	return ok
}

func filter(n plan.Node, preds []plan.Expr) plan.Node {
	if len(preds) == 0 {
		return n
	}
	return &plan.Filter{Input: n, Pred: plan.And(preds)}
}

func idSet(cols []plan.Column) map[plan.ColumnID]bool {
	m := make(map[plan.ColumnID]bool, len(cols))
	for _, c := range cols {
		m[c.ID] = true
	}
	return m
}
