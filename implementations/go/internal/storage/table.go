// Package storage holds immutable in-memory tables (column-oriented: one
// typed vector plus null flags per column) and the catalog that maps names to
// tables.
package storage

import (
	"polyquery/internal/types"
)

// ColumnDef describes a table column.
type ColumnDef struct {
	Name string
	Type types.Type
}

// Vector is a typed column of values. Integers, booleans, decimals (unscaled),
// dates and timestamps are stored in Ints; FLOAT64 in Floats; STRING in Strs.
type Vector struct {
	Type   types.Type
	Ints   []int64
	Floats []float64
	Strs   []string
	Nulls  []bool // nil if the column has no NULLs
}

// NewVector creates an empty vector with capacity n.
func NewVector(t types.Type, n int) *Vector {
	v := &Vector{Type: t}
	switch t.Kind {
	case types.KindFloat64:
		v.Floats = make([]float64, 0, n)
	case types.KindString, types.KindNull:
		v.Strs = make([]string, 0, n)
	default:
		v.Ints = make([]int64, 0, n)
	}
	return v
}

// Len returns the number of values.
func (v *Vector) Len() int {
	switch v.Type.Kind {
	case types.KindFloat64:
		return len(v.Floats)
	case types.KindString, types.KindNull:
		return len(v.Strs)
	}
	return len(v.Ints)
}

// Append adds a value.
func (v *Vector) Append(val types.Value) {
	if val.Null {
		if v.Nulls == nil {
			v.Nulls = make([]bool, v.Len(), cap(v.Ints)+cap(v.Floats)+cap(v.Strs))
		}
		v.Nulls = append(v.Nulls, true)
		val = types.Value{}
	} else if v.Nulls != nil {
		v.Nulls = append(v.Nulls, false)
	}
	switch v.Type.Kind {
	case types.KindFloat64:
		v.Floats = append(v.Floats, val.F)
	case types.KindString, types.KindNull:
		v.Strs = append(v.Strs, val.S)
	default:
		v.Ints = append(v.Ints, val.I)
	}
}

// IsNull reports whether row i is NULL.
func (v *Vector) IsNull(i int) bool { return v.Nulls != nil && v.Nulls[i] }

// Get returns the value at row i.
func (v *Vector) Get(i int) types.Value {
	if v.Nulls != nil && v.Nulls[i] {
		return types.NullValue
	}
	switch v.Type.Kind {
	case types.KindFloat64:
		return types.Value{F: v.Floats[i]}
	case types.KindString, types.KindNull:
		return types.Value{S: v.Strs[i]}
	}
	return types.Value{I: v.Ints[i]}
}

// Table is an immutable table.
type Table struct {
	Name    string
	Columns []ColumnDef
	Data    []*Vector
	Rows    int
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
