package physical

import (
	"polyquery/internal/index"
	"polyquery/internal/plan"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Index selection thresholds (indexes-and-planning.md §3): an index scan is
// chosen when the estimated fraction of matching rows is at most
// indexSelectivity. A point lookup (= or IN) expected to return at most
// smallLookupRows rows is also chosen: probing an index for a handful of rows
// never costs more than a scan, and on small tables (under 50 rows, where
// this rule is the only one that can apply) a single key already exceeds 10%
// of the rows.
const (
	indexSelectivity = 0.10
	smallLookupRows  = 5
	// defaultSelectivity is used for predicates without usable statistics
	// (and for ranges over non-numeric, non-temporal columns).
	defaultSelectivity = 1.0 / 3
)

// numeric maps a value of an ordered numeric/temporal type to a float for
// interpolation; ok is false for other types.
func numeric(t types.Type, v types.Value) (float64, bool) {
	switch t.Kind {
	case types.KindInt64, types.KindDate, types.KindTimestamp:
		return float64(v.I), true
	case types.KindDecimal:
		return types.DecimalToFloat(v.I, t.Scale), true
	case types.KindFloat64:
		return v.F, true
	}
	return 0, false
}

// selectivity estimates the fraction of table rows satisfying a search
// argument from column statistics: equality ≈ 1/distinct per point, ranges
// by linear interpolation between min and max (numeric and temporal types)
// and 1/3 otherwise.
func selectivity(t *storage.Table, s sarg) float64 {
	if s.empty {
		return 0
	}
	st, err := t.ColumnStats(s.ord)
	if err != nil {
		return defaultSelectivity
	}
	if st.Distinct == 0 || st.Min.Null {
		return 0 // only NULLs: nothing matches
	}
	if s.point {
		return min(1, float64(len(s.points))/float64(st.Distinct))
	}
	return rangeSelectivity(t.Columns[s.ord].Type, st, s.rng)
}

func rangeSelectivity(ct types.Type, st storage.ColumnStats, r index.Range) float64 {
	lo, ok1 := numeric(ct, st.Min)
	hi, ok2 := numeric(ct, st.Max)
	if !ok1 || !ok2 {
		return defaultSelectivity
	}
	if hi <= lo {
		if (bounder{ct}).contains(r, st.Min) {
			return 1
		}
		return 0
	}
	from, to := lo, hi
	if r.Lo != nil {
		x, _ := numeric(ct, r.Lo.Value)
		from = max(from, x)
	}
	if r.Hi != nil {
		x, _ := numeric(ct, r.Hi.Value)
		to = min(to, x)
	}
	if to < from {
		return 0
	}
	return (to - from) / (hi - lo)
}

// access is a candidate index access path for a filtered scan.
type access struct {
	ix       *index.Index
	point    bool
	points   []types.Value
	rng      index.Range
	empty    bool
	consumed map[int]bool // conjuncts answered exactly by the lookup
	sel      float64
}

// chooseIndex returns the cheapest index access path for the search
// arguments, or nil if a full scan is preferable.
func (p *planner) chooseIndex(t *storage.Table, sargs []sarg) *access {
	if !p.opts.UseIndexes || p.opts.Indexes == nil || len(sargs) == 0 {
		return nil
	}
	var best *access
	consider := func(a *access) {
		if best == nil || a.sel < best.sel || a.sel == best.sel && a.point && a.ix.Kind == index.Hash && best.ix.Kind != index.Hash {
			best = a
		}
	}
	for _, ix := range p.opts.Indexes(t) {
		var ranged *access
		for _, s := range sargs {
			if s.ord != ix.Ord {
				continue
			}
			if s.point {
				consider(&access{ix: ix, point: true, points: s.points, empty: s.empty,
					consumed: map[int]bool{s.conj: true}, sel: selectivity(t, s)})
				continue
			}
			if !ix.SupportsRange() {
				continue
			}
			if ranged == nil {
				ranged = &access{ix: ix, consumed: map[int]bool{}}
			}
			b := bounder{ix.Type}
			var empty bool
			ranged.rng, empty = b.intersect(ranged.rng, s.rng)
			ranged.empty = ranged.empty || empty || s.empty
			ranged.consumed[s.conj] = true
		}
		if ranged != nil {
			if ranged.empty {
				ranged.sel = 0
			} else {
				ranged.sel = selectivity(t, sarg{ord: ix.Ord, rng: ranged.rng})
			}
			consider(ranged)
		}
	}
	if best == nil {
		return nil
	}
	if best.sel <= indexSelectivity || best.point && best.sel*float64(t.Rows) <= smallLookupRows {
		return best
	}
	return nil
}

// filterSelectivity estimates the fraction of rows of a scanned table that
// satisfy all conjuncts (assuming independence).
func (p *planner) filterSelectivity(t *storage.Table, conjuncts []plan.Expr, sargs []sarg) float64 {
	sel := 1.0
	covered := map[int]bool{}
	for _, s := range sargs {
		sel *= selectivity(t, s)
		covered[s.conj] = true
	}
	for i := range conjuncts {
		if !covered[i] {
			sel *= defaultSelectivity
		}
	}
	return sel
}
