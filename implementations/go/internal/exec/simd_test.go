package exec

import (
	"math"
	"math/rand/v2"
	"testing"

	"polyquery/internal/plan"
)

// TestSIMDKernelsMatchScalar checks the explicit SIMD kernels (when
// compiled in) against the portable loops, including lengths that leave a
// scalar remainder.
func TestSIMDKernelsMatchScalar(t *testing.T) {
	ops := []plan.BinaryOp{plan.OpEq, plan.OpNe, plan.OpLt, plan.OpLe, plan.OpGt, plan.OpGe}
	r := rand.New(rand.NewPCG(1, 2))
	for _, n := range []int{0, 1, 3, 4, 7, 8, 9, 31, 2048} {
		a, b := make([]int64, n), make([]int64, n)
		fa, fb := make([]float64, n), make([]float64, n)
		for i := range a {
			a[i], b[i] = r.Int64N(7)-3, r.Int64N(7)-3
			if i%5 == 0 {
				a[i] = math.MinInt64 + r.Int64N(2)
			}
			fa[i], fb[i] = float64(a[i])/2, float64(b[i])/2
		}
		for _, op := range ops {
			want, got := make([]int64, n), make([]int64, n)
			cmpVC(op, a, 1, want)
			if simdCmpVCInt(op, a, 1, got) && !equalInts(want, got) {
				t.Errorf("int VC %s n=%d", op, n)
			}
			cmpVV(op, a, b, want)
			if simdCmpVVInt(op, a, b, got) && !equalInts(want, got) {
				t.Errorf("int VV %s n=%d", op, n)
			}
			cmpVC(op, fa, 0.5, want)
			if simdCmpVCFloat(op, fa, 0.5, got) && !equalInts(want, got) {
				t.Errorf("float VC %s n=%d", op, n)
			}
			cmpVV(op, fa, fb, want)
			if simdCmpVVFloat(op, fa, fb, got) && !equalInts(want, got) {
				t.Errorf("float VV %s n=%d", op, n)
			}
		}
		for _, op := range []plan.BinaryOp{plan.OpAdd, plan.OpSub, plan.OpMul, plan.OpDiv} {
			got := make([]float64, n)
			if !simdFloatOp(op, fa, fb, got) {
				continue
			}
			for i := range got {
				var w float64
				switch op {
				case plan.OpAdd:
					w = fa[i] + fb[i]
				case plan.OpSub:
					w = fa[i] - fb[i]
				case plan.OpMul:
					w = fa[i] * fb[i]
				default:
					w = fa[i] / fb[i]
				}
				if math.Float64bits(w) != math.Float64bits(got[i]) && !(math.IsNaN(w) && math.IsNaN(got[i])) {
					t.Errorf("float %s n=%d i=%d: %v != %v", op, n, i, got[i], w)
				}
			}
		}
	}
	t.Logf("SIMD kernels enabled: %v", SIMDEnabled())
}

func equalInts(a, b []int64) bool {
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestMul64Overflow(t *testing.T) {
	cases := []struct {
		a, b int64
		ok   bool
	}{
		{3, 4, true}, {-3, 4, true}, {math.MaxInt64, 1, true}, {math.MinInt64, 1, true},
		{math.MinInt64, -1, false}, {math.MaxInt64, 2, false}, {1 << 32, 1 << 30, true},
		{1 << 32, 1 << 31, false}, {-(1 << 32), 1 << 31, true}, {-(1 << 32), 1 << 32, false},
	}
	for _, c := range cases {
		got, ok := mul64(c.a, c.b)
		if ok != c.ok || (ok && got != c.a*c.b) {
			t.Errorf("mul64(%d, %d) = %d, %v", c.a, c.b, got, ok)
		}
	}
}
