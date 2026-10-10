// Package storage holds immutable in-memory tables. A table is split into
// row groups; each group stores its rows either column-oriented (one typed
// vector with a validity bitmap per column, STRING columns optionally
// dictionary-encoded) or row-oriented (a slice of row tuples), and carries
// per-column statistics (null count, min, max) used for row-group skipping.
// Column chunks may be loaded lazily (memory-mapped PQCF files).
package storage

import (
	"sort"
	"sync"

	"polyquery/internal/errs"
	"polyquery/internal/types"
)

// ColumnDef describes a table column.
type ColumnDef struct {
	Name string
	Type types.Type
}

// Layout selects the in-memory representation of a table.
type Layout uint8

// Layouts.
const (
	ColumnLayout Layout = iota
	RowLayout
)

func (l Layout) String() string {
	if l == RowLayout {
		return "row"
	}
	return "column"
}

// ParseLayout maps a layout option value to a Layout.
func ParseLayout(s string) (Layout, bool) {
	switch s {
	case "column":
		return ColumnLayout, true
	case "row":
		return RowLayout, true
	}
	return ColumnLayout, false
}

// DefaultGroupSize is the number of rows per row group of loaded tables.
const DefaultGroupSize = 65536

// ChunkStats summarizes one column of one row group. Min and Max bound the
// non-NULL values and are only meaningful if HasRange is set.
type ChunkStats struct {
	NullCount int
	HasRange  bool
	Min, Max  types.Value
}

// ComputeStats computes exact statistics of a vector.
func ComputeStats(v *Vector) ChunkStats {
	var st ChunkStats
	t := v.Type
	for i := 0; i < v.Len(); i++ {
		val := v.Get(i)
		if val.Null {
			st.NullCount++
			continue
		}
		if !st.HasRange {
			st.Min, st.Max, st.HasRange = val, val, true
			continue
		}
		if types.Compare(t, val, t, st.Min) < 0 {
			st.Min = val
		}
		if types.Compare(t, val, t, st.Max) > 0 {
			st.Max = val
		}
	}
	return st
}

// Chunk is the vector of one column in one row group, possibly decoded on
// first access.
type Chunk struct {
	once sync.Once
	load func() (*Vector, error)
	vec  *Vector
	err  error
}

// LoadedChunk wraps an already decoded vector.
func LoadedChunk(v *Vector) *Chunk {
	c := &Chunk{vec: v}
	c.once.Do(func() {})
	return c
}

// LazyChunk creates a chunk decoded by load on first access. A decoding
// error is remembered and returned by every access.
func LazyChunk(load func() (*Vector, error)) *Chunk { return &Chunk{load: load} }

// Vector returns the decoded vector.
func (c *Chunk) Vector() (*Vector, error) {
	c.once.Do(func() {
		c.vec, c.err = c.load()
		c.load = nil
	})
	return c.vec, c.err
}

// RowGroup is a horizontal partition of a table.
type RowGroup struct {
	Start int          // row ID of the group's first row
	Rows  int          // number of rows
	Stats []ChunkStats // one per column
	// Exactly one of chunks (column layout) and tuples (row layout) is used.
	chunks []*Chunk
	tuples []types.Row
}

// NewColumnGroup creates a column-oriented row group.
func NewColumnGroup(start, rows int, stats []ChunkStats, chunks []*Chunk) *RowGroup {
	return &RowGroup{Start: start, Rows: rows, Stats: stats, chunks: chunks}
}

// NewRowGroup creates a row-oriented row group.
func NewRowGroup(start int, stats []ChunkStats, tuples []types.Row) *RowGroup {
	return &RowGroup{Start: start, Rows: len(tuples), Stats: stats, tuples: tuples}
}

// Column returns the vector of column ord (column layout only).
func (g *RowGroup) Column(ord int) (*Vector, error) {
	if g.chunks == nil {
		return nil, errs.New(errs.InternalError, "row group is not column-oriented")
	}
	return g.chunks[ord].Vector()
}

// Tuples returns the rows of a row-oriented group (nil for column-oriented
// groups). The rows must not be modified.
func (g *RowGroup) Tuples() []types.Row { return g.tuples }

// GroupReader reads selected columns of one row group.
type GroupReader struct {
	ords   []int
	vecs   []*Vector
	tuples []types.Row
}

// Reader prepares reading the columns ords of the group (decoding lazily
// loaded chunks, which may fail with STORAGE_CORRUPT).
func (g *RowGroup) Reader(ords []int) (*GroupReader, error) {
	r := &GroupReader{ords: ords, tuples: g.tuples}
	if g.tuples == nil {
		r.vecs = make([]*Vector, len(ords))
		for i, o := range ords {
			v, err := g.chunks[o].Vector()
			if err != nil {
				return nil, err
			}
			r.vecs[i] = v
		}
	}
	return r, nil
}

