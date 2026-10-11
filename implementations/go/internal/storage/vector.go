package storage

import (
	"math"

	"polyquery/internal/types"
)

// Bitmap is an LSB-first bit set: bit i is bit (i mod 64) of word i/64.
type Bitmap []uint64

// NewBitmap returns a bitmap of n bits, all set to value.
func NewBitmap(n int, value bool) Bitmap {
	b := make(Bitmap, (n+63)/64)
	if value {
		for i := range b {
			b[i] = math.MaxUint64
		}
		if r := n % 64; r != 0 {
			b[len(b)-1] = 1<<uint(r) - 1
		}
	}
	return b
}

// Get reports whether bit i is set.
func (b Bitmap) Get(i int) bool { return b[i>>6]&(1<<uint(i&63)) != 0 }

// Set sets bit i.
func (b Bitmap) Set(i int) { b[i>>6] |= 1 << uint(i&63) }

// Clear clears bit i.
func (b Bitmap) Clear(i int) { b[i>>6] &^= 1 << uint(i&63) }

// Vector is a typed column of n values plus a validity bitmap. BOOLEAN,
// INT64, narrow DECIMAL (unscaled), DATE and TIMESTAMP values are stored in
// Ints, wide DECIMALs (unscaled) in Wides, FLOAT64 in Floats, and STRING
// either plainly in Strs or dictionary-encoded (Dict + Codes). Values of
// NULL slots are unspecified.
type Vector struct {
	Type   types.Type
	Ints   []int64
	Wides  []types.Int128
	Floats []float64
	Strs   []string
	Dict   []string // dictionary of a dictionary-encoded STRING vector
	Codes  []uint32 // per-row index into Dict
	Valid  Bitmap   // nil if the vector has no NULLs; a set bit means non-NULL
	n      int
}

// NewVector creates an empty plain vector with capacity n.
func NewVector(t types.Type, n int) *Vector {
	v := &Vector{Type: t}
	switch storageClass(t) {
	case classFloat:
		v.Floats = make([]float64, 0, n)
	case classString:
		v.Strs = make([]string, 0, n)
	case classWide:
		v.Wides = make([]types.Int128, 0, n)
	default:
		v.Ints = make([]int64, 0, n)
	}
	return v
}

type class uint8

const (
	classInt class = iota
	classFloat
	classString
	classWide
)

