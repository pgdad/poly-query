package engine

import (
	"context"
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/storage"
)

func query(t *testing.T, e *Engine, sql string) string {
	t.Helper()
	r, err := e.Query(context.Background(), sql, QueryOptions{MaxRows: -1})
	if err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return render(r)
}

func TestSaveOpenWithIndexes(t *testing.T) {
	e := newEngine(t)
	query(t, e, "CREATE INDEX p_age ON people (age)")
	query(t, e, "CREATE INDEX p_name ON people (name) USING HASH")
	if _, err := e.Save(SaveRequest{Table: "people", Path: "p.pqcf", Encoding: "rle", RowGroupSize: 2}); err != nil {
		t.Fatal(err)
	}
	// The index names are still taken by the source table.
	if _, err := e.Open(OpenRequest{Table: "copy", Path: "p.pqcf"}); !errs.Is(err, errs.AlreadyExists) {
		t.Fatalf("open with taken index names: %v", err)
	}
	if e.Catalog().Exists("copy") {
		t.Fatal("failed open created a table")
	}
	for _, layout := range []storage.Layout{storage.RowLayout, storage.ColumnLayout} {
		if _, err := e.Open(OpenRequest{Table: "people", Path: "p.pqcf", Replace: true, Mmap: true, Layout: layout}); err != nil {
			t.Fatal(err)
		}
		entry, _ := e.Catalog().Snapshot().Entry("people")
		if len(entry.Indexes) != 2 || entry.Indexes[0].Name != "p_age" || entry.Table.Layout != layout {
			t.Fatalf("indexes after open: %v", entry.Indexes)
		}
		if got := query(t, e, "SELECT name FROM people WHERE name = 'Bob' OR age > 40 ORDER BY id"); got != "name:STRING|Bob|dave" {
			t.Fatalf("query after open: %s", got)
		}
	}
	_, stats, err := e.Stats("people")
	if err != nil || stats[2].NullCount != 1 || stats[2].Min.I != 28 || stats[2].Max.I != 52 || stats[2].Distinct != 3 {
		t.Fatalf("stats %+v %v", stats, err)
	}
}

func TestStorageErrors(t *testing.T) {
	e := newEngine(t)
	cases := []struct {
		err  error
		code errs.Code
	}{
		{func() error { _, err := e.Save(SaveRequest{Table: "nope", Path: "x.pqcf"}); return err }(), errs.NotFound},
		{func() error { _, err := e.Save(SaveRequest{Table: "people", Path: "../x.pqcf"}); return err }(), errs.AccessDenied},
		{func() error { _, err := e.Save(SaveRequest{Table: "people", Path: "no_dir/x.pqcf"}); return err }(), errs.IOError},
		{func() error { _, err := e.Open(OpenRequest{Table: "x", Path: "missing.pqcf"}); return err }(), errs.NotFound},
		{func() error { _, err := e.Open(OpenRequest{Table: "people", Path: "missing.pqcf"}); return err }(), errs.AlreadyExists},
		{func() error { _, _, err := e.Stats("nope"); return err }(), errs.NotFound},
	}
	for i, c := range cases {
		if !errs.Is(c.err, c.code) {
			t.Errorf("case %d: got %v, want %s", i, c.err, c.code)
		}
	}
}
