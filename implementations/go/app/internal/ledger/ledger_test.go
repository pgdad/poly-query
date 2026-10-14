package ledger

import (
	"context"
	"errors"
	"math/big"
	"testing"

	"polyquery"
	"polyquery/app/internal/bank"
)

func TestShare(t *testing.T) {
	cases := []struct{ part, total, want int64 }{
		{39701, 40001, 993}, {300, 40001, 7}, {200, 300, 667}, {100, 300, 333},
		{1, 8, 125}, {1, 16, 63}, // 6.25 → 6.3 (half away from zero)
		{5, 5, 1000}, {0, 7, 0},
	}
	for _, c := range cases {
		if got := Share(big.NewInt(c.part), big.NewInt(c.total)); got.Int64() != c.want {
			t.Errorf("Share(%d, %d) = %s, want %d", c.part, c.total, got, c.want)
		}
	}
}

func TestInitOpenImport(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir() + "/a/b"
	var se *StateError
	if _, err := Open(dir, Settings{}); !errors.As(err, &se) {
		t.Fatalf("open before init: %v", err)
	}
	if err := Init(dir, Settings{Threads: 1}); err != nil {
		t.Fatal(err)
	}
	if err := Init(dir, Settings{}); !errors.As(err, &se) {
		t.Fatalf("second init: %v", err)
	}
	l, err := Open(dir, Settings{Threads: 1, MemoryMB: 64})
	if err != nil {
		t.Fatal(err)
	}
	day, _ := polyquery.DateOf(2026, 3, 2)
	tx := bank.Transaction{Date: day, Description: "x", Merchant: "X", Amount: -450}
	res, err := l.Import(ctx, "a", "f.csv", []bank.Transaction{tx, tx})
	if err != nil || res != (ImportResult{Batch: 1, Imported: 2}) {
		t.Fatalf("import = %+v, %v", res, err)
	}
	l.Close()

	l, err = Open(dir, Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	res, err = l.Import(ctx, "a", "g.csv", []bank.Transaction{tx, tx, tx})
	if err != nil || res != (ImportResult{Batch: 2, Imported: 1, Duplicates: 2}) {
		t.Fatalf("second import = %+v, %v", res, err)
	}
	got, err := l.Query(ctx, "SELECT id, batch FROM transactions ORDER BY id")
	if err != nil || len(got.Rows) != 3 || got.Rows[2][0] != int64(3) || got.Rows[2][1] != int64(2) {
		t.Fatalf("transactions = %v, %v", got, err)
	}
	if err := l.SetCategory(ctx, 4, "x"); !errors.As(err, &se) {
		t.Errorf("unknown id: %v", err)
	}
}
