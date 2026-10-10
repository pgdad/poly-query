// Package analyzer performs semantic analysis: it resolves names against the
// catalog, type-checks expressions (inserting implicit promotions), validates
// aggregate usage and produces a logical plan (spec/sql/semantics.md).
package analyzer

import (
	"sort"
	"strconv"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Catalog is the read-only view of tables used during analysis.
type Catalog interface {
	Get(name string) (*storage.Table, bool)
}

// Config holds analysis switches.
type Config struct {
	// TestFunctions enables PQ_SLEEP.
	TestFunctions bool
}

// Analyze validates a parsed statement and returns its logical plan.
func Analyze(stmt ast.Statement, cat Catalog, cfg Config) (plan.Node, error) {
	a := &analyzer{cat: cat, cfg: cfg}
	switch s := stmt.(type) {
	case *ast.Query:
		return a.query(s)
	case *ast.Explain:
		return nil, unsupportedAt(s.Pos, "EXPLAIN is not supported")
	case *ast.CreateIndex:
		return nil, unsupportedAt(s.Pos, "CREATE INDEX is not supported")
	case *ast.DropIndex:
		return nil, unsupportedAt(s.Pos, "DROP INDEX is not supported")
	}
	return nil, errs.New(errs.InternalError, "unknown statement type %T", stmt)
}

type analyzer struct {
	cat Catalog
	cfg Config
}

func unsupportedAt(p ast.Pos, format string, args ...any) error {
	return errs.At(errs.Unsupported, p.Line, p.Col, format, args...)
}

func semanticAt(p ast.Pos, format string, args ...any) error {
	return errs.At(errs.SemanticError, p.Line, p.Col, format, args...)
}

func typeAt(p ast.Pos, format string, args ...any) error {
	return errs.At(errs.TypeError, p.Line, p.Col, format, args...)
}

// rangeVar is a FROM-clause range variable.
type rangeVar struct {
	name   string
	table  *storage.Table
	offset int // position of the table's first column in the input row
}

// scope is the set of range variables visible to expressions.
type scope struct {
	vars []*rangeVar
	used map[*rangeVar]map[int]bool // referenced columns, for pruning
}

func (s *scope) markUsed(v *rangeVar, col int) {
	if s.used == nil {
		s.used = map[*rangeVar]map[int]bool{}
	}
	if s.used[v] == nil {
		s.used[v] = map[int]bool{}
	}
	s.used[v][col] = true
}

// outItem is one select-list output column.
type outItem struct {
	expr plan.Expr
	name string
	bare bool // references input columns outside aggregate arguments
}

func (a *analyzer) query(q *ast.Query) (plan.Node, error) {
	switch {
	case len(q.With) > 0:
		return nil, unsupportedAt(q.With[0].Pos, "WITH is not supported")
	case q.Distinct:
		return nil, unsupportedAt(q.Pos, "SELECT DISTINCT is not supported")
	case len(q.GroupBy) > 0:
		return nil, unsupportedAt(ast.Pos{}, "GROUP BY is not supported")
	case q.Having != nil:
		return nil, unsupportedAt(q.Having.Position(), "HAVING is not supported")
	}

	sc := &scope{}
	var input plan.Node
	var scan *plan.Scan
	switch f := q.From.(type) {
	case nil:
		input = &plan.Values{Rows: [][]plan.Expr{{}}}
	case *ast.TableRef:
		t, ok := a.cat.Get(f.Name)
		if !ok {
			return nil, semanticAt(f.Pos, "unknown table %q", f.Name)
		}
		name := f.Name
		if f.Alias != "" {
			name = f.Alias
		}
		sc.vars = append(sc.vars, &rangeVar{name: name, table: t})
		scan = &plan.Scan{Table: t}
		input = scan
	case *ast.Join:
		return nil, unsupportedAt(f.Pos, "joins are not supported")
	case *ast.SubqueryRef:
		return nil, unsupportedAt(f.Pos, "derived tables are not supported")
	default:
		return nil, errs.New(errs.InternalError, "unknown FROM item %T", f)
	}

	if q.Where != nil {
		b := &binder{a: a, scope: sc, aggClause: "WHERE"}
		pred, err := b.bind(q.Where)
		if err != nil {
			return nil, err
		}
		if k := pred.Type().Kind; k != types.KindBoolean && k != types.KindNull {
			return nil, typeAt(q.Where.Position(), "WHERE condition must be BOOLEAN, not %s", pred.Type())
		}
		input = &plan.Filter{Input: input, Pred: pred}
	}

	var aggs []*plan.AggCall
	var outs []outItem
	for _, item := range q.Items {
		if item.Star {
			expanded, err := expandStar(sc, item)
			if err != nil {
				return nil, err
			}
			outs = append(outs, expanded...)
			continue
		}
		b := &binder{a: a, scope: sc, aggs: &aggs}
		e, err := b.bind(item.Expr)
		if err != nil {
			return nil, err
		}
		name := item.Alias
		if !item.HasAlias {
			if _, ok := item.Expr.(*ast.ColumnRef); ok {
				name = e.(*plan.ColumnRef).Name
			}
		}
		outs = append(outs, outItem{expr: e, name: name, bare: b.bare})
	}
	for i := range outs {
		if outs[i].name == "" {
			outs[i].name = "_col" + strconv.Itoa(i+1)
		}
	}
	visible := len(outs)

	var keys []plan.SortKey
	for _, item := range q.OrderBy {
		idx, err := a.orderKey(item, sc, &outs, visible, &aggs)
		if err != nil {
			return nil, err
		}
		key := plan.SortKey{Index: idx, Desc: item.Desc, NullsFirst: !item.Desc}
		if item.NullsFirst != nil {
			key.NullsFirst = *item.NullsFirst
		}
		keys = append(keys, key)
	}

	if len(aggs) > 0 {
		for _, o := range outs {
			if o.bare {
				return nil, errs.New(errs.SemanticError, "column references outside aggregate functions require GROUP BY")
			}
		}
		input = &plan.Aggregate{Input: input, Aggs: aggs}
	}

	if scan != nil {
		scan.Needed = sortedKeys(sc.used[sc.vars[0]])
	}

	exprs := make([]plan.Expr, len(outs))
	cols := make([]plan.Column, len(outs))
	for i, o := range outs {
		exprs[i] = o.expr
		cols[i] = plan.Column{Name: o.name, Type: o.expr.Type()}
	}
	var node plan.Node = &plan.Project{Input: input, Exprs: exprs, Cols: cols}
	if len(keys) > 0 {
		node = &plan.Sort{Input: node, Keys: keys, Limit: -1}
	}
	if q.Limit != nil || q.Offset != nil {
		lim := &plan.Limit{Input: node}
		var err error
		if lim.Count, err = a.limitExpr(q.Limit, sc); err != nil {
			return nil, err
		}
		if lim.Offset, err = a.limitExpr(q.Offset, sc); err != nil {
			return nil, err
		}
		node = lim
	}
	if len(outs) > visible {
		trim := make([]plan.Expr, visible)
		for i := range trim {
			trim[i] = &plan.ColumnRef{Index: i, Name: cols[i].Name, T: cols[i].Type}
		}
		node = &plan.Project{Input: node, Exprs: trim, Cols: cols[:visible]}
	}
	return node, nil
}

func sortedKeys(m map[int]bool) []int {
	out := make([]int, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Ints(out)
	return out
}

func expandStar(sc *scope, item *ast.SelectItem) ([]outItem, error) {
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
	var outs []outItem
	for _, v := range vars {
		for i, c := range v.table.Columns {
			sc.markUsed(v, i)
			outs = append(outs, outItem{
				expr: &plan.ColumnRef{Index: v.offset + i, Name: c.Name, T: c.Type},
				name: c.Name,
				bare: true,
			})
		}
	}
	return outs, nil
}

// orderKey resolves an ORDER BY item to an index into the projected row,
// appending a hidden projected column when needed (semantics.md §6).
func (a *analyzer) orderKey(item *ast.OrderItem, sc *scope, outs *[]outItem, visible int, aggs *[]*plan.AggCall) (int, error) {
	if lit, ok := item.Expr.(*ast.Literal); ok && lit.Kind == ast.LitNumber && isDigits(lit.Text) {
		k, err := strconv.Atoi(lit.Text)
		if err != nil || k < 1 || k > visible {
			return 0, semanticAt(lit.Pos, "ORDER BY position %s is out of range", lit.Text)
		}
		return k - 1, nil
	}
	if cr, ok := item.Expr.(*ast.ColumnRef); ok && cr.Qualifier == "" {
		match := -1
		for i := 0; i < visible; i++ {
			o := (*outs)[i]
			if !storage.EqualFold(o.name, cr.Name) {
				continue
			}
			if match >= 0 && (*outs)[match].expr.String() != o.expr.String() {
				return 0, semanticAt(cr.Pos, "ORDER BY name %q is ambiguous", cr.Name)
			}
			if match < 0 {
				match = i
			}
		}
		if match >= 0 {
			return match, nil
		}
	}
	b := &binder{a: a, scope: sc, aggs: aggs}
	e, err := b.bind(item.Expr)
	if err != nil {
		return 0, err
	}
	key := e.String()
	for i, o := range *outs {
		if o.expr.String() == key {
			if b.bare {
				(*outs)[i].bare = true
			}
			return i, nil
		}
	}
	*outs = append(*outs, outItem{expr: e, name: "_order" + strconv.Itoa(len(*outs)), bare: b.bare})
	return len(*outs) - 1, nil
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

func (a *analyzer) limitExpr(e ast.Expr, sc *scope) (plan.Expr, error) {
	if e == nil {
		return nil, nil
	}
	b := &binder{a: a, scope: &scope{vars: sc.vars}, aggClause: "LIMIT/OFFSET"}
	x, err := b.bind(e)
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
