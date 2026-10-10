package optimizer

import (
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Join reordering for chains of inner joins (after predicate pushdown).
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

func reorder(n plan.Node) plan.Node {
	switch x := n.(type) {
	case *plan.Join:
		if x.Kind == plan.JoinLeft {
			return &plan.Join{Kind: x.Kind, Left: reorder(x.Left), Right: reorder(x.Right), Cond: x.Cond}
		}
		var leaves []plan.Node
		var conds []plan.Expr
		flattenJoins(x, &leaves, &conds)
		for i, l := range leaves {
			leaves[i] = reorder(l)
		}
		if len(leaves) < 3 {
			return rebuildPair(x, leaves, conds)
		}
		return greedyJoin(x.Schema(), leaves, conds)
	case *plan.Filter:
		return &plan.Filter{Input: reorder(x.Input), Pred: x.Pred}
	case *plan.Project:
		return &plan.Project{Input: reorder(x.Input), Exprs: x.Exprs, Cols: x.Cols}
	case *plan.Aggregate:
		c := *x
		c.Input = reorder(x.Input)
		return &c
	case *plan.Sort:
		return &plan.Sort{Input: reorder(x.Input), Keys: x.Keys}
	case *plan.Limit:
		return &plan.Limit{Input: reorder(x.Input), Count: x.Count, Offset: x.Offset}
	case *plan.Distinct:
		return &plan.Distinct{Input: reorder(x.Input)}
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
	}
	if c := n.Children(); len(c) == 1 {
		return estimate(c[0])
	}
	return 1
}

func greedyJoin(schema []plan.Column, leaves []plan.Node, conds []plan.Expr) plan.Node {
	ests := make([]float64, len(leaves))
	ids := make([]map[plan.ColumnID]bool, len(leaves))
	for i, l := range leaves {
		ests[i] = estimate(l)
		ids[i] = idSet(l.Schema())
	}
	refs := make([]map[plan.ColumnID]bool, len(conds))
	for i, c := range conds {
		refs[i] = plan.RefSet(c)
	}
	produced := map[plan.ColumnID]bool{}
	for _, m := range ids {
		for id := range m {
			produced[id] = true
		}
	}
	for _, r := range refs {
		for id := range r {
			if !produced[id] {
				delete(r, id) // outer reference (correlated subquery): always available
			}
		}
	}
	used := make([]bool, len(leaves))
	applied := make([]bool, len(conds))
	have := map[plan.ColumnID]bool{}
	covered := func(c int, extra map[plan.ColumnID]bool) bool {
		for id := range refs[c] {
			if !have[id] && !extra[id] {
				return false
			}
		}
		return true
	}
	connected := func(i int) bool {
		for c := range conds {
			if !applied[c] && covered(c, ids[i]) {
				return true
			}
		}
		return false
	}
	pick := func(needConnected bool) int {
		best := -1
		for i := range leaves {
			if used[i] || (needConnected && !connected(i)) {
				continue
			}
			if best < 0 || ests[i] < ests[best] {
				best = i
			}
		}
		return best
	}
	first := pick(false)
	used[first] = true
	var tree plan.Node = leaves[first]
	for id := range ids[first] {
		have[id] = true
	}
	for k := 1; k < len(leaves); k++ {
		i := pick(true)
		if i < 0 {
			i = pick(false)
		}
		used[i] = true
		var on []plan.Expr
		for c := range conds {
			if !applied[c] && covered(c, ids[i]) {
				applied[c] = true
				on = append(on, conds[c])
			}
		}
		kind := plan.JoinInner
		if len(on) == 0 {
			kind = plan.JoinCross
		}
		tree = &plan.Join{Kind: kind, Left: tree, Right: leaves[i], Cond: plan.And(on)}
		for id := range ids[i] {
			have[id] = true
		}
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
