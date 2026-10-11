package types

import (
	"math/big"
	"strconv"
)

// Wide DECIMAL arithmetic (change request CR-2). Wide decimals (precision
// 19–38) hold their unscaled value as an Int128; every operation whose
// result type is wide converts its operands (INT64, narrow or wide DECIMAL)
// to Int128 with DecimalOf and checks the result against 10^38.
// Intermediate values are exact: products and rescalings that do not fit
// 128 bits are overflows anyway, because 10^38 < 2^127.

// DecimalOf returns the unscaled value of a non-NULL INT64 or DECIMAL value
// of type t (INT64 values have scale 0).
func DecimalOf(t Type, v Value) Int128 {
	if t.IsWide() {
		return v.Wide()
	}
	return Int128From(v.I)
}

// MakeDecimal stores an unscaled value that fits DECIMAL type t.
func MakeDecimal(t Type, x Int128) Value {
	if t.IsWide() {
		return WideValue(x)
	}
	return IntValue(x.Int64())
}

func (u uint128) inc() uint128 {
	if u.lo == ^uint64(0) {
		return uint128{hi: u.hi + 1}
	}
	return uint128{hi: u.hi, lo: u.lo + 1}
}

// RescaleWide converts an unscaled value from scale `from` to scale `to`
// (rounding half away from zero when reducing) and checks precision p.
func RescaleWide(x Int128, from, to, p int) (Int128, error) {
	neg, m := x.Hi < 0, x.abs()
	switch {
	case to > from:
		k := to - from
		if k > MaxDecimalPrecision {
			if m.isZero() {
				return Int128{}, nil
			}
			return Int128{}, overflow("decimal value out of range")
		}
		var ok bool
		if m, ok = mulU128(m, pow10U128[k]); !ok {
			return Int128{}, overflow("decimal value out of range")
		}
	case to < from:
		k := from - to
		if k > MaxDecimalPrecision {
			m = uint128{} // |x| < 10^38 ≤ 10^k / 2
		} else {
			var half bool
			if m, _, half = divPow10(m, k); half {
				m = m.inc()
			}
		}
	}
	if !m.less(pow10U128[p]) {
		return Int128{}, overflow("value does not fit DECIMAL(%d,%d)", p, to)
	}
	return m.signed(neg), nil
}

// AddWide adds two decimals of scales sa and sb, producing scale
// max(sa,sb) and precision 38.
func AddWide(a Int128, sa int, b Int128, sb int) (Int128, error) {
	var err error
	if sa < sb {
		a, err = RescaleWide(a, sa, sb, MaxDecimalPrecision)
	} else if sb < sa {
		b, err = RescaleWide(b, sb, sa, MaxDecimalPrecision)
	}
	if err != nil {
		return Int128{}, overflow("decimal overflow in addition")
	}
	c, ok := a.add(b) // both < 10^38: cannot overflow 128 bits
	if !ok || !FitsWide(c, MaxDecimalPrecision) {
		return Int128{}, overflow("decimal overflow in addition")
	}
	return c, nil
}

// SubWide subtracts two decimals of scales sa and sb.
func SubWide(a Int128, sa int, b Int128, sb int) (Int128, error) {
	return AddWide(a, sa, b.Neg(), sb)
}

// MulDecimalWide multiplies unscaled values exactly; the result scale is the
// sum of the operand scales. Results needing more than 38 digits overflow.
func MulDecimalWide(a, b Int128) (Int128, error) {
	c, ok := MulWide(a, b)
	if !ok || !FitsWide(c, MaxDecimalPrecision) {
		return Int128{}, overflow("decimal overflow in multiplication")
	}
	return c, nil
}

// CompareWide compares a/10^sa with b/10^sb exactly.
func CompareWide(a Int128, sa int, b Int128, sb int) int {
	// Scaling the operand with the smaller scale up either succeeds within
	// 127 bits, or its magnitude exceeds every decimal value, so its sign
	// decides.
	if sa < sb {
		m, ok := mulU128(a.abs(), pow10U128[min(sb-sa, MaxDecimalPrecision)])
		if !ok || m.hi>>63 != 0 {
			return a.Sign()
		}
		a = m.signed(a.Hi < 0)
	} else if sb < sa {
		m, ok := mulU128(b.abs(), pow10U128[min(sa-sb, MaxDecimalPrecision)])
		if !ok || m.hi>>63 != 0 {
			return -b.Sign()
		}
		b = m.signed(b.Hi < 0)
	}
	return a.Cmp(b)
}

