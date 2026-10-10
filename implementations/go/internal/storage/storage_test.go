package storage

import (
	"testing"

	"polyquery/internal/types"
)

func TestVectorNullsAndSlice(t *testing.T) {
	v := NewVector(types.Int64, 0)
	for i := 0; i < 200; i++ {
		if i%7 == 3 {
			v.Append(types.NullValue)
		} else {
			v.Append(types.IntValue(int64(i)))
		}
	}
	if v.Len() != 200 || v.NullCount() != 29 {
		t.Fatalf("len %d nulls %d", v.Len(), v.NullCount())
	}
	s := v.Slice(65, 140)
	for i := 0; i < s.Len(); i++ {
		if got, want := s.Get(i), v.Get(65+i); got != want {
			t.Fatalf("slice row %d: %v != %v", i, got, want)
		}
	}
	if v.Slice(0, 3).Valid != nil {
		t.Fatal("a slice without NULLs needs no validity bitmap")
	}
}

func TestDictEncode(t *testing.T) {
	v := NewVector(types.String, 0)
	for _, s := range []string{"a", "b", "a", "", "b"} {
		v.Append(types.StringValue(s))
	}
	v.Append(types.NullValue)
	d := v.DictEncode()
	if len(d.Dict) != 3 || !d.IsDict() {
		t.Fatalf("dictionary %v", d.Dict)
	}
	for i := 0; i < v.Len(); i++ {
		if d.Get(i) != v.Get(i) {
			t.Fatalf("row %d differs", i)
		}
	}
}

func build(layout Layout, dict bool, group int) *Table {
	cols := []ColumnDef{{Name: "n", Type: types.Int64}, {Name: "s", Type: types.String}, {Name: "f", Type: types.Float64}}
	vecs := []*Vector{NewVector(types.Int64, 0), NewVector(types.String, 0), NewVector(types.Float64, 0)}
	for i := 0; i < 1000; i++ {
		vecs[0].Append(types.IntValue(int64(i % 100)))
		if i%10 == 0 {
			vecs[1].Append(types.NullValue)
		} else {
			vecs[1].Append(types.StringValue(string(rune('a' + i%26))))
		}
		vecs[2].Append(types.FloatValue(float64(i) / 4))
	}
	return Build("t", &Data{Columns: cols, Vectors: vecs, Rows: 1000}, BuildOptions{Layout: layout, Dictionary: dict, GroupSize: group})
}

func TestLayoutsAgree(t *testing.T) {
	ref := build(ColumnLayout, false, 0)
	for _, tb := range []*Table{build(RowLayout, false, 0), build(ColumnLayout, true, 33), build(RowLayout, false, 7)} {
		if tb.Rows != 1000 {
			t.Fatalf("rows %d", tb.Rows)
		}
		for c := range ref.Columns {
			var a, b []types.Value
			_ = ref.ScanColumn(c, func(_ int, v types.Value) { a = append(a, v) })
			_ = tb.ScanColumn(c, func(_ int, v types.Value) { b = append(b, v) })
			for i := range a {
				if a[i] != b[i] {
					t.Fatalf("column %d row %d: %v != %v", c, i, a[i], b[i])
				}
			}
		}
		for id := 0; id < 1000; id += 37 {
			g := tb.Groups[tb.GroupOf(id)]
			if id < g.Start || id >= g.Start+g.Rows {
				t.Fatalf("GroupOf(%d) = group starting at %d", id, g.Start)
			}
		}
	}
}

func TestStats(t *testing.T) {
	tb := build(ColumnLayout, false, 128)
	st, err := tb.ColumnStats(1)
	if err != nil {
		t.Fatal(err)
	}
	if st.NullCount != 100 || st.Distinct != 26 || st.Min.S != "a" || st.Max.S != "z" {
		t.Fatalf("stats %+v", st)
	}
	st, _ = tb.ColumnStats(0)
	if st.Distinct != 100 || st.Min.I != 0 || st.Max.I != 99 {
		t.Fatalf("stats %+v", st)
	}
	g := tb.Groups[1].Stats[0]
	if !g.HasRange || g.Min.I != 0 || g.Max.I != 99 {
		t.Fatalf("group stats %+v", g)
	}
}

func TestDistinctCounter(t *testing.T) {
	for _, n := range []int{10, 1000, 200_000, 1_000_000} {
		d := newDistinctCounter()
		for rep := 0; rep < 2; rep++ {
			for i := 0; i < n; i++ {
				d.add(mix64(uint64(i)))
			}
		}
		got := d.count()
		if n <= exactDistinctLimit && got != n {
			t.Fatalf("exact count %d, want %d", got, n)
		}
		if diff := float64(got-n) / float64(n); diff > 0.05 || diff < -0.05 {
			t.Fatalf("estimate %d for %d distinct values", got, n)
		}
	}
}
