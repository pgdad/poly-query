// Package index implements single-column secondary indexes over immutable
// tables (spec/storage/indexes-and-planning.md §2): HASH indexes (hash table
// from value to row IDs, equality lookups) and BTREE indexes (a sorted
// permutation of the non-NULL rows, equality and range lookups). NULLs are
// never indexed, so no lookup returns them.
//
// Lookup values must already be in the column's domain (same type; DECIMAL
// at the column's scale): the planner converts constants (see Bound).
package index

import (
	"cmp"
	"slices"
	"sort"
	"strings"

	"polyquery/internal/errs"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Kind is an index kind.
type Kind string

// Index kinds.
const (
	Hash  Kind = "HASH"
	BTree Kind = "BTREE"
)

// Def describes an index (as stored in the catalog and in PQCF metadata).
type Def struct {
	Name   string
	Column string // declared column name
	Kind   Kind
}

// Index is a built index over one column of one table version.
type Index struct {
	Def
	Table *storage.Table
	Ord   int // column ordinal
	Type  types.Type

	// HASH
	ints   map[int64][]uint32
	wides  map[types.Int128][]uint32
	floats map[float64][]uint32
	strs   map[string][]uint32
	// BTREE: row IDs ordered by value (ties by row ID) and their keys.
	order     []uint32
	intKeys   []int64
	wideKeys  []types.Int128
	floatKeys []float64
	strKeys   []string
}

// Build creates an index on column def.Column of table t.
func Build(def Def, t *storage.Table) (*Index, error) {
	ord := t.ColumnIndex(def.Column)
	if ord < 0 {
		return nil, errs.New(errs.SemanticError, "unknown column %q in table %q", def.Column, t.Name)
	}
	def.Column = t.Columns[ord].Name
	ix := &Index{Def: def, Table: t, Ord: ord, Type: t.Columns[ord].Type}
	var err error
	if def.Kind == Hash {
		err = ix.buildHash()
	} else {
		err = ix.buildBTree()
	}
	if err != nil {
		return nil, err
	}
	return ix, nil
}

type class uint8

const (
	classInt class = iota
	classFloat
	classString
	classWide // wide DECIMAL
)

func classOf(t types.Type) class {
	switch t.Kind {
	case types.KindFloat64:
		return classFloat
	case types.KindString, types.KindNull:
		return classString
	}
	if t.IsWide() {
		return classWide
	}
	return classInt
}

// normFloat maps -0.0 to 0.0 so that equal values share a key.
func normFloat(f float64) float64 {
	if f == 0 {
		return 0
	}
	return f
}

func (ix *Index) buildHash() error {
	switch classOf(ix.Type) {
	case classInt:
		ix.ints = map[int64][]uint32{}
	case classWide:
		ix.wides = map[types.Int128][]uint32{}
	case classFloat:
		ix.floats = map[float64][]uint32{}
	default:
		ix.strs = map[string][]uint32{}
	}
	return ix.Table.ScanColumn(ix.Ord, func(id int, v types.Value) {
		if v.Null {
			return
		}
		switch {
		case ix.ints != nil:
			ix.ints[v.I] = append(ix.ints[v.I], uint32(id))
		case ix.wides != nil:
			ix.wides[v.Wide()] = append(ix.wides[v.Wide()], uint32(id))
		case ix.floats != nil:
			f := normFloat(v.F)
			ix.floats[f] = append(ix.floats[f], uint32(id))
		default:
			ix.strs[v.S] = append(ix.strs[v.S], uint32(id))
		}
	})
}

func (ix *Index) buildBTree() error {
	type entry[K any] struct {
		key K
		id  uint32
	}
	var ints []entry[int64]
	var wides []entry[types.Int128]
	var floats []entry[float64]
	var strs []entry[string]
	cls := classOf(ix.Type)
	err := ix.Table.ScanColumn(ix.Ord, func(id int, v types.Value) {
		if v.Null {
			return
		}
		switch cls {
		case classInt:
			ints = append(ints, entry[int64]{v.I, uint32(id)})
		case classWide:
			wides = append(wides, entry[types.Int128]{v.Wide(), uint32(id)})
		case classFloat:
			floats = append(floats, entry[float64]{normFloat(v.F), uint32(id)})
		default:
			strs = append(strs, entry[string]{v.S, uint32(id)})
		}
	})
	if err != nil {
		return err
	}
	// Ties are ordered by row ID.
	switch cls {
	case classInt:
		slices.SortFunc(ints, func(a, b entry[int64]) int { return cmp.Or(cmp.Compare(a.key, b.key), cmp.Compare(a.id, b.id)) })
		ix.intKeys = make([]int64, len(ints))
		ix.order = make([]uint32, len(ints))
		for i, e := range ints {
			ix.intKeys[i], ix.order[i] = e.key, e.id
		}
	case classWide:
		slices.SortFunc(wides, func(a, b entry[types.Int128]) int { return cmp.Or(a.key.Cmp(b.key), cmp.Compare(a.id, b.id)) })
		ix.wideKeys = make([]types.Int128, len(wides))
		ix.order = make([]uint32, len(wides))
		for i, e := range wides {
			ix.wideKeys[i], ix.order[i] = e.key, e.id
		}
	case classFloat:
		slices.SortFunc(floats, func(a, b entry[float64]) int { return cmp.Or(cmp.Compare(a.key, b.key), cmp.Compare(a.id, b.id)) })
		ix.floatKeys = make([]float64, len(floats))
		ix.order = make([]uint32, len(floats))
		for i, e := range floats {
			ix.floatKeys[i], ix.order[i] = e.key, e.id
		}
	default:
		slices.SortFunc(strs, func(a, b entry[string]) int { return cmp.Or(strings.Compare(a.key, b.key), cmp.Compare(a.id, b.id)) })
		ix.strKeys = make([]string, len(strs))
		ix.order = make([]uint32, len(strs))
		for i, e := range strs {
			ix.strKeys[i], ix.order[i] = e.key, e.id
		}
	}
	return nil
}

// cmpKey compares the key at sorted position i with v.
func (ix *Index) cmpKey(i int, v types.Value) int {
	switch {
	case ix.intKeys != nil:
		return cmpInt(ix.intKeys[i], v.I)
	case ix.wideKeys != nil:
		return ix.wideKeys[i].Cmp(v.Wide())
	case ix.floatKeys != nil:
		return cmpFloat(ix.floatKeys[i], normFloat(v.F))
	}
	return strings.Compare(ix.strKeys[i], v.S)
}

func cmpInt(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func cmpFloat(a, b float64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Bound is one end of a range in the column's domain.
type Bound struct {
	Value     types.Value
	Inclusive bool
}

// Range is a set of column values: all non-NULL values between Lo and Hi
// (nil = unbounded).
type Range struct {
	Lo, Hi *Bound
}

// SupportsRange reports whether the index can answer range lookups.
func (ix *Index) SupportsRange() bool { return ix.Kind == BTree }

// Equal returns the IDs (ascending) of rows whose value equals v.
func (ix *Index) Equal(v types.Value) []uint32 {
	if v.Null {
		return nil
	}
	if ix.Kind == Hash {
		switch {
		case ix.ints != nil:
			return ix.ints[v.I]
		case ix.wides != nil:
			return ix.wides[v.Wide()]
		case ix.floats != nil:
			return ix.floats[normFloat(v.F)]
		}
		return ix.strs[v.S]
	}
	b := &Bound{Value: v, Inclusive: true}
	return ix.Range(Range{Lo: b, Hi: b})
}

// Range returns the IDs (ascending) of rows whose value lies in r. Only
// BTREE indexes support ranges.
func (ix *Index) Range(r Range) []uint32 {
	n := len(ix.order)
	lo, hi := 0, n
	if r.Lo != nil {
		lo = sort.Search(n, func(i int) bool {
			c := ix.cmpKey(i, r.Lo.Value)
			return c > 0 || (c == 0 && r.Lo.Inclusive)
		})
	}
	if r.Hi != nil {
		hi = sort.Search(n, func(i int) bool {
			c := ix.cmpKey(i, r.Hi.Value)
			return c > 0 || (c == 0 && !r.Hi.Inclusive)
		})
	}
	if lo >= hi {
		return nil
	}
	ids := slices.Clone(ix.order[lo:hi])
	slices.Sort(ids)
	return ids
}

// Lookup returns the sorted, duplicate-free IDs of rows whose value equals
// one of points (NULL points match nothing).
func (ix *Index) Lookup(points []types.Value) []uint32 {
	if len(points) == 1 {
		return ix.Equal(points[0])
	}
	var ids []uint32
	for _, p := range points {
		ids = append(ids, ix.Equal(p)...)
	}
	slices.Sort(ids)
	return slices.Compact(ids)
}

// Entries returns the number of indexed (non-NULL) rows.
func (ix *Index) Entries() int {
	if ix.Kind == BTree {
		return len(ix.order)
	}
	n := 0
	for _, l := range ix.ints {
		n += len(l)
	}
	for _, l := range ix.wides {
		n += len(l)
	}
	for _, l := range ix.floats {
		n += len(l)
	}
	for _, l := range ix.strs {
		n += len(l)
	}
	return n
}
