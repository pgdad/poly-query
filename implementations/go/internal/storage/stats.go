package storage

import (
	"math"
	"sync"

	"polyquery/internal/types"
)

// ColumnStats are table-level statistics of one column. Min and Max are
// NULL if the column has no non-NULL values. Distinct counts distinct
// non-NULL values exactly.
type ColumnStats struct {
	NullCount int
	Distinct  int
	Min, Max  types.Value
}

type columnStats struct {
	once sync.Once
	st   ColumnStats
	err  error
}

// ColumnStats returns the statistics of column ord, computing them on first
// use (which decodes lazily loaded chunks and may fail).
func (t *Table) ColumnStats(ord int) (ColumnStats, error) {
	cs := &t.stats[ord]
	cs.once.Do(func() { cs.st, cs.err = t.computeStats(ord) })
	return cs.st, cs.err
}

func (t *Table) computeStats(ord int) (ColumnStats, error) {
	typ := t.Columns[ord].Type
	st := ColumnStats{Min: types.NullValue, Max: types.NullValue}
	ints := map[int64]struct{}{}
	floats := map[uint64]struct{}{}
	strs := map[string]struct{}{}
	err := t.ScanColumn(ord, func(_ int, v types.Value) {
		if v.Null {
			st.NullCount++
			return
		}
		switch storageClass(typ) {
		case classFloat:
			f := v.F
			if f == 0 {
				f = 0 // -0.0 and 0.0 are one value
			}
			floats[math.Float64bits(f)] = struct{}{}
		case classString:
			strs[v.S] = struct{}{}
		default:
			ints[v.I] = struct{}{}
		}
		if st.Min.Null || types.Compare(typ, v, typ, st.Min) < 0 {
			st.Min = v
		}
		if st.Max.Null || types.Compare(typ, v, typ, st.Max) > 0 {
			st.Max = v
		}
	})
	st.Distinct = len(ints) + len(floats) + len(strs)
	return st, err
}
