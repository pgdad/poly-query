package optimizer

import (
	"slices"

	"polyquery/internal/interrupt"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// JoinReorder reorders chains of inner joins (best applied after predicate
// pushdown, which turns WHERE conjuncts into join conditions).
//
// A tree of INNER/CROSS joins is flattened into its inputs ("leaves": scans
// with their pushed-down filters, LEFT joins, derived tables, …) and its
// join conjuncts. It is rebuilt left-deep, greedily: start with the leaf
// with the smallest estimated cardinality, then repeatedly join the
// smallest leaf connected to the joined set by a join conjunct (a cross
// product only if the join graph is disconnected). Each conjunct is
// attached to the first join where all its columns are available. A
// projection on top restores the original column order. Inner joins are
// commutative and associative, so results are unchanged; this avoids
// cross products caused by the FROM order and keeps intermediate results
// small.
type JoinReorder struct {
	// Interrupt aborts the rule at the query's deadline (nil: never).
	Interrupt *interrupt.Checker
}

// Name implements Rule.
func (JoinReorder) Name() string { return "join_reorder" }

// Apply implements Rule.
func (r JoinReorder) Apply(n plan.Node) plan.Node {
	return everyPlan(n, reorderer{r.Interrupt}.reorder)
}

type reorderer struct{ intr *interrupt.Checker }

func (ro reorderer) reorder(n plan.Node) plan.Node {
	tick(ro.intr)
	switch x := n.(type) {
	case *plan.Join:
		if x.Kind == plan.JoinLeft {
			return &plan.Join{Kind: x.Kind, Left: ro.reorder(x.Left), Right: ro.reorder(x.Right), Cond: x.Cond}
		}
		var leaves []plan.Node
		var conds []plan.Expr
		flattenJoins(x, &leaves, &conds)
		for i, l := range leaves {
			leaves[i] = ro.reorder(l)
		}
		if len(leaves) < 3 {
			return rebuildPair(x, leaves, conds)
		}
		return ro.greedyJoin(x.Schema(), leaves, conds)
	case *plan.Filter:
		return &plan.Filter{Input: ro.reorder(x.Input), Pred: x.Pred}
	case *plan.Project:
		return &plan.Project{Input: ro.reorder(x.Input), Exprs: x.Exprs, Cols: x.Cols}
	case *plan.Aggregate:
		c := *x
		c.Input = ro.reorder(x.Input)
		return &c
	case *plan.Sort:
		return &plan.Sort{Input: ro.reorder(x.Input), Keys: x.Keys}
	case *plan.Limit:
		return &plan.Limit{Input: ro.reorder(x.Input), Count: x.Count, Offset: x.Offset}
	case *plan.Distinct:
		return &plan.Distinct{Input: ro.reorder(x.Input)}
	case *plan.UnionAll:
		c := &plan.UnionAll{Inputs: make([]plan.Node, len(x.Inputs)), Cols: x.Cols}
		for i, in := range x.Inputs {
			c.Inputs[i] = ro.reorder(in)
		}
		return c
	}
	return n
}

func flattenJoins(n plan.Node, leaves *[]plan.Node, conds *[]plan.Expr) {
	if j, ok := n.(*plan.Join); ok && j.Kind != plan.JoinLeft {
		flattenJoins(j.Left, leaves, conds)
		flattenJoins(j.Right, leaves, conds)
		*conds = append(*conds, plan.Conjuncts(j.Cond)...)
		return
	}
	*leaves = append(*leaves, n)
}

func rebuildPair(j *plan.Join, leaves []plan.Node, conds []plan.Expr) plan.Node {
	return &plan.Join{Kind: j.Kind, Left: leaves[0], Right: leaves[1], Cond: plan.And(conds)}
}

// estimate is a coarse cardinality estimate from table sizes.
func estimate(n plan.Node) float64 {
	switch x := n.(type) {
	case *plan.Scan:
		return float64(x.Table.Rows)
	case *plan.Values:
		return float64(len(x.Rows))
	case *plan.Filter:
		e := estimate(x.Input)
		for range plan.Conjuncts(x.Pred) {
			e /= 3
		}
		return e
	case *plan.Join:
		l, r := estimate(x.Left), estimate(x.Right)
		if x.Kind == plan.JoinCross {
			return l * r
		}
		return max(l, r)
	case *plan.Aggregate:
		if len(x.Keys) == 0 {
			return 1
		}
		return estimate(x.Input) / 2
	case *plan.Limit:
		if c, ok := x.Count.(*plan.Literal); ok && !c.Val.Null && c.T.Kind == types.KindInt64 {
			return min(float64(c.Val.I), estimate(x.Input))
		}
	case *plan.UnionAll:
		sum := 0.0
		for _, in := range x.Inputs {
			sum += estimate(in)
		}
		return sum
	}
	if c := n.Children(); len(c) == 1 {
		return estimate(c[0])
	}
	return 1
}

// greedyJoin rebuilds a join tree from its leaves and conjuncts (see
// JoinReorder). A conjunct can be applied when every leaf it references
// has been joined; to pick the next leaf in time linear in the number of
// leaves, each unapplied conjunct tracks how many of its leaves are still
// missing (one missing leaf i makes the conjunct connect i).
func (ro reorderer) greedyJoin(schema []plan.Column, leaves []plan.Node, conds []plan.Expr) plan.Node {
	ests := make([]float64, len(leaves))
	leafOf := map[plan.ColumnID]int{}
	for i, l := range leaves {
		ests[i] = estimate(l)
		for _, c := range l.Schema() {
			leafOf[c.ID] = i
		}
	}
	// condLeaves[c]: the leaves conjunct c references (outer references of
	// correlated subqueries are always available); leafConds the inverse.
	condLeaves := make([][]int, len(conds))
	leafConds := make([][]int, len(leaves))
	for c, e := range conds {
		seen := map[int]bool{}
		for id := range plan.RefSet(e) {
			if l, ok := leafOf[id]; ok && !seen[l] {
				seen[l] = true
				condLeaves[c] = append(condLeaves[c], l)
				leafConds[l] = append(leafConds[l], c)
			}
		}
	}
	used := make([]bool, len(leaves))
	applied := make([]bool, len(conds))
	missing := make([]int, len(conds))   // referenced leaves not yet joined
	ready := map[int]bool{}              // unapplied conjuncts with no missing leaf
	connects := make([]int, len(leaves)) // unapplied conjuncts whose only missing leaf is i
	lastMissing := func(c int) int {
		for _, l := range condLeaves[c] {
			if !used[l] {
				return l
			}
		}
		return -1
	}
	for c := range conds {
		missing[c] = len(condLeaves[c])
		switch missing[c] {
		case 0:
			ready[c] = true
		case 1:
			connects[condLeaves[c][0]]++
		}
	}
	use := func(i int) {
		used[i] = true
		for _, c := range leafConds[i] {
			missing[c]--
			if applied[c] {
				continue
			}
			switch missing[c] {
			case 1:
				connects[lastMissing(c)]++
			case 0:
				connects[i]--
				ready[c] = true
			}
		}
	}
	pick := func(needConnected bool) int {
		best := -1
		for i := range leaves {
			tick(ro.intr)
			if used[i] || (needConnected && len(ready) == 0 && connects[i] == 0) {
				continue
			}
			if best < 0 || ests[i] < ests[best] {
				best = i
			}
		}
		return best
	}
	first := pick(false)
	var tree plan.Node = leaves[first]
	use(first)
	for k := 1; k < len(leaves); k++ {
		i := pick(true)
		if i < 0 {
			i = pick(false)
		}
		// Conjuncts covered once i is joined, in their original order.
		var idx []int
		for c := range ready {
			idx = append(idx, c)
		}
		for _, c := range leafConds[i] {
			if !applied[c] && missing[c] == 1 {
				idx = append(idx, c)
			}
		}
		slices.Sort(idx)
		var on []plan.Expr
		for _, c := range idx {
			applied[c] = true
			delete(ready, c)
			if missing[c] == 1 {
				connects[i]--
			}
			on = append(on, conds[c])
		}
		kind := plan.JoinInner
		if len(on) == 0 {
			kind = plan.JoinCross
		}
		tree = &plan.Join{Kind: kind, Left: tree, Right: leaves[i], Cond: plan.And(on)}
		use(i)
	}
	var rest []plan.Expr
	for c, done := range applied {
		if !done {
			rest = append(rest, conds[c])
		}
	}
	tree = filter(tree, rest)
	if sameOrder(tree.Schema(), schema) {
		return tree
	}
	exprs := make([]plan.Expr, len(schema))
	for i, c := range schema {
		exprs[i] = c.Ref()
	}
	return &plan.Project{Input: tree, Exprs: exprs, Cols: schema}
}

func sameOrder(a, b []plan.Column) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].ID != b[i].ID {
			return false
		}
	}
	return true
}
