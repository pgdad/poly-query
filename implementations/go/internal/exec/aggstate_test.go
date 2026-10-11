package exec

import (
	"fmt"
	"math"
	"math/big"
	"math/rand"
	"testing"

	"polyquery/internal/plan"
	"polyquery/internal/types"
)

func TestGroupMaps(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	im, sm := newIntGroupMap(), newStrGroupMap()
	ints, strs := map[int64]int32{}, map[string]int32{}
	for i := 0; i < 50000; i++ {
		k := r.Int63n(20000) - 10000
		if i%7 == 0 {
			k = int64(i) << 20 // spread keys
		}
		g, slot, ok := im.find(k)
		if want, exists := ints[k]; ok != exists || (ok && g != want) {
			t.Fatalf("int %d: got %d,%v want %d,%v", k, g, ok, want, exists)
		}
		if !ok {
			ints[k] = int32(len(ints))
			im.insert(slot, k, ints[k])
		}
		s := fmt.Sprint("k", r.Intn(15000))
		h := strKeyHash(s)
		g, slot, ok = sm.find(s, h)
		if want, exists := strs[s]; ok != exists || (ok && g != want) {
			t.Fatalf("string %q: got %d,%v want %d,%v", s, g, ok, want, exists)
		}
		if !ok {
			strs[s] = int32(len(strs))
			sm.insert(slot, s, h, strs[s])
		}
	}
}

// exactSum sums values with big.Int.
func exactSum(vals []int64) *big.Int {
	sum := new(big.Int)
	for _, v := range vals {
		sum.Add(sum, big.NewInt(v))
	}
	return sum
}

func TestExactSumStateSpills(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	call := &plan.AggCall{Func: plan.AggSum, Arg: &plan.ColumnRef{T: types.Int64}}
	a, b := newAggState(call).(*exactSumState), newAggState(call).(*exactSumState)
	a.grow(3)
	b.grow(3)
	var vals [3][]int64
	add := func(s *exactSumState, g int32, v int64) {
		s.update([]int32{g}, 1, nil, &Vec{I: []int64{v}})
		vals[g] = append(vals[g], v)
	}
	for i := 0; i < 2000; i++ {
		// Group 0 stays small; group 1 overflows int64 back and forth;
		// group 2 ends beyond int64.
		add(a, 0, r.Int63n(1000)-500)
		big := int64(math.MaxInt64 - r.Int63n(1000))
		if i%3 == 2 {
			big = -big
		}
		add(a, 1, big)
		add(b, 1, r.Int63n(10))
		add(b, 2, math.MaxInt64/3)
	}
	a.merge(2, b, 2)
	a.merge(1, b, 1)
	for g := 0; g < 3; g++ {
		want := exactSum(vals[g])
		got := a.total(int32(g))
		if got.Big().Cmp(want) != 0 {
			t.Errorf("group %d: sum %s, want %s", g, got.Big(), want)
		}
		v, err := a.result(g)
		if fits := want.IsInt64(); fits != (err == nil) || (fits && v.I != want.Int64()) {
			t.Errorf("group %d: result %v %v, want %s", g, v, err, want)
		}
	}
}

func TestRatioFloat64(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for i := 0; i < 20000; i++ {
		sum := r.Int63n(1<<55) - 1<<54
		if i%3 == 0 {
			sum = r.Int63() - r.Int63()
		}
		count, scale := r.Int63n(100000)+1, r.Intn(19)
		var s types.BigDecimalSum
		s.Add(sum)
		if got, want := types.RatioFloat64(sum, count, scale), s.RatioFloat(count, scale); got != want {
			t.Fatalf("RatioFloat64(%d, %d, %d) = %v, want %v", sum, count, scale, got, want)
		}
	}
}

func TestDistinctState(t *testing.T) {
	for _, fn := range []plan.AggFunc{plan.AggCount, plan.AggSum} {
		call := &plan.AggCall{Func: fn, Distinct: true, Arg: &plan.ColumnRef{T: types.Int64}}
		a, b := newDistinctState(call), newDistinctState(call)
		a.grow(2)
		b.grow(2)
		seen := [2]map[int64]bool{{}, {}}
		r := rand.New(rand.NewSource(4))
		for i := 0; i < 5000; i++ {
			g := int32(i % 2)
			v := r.Int63n(300)
			s := a
			if i%3 == 0 {
				s = b
			}
			nulls := []bool{i%11 == 0}
			s.update([]int32{g}, 1, nil, &Vec{I: []int64{v}, Nulls: nulls})
			if !nulls[0] {
				seen[g][v] = true
			}
		}
		a.merge(0, b, 0)
		a.merge(1, b, 1)
		for g := 0; g < 2; g++ {
			want := int64(len(seen[g]))
			if fn == plan.AggSum {
				want = 0
				for v := range seen[g] {
					want += v
				}
			}
			if v, err := a.result(g); err != nil || v.I != want {
				t.Errorf("%v group %d: %v %v, want %d", fn, g, v, err, want)
			}
		}
	}
	// STRING arguments, dictionary-encoded or plain.
	call := &plan.AggCall{Func: plan.AggCount, Distinct: true, Arg: &plan.ColumnRef{T: types.String}}
	s := newDistinctState(call)
	s.grow(1)
	gids := []int32{0, 0, 0, 0}
	s.update(gids, 4, nil, &Vec{S: []string{"a", "b", "a", ""}})
	s.update(gids, 4, []int32{0, 1, 3}, &Vec{Dict: []string{"c", "a"}, Codes: []uint32{0, 1, 0, 0}})
	if v, _ := s.result(0); v.I != 4 {
		t.Errorf("COUNT(DISTINCT string) = %d, want 4", v.I)
	}
}
