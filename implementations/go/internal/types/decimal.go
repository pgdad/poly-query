package types

import (
	"math"
	"math/big"
	"math/bits"
	"strconv"

	"polyquery/internal/errs"
)

// Pow10 holds 10^0 … 10^18.
var Pow10 = [19]int64{
	1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000,
	10000000000, 100000000000, 1000000000000, 10000000000000, 100000000000000,
	1000000000000000, 10000000000000000, 100000000000000000, 1000000000000000000,
}

// MaxDecimalUnscaled is the exclusive bound on |unscaled| for 18-digit decimals.
const MaxDecimalUnscaled = int64(1000000000000000000)

func overflow(format string, args ...any) error {
	return errs.New(errs.NumericOverflow, format, args...)
}

// FitsPrecision reports whether unscaled value u has at most p digits.
func FitsPrecision(u int64, p int) bool {
	if p >= 19 {
		return true
	}
	return u > -Pow10[p] && u < Pow10[p]
}

// AddInt64 returns a+b or NUMERIC_OVERFLOW.
func AddInt64(a, b int64) (int64, error) {
	c := a + b
	if (c > a) != (b > 0) {
		return 0, overflow("integer overflow in addition")
	}
	return c, nil
}

// SubInt64 returns a-b or NUMERIC_OVERFLOW.
func SubInt64(a, b int64) (int64, error) {
	c := a - b
	if (c < a) != (b > 0) {
		return 0, overflow("integer overflow in subtraction")
	}
	return c, nil
}

// MulInt64 returns a*b or NUMERIC_OVERFLOW.
func MulInt64(a, b int64) (int64, error) {
	if c, ok := mulCheck(a, b); ok {
		return c, nil
	}
	return 0, overflow("integer overflow in multiplication")
}

func mulCheck(a, b int64) (int64, bool) {
	hi, lo := bits.Mul64(absU(a), absU(b))
	neg := (a < 0) != (b < 0)
	if hi != 0 {
		return 0, false
	}
	if neg {
		if lo > 1<<63 {
			return 0, false
		}
		return -int64(lo), true
	}
	if lo > math.MaxInt64 {
		return 0, false
	}
	return int64(lo), true
}

func absU(a int64) uint64 {
	if a < 0 {
		return uint64(-a) // wraps correctly for MinInt64
	}
	return uint64(a)
}

// RescaleUp multiplies an unscaled value by 10^k, failing with
// NUMERIC_OVERFLOW if the result needs more than 18 digits.
func RescaleUp(u int64, k int) (int64, error) {
	if k == 0 {
		if u <= -MaxDecimalUnscaled || u >= MaxDecimalUnscaled {
			return 0, overflow("decimal value out of range")
		}
		return u, nil
	}
	if k > 18 {
		if u == 0 {
			return 0, nil
		}
		return 0, overflow("decimal value out of range")
	}
	r, ok := mulCheck(u, Pow10[k])
	if !ok || r <= -MaxDecimalUnscaled || r >= MaxDecimalUnscaled {
		return 0, overflow("decimal value out of range")
	}
	return r, nil
}

// RoundDiv divides u by 10^k rounding half away from zero.
func RoundDiv(u int64, k int) int64 {
	if k == 0 {
		return u
	}
	if k > 18 {
		return 0
	}
	d := Pow10[k]
	q, r := u/d, u%d
	if r < 0 {
		r = -r
	}
	if uint64(r)*2 >= uint64(d) {
		if u < 0 {
			q--
		} else {
			q++
		}
	}
	return q
}

// Rescale converts an unscaled value from scale `from` to scale `to`
// (rounding half away from zero when reducing) and checks precision p.
func Rescale(u int64, from, to, p int) (int64, error) {
	var r int64
	if to >= from {
		var err error
		if r, err = RescaleUp(u, to-from); err != nil {
			return 0, err
		}
	} else {
		r = RoundDiv(u, from-to)
	}
	if !FitsPrecision(r, p) {
		return 0, overflow("value does not fit DECIMAL(%d,%d)", p, to)
	}
	return r, nil
}

