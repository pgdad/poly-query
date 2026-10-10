package physical

import (
	"bytes"
	"encoding/json"

	"polyquery/internal/plan"
)

// Object is a JSON object that preserves key order.
type Object struct {
	keys []string
	vals []any
}

// Set appends a key/value pair.
func (o *Object) Set(k string, v any) *Object {
	o.keys = append(o.keys, k)
	o.vals = append(o.vals, v)
	return o
}

// MarshalJSON renders the object with keys in insertion order.
func (o *Object) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, k := range o.keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		buf.Write(kb)
		buf.WriteByte(':')
		vb, err := json.Marshal(o.vals[i])
		if err != nil {
			return nil, err
		}
		buf.Write(vb)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

// Explain renders the plan tree as EXPLAIN JSON: every node has "op" and
// "children"; subquery plans appear as "Subquery" children of the operator
// evaluating them.
func Explain(p *Plan) *Object { return explainNode(p, p.Root) }

// ExplainText renders the plan as compact JSON text.
func ExplainText(p *Plan) string {
	b, _ := json.Marshal(Explain(p))
	return string(b)
}

func displayAll(es []plan.Expr) []string {
	out := make([]string, len(es))
	for i, e := range es {
		out[i] = plan.Display(e)
	}
	return out
}

func names(cols []plan.Column) []string {
	out := make([]string, len(cols))
	for i, c := range cols {
		out[i] = c.Name
	}
	return out
}

func explainNode(p *Plan, n Node) *Object {
	o := &Object{}
	switch x := n.(type) {
	case *TableScan:
		cols := make([]string, len(x.Ords))
		for i, ord := range x.Ords {
			cols[i] = x.Table.Columns[ord].Name
		}
		o.Set("op", "TableScan").Set("table", x.Table.Name).Set("columns", cols)
	case *Values:
		o.Set("op", "Values").Set("rows", len(x.Rows))
	case *Filter:
		o.Set("op", "Filter").Set("predicate", plan.Display(x.Pred))
	case *Project:
		o.Set("op", "Project").Set("columns", names(x.Cols)).Set("exprs", displayAll(x.Exprs))
	case *HashAggregate:
		aggs := make([]string, len(x.Aggs))
		for i, a := range x.Aggs {
			aggs[i] = plan.Display(a)
		}
		o.Set("op", "Aggregate").Set("algorithm", "hash").Set("group_by", displayAll(x.Keys)).Set("aggregates", aggs)
	case *HashJoin:
		keys := make([]string, len(x.LeftKeys))
		for i := range keys {
			keys[i] = plan.Display(x.LeftKeys[i]) + " = " + plan.Display(x.RightKeys[i])
		}
		build := "right"
		if x.BuildLeft {
			build = "left"
		}
		o.Set("op", "HashJoin").Set("join_type", x.Kind.String()).Set("keys", keys).Set("build", build)
		if x.Residual != nil {
			o.Set("residual", plan.Display(x.Residual))
		}
	case *NestedLoopJoin:
		o.Set("op", "NestedLoopJoin").Set("join_type", x.Kind.String())
		if x.Cond != nil {
			o.Set("condition", plan.Display(x.Cond))
		}
	case *Sort:
		keys := make([]string, len(x.Keys))
		for i, k := range x.Keys {
			s := plan.Display(k.Expr)
			if k.Desc {
				s += " DESC"
			} else {
				s += " ASC"
			}
			if k.NullsFirst {
				s += " NULLS FIRST"
			} else {
				s += " NULLS LAST"
			}
			keys[i] = s
		}
		o.Set("op", "Sort").Set("keys", keys)
		if x.Limit >= 0 {
			o.Set("top_n", x.Limit)
		}
	case *Limit:
		o.Set("op", "Limit")
		if x.Count != nil {
			o.Set("limit", plan.Display(x.Count))
		}
		if x.Offset != nil {
			o.Set("offset", plan.Display(x.Offset))
		}
	case *HashDistinct:
		o.Set("op", "Distinct").Set("algorithm", "hash")
	case *ParamLookup:
		keys := make([]string, len(x.InnerKeys))
		for i := range keys {
			keys[i] = plan.Display(x.InnerKeys[i]) + " = " + plan.Display(x.OuterKeys[i])
		}
		o.Set("op", "ParamLookup").Set("keys", keys)
		if x.Residual != nil {
			o.Set("residual", plan.Display(x.Residual))
		}
	case *Materialize:
		o.Set("op", "Materialize")
	default:
		o.Set("op", "Unknown")
	}
	children := []*Object{}
	for _, c := range n.Children() {
		children = append(children, explainNode(p, c))
	}
	for _, e := range Exprs(n) {
		plan.Walk(e, func(x plan.Expr) {
			sq, ok := x.(*plan.Subquery)
			if !ok {
				return
			}
			sub, ok := p.Subplans[sq]
			if !ok {
				return
			}
			kind := map[plan.SubqueryKind]string{plan.SubScalar: "scalar", plan.SubExists: "exists", plan.SubIn: "in"}[sq.Kind]
			so := &Object{}
			so.Set("op", "Subquery").Set("kind", kind).Set("correlated", len(sq.Correlated) > 0)
			so.Set("children", []*Object{explainNode(p, sub)})
			children = append(children, so)
		})
	}
	o.Set("children", children)
	return o
}
