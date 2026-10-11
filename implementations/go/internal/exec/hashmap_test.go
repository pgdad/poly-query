package exec

import (
	"math"
	"math/rand/v2"
	"testing"
)

func TestI64Map(t *testing.T) {
	testI64Map(t, func(m *i64Map) {})
	testI64Map(t, func(m *i64Map) { m.setWindow(-100, 1000) })
	testI64Map(t, func(m *i64Map) { m.setWindow(math.MaxInt64-10, 10) })
}

func testI64Map(t *testing.T, setup func(*i64Map)) {
	var m i64Map
	setup(&m)
	ref := map[int64]int32{}
	r := rand.New(rand.NewPCG(1, 2))
	for i := 0; i < 100000; i++ {
		k := r.Int64N(50000) - 25000
		if i%3 == 0 {
			k = int64(i) << 20
		}
		g, ok := m.get(k)
		rg, rok := ref[k]
		if ok != rok || g != rg {
			t.Fatalf("key %d: got %d,%v want %d,%v", k, g, ok, rg, rok)
		}
		if !ok {
			m.put(k, int32(len(ref)))
			ref[k] = int32(len(ref))
		}
	}
}

func TestPairSet(t *testing.T) {
	var s pairSet
	ref := map[[2]int64]bool{}
	r := rand.New(rand.NewPCG(3, 4))
	for i := 0; i < 100000; i++ {
		g, v := int32(r.IntN(100)), r.Int64N(2000)
		if got, want := s.add(g, v), !ref[[2]int64{int64(g), v}]; got != want {
			t.Fatalf("(%d, %d): add = %v, want %v", g, v, got, want)
		}
		ref[[2]int64{int64(g), v}] = true
	}
}

func benchKeys() []int64 {
	r := rand.New(rand.NewPCG(1, 2))
	keys := make([]int64, 1<<20)
	for i := range keys {
		keys[i] = 1 + r.Int64N(100000)
	}
	return keys
}

func BenchmarkI64Map(b *testing.B) {
	keys := benchKeys()
	for b.Loop() {
		var m i64Map
		for _, k := range keys {
			if _, ok := m.get(k); !ok {
				m.put(k, int32(m.n))
			}
		}
	}
}

func BenchmarkGoMap(b *testing.B) {
	keys := benchKeys()
	for b.Loop() {
		m := map[int64]int32{}
		for _, k := range keys {
			if _, ok := m[k]; !ok {
				m[k] = int32(len(m))
			}
		}
	}
}