// TruncWide divides by 10^k truncating toward zero (0 ≤ k ≤ 38).
func TruncWide(x Int128, k int) Int128 {
	q, _, _ := divPow10(x.abs(), k)
	return q.signed(x.Hi < 0)
}

// FloorWide divides by 10^k rounding toward negative infinity (CeilWide:
// toward positive infinity).
func FloorWide(x Int128, k int) Int128 {
	q, inexact, _ := divPow10(x.abs(), k)
	if inexact && x.Hi < 0 {
		q = q.inc()
	}
	return q.signed(x.Hi < 0)
}

// FloorWideExact divides by 10^k rounding toward negative infinity and
// reports whether the division was exact.
func FloorWideExact(x Int128, k int) (Int128, bool) {
	q, inexact, _ := divPow10(x.abs(), k)
	if inexact && x.Hi < 0 {
		q = q.inc()
	}
	return q.signed(x.Hi < 0), !inexact
}

// CeilWide divides by 10^k rounding toward positive infinity.
func CeilWide(x Int128, k int) Int128 {
	q, inexact, _ := divPow10(x.abs(), k)
	if inexact && x.Hi >= 0 {
		q = q.inc()
	}
	return q.signed(x.Hi < 0)
}

// RoundWide rounds an unscaled value of scale s to n fractional digits
// (half away from zero) and returns it at scale max(0, min(n, s)) (the
// ROUND function); results needing more than 38 digits overflow.
func RoundWide(x Int128, s int, n int64) (Int128, error) {
	switch {
	case n >= int64(s):
		return x, nil
	case n >= 0:
		return RescaleWide(x, s, int(n), MaxDecimalPrecision)
	}
	// Round to a multiple of 10^-n, then scale back up at scale 0.
	k := int64(s) - n
	if k > 2*MaxDecimalPrecision {
		return Int128{}, nil
	}
	q, _ := RescaleWide(x, int(k), 0, MaxDecimalPrecision)
	if q.Sign() == 0 {
		return q, nil
	}
	return RescaleWide(q, 0, int(-n), MaxDecimalPrecision)
}

// NormalizeWide strips trailing fractional zeros: it returns the unscaled
// value and scale of the same number with the smallest scale ≥ 0.
func NormalizeWide(x Int128, s int) (Int128, int) {
	if s == 0 || x.Lo%10 != 0 && x.Hi == 0 {
		return x, s
	}
	neg, m := x.Hi < 0, x.abs()
	for s > 0 {
		q, r := divSmall(m, 10)
		if r != 0 {
			break
		}
		m, s = q, s-1
	}
	return m.signed(neg), s
}

// Pow10Wide returns 10^k (0 ≤ k ≤ 38).
func Pow10Wide(k int) Int128 { return pow10U128[k].signed(false) }

// AppendWide appends an unscaled value with exactly s fractional digits.
func AppendWide(b []byte, x Int128, s int) []byte {
	if x.Hi < 0 {
		b = append(b, '-')
	}
	start := len(b)
	b = appendU128(b, x.abs())
	if s > 0 {
		digits := len(b) - start
		if digits <= s {
			pad := s - digits + 1
			b = append(b, make([]byte, pad)...)
			copy(b[start+pad:], b[start:start+digits])
			for i := start; i < start+pad; i++ {
				b[i] = '0'
			}
			digits += pad
		}
		point := start + digits - s
		b = append(b, 0)
		copy(b[point+1:], b[point:len(b)-1])
		b[point] = '.'
	}
	return b
}

// FormatWide renders an unscaled value with exactly s fractional digits.
func FormatWide(x Int128, s int) string { return string(AppendWide(nil, x, s)) }

// WideToFloat converts an unscaled decimal to the nearest FLOAT64.
func WideToFloat(x Int128, s int) float64 {
	if x.IsInt64() && s <= NarrowDecimalPrecision {
		return DecimalToFloat(x.Int64(), s)
	}
	f, _ := strconv.ParseFloat(FormatWide(x, s), 64) // correctly rounded
	return f
}