// Read stores the selected columns of the group's row i into dst.
func (r *GroupReader) Read(i int, dst types.Row) {
	if r.tuples != nil {
		row := r.tuples[i]
		for k, o := range r.ords {
			dst[k] = row[o]
		}
		return
	}
	for k, v := range r.vecs {
		dst[k] = v.Get(i)
	}
}

// Value returns column k (an index into the reader's ords) of row i.
func (r *GroupReader) Value(i, k int) types.Value {
	if r.tuples != nil {
		return r.tuples[i][r.ords[k]]
	}
	return r.vecs[k].Get(i)
}

// Table is an immutable table.
type Table struct {
	Name    string
	Columns []ColumnDef
	Rows    int
	Layout  Layout
	Groups  []*RowGroup
	stats   []columnStats
}

// NewTable assembles a table from its row groups (which must be contiguous
// and start at row 0).
func NewTable(name string, cols []ColumnDef, layout Layout, groups []*RowGroup) *Table {
	t := &Table{Name: name, Columns: cols, Layout: layout, Groups: groups, stats: make([]columnStats, len(cols))}
	for _, g := range groups {
		t.Rows += g.Rows
	}
	return t
}

// BuildOptions control how loaded data is laid out in memory.
type BuildOptions struct {
	Layout Layout
	// Dictionary forces dictionary encoding of STRING columns (column
	// layout). Otherwise a STRING chunk is dictionary-encoded when it has
	// fewer distinct values than half its rows.
	Dictionary bool
	// GroupSize is the number of rows per row group (0 = DefaultGroupSize).
	GroupSize int
}

// Data is fully materialized column data, as produced by ingestion.
type Data struct {
	Columns []ColumnDef
	Vectors []*Vector
	Rows    int
}

// Build lays out materialized column data as a table.
func Build(name string, d *Data, opts BuildOptions) *Table {
	size := opts.GroupSize
	if size <= 0 {
		size = DefaultGroupSize
	}
	var groups []*RowGroup
	for start := 0; start < d.Rows; start += size {
		end := min(start+size, d.Rows)
		vecs := make([]*Vector, len(d.Vectors))
		stats := make([]ChunkStats, len(d.Vectors))
		for i, v := range d.Vectors {
			if start == 0 && end == v.Len() {
				vecs[i] = v
			} else {
				vecs[i] = v.Slice(start, end)
			}
			stats[i] = ComputeStats(vecs[i])
		}
		groups = append(groups, GroupFromVectors(start, end-start, stats, vecs, opts))
	}
	return NewTable(name, d.Columns, opts.Layout, groups)
}

// GroupFromVectors lays out decoded vectors of one row group according to
// opts.
func GroupFromVectors(start, rows int, stats []ChunkStats, vecs []*Vector, opts BuildOptions) *RowGroup {
	if opts.Layout == RowLayout {
		tuples := make([]types.Row, rows)
		cells := make([]types.Value, rows*len(vecs))
		for r := range tuples {
			row := cells[r*len(vecs) : (r+1)*len(vecs) : (r+1)*len(vecs)]
			for c, v := range vecs {
				row[c] = v.Get(r)
			}
			tuples[r] = row
		}
		return NewRowGroup(start, stats, tuples)
	}
	chunks := make([]*Chunk, len(vecs))
	for i, v := range vecs {
		if storageClass(v.Type) == classString && !v.IsDict() &&
			(opts.Dictionary || v.distinctStrings(rows/2) < rows/2) {
			v = v.DictEncode()
		}
		chunks[i] = LoadedChunk(v)
	}
	return NewColumnGroup(start, rows, stats, chunks)
}

// GroupOf returns the index of the row group containing row ID id.
func (t *Table) GroupOf(id int) int {
	return sort.Search(len(t.Groups), func(i int) bool { return t.Groups[i].Start+t.Groups[i].Rows > id })
}

// ColumnIndex finds a column by case-insensitive name, or -1.
func (t *Table) ColumnIndex(name string) int {
	for i, c := range t.Columns {
		if EqualFold(c.Name, name) {
			return i
		}
	}
	return -1
}

// ScanColumn calls fn for every row of column ord in row-ID order.
func (t *Table) ScanColumn(ord int, fn func(id int, v types.Value)) error {
	for _, g := range t.Groups {
		r, err := g.Reader([]int{ord})
		if err != nil {
			return err
		}
		for i := 0; i < g.Rows; i++ {
			fn(g.Start+i, r.Value(i, 0))
		}
	}
	return nil
}

// EqualFold compares names with ASCII case folding.
func EqualFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 32
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}

// FoldKey returns the ASCII-lowercased name used as a lookup key.
func FoldKey(s string) string {
	b := []byte(s)
	changed := false
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
			changed = true
		}
	}
	if !changed {
		return s
	}
	return string(b)
}
