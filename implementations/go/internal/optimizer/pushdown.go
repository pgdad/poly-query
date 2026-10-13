package optimizer

import (
	"polyquery/internal/interrupt"
	"polyquery/internal/plan"
)

// PredicatePushdown moves filter predicates as close to the table scans as
// possible: WHERE conjuncts that reference a single join input are
// evaluated below the join and conjuncts spanning both inputs of an
// inner/cross join become join conditions (so comma joins become inner
// joins); predicates move through projections (derived tables and CTEs;
// output columns are replaced by their defining expressions), sorts,
// DISTINCT and into every UNION ALL branch; stacked filters are merged and
// filters reduced to TRUE disappear. Predicates are never moved below an
// aggregation or a LIMIT, out of the NULL-extended side of a LEFT join, or
// across operators where an extra evaluation would be observable
// (subqueries, PQ_SLEEP).
type PredicatePushdown struct {
	// Interrupt aborts the rule at the query's deadline (nil: never).
	Interrupt *interrupt.Checker
}

// Name implements Rule.
func (PredicatePushdown) Name() string { return "predicate_pushdown" }

// Apply implements Rule.
func (r PredicatePushdown) Apply(n plan.Node) plan.Node {
	pd := pusher{r.Interrupt}
	return everyPlan(n, func(n plan.Node) plan.Node { return pd.push(n, nil) })
}

type pusher struct{ intr *interrupt.Checker }

// push rewrites n with the given predicates (conjuncts that must hold on n's
// output) placed as low as possible.
func (pd pusher) push(n plan.Node, preds []plan.Expr) plan.Node {
	tick(pd.intr)
	switch x := n.(type) {
	case *plan.Filter:
		for _, c := range plan.Conjuncts(x.Pred) {
			if !isTrue(c) {
				preds = append(preds, c)
			}
		}
		return pd.push(x.Input, preds)
	case *plan.Join:
		return pd.pushJoin(x, preds)
	case *plan.Project:
		down, keep := throughProject(x, preds)
		return filter(&plan.Project{Input: pd.push(x.Input, down), Exprs: x.Exprs, Cols: x.Cols}, keep)
	case *plan.Aggregate:
		c := *x
		c.Input = pd.push(x.Input, nil)
		return filter(&c, preds)
	case *plan.Sort:
		return &plan.Sort{Input: pd.push(x.Input, preds), Keys: x.Keys}
	case *plan.Limit:
		return filter(&plan.Limit{Input: pd.push(x.Input, nil), Count: x.Count, Offset: x.Offset}, preds)
	case *plan.Distinct:
		return &plan.Distinct{Input: pd.push(x.Input, preds)}
	case *plan.UnionAll:
		return pd.pushUnion(x, preds)
	}
	return filter(n, preds)
}

// pushUnion pushes predicates over a UNION ALL's output into every branch,
// rewritten in terms of the branch's columns. Predicates containing
// subqueries stay above (their plans must not be duplicated).
func (pd pusher) pushUnion(u *plan.UnionAll, preds []plan.Expr) plan.Node {
	var down, keep []plan.Expr
	for _, p := range preds {
		if hasSubquery(p) {
			keep = append(keep, p)
		} else {
			down = append(down, p)
		}
	}
	out := &plan.UnionAll{Inputs: make([]plan.Node, len(u.Inputs)), Cols: u.Cols}
	for i, in := range u.Inputs {
		branch := make(map[plan.ColumnID]plan.Column, len(u.Cols))
		for j, c := range in.Schema() {
			branch[u.Cols[j].ID] = c
		}
		mapped := make([]plan.Expr, len(down))
		for k, p := range down {
			mapped[k] = plan.Map(p, func(e plan.Expr) plan.Expr {
				if ref, ok := e.(*plan.ColumnRef); ok {
					if c, ok := branch[ref.ID]; ok {
						return c.Ref()
					}
				}
				return nil
			})
		}
		out.Inputs[i] = pd.push(in, mapped)
	}
	return filter(out, keep)
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

func (pd pusher) pushJoin(j *plan.Join, preds []plan.Expr) plan.Node {
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
		out := &plan.Join{Kind: plan.JoinLeft, Left: pd.push(j.Left, lp), Right: pd.push(j.Right, rp), Cond: plan.And(cond)}
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
	return &plan.Join{Kind: kind, Left: pd.push(j.Left, lp), Right: pd.push(j.Right, rp), Cond: plan.And(cond)}
}
