package exec

import (
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Vector kernels for expressions that the generic element-wise path would
// evaluate through the row-mode evaluator: conversions and calendar
// functions over INT-class vectors, CASE, COALESCE and uncorrelated
// subqueries. They follow the vexpr contract: values are computed for the
// needed rows, and any failure (errVector or an error of an operand) makes
// the caller re-evaluate the batch row by row.

// forNeeded calls fn for the needed rows (sel, nil: 0..n-1) that are not
// NULL in nulls.
func forNeeded(n int, sel []int32, nulls []bool, fn func(i int)) {
	if sel == nil {
		for i := 0; i < n; i++ {
			if nulls == nil || !nulls[i] {
				fn(i)
			}
		}
		return
	}
	for _, i := range sel {
		if nulls == nil || !nulls[i] {
			fn(int(i))
		}
	}
}

// vmapInt applies a function that cannot fail to the non-NULL values of
// an INT-class vector; the result is INT-class (toFloat unset) or FLOAT64.
type vmapInt struct {
	x       vexpr
	toInt   func(int64) int64
	toFloat func(int64) float64
	out     vecBuf
}

func (v *vmapInt) eval(b *Batch, sel []int32) (*Vec, error) {
	in, err := v.x.eval(b, sel)
	if err != nil {
		return nil, err
	}
	n := b.N
	cls := vInt
	if v.toFloat != nil {
		cls = vFloat
	}
	out := v.out.reset(n, cls)
	if in.Nulls != nil {
		copy(v.out.withNulls(n), in.Nulls[:n])
	}
	vals := in.I
	if v.toFloat != nil {
		f, res := v.toFloat, out.F
		forNeeded(n, sel, in.Nulls, func(i int) { res[i] = f(vals[i]) })
	} else {
		f, res := v.toInt, out.I
		forNeeded(n, sel, in.Nulls, func(i int) { res[i] = f(vals[i]) })
	}
	return out, nil
}

// mapKernel returns the vector kernel of a cast or function call over a
// single INT-class operand, or nil if there is none.
func (c *vcompiler) mapKernel(e plan.Expr) (vexpr, error) {
	var arg plan.Expr
	var toInt func(int64) int64
	var toFloat func(int64) float64
	switch x := e.(type) {
	case *plan.Cast:
		from := x.X.Type()
		switch {
		case x.To.Kind != types.KindFloat64:
			return nil, nil
		case from.Kind == types.KindInt64:
			toFloat = func(i int64) float64 { return float64(i) }
		case from.Kind == types.KindDecimal && !from.IsWide():
			s := from.Scale
			toFloat = func(u int64) float64 { return types.DecimalToFloat(u, s) }
		default:
			return nil, nil
		}
		arg = x.X
	case *plan.Func:
		if x.NullParam {
			return nil, nil
		}
		switch x.Name {
		case "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND":
			arg = x.Args[0]
		case "DATE_TRUNC":
			arg = x.Args[1]
		default:
			return nil, nil
		}
		toInt = calendarKernel(x.Name, x.Unit, arg.Type())
		if toInt == nil {
			return nil, nil
		}
	default:
		return nil, nil
	}
	in, err := c.compile(arg)
	if err != nil {
		return nil, err
	}
	return &vmapInt{x: in, toInt: toInt, toFloat: toFloat}, nil
}

// calendarKernel computes a calendar function of a DATE (days) or
// TIMESTAMP (microseconds) value like compileFunc does, or returns nil.
func calendarKernel(name, unit string, t types.Type) func(int64) int64 {
	isTS := t.Kind == types.KindTimestamp
	if !isTS && t.Kind != types.KindDate {
		return nil
	}
	days := func(v int64) int64 {
		if isTS {
			return types.TimestampToDate(v)
		}
		return v
	}
	switch name {
	case "YEAR":
		return func(v int64) int64 { y, _, _ := types.CivilFromDays(days(v)); return y }
	case "MONTH":
		return func(v int64) int64 { _, m, _ := types.CivilFromDays(days(v)); return m }
	case "DAY":
		return func(v int64) int64 { _, _, d := types.CivilFromDays(days(v)); return d }
	case "HOUR", "MINUTE", "SECOND":
		if !isTS {
			return nil
		}
		div := map[string]int64{"HOUR": 3600, "MINUTE": 60, "SECOND": 1}[name]
		mod := map[string]int64{"HOUR": 24, "MINUTE": 60, "SECOND": 60}[name]
		return func(v int64) int64 {
			rem := v - types.TimestampToDate(v)*types.MicrosPerDay
			return rem / 1000000 / div % mod
		}
	case "DATE_TRUNC":
		switch unit {
		case "year", "month", "day", "hour", "minute":
		default:
			return nil // the row evaluator reports the error
		}
		trunc := dateTruncFn(t, unit)
		return func(v int64) int64 {
			r, _ := trunc(types.Value{I: v})
			return r.I
		}
	}
	return nil
}

// ---------------------------------------------------------------- CASE / COALESCE

// vbranches evaluates CASE (without operand) and COALESCE: branch k is
// evaluated for the rows not decided by earlier branches, exactly the rows
// for which row-at-a-time evaluation reaches it.
type vbranches struct {
	operand vexpr   // CASE with operand: compared with the WHEN values
	opCls   vclass  // class of the operand and the WHEN values
	nullOp  []int32 // rows whose operand is NULL (ELSE)
	conds   []vexpr // CASE: WHEN conditions (or values); nil for COALESCE
	results []vexpr // CASE: THEN results; COALESCE: the arguments
	els     vexpr   // CASE: ELSE (nil: NULL)
	cls     vclass
	out     vecBuf
	rows    []int32
	take    []int32
	rest    []int32
}

// branchesKernel compiles a CASE or COALESCE whose branches all have the
// result type, or returns nil.
func (c *vcompiler) branchesKernel(e plan.Expr) (vexpr, error) {
	var conds, results []plan.Expr
	var els, operand plan.Expr
	t := e.Type()
	switch x := e.(type) {
	case *plan.Case:
		if operand = x.Operand; operand != nil {
			// Operand and values of one type compare by representation.
			switch operand.Type().Kind {
			case types.KindInt64, types.KindBoolean, types.KindDate, types.KindTimestamp, types.KindString:
			default:
				return nil, nil
			}
			for _, w := range x.Whens {
				if w.Cond.Type() != operand.Type() {
					return nil, nil
				}
			}
		}
		for _, w := range x.Whens {
			conds = append(conds, w.Cond)
			results = append(results, w.Result)
		}
		els = x.Else
	case *plan.Func:
		if x.Name != "COALESCE" || x.NullParam {
			return nil, nil
		}
		results = x.Args
	default:
		return nil, nil
	}
	if t.Kind == types.KindNull {
		return nil, nil
	}
	for _, r := range append(append([]plan.Expr(nil), results...), els) {
		if r != nil && r.Type() != t {
			return nil, nil
		}
	}
	for _, x := range conds {
		if operand == nil && x.Type().Kind != types.KindBoolean {
			return nil, nil
		}
	}
	if operand != nil && volatile(operand) {
		return nil, nil
	}
	for _, x := range append(append([]plan.Expr(nil), conds...), results...) {
		if volatile(x) {
			return nil, nil
		}
	}
	v := &vbranches{cls: classOf(t)}
	if operand != nil {
		var err error
		if v.operand, err = c.compile(operand); err != nil {
			return nil, err
		}
		v.opCls = classOf(operand.Type())
	}
	for _, x := range conds {
		ve, err := c.compile(x)
		if err != nil {
			return nil, err
		}
		v.conds = append(v.conds, ve)
	}
	for _, x := range results {
		ve, err := c.compile(x)
		if err != nil {
			return nil, err
		}
		v.results = append(v.results, ve)
	}
	if els != nil && !volatile(els) {
		ve, err := c.compile(els)
		if err != nil {
			return nil, err
		}
		v.els = ve
	} else if els != nil {
		return nil, nil
	}
	return v, nil
}

// strAt returns row i of a (possibly dictionary-encoded) STRING vector.
func strAt(v *Vec, i int) string {
	if v.Dict != nil {
		return v.Dict[v.Codes[i]]
	}
	return v.S[i]
}

// copyRows copies rows of src (class cls) into dst, including NULL flags.
func copyRows(dst *Vec, nulls []bool, src *Vec, rows []int32, cls vclass) {
	for _, i := range rows {
		if src.Nulls != nil && src.Nulls[i] {
			nulls[i] = true
			continue
		}
		nulls[i] = false
		switch cls {
		case vInt:
			dst.I[i] = src.I[i]
		case vFloat:
			dst.F[i] = src.F[i]
		case vWide:
			dst.W[i] = src.W[i]
		default:
			if src.Dict != nil {
				dst.S[i] = src.Dict[src.Codes[i]]
			} else {
				dst.S[i] = src.S[i]
			}
		}
	}
}

func (v *vbranches) eval(b *Batch, sel []int32) (*Vec, error) {
	n := b.N
	// The operands are evaluated before the output buffer is filled: an
	// operand may return a vector that aliases a batch column, never this
	// buffer.
	v.rows = v.rows[:0]
	if sel == nil {
		for i := 0; i < n; i++ {
			v.rows = append(v.rows, int32(i))
		}
	} else {
		v.rows = append(v.rows, sel...)
	}
	var op *Vec
	v.nullOp = v.nullOp[:0]
	if v.operand != nil {
		// A NULL operand matches no WHEN value.
		var err error
		if op, err = v.operand.eval(b, v.rows); err != nil {
			return nil, err
		}
		if op.Nulls != nil {
			kept := v.rows[:0]
			for _, i := range v.rows {
				if op.Nulls[i] {
					v.nullOp = append(v.nullOp, i)
				} else {
					kept = append(kept, i)
				}
			}
			v.rows = kept
		}
	}
	out := v.out.reset(n, v.cls)
	nulls := v.out.withNulls(n)
	rows := v.rows
	for k, r := range v.results {
		if len(rows) == 0 {
			break
		}
		v.take, v.rest = v.take[:0], v.rest[:0]
		if v.conds != nil {
			cv, err := v.conds[k].eval(b, rows)
			if err != nil {
				return nil, err
			}
			for _, i := range rows {
				var match bool
				switch {
				case cv.isNull(int(i)):
				case op == nil:
					match = cv.I[i] != 0
				case v.opCls == vInt:
					match = op.I[i] == cv.I[i]
				default:
					match = strAt(op, int(i)) == strAt(cv, int(i))
				}
				if match {
					v.take = append(v.take, i)
				} else {
					v.rest = append(v.rest, i)
				}
			}
			if len(v.take) > 0 {
				rv, err := r.eval(b, v.take)
				if err != nil {
					return nil, err
				}
				copyRows(out, nulls, rv, v.take, v.cls)
			}
		} else {
			rv, err := r.eval(b, rows)
			if err != nil {
				return nil, err
			}
			for _, i := range rows {
				if rv.Nulls != nil && rv.Nulls[i] {
					v.rest = append(v.rest, i)
				} else {
					v.take = append(v.take, i)
				}
			}
			copyRows(out, nulls, rv, v.take, v.cls)
		}
		// rows aliases v.rows or a previous rest buffer: swap buffers.
		v.rows, v.rest = v.rest, rows[:0]
		rows = v.rows
	}
	if len(v.nullOp) > 0 {
		rows = append(rows, v.nullOp...)
	}
	if len(rows) == 0 {
		return out, nil
	}
	if v.els == nil {
		for _, i := range rows {
			nulls[i] = true
		}
		return out, nil
	}
	ev, err := v.els.eval(b, rows)
	if err != nil {
		return nil, err
	}
	copyRows(out, nulls, ev, rows, v.cls)
	return out, nil
}

// ---------------------------------------------------------------- subqueries

// subqueryKernel compiles an uncorrelated scalar, EXISTS or IN subquery
// or a correlated subquery of a shape correlatedKernel supports, or
// returns nil.
func (c *vcompiler) subqueryKernel(x *plan.Subquery) (vexpr, error) {
	if len(x.Correlated) > 0 {
		return c.correlatedKernel(x)
	}
	sub, ok := c.ec.Plan.Subplans[x]
	if !ok {
		return nil, nil
	}
	if x.Kind != plan.SubIn {
		return &vsubConst{ec: c.ec, x: x, sub: sub}, nil
	}
	_, effX := caster(x.X.Type(), x.CmpType)
	_, effSet := caster(sub.Schema()[0].Type, x.CmpType)
	kind := directInKind(effX)
	if kind == vWide || effX.Kind != effSet.Kind || volatile(x.X) {
		return nil, nil
	}
	in, err := c.compile(x.X)
	if err != nil {
		return nil, err
	}
	return &vinSubquery{ec: c.ec, x: x, sub: sub, in: in, kind: kind}, nil
}

// vsubConst is an uncorrelated scalar or EXISTS subquery: a constant
// vector computed on first use.
type vsubConst struct {
	ec  *Context
	x   *plan.Subquery
	sub physical.Node
	vec *vconst
}

func (v *vsubConst) eval(*Batch, []int32) (*Vec, error) {
	if v.vec == nil {
		r, err := v.ec.uncorrelated(v.x, v.sub)
		if err != nil {
			return nil, errVector
		}
		val := r.value
		if v.x.Kind == plan.SubExists {
			val = types.BoolValue(r.exists)
		}
		v.vec = newVConst(val, classOf(v.x.T))
	}
	return &v.vec.vec, nil
}

// vinSubquery is `x [NOT] IN (uncorrelated subquery)` whose values compare
// by their INT-class or STRING representation: the tested values are
// computed vectorized and probed in the subquery's value set.
type vinSubquery struct {
	ec   *Context
	x    *plan.Subquery
	sub  physical.Node
	in   vexpr
	kind vclass
	out  vecBuf
}

func (v *vinSubquery) eval(b *Batch, sel []int32) (*Vec, error) {
	xv, err := v.in.eval(b, sel)
	if err != nil {
		return nil, err
	}
	r, err := v.ec.uncorrelated(v.x, v.sub)
	if err != nil {
		return nil, errVector
	}
	n := b.N
	out := v.out.reset(n, vInt)
	nulls := v.out.withNulls(n)
	// Results as in compileSubquery: FALSE for an empty subquery, NULL
	// for a NULL value or an unmatched value when the subquery has NULLs.
	notFound, found := int64(0), int64(1)
	if v.x.Not {
		notFound, found = 1, 0
	}
	forNeeded(n, sel, nil, func(i int) {
		switch {
		case !r.exists:
			out.I[i] = notFound
		case xv.Nulls != nil && xv.Nulls[i]:
			nulls[i] = true
		default:
			var ok bool
			switch {
			case v.kind == vInt:
				_, ok = r.ints[xv.I[i]]
			case xv.Dict != nil:
				_, ok = r.strs[xv.Dict[xv.Codes[i]]]
			default:
				_, ok = r.strs[xv.S[i]]
			}
			switch {
			case ok:
				out.I[i] = found
			case r.hasNull:
				nulls[i] = true
			default:
				out.I[i] = notFound
			}
		}
	})
	return out, nil
}