func storageClass(t types.Type) class {
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

// Len returns the number of values.
func (v *Vector) Len() int { return v.n }

// IsDict reports whether the vector is dictionary-encoded.
func (v *Vector) IsDict() bool { return v.Dict != nil }

// Append adds a value to a plain vector.
func (v *Vector) Append(val types.Value) {
	if val.Null && v.Valid == nil {
		v.Valid = NewBitmap(v.n, true)
	}
	if v.Valid != nil {
		if v.n/64 >= len(v.Valid) {
			v.Valid = append(v.Valid, 0)
		}
		if !val.Null {
			v.Valid.Set(v.n)
		}
	}
	switch storageClass(v.Type) {
	case classFloat:
		v.Floats = append(v.Floats, val.F)
	case classString:
		v.Strs = append(v.Strs, val.S)
	case classWide:
		v.Wides = append(v.Wides, val.Wide())
	default:
		v.Ints = append(v.Ints, val.I)
	}
	v.n++
}

// IsNull reports whether row i is NULL.
func (v *Vector) IsNull(i int) bool { return v.Valid != nil && !v.Valid.Get(i) }

// NullCount counts the NULL rows.
func (v *Vector) NullCount() int {
	if v.Valid == nil {
		return 0
	}
	n := 0
	for i := 0; i < v.n; i++ {
		if !v.Valid.Get(i) {
			n++
		}
	}
	return n
}

// Get returns the value at row i.
func (v *Vector) Get(i int) types.Value {
	if v.Valid != nil && !v.Valid.Get(i) {
		return types.NullValue
	}
	switch {
	case v.Ints != nil:
		return types.Value{I: v.Ints[i]}
	case v.Wides != nil:
		return types.WideValue(v.Wides[i])
	case v.Floats != nil:
		return types.Value{F: v.Floats[i]}
	case v.Dict != nil:
		return types.Value{S: v.Dict[v.Codes[i]]}
	case v.Strs != nil:
		return types.Value{S: v.Strs[i]}
	}
	return types.Value{}
}

// Slice returns rows [lo, hi) as a new vector. Value storage is shared.
func (v *Vector) Slice(lo, hi int) *Vector {
	out := &Vector{Type: v.Type, Dict: v.Dict, n: hi - lo}
	switch {
	case v.Ints != nil:
		out.Ints = v.Ints[lo:hi:hi]
	case v.Wides != nil:
		out.Wides = v.Wides[lo:hi:hi]
	case v.Floats != nil:
		out.Floats = v.Floats[lo:hi:hi]
	case v.Dict != nil:
		out.Codes = v.Codes[lo:hi:hi]
	case v.Strs != nil:
		out.Strs = v.Strs[lo:hi:hi]
	}
	if v.Valid != nil {
		valid := NewBitmap(hi-lo, false)
		hasNull := false
		for i := lo; i < hi; i++ {
			if v.Valid.Get(i) {
				valid.Set(i - lo)
			} else {
				hasNull = true
			}
		}
		if hasNull {
			out.Valid = valid
		}
	}
	return out
}

// DictEncode returns a dictionary-encoded copy of a plain STRING vector.
// Dictionary entries appear in order of first occurrence.
func (v *Vector) DictEncode() *Vector {
	if v.Dict != nil || storageClass(v.Type) != classString {
		return v
	}
	out := &Vector{Type: v.Type, Valid: v.Valid, n: v.n, Codes: make([]uint32, v.n), Dict: []string{}}
	codes := map[string]uint32{}
	for i := 0; i < v.n; i++ {
		if v.IsNull(i) {
			continue
		}
		s := v.Strs[i]
		c, ok := codes[s]
		if !ok {
			c = uint32(len(out.Dict))
			codes[s] = c
			out.Dict = append(out.Dict, s)
		}
		out.Codes[i] = c
	}
	return out
}

// distinctStrings counts distinct non-NULL values of a plain STRING vector,
// stopping early once limit is exceeded.
func (v *Vector) distinctStrings(limit int) int {
	seen := map[string]struct{}{}
	for i := 0; i < v.n; i++ {
		if v.IsNull(i) {
			continue
		}
		seen[v.Strs[i]] = struct{}{}
		if len(seen) > limit {
			break
		}
	}
	return len(seen)
}

// IntVector wraps int-class values (BOOLEAN, INT64, narrow DECIMAL, DATE,
// TIMESTAMP).
func IntVector(t types.Type, vals []int64, valid Bitmap) *Vector {
	if vals == nil {
		vals = []int64{}
	}
	return &Vector{Type: t, Ints: vals, Valid: valid, n: len(vals)}
}

// WideVector wraps wide DECIMAL values.
func WideVector(t types.Type, vals []types.Int128, valid Bitmap) *Vector {
	if vals == nil {
		vals = []types.Int128{}
	}
	return &Vector{Type: t, Wides: vals, Valid: valid, n: len(vals)}
}

// FloatVector wraps FLOAT64 values.
func FloatVector(vals []float64, valid Bitmap) *Vector {
	if vals == nil {
		vals = []float64{}
	}
	return &Vector{Type: types.Float64, Floats: vals, Valid: valid, n: len(vals)}
}

// StringVector wraps plain STRING values.
func StringVector(vals []string, valid Bitmap) *Vector {
	if vals == nil {
		vals = []string{}
	}
	return &Vector{Type: types.String, Strs: vals, Valid: valid, n: len(vals)}
}

// DictVector wraps a dictionary-encoded STRING column.
func DictVector(dict []string, codes []uint32, valid Bitmap) *Vector {
	if dict == nil {
		dict = []string{}
	}
	if codes == nil {
		codes = []uint32{}
	}
	return &Vector{Type: types.String, Dict: dict, Codes: codes, Valid: valid, n: len(codes)}
}
