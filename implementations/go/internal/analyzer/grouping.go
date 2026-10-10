package analyzer

import (
	"polyquery/internal/errs"
	"polyquery/internal/plan"
)

// grouping rewrites the post-aggregation expressions of an aggregated query
// (select list, HAVING, ORDER BY) over the output of an Aggregate node:
// subexpressions structurally equal to a GROUP BY key become references to
// the key column, aggregate calls become references to aggregate columns,
// and any remaining reference to an input column is a grouping violation
// (semantics.md §5).
type grouping struct {
	a       *analyzer
	input   map[plan.ColumnID]bool
	keyIdx  map[string]int
	keyByID map[plan.ColumnID]int // keys that are plain column references
	keyCols []plan.Column
	aggIdx  map[string]int
	aggs    []*plan.AggCall
	aggCols []plan.Column
}

func (a *analyzer) newGrouping(sc *scope, keys []plan.Expr) *grouping {
	g := &grouping{
		a:       a,
		input:   sc.inputIDs(),
		keyIdx:  map[string]int{},
		keyByID: map[plan.ColumnID]int{},
		aggIdx:  map[string]int{},
	}
	for i, k := range keys {
		name := plan.Display(k)
		if cr, ok := k.(*plan.ColumnRef); ok {
			name = cr.Name
			if _, dup := g.keyByID[cr.ID]; !dup {
				g.keyByID[cr.ID] = i
			}
		}
		if _, dup := g.keyIdx[k.String()]; !dup {
			g.keyIdx[k.String()] = i
		}
		g.keyCols = append(g.keyCols, a.newColumn(name, k.Type()))
	}
	return g
}

func (g *grouping) aggRef(call *plan.AggCall) plan.Expr {
	key := call.String()
	i, ok := g.aggIdx[key]
	if !ok {
		i = len(g.aggs)
		g.aggIdx[key] = i
		g.aggs = append(g.aggs, call)
		g.aggCols = append(g.aggCols, g.a.newColumn(plan.Display(call), call.T))
	}
	return g.aggCols[i].Ref()
}

func groupingError(name string) error {
	return errs.New(errs.SemanticError, "column %q must appear in the GROUP BY clause or be used in an aggregate function", name)
}

func (g *grouping) rewrite(e plan.Expr) (plan.Expr, error) {
	if e == nil {
		return nil, nil
	}
	var err error
	out := plan.Map(e, func(x plan.Expr) plan.Expr {
		if err != nil {
			return x
		}
		if i, ok := g.keyIdx[x.String()]; ok {
			return g.keyCols[i].Ref()
		}
		switch y := x.(type) {
		case *plan.AggCall:
			return g.aggRef(y)
		case *plan.ColumnRef:
			if g.input[y.ID] {
				err = groupingError(y.Name)
			}
			return x
		case *plan.Subquery:
			var r plan.Expr
			r, err = g.subquery(y)
			return r
		}
		return nil
	})
	return out, err
}

// subquery rewrites a subquery evaluated after aggregation: its references
// to grouped input columns are redirected to the key columns.
func (g *grouping) subquery(sq *plan.Subquery) (plan.Expr, error) {
	c := *sq
	var err error
	if c.X, err = g.rewrite(sq.X); err != nil {
		return nil, err
	}
	subst := map[plan.ColumnID]plan.Expr{}
	for _, col := range sq.Correlated {
		if !g.input[col.ID] {
			continue
		}
		i, ok := g.keyByID[col.ID]
		if !ok {
			return nil, groupingError(col.Name)
		}
		subst[col.ID] = g.keyCols[i].Ref()
	}
	if len(subst) > 0 {
		c.Plan = plan.MapExprs(sq.Plan, func(x plan.Expr) plan.Expr {
			if cr, ok := x.(*plan.ColumnRef); ok {
				if r, ok := subst[cr.ID]; ok {
					return r
				}
			}
			return nil
		})
		c.Correlated = plan.FreeColumns(c.Plan)
	}
	return &c, nil
}
