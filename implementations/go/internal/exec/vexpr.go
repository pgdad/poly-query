package exec

import (
	"errors"
	"math"
	"math/bits"

	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Vectorized expression evaluation.
//
// A vexpr computes an expression for a whole batch, column at a time. The
// sel argument lists the rows whose values are needed (nil: all rows
// 0..N-1). Kernels that cannot fail compute every physical row (dense,
// branch-free loops the compiler can keep tight); kernels that can fail
// (overflow, division by zero, conversions) report an error only if one
// of the needed, non-NULL rows fails.
//
// Vectorized evaluation may evaluate subexpressions row-at-a-time
// evaluation would skip (e.g. arguments after a NULL argument). Therefore
// an error from a vexpr never reaches the user directly: operators then
// re-evaluate the batch row by row with the row-mode evaluator of the same
// expression, which yields exactly the row-mode results and errors.

type vexpr interface {
	eval(b *Batch, sel []int32) (*Vec, error)
}

// errVector signals a failure of vectorized evaluation; the caller falls
// back to row-at-a-time evaluation to obtain the precise error.
var errVector = errors.New("vectorized evaluation failed")

// vcompiler compiles expressions against the column layout of a batch.
type vcompiler struct {
	ec      *Context
	lay     layout
	classes []vclass // classes of the batch columns
}

func newVCompiler(ec *Context, cols []plan.Column) *vcompiler {
	c := &vcompiler{ec: ec, lay: layoutOf(cols)}
	for _, col := range cols {
		c.classes = append(c.classes, classOf(col.Type))
	}
	return c
}

// volatile reports whether e calls PQ_SLEEP (whose evaluation count is
// observable).
func volatile(e plan.Expr) bool {
	found := false
	plan.Walk(e, func(x plan.Expr) {
		if f, ok := x.(*plan.Func); ok && f.Name == "PQ_SLEEP" {
			found = true
		}
	})
	return found
}

func (c *vcompiler) compile(e plan.Expr) (vexpr, error) {
	t := e.Type()
	if ref, ok := e.(*plan.ColumnRef); ok {
		if i, ok := c.lay[ref.ID]; ok {
			return &vcol{index: i}, nil
		}
		return c.fallback(e)
	}
	if plan.IsConstant(e) && !volatile(e) {
		if v, err := evalConstant(c.ec, e); err == nil {
			return newVConst(v, classOf(t)), nil
		}
		return c.fallback(e)
	}
	switch x := e.(type) {
	case *plan.Binary:
		if x.L.Type().Kind == types.KindNull || x.R.Type().Kind == types.KindNull {
			break
		}
		switch {
		case x.Op == plan.OpAnd || x.Op == plan.OpOr:
			return c.logic(x)
		case x.Op.IsComparison():
			return c.comparison(x)
		case x.Op == plan.OpConcat:
			return c.elementwise(e)
		}
		return c.arithmetic(x)
	case *plan.Unary:
		if x.Op == plan.OpNot && x.X.Type().Kind != types.KindNull {
			in, err := c.compile(x.X)
			if err != nil {
				return nil, err
			}
			return &vnot{x: in}, nil
		}
		return c.elementwise(e)
	case *plan.IsNull:
		in, err := c.compile(x.X)
		if err != nil {
			return nil, err
		}
		return &visnull{x: in, not: x.Not}, nil
	case *plan.Cast, *plan.Like, *plan.Between:
		return c.elementwise(e)
	case *plan.InList:
		for _, item := range x.List {
			if !plan.IsConstant(item) {
				return c.fallback(e)
			}
		}
		return c.elementwise(e)
	case *plan.Func:
		switch x.Name {
		case "COALESCE", "PQ_SLEEP":
			return c.fallback(e)
		}
		return c.elementwise(e)
	}
	return c.fallback(e)
}

// ---------------------------------------------------------------- leaves

// vcol returns a column of the input batch.
type vcol struct{ index int }

func (v *vcol) eval(b *Batch, _ []int32) (*Vec, error) { return b.Cols[v.index], nil }

// vconst returns a constant: a vector holding the value in every position.
type vconst struct {
	val types.Value
	vec Vec
}

func newVConst(v types.Value, c vclass) *vconst {
	k := &vconst{val: v}
	if v.Null {
		k.vec.Nulls = make([]bool, BatchSize)
		for i := range k.vec.Nulls {
			k.vec.Nulls[i] = true
		}
	}
	switch c {
	case vInt:
		k.vec.I = make([]int64, BatchSize)
		for i := range k.vec.I {
			k.vec.I[i] = v.I
		}
	case vFloat:
		k.vec.F = make([]float64, BatchSize)
		for i := range k.vec.F {
			k.vec.F[i] = v.F
		}
	case vWide:
		k.vec.W = make([]types.Int128, BatchSize)
		for i := range k.vec.W {
			k.vec.W[i] = v.Wide()
		}
	default:
		k.vec.S = make([]string, BatchSize)
		for i := range k.vec.S {
			k.vec.S[i] = v.S
		}
	}
	return k
}

func (k *vconst) eval(*Batch, []int32) (*Vec, error) { return &k.vec, nil }

// vfallback evaluates an expression row by row with the row-mode
// evaluator (CASE, COALESCE, subqueries, outer references, …).
type vfallback struct {
	fn      evalFn
	refs    []int // batch columns the expression reads
	classes []vclass
	cls     vclass
	row     types.Row
	out     vecBuf
}

func (c *vcompiler) fallback(e plan.Expr) (vexpr, error) {
	fn, err := compile(c.ec, c.lay, e)
	if err != nil {
		return nil, err
	}
	f := &vfallback{fn: fn, classes: c.classes, cls: classOf(e.Type()), row: make(types.Row, len(c.classes))}
	for id := range plan.RefSet(e) {
		if i, ok := c.lay[id]; ok {
			f.refs = append(f.refs, i)
		}
	}
	return f, nil
}

func (f *vfallback) eval(b *Batch, sel []int32) (*Vec, error) {
	out := f.out.reset(b.N, f.cls)
	f.out.withNulls(b.N)
	one := func(i int) error {
		for _, k := range f.refs {
			f.row[k] = b.Cols[k].value(i, f.classes[k])
		}
		v, err := f.fn(f.row)
		if err != nil {
			return err
		}
		out.set(i, v, f.cls)
		return nil
	}
	if sel == nil {
		for i := 0; i < b.N; i++ {
			if err := one(i); err != nil {
				return nil, err
			}
		}
		return out, nil
	}
	for _, i := range sel {
		if err := one(int(i)); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// ---------------------------------------------------------------- NULL helpers

// orNulls combines the NULL arrays of two operands into buf (nil if neither
// operand has NULLs).
func orNulls(buf *vecBuf, n int, a, b []bool) []bool {
	switch {
	case a == nil && b == nil:
		return nil
	case b == nil:
		out := buf.withNulls(n)
		copy(out, a[:n])
		return out
	case a == nil:
		out := buf.withNulls(n)
		copy(out, b[:n])
		return out
	}
	out := buf.withNulls(n)
	a, b = a[:n], b[:n]
	for i := range out {
		out[i] = a[i] || b[i]
	}
	return out
}

// anyFailed reports whether some needed, non-NULL row has failed[i] set.
func anyFailed(n int, sel []int32, nulls, failed []bool) bool {
	if sel == nil {
		for i := 0; i < n; i++ {
			if failed[i] && (nulls == nil || !nulls[i]) {
				return true
			}
		}
		return false
	}
	for _, i := range sel {
		if failed[i] && (nulls == nil || !nulls[i]) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- logic

// vlogic is three-valued AND / OR. The right operand is only evaluated
// for rows the left operand does not decide (row mode short-circuits).
type vlogic struct {
	and  bool
	l, r vexpr
	sel  []int32
	out  vecBuf
}

func (c *vcompiler) logic(x *plan.Binary) (vexpr, error) {
	l, err := c.compile(x.L)
	if err != nil {
		return nil, err
	}
	r, err := c.compile(x.R)
	if err != nil {
		return nil, err
	}
	return &vlogic{and: x.Op == plan.OpAnd, l: l, r: r}, nil
}

func (v *vlogic) eval(b *Batch, sel []int32) (*Vec, error) {
	lv, err := v.l.eval(b, sel)
	if err != nil {
		return nil, err
	}
	// decided: left is FALSE (AND) or TRUE (OR).
	var decided int64
	if !v.and {
		decided = 1
	}
	rest := undecided(v.sel, b.N, sel, lv, decided)
	v.sel = rest
	n := b.N
	out := v.out.reset(n, vInt)
	if len(rest) == 0 {
		copy(out.I, lv.I[:n])
		if lv.Nulls != nil {
			copy(v.out.withNulls(n), lv.Nulls[:n])
		}
		return out, nil
	}
	rv, err := v.r.eval(b, rest)
	if err != nil {
		return nil, err
	}
	// Combine (only rows in rest read the right operand).
	copy(out.I, lv.I[:n])
	var nulls []bool
	if lv.Nulls != nil || rv.Nulls != nil {
		nulls = v.out.withNulls(n)
		if lv.Nulls != nil {
			copy(nulls, lv.Nulls[:n])
		}
	}
	for _, i := range rest {
		ln := lv.Nulls != nil && lv.Nulls[i]
		rn := rv.Nulls != nil && rv.Nulls[i]
		switch {
		case !rn && rv.I[i] == decided:
			out.I[i] = decided
			if nulls != nil {
				nulls[i] = false
			}
		case ln || rn:
			out.I[i] = 0
			nulls[i] = true
		default:
			out.I[i] = 1 - decided
		}
	}
	return out, nil
}

// undecided lists the rows of sel (nil: 0..n-1) whose value in v is NULL
// or differs from decided, reusing buf.
func undecided(buf []int32, n int, sel []int32, v *Vec, decided int64) []int32 {
	vals, nulls := v.I, v.Nulls
	if sel == nil && nulls == nil {
		// Branch-free: always store, advance when the row is undecided.
		buf = grow(buf, n)
		k := 0
		for i, x := range vals[:n] {
			buf[k] = int32(i)
			k += int((x ^ decided) & 1)
		}
		return buf[:k]
	}
	rest := buf[:0]
	if sel == nil {
		for i := 0; i < n; i++ {
			if nulls[i] || vals[i] != decided {
				rest = append(rest, int32(i))
			}
		}
		return rest
	}
	for _, i := range sel {
		if (nulls != nil && nulls[i]) || vals[i] != decided {
			rest = append(rest, i)
		}
	}
	return rest
}

// vnot is three-valued NOT.
type vnot struct {
	x   vexpr
	out vecBuf
}

func (v *vnot) eval(b *Batch, sel []int32) (*Vec, error) {
	in, err := v.x.eval(b, sel)
	if err != nil {
		return nil, err
	}
	out := v.out.reset(b.N, vInt)
	src := in.I[:b.N]
	for i, x := range src {
		out.I[i] = x ^ 1
	}
	if in.Nulls != nil {
		copy(v.out.withNulls(b.N), in.Nulls[:b.N])
	}
	return out, nil
}

// visnull is IS [NOT] NULL.
type visnull struct {
	x   vexpr
	not bool
	out vecBuf
}

func (v *visnull) eval(b *Batch, sel []int32) (*Vec, error) {
	in, err := v.x.eval(b, sel)
	if err != nil {
		return nil, err
	}
	out := v.out.reset(b.N, vInt)
	var t, f int64 = 1, 0
	if v.not {
		t, f = 0, 1
	}
	if in.Nulls == nil {
		for i := range out.I {
			out.I[i] = f
		}
		return out, nil
	}
	for i, isNull := range in.Nulls[:b.N] {
		out.I[i] = f
		if isNull {
			out.I[i] = t
		}
	}
	return out, nil
}

// ---------------------------------------------------------------- comparisons

func flipComparison(op plan.BinaryOp) plan.BinaryOp {
	switch op {
	case plan.OpLt:
		return plan.OpGt
	case plan.OpLe:
		return plan.OpGe
	case plan.OpGt:
		return plan.OpLt
	case plan.OpGe:
		return plan.OpLe
	}
	return op
}

type vcmp struct {
	op     plan.BinaryOp
	l, r   vexpr
	cls    vclass
	scaleL int // DECIMAL operands of different scales are compared exactly
	scaleR int
	// rconst is set when the right operand is a constant (comparisons with
	// a constant on the left are flipped).
	rconst *vconst
	// Per-dictionary-entry results for dictionary-encoded STRING operands
	// compared with a constant.
	dict      []string
	dictMatch []int64
	out       vecBuf
}

func (c *vcompiler) comparison(x *plan.Binary) (vexpr, error) {
	lt, rt := x.L.Type(), x.R.Type()
	switch {
	case lt.IsWide() || rt.IsWide():
		// Exact 128-bit comparison per element.
		return c.elementwise(x)
	case lt.Kind != rt.Kind && !(isExact(lt) && isExact(rt)):
		return c.fallback(x)
	}
	l, err := c.compile(x.L)
	if err != nil {
		return nil, err
	}
	r, err := c.compile(x.R)
	if err != nil {
		return nil, err
	}
	op := x.Op
	if lc, ok := l.(*vconst); ok {
		if _, rIsConst := r.(*vconst); !rIsConst {
			l, r, op = r, lc, flipComparison(op)
			lt, rt = rt, lt
		}
	}
	// INT64 (scale 0) and narrow DECIMAL operands compare as int64
	// unscaled values, exactly across scales.
	v := &vcmp{op: op, l: l, r: r, cls: classOf(lt), scaleL: lt.Scale, scaleR: rt.Scale}
	if rc, ok := r.(*vconst); ok {
		v.rconst = rc
	}
	return v, nil
}

// isExact reports whether t is INT64 or DECIMAL.
func isExact(t types.Type) bool { return t.Kind == types.KindInt64 || t.Kind == types.KindDecimal }

func cmpResult(op plan.BinaryOp, c int) int64 {
	var ok bool
	switch op {
	case plan.OpEq:
		ok = c == 0
	case plan.OpNe:
		ok = c != 0
	case plan.OpLt:
		ok = c < 0
	case plan.OpLe:
		ok = c <= 0
	case plan.OpGt:
		ok = c > 0
	default:
		ok = c >= 0
	}
	if ok {
		return 1
	}
	return 0
}

func b2i(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

type ordered interface{ int64 | float64 | string }

// cmpVV compares two vectors element-wise.
func cmpVV[T ordered](op plan.BinaryOp, a, b []T, out []int64) {
	b = b[:len(a)]
	out = out[:len(a)]
	switch op {
	case plan.OpEq:
		for i := range a {
			out[i] = b2i(a[i] == b[i])
		}
	case plan.OpNe:
		for i := range a {
			out[i] = b2i(a[i] != b[i])
		}
	case plan.OpLt:
		for i := range a {
			out[i] = b2i(a[i] < b[i])
		}
	case plan.OpLe:
		for i := range a {
			out[i] = b2i(a[i] <= b[i])
		}
	case plan.OpGt:
		for i := range a {
			out[i] = b2i(a[i] > b[i])
		}
	default:
		for i := range a {
			out[i] = b2i(a[i] >= b[i])
		}
	}
}

// cmpVC compares a vector with a constant element-wise.
func cmpVC[T ordered](op plan.BinaryOp, a []T, c T, out []int64) {
	out = out[:len(a)]
	switch op {
	case plan.OpEq:
		for i := range a {
			out[i] = b2i(a[i] == c)
		}
	case plan.OpNe:
		for i := range a {
			out[i] = b2i(a[i] != c)
		}
	case plan.OpLt:
		for i := range a {
			out[i] = b2i(a[i] < c)
		}
	case plan.OpLe:
		for i := range a {
			out[i] = b2i(a[i] <= c)
		}
	case plan.OpGt:
		for i := range a {
			out[i] = b2i(a[i] > c)
		}
	default:
		for i := range a {
			out[i] = b2i(a[i] >= c)
		}
	}
}

func (v *vcmp) eval(b *Batch, sel []int32) (*Vec, error) {
	lv, err := v.l.eval(b, sel)
	if err != nil {
		return nil, err
	}
	rv, err := v.r.eval(b, sel)
	if err != nil {
		return nil, err
	}
	n := b.N
	out := v.out.reset(n, vInt)
	switch {
	case v.cls == vInt && v.scaleL != v.scaleR:
		for i := 0; i < n; i++ {
			out.I[i] = cmpResult(v.op, types.CompareDecimal(lv.I[i], v.scaleL, rv.I[i], v.scaleR))
		}
	case v.cls == vInt && v.rconst != nil:
		if !simdCmpVCInt(v.op, lv.I[:n], v.rconst.val.I, out.I) {
			cmpVC(v.op, lv.I[:n], v.rconst.val.I, out.I)
		}
	case v.cls == vInt:
		if !simdCmpVVInt(v.op, lv.I[:n], rv.I[:n], out.I) {
			cmpVV(v.op, lv.I[:n], rv.I[:n], out.I)
		}
	case v.cls == vFloat && v.rconst != nil:
		if !simdCmpVCFloat(v.op, lv.F[:n], v.rconst.val.F, out.I) {
			cmpVC(v.op, lv.F[:n], v.rconst.val.F, out.I)
		}
	case v.cls == vFloat:
		if !simdCmpVVFloat(v.op, lv.F[:n], rv.F[:n], out.I) {
			cmpVV(v.op, lv.F[:n], rv.F[:n], out.I)
		}
	case v.rconst != nil && lv.Dict != nil:
		v.compareDict(lv, n, out.I)
	case v.rconst != nil:
		cmpVC(v.op, lv.strs(n)[:n], v.rconst.val.S, out.I)
	default:
		cmpVV(v.op, lv.strs(n)[:n], rv.strs(n)[:n], out.I)
	}
	out.Nulls = orNulls(&v.out, n, lv.Nulls, rv.Nulls)
	return out, nil
}

// compareDict compares a dictionary-encoded vector with the constant by
// comparing every dictionary entry once.
func (v *vcmp) compareDict(lv *Vec, n int, out []int64) {
	if !sameDict(v.dict, lv.Dict) {
		v.dict = lv.Dict
		v.dictMatch = grow(v.dictMatch, len(lv.Dict))
		cmpVC(v.op, lv.Dict, v.rconst.val.S, v.dictMatch)
	}
	m := v.dictMatch
	for i, c := range lv.Codes[:n] {
		out[i] = m[c]
	}
}

// sameDict reports whether two dictionaries are the same slice.
func sameDict(a, b []string) bool {
	return len(a) == len(b) && (len(a) == 0 || &a[0] == &b[0])
}

// ---------------------------------------------------------------- arithmetic

type varith struct {
	op       plan.BinaryOp
	kind     types.Kind
	sl, sr   int // DECIMAL operand scales
	l, r     vexpr
	failed   []bool
	out      vecBuf
	fallback vexpr // element-wise evaluation for unsupported cases
}

func (c *vcompiler) arithmetic(x *plan.Binary) (vexpr, error) {
	kind := x.T.Kind
	switch {
	case kind == types.KindInt64:
	case kind == types.KindFloat64 && x.Op != plan.OpMod:
	case kind == types.KindDecimal && !x.T.IsWide() && (x.Op == plan.OpAdd || x.Op == plan.OpSub || x.Op == plan.OpMul):
	default:
		return c.elementwise(x)
	}
	l, err := c.compile(x.L)
	if err != nil {
		return nil, err
	}
	r, err := c.compile(x.R)
	if err != nil {
		return nil, err
	}
	return &varith{op: x.Op, kind: kind, sl: x.L.Type().Scale, sr: x.R.Type().Scale, l: l, r: r}, nil
}

// mul64 multiplies with overflow detection.
func mul64(a, b int64) (int64, bool) {
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	shi := int64(hi) - (a>>63)&b - (b>>63)&a
	c := int64(lo)
	return c, shi == c>>63
}

func (v *varith) eval(b *Batch, sel []int32) (*Vec, error) {
	lv, err := v.l.eval(b, sel)
	if err != nil {
		return nil, err
	}
	rv, err := v.r.eval(b, sel)
	if err != nil {
		return nil, err
	}
	n := b.N
	nulls := orNulls(&v.out, n, lv.Nulls, rv.Nulls)
	var out *Vec
	failedAny := false
	if v.kind == types.KindFloat64 {
		out = v.out.reset(n, vFloat)
		failedAny = v.floatOp(lv.F[:n], rv.F[:n], out.F[:n])
	} else {
		out = v.out.reset(n, vInt)
		failedAny = v.intOp(lv.I[:n], rv.I[:n], out.I[:n])
	}
	out.Nulls = nulls
	if failedAny && anyFailed(n, sel, nulls, v.failed) {
		return nil, errVector
	}
	return out, nil
}

// intOp computes INT64 or DECIMAL results. It reports whether some row
// failed; failed rows are then flagged in v.failed.
func (v *varith) intOp(a, b, out []int64) bool {
	b = b[:len(a)]
	if v.fastIntOp(a, b, out) {
		return false
	}
	v.failed = grow(v.failed, len(a))
	failedAny := false
	for i := range out {
		var c int64
		ok := true
		x, y := a[i], b[i]
		if v.kind == types.KindInt64 {
			switch v.op {
			case plan.OpAdd:
				c = x + y
				ok = (x^c)&(y^c) >= 0
			case plan.OpSub:
				c = x - y
				ok = (x^y)&(x^c) >= 0
			case plan.OpMul:
				c, ok = mul64(x, y)
			case plan.OpDiv:
				if y == 0 || (x == math.MinInt64 && y == -1) {
					ok = false
				} else {
					c = x / y
				}
			default: // OpMod
				switch y {
				case 0:
					ok = false
				case -1:
					c = 0
				default:
					c = x % y
				}
			}
		} else {
			var err error
			switch v.op {
			case plan.OpAdd:
				c, err = types.DecimalAdd(x, v.sl, y, v.sr)
			case plan.OpSub:
				c, err = types.DecimalSub(x, v.sl, y, v.sr)
			default:
				c, err = types.DecimalMul(x, y)
			}
			ok = err == nil
		}
		out[i] = c
		v.failed[i] = !ok
		failedAny = failedAny || !ok
	}
	return failedAny
}

// fastIntOp computes the common operators with branch-free loops and
// reports whether no row failed (otherwise the caller recomputes per
// element with failure flags).
func (v *varith) fastIntOp(a, b, out []int64) bool {
	switch {
	case v.kind == types.KindInt64 && v.op == plan.OpAdd:
		var bad int64
		for i := range out {
			c := a[i] + b[i]
			bad |= (a[i] ^ c) & (b[i] ^ c)
			out[i] = c
		}
		return bad >= 0
	case v.kind == types.KindInt64 && v.op == plan.OpSub:
		var bad int64
		for i := range out {
			c := a[i] - b[i]
			bad |= (a[i] ^ b[i]) & (a[i] ^ c)
			out[i] = c
		}
		return bad >= 0
	case v.kind == types.KindInt64 && v.op == plan.OpMul:
		ok := true
		for i := range out {
			c, fits := mul64(a[i], b[i])
			ok = ok && fits
			out[i] = c
		}
		return ok
	case v.kind == types.KindDecimal && v.sl == v.sr && (v.op == plan.OpAdd || v.op == plan.OpSub):
		const lim = types.MaxDecimalUnscaled
		sign := int64(1)
		if v.op == plan.OpSub {
			sign = -1
		}
		ok := true
		for i := range out {
			c := a[i] + sign*b[i] // |a|, |b| < 10^18: no int64 overflow
			ok = ok && c > -lim && c < lim
			out[i] = c
		}
		return ok
	}
	return false
}

func (v *varith) floatOp(a, b, out []float64) bool {
	b = b[:len(a)]
	if simdFloatOp(v.op, a, b, out) {
		return v.flagNonFinite(out)
	}
	switch v.op {
	case plan.OpAdd:
		for i := range out {
			out[i] = a[i] + b[i]
		}
	case plan.OpSub:
		for i := range out {
			out[i] = a[i] - b[i]
		}
	case plan.OpMul:
		for i := range out {
			out[i] = a[i] * b[i]
		}
	default:
		for i := range out {
			out[i] = a[i] / b[i]
		}
	}
	return v.flagNonFinite(out)
}

// flagNonFinite flags non-finite results (incl. division by zero) as
// failed and reports whether there are any.
func (v *varith) flagNonFinite(out []float64) bool {
	bad := false
	for _, x := range out {
		if math.IsInf(x, 0) || math.IsNaN(x) {
			bad = true
			break
		}
	}
	if !bad {
		return false
	}
	v.failed = grow(v.failed, len(out))
	for i, x := range out {
		v.failed[i] = math.IsInf(x, 0) || math.IsNaN(x)
	}
	return true
}

// ---------------------------------------------------------------- element-wise

// velementwise evaluates a node whose operands are evaluated vectorized:
// the node itself is applied per row by the row-mode evaluator over a small
// row holding the operand values. Constant operands stay inline (so LIKE
// patterns, IN sets etc. are prepared once). When the only variable operand
// is a dictionary-encoded STRING vector, the node is evaluated once per
// dictionary entry.
type velementwise struct {
	fn      evalFn
	args    []vexpr
	argCls  []vclass
	cls     vclass
	row     types.Row
	out     vecBuf
	vals    []*Vec
	dict    []string
	dictOut []types.Value
	dictErr bool
	dictStr []string
}

func (c *vcompiler) elementwise(e plan.Expr) (vexpr, error) {
	var args []vexpr
	var argCls []vclass
	lay := layout{}
	first := true
	var compileErr error
	mapped := plan.Map(e, func(x plan.Expr) plan.Expr {
		if first {
			first = false
			return nil
		}
		if plan.IsConstant(x) && !volatile(x) {
			return x
		}
		v, err := c.compile(x)
		if err != nil {
			compileErr = err
			return x
		}
		id := plan.ColumnID(-1 - len(args))
		lay[id] = len(args)
		args = append(args, v)
		argCls = append(argCls, classOf(x.Type()))
		return &plan.ColumnRef{ID: id, T: x.Type()}
	})
	if compileErr != nil {
		return nil, compileErr
	}
	fn, err := compile(c.ec, lay, mapped)
	if err != nil {
		return nil, err
	}
	return &velementwise{fn: fn, args: args, argCls: argCls, cls: classOf(e.Type()),
		row: make(types.Row, len(args)), vals: make([]*Vec, len(args))}, nil
}

func (v *velementwise) eval(b *Batch, sel []int32) (*Vec, error) {
	for k, a := range v.args {
		vec, err := a.eval(b, sel)
		if err != nil {
			return nil, err
		}
		v.vals[k] = vec
	}
	if len(v.vals) == 1 && v.vals[0].Dict != nil && (len(v.vals[0].Dict) <= 8*BatchSize || sameDict(v.dict, v.vals[0].Dict)) {
		if out, ok := v.evalDict(v.vals[0], b.N); ok {
			return out, nil
		}
	}
	out := v.out.reset(b.N, v.cls)
	v.out.withNulls(b.N)
	one := func(i int) error {
		for k, vec := range v.vals {
			v.row[k] = vec.value(i, v.argCls[k])
		}
		r, err := v.fn(v.row)
		if err != nil {
			return errVector
		}
		out.set(i, r, v.cls)
		return nil
	}
	if sel == nil {
		for i := 0; i < b.N; i++ {
			if err := one(i); err != nil {
				return nil, err
			}
		}
		return out, nil
	}
	for _, i := range sel {
		if err := one(int(i)); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// evalDict applies the node to every dictionary entry once (cached per
// dictionary) and maps the codes. It reports false if some entry fails.
func (v *velementwise) evalDict(in *Vec, n int) (*Vec, bool) {
	if !sameDict(v.dict, in.Dict) {
		v.dict = in.Dict
		v.dictErr = false
		v.dictOut = grow(v.dictOut, len(in.Dict))
		for k, s := range in.Dict {
			v.row[0] = types.Value{S: s}
			r, err := v.fn(v.row)
			if err != nil {
				v.dictErr = true
				break
			}
			v.dictOut[k] = r
		}
		if !v.dictErr && v.cls == vStr {
			// A fresh slice: output dictionaries are immutable (consumers
			// such as parallel gathers may retain them).
			v.dictStr = make([]string, len(in.Dict))
			for k, r := range v.dictOut[:len(in.Dict)] {
				v.dictStr[k] = r.S
			}
		}
	}
	if v.dictErr {
		return nil, false
	}
	// A NULL input row stays NULL for every function evaluated this way
	// except IS NULL-like ones, which are not element-wise nodes.
	var nullRes types.Value
	v.row[0] = null
	if r, err := v.fn(v.row); err == nil {
		nullRes = r
	} else {
		return nil, false
	}
	codes := in.Codes[:n]
	out := v.out.reset(n, v.cls)
	var nulls []bool
	anyNull := in.Nulls != nil && nullRes.Null
	for _, r := range v.dictOut[:len(in.Dict)] {
		anyNull = anyNull || r.Null
	}
	if anyNull {
		nulls = v.out.withNulls(n)
	}
	vals := v.dictOut
	for i, c := range codes {
		r := vals[c]
		if in.Nulls != nil && in.Nulls[i] {
			r = nullRes
		}
		if nulls != nil {
			nulls[i] = r.Null
		}
		switch v.cls {
		case vInt:
			out.I[i] = r.I
		case vFloat:
			out.F[i] = r.F
		case vWide:
			out.W[i] = r.Wide()
		}
	}
	if v.cls == vStr {
		if in.Nulls != nil && !nullRes.Null {
			// Rare: NULL maps to a non-NULL string; decode plainly.
			for i, c := range codes {
				out.S[i] = v.dictStr[c]
				if in.Nulls[i] {
					out.S[i] = nullRes.S
				}
			}
			return out, true
		}
		out.S = out.S[:0]
		out.Dict, out.Codes = v.dictStr[:len(in.Dict)], codes
	}
	return out, true
}
