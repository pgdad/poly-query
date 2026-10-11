package exec

import (
	"encoding/binary"
	"math"
	"math/bits"
	"unsafe"

	"polyquery/internal/native"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Native scan filters (option native: true with a loaded kernel library).
//
// The conjuncts of a filter directly above a table scan that compare
// int-class columns (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP) with
// constants or with each other, test for NULL, or combine such tests with
// AND, OR and NOT, are compiled into an npred tree. The scan evaluates the
// tree on the table's storage vectors — the int64 data and the LSB-first
// validity bitmaps — with the kernels: one bitmap per leaf
// (pqk_filter_i64_bitmap, pqk_compare_i64), combined with pqk_bitmap_and /
// pqk_bitmap_or, or a selection vector straight from pqk_filter_i64 for a
// single comparison. Only rows where the predicate is TRUE qualify, so
// three-valued logic reduces to bitmaps of TRUE rows: a comparison is TRUE
// on valid rows where it holds, AND/OR of TRUE-sets are their
// intersection/union, and NOT is pushed down to the leaves (De Morgan,
// negated operators), where it is exact because NULL stays NULL. Remaining
// conjuncts are evaluated by the regular filter operator on the qualifying
// rows only (short-circuiting is permitted, types.md §6).

type npredKind uint8

const (
	nConst npredKind = iota // column op constant(s)
	nCols                   // column op column
	nValid                  // column IS NOT NULL
	nNull                   // column IS NULL
	nTrue                   // every row
	nFalse                  // no row
	nAnd
	nOr
)

// npred is an immutable native predicate tree; leaves reference table
// column ordinals.
type npred struct {
	kind      npredKind
	ord, ord2 int
	op        native.Op
	a, b      int64
	kids      []*npred
}

// nativeCompiler compiles filter conjuncts over a table scan's output.
type nativeCompiler struct {
	ec   *Context
	ords map[plan.ColumnID]int // scan output column → table ordinal
}

func newNativeCompiler(ec *Context, scan *physical.TableScan) *nativeCompiler {
	c := &nativeCompiler{ec: ec, ords: make(map[plan.ColumnID]int, len(scan.Cols))}
	for k, col := range scan.Cols {
		c.ords[col.ID] = scan.Ords[k]
	}
	return c
}

// nativeScanFilter compiles the native conjuncts of a filter directly above
// a table scan (ok is false if native execution is off or no conjunct is
// native); rest is the conjunction of the others (nil if none).
func nativeScanFilter(ec *Context, x *physical.Filter) (scan *physical.TableScan, root *npred, rest plan.Expr, ok bool) {
	if ec.Native == nil {
		return nil, nil, nil, false
	}
	if scan, ok = x.Input.(*physical.TableScan); !ok {
		return nil, nil, nil, false
	}
	root, others := newNativeCompiler(ec, scan).split(x.Pred)
	if root == nil {
		return nil, nil, nil, false
	}
	return scan, root, andAll(others), true
}

// conjuncts splits a predicate at its top-level ANDs.
func conjuncts(e plan.Expr, out []plan.Expr) []plan.Expr {
	if b, ok := e.(*plan.Binary); ok && b.Op == plan.OpAnd {
		return conjuncts(b.R, conjuncts(b.L, out))
	}
	return append(out, e)
}

// andAll combines expressions with AND (nil for none).
func andAll(es []plan.Expr) plan.Expr {
	var r plan.Expr
	for _, e := range es {
		if r == nil {
			r = e
		} else {
			r = &plan.Binary{Op: plan.OpAnd, L: r, R: e, T: types.Boolean}
		}
	}
	return r
}

// split compiles the native conjuncts of pred into one tree and returns the
// others (nil tree if no conjunct is native).
func (c *nativeCompiler) split(pred plan.Expr) (*npred, []plan.Expr) {
	var kids []*npred
	var rest []plan.Expr
	for _, e := range conjuncts(pred, nil) {
		if p, ok := c.compile(e, false); ok {
			kids = append(kids, p)
		} else {
			rest = append(rest, e)
		}
	}
	switch len(kids) {
	case 0:
		return nil, rest
	case 1:
		return kids[0], rest
	}
	return &npred{kind: nAnd, kids: kids}, rest
}

// intClass reports whether values of t are compared as their int64
// representation (DECIMALs of equal scale).
func intClass(t types.Type) bool {
	switch t.Kind {
	case types.KindBoolean, types.KindInt64, types.KindDecimal, types.KindDate, types.KindTimestamp:
		return true
	}
	return false
}

// column returns the table ordinal of a column reference of the scan.
func (c *nativeCompiler) column(e plan.Expr) (int, bool) {
	ref, ok := e.(*plan.ColumnRef)
	if !ok {
		return 0, false
	}
	ord, ok := c.ords[ref.ID]
	return ord, ok
}

// constant evaluates a constant expression (ok false if e is not constant
// or its evaluation fails — the regular path then reports the error).
func (c *nativeCompiler) constant(e plan.Expr) (types.Value, bool) {
	if !plan.IsConstant(e) || volatile(e) {
		return null, false
	}
	v, err := evalConstant(c.ec, e)
	return v, err == nil
}

var pow10 = func() [19]int64 {
	var p [19]int64
	p[0] = 1
	for i := 1; i < len(p); i++ {
		p[i] = p[i-1] * 10
	}
	return p
}()

// rescale converts the unscaled value v of a DECIMAL with scale from to
// scale to, if exactly representable.
func rescale(v int64, from, to int) (int64, bool) {
	switch {
	case from == to:
		return v, true
	case from < to:
		d := to - from
		if d >= len(pow10) {
			return 0, false
		}
		hi, lo := bits.Mul64(uint64(abs64(v)), uint64(pow10[d]))
		if hi != 0 || lo > math.MaxInt64 || v == math.MinInt64 {
			return 0, false
		}
		if v < 0 {
			return -int64(lo), true
		}
		return int64(lo), true
	}
	d := from - to
	if d >= len(pow10) || v%pow10[d] != 0 {
		return 0, false
	}
	return v / pow10[d], true
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

// constFor converts a constant of type kt to the representation of a
// column of type ct (same kind); null reports a NULL constant.
func constFor(v types.Value, kt, ct types.Type) (x int64, null, ok bool) {
	if v.Null || kt.Kind == types.KindNull {
		return 0, true, true
	}
	if kt.Kind != ct.Kind {
		return 0, false, false
	}
	if ct.Kind == types.KindDecimal {
		x, ok = rescale(v.I, kt.Scale, ct.Scale)
		return x, false, ok
	}
	return v.I, false, true
}

var cmpOps = map[plan.BinaryOp]native.Op{
	plan.OpEq: native.EQ, plan.OpNe: native.NE, plan.OpLt: native.LT,
	plan.OpLe: native.LE, plan.OpGt: native.GT, plan.OpGe: native.GE,
}

// compile compiles e (negated if neg) into a tree of TRUE rows.
func (c *nativeCompiler) compile(e plan.Expr, neg bool) (*npred, bool) {
	switch x := e.(type) {
	case *plan.Binary:
		if x.Op == plan.OpAnd || x.Op == plan.OpOr {
			l, ok := c.compile(x.L, neg)
			if !ok {
				return nil, false
			}
			r, ok := c.compile(x.R, neg)
			if !ok {
				return nil, false
			}
			kind := nAnd
			if (x.Op == plan.OpOr) != neg {
				kind = nOr
			}
			return &npred{kind: kind, kids: []*npred{l, r}}, true
		}
		if x.Op.IsComparison() {
			return c.comparison(x, neg)
		}
	case *plan.Unary:
		if x.Op == plan.OpNot {
			return c.compile(x.X, !neg)
		}
	case *plan.IsNull:
		ord, ok := c.column(x.X)
		if !ok {
			return nil, false
		}
		if x.Not != neg {
			return &npred{kind: nValid, ord: ord}, true
		}
		return &npred{kind: nNull, ord: ord}, true
	case *plan.Between:
		return c.between(x, neg)
	case *plan.InList:
		return c.inList(x, neg)
	case *plan.ColumnRef:
		ord, ok := c.column(x)
		if !ok || x.T.Kind != types.KindBoolean {
			return nil, false
		}
		v := int64(1)
		if neg {
			v = 0
		}
		return &npred{kind: nConst, ord: ord, op: native.EQ, a: v}, true
	case *plan.Literal:
		switch {
		case x.T.Kind == types.KindNull || (x.T.Kind == types.KindBoolean && x.Val.Null):
			return &npred{kind: nFalse}, true
		case x.T.Kind == types.KindBoolean && (x.Val.I != 0) != neg:
			return &npred{kind: nTrue}, true
		case x.T.Kind == types.KindBoolean:
			return &npred{kind: nFalse}, true
		}
	}
	return nil, false
}

func (c *nativeCompiler) comparison(x *plan.Binary, neg bool) (*npred, bool) {
	op := cmpOps[x.Op]
	if neg {
		op, _ = op.Negate()
	}
	lt, rt := x.L.Type(), x.R.Type()
	lord, lcol := c.column(x.L)
	rord, rcol := c.column(x.R)
	switch {
	case lcol && rcol:
		if !intClass(lt) || lt.Kind != rt.Kind || lt.Scale != rt.Scale {
			return nil, false
		}
		return &npred{kind: nCols, ord: lord, ord2: rord, op: op}, true
	case rcol:
		lord, lt, rt = rord, rt, lt
		x = &plan.Binary{Op: x.Op, L: x.R, R: x.L, T: x.T}
		op = op.Flip()
	case !lcol:
		return nil, false
	}
	if !intClass(lt) {
		return nil, false
	}
	v, ok := c.constant(x.R)
	if !ok {
		return nil, false
	}
	k, isNull, ok := constFor(v, rt, lt)
	switch {
	case !ok:
		return nil, false
	case isNull:
		return &npred{kind: nFalse}, true
	}
	return &npred{kind: nConst, ord: lord, op: op, a: k}, true
}

// between compiles X [NOT] BETWEEN Lo AND Hi (lo <= x AND x <= hi).
func (c *nativeCompiler) between(x *plan.Between, neg bool) (*npred, bool) {
	ord, ok := c.column(x.X)
	xt := x.X.Type()
	if !ok || !intClass(xt) || x.LoType.Kind != xt.Kind || x.HiType.Kind != xt.Kind {
		return nil, false
	}
	bound := func(e plan.Expr) (int64, bool, bool) {
		v, ok := c.constant(e)
		if !ok {
			return 0, false, false
		}
		return constFor(v, e.Type(), xt)
	}
	lo, loNull, ok1 := bound(x.Lo)
	hi, hiNull, ok2 := bound(x.Hi)
	if !ok1 || !ok2 {
		return nil, false
	}
	leaf := func(isNull bool, op native.Op, v int64) *npred {
		if isNull {
			return &npred{kind: nFalse}
		}
		return &npred{kind: nConst, ord: ord, op: op, a: v}
	}
	if x.Not == neg {
		if loNull || hiNull {
			return &npred{kind: nFalse}, true
		}
		return &npred{kind: nConst, ord: ord, op: native.Between, a: lo, b: hi}, true
	}
	// NOT (lo <= x AND x <= hi) = x < lo OR x > hi.
	return &npred{kind: nOr, kids: []*npred{leaf(loNull, native.LT, lo), leaf(hiNull, native.GT, hi)}}, true
}

// inList compiles X [NOT] IN (constants).
func (c *nativeCompiler) inList(x *plan.InList, neg bool) (*npred, bool) {
	ord, ok := c.column(x.X)
	xt := x.X.Type()
	if !ok || !intClass(xt) || len(x.List) == 0 {
		return nil, false
	}
	not := x.Not != neg
	var kids []*npred
	for i, e := range x.List {
		if x.CmpTypes[i].Kind != xt.Kind {
			return nil, false
		}
		v, ok := c.constant(e)
		if !ok {
			return nil, false
		}
		k, isNull, ok := constFor(v, e.Type(), xt)
		switch {
		case !ok:
			return nil, false
		case isNull && not:
			// x NOT IN (…, NULL, …) is never TRUE.
			return &npred{kind: nFalse}, true
		case isNull:
			continue
		}
		op := native.EQ
		if not {
			op = native.NE
		}
		kids = append(kids, &npred{kind: nConst, ord: ord, op: op, a: k})
	}
	switch {
	case len(kids) == 0:
		return &npred{kind: nFalse}, true
	case len(kids) == 1:
		return kids[0], true
	case not:
		return &npred{kind: nAnd, kids: kids}, true
	}
	return &npred{kind: nOr, kids: kids}, true
}

// ---------------------------------------------------------------- evaluation

// ncol is the window of one column the kernels read: int64 data and a
// validity bitmap (nil: all valid).
type ncol struct {
	ints  []int64
	valid []byte
}

// columnWindow returns rows [lo, hi) of a table column as kernel input:
// column-layout groups are viewed without copying (validity bitmaps are
// copied only when lo is not byte-aligned), row-layout groups are packed
// into buf.
func columnWindow(g *storage.RowGroup, ord, lo, hi int, buf *colBuf) (ncol, error) {
	n := hi - lo
	if tuples := g.Tuples(); tuples != nil {
		buf.ints = grow(buf.ints, n)
		buf.valid = grow(buf.valid, native.BitmapBytes(n))
		clear(buf.valid)
		for i := 0; i < n; i++ {
			v := tuples[lo+i][ord]
			if !v.Null {
				buf.ints[i] = v.I
				buf.valid[i>>3] |= 1 << (i & 7)
			} else {
				buf.ints[i] = 0
			}
		}
		return ncol{ints: buf.ints, valid: buf.valid}, nil
	}
	v, err := g.Column(ord)
	if err != nil {
		return ncol{}, err
	}
	var col ncol
	if v.Ints != nil {
		col.ints = v.Ints[lo:hi] // nil for float/string columns (validity only)
	}
	if v.Valid != nil {
		col.valid = validWindow(v.Valid, lo, n, &buf.valid)
	}
	return col, nil
}

// colBuf holds the packing buffers of one column.
type colBuf struct {
	ints  []int64
	valid []byte
}

// validWindow returns the validity bits of rows [lo, lo+n) as an LSB-first
// byte bitmap (bits past n are unspecified).
func validWindow(valid storage.Bitmap, lo, n int, buf *[]byte) []byte {
	bytes := native.WordsAsBytes(valid)
	nb := native.BitmapBytes(n)
	if lo&7 == 0 {
		return bytes[lo>>3 : lo>>3+nb]
	}
	out := grow(*buf, nb)
	*buf = out
	shift := uint(lo & 7)
	base := lo >> 3
	for j := range out {
		b := bytes[base+j] >> shift
		if base+j+1 < len(bytes) {
			b |= bytes[base+j+1] << (8 - shift)
		}
		out[j] = b
	}
	return out
}

// nfilter evaluates an npred over windows of row groups. It owns scratch
// buffers and is used by one goroutine.
type nfilter struct {
	lib   *native.Lib
	root  *npred
	cols  map[int]*colBuf // packing buffers per ordinal
	tmp   [][]byte        // per tree depth
	ones  []byte
	bits  []byte
	idx   []int32
	group *storage.RowGroup
}

func newNFilter(lib *native.Lib, root *npred) *nfilter {
	return &nfilter{lib: lib, root: root, cols: map[int]*colBuf{}}
}

func (f *nfilter) column(g *storage.RowGroup, ord, lo, hi int) (ncol, error) {
	buf := f.cols[ord]
	if buf == nil {
		buf = &colBuf{}
		f.cols[ord] = buf
	}
	return columnWindow(g, ord, lo, hi, buf)
}

func (f *nfilter) scratch(depth, nb int) []byte {
	for len(f.tmp) <= depth {
		f.tmp = append(f.tmp, nil)
	}
	f.tmp[depth] = grow(f.tmp[depth], nb)
	return f.tmp[depth]
}

// constBits returns a bitmap of nb bytes with every byte set to b.
func constBits(buf *[]byte, nb int, b byte) []byte {
	if len(*buf) < nb {
		*buf = make([]byte, max(nb, BatchSize/8))
		if b != 0 {
			for i := range *buf {
				(*buf)[i] = b
			}
		}
	}
	return (*buf)[:nb]
}

// eval writes the TRUE rows of p over rows [lo, hi) of g into out (bits
// past hi-lo are unspecified).
func (f *nfilter) eval(p *npred, g *storage.RowGroup, lo, hi int, out []byte, depth int) error {
	n := hi - lo
	nb := native.BitmapBytes(n)
	switch p.kind {
	case nConst:
		c, err := f.column(g, p.ord, lo, hi)
		if err != nil {
			return err
		}
		f.lib.FilterI64Bitmap(c.ints, c.valid, p.op, p.a, p.b, out)
	case nCols:
		a, err := f.column(g, p.ord, lo, hi)
		if err != nil {
			return err
		}
		b, err := f.column(g, p.ord2, lo, hi)
		if err != nil {
			return err
		}
		f.lib.CompareI64(a.ints, b.ints, p.op, out)
		if a.valid != nil {
			f.lib.BitmapAnd(out, a.valid, out[:nb])
		}
		if b.valid != nil {
			f.lib.BitmapAnd(out, b.valid, out[:nb])
		}
	case nValid, nNull:
		c, err := f.column(g, p.ord, lo, hi)
		if err != nil {
			return err
		}
		ones := constBits(&f.ones, nb, 0xFF)
		switch {
		case c.valid == nil && p.kind == nValid:
			copy(out, ones)
		case c.valid == nil:
			clear(out[:nb])
		case p.kind == nValid:
			copy(out, c.valid[:nb])
		default:
			f.lib.BitmapAndNot(ones, c.valid, out[:nb])
		}
	case nTrue:
		copy(out, constBits(&f.ones, nb, 0xFF))
	case nFalse:
		clear(out[:nb])
	case nAnd, nOr:
		if err := f.eval(p.kids[0], g, lo, hi, out, depth+1); err != nil {
			return err
		}
		for _, k := range p.kids[1:] {
			tmp := f.scratch(depth, nb)
			if err := f.eval(k, g, lo, hi, tmp, depth+1); err != nil {
				return err
			}
			if p.kind == nAnd {
				f.lib.BitmapAnd(out, tmp, out[:nb])
			} else {
				f.lib.BitmapOr(out, tmp, out[:nb])
			}
		}
	}
	return nil
}

// bitmap returns the bitmap of qualifying rows of [lo, hi) in buf (bits
// past hi-lo are unspecified).
func (f *nfilter) bitmap(g *storage.RowGroup, lo, hi int, buf *[]byte) ([]byte, error) {
	out := grow(*buf, native.BitmapBytes(hi-lo))
	*buf = out
	return out, f.eval(f.root, g, lo, hi, out, 0)
}

// selection returns the qualifying rows of [lo, hi) of g as ascending
// window-relative indices (valid until the next call).
func (f *nfilter) selection(g *storage.RowGroup, lo, hi int) ([]int32, error) {
	n := hi - lo
	f.idx = grow(f.idx, n)
	if p := f.root; p.kind == nConst {
		c, err := f.column(g, p.ord, lo, hi)
		if err != nil {
			return nil, err
		}
		idx := unsafe.Slice((*uint32)(unsafe.Pointer(unsafe.SliceData(f.idx))), n)
		k := f.lib.FilterI64(c.ints, c.valid, p.op, p.a, p.b, idx)
		return f.idx[:k], nil
	}
	bm, err := f.bitmap(g, lo, hi, &f.bits)
	if err != nil {
		return nil, err
	}
	return bitmapToSel(bm, n, f.idx[:0]), nil
}

// bitmapToSel appends the indices of the set bits among the first n bits
// of bm to out.
func bitmapToSel(bm []byte, n int, out []int32) []int32 {
	full := n >> 6
	for w := 0; w < full; w++ {
		word := binary.LittleEndian.Uint64(bm[w*8:])
		base := int32(w * 64)
		for word != 0 {
			out = append(out, base+int32(bits.TrailingZeros64(word)))
			word &= word - 1
		}
	}
	for i := full * 64; i < n; i++ {
		if bm[i>>3]&(1<<(i&7)) != 0 {
			out = append(out, int32(i))
		}
	}
	return out
}
