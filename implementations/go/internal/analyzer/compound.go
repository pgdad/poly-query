package analyzer

import (
	"strconv"

	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// compound analyzes a UNION ALL query (spec/changes/union-all.md): every
// branch is analyzed as a select block in the same environment, output
// column i gets the common type of column i of all branches (the CASE
// result rule) and the names of the first branch; ORDER BY and LIMIT/OFFSET
// apply to the concatenated result. q.With has already been processed into
// env.
func (a *analyzer) compound(q *ast.Query, outer *scope, env *cteEnv) (plan.Node, error) {
	branches := append([]*ast.Query{q}, q.Union...)
	inputs := make([]plan.Node, len(branches))
	for i, b := range branches {
		core := *b
		core.With, core.Union, core.OrderBy, core.Limit, core.Offset = nil, nil, nil, nil, nil
		n, err := a.selectBlock(&core, outer, env)
		if err != nil {
			return nil, err
		}
		if i > 0 && len(n.Schema()) != len(inputs[0].Schema()) {
			return nil, semanticAt(b.Pos, "UNION ALL branches must have the same number of columns (%d and %d)",
				len(inputs[0].Schema()), len(n.Schema()))
		}
		inputs[i] = n
	}

	first := inputs[0].Schema()
	cols := make([]plan.Column, len(first))
	for j, c := range first {
		t := types.Null
		for i, in := range inputs {
			u := in.Schema()[j].Type
			var err error
			if t, err = unify(branches[i].Pos, "UNION ALL column "+strconv.Itoa(j+1), []types.Type{t, u}); err != nil {
				return nil, err
			}
		}
		cols[j] = a.newColumn(c.Name, t)
	}
	for i, in := range inputs {
		inputs[i] = a.convertBranch(in, cols)
	}
	var node plan.Node = &plan.UnionAll{Inputs: inputs, Cols: cols}

	if len(q.OrderBy) > 0 {
		s := &plan.Sort{Input: node}
		for _, item := range q.OrderBy {
			idx, err := compoundOrderIndex(item, cols)
			if err != nil {
				return nil, err
			}
			k := plan.SortKey{Expr: cols[idx].Ref(), Desc: item.Desc, NullsFirst: !item.Desc}
			if item.NullsFirst != nil {
				k.NullsFirst = *item.NullsFirst
			}
			s.Keys = append(s.Keys, k)
		}
		node = s
	}
	if q.Limit != nil || q.Offset != nil {
		lim := &plan.Limit{Input: node}
		var err error
		if lim.Count, err = a.limitExpr(q.Limit, env); err != nil {
			return nil, err
		}
		if lim.Offset, err = a.limitExpr(q.Offset, env); err != nil {
			return nil, err
		}
		node = lim
	}
	return node, nil
}

// convertBranch converts the output columns of a branch to the compound's
// column types (numeric promotion, typing of NULL columns).
func (a *analyzer) convertBranch(n plan.Node, cols []plan.Column) plan.Node {
	schema := n.Schema()
	same := true
	for j, c := range schema {
		same = same && c.Type == cols[j].Type
	}
	if same {
		return n
	}
	p := &plan.Project{Input: n}
	for j, c := range schema {
		var e plan.Expr = c.Ref()
		if c.Type != cols[j].Type {
			e = &plan.Cast{X: e, To: cols[j].Type}
		}
		p.Exprs = append(p.Exprs, e)
		p.Cols = append(p.Cols, a.newColumn(c.Name, cols[j].Type))
	}
	return p
}

// compoundOrderIndex resolves an ORDER BY item of a compound query, which
// must be an output column name or a 1-based position.
func compoundOrderIndex(item *ast.OrderItem, cols []plan.Column) (int, error) {
	switch x := item.Expr.(type) {
	case *ast.Literal:
		if x.Kind == ast.LitNumber && isDigits(x.Text) {
			k, err := strconv.Atoi(x.Text)
			if err != nil || k < 1 || k > len(cols) {
				return 0, semanticAt(x.Pos, "ORDER BY position %s is out of range", x.Text)
			}
			return k - 1, nil
		}
	case *ast.ColumnRef:
		if x.Qualifier == "" {
			idx := -1
			for i, c := range cols {
				if !storage.EqualFold(c.Name, x.Name) {
					continue
				}
				if idx >= 0 {
					return 0, semanticAt(x.Pos, "ORDER BY name %q is ambiguous", x.Name)
				}
				idx = i
			}
			if idx >= 0 {
				return idx, nil
			}
			return 0, semanticAt(x.Pos, "ORDER BY name %q is not an output column of the UNION ALL", x.Name)
		}
	}
	return 0, semanticAt(item.Pos, "ORDER BY of a UNION ALL must name an output column or give its position")
}
