// Package optimizer applies result-preserving rewrites to logical plans:
// predicate pushdown through joins (WHERE conjuncts that reference a single
// join input are evaluated below the join, conjuncts spanning both inputs of
// an inner/cross join become join conditions) and merging of stacked
// filters. Subquery plans are optimized recursively.
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
		return filter(&plan.Project{Input: push(x.Input, nil), Exprs: x.Exprs, Cols: x.Cols}, preds)
	case *plan.Aggregate:
		c := *x
		c.Input = push(x.Input, nil)
		return filter(&c, preds)
	case *plan.Sort:
		return filter(&plan.Sort{Input: push(x.Input, nil), Keys: x.Keys}, preds)
	case *plan.Limit:
		return filter(&plan.Limit{Input: push(x.Input, nil), Count: x.Count, Offset: x.Offset}, preds)
	case *plan.Distinct:
		return filter(&plan.Distinct{Input: push(x.Input, nil)}, preds)
	}
	return filter(n, preds)
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
