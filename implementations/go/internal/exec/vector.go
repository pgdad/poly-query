package exec

import (
	"polyquery/internal/types"
)

// This file defines the data model of vectorized execution (mode
// "vectorized"): operators exchange batches of up to BatchSize rows stored
// column-wise in typed vectors, with an optional selection vector listing
// the active rows.

// BatchSize is the maximum number of rows of a batch.
const BatchSize = 2048

// vclass is the physical representation class of a vector.
type vclass uint8

const (
	vInt   vclass = iota // BOOLEAN (0/1), INT64, narrow DECIMAL (unscaled), DATE, TIMESTAMP
	vFloat               // FLOAT64
	vStr                 // STRING and the null type
	vWide                // wide DECIMAL (128-bit unscaled)
)

func classOf(t types.Type) vclass {
	switch t.Kind {
	case types.KindFloat64:
		return vFloat
	case types.KindString, types.KindNull:
		return vStr
	}
	if t.IsWide() {
		return vWide
	}
	return vInt
}

// Vec is one column of a batch: position i holds row i of the batch. Only
// the slice matching the column's class is used; STRING vectors are either
// plain (S) or dictionary-encoded (Dict + Codes). Values at NULL positions
// and at positions outside the batch's selection are unspecified.
type Vec struct {
	I     []int64
	W     []types.Int128
	F     []float64
	S     []string
	Dict  []string
	Codes []uint32
	Nulls []bool // nil: no NULLs; else Nulls[i] reports whether row i is NULL
}

// isNull reports whether row i is NULL.
func (v *Vec) isNull(i int) bool { return v.Nulls != nil && v.Nulls[i] }

// value returns row i as a Value.
func (v *Vec) value(i int, c vclass) types.Value {
	if v.Nulls != nil && v.Nulls[i] {
		return null
	}
	switch c {
	case vInt:
		return types.Value{I: v.I[i]}
	case vFloat:
		return types.Value{F: v.F[i]}
	case vWide:
		return types.WideValue(v.W[i])
	}
	if v.Dict != nil {
		return types.Value{S: v.Dict[v.Codes[i]]}
	}
	return types.Value{S: v.S[i]}
}

// strs returns the plain strings of the first n rows, decoding a
// dictionary-encoded vector in place (the vector stays equivalent).
func (v *Vec) strs(n int) []string {
	if v.Dict == nil {
		return v.S
	}
	s := grow(v.S, n)
	for i, c := range v.Codes[:n] {
		s[i] = v.Dict[c]
	}
	v.S, v.Dict, v.Codes = s, nil, nil
	return s
}

// grow returns a slice of length n reusing buf's storage when possible.
// Storage is sized to the rows actually seen (doubling up to a batch):
// expressions of many nodes over small tables keep small buffers.
func grow[T any](buf []T, n int) []T {
	if cap(buf) >= n {
		return buf[:n]
	}
	return make([]T, n, max(n, min(2*cap(buf), BatchSize)))
}

// vecBuf is an operator-owned output vector reused across batches.
type vecBuf struct {
	v     Vec
	nulls []bool
}

// reset prepares the buffer for n rows of class c and returns the vector
// (without NULLs; call withNulls to add them).
func (b *vecBuf) reset(n int, c vclass) *Vec {
	switch c {
	case vInt:
		b.v.I = grow(b.v.I, n)
	case vFloat:
		b.v.F = grow(b.v.F, n)
	case vWide:
		b.v.W = grow(b.v.W, n)
	default:
		b.v.S = grow(b.v.S, n)
		b.v.Dict, b.v.Codes = nil, nil
	}
	b.v.Nulls = nil
	return &b.v
}

// withNulls attaches a cleared NULL array of n rows to the buffer's vector.
func (b *vecBuf) withNulls(n int) []bool {
	b.nulls = grow(b.nulls, n)
	clear(b.nulls)
	b.v.Nulls = b.nulls
	return b.nulls
}

// set stores val at row i of a vector of class c whose NULL array exists.
func (v *Vec) set(i int, val types.Value, c vclass) {
	if val.Null {
		v.Nulls[i] = true
		return
	}
	v.Nulls[i] = false
	switch c {
	case vInt:
		v.I[i] = val.I
	case vFloat:
		v.F[i] = val.F
	case vWide:
		v.W[i] = val.Wide()
	default:
		v.S[i] = val.S
	}
}

