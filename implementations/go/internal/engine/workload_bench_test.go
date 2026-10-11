package engine

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"polyquery/internal/ingest"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// BenchmarkWorkload runs the queries of benchmarks/workloads/analytics.json
// with the default query options over the generated datasets in
// POLYQUERY_BENCH_DATA (skipped without it). Profile one query with e.g.
//
//	POLYQUERY_BENCH_DATA=$PWD/../../datasets/generated/1m go test ./internal/engine \
//	    -run - -bench 'Workload/q09' -cpuprofile cpu.out
func BenchmarkWorkload(b *testing.B) {
	dir := os.Getenv("POLYQUERY_BENCH_DATA")
	if dir == "" {
		b.Skip("POLYQUERY_BENCH_DATA not set")
	}
	raw, err := os.ReadFile("../../../../benchmarks/workloads/analytics.json")
	if err != nil {
		b.Skip(err)
	}
	var wl struct {
		Tables  map[string]string
		Indexes []struct{ SQL string }
		Queries []struct{ Name, SQL, Result string }
	}
	if err := json.Unmarshal(raw, &wl); err != nil {
		b.Fatal(err)
	}
	cfg := DefaultConfig()
	cfg.DataDir = dir
	e := New(cfg)
	for table, file := range wl.Tables {
		raw, err := os.ReadFile(filepath.Join(dir, file+".schema.json"))
		if err != nil {
			b.Fatal(err)
		}
		var cols []struct{ Name, Type string }
		if err := json.Unmarshal(raw, &cols); err != nil {
			b.Fatal(err)
		}
		opts := ingest.DefaultOptions(ingest.CSV)
		for _, c := range cols {
			t, err := types.ParseTypeName(c.Type)
			if err != nil {
				b.Fatal(err)
			}
			opts.Schema = append(opts.Schema, storage.ColumnDef{Name: c.Name, Type: t})
		}
		if _, err := e.Load(LoadRequest{Table: table, Path: file + ".csv", Options: opts}); err != nil {
			b.Fatal(err)
		}
	}
	for _, ix := range wl.Indexes {
		if _, err := e.Query(context.Background(), ix.SQL, QueryOptions{MaxRows: -1}); err != nil {
			b.Fatal(err)
		}
	}
	for _, q := range wl.Queries {
		b.Run(q.Name, func(b *testing.B) {
			opts := QueryOptions{MaxRows: -1, CountOnly: q.Result == "count"}
			for b.Loop() {
				if _, err := e.Query(context.Background(), q.SQL, opts); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
