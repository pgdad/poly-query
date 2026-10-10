package exec

import (
	"math"
	"strings"
	"time"
	"unicode/utf8"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// compileFunc compiles a scalar function call (functions.md §1).
func compileFunc(ec *Context, lay layout, x *plan.Func) (evalFn, error) {
	args, err := compileAll(ec, lay, x.Args)
	if err != nil {
		return nil, err
	}
	if x.NullParam {
		return func(types.Row) (types.Value, error) { return null, nil }, nil
	}
	argType := func(i int) types.Type { return x.Args[i].Type() }
	switch x.Name {
	case "ABS":
		return unaryFn(args[0], absFn(argType(0))), nil
	case "ROUND":
		return unaryFn(args[0], roundFn(argType(0), x.Digits)), nil
	case "FLOOR":
		return unaryFn(args[0], floorCeilFn(argType(0), false)), nil
	case "CEIL":
		return unaryFn(args[0], floorCeilFn(argType(0), true)), nil
	case "SQRT":
		return unaryFn(args[0], func(v types.Value) (types.Value, error) {
			if v.F < 0 {
				return null, errs.New(errs.InvalidArgument, "SQRT of a negative number")
			}
			return types.FloatValue(math.Sqrt(v.F)), nil
		}), nil
	case "POWER":
		return strictFn(args, func(vs []types.Value) (types.Value, error) {
			return power(vs[0].F, vs[1].F)
		}), nil
	case "MOD":
		return strictFn(args, func(vs []types.Value) (types.Value, error) {
			r, err := intOp(plan.OpMod, vs[0].I, vs[1].I)
			return types.IntValue(r), err
		}), nil
	case "LENGTH":
		return unaryFn(args[0], func(v types.Value) (types.Value, error) {
			return types.IntValue(int64(utf8.RuneCountInString(v.S))), nil
		}), nil
	case "UPPER":
		return unaryFn(args[0], func(v types.Value) (types.Value, error) {
			return types.StringValue(asciiMap(v.S, 'a', 'z', -32)), nil
		}), nil
	case "LOWER":
		return unaryFn(args[0], func(v types.Value) (types.Value, error) {
			return types.StringValue(asciiMap(v.S, 'A', 'Z', 32)), nil
		}), nil
	case "TRIM":
		return unaryFn(args[0], stringFn(func(s string) string { return strings.Trim(s, " ") })), nil
	case "LTRIM":
		return unaryFn(args[0], stringFn(func(s string) string { return strings.TrimLeft(s, " ") })), nil
	case "RTRIM":
		return unaryFn(args[0], stringFn(func(s string) string { return strings.TrimRight(s, " ") })), nil
	case "REPLACE":
		return strictFn(args, func(vs []types.Value) (types.Value, error) {
			if vs[1].S == "" {
				return vs[0], nil
			}
			return types.StringValue(strings.ReplaceAll(vs[0].S, vs[1].S, vs[2].S)), nil
		}), nil
	case "SUBSTR":
		return strictFn(args, func(vs []types.Value) (types.Value, error) {
			length := int64(-1)
			if len(vs) == 3 {
				if vs[2].I < 0 {
					return null, errs.New(errs.InvalidArgument, "SUBSTR length must not be negative")
				}
				length = vs[2].I
			}
			return types.StringValue(substr(vs[0].S, vs[1].I, length)), nil
		}), nil
	case "CONCAT":
		ts := make([]types.Type, len(args))
		for i := range args {
			ts[i] = argType(i)
		}
		return func(row types.Row) (types.Value, error) {
			var sb strings.Builder
			for i, f := range args {
				v, err := f(row)
				if err != nil {
					return v, err
				}
				if !v.Null {
					sb.WriteString(types.FormatValue(v, ts[i]))
				}
			}
			return types.StringValue(sb.String()), nil
		}, nil
	case "COALESCE":
		return func(row types.Row) (types.Value, error) {
			for _, f := range args {
				v, err := f(row)
				if err != nil || !v.Null {
					return v, err
				}
			}
			return null, nil
		}, nil
	case "NULLIF":
		return compileNullif(x, args), nil
	case "YEAR", "MONTH", "DAY":
		field := map[string]int{"YEAR": 0, "MONTH": 1, "DAY": 2}[x.Name]
		isTS := argType(0).Kind == types.KindTimestamp
		return unaryFn(args[0], func(v types.Value) (types.Value, error) {
			days := v.I
			if isTS {
				days = types.TimestampToDate(v.I)
			}
			y, m, d := types.CivilFromDays(days)
			return types.IntValue([3]int64{y, m, d}[field]), nil
		}), nil
	case "HOUR", "MINUTE", "SECOND":
		div := map[string]int64{"HOUR": 3600, "MINUTE": 60, "SECOND": 1}[x.Name]
		mod := map[string]int64{"HOUR": 24, "MINUTE": 60, "SECOND": 60}[x.Name]
		return unaryFn(args[0], func(v types.Value) (types.Value, error) {
			rem := v.I - types.TimestampToDate(v.I)*types.MicrosPerDay
			return types.IntValue(rem / 1000000 / div % mod), nil
		}), nil
	case "DATE_TRUNC":
		return unaryFn(args[1], dateTruncFn(argType(1), x.Unit)), nil
	case "DATE_DIFF":
		ta, tb := argType(1), argType(2)
		return strictFn(args[1:], func(vs []types.Value) (types.Value, error) {
			return types.IntValue(dayOf(vs[1], tb) - dayOf(vs[0], ta)), nil
		}), nil
	case "PQ_SLEEP":
		return unaryFn(args[0], func(v types.Value) (types.Value, error) { return sleep(ec, v) }), nil
	}
	return nil, errs.New(errs.InternalError, "unknown function %s", x.Name)
}

// unaryFn applies fn to the non-NULL value of a single argument.
func unaryFn(arg evalFn, fn func(types.Value) (types.Value, error)) evalFn {
	return func(row types.Row) (types.Value, error) {
		v, err := arg(row)
		if err != nil || v.Null {
			return null, err
		}
		return fn(v)
	}
}

// strictFn applies fn when no argument is NULL (else the result is NULL).
func strictFn(args []evalFn, fn func([]types.Value) (types.Value, error)) evalFn {
	return func(row types.Row) (types.Value, error) {
		vs := make([]types.Value, len(args))
		for i, f := range args {
			v, err := f(row)
			if err != nil {
				return null, err
			}
			if v.Null {
				return null, nil
			}
			vs[i] = v
		}
		return fn(vs)
	}
}

func stringFn(f func(string) string) func(types.Value) (types.Value, error) {
	return func(v types.Value) (types.Value, error) { return types.StringValue(f(v.S)), nil }
}

// asciiMap shifts ASCII letters in [lo, hi] by delta. Only words (maximal
// runs of non-whitespace) consisting entirely of ASCII characters are
// mapped; words containing other characters are left unchanged, as are all
// non-letter characters (functions.md §1 as interpreted by the conformance
// suite: UPPER('abc Ünï') = 'ABC Ünï').
func asciiMap(s string, lo, hi byte, delta int) string {
	var b []byte
	for start := 0; start < len(s); {
		end := start
		ascii := true
		for end < len(s) && !isSpace(s[end]) {
			ascii = ascii && s[end] < utf8.RuneSelf
			end++
		}
		if ascii {
			for i := start; i < end; i++ {
				if c := s[i]; c >= lo && c <= hi {
					if b == nil {
						b = []byte(s)
					}
					b[i] = byte(int(c) + delta)
				}
			}
		}
		for end < len(s) && isSpace(s[end]) {
			end++
		}
		start = end
	}
	if b == nil {
		return s
	}
	return string(b)
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

// substr returns the code points at 1-based positions i with
// max(start,1) ≤ i and, if length ≥ 0, i < start+length.
func substr(s string, start, length int64) string {
	from := max(start, 1)
	end := int64(math.MaxInt64)
	if length >= 0 {
		if start > math.MaxInt64-length {
			end = math.MaxInt64
		} else {
			end = start + length
		}
	}
	if end <= from {
		return ""
	}
	pos := int64(1)
	bfrom, bto := len(s), len(s)
	for i := range s {
		if pos == from {
			bfrom = i
		}
		if pos == end {
			bto = i
			break
		}
		pos++
	}
	if bfrom > bto {
		return ""
	}
	return s[bfrom:bto]
}

func absFn(t types.Type) func(types.Value) (types.Value, error) {
	return func(v types.Value) (types.Value, error) {
		switch t.Kind {
		case types.KindFloat64:
			return types.FloatValue(math.Abs(v.F)), nil
		case types.KindInt64, types.KindDecimal:
			if v.I == math.MinInt64 {
				return null, overflowErr("ABS overflow")
			}
			if v.I < 0 {
				return types.IntValue(-v.I), nil
			}
		}
		return v, nil
	}
}

func roundFn(t types.Type, n int64) func(types.Value) (types.Value, error) {
	return func(v types.Value) (types.Value, error) {
		switch t.Kind {
		case types.KindInt64:
			if n >= 0 {
				return v, nil
			}
			r, err := roundInt(v.I, -n)
			return types.IntValue(r), err
		case types.KindDecimal:
			s := int64(t.Scale)
			switch {
			case n >= s:
				return v, nil
			case n >= 0:
				return types.IntValue(types.RoundDiv(v.I, int(s-n))), nil
			}
			q := int64(0)
			if s-n <= 18 {
				q = types.RoundDiv(v.I, int(s-n))
			}
			if q == 0 {
				return types.IntValue(0), nil
			}
			if -n > 18 {
				return null, overflowErr("ROUND result out of range")
			}
			r, err := types.RescaleUp(q, int(-n))
			return types.IntValue(r), err
		case types.KindFloat64:
			r, err := roundFloat(v.F, n)
			return types.FloatValue(r), err
		}
		return v, nil
	}
}

// roundInt rounds an INT64 to a multiple of 10^k (k ≥ 1), half away from zero.
func roundInt(v, k int64) (int64, error) {
	if k > 18 {
		if v >= 5e18 || v <= -5e18 {
			return 0, overflowErr("ROUND result out of range")
		}
		return 0, nil
	}
	q := types.RoundDiv(v, int(k))
	return types.MulInt64(q, types.Pow10[k])
}

func roundFloat(x float64, n int64) (float64, error) {
	switch {
	case n > 308:
		return x, nil
	case n < -308:
		return 0, nil
	case n >= 0:
		p := math.Pow(10, float64(n))
		y := x * p
		if math.IsInf(y, 0) {
			return x, nil
		}
		return math.Round(y) / p, nil
	}
	p := math.Pow(10, float64(-n))
	return finite(math.Round(x/p) * p)
}

func floorCeilFn(t types.Type, ceil bool) func(types.Value) (types.Value, error) {
	return func(v types.Value) (types.Value, error) {
		switch t.Kind {
		case types.KindFloat64:
			if ceil {
				return types.FloatValue(math.Ceil(v.F)), nil
			}
			return types.FloatValue(math.Floor(v.F)), nil
		case types.KindDecimal:
			d := types.Pow10[t.Scale]
			q := types.FloorDiv(v.I, d)
			if ceil && q*d != v.I {
				q++
			}
			return types.IntValue(q), nil
		}
		return v, nil
	}
}

func power(x, y float64) (types.Value, error) {
	if x == 0 && y < 0 {
		return null, errDivZero
	}
	if x < 0 && y != math.Trunc(y) {
		return null, errs.New(errs.InvalidArgument, "POWER of a negative base with a non-integral exponent")
	}
	r, err := finite(math.Pow(x, y))
	return types.FloatValue(r), err
}

func compileNullif(x *plan.Func, args []evalFn) evalFn {
	at, bt := x.Args[0].Type(), x.Args[1].Type()
	cmpIdx := 0
	if len(args) == 3 {
		cmpIdx, at = 2, x.Args[2].Type()
	}
	return func(row types.Row) (types.Value, error) {
		a, err := args[0](row)
		if err != nil || a.Null {
			return a, err
		}
		b, err := args[1](row)
		if err != nil || b.Null {
			return a, err
		}
		ca := a
		if cmpIdx == 2 {
			if ca, err = args[2](row); err != nil {
				return null, err
			}
		}
		if types.Compare(at, ca, bt, b) == 0 {
			return null, nil
		}
		return a, nil
	}
}

func dayOf(v types.Value, t types.Type) int64 {
	if t.Kind == types.KindTimestamp {
		return types.TimestampToDate(v.I)
	}
	return v.I
}

func dateTruncFn(t types.Type, unit string) func(types.Value) (types.Value, error) {
	return func(v types.Value) (types.Value, error) {
		micros := v.I
		if t.Kind == types.KindDate {
			micros *= types.MicrosPerDay
		}
		days := types.TimestampToDate(micros)
		var r int64
		switch unit {
		case "year", "month":
			y, m, _ := types.CivilFromDays(days)
			if unit == "year" {
				m = 1
			}
			r = types.DaysFromCivil(y, m, 1) * types.MicrosPerDay
		case "day":
			r = days * types.MicrosPerDay
		case "hour":
			r = types.FloorDiv(micros, 3600000000) * 3600000000
		case "minute":
			r = types.FloorDiv(micros, 60000000) * 60000000
		default:
			return null, errs.New(errs.InvalidArgument, "unsupported DATE_TRUNC unit %q", unit)
		}
		return types.IntValue(r), nil
	}
}

func sleep(ec *Context, v types.Value) (types.Value, error) {
	if v.I < 0 {
		return null, errs.New(errs.InvalidArgument, "PQ_SLEEP requires a non-negative duration")
	}
	timer := time.NewTimer(time.Duration(v.I) * time.Millisecond)
	defer timer.Stop()
	select {
	case <-timer.C:
		return v, nil
	case <-ec.Ctx.Done():
		return null, ContextError(ec.Ctx.Err())
	}
}

// ---------------------------------------------------------------- LIKE

func compileLike(ec *Context, lay layout, x *plan.Like) (evalFn, error) {
	vf, err := compile(ec, lay, x.X)
	if err != nil {
		return nil, err
	}
	pf, err := compile(ec, lay, x.Pattern)
	if err != nil {
		return nil, err
	}
	not := x.Not
	var fixed *likePattern
	if lit, ok := x.Pattern.(*plan.Literal); ok && !lit.Val.Null {
		fixed = newLikePattern(lit.Val.S)
	}
	return func(row types.Row) (types.Value, error) {
		v, p, err := both(vf, pf, row)
		if err != nil || v.Null || p.Null {
			return null, err
		}
		pat := fixed
		if pat == nil {
			pat = newLikePattern(p.S)
		}
		return types.BoolValue(pat.match(v.S) != not), nil
	}, nil
}

// likePattern is a compiled LIKE pattern over code points: '%' matches any
// sequence, '_' exactly one code point; matching is case-sensitive and covers
// the whole string (semantics.md §11).
type likePattern struct {
	p     []rune
	ascii bool
	bp    []byte
}

func newLikePattern(p string) *likePattern {
	lp := &likePattern{ascii: isASCII(p)}
	if lp.ascii {
		lp.bp = []byte(p)
	} else {
		lp.p = []rune(p)
	}
	return lp
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

func (lp *likePattern) match(s string) bool {
	if lp.ascii && isASCII(s) {
		return wildcard([]byte(s), lp.bp)
	}
	p := lp.p
	if p == nil {
		p = []rune(string(lp.bp))
	}
	return wildcard([]rune(s), p)
}

// wildcard matches s against pattern p with '%' and '_' wildcards using the
// greedy backtracking algorithm (linear in practice, O(|s|·|p|) worst case).
func wildcard[T byte | rune](s, p []T) bool {
	si, pi := 0, 0
	star, mark := -1, 0
	for si < len(s) {
		switch {
		case pi < len(p) && p[pi] == '%':
			star, mark = pi, si
			pi++
		case pi < len(p) && (p[pi] == '_' || p[pi] == s[si]):
			si++
			pi++
		case star >= 0:
			pi = star + 1
			mark++
			si = mark
		default:
			return false
		}
	}
	for pi < len(p) && p[pi] == '%' {
		pi++
	}
	return pi == len(p)
}