// DecimalAdd adds two decimals of scales sa and sb, producing scale max(sa,sb).
func DecimalAdd(a int64, sa int, b int64, sb int) (int64, error) {
	a, b, err := alignScales(a, sa, b, sb)
	if err != nil {
		return 0, err
	}
	c := a + b // both < 10^18 in magnitude, cannot overflow int64
	if c <= -MaxDecimalUnscaled || c >= MaxDecimalUnscaled {
		return 0, overflow("decimal overflow in addition")
	}
	return c, nil
}

// DecimalSub subtracts two decimals of scales sa and sb.
func DecimalSub(a int64, sa int, b int64, sb int) (int64, error) {
	return DecimalAdd(a, sa, -b, sb)
}

func alignScales(a int64, sa int, b int64, sb int) (int64, int64, error) {
	var err error
	if sa < sb {
		a, err = RescaleUp(a, sb-sa)
	} else if sb < sa {
		b, err = RescaleUp(b, sa-sb)
	}
	return a, b, err
}

// DecimalMul multiplies unscaled values exactly; the result scale is the sum
// of the operand scales. Results needing more than 18 digits overflow.
func DecimalMul(a, b int64) (int64, error) {
	hi, lo := bits.Mul64(absU(a), absU(b))
	if hi != 0 || lo >= uint64(MaxDecimalUnscaled) {
		return 0, overflow("decimal overflow in multiplication")
	}
	if (a < 0) != (b < 0) {
		return -int64(lo), nil
	}
	return int64(lo), nil
}

// CompareDecimal compares a/10^sa with b/10^sb exactly (scales are ≤ 18).
func CompareDecimal(a int64, sa int, b int64, sb int) int {
	if sa < sb {
		s, ok := mulCheck(a, Pow10[sb-sa])
		if !ok {
			return signum(a) // |a·10^k| ≥ 2^63 > |b|
		}
		a = s
	} else if sb < sa {
		s, ok := mulCheck(b, Pow10[sa-sb])
		if !ok {
			return -signum(b)
		}
		b = s
	}
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func signum(a int64) int {
	switch {
	case a < 0:
		return -1
	case a > 0:
		return 1
	}
	return 0
}

// DecimalToFloat converts an unscaled decimal to the nearest FLOAT64.
func DecimalToFloat(u int64, s int) float64 {
	if s == 0 {
		return float64(u)
	}
	if u > -(1<<53) && u < 1<<53 {
		// Both operands are exact, so the single division is correctly rounded.
		return float64(u) / float64(Pow10[s])
	}
	f, _ := strconv.ParseFloat(FormatDecimal(u, s), 64)
	return f
}

// FormatDecimal renders an unscaled value with exactly s fractional digits.
func FormatDecimal(u int64, s int) string {
	neg := u < 0
	digits := strconv.FormatUint(absU(u), 10)
	if s > 0 {
		if len(digits) <= s {
			digits = zeros(s-len(digits)+1) + digits
		}
		digits = digits[:len(digits)-s] + "." + digits[len(digits)-s:]
	}
	if neg {
		return "-" + digits
	}
	return digits
}

// AppendDecimal appends FormatDecimal(u, s) to b without allocating.
func AppendDecimal(b []byte, u int64, s int) []byte {
	var buf [24]byte
	digits := strconv.AppendUint(buf[:0], absU(u), 10)
	if u < 0 {
		b = append(b, '-')
	}
	if s <= 0 {
		return append(b, digits...)
	}
	if len(digits) <= s {
		b = append(b, '0', '.')
		for i := len(digits); i < s; i++ {
			b = append(b, '0')
		}
		return append(b, digits...)
	}
	b = append(b, digits[:len(digits)-s]...)
	b = append(b, '.')
	return append(b, digits[len(digits)-s:]...)
}

func zeros(n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = '0'
	}
	return string(b)
}

