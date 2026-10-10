package engine

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"polyquery/internal/ingest"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Benchmarks over generated datasets. Set POLYQUERY_BENCH_DATA to a
// directory produced by `pqgen.py generate --scale …` (e.g. /tmp/pqdata/1m);
// without it the benchmarks are skipped. Profile with e.g.
//
//	POLYQUERY_BENCH_DATA=/tmp/pqdata/1m go test ./internal/engine -run - \
//	    -bench 'Bench/agg_lowcard/vec1' -cpuprofile cpu.out

var (
	benchOnce   sync.Once
	benchEngine *Engine
	benchErr    error
)

func loadBenchEngine(b *testing.B) *Engine {
	dir := os.Getenv("POLYQUERY_BENCH_DATA")
	if dir == "" {
		b.Skip("POLYQUERY_BENCH_DATA not set")
	}
	benchOnce.Do(func() {
		cfg := DefaultConfig()
		cfg.DataDir = dir
		e := New(cfg)
		for table, file := range map[string]string{"tx": "transactions", "cust": "customers", "orders": "orders",
			"items": "order_items", "sk": "sort_keys", "sensors": "sensor_readings"} {
			raw, err := os.ReadFile(filepath.Join(dir, file+".schema.json"))
			if err != nil {
				benchErr = err
				return
			}
			var cols []struct{ Name, Type string }
			if err := json.Unmarshal(raw, &cols); err != nil {
				benchErr = err
				return
			}
			opts := ingest.DefaultOptions(ingest.CSV)
			for _, c := range cols {
				t, err := types.ParseTypeName(c.Type)
				if err != nil {
					benchErr = err
					return
				}
				opts.Schema = append(opts.Schema, storage.ColumnDef{Name: c.Name, Type: t})
			}
			if _, err := e.Load(LoadRequest{Table: table, Path: file + ".csv", Options: opts}); err != nil {
				benchErr = err
				return
			}
		}
		benchEngine = e
	})
	if benchErr != nil {
		b.Fatal(benchErr)
	}
	return benchEngine
}

var benchQueries = []struct{ name, sql string }{
	{"filter_count", "SELECT COUNT(*) FROM tx WHERE amount > 500 AND status = 'approved'"},
	{"agg_lowcard", "SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(ts), MAX(merchant_id) FROM tx GROUP BY category"},
	{"agg_highcard", "SELECT customer_id, COUNT(*), SUM(amount) FROM tx GROUP BY customer_id"},
	{"agg_expr", "SELECT bucket % 10 AS b, COUNT(*), SUM(fee * 2), MAX(ts) FROM tx WHERE is_fraud = FALSE GROUP BY bucket % 10"},
	{"join_big", "SELECT o.status, SUM(i.quantity), COUNT(*) FROM items i JOIN orders o ON o.order_id = i.order_id GROUP BY o.status"},
	{"topn", "SELECT tx_id, amount FROM tx ORDER BY amount DESC, tx_id LIMIT 10"},
	{"sort_full", "SELECT id, str_key FROM sk ORDER BY str_key, id"},
	{"distinct", "SELECT DISTINCT merchant_id FROM tx"},
}

func BenchmarkQueries(b *testing.B) {
	e := loadBenchEngine(b)
	configs := []struct {
		name string
		opts QueryOptions
	}{
		{"row1", QueryOptions{Mode: "row", Threads: 1}},
		{"vec1", QueryOptions{Mode: "vectorized", Threads: 1}},
		{"vec8", QueryOptions{Mode: "vectorized", Threads: 8}},
	}
	for _, q := range benchQueries {
		for _, c := range configs {
			b.Run(q.name+"/"+c.name, func(b *testing.B) {
				opts := c.opts
				opts.MaxRows, opts.CountOnly = -1, true
				for b.Loop() {
					if _, err := e.Query(context.Background(), q.sql, opts); err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
