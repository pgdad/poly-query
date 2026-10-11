package native

import (
	"math"
	"math/bits"
	"math/rand/v2"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// testLib loads the library from $PQ_NATIVE_KERNELS or the workspace build
// directory, skipping the test when it is unavailable.
func testLib(t *testing.T) *Lib {
	t.Helper()
	path := os.Getenv("PQ_NATIVE_KERNELS")
	if path == "" {
		arch := map[string]string{"amd64": "x86_64", "arm64": "aarch64"}[runtime.GOARCH]
		path = filepath.Join("..", "..", "..", "..", "native-kernels", "build", arch, "libpqkernels.so")
	}
	if _, err := os.Stat(path); err != nil || !Supported() {
		t.Skipf("native kernel library not available (%s)", path)
	}
	lib, err := Load(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	return lib
}

func TestLoadErrors(t *testing.T) {
	if _, err := Load("/nonexistent/libpqkernels.so"); err == nil {
		t.Fatal("loading a missing library succeeded")
	}
}

func randomData(r *rand.Rand, n int) ([]int64, []byte) {
	data := make([]int64, n)
	valid := make([]byte, BitmapBytes(n))
	for i := range data {
		switch r.IntN(10) {
		case 0:
			data[i] = math.MaxInt64 - r.Int64N(3)
		case 1:
			data[i] = math.MinInt64 + r.Int64N(3)
		default:
			data[i] = r.Int64N(41) - 20
		}
		if r.IntN(5) != 0 {
			valid[i>>3] |= 1 << (i & 7)
		}
	}
	return data, valid
}

func isValid(valid []byte, i int) bool { return valid == nil || valid[i>>3]&(1<<(i&7)) != 0 }

func TestKernelsAgainstReference(t *testing.T) {
	lib := testLib(t)
	t.Logf("variant %s (available: %s)", lib.Variant(), lib.AvailableVariants())
	r := rand.New(rand.NewPCG(1, 2))
	for _, n := range []int{0, 1, 7, 8, 9, 63, 64, 65, 1000, 2048, 4099} {
		data, valid := randomData(r, n)
		for _, v := range [][]byte{nil, valid} {
			for op := EQ; op <= Between; op++ {
				a, b := r.Int64N(21)-10, r.Int64N(21)
				var want []uint32
				for i, x := range data {
					if isValid(v, i) && op.Holds(x, a, b) {
						want = append(want, uint32(i))
					}
				}
				idx := make([]uint32, n)
				if got := lib.FilterI64(data, v, op, a, b, idx); got != len(want) {
					t.Fatalf("n=%d op=%d: filter count %d, want %d", n, op, got, len(want))
				}
				for k := range want {
					if idx[k] != want[k] {
						t.Fatalf("n=%d op=%d: index %d = %d, want %d", n, op, k, idx[k], want[k])
					}
				}
				bm := make([]byte, BitmapBytes(n))
				if got := lib.FilterI64Bitmap(data, v, op, a, b, bm); got != len(want) {
					t.Fatalf("bitmap count %d, want %d", got, len(want))
				}
				ones := 0
				for _, x := range bm {
					ones += bits.OnesCount8(x)
				}
				if ones != len(want) || lib.Popcount(bm, n) != len(want) {
					t.Fatalf("bitmap has %d bits, want %d", ones, len(want))
				}
				if got := lib.CountI64(data, v, op, a, b); got != len(want) {
					t.Fatalf("count %d, want %d", got, len(want))
				}
			}
			// Exact sum with overflow detection.
			var hi, lo uint64 // 128-bit two's complement accumulator
			cnt := 0
			var mn, mx int64
			for i, x := range data {
				if !isValid(v, i) {
					continue
				}
				var c uint64
				lo, c = bits.Add64(lo, uint64(x), 0)
				ext := uint64(0)
				if x < 0 {
					ext = math.MaxUint64
				}
				hi, _ = bits.Add64(hi, ext, c)
				if cnt == 0 || x < mn {
					mn = x
				}
				if cnt == 0 || x > mx {
					mx = x
				}
				cnt++
			}
			fits := (hi == 0 && int64(lo) >= 0) || (hi == math.MaxUint64 && int64(lo) < 0)
			sum, ok := lib.SumI64(data, v)
			if ok != fits || (ok && sum != int64(lo)) {
				t.Fatalf("n=%d: sum (%d, %v), want (%d, %v)", n, sum, ok, int64(lo), fits)
			}
			c, gotMin, gotMax := lib.MinMaxI64(data, v)
			if c != cnt || (cnt > 0 && (gotMin != mn || gotMax != mx)) {
				t.Fatalf("minmax (%d,%d,%d), want (%d,%d,%d)", c, gotMin, gotMax, cnt, mn, mx)
			}
		}
	}
}

func TestBitmapHashGather(t *testing.T) {
	lib := testLib(t)
	a := []byte{0xF0, 0x0F, 0xAA}
	b := []byte{0xFF, 0x01, 0x55}
	out := make([]byte, 3)
	lib.BitmapAnd(a, b, out)
	if out[0] != 0xF0 || out[1] != 0x01 || out[2] != 0 {
		t.Fatalf("and: %x", out)
	}
	lib.BitmapOr(a, b, out)
	if out[0] != 0xFF || out[1] != 0x0F || out[2] != 0xFF {
		t.Fatalf("or: %x", out)
	}
	lib.BitmapAndNot(a, b, out)
	if out[0] != 0 || out[1] != 0x0E || out[2] != 0xAA {
		t.Fatalf("andnot: %x", out)
	}
	data := []int64{0, 1, -1, math.MaxInt64}
	hashes := make([]uint64, len(data))
	lib.HashI64(data, 42, hashes)
	for i, x := range data {
		k := uint64(x) ^ 42
		k ^= k >> 33
		k *= 0xff51afd7ed558ccd
		k ^= k >> 33
		k *= 0xc4ceb9fe1a85ec53
		k ^= k >> 33
		if hashes[i] != k {
			t.Fatalf("hash %d: %x, want %x", x, hashes[i], k)
		}
	}
	g := make([]int64, 2)
	lib.GatherI64(data, []uint32{3, 1}, g)
	if g[0] != math.MaxInt64 || g[1] != 1 {
		t.Fatalf("gather: %v", g)
	}
	bm := make([]byte, 1)
	if n := lib.CompareI64([]int64{1, 2, 3}, []int64{2, 2, 2}, LE, bm); n != 2 || bm[0] != 3 {
		t.Fatalf("compare: %d %b", n, bm[0])
	}
	if n := lib.CompareI64([]int64{1}, []int64{1}, Between, bm); n != -1 {
		t.Fatalf("compare with BETWEEN: %d", n)
	}
}

func TestGroupSum(t *testing.T) {
	lib := testLib(t)
	gids := []uint32{0, 1, 0, 2}
	vals := []int64{5, 7, -2, 1}
	valid := []byte{0b1011}
	sums := make([]int64, 3)
	counts := make([]int64, 3)
	if st := lib.GroupSumI64(gids, vals, valid, sums, counts); st != OK {
		t.Fatalf("status %d", st)
	}
	if sums[0] != 5 || sums[1] != 7 || sums[2] != 1 || counts[0] != 1 || counts[2] != 1 {
		t.Fatalf("sums %v counts %v", sums, counts)
	}
	if st := lib.GroupSumI64([]uint32{0, 0}, []int64{math.MaxInt64, 1}, nil, sums, nil); st != Overflow {
		t.Fatalf("overflow status %d", st)
	}
	if st := lib.GroupSumI64([]uint32{3}, []int64{1}, nil, sums, nil); st != Invalid {
		t.Fatalf("invalid status %d", st)
	}
}