// BigDecimalSum accumulates exact sums of INT64 values and unscaled
// DECIMALs (narrow or wide) without intermediate overflow: in an int64
// while possible, then in 128 bits, then in a big.Int.
type BigDecimalSum struct {
	small  int64
	wide   Int128
	isWide bool
	big    *big.Int
}

// Add adds v to the sum.
func (s *BigDecimalSum) Add(v int64) {
	if s.big == nil && !s.isWide {
		c := s.small + v
		if (c > s.small) == (v > 0) {
			s.small = c
			return
		}
	}
	s.AddWide(Int128From(v))
}

// AddSmall adds v if the sum stays within int64 (the common case; small
// enough to be inlined into aggregation loops) and reports whether it did;
// otherwise the caller uses Add.
func (s *BigDecimalSum) AddSmall(v int64) bool {
	c := s.small + v
	if s.big != nil || s.isWide || (c > s.small) != (v > 0) {
		return false
	}
	s.small = c
	return true
}

// AddWide adds a 128-bit value to the sum.
func (s *BigDecimalSum) AddWide(x Int128) {
	if s.big != nil {
		s.big.Add(s.big, x.Big())
		return
	}
	if !s.isWide {
		s.wide, s.isWide = Int128From(s.small), true
	}
	c, ok := s.wide.add(x)
	if !ok {
		s.big = s.wide.Big()
		s.big.Add(s.big, x.Big())
		return
	}
	s.wide = c
}

// Merge adds another partial sum.
func (s *BigDecimalSum) Merge(o *BigDecimalSum) {
	switch {
	case o.big != nil:
		if s.big == nil {
			s.big = s.Big()
		}
		s.big.Add(s.big, o.big)
	case o.isWide:
		s.AddWide(o.wide)
	default:
		s.Add(o.small)
	}
}

// Int64 returns the sum if it fits in int64.
func (s *BigDecimalSum) Int64() (int64, bool) {
	switch {
	case s.big != nil:
		if s.big.IsInt64() {
			return s.big.Int64(), true
		}
		return 0, false
	case s.isWide:
		return s.wide.Int64(), s.wide.IsInt64()
	}
	return s.small, true
}

// Wide returns the sum if it fits in 127 bits.
func (s *BigDecimalSum) Wide() (Int128, bool) {
	switch {
	case s.big != nil:
		return Int128FromBig(s.big)
	case s.isWide:
		return s.wide, true
	}
	return Int128From(s.small), true
}

// Big returns the sum as a big.Int.
func (s *BigDecimalSum) Big() *big.Int {
	switch {
	case s.big != nil:
		return new(big.Int).Set(s.big)
	case s.isWide:
		return s.wide.Big()
	}
	return big.NewInt(s.small)
}

// RatioFloat64 returns sum / (count · 10^scale) correctly rounded to
// FLOAT64, like BigDecimalSum.RatioFloat.
func RatioFloat64(sum, count int64, scale int) float64 {
	const exact = 1 << 53 // integers up to 2^53 convert to FLOAT64 exactly
	if scale < len(Pow10) && sum > -exact && sum < exact && count > 0 && count < exact/Pow10[scale] {
		// Both operands are exact, so the single division is correctly
		// rounded.
		return float64(sum) / float64(count*Pow10[scale])
	}
	var s BigDecimalSum
	s.Add(sum)
	return s.RatioFloat(count, scale)
}

// RatioFloat returns sum / (count · 10^scale) correctly rounded to FLOAT64.
func (s *BigDecimalSum) RatioFloat(count int64, scale int) float64 {
	den := big.NewInt(count)
	if scale > 0 {
		den.Mul(den, bigPow10(scale))
	}
	f, _ := new(big.Rat).SetFrac(s.Big(), den).Float64()
	return f
}
