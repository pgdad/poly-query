package exec

import (
	"context"
	"fmt"
	"math/rand/v2"
	"slices"
	"testing"

	"polyquery/internal/types"
)

// TestParallelSortMatchesComparator checks the radix sort with tie
// resolution against a comparison sort with the full comparator.
func TestParallelSortMatchesComparator(t *testing.T) {
	r := rand.New(rand.NewPCG(7, 8))
	strs := []string{"", "a", "a\x00", "ab", "abcdefgh", "abcdefghi", "abcdefghj", "abcdefgh\x00", "b", "zzzzzzzzzz"}
	const n = 40000
	store := newColStore([]vclass{vInt, vStr, vFloat, vInt})
	for i := 0; i < n; i++ {
		c := store.cols
		c[0].I = append(c[0].I, r.Int64N(50)-25)
		c[0].Nulls = append(c[0].Nulls, r.IntN(10) == 0)
		c[1].S = append(c[1].S, strs[r.IntN(len(strs))])
		c[1].Nulls = append(c[1].Nulls, r.IntN(20) == 0)
		f := []float64{0, -0.0, 1.5, -2, 1e300}[r.IntN(5)]
		c[2].F = append(c[2].F, f)
		c[3].I = append(c[3].I, []int64{-1 << 63, 1<<63 - 1, 0, 7}[r.IntN(4)])
		store.n++
	}
	for _, ks := range [][]sortKey{
		{{index: 0}, {index: 1, desc: true}},
		{{index: 1, nullsFirst: true}, {index: 2}},
		{{index: 2, desc: true}, {index: 0, nullsFirst: true}},
		{{index: 3, desc: true}},
		{{index: 3}, {index: 1, desc: true}},
		{{index: 0, desc: true, nullsFirst: true}, {index: 2}, {index: 1}},
		{{index: 0}},
		{{index: 1}},
	} {
		for _, threads := range []int{1, 4} {
			t.Run(fmt.Sprint(ks, threads), func(t *testing.T) {
				for i := range ks {
					ks[i].typ = types.Type{Kind: types.KindInt64}
				}
				ec := &Context{Ctx: context.Background()}
				c := newColComparator(store, ks, threads)
				got, err := parallelSort(ec, c.items(n, threads), c, threads)
				if err != nil {
					t.Fatal(err)
				}
				want := c.items(n, 1)
				slices.SortFunc(want, func(a, b sortItem) int { return c.compare(a.row, b.row) })
				for i := range want {
					if got[i].row != want[i].row {
						t.Fatalf("position %d: row %d, want %d", i, got[i].row, want[i].row)
					}
				}
			})
		}
	}
}

func BenchmarkRadixSortItems(b *testing.B) {
	r := rand.New(rand.NewPCG(5, 6))
	src := make([]sortItem, 1<<20)
	for i := range src {
		src[i] = sortItem{key: r.Uint64(), row: int32(i)}
	}
	items := make([]sortItem, len(src))
	ec := &Context{Ctx: context.Background()}
	for _, threads := range []int{1, 4} {
		b.Run(fmt.Sprint(threads), func(b *testing.B) {
			for b.Loop() {
				copy(items, src)
				if _, err := radixSortItems(ec, items, threads); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
