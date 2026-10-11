package types

import (
	"math/big"
	"math/bits"
	"strconv"
)

// Int128 is a signed 128-bit two's-complement integer: the unscaled value
// of a wide DECIMAL (precision 19–38). The value is Hi·2⁶⁴ + Lo.
type Int128 struct {
	Hi int64
	Lo uint64
}

// uint128 is an unsigned 128-bit magnitude.
type uint128 struct{ hi, lo uint64 }

// Int128From sign-extends an int64.
func Int128From(v int64) Int128 { return Int128{Hi: v >> 63, Lo: uint64(v)} }

// pow10U128[k] = 10^k for k = 0…38.
var pow10U128 = func() [39]uint128 {
	var t [39]uint128
	t[0] = uint128{lo: 1}
	for k := 1; k < len(t); k++ {
		t[k], _ = mulSmall(t[k-1], 10)
	}
	return t
}()

// IsInt64 reports whether x fits in an int64.
func (x Int128) IsInt64() bool { return x.Hi == int64(x.Lo)>>63 }

// Int64 returns the low 64 bits as int64 (exact when IsInt64).
func (x Int128) Int64() int64 { return int64(x.Lo) }

// Sign returns -1, 0 or 1.
func (x Int128) Sign() int {
	switch {
	case x.Hi < 0:
		return -1
	case x.Hi == 0 && x.Lo == 0:
		return 0
	}
	return 1
}

// Neg returns -x (wrapping for the minimum value, which never occurs for
// decimal values).
func (x Int128) Neg() Int128 {
	lo, borrow := bits.Sub64(0, x.Lo, 0)
	hi, _ := bits.Sub64(0, uint64(x.Hi), borrow)
	return Int128{Hi: int64(hi), Lo: lo}
}

// Cmp compares x and y.
func (x Int128) Cmp(y Int128) int {
	switch {
	case x.Hi < y.Hi:
		return -1
	case x.Hi > y.Hi:
		return 1
	case x.Lo < y.Lo:
		return -1
	case x.Lo > y.Lo:
		return 1
	}
	return 0
}

// add returns x+y and whether it did not overflow 128 bits.
func (x Int128) add(y Int128) (Int128, bool) {
	lo, carry := bits.Add64(x.Lo, y.Lo, 0)
	hi, _ := bits.Add64(uint64(x.Hi), uint64(y.Hi), carry)
	r := Int128{Hi: int64(hi), Lo: lo}
	// Overflow iff both operands have the same sign and the result differs.
	ok := (x.Hi < 0) != (y.Hi < 0) || (r.Hi < 0) == (x.Hi < 0)
	return r, ok
}

// abs returns the magnitude of x.
func (x Int128) abs() uint128 {
	if x.Hi < 0 {
		n := x.Neg()
		return uint128{hi: uint64(n.Hi), lo: n.Lo}
	}
	return uint128{hi: uint64(x.Hi), lo: x.Lo}
}

// signed applies a sign to a magnitude below 2^127.
func (u uint128) signed(neg bool) Int128 {
	x := Int128{Hi: int64(u.hi), Lo: u.lo}
	if neg {
		return x.Neg()
	}
	return x
}

func (u uint128) less(v uint128) bool { return u.hi < v.hi || u.hi == v.hi && u.lo < v.lo }

func (u uint128) isZero() bool { return u.hi == 0 && u.lo == 0 }

// mulSmall multiplies by a 64-bit factor; ok is false on 128-bit overflow.
func mulSmall(u uint128, m uint64) (uint128, bool) {
	h1, l1 := bits.Mul64(u.lo, m)
	h2, l2 := bits.Mul64(u.hi, m)
	hi, carry := bits.Add64(h1, l2, 0)
	return uint128{hi: hi, lo: l1}, h2 == 0 && carry == 0
}

// mulU128 multiplies two magnitudes; ok is false if the product needs more
// than 128 bits.
func mulU128(a, b uint128) (uint128, bool) {
	if a.hi != 0 && b.hi != 0 {
		return uint128{}, false
	}
	if a.hi != 0 {
		a, b = b, a
	}
	// a < 2^64 now.
	h1, l1 := bits.Mul64(a.lo, b.lo)
	h2, l2 := bits.Mul64(a.lo, b.hi)
	hi, carry := bits.Add64(h1, l2, 0)
	return uint128{hi: hi, lo: l1}, h2 == 0 && carry == 0
}

