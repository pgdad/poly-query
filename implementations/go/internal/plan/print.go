package plan

import (
	"strconv"
	"strings"
)

// Format renders a logical plan as an indented tree for debugging and
// tests, one operator per line with its children indented below it.
// Expressions use their canonical form (columns as #id:name); the plans of
// subqueries are printed below the operator whose expressions contain them.
//
//	Project [#7:name := #2:name]
//	  Filter (#4:salary > 50)
//	    Scan emp [#1:id, #2:name, #4:salary]
func Format(n Node) string {
	var sb strings.Builder
	formatNode(&sb, n, 0)
	return sb.String()
}

func formatNode(sb *strings.Builder, n Node, depth int) {
	sb.WriteString(strings.Repeat("  ", depth))
	sb.WriteString(describe(n))
	sb.WriteByte('\n')
	for _, e := range NodeExprs(n) {
		Walk(e, func(x Expr) {
			if sq, ok := x.(*Subquery); ok {
				sb.WriteString(strings.Repeat("  ", depth+1))
				sb.WriteString("$subquery" + strconv.Itoa(sq.Seq) + ":")
				if len(sq.Correlated) > 0 {
					sb.WriteString(" correlated " + columnList(sq.Correlated))
				}
				sb.WriteByte('\n')
				formatNode(sb, sq.Plan, depth+2)
			}
		})
	}
	for _, c := range n.Children() {
		formatNode(sb, c, depth+1)
	}
}

// describe renders one operator without its children.
func describe(n Node) string {
	switch x := n.(type) {
	case *Scan:
		return "Scan " + x.Table.Name + " " + columnList(x.Cols)
	case *Values:
		return "Values rows=" + strconv.Itoa(len(x.Rows)) + " " + columnList(x.Cols)
	case *Filter:
		return "Filter " + x.Pred.String()
	case *Project:
		items := make([]string, len(x.Cols))
		for i, c := range x.Cols {
			items[i] = columnName(c) + " := " + x.Exprs[i].String()
		}
		return "Project [" + strings.Join(items, ", ") + "]"
	case *Aggregate:
		keys := make([]string, len(x.KeyCols))
		for i, c := range x.KeyCols {
			keys[i] = columnName(c) + " := " + x.Keys[i].String()
		}
		aggs := make([]string, len(x.AggCols))
		for i, c := range x.AggCols {
			aggs[i] = columnName(c) + " := " + x.Aggs[i].String()
		}
		return "Aggregate keys=[" + strings.Join(keys, ", ") + "] aggs=[" + strings.Join(aggs, ", ") + "]"
	case *Join:
		s := "Join " + x.Kind.String()
		if x.Cond != nil {
			s += " " + x.Cond.String()
		}
		return s
	case *Sort:
		keys := make([]string, len(x.Keys))
		for i, k := range x.Keys {
			keys[i] = k.Expr.String()
			if k.Desc {
				keys[i] += " DESC"
			}
			if k.NullsFirst {
				keys[i] += " NULLS FIRST"
			}
		}
		return "Sort [" + strings.Join(keys, ", ") + "]"
	case *Limit:
		s := "Limit"
		if x.Count != nil {
			s += " count=" + x.Count.String()
		}
		if x.Offset != nil {
			s += " offset=" + x.Offset.String()
		}
		return s
	case *Distinct:
		return "Distinct"
	case *UnionAll:
		return "UnionAll " + columnList(x.Cols)
	}
	return "?"
}

func columnName(c Column) string { return "#" + strconv.Itoa(int(c.ID)) + ":" + c.Name }

func columnList(cols []Column) string {
	names := make([]string, len(cols))
	for i, c := range cols {
		names[i] = columnName(c)
	}
	return "[" + strings.Join(names, ", ") + "]"
}
