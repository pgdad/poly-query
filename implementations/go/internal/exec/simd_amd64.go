//go:build goexperiment.simd && amd64

package exec

import (
	"simd/archsimd"

	"polyquery/internal/plan"
)

// Explicit SIMD kernels (AVX2, 4 × 64-bit lanes, unrolled twice) for the
// hottest vectorized loops: comparisons producing 0/1 BOOLEAN vectors and
// FLOAT64 arithmetic. They are compiled with GOEXPERIMENT=simd (the
// standard library's experimental simd/archsimd package; the Makefile sets
// it) and used when the CPU supports AVX2; otherwise the portable loops of
// vexpr.go run. Results are identical either way.

var hasAVX2 = archsimd.X86.AVX2()

// SIMDEnabled reports whether explicit SIMD kernels are in use.
func SIMDEnabled() bool { return hasAVX2 }

func cmpMask(op plan.BinaryOp, x, y archsimd.Int64x4) archsimd.Mask64x4 {
	switch op {
	case plan.OpEq:
		return x.Equal(y)
	case plan.OpNe:
		return x.NotEqual(y)
	case plan.OpLt:
		return x.Less(y)
	case plan.OpLe:
		return x.LessEqual(y)
	case plan.OpGt:
		return x.Greater(y)
	}
	return x.GreaterEqual(y)
}

func cmpMaskF(op plan.BinaryOp, x, y archsimd.Float64x4) archsimd.Mask64x4 {
	switch op {
	case plan.OpEq:
		return x.Equal(y)
	case plan.OpNe:
		return x.NotEqual(y)
	case plan.OpLt:
		return x.Less(y)
	case plan.OpLe:
		return x.LessEqual(y)
	case plan.OpGt:
		return x.Greater(y)
	}
	return x.GreaterEqual(y)
}

func lanes(s []int64, i int) *[4]int64      { return (*[4]int64)(s[i : i+4]) }
func lanesF(s []float64, i int) *[4]float64 { return (*[4]float64)(s[i : i+4]) }

// simdCmpVCInt sets out[i] = a[i] op c (0/1); it reports false if SIMD is
// unavailable (out untouched).
func simdCmpVCInt(op plan.BinaryOp, a []int64, c int64, out []int64) bool {
	if !hasAVX2 {
		return false
	}
	n := len(a)
	out = out[:n]
	cv, one := archsimd.BroadcastInt64x4(c), archsimd.BroadcastInt64x4(1)
	i := 0
	for ; i+8 <= n; i += 8 {
		x := archsimd.LoadInt64x4Array(lanes(a, i))
		y := archsimd.LoadInt64x4Array(lanes(a, i+4))
		cmpMask(op, x, cv).ToInt64x4().And(one).StoreArray(lanes(out, i))
		cmpMask(op, y, cv).ToInt64x4().And(one).StoreArray(lanes(out, i+4))
	}
	cmpVC(op, a[i:], c, out[i:])
	return true
}

func simdCmpVVInt(op plan.BinaryOp, a, b []int64, out []int64) bool {
	if !hasAVX2 {
		return false
	}
	n := len(a)
	b, out = b[:n], out[:n]
	one := archsimd.BroadcastInt64x4(1)
	i := 0
	for ; i+4 <= n; i += 4 {
		x := archsimd.LoadInt64x4Array(lanes(a, i))
		y := archsimd.LoadInt64x4Array(lanes(b, i))
		cmpMask(op, x, y).ToInt64x4().And(one).StoreArray(lanes(out, i))
	}
	cmpVV(op, a[i:], b[i:], out[i:])
	return true
}

func simdCmpVCFloat(op plan.BinaryOp, a []float64, c float64, out []int64) bool {
	if !hasAVX2 {
		return false
	}
	n := len(a)
	out = out[:n]
	cv, one := archsimd.BroadcastFloat64x4(c), archsimd.BroadcastInt64x4(1)
	i := 0
	for ; i+8 <= n; i += 8 {
		x := archsimd.LoadFloat64x4Array(lanesF(a, i))
		y := archsimd.LoadFloat64x4Array(lanesF(a, i+4))
		cmpMaskF(op, x, cv).ToInt64x4().And(one).StoreArray(lanes(out, i))
		cmpMaskF(op, y, cv).ToInt64x4().And(one).StoreArray(lanes(out, i+4))
	}
	cmpVC(op, a[i:], c, out[i:])
	return true
}

func simdCmpVVFloat(op plan.BinaryOp, a, b []float64, out []int64) bool {
	if !hasAVX2 {
		return false
	}
	n := len(a)
	b, out = b[:n], out[:n]
	one := archsimd.BroadcastInt64x4(1)
	i := 0
	for ; i+4 <= n; i += 4 {
		x := archsimd.LoadFloat64x4Array(lanesF(a, i))
		y := archsimd.LoadFloat64x4Array(lanesF(b, i))
		cmpMaskF(op, x, y).ToInt64x4().And(one).StoreArray(lanes(out, i))
	}
	cmpVV(op, a[i:], b[i:], out[i:])
	return true
}

// simdFloatOp computes out = a op b for +, -, * and /.
func simdFloatOp(op plan.BinaryOp, a, b, out []float64) bool {
	if !hasAVX2 {
		return false
	}
	n := len(a)
	b, out = b[:n], out[:n]
	i := 0
	for ; i+4 <= n; i += 4 {
		x := archsimd.LoadFloat64x4Array(lanesF(a, i))
		y := archsimd.LoadFloat64x4Array(lanesF(b, i))
		var r archsimd.Float64x4
		switch op {
		case plan.OpAdd:
			r = x.Add(y)
		case plan.OpSub:
			r = x.Sub(y)
		case plan.OpMul:
			r = x.Mul(y)
		default:
			r = x.Div(y)
		}
		r.StoreArray(lanesF(out, i))
	}
	for ; i < n; i++ {
		switch op {
		case plan.OpAdd:
			out[i] = a[i] + b[i]
		case plan.OpSub:
			out[i] = a[i] - b[i]
		case plan.OpMul:
			out[i] = a[i] * b[i]
		default:
			out[i] = a[i] / b[i]
		}
	}
	return true
}