// Batch is a set of rows stored column-wise. Rows 0..N-1 exist physically;
// if Sel is non-nil only the rows it lists (ascending) are part of the
// batch.
type Batch struct {
	N    int
	Sel  []int32
	Cols []*Vec
}

// Len returns the number of active rows.
func (b *Batch) Len() int {
	if b.Sel != nil {
		return len(b.Sel)
	}
	return b.N
}

// forActive calls fn for every active row position.
func forActive(n int, sel []int32, fn func(i int)) {
	if sel == nil {
		for i := 0; i < n; i++ {
			fn(i)
		}
		return
	}
	for _, i := range sel {
		fn(int(i))
	}
}

// BatchOperator is a pull-based batch iterator. NextBatch returns nil at the
// end of input. A returned batch (and its vectors) is only valid until the
// following call; it never has zero active rows.
type BatchOperator interface {
	NextBatch() (*Batch, error)
}

// rowReader reads rows out of batches: it adapts a batch operator to the
// row Operator interface.
type rowReader struct {
	input   BatchOperator
	classes []vclass
	b       *Batch
	pos     int
	buf     types.Row
}

func newRowReader(in BatchOperator, ts []types.Type) *rowReader {
	r := &rowReader{input: in, buf: make(types.Row, len(ts))}
	for _, t := range ts {
		r.classes = append(r.classes, classOf(t))
	}
	return r
}

func (r *rowReader) Next() (types.Row, error) {
	for r.b == nil || r.pos >= r.b.Len() {
		b, err := r.input.NextBatch()
		if b == nil || err != nil {
			r.b = nil
			return nil, err
		}
		r.b, r.pos = b, 0
	}
	i := r.pos
	if r.b.Sel != nil {
		i = int(r.b.Sel[i])
	}
	r.pos++
	for k, v := range r.b.Cols {
		r.buf[k] = v.value(i, r.classes[k])
	}
	return r.buf, nil
}

// CountRows counts the remaining rows of a root operator without
// materializing them when it reads a vectorized plan (ok is false
// otherwise). Counting stops once more than limit rows (limit ≥ 0) exist.
func CountRows(op Operator, limit int64) (n int64, ok bool, err error) {
	r, isReader := op.(*rowReader)
	if !isReader || r.b != nil {
		return 0, false, nil
	}
	for {
		b, err := r.input.NextBatch()
		if b == nil || err != nil {
			return n, true, err
		}
		n += int64(b.Len())
		if limit >= 0 && n > limit {
			return n, true, nil
		}
	}
}

// batchWriter accumulates rows into batches: it adapts a row Operator to
// the BatchOperator interface.
type batchWriter struct {
	input   Operator
	classes []vclass
	bufs    []vecBuf
	batch   Batch
	err     error // error to report after the rows read before it
	done    bool
}

func newBatchWriter(in Operator, ts []types.Type) *batchWriter {
	w := &batchWriter{input: in, bufs: make([]vecBuf, len(ts))}
	for _, t := range ts {
		w.classes = append(w.classes, classOf(t))
	}
	w.batch.Cols = make([]*Vec, len(ts))
	return w
}

func (w *batchWriter) NextBatch() (*Batch, error) {
	if w.err != nil || w.done {
		err := w.err
		w.err = nil
		return nil, err
	}
	for k := range w.bufs {
		w.batch.Cols[k] = w.bufs[k].reset(BatchSize, w.classes[k])
		w.bufs[k].withNulls(BatchSize)
	}
	n := 0
	for n < BatchSize {
		row, err := w.input.Next()
		if err != nil {
			w.err = err
			break
		}
		if row == nil {
			w.done = true
			break
		}
		for k, v := range row {
			w.batch.Cols[k].set(n, v, w.classes[k])
		}
		n++
	}
	if n == 0 {
		err := w.err
		w.err = nil
		return nil, err
	}
	w.batch.N, w.batch.Sel = n, nil
	return &w.batch, nil
}

// batchRow materializes row i of a batch into dst (columns of the given
// classes).
func batchRow(b *Batch, i int, classes []vclass, dst types.Row) {
	for k, v := range b.Cols {
		dst[k] = v.value(i, classes[k])
	}
}
