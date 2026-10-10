// Package engine ties the layers together: it owns the catalog and
// configuration and runs loads and queries (parse → analyze → plan →
// execute).
package engine

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"polyquery/internal/analyzer"
	"polyquery/internal/errs"
	"polyquery/internal/exec"
	"polyquery/internal/ingest"
	"polyquery/internal/optimizer"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/parser"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Version information.
const (
	Name            = "polyquery-go"
	Version         = "0.1.0"
	ProtocolVersion = 1
	SpecVersion     = "1.0.0"
)

// Capabilities lists the capability strings this engine implements.
var Capabilities = []string{
	"phase1", "ingest.csv", "ingest.json", "ingest.jsonl", "sql.basic", "test.functions",
	"phase2", "sql.groupby", "sql.join", "sql.functions", "sql.subquery", "sql.cte", "sql.correlated_subquery",
}

// Config holds engine-wide settings (CLI options).
type Config struct {
	DataDir          string
	TestFunctions    bool
	MaxQueryMemoryMB int64
	MaxIngestBytes   int64
	MaxTableRows     int64
	MaxJoinRows      int64
	Threads          int
	Logger           *slog.Logger
}

// DefaultConfig returns the default configuration.
func DefaultConfig() Config {
	return Config{
		DataDir:          ".",
		MaxQueryMemoryMB: 4096,
		MaxIngestBytes:   4 << 30,
		MaxTableRows:     500_000_000,
		MaxJoinRows:      100_000_000,
		Threads:          1,
		Logger:           slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

// Engine is a PolyQuery database instance.
type Engine struct {
	cfg     Config
	catalog *storage.Catalog
}

// New creates an engine with an empty catalog.
func New(cfg Config) *Engine {
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Engine{cfg: cfg, catalog: storage.NewCatalog()}
}

// Config returns the engine configuration.
func (e *Engine) Config() Config { return e.cfg }

// Catalog returns the engine catalog.
func (e *Engine) Catalog() *storage.Catalog { return e.catalog }

// ---------------------------------------------------------------- loading

// LoadRequest describes a load operation.
type LoadRequest struct {
	Table   string
	Path    string // relative to the data directory; empty if Data is used
	Data    *string
	Replace bool
	Options ingest.Options
}

// Load ingests data and publishes it atomically as a table.
func (e *Engine) Load(req LoadRequest) (*storage.Table, error) {
	if !req.Replace && e.catalog.Exists(req.Table) {
		return nil, errs.New(errs.AlreadyExists, "table %q already exists", req.Table)
	}
	var data []byte
	if req.Data != nil {
		if int64(len(*req.Data)) > e.cfg.MaxIngestBytes {
			return nil, errs.New(errs.ResourceLimit, "input exceeds the ingestion limit of %d bytes", e.cfg.MaxIngestBytes)
		}
		data = []byte(*req.Data)
	} else {
		var err error
		if data, err = e.readFile(req.Path); err != nil {
			return nil, err
		}
	}
	opts := req.Options
	opts.MaxRows = e.cfg.MaxTableRows
	start := time.Now()
	t, err := ingest.Load(req.Table, data, opts)
	if err != nil {
		return nil, err
	}
	if err := e.catalog.Put(t, req.Replace); err != nil {
		return nil, err
	}
	e.cfg.Logger.Info("table loaded", "table", t.Name, "rows", t.Rows, "duration_ms", time.Since(start).Milliseconds())
	return t, nil
}

// ResolvePath validates a request path (protocol.md §6) and joins it to the
// data directory.
func (e *Engine) ResolvePath(p string) (string, error) {
	if p == "" || strings.ContainsRune(p, 0) || filepath.IsAbs(p) || strings.HasPrefix(p, "/") || strings.HasPrefix(p, `\`) {
		return "", errs.New(errs.AccessDenied, "path %q is not permitted", p)
	}
	for _, part := range strings.FieldsFunc(p, func(r rune) bool { return r == '/' || r == '\\' }) {
		if part == ".." {
			return "", errs.New(errs.AccessDenied, "path %q is not permitted", p)
		}
	}
	return filepath.Join(e.cfg.DataDir, filepath.FromSlash(p)), nil
}

func (e *Engine) readFile(p string) ([]byte, error) {
	full, err := e.ResolvePath(p)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, fileError(p, err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, fileError(p, err)
	}
	if st.IsDir() {
		return nil, errs.New(errs.IOError, "%q is a directory", p)
	}
	if st.Size() > e.cfg.MaxIngestBytes {
		return nil, errs.New(errs.ResourceLimit, "file exceeds the ingestion limit of %d bytes", e.cfg.MaxIngestBytes)
	}
	data, err := io.ReadAll(io.LimitReader(f, e.cfg.MaxIngestBytes+1))
	if err != nil {
		return nil, fileError(p, err)
	}
	if int64(len(data)) > e.cfg.MaxIngestBytes {
		return nil, errs.New(errs.ResourceLimit, "file exceeds the ingestion limit of %d bytes", e.cfg.MaxIngestBytes)
	}
	return data, nil
}

func fileError(p string, err error) error {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return errs.New(errs.NotFound, "file %q not found", p)
	case errors.Is(err, fs.ErrPermission):
		return errs.New(errs.AccessDenied, "permission denied for %q", p)
	}
	return errs.New(errs.IOError, "cannot read %q: %v", p, err)
}

// ---------------------------------------------------------------- queries

// QueryOptions are per-query execution options.
type QueryOptions struct {
	MaxRows    int64 // < 0 = unlimited
	Timeout    time.Duration
	CountOnly  bool   // do not retain rows (result: "count")
	NoOptimize bool   // skip logical optimization (optimize: false)
	Join       string // forced join algorithm ("", "auto", "hash", "nested_loop")
}

// Result is a query result.
type Result struct {
	Columns  []plan.Column
	Rows     []types.Row
	RowCount int64
}

// Query parses, analyzes, plans and executes a SQL statement.
func (e *Engine) Query(ctx context.Context, sql string, opts QueryOptions) (*Result, error) {
	stmt, err := parser.Parse(sql)
	if err != nil {
		return nil, err
	}
	switch s := stmt.(type) {
	case *ast.Query:
		p, err := e.plan(s, opts)
		if err != nil {
			return nil, err
		}
		return e.execute(ctx, p, opts)
	case *ast.Explain:
		p, err := e.plan(s.Query, opts)
		if err != nil {
			return nil, err
		}
		text := types.StringValue(physical.ExplainText(p))
		return &Result{Columns: []plan.Column{{Name: "plan", Type: types.String}}, Rows: []types.Row{{text}}, RowCount: 1}, nil
	}
	return nil, unsupportedStatement(stmt)
}

// Explain plans a query and returns its EXPLAIN plan tree.
func (e *Engine) Explain(sql string, opts QueryOptions) (*physical.Object, error) {
	stmt, err := parser.Parse(sql)
	if err != nil {
		return nil, err
	}
	q, ok := stmt.(*ast.Query)
	if ex, isExplain := stmt.(*ast.Explain); isExplain {
		q, ok = ex.Query, true
	}
	if !ok {
		return nil, unsupportedStatement(stmt)
	}
	p, err := e.plan(q, opts)
	if err != nil {
		return nil, err
	}
	return physical.Explain(p), nil
}

func unsupportedStatement(stmt ast.Statement) error {
	switch stmt.(type) {
	case *ast.CreateIndex:
		return errs.New(errs.Unsupported, "CREATE INDEX is not supported (no index capability)")
	case *ast.DropIndex:
		return errs.New(errs.Unsupported, "DROP INDEX is not supported (no index capability)")
	}
	return errs.New(errs.Unsupported, "statement %T is not supported", stmt)
}

// plan runs semantic analysis, logical optimization and physical planning.
func (e *Engine) plan(q *ast.Query, opts QueryOptions) (*physical.Plan, error) {
	logical, err := analyzer.AnalyzeQuery(q, e.catalog, analyzer.Config{
		TestFunctions: e.cfg.TestFunctions,
		EvalConst:     exec.EvalConstant,
	})
	if err != nil {
		return nil, err
	}
	if !opts.NoOptimize {
		logical = optimizer.Optimize(logical)
	}
	return physical.Build(logical, physical.Options{Join: opts.Join})
}

// execute runs a physical plan and collects its result.
func (e *Engine) execute(ctx context.Context, p *physical.Plan, opts QueryOptions) (*Result, error) {
	if opts.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, opts.Timeout)
		defer cancel()
	}
	ec := &exec.Context{
		Ctx:         ctx,
		Mem:         &exec.MemTracker{Limit: e.cfg.MaxQueryMemoryMB << 20},
		MaxJoinRows: e.cfg.MaxJoinRows,
		Plan:        p,
	}
	op, err := exec.Build(ec, p.Root)
	if err != nil {
		return nil, err
	}
	res := &Result{Columns: p.Root.Schema()}
	for {
		row, err := op.Next()
		if err != nil {
			return nil, err
		}
		if row == nil {
			break
		}
		res.RowCount++
		if opts.MaxRows >= 0 && res.RowCount > opts.MaxRows {
			return nil, errs.New(errs.ResourceLimit, "result exceeds max_rows (%d)", opts.MaxRows)
		}
		if !opts.CountOnly {
			cp := append(types.Row(nil), row...)
			if err := ec.Mem.Reserve(exec.RowSize(cp)); err != nil {
				return nil, err
			}
			res.Rows = append(res.Rows, cp)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, exec.ContextError(err)
	}
	return res, nil
}
