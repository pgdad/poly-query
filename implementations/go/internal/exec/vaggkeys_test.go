package exec

import (
	"context"
	"math/rand/v2"
	"testing"

	"polyquery/internal/types"
)

// TestMultiKeysMatchEncoded checks that the multi-column key resolver and
// the plain-string resolver assign the same groups as the canonical byte
// encoding.
func TestMultiKeysMatchEncoded(t *testing.T) {
	r := rand.New(rand.NewPCG(9, 10))
	ec := &Context{Ctx: context.Background(), Mem: &MemTracker{}}
	dict := []string{"x", "y", "", "zz"}
	keyTypes := []types.Type{{Kind: types.KindInt64}, {Kind: types.KindString}, {Kind: types.KindFloat64}, {Kind: types.KindString}}
	for _, ncols := range []int{1, 2, 4} {
		kt := keyTypes[len(keyTypes)-ncols:]
		fast := newAggTable(ec, kt, nil)
		slow := newAggTable(ec, kt, nil)
		slow.multi = nil
		var pos int64
		for b := 0; b < 20; b++ {
			n := 1 + r.IntN(BatchSize)
			keys := make([]*Vec, ncols)
			for k := range keys {
				v := &Vec{Nulls: make([]bool, n)}
				for i := 0; i < n; i++ {
					v.Nulls[i] = r.IntN(15) == 0
				}
				switch kt[k].Kind {
				case types.KindInt64:
					for i := 0; i < n; i++ {
						v.I = append(v.I, r.Int64N(30)-15)
					}
				case types.KindFloat64:
					for i := 0; i < n; i++ {
						v.F = append(v.F, []float64{0, -0.0, 2.5}[r.IntN(3)])
					}
				default:
					if b%2 == 0 {
						v.Dict = dict
						for i := 0; i < n; i++ {
							v.Codes = append(v.Codes, uint32(r.IntN(len(dict))))
						}
					} else {
						for i := 0; i < n; i++ {
							v.S = append(v.S, string([]byte{'a' + byte(r.IntN(3))}))
						}
					}
				}
				keys[k] = v
			}
			var sel []int32
			if b%3 == 0 {
				for i := 0; i < n; i += 2 {
					sel = append(sel, int32(i))
				}
			}
			if err := fast.resolve(keys, n, sel, pos); err != nil {
				t.Fatal(err)
			}
			if ncols == 1 {
				slow.gids = grow(slow.gids, n)
				if err := slow.resolveEncoded(keys, n, sel, pos); err != nil {
					t.Fatal(err)
				}
			} else if err := slow.resolve(keys, n, sel, pos); err != nil {
				t.Fatal(err)
			}
			forActive(n, sel, func(i int) {
				if fast.gids[i] != slow.gids[i] {
					t.Fatalf("%d columns, batch %d, row %d: group %d, want %d", ncols, b, i, fast.gids[i], slow.gids[i])
				}
			})
			pos += int64(n)
		}
		if fast.groups() != slow.groups() {
			t.Fatalf("%d columns: %d groups, want %d", ncols, fast.groups(), slow.groups())
		}
	}
}
