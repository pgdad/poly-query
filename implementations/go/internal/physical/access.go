package physical

import (
	"strings"

	"polyquery/internal/index"
	"polyquery/internal/plan"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// A sarg ("search argument") is a WHERE conjunct of the form
// `column <op> constant`, `column [NOT] BETWEEN constant AND constant` or
// `column IN (constants)` over one scanned table column, translated into
// the column's own domain (same type, DECIMAL at the column's scale) so
// that it can drive index lookups and row-group skipping.
type sarg struct {
	conj   int // index of the conjunct it was derived from
	ord    int // table column ordinal
	point  bool
	points []types.Value // point: the column must equal one of these
	rng    index.Range   // !point: the column must lie in this range
	empty  bool          // no non-NULL value satisfies the conjunct
}

// scanColumn identifies a table column read by a scan: e is the column
// itself, or the column under a value-preserving promotion (INT64 →
// DECIMAL, DATE → TIMESTAMP).
func scanColumn(e plan.Expr, ords map[plan.ColumnID]int) (int, types.Type, bool) {
	if c, ok := e.(*plan.Cast); ok {
		from := c.X.Type().Kind
		if !(from == types.KindInt64 && c.To.Kind == types.KindDecimal) &&
			!(from == types.KindDate && c.To.Kind == types.KindTimestamp) {
			return 0, types.Type{}, false
		}
		e = c.X
	}
	ref, ok := e.(*plan.ColumnRef)
	if !ok {
		return 0, types.Type{}, false
	}
	ord, ok := ords[ref.ID]
	return ord, ref.T, ok
}

// domainValue is a constant translated into a column's domain: v is the
// largest column value ≤ the constant (exact if equal); inf is -1/+1 when
// the constant lies below/above every representable column value.
type domainValue struct {
	v     types.Value
	exact bool
	inf   int
}

// toDomain translates constant v of type vt into the domain of column type
// ct; ok is false for type combinations that are not supported.
func toDomain(ct types.Type, v types.Value, vt types.Type) (domainValue, bool) {
	exactNum := func(t types.Type) bool { return t.Kind == types.KindInt64 || t.Kind == types.KindDecimal }
	switch {
	case exactNum(ct) && exactNum(vt):
		return exactToDomain(ct, types.DecimalOf(vt, v), vt.Scale), true
	case ct.Kind == types.KindFloat64 && vt.Kind == types.KindInt64:
		return domainValue{v: types.FloatValue(float64(v.I)), exact: true}, true
	case ct.Kind == types.KindFloat64 && vt.Kind == types.KindDecimal:
		return domainValue{v: types.FloatValue(types.DecimalValueToFloat(v, vt)), exact: true}, true
	case ct.Kind == types.KindDate && vt.Kind == types.KindTimestamp:
		q := types.FloorDiv(v.I, types.MicrosPerDay)
		return domainValue{v: types.IntValue(q), exact: q*types.MicrosPerDay == v.I}, true
	case ct.Kind == types.KindTimestamp && vt.Kind == types.KindDate:
		return domainValue{v: types.IntValue(v.I * types.MicrosPerDay), exact: true}, true
	case ct.Kind == vt.Kind && ct.Kind != types.KindDecimal && ct.Kind != types.KindNull:
		return domainValue{v: v, exact: true}, true
	}
	return domainValue{}, false
}

// exactToDomain translates the INT64/DECIMAL constant x / 10^vs into the
// domain of an INT64 or DECIMAL column type ct (of any precision): the
// largest value at the column's scale ≤ the constant, or ±inf if that lies
// outside the values the column can hold.
func exactToDomain(ct types.Type, x types.Int128, vs int) domainValue {
	cs := ct.Scale // 0 for INT64
	d := domainValue{exact: true}
	if vs <= cs {
		y, err := types.RescaleWide(x, vs, cs, types.MaxDecimalPrecision)
		if err != nil {
			return domainValue{inf: x.Sign()} // beyond 38 digits (x ≠ 0)
		}
		x = y
	} else {
		x, d.exact = types.FloorWideExact(x, vs-cs)
	}
	// Column capacity: INT64 range, 18 digits (narrow), 38 digits (wide).
	fits := x.IsInt64()
	switch {
	case ct.IsWide():
		fits = true // |x| < 10^38 after the steps above
	case ct.Kind == types.KindDecimal:
		fits = fits && types.FitsPrecision(x.Int64(), types.NarrowDecimalPrecision)
	}
	if !fits {
		return domainValue{inf: x.Sign()}
	}
	if ct.IsWide() {
		d.v = types.WideValue(x)
	} else {
		d.v = types.IntValue(x.Int64())
	}
	return d
}

// bounder converts comparisons into ranges over one column type.
type bounder struct{ t types.Type }

func (b bounder) cmp(x, y types.Value) int { return types.Compare(b.t, x, b.t, y) }

// fromComparison returns the range of column values satisfying
// `column op constant`; empty reports that none does.
func (b bounder) fromComparison(op plan.BinaryOp, d domainValue) (r index.Range, empty bool) {
	lower := func(incl bool) (index.Range, bool) {
		switch d.inf {
		case 1:
			return r, true
		case -1:
			return r, false
		}
		return index.Range{Lo: &index.Bound{Value: d.v, Inclusive: incl}}, false
	}
	upper := func(incl bool) (index.Range, bool) {
		switch d.inf {
		case -1:
			return r, true
		case 1:
			return r, false
		}
		return index.Range{Hi: &index.Bound{Value: d.v, Inclusive: incl}}, false
	}
	switch op {
	case plan.OpGt:
		return lower(false)
	case plan.OpGe:
		return lower(d.exact)
	case plan.OpLt:
		return upper(!d.exact)
	case plan.OpLe:
		return upper(true)
	}
	return r, false
}

// intersect narrows range a by range b; empty reports an empty result.
func (b bounder) intersect(a, c index.Range) (index.Range, bool) {
	if c.Lo != nil && (a.Lo == nil || b.cmp(c.Lo.Value, a.Lo.Value) > 0 ||
		b.cmp(c.Lo.Value, a.Lo.Value) == 0 && !c.Lo.Inclusive) {
		a.Lo = c.Lo
	}
	if c.Hi != nil && (a.Hi == nil || b.cmp(c.Hi.Value, a.Hi.Value) < 0 ||
		b.cmp(c.Hi.Value, a.Hi.Value) == 0 && !c.Hi.Inclusive) {
		a.Hi = c.Hi
	}
	if a.Lo != nil && a.Hi != nil {
		k := b.cmp(a.Lo.Value, a.Hi.Value)
		if k > 0 || k == 0 && !(a.Lo.Inclusive && a.Hi.Inclusive) {
			return a, true
		}
	}
	return a, false
}

// contains reports whether value v lies in range r.
func (b bounder) contains(r index.Range, v types.Value) bool {
	if r.Lo != nil {
		if k := b.cmp(v, r.Lo.Value); k < 0 || k == 0 && !r.Lo.Inclusive {
			return false
		}
	}
	if r.Hi != nil {
		if k := b.cmp(v, r.Hi.Value); k > 0 || k == 0 && !r.Hi.Inclusive {
			return false
		}
	}
	return true
}

// overlaps reports whether range r intersects [lo, hi].
func (b bounder) overlaps(r index.Range, lo, hi types.Value) bool {
	_, empty := b.intersect(r, index.Range{Lo: &index.Bound{Value: lo, Inclusive: true}, Hi: &index.Bound{Value: hi, Inclusive: true}})
	return !empty
}

var flipped = map[plan.BinaryOp]plan.BinaryOp{
	plan.OpEq: plan.OpEq, plan.OpNe: plan.OpNe,
	plan.OpLt: plan.OpGt, plan.OpLe: plan.OpGe, plan.OpGt: plan.OpLt, plan.OpGe: plan.OpLe,
}

// sargs extracts the search arguments of a scan's filter conjuncts.
func (p *planner) sargs(conjuncts []plan.Expr, ords map[plan.ColumnID]int) []sarg {
	var out []sarg
	for i, c := range conjuncts {
		if s, ok := p.sarg(c, ords); ok {
			s.conj = i
			out = append(out, s)
		}
	}
	return out
}

// constant evaluates a constant expression at planning time.
func (p *planner) constant(e plan.Expr) (types.Value, bool) {
	if p.opts.EvalConst == nil || !plan.IsConstant(e) {
		return types.Value{}, false
	}
	v, err := p.opts.EvalConst(e)
	return v, err == nil
}

func (p *planner) sarg(c plan.Expr, ords map[plan.ColumnID]int) (sarg, bool) {
	switch x := c.(type) {
	case *plan.Binary:
		if _, ok := flipped[x.Op]; !ok || x.Op == plan.OpNe {
			return sarg{}, false
		}
		op, colExpr, constExpr := x.Op, x.L, x.R
		if _, _, isCol := scanColumn(x.L, ords); !isCol {
			op, colExpr, constExpr = flipped[x.Op], x.R, x.L
		}
		ord, ct, ok := scanColumn(colExpr, ords)
		if !ok {
			return sarg{}, false
		}
		v, ok := p.constant(constExpr)
		if !ok {
			return sarg{}, false
		}
		s := sarg{ord: ord, point: op == plan.OpEq}
		if v.Null {
			s.empty = true
			return s, true
		}
		d, ok := toDomain(ct, v, constExpr.Type())
		if !ok {
			return sarg{}, false
		}
		if s.point {
			if d.inf == 0 && d.exact {
				s.points = []types.Value{d.v}
			} else {
				s.empty = true
			}
			return s, true
		}
		s.rng, s.empty = bounder{ct}.fromComparison(op, d)
		return s, true
	case *plan.Between:
		if x.Not {
			return sarg{}, false
		}
		ord, ct, ok := scanColumn(x.X, ords)
		if !ok {
			return sarg{}, false
		}
		lo, ok1 := p.constant(x.Lo)
		hi, ok2 := p.constant(x.Hi)
		if !ok1 || !ok2 {
			return sarg{}, false
		}
		s := sarg{ord: ord}
		if lo.Null || hi.Null {
			// NULL bounds make the predicate NULL or FALSE for every row
			// unless the other bound alone decides; keep it simple.
			return sarg{}, false
		}
		dl, ok1 := toDomain(ct, lo, x.Lo.Type())
		dh, ok2 := toDomain(ct, hi, x.Hi.Type())
		if !ok1 || !ok2 {
			return sarg{}, false
		}
		b := bounder{ct}
		r1, e1 := b.fromComparison(plan.OpGe, dl)
		r2, e2 := b.fromComparison(plan.OpLe, dh)
		s.rng, s.empty = b.intersect(r1, r2)
		s.empty = s.empty || e1 || e2
		return s, true
	case *plan.InList:
		if x.Not {
			return sarg{}, false
		}
		ord, ct, ok := scanColumn(x.X, ords)
		if !ok {
			return sarg{}, false
		}
		s := sarg{ord: ord, point: true}
		b := bounder{ct}
		for _, item := range x.List {
			v, ok := p.constant(item)
			if !ok {
				return sarg{}, false
			}
			if v.Null {
				continue // never TRUE
			}
			d, ok := toDomain(ct, v, item.Type())
			if !ok {
				return sarg{}, false
			}
			if d.inf != 0 || !d.exact {
				continue
			}
			dup := false
			for _, q := range s.points {
				if b.cmp(q, d.v) == 0 {
					dup = true
				}
			}
			if !dup {
				s.points = append(s.points, d.v)
			}
		}
		s.empty = len(s.points) == 0
		return s, true
	}
	return sarg{}, false
}

// ColumnFilter is the combined constraint of all search arguments on one
// column; a scan skips row groups whose statistics show that no row can
// satisfy it.
type ColumnFilter struct {
	Ord    int
	Type   types.Type
	Range  index.Range
	Points []types.Value // nil: no point constraint
	Empty  bool
}

// columnFilters merges search arguments per column.
func columnFilters(sargs []sarg, t *storage.Table) []ColumnFilter {
	var out []ColumnFilter
	byOrd := map[int]int{}
	for _, s := range sargs {
		i, ok := byOrd[s.ord]
		if !ok {
			i = len(out)
			byOrd[s.ord] = i
			out = append(out, ColumnFilter{Ord: s.ord, Type: t.Columns[s.ord].Type})
		}
		f := &out[i]
		b := bounder{f.Type}
		if s.empty {
			f.Empty = true
			continue
		}
		if s.point {
			if f.Points == nil {
				f.Points = s.points
			} else {
				var keep []types.Value
				for _, v := range f.Points {
					for _, w := range s.points {
						if b.cmp(v, w) == 0 {
							keep = append(keep, v)
							break
						}
					}
				}
				f.Points = keep
				f.Empty = f.Empty || len(keep) == 0
			}
			continue
		}
		var empty bool
		f.Range, empty = b.intersect(f.Range, s.rng)
		f.Empty = f.Empty || empty
	}
	return out
}

// Skips reports whether no row of a row group with the given column
// statistics can satisfy the filter.
func (f *ColumnFilter) Skips(st storage.ChunkStats, rows int) bool {
	if f.Empty || st.NullCount >= rows {
		return true // every constrained value must be non-NULL
	}
	if !st.HasRange {
		return false
	}
	b := bounder{f.Type}
	if !b.overlaps(f.Range, st.Min, st.Max) {
		return true
	}
	if f.Points != nil {
		for _, v := range f.Points {
			if b.cmp(v, st.Min) >= 0 && b.cmp(v, st.Max) <= 0 && b.contains(f.Range, v) {
				return false
			}
		}
		return true
	}
	return false
}

// describe renders the filter for EXPLAIN.
func (f *ColumnFilter) describe(name string) string {
	if f.Empty {
		return name + ": none"
	}
	var parts []string
	if f.Points != nil {
		vals := make([]string, len(f.Points))
		for i, v := range f.Points {
			vals[i] = types.FormatValue(v, f.Type)
		}
		parts = append(parts, name+" IN ("+strings.Join(vals, ", ")+")")
	}
	if f.Range.Lo != nil {
		op := " > "
		if f.Range.Lo.Inclusive {
			op = " >= "
		}
		parts = append(parts, name+op+types.FormatValue(f.Range.Lo.Value, f.Type))
	}
	if f.Range.Hi != nil {
		op := " < "
		if f.Range.Hi.Inclusive {
			op = " <= "
		}
		parts = append(parts, name+op+types.FormatValue(f.Range.Hi.Value, f.Type))
	}
	if len(parts) == 0 {
		return name + " IS NOT NULL"
	}
	return strings.Join(parts, " AND ")
}
