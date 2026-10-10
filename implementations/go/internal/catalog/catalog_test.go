package catalog

import (
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/index"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

func table(name string) *storage.Table {
	v := storage.NewVector(types.Int64, 1)
	v.Append(types.IntValue(1))
	return storage.Build(name, &storage.Data{Columns: []storage.ColumnDef{{Name: "a", Type: types.Int64}}, Vectors: []*storage.Vector{v}, Rows: 1}, storage.BuildOptions{})
}

func TestIndexLifecycle(t *testing.T) {
	c := New()
	if err := c.Put(table("T"), nil, false); err != nil {
		t.Fatal(err)
	}
	snap := c.Snapshot()
	def := index.Def{Name: "Ix", Column: "A", Kind: index.Hash}
	if err := c.CreateIndex(def, "t", false); err != nil {
		t.Fatal(err)
	}
	if err := c.CreateIndex(def, "t", false); !errs.Is(err, errs.AlreadyExists) {
		t.Fatalf("duplicate index: %v", err)
	}
	if err := c.CreateIndex(def, "t", true); err != nil {
		t.Fatalf("IF NOT EXISTS: %v", err)
	}
	if err := c.CreateIndex(index.Def{Name: "x", Column: "zz"}, "t", false); !errs.Is(err, errs.SemanticError) {
		t.Fatalf("unknown column: %v", err)
	}
	if len(snap.IndexesOf(snap.List()[0])) != 0 {
		t.Fatal("an old snapshot must not see later indexes")
	}
	cur := c.Snapshot()
	tb, _ := cur.Get("t")
	if ixs := cur.IndexesOf(tb); len(ixs) != 1 || ixs[0].Name != "Ix" {
		t.Fatalf("indexes %v", ixs)
	}
	// Replacing the table drops its indexes, so the name is free again.
	if err := c.Put(table("t"), nil, true); err != nil {
		t.Fatal(err)
	}
	if _, ok := c.Snapshot().Index("ix"); ok {
		t.Fatal("index survived table replacement")
	}
	if err := c.DropIndex("ix", false); !errs.Is(err, errs.NotFound) {
		t.Fatalf("drop: %v", err)
	}
	if err := c.DropIndex("ix", true); err != nil {
		t.Fatal(err)
	}
}

func TestPutWithIndexNameConflict(t *testing.T) {
	c := New()
	a := table("a")
	ix, _ := index.Build(index.Def{Name: "shared", Column: "a", Kind: index.BTree}, a)
	if err := c.Put(a, []*index.Index{ix}, false); err != nil {
		t.Fatal(err)
	}
	b := table("b")
	ix2, _ := index.Build(index.Def{Name: "SHARED", Column: "a", Kind: index.BTree}, b)
	if err := c.Put(b, []*index.Index{ix2}, false); !errs.Is(err, errs.AlreadyExists) {
		t.Fatalf("conflicting index name: %v", err)
	}
	if c.Exists("b") {
		t.Fatal("failed put changed the catalog")
	}
	if err := c.Drop("a"); err != nil {
		t.Fatal(err)
	}
	if err := c.Put(b, []*index.Index{ix2}, false); err != nil {
		t.Fatalf("index name should be free after drop: %v", err)
	}
}
