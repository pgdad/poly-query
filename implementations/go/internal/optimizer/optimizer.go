// Package optimizer applies result-preserving rewrites to logical plans:
// predicate pushdown through joins (WHERE conjuncts that reference a single
// join input are evaluated below the join, conjuncts spanning both inputs of
// an inner/cross join become join conditions), through projections (derived
// tables and CTEs; output columns are replaced by their defining
// expressions), sorts and DISTINCT, and merging of stacked filters, so that
// predicates reach the table scans. Subquery plans are optimized
// recursively.
package optimizer

import (
	"polyquery/internal/plan"
)

// Optimize returns an optimized copy of the plan.
func Optimize(n plan.Node) plan.Node {
	n = push(n, nil)
	return plan.MapExprs(n, func(e plan.Expr) plan.Expr {
		if sq, ok := e.(*plan.Subquery); ok {
			c := *sq
			c.X = optimizeExpr(sq.X)
			c.Plan = Optimize(sq.Plan)
			return &c
		}
		return nil
	})
}

func optimizeExpr(e plan.Expr) plan.Expr {
	return plan.Map(e, func(x plan.Expr) plan.Expr {
		if sq, ok := x.(*plan.Subquery); ok {
			c := *sq
			c.X = optimizeExpr(sq.X)
			c.Plan = Optimize(sq.Plan)
			return &c
		}
		return nil
	})
}

// push rewrites n with the given predicates (conjuncts that must hold on n's
// output) placed as low as possible.
func push(n plan.Node, preds []plan.Expr) plan.Node {
	switch x := n.(type) {
	case *plan.Filter:
		return push(x.Input, append(preds, plan.Conjuncts(x.Pred)...))
	case *plan.Join:
		return pushJoin(x, preds)
	case *plan.Project:
		down, keep := throughProject(x, preds)
		return filter(&plan.Project{Input: push(x.Input, down), Exprs: x.Exprs, Cols: x.Cols}, keep)
	case *plan.Aggregate:
		c := *x
		c.Input = push(x.Input, nil)
		return filter(&c, preds)
	case *plan.Sort:
		return &plan.Sort{Input: push(x.Input, preds), Keys: x.Keys}
	case *plan.Limit:
		return filter(&plan.Limit{Input: push(x.Input, nil), Count: x.Count, Offset: x.Offset}, preds)
	case *plan.Distinct:
		return &plan.Distinct{Input: push(x.Input, preds)}
	}
	return filter(n, preds)
}

// throughProject splits predicates over a projection's output into those
// that can be evaluated below it (rewritten in terms of the projection's
// input) and those that stay above. Predicates containing subqueries, or
// referencing outputs computed with subqueries or PQ_SLEEP, stay above.
func throughProject(p *plan.Project, preds []plan.Expr) (down, keep []plan.Expr) {
	defs := make(map[plan.ColumnID]plan.Expr, len(p.Cols))
	for i, c := range p.Cols {
		defs[c.ID] = p.Exprs[i]
	}
	for _, pred := range preds {
		ok := !hasSubquery(pred)
		for id := range plan.RefSet(pred) {
			if def, isOutput := defs[id]; isOutput && !movable(def) {
				ok = false
			}
		}
		if !ok {
			keep = append(keep, pred)
			continue
		}
		down = append(down, plan.Map(pred, func(e plan.Expr) plan.Expr {
			if ref, isRef := e.(*plan.ColumnRef); isRef {
				if def, isOutput := defs[ref.ID]; isOutput {
					return def
				}
			}
			return nil
		}))
	}
	return down, keep
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

// side classifies a predicate by the join inputs whose columns it uses.
type side uint8

const (
	sideNone side = iota
	sideLeft
	sideRight
	sideBoth
)

func classify(e plan.Expr, left, right map[plan.ColumnID]bool) side {
	s := sideNone
	for id := range plan.RefSet(e) {
		switch {
		case left[id]:
			s |= sideLeft
		case right[id]:
			s |= sideRight
		}
	}
	return s
}

func idSet(cols []plan.Column) map[plan.ColumnID]bool {
	m := make(map[plan.ColumnID]bool, len(cols))
	for _, c := range cols {
		m[c.ID] = true
	}
	return m
}

func pushJoin(j *plan.Join, preds []plan.Expr) plan.Node {
	left, right := idSet(j.Left.Schema()), idSet(j.Right.Schema())
	var lp, rp, cond, above []plan.Expr
	on := plan.Conjuncts(j.Cond)
	if j.Kind == plan.JoinLeft {
		// WHERE conjuncts on the preserved (left) side filter it directly;
		// ON conjuncts on the right side filter the right input.
		for _, p := range preds {
			if s := classify(p, left, right); s == sideLeft {
				lp = append(lp, p)
			} else {
				above = append(above, p)
			}
		}
		for _, c := range on {
			if s := classify(c, left, right); s == sideRight {
				rp = append(rp, c)
			} else {
				cond = append(cond, c)
			}
		}
		out := &plan.Join{Kind: plan.JoinLeft, Left: push(j.Left, lp), Right: push(j.Right, rp), Cond: plan.And(cond)}
		return filter(out, above)
	}
	for _, p := range append(on, preds...) {
		switch classify(p, left, right) {
		case sideLeft, sideNone:
			lp = append(lp, p)
		case sideRight:
			rp = append(rp, p)
		default:
			cond = append(cond, p)
		}
	}
	kind := plan.JoinInner
	if len(cond) == 0 {
		kind = plan.JoinCross
	}
	return &plan.Join{Kind: kind, Left: push(j.Left, lp), Right: push(j.Right, rp), Cond: plan.And(cond)}
}