// FloatToDecimal converts a finite FLOAT64 to DECIMAL(p,s): the exact
// binary value of the double, rounded half away from zero to scale s. ok is
// false if the result does not fit precision p.
func FloatToDecimal(f float64, p, s int) (Int128, bool) {
	r := new(big.Rat).SetFloat64(f)
	if r == nil {
		return Int128{}, false
	}
	num := new(big.Int).Mul(r.Num(), bigPow10(s))
	neg := num.Sign() < 0
	num.Abs(num)
	den := r.Denom()
	q, m := new(big.Int).QuoRem(num, den, new(big.Int))
	if m.Lsh(m, 1).Cmp(den) >= 0 {
		q.Add(q, big.NewInt(1))
	}
	if neg {
		q.Neg(q)
	}
	x, ok := Int128FromBig(q)
	if !ok || !FitsWide(x, p) {
		return Int128{}, false
	}
	return x, true
}

func bigPow10(k int) *big.Int {
	return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(k)), nil)
}

// ParseWideExact parses decimal text for DECIMAL(p,s) without rounding
// (ingestion rule): at most s fractional digits and at most p-s integer
// digits.
func ParseWideExact(text string, p, s int) (Int128, TextStatus) {
	neg, ip, frac, ok := decimalParts(text)
	if !ok {
		return Int128{}, TextSyntax
	}
	if len(frac) > s || len(ip) > p-s {
		return Int128{}, TextRange
	}
	return parseU128(ip + frac + zeroDigits(s-len(frac))).signed(neg), TextOK
}

// ParseWideRound parses decimal text for DECIMAL(p,s), rounding extra
// fractional digits half away from zero (CAST rule).
func ParseWideRound(text string, p, s int) (Int128, TextStatus) {
	neg, ip, frac, ok := decimalParts(text)
	if !ok {
		return Int128{}, TextSyntax
	}
	if len(ip) > p-s {
		return Int128{}, TextRange
	}
	roundUp := false
	if len(frac) > s {
		roundUp = frac[s] >= '5'
		frac = frac[:s]
	}
	m := parseU128(ip + frac + zeroDigits(s-len(frac)))
	if roundUp {
		m = m.inc()
	}
	if !m.less(pow10U128[p]) {
		return Int128{}, TextRange
	}
	return m.signed(neg), TextOK
}

// ParseDecimalValue parses decimal text into a value of DECIMAL type t,
// rounding extra fractional digits (CAST) or rejecting them (ingestion).
func ParseDecimalValue(text string, t Type, round bool) (Value, TextStatus) {
	if t.IsWide() {
		var x Int128
		var st TextStatus
		if round {
			x, st = ParseWideRound(text, t.Precision, t.Scale)
		} else {
			x, st = ParseWideExact(text, t.Precision, t.Scale)
		}
		return WideValue(x), st
	}
	var u int64
	var st TextStatus
	if round {
		u, st = ParseDecimalRound(text, t.Precision, t.Scale)
	} else {
		u, st = ParseDecimalExact(text, t.Precision, t.Scale)
	}
	return IntValue(u), st
}

// FormatDecimalValue renders a non-NULL DECIMAL value of type t canonically.
func FormatDecimalValue(v Value, t Type) string {
	if t.IsWide() {
		return FormatWide(v.Wide(), t.Scale)
	}
	return FormatDecimal(v.I, t.Scale)
}

// AppendDecimalValue appends the canonical text of a DECIMAL value.
func AppendDecimalValue(b []byte, v Value, t Type) []byte {
	if t.IsWide() {
		return AppendWide(b, v.Wide(), t.Scale)
	}
	return AppendDecimal(b, v.I, t.Scale)
}

// DecimalValueToFloat converts a DECIMAL value of type t to the nearest
// FLOAT64.
func DecimalValueToFloat(v Value, t Type) float64 {
	if t.IsWide() {
		return WideToFloat(v.Wide(), t.Scale)
	}
	return DecimalToFloat(v.I, t.Scale)
}

func zeroDigits(n int) string {
	if n <= 0 {
		return ""
	}
	return zeros(n)
}
