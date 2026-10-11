package exec

import (
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Vectorized kernels for wide DECIMALs (precision 19–38, CR-2): operands
// of any exact numeric type (INT64, narrow or wide DECIMAL) are widened to
// 128-bit unscaled values at their own scale; comparisons are exact across
// scales and arithmetic checks the 38-digit bound per element.

// widen returns the first n values of an INT64 / DECIMAL vector of type t as
// Int128s, reusing buf for narrow inputs.
func widen(v *Vec, t types.Type, n int, buf *[]types.Int128) []types.Int128 {
	if t.IsWide() {
		return v.W[:n]
	}
	out := grow(*buf, n)
	*buf = out
	for i, x := range v.I[:n] {
		out[i] = types.Int128From(x)
	}
	return out
}

// vwideCmp compares two exact numeric operands of which at least one is a
// wide DECIMAL.
type vwideCmp struct {
	op         plan.BinaryOp
	l, r       vexpr
	lt, rt     types.Type
	lbuf, rbuf []types.Int128
	out        vecBuf
}

func (c *vcompiler) wideComparison(x *plan.Binary) (vexpr, error) {
	l, err := c.compile(x.L)
	if err != nil {
		return nil, err
	}
	r, err := c.compile(x.R)
	if err != nil {
		return nil, err
	}
	return &vwideCmp{op: x.Op, l: l, r: r, lt: x.L.Type(), rt: x.R.Type()}, nil
}

func (v *vwideCmp) eval(b *Batch, sel []int32) (*Vec, error) {
	lv, err := v.l.eval(b, sel)
	if err != nil {
		return nil, err
	}
	rv, err := v.r.eval(b, sel)
	if err != nil {
		return nil, err
	}
	n := b.N
	a, c := widen(lv, v.lt, n, &v.lbuf), widen(rv, v.rt, n, &v.rbuf)
	out := v.out.reset(n, vInt)
	sl, sr := v.lt.Scale, v.rt.Scale
	if sl == sr {
		for i := range out.I[:n] {
			out.I[i] = cmpResult(v.op, a[i].Cmp(c[i]))
		}
	} else {
		for i := range out.I[:n] {
			out.I[i] = cmpResult(v.op, types.CompareWide(a[i], sl, c[i], sr))
		}
	}
	out.Nulls = orNulls(&v.out, n, lv.Nulls, rv.Nulls)
	return out, nil
}

// vwideArith computes + - * with a wide DECIMAL result.
type vwideArith struct {
	op         plan.BinaryOp
	l, r       vexpr
	lt, rt     types.Type
	lbuf, rbuf []types.Int128
	failed     []bool
	out        vecBuf
}

func (c *vcompiler) wideArithmetic(x *plan.Binary) (vexpr, error) {
	l, err := c.compile(x.L)
	if err != nil {
		return nil, err
	}
	r, err := c.compile(x.R)
	if err != nil {
		return nil, err
	}
	return &vwideArith{op: x.Op, l: l, r: r, lt: x.L.Type(), rt: x.R.Type()}, nil
}

func (v *vwideArith) eval(b *Batch, sel []int32) (*Vec, error) {
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
	a, c := widen(lv, v.lt, n, &v.lbuf), widen(rv, v.rt, n, &v.rbuf)
	out := v.out.reset(n, vWide)
	out.Nulls = nulls
	v.failed = grow(v.failed, n)
	failedAny := false
	sl, sr := v.lt.Scale, v.rt.Scale
	for i := range out.W[:n] {
		r, err := wideOp(v.op, a[i], sl, c[i], sr)
		out.W[i] = r
		v.failed[i] = err != nil
		failedAny = failedAny || err != nil
	}
	if failedAny && anyFailed(n, sel, nulls, v.failed) {
		return nil, errVector
	}
	return out, nil
}

// wideSumState is SUM/AVG over wide DECIMALs: exact 128-bit (then big)
// sums per group; SUM results must fit DECIMAL(38,s).
type wideSumState struct {
	sums  []types.BigDecimalSum
	n     []int64
	avg   bool
	scale int
}

func (s *wideSumState) grow(g int) {
	s.sums = growZero(s.sums, g)
	s.n = growZero(s.n, g)
}

func (s *wideSumState) update(gids []int32, n int, sel []int32, v *Vec) {
	sums, cnt, vals, nulls := s.sums, s.n, v.W, v.Nulls
	forActive(n, sel, func(i int) {
		if nulls == nil || !nulls[i] {
			g := gids[i]
			sums[g].AddWide(vals[i])
			cnt[g]++
		}
	})
}

func (s *wideSumState) merge(g int32, src aggState, sg int32) {
	o := src.(*wideSumState)
	s.sums[g].Merge(&o.sums[sg])
	s.n[g] += o.n[sg]
}

func (s *wideSumState) result(g int) (types.Value, error) {
	switch {
	case s.n[g] == 0:
		return null, nil
	case s.avg:
		return types.FloatValue(s.sums[g].RatioFloat(s.n[g], s.scale)), nil
	}
	return wideSumResult(&s.sums[g])
}

// wideMinMax is MIN/MAX over wide DECIMALs (one scale per column).
type wideMinMax struct {
	sign int
	best []types.Int128
	any  []bool
}

func (s *wideMinMax) grow(g int) {
	s.best = growZero(s.best, g)
	s.any = growZero(s.any, g)
}

func (s *wideMinMax) fold(g int32, x types.Int128) {
	if !s.any[g] || x.Cmp(s.best[g])*s.sign > 0 {
		s.best[g], s.any[g] = x, true
	}
}

func (s *wideMinMax) update(gids []int32, n int, sel []int32, v *Vec) {
	vals, nulls := v.W, v.Nulls
	forActive(n, sel, func(i int) {
		if nulls == nil || !nulls[i] {
			s.fold(gids[i], vals[i])
		}
	})
}

func (s *wideMinMax) merge(g int32, src aggState, sg int32) {
	if o := src.(*wideMinMax); o.any[sg] {
		s.fold(g, o.best[sg])
	}
}

func (s *wideMinMax) result(g int) (types.Value, error) {
	if !s.any[g] {
		return null, nil
	}
	return types.WideValue(s.best[g]), nil
}

// resolveWide resolves a single wide DECIMAL key (one scale per column, so
// equal values have equal unscaled values).
func (t *aggTable) resolveWide(v *Vec, n int, sel []int32, pos int64) error {
	gids, vals, nulls := t.gids, v.W, v.Nulls
	var err error
	forActive(n, sel, func(i int) {
		if err != nil {
			return
		}
		if nulls != nil && nulls[i] {
			gids[i], err = t.nullKey(pos + int64(i))
			return
		}
		k := vals[i]
		g, ok := t.wideMap[k]
		if !ok {
			if g, err = t.newGroup(t.key1(types.WideValue(k)), pos+int64(i)); err != nil {
				return
			}
			t.wideMap[k] = g
		}
		gids[i] = g
	})
	return err
}
