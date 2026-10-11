package protocol

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"polyquery/internal/engine"
)

// BenchmarkWorkload runs the queries of benchmarks/analytics.json through
// the protocol handler (default options, full results, i.e. including JSON
// serialization). Set POLYQUERY_BENCH_DATA to a directory produced by
// `pqgen.py generate --scale 1m`; without it the benchmark is skipped.
// POLYQUERY_BENCH_OPTIONS adds query options (a JSON object, e.g.
// {"threads":1}). Profile one query with e.g.
//
//	POLYQUERY_BENCH_DATA=/tmp/pqdata/1m GOEXPERIMENT=simd go test ./internal/protocol \
//	    -run - -bench 'Workload/q10_' -cpuprofile cpu.out

type workload struct {
	Tables  []string
	Queries []struct{ Name, SQL string }
}

var (
	workloadOnce    sync.Once
	workloadHandler *Handler
	workloadSpec    workload
	workloadErr     error
)

func loadWorkload(b *testing.B) (*Handler, workload) {
	dir := os.Getenv("POLYQUERY_BENCH_DATA")
	if dir == "" {
		b.Skip("POLYQUERY_BENCH_DATA not set")
	}
	workloadOnce.Do(func() {
		raw, err := os.ReadFile(filepath.Join("..", "..", "benchmarks", "analytics.json"))
		if err != nil {
			workloadErr = err
			return
		}
		if workloadErr = json.Unmarshal(raw, &workloadSpec); workloadErr != nil {
			return
		}
		cfg := engine.DefaultConfig()
		cfg.DataDir = dir
		h := NewHandler(engine.New(cfg))
		for _, t := range workloadSpec.Tables {
			schema, err := os.ReadFile(filepath.Join(dir, t+".schema.json"))
			if err != nil {
				workloadErr = err
				return
			}
			req, _ := json.Marshal(map[string]any{"op": "load", "table": t, "path": t + ".csv",
				"format": "csv", "schema": json.RawMessage(schema)})
			if resp := h.HandleLine(req); !bytes.Contains(resp, []byte(`"ok":true`)) {
				workloadErr = &loadError{string(resp)}
				return
			}
		}
		workloadHandler = h
	})
	if workloadErr != nil {
		b.Fatal(workloadErr)
	}
	return workloadHandler, workloadSpec
}

type loadError struct{ resp string }

func (e *loadError) Error() string { return "load failed: " + e.resp }

func BenchmarkWorkload(b *testing.B) {
	h, w := loadWorkload(b)
	opts := json.RawMessage(`{}`)
	if o := os.Getenv("POLYQUERY_BENCH_OPTIONS"); o != "" {
		opts = json.RawMessage(o)
	}
	for _, q := range w.Queries {
		b.Run(q.Name, func(b *testing.B) {
			req, _ := json.Marshal(map[string]any{"op": "query", "sql": q.SQL, "options": opts})
			for b.Loop() {
				if resp := h.HandleLine(req); !bytes.Contains(resp, []byte(`"ok":true`)) {
					b.Fatal(string(resp))
				}
			}
		})
	}
}