// divSmall divides by a non-zero 64-bit divisor.
func divSmall(u uint128, d uint64) (uint128, uint64) {
	qhi, r := u.hi/d, u.hi%d
	qlo, r := bits.Div64(r, u.lo, d)
	return uint128{hi: qhi, lo: qlo}, r
}

// divPow10 divides a magnitude by 10^k (0 ≤ k ≤ 38), truncating, and
// reports whether the remainder was non-zero and whether it was at least
// half of 10^k.
func divPow10(u uint128, k int) (q uint128, inexact, half bool) {
	if k == 0 {
		return u, false, false
	}
	// Peel off all but the last digit in chunks of at most 19 digits; the
	// last digit decides "at least half".
	q = u
	for rest := k - 1; rest > 0; {
		step := min(rest, 19)
		var r uint64
		q, r = divSmall(q, pow10U128[step].lo)
		inexact = inexact || r != 0
		rest -= step
	}
	q, r := divSmall(q, 10)
	half = r >= 5
	inexact = inexact || r != 0
	return q, inexact, half
}

// MulWide multiplies two 128-bit integers; ok is false if |a·b| does not fit
// in 127 bits.
func MulWide(a, b Int128) (Int128, bool) {
	p, ok := mulU128(a.abs(), b.abs())
	if !ok || p.hi>>63 != 0 {
		return Int128{}, false
	}
	return p.signed((a.Hi < 0) != (b.Hi < 0)), true
}

// FitsWide reports whether |x| < 10^p for a precision p ≤ 38.
func FitsWide(x Int128, p int) bool { return x.abs().less(pow10U128[p]) }

// String renders x in decimal.
func (x Int128) String() string { return FormatWide(x, 0) }

// Big converts x to a big.Int.
func (x Int128) Big() *big.Int {
	u := x.abs()
	b := new(big.Int).SetUint64(u.hi)
	b.Lsh(b, 64)
	b.Or(b, new(big.Int).SetUint64(u.lo))
	if x.Hi < 0 {
		b.Neg(b)
	}
	return b
}

// Int128FromBig converts a big.Int whose magnitude is below 2^127.
func Int128FromBig(b *big.Int) (Int128, bool) {
	if b.BitLen() > 127 {
		return Int128{}, false
	}
	var m big.Int
	m.Abs(b)
	lo := new(big.Int).And(&m, new(big.Int).SetUint64(^uint64(0))).Uint64()
	hi := new(big.Int).Rsh(&m, 64).Uint64()
	return uint128{hi: hi, lo: lo}.signed(b.Sign() < 0), true
}

// appendU128 appends the decimal digits of a magnitude.
func appendU128(b []byte, u uint128) []byte {
	if u.hi == 0 {
		return strconv.AppendUint(b, u.lo, 10)
	}
	// At most 39 digits: 19-digit chunks from the right.
	var chunks [3]uint64
	n := 0
	for !u.isZero() {
		u, chunks[n] = divSmall(u, pow10U128[19].lo)
		n++
	}
	b = strconv.AppendUint(b, chunks[n-1], 10)
	for i := n - 2; i >= 0; i-- {
		var digits [19]byte
		v := chunks[i]
		for j := len(digits) - 1; j >= 0; j-- {
			digits[j] = byte('0' + v%10)
			v /= 10
		}
		b = append(b, digits[:]...)
	}
	return b
}

// parseU128 converts a string of at most 38 decimal digits.
func parseU128(d string) uint128 {
	var u uint128
	for len(d) > 0 {
		n := min(len(d), 19)
		var chunk uint64
		for i := 0; i < n; i++ {
			chunk = chunk*10 + uint64(d[i]-'0')
		}
		u, _ = mulSmall(u, pow10U128[n].lo)
		lo, carry := bits.Add64(u.lo, chunk, 0)
		u = uint128{hi: u.hi + carry, lo: lo}
		d = d[n:]
	}
	return u
}
