package analyzer

import (
	"strconv"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// selItem is one select-list output column.
type selItem struct {
	expr  plan.Expr
	name  string
	alias bool // name comes from an explicit alias
}

// orderSpec is a resolved ORDER BY item: either an output column index or an
// expression over the input.
type orderSpec struct {
	index      int
	expr       plan.Expr
	desc       bool
	nullsFirst bool
}

// query analyzes a query block (semantics.md §4). outer is the scope of the
// enclosing query (nil at top level), env the visible CTEs.
func (a *analyzer) query(q *ast.Query, outer *scope, env *cteEnv) (plan.Node, error) {
	seen := map[string]bool{}
	for _, c := range q.With {
		key := storage.FoldKey(c.Name)
		if seen[key] {
			return nil, semanticAt(c.Pos, "duplicate CTE name %q", c.Name)
		}
		seen[key] = true
		def := &cteDef{def: c, env: env, outer: outer}
		if _, _, err := a.cteRelation(def); err != nil { // validate even if unused
			return nil, err
		}
		env = &cteEnv{def: def, parent: env}
	}

	sc := &scope{parent: outer}
	var input plan.Node = &plan.Values{Rows: [][]plan.Expr{{}}}
	if q.From != nil {
		var err error
		if input, err = a.from(q.From, sc, env); err != nil {
			return nil, err
		}
	}

	if q.Where != nil {
		pred, err := a.newBinder(sc, env, nil, "WHERE").bind(q.Where)
		if err != nil {
			return nil, err
		}
		if !isBoolish(pred.Type()) {
			return nil, typeAt(q.Where.Position(), "WHERE condition must be BOOLEAN, not %s", pred.Type())
		}
		input = &plan.Filter{Input: input, Pred: pred}
	}

	var aggs []*plan.AggCall
	items, err := a.selectList(q, sc, env, &aggs)
	if err != nil {
		return nil, err
	}
	visible := len(items)

	keys, err := a.groupBy(q, sc, env, items)
	if err != nil {
		return nil, err
	}

	var having plan.Expr
	if q.Having != nil {
		if having, err = a.newBinder(sc, env, &aggs, "HAVING").bind(q.Having); err != nil {
			return nil, err
		}
		if !isBoolish(having.Type()) {
			return nil, typeAt(q.Having.Position(), "HAVING condition must be BOOLEAN, not %s", having.Type())
		}
	}

	orders, err := a.orderBy(q, sc, env, items, &aggs)
	if err != nil {
		return nil, err
	}

	if len(keys) > 0 || len(aggs) > 0 || q.Having != nil {
		g := a.newGrouping(sc, keys)
		for i := range items {
			if items[i].expr, err = g.rewrite(items[i].expr); err != nil {
				return nil, err
			}
		}
		if having, err = g.rewrite(having); err != nil {
			return nil, err
		}
		for i := range orders {
			if orders[i].expr, err = g.rewrite(orders[i].expr); err != nil {
				return nil, err
			}
		}
		input = &plan.Aggregate{Input: input, Keys: keys, KeyCols: g.keyCols, Aggs: g.aggs, AggCols: g.aggCols}
		if having != nil {
			input = &plan.Filter{Input: input, Pred: having}
		}
	}

	// ORDER BY expressions equal to a select item sort by that item; others
	// become hidden output columns (not allowed with DISTINCT).
	for i := range orders {
		o := &orders[i]
		if o.expr == nil {
			continue
		}
		key := o.expr.String()
		o.index = -1
		for j := 0; j < visible; j++ {
			if items[j].expr.String() == key {
				o.index = j
				break
			}
		}
		if o.index < 0 {
			if q.Distinct {
				return nil, semanticAt(q.OrderBy[i].Pos, "ORDER BY expressions must appear in the select list of a SELECT DISTINCT")
			}
			for j := visible; j < len(items); j++ {
				if items[j].expr.String() == key {
					o.index = j
				}
			}
			if o.index < 0 {
				items = append(items, selItem{expr: o.expr, name: "_order" + strconv.Itoa(len(items)+1)})
				o.index = len(items) - 1
			}
		}
	}

	proj := &plan.Project{Input: input}
	for _, it := range items {
		proj.Exprs = append(proj.Exprs, it.expr)
		proj.Cols = append(proj.Cols, a.newColumn(it.name, it.expr.Type()))
	}
	var node plan.Node = proj
	if q.Distinct {
		node = &plan.Distinct{Input: node}
	}
	if len(orders) > 0 {
		s := &plan.Sort{Input: node}
		for _, o := range orders {
			s.Keys = append(s.Keys, plan.SortKey{Expr: proj.Cols[o.index].Ref(), Desc: o.desc, NullsFirst: o.nullsFirst})
		}
		node = s
	}
	if q.Limit != nil || q.Offset != nil {
		lim := &plan.Limit{Input: node}
		if lim.Count, err = a.limitExpr(q.Limit, env); err != nil {
			return nil, err
		}
		if lim.Offset, err = a.limitExpr(q.Offset, env); err != nil {
			return nil, err
		}
		node = lim
	}
	if len(items) > visible {
		trim := &plan.Project{Input: node}
		for _, c := range proj.Cols[:visible] {
			trim.Exprs = append(trim.Exprs, c.Ref())
			trim.Cols = append(trim.Cols, a.newColumn(c.Name, c.Type))
		}
		node = trim
	}
	return node, nil
}

func isBoolish(t types.Type) bool { return t.Kind == types.KindBoolean || t.Kind == types.KindNull }

// selectList binds the select items, expanding stars and naming outputs
// (semantics.md §3).
func (a *analyzer) selectList(q *ast.Query, sc *scope, env *cteEnv, aggs *[]*plan.AggCall) ([]selItem, error) {
	var items []selItem
	for _, it := range q.Items {
		if it.Star {
			expanded, err := expandStar(sc, it)
			if err != nil {
				return nil, err
			}
			items = append(items, expanded...)
			continue
		}
		e, err := a.newBinder(sc, env, aggs, "").bind(it.Expr)
		if err != nil {
			return nil, err
		}
		item := selItem{expr: e, name: it.Alias, alias: it.HasAlias}
		if !it.HasAlias {
			if _, ok := it.Expr.(*ast.ColumnRef); ok {
				item.name = e.(*plan.ColumnRef).Name
			}
		}
		items = append(items, item)
	}
	for i := range items {
		if items[i].name == "" {
			items[i].name = "_col" + strconv.Itoa(i+1)
		}
	}
	return items, nil
}

func expandStar(sc *scope, item *ast.SelectItem) ([]selItem, error) {
	var vars []*rangeVar
	if item.Qualifier == "" {
		if len(sc.vars) == 0 {
			return nil, semanticAt(item.Pos, "SELECT * requires a FROM clause")
		}
		vars = sc.vars
	} else {
		for _, v := range sc.vars {
			if storage.EqualFold(v.name, item.Qualifier) {
				vars = append(vars, v)
			}
		}
		if len(vars) == 0 {
			return nil, semanticAt(item.Pos, "unknown table or alias %q", item.Qualifier)
		}
	}
	var items []selItem
	for _, v := range vars {
		for _, c := range v.cols {
			items = append(items, selItem{expr: c.Ref(), name: c.Name})
		}
	}
	return items, nil
}

// groupBy binds the GROUP BY items: ordinals and select aliases refer to
// select items (semantics.md §5).
func (a *analyzer) groupBy(q *ast.Query, sc *scope, env *cteEnv, items []selItem) ([]plan.Expr, error) {
	var keys []plan.Expr
	for _, g := range q.GroupBy {
		var e plan.Expr
		if lit, ok := g.(*ast.Literal); ok && lit.Kind == ast.LitNumber && isDigits(lit.Text) {
			k, err := strconv.Atoi(lit.Text)
			if err != nil || k < 1 || k > len(items) {
				return nil, semanticAt(lit.Pos, "GROUP BY position %s is out of range", lit.Text)
			}
			e = items[k-1].expr
		} else if cr, ok := g.(*ast.ColumnRef); ok && cr.Qualifier == "" && !sc.hasColumn(cr.Name) {
			for _, it := range items {
				if it.alias && storage.EqualFold(it.name, cr.Name) {
					e = it.expr
					break
				}
			}
		}
		if e == nil {
			var err error
			if e, err = a.newBinder(sc, env, nil, "GROUP BY").bind(g); err != nil {
				return nil, err
			}
		}
		if plan.ContainsAgg(e) {
			return nil, semanticAt(g.Position(), "aggregate functions are not allowed in GROUP BY")
		}
		keys = append(keys, e)
	}
	return keys, nil
}

// orderBy resolves ORDER BY items against output columns (ordinals and
// output names) or binds them as input expressions (semantics.md §6).
func (a *analyzer) orderBy(q *ast.Query, sc *scope, env *cteEnv, items []selItem, aggs *[]*plan.AggCall) ([]orderSpec, error) {
	var out []orderSpec
	for _, item := range q.OrderBy {
		o := orderSpec{index: -1, desc: item.Desc, nullsFirst: !item.Desc}
		if item.NullsFirst != nil {
			o.nullsFirst = *item.NullsFirst
		}
		if lit, ok := item.Expr.(*ast.Literal); ok && lit.Kind == ast.LitNumber && isDigits(lit.Text) {
			k, err := strconv.Atoi(lit.Text)
			if err != nil || k < 1 || k > len(items) {
				return nil, semanticAt(lit.Pos, "ORDER BY position %s is out of range", lit.Text)
			}
			o.index = k - 1
			out = append(out, o)
			continue
		}
		if cr, ok := item.Expr.(*ast.ColumnRef); ok && cr.Qualifier == "" {
			for i, it := range items {
				if !storage.EqualFold(it.name, cr.Name) {
					continue
				}
				if o.index >= 0 && items[o.index].expr.String() != it.expr.String() {
					return nil, semanticAt(cr.Pos, "ORDER BY name %q is ambiguous", cr.Name)
				}
				if o.index < 0 {
					o.index = i
				}
			}
			if o.index >= 0 {
				out = append(out, o)
				continue
			}
		}
		e, err := a.newBinder(sc, env, aggs, "ORDER BY").bind(item.Expr)
		if err != nil {
			return nil, err
		}
		o.expr = e
		out = append(out, o)
	}
	return out, nil
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// limitExpr binds a LIMIT/OFFSET expression, which must be a constant INT64.
func (a *analyzer) limitExpr(e ast.Expr, env *cteEnv) (plan.Expr, error) {
	if e == nil {
		return nil, nil
	}
	x, err := a.newBinder(&scope{}, env, nil, "LIMIT/OFFSET").bind(e)
	if err != nil {
		return nil, err
	}
	if !plan.IsConstant(x) {
		return nil, semanticAt(e.Position(), "LIMIT/OFFSET must be a constant expression")
	}
	if k := x.Type().Kind; k != types.KindInt64 && k != types.KindNull {
		return nil, typeAt(e.Position(), "LIMIT/OFFSET must be INT64, not %s", x.Type())
	}
	return x, nil
}

// ---------------------------------------------------------------- FROM

// from analyzes a FROM item, registering its range variables in sc.
func (a *analyzer) from(item ast.FromItem, sc *scope, env *cteEnv) (plan.Node, error) {
	switch f := item.(type) {
	case *ast.TableRef:
		name := f.Name
		if f.Alias != "" {
			name = f.Alias
		}
		if def := env.lookup(f.Name); def != nil {
			node, cols, err := a.cteRelation(def)
			if err != nil {
				return nil, err
			}
			return node, sc.add(f.Pos, &rangeVar{name: name, cols: cols})
		}
		t, ok := a.cat.Get(f.Name)
		if !ok {
			return nil, semanticAt(f.Pos, "unknown table %q", f.Name)
		}
		scan := &plan.Scan{Table: t, Cols: make([]plan.Column, len(t.Columns))}
		for i, c := range t.Columns {
			scan.Cols[i] = a.newColumn(c.Name, c.Type)
		}
		return scan, sc.add(f.Pos, &rangeVar{name: name, cols: scan.Cols})
	case *ast.SubqueryRef:
		node, err := a.query(f.Query, sc.parent, env)
		if err != nil {
			return nil, err
		}
		return node, sc.add(f.Pos, &rangeVar{name: f.Alias, cols: node.Schema()})
	case *ast.Join:
		left, err := a.from(f.Left, sc, env)
		if err != nil {
			return nil, err
		}
		right, err := a.from(f.Right, sc, env)
		if err != nil {
			return nil, err
		}
		j := &plan.Join{Left: left, Right: right}
		switch f.Type {
		case ast.JoinLeft:
			j.Kind = plan.JoinLeft
		case ast.JoinCross:
			j.Kind = plan.JoinCross
		}
		if f.On != nil {
			if j.Cond, err = a.newBinder(sc, env, nil, "ON").bind(f.On); err != nil {
				return nil, err
			}
			if !isBoolish(j.Cond.Type()) {
				return nil, typeAt(f.On.Position(), "ON condition must be BOOLEAN, not %s", j.Cond.Type())
			}
		}
		return j, nil
	}
	return nil, errs.New(errs.InternalError, "unknown FROM item %T", item)
}

// cteRelation analyzes a CTE reference afresh (each reference gets its own
// column IDs) and applies the CTE's column list.
func (a *analyzer) cteRelation(def *cteDef) (plan.Node, []plan.Column, error) {
	node, err := a.query(def.def.Query, def.outer, def.env)
	if err != nil {
		return nil, nil, err
	}
	cols := append([]plan.Column(nil), node.Schema()...)
	if names := def.def.Columns; len(names) > 0 {
		if len(names) != len(cols) {
			return nil, nil, semanticAt(def.def.Pos, "CTE %q has %d columns but %d names were given", def.def.Name, len(cols), len(names))
		}
		for i := range cols {
			cols[i].Name = names[i]
		}
	}
	return node, cols, nil
}

// hasColumn reports whether an unqualified name resolves to an input column
// of this query block.
func (s *scope) hasColumn(name string) bool {
	for _, v := range s.vars {
		for _, c := range v.cols {
			if storage.EqualFold(c.Name, name) {
				return true
			}
		}
	}
	return false
}
