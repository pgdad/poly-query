package physical

import (
	"fmt"
	"strings"

	"polyquery/internal/plan"
)

// Shared aggregations. A statement may contain the same aggregation more
// than once — typically a CTE referenced twice, which the analyzer expands
// per reference with fresh column IDs. Aggregations whose subtrees are
// self-contained (table scans, filters, projections and aggregations
// without subqueries, test functions or outer references) and identical
// up to column IDs get a common key; execution computes the rows of a key
// once per statement and replays them for every occurrence (tables are
// immutable snapshots, so the occurrences yield the same rows).

// sharedAggregates returns the keys of the aggregations of a plan that
// occur more than once.
func sharedAggregates(p *Plan) map[*HashAggregate]string {
	byKey := map[string][]*HashAggregate{}
	var visit func(Node)
	visit = func(n Node) {
		if a, ok := n.(*HashAggregate); ok {
			if key, ok := fingerprint(a); ok {
				byKey[key] = append(byKey[key], a)
			}
		}
		for _, c := range n.Children() {
			visit(c)
		}
	}
	visit(p.Root)
	for _, sub := range p.Subplans {
		visit(sub)
	}
	var shared map[*HashAggregate]string
	for key, nodes := range byKey {
		if len(nodes) < 2 {
			continue
		}
		if shared == nil {
			shared = map[*HashAggregate]string{}
		}
		for _, a := range nodes {
			shared[a] = key
		}
	}
	return shared
}

// fingerprint renders a self-contained subtree with the column IDs it
// produces renumbered in order of production; ok is false for subtrees
// that cannot be shared.
func fingerprint(n Node) (string, bool) {
	var sb strings.Builder
	ids := map[plan.ColumnID]plan.ColumnID{}
	if !render(&sb, n, ids) {
		return "", false
	}
	return sb.String(), true
}

// render writes the subtree (children first, so the columns they produce
// are numbered when expressions refer to them).
func render(sb *strings.Builder, n Node, ids map[plan.ColumnID]plan.ColumnID) bool {
	for _, c := range n.Children() {
		if !render(sb, c, ids) {
			return false
		}
	}
	cols := func(cs []plan.Column) {
		for _, c := range cs {
			id := plan.ColumnID(len(ids))
			ids[c.ID] = id
			fmt.Fprintf(sb, " #%d:%s", id, c.Type)
		}
	}
	expr := func(e plan.Expr) bool {
		canon, ok := canonical(e, ids)
		if ok {
			sb.WriteString(" " + canon)
		}
		return ok
	}
	switch x := n.(type) {
	case *TableScan:
		fmt.Fprintf(sb, "(scan %p %v %+v", x.Table, x.Ords, x.Filters)
		cols(x.Cols)
	case *Filter:
		sb.WriteString("(filter")
		if !expr(x.Pred) {
			return false
		}
	case *Project:
		sb.WriteString("(project")
		for _, e := range x.Exprs {
			if !expr(e) {
				return false
			}
		}
		cols(x.Cols)
	case *HashAggregate:
		fmt.Fprintf(sb, "(aggregate %v", x.AnyOrder)
		for _, e := range x.Keys {
			if !expr(e) {
				return false
			}
		}
		for _, a := range x.Aggs {
			if !expr(a) {
				return false
			}
		}
		cols(x.KeyCols)
		cols(x.AggCols)
	default:
		return false
	}
	sb.WriteString(")")
	return true
}

// canonical renders e with column references renumbered by ids; ok is
// false if e refers to a column not produced inside the subtree (outer
// references) or evaluates a subquery or test function.
func canonical(e plan.Expr, ids map[plan.ColumnID]plan.ColumnID) (string, bool) {
	ok := true
	c := plan.Map(e, func(x plan.Expr) plan.Expr {
		switch y := x.(type) {
		case *plan.ColumnRef:
			id, found := ids[y.ID]
			if !found {
				ok = false
			}
			return &plan.ColumnRef{ID: id, T: y.T}
		case *plan.Subquery:
			ok = false
		case *plan.Func:
			if y.Name == "PQ_SLEEP" {
				ok = false
			}
		}
		return nil
	})
	if !ok {
		return "", false
	}
	return c.String(), true
}
