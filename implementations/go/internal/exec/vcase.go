package exec

import (
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// vcase is a searched CASE evaluated batch-wise. Like row-mode evaluation,
// a condition is only evaluated for the rows no earlier condition was
// TRUE for, and a branch result only for the rows that take the branch
// (so CASE WHEN x = 0 THEN 0 ELSE 1 / x END cannot fail on x = 0): each
// WHEN narrows the selection of remaining rows.
type vcase struct {
	conds   []vexpr // nil: a NULL condition (never TRUE)
	results []vexpr // nil: a NULL result
	els     vexpr   // nil: ELSE NULL
	cls     vclass
	out     vecBuf
	rem     []int32
	taken   []int32
	rest    []int32
}

// searchedCase compiles a searched CASE whose branch results have the
// representation of the CASE's type (otherwise it is evaluated row by
// row).
func (c *vcompiler) searchedCase(x *plan.Case) (vexpr, error) {
	t := x.Type()
	same := func(e plan.Expr) bool {
		bt := e.Type()
		if bt.Kind == types.KindNull {
			return true
		}
		return classOf(bt) == classOf(t) && (t.Kind != types.KindDecimal || bt.Scale == t.Scale)
	}
	for _, w := range x.Whens {
		if !same(w.Result) {
			return c.fallback(x)
		}
	}
	if x.Else != nil && !same(x.Else) {
		return c.fallback(x)
	}
	compile := func(e plan.Expr) (vexpr, error) {
		if e == nil || e.Type().Kind == types.KindNull {
			return nil, nil
		}
		return c.compile(e)
	}
	v := &vcase{cls: classOf(t)}
	for _, w := range x.Whens {
		cond, err := compile(w.Cond)
		if err != nil {
			return nil, err
		}
		res, err := compile(w.Result)
		if err != nil {
			return nil, err
		}
		v.conds, v.results = append(v.conds, cond), append(v.results, res)
	}
	var err error
	if v.els, err = compile(x.Else); err != nil {
		return nil, err
	}
	return v, nil
}

func (v *vcase) eval(b *Batch, sel []int32) (*Vec, error) {
	n := b.N
	out := v.out.reset(n, v.cls)
	nulls := v.out.withNulls(n)
	rem := v.rem[:0]
	if sel == nil {
		for i := 0; i < n; i++ {
			rem = append(rem, int32(i))
		}
	} else {
		rem = append(rem, sel...)
	}
	for k, cond := range v.conds {
		if len(rem) == 0 {
			break
		}
		if cond == nil {
			continue
		}
		cv, err := cond.eval(b, rem)
		if err != nil {
			return nil, err
		}
		taken, rest := v.taken[:0], v.rest[:0]
		for _, i := range rem {
			if (cv.Nulls == nil || !cv.Nulls[i]) && cv.I[i] != 0 {
				taken = append(taken, i)
			} else {
				rest = append(rest, i)
			}
		}
		if err := v.fill(b, out, nulls, v.results[k], taken); err != nil {
			return nil, err
		}
		// The remaining rows move to rest's buffer; rem's becomes scratch.
		v.taken, v.rest, rem = taken, rem, rest
	}
	if err := v.fill(b, out, nulls, v.els, rem); err != nil {
		return nil, err
	}
	v.rem = rem
	return out, nil
}

// fill evaluates e for rows and stores the values in out (NULL if e is
// nil).
func (v *vcase) fill(b *Batch, out *Vec, nulls []bool, e vexpr, rows []int32) error {
	if len(rows) == 0 {
		return nil
	}
	if e == nil {
		for _, i := range rows {
			nulls[i] = true
		}
		return nil
	}
	r, err := e.eval(b, rows)
	if err != nil {
		return err
	}
	if r.Nulls != nil {
		for _, i := range rows {
			nulls[i] = r.Nulls[i]
		}
	}
	switch v.cls {
	case vInt:
		for _, i := range rows {
			out.I[i] = r.I[i]
		}
	case vFloat:
		for _, i := range rows {
			out.F[i] = r.F[i]
		}
	case vWide:
		for _, i := range rows {
			out.W[i] = r.W[i]
		}
	default:
		if r.Dict != nil {
			for _, i := range rows {
				out.S[i] = r.Dict[r.Codes[i]]
			}
		} else {
			for _, i := range rows {
				out.S[i] = r.S[i]
			}
		}
	}
	return nil
}
