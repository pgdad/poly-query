package index

import (
	"slices"
	"testing"

	"polyquery/internal/storage"
	"polyquery/internal/types"
)

func table(t types.Type, vals []types.Value) *storage.Table {
	v := storage.NewVector(t, len(vals))
	for _, x := range vals {
		v.Append(x)
	}
	return storage.Build("t", &storage.Data{Columns: []storage.ColumnDef{{Name: "c", Type: t}}, Vectors: []*storage.Vector{v}, Rows: len(vals)},
		storage.BuildOptions{GroupSize: 3})
}

func ints(xs ...int64) []types.Value {
	out := make([]types.Value, len(xs))
	for i, x := range xs {
		if x < 0 {
			out[i] = types.NullValue
		} else {
			out[i] = types.IntValue(x)
		}
	}
	return out
}

func TestHashAndBTree(t *testing.T) {
	tb := table(types.Int64, ints(5, 3, -1, 5, 9, 1, -1, 3, 5))
	for _, kind := range []Kind{Hash, BTree} {
		ix, err := Build(Def{Name: "i", Column: "C", Kind: kind}, tb)
		if err != nil {
			t.Fatal(err)
		}
		if ix.Column != "c" || ix.Entries() != 7 {
			t.Fatalf("column %q entries %d", ix.Column, ix.Entries())
		}
		if got := ix.Equal(types.IntValue(5)); !slices.Equal(got, []uint32{0, 3, 8}) {
			t.Fatalf("%s: Equal(5) = %v", kind, got)
		}
		if got := ix.Lookup(ints(9, 3, 9, 4)); !slices.Equal(got, []uint32{1, 4, 7}) {
			t.Fatalf("%s: Lookup = %v", kind, got)
		}
		if got := ix.Equal(types.NullValue); got != nil {
			t.Fatalf("NULL lookup returned %v", got)
		}
	}
	ix, _ := Build(Def{Name: "i", Column: "c", Kind: BTree}, tb)
	r := Range{Lo: &Bound{Value: types.IntValue(3)}, Hi: &Bound{Value: types.IntValue(9), Inclusive: true}}
	if got := ix.Range(r); !slices.Equal(got, []uint32{0, 3, 4, 8}) {
		t.Fatalf("(3, 9] = %v", got)
	}
	if got := ix.Range(Range{Hi: &Bound{Value: types.IntValue(3), Inclusive: true}}); !slices.Equal(got, []uint32{1, 5, 7}) {
		t.Fatalf("<= 3 = %v", got)
	}
	if got := ix.Range(Range{}); len(got) != 7 {
		t.Fatalf("unbounded range returned %d rows", len(got))
	}
}

func TestFloatAndString(t *testing.T) {
	ft := table(types.Float64, []types.Value{types.FloatValue(0), types.FloatValue(-1.5), types.FloatValue(2)})
	for _, kind := range []Kind{Hash, BTree} {
		ix, _ := Build(Def{Name: "f", Column: "c", Kind: kind}, ft)
		if got := ix.Equal(types.FloatValue(-0.0 * 1)); !slices.Equal(got, []uint32{0}) {
			t.Fatalf("%s: -0.0 lookup = %v", kind, got)
		}
	}
	st := table(types.String, []types.Value{types.StringValue("b"), types.StringValue(""), types.StringValue("ä"), types.NullValue})
	ix, _ := Build(Def{Name: "s", Column: "c", Kind: BTree}, st)
	if got := ix.Range(Range{Lo: &Bound{Value: types.StringValue("b"), Inclusive: true}}); !slices.Equal(got, []uint32{0, 2}) {
		t.Fatalf(">= 'b' = %v", got)
	}
}
