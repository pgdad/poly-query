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
	"runtime"
	"strings"
	"time"

	"polyquery/internal/analyzer"
	"polyquery/internal/catalog"
	"polyquery/internal/errs"
	"polyquery/internal/exec"
	"polyquery/internal/index"
	"polyquery/internal/ingest"
	"polyquery/internal/native"
	"polyquery/internal/optimizer"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/pqcf"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/parser"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Version information.
const (
	Name            = "polyquery-go"
	Version         = "0.3.0"
	ProtocolVersion = 1
	SpecVersion     = "1.1.0-cr1"
)

// Capabilities lists the capability strings this engine implements.
// native.kernels is claimed when the build can load libpqkernels (cgo).
var Capabilities = append([]string{
	"phase1", "ingest.csv", "ingest.json", "ingest.jsonl", "sql.basic", "test.functions",
	"phase2", "sql.groupby", "sql.join", "sql.functions", "sql.subquery", "sql.cte", "sql.correlated_subquery",
	"phase3", "storage.pqcf", "storage.mmap", "index.hash", "index.btree",
	"phase4", "http.streaming",
	"phase5", "exec.row", "exec.vectorized", "exec.parallel", "join.hash", "join.merge", "join.nested_loop",
	"change.union_all",
}, nativeCapabilities()...)

func nativeCapabilities() []string {
	if native.Supported() {
		return []string{"native.kernels"}
	}
	return nil
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
	// MorselRows is the number of rows per parallel work unit (0: the
	// executor default; small values are useful to test parallelism on
	// small tables).
	MorselRows int
	// Native is the loaded native kernel library (nil: none); queries use
	// it when they run with the option native: true.
	Native *native.Lib
	Logger *slog.Logger
}

// DefaultConfig returns the default configuration.
func DefaultConfig() Config {
	return Config{
		DataDir:          ".",
		MaxQueryMemoryMB: 4096,
		MaxIngestBytes:   4 << 30,
		MaxTableRows:     500_000_000,
		MaxJoinRows:      100_000_000,
		Threads:          min(4, runtime.NumCPU()),
		Logger:           slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

// Engine is a PolyQuery database instance.
type Engine struct {
	cfg     Config
	catalog *catalog.Catalog
}

// New creates an engine with an empty catalog.
func New(cfg Config) *Engine {
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Engine{cfg: cfg, catalog: catalog.New()}
}

// Config returns the engine configuration.
func (e *Engine) Config() Config { return e.cfg }

// Catalog returns the engine catalog.
func (e *Engine) Catalog() *catalog.Catalog { return e.catalog }

// ---------------------------------------------------------------- loading

// LoadRequest describes a load operation.
type LoadRequest struct {
	Table   string
	Path    string // relative to the data directory; empty if Data is used
	Data    *string
	Replace bool
	Options ingest.Options
	Build   storage.BuildOptions
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
	d, err := ingest.Load(data, opts)
	if err != nil {
		return nil, err
	}
	t := storage.Build(req.Table, d, req.Build)
	if err := e.catalog.Put(t, nil, req.Replace); err != nil {
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
	NoIndexes  bool   // never use indexes (use_indexes: false)
	Join       string // forced join algorithm ("", "auto", "hash", "merge", "nested_loop")
	Mode       string // execution model ("", "auto", "row", "vectorized")
	Threads    int    // worker threads (0: the engine default)
	QueryID    string // client-assigned query id (HTTP cancellation)
	Native     bool   // use the native kernels if loaded (native: true)
}

// Result is a query result.
type Result struct {
	Columns  []plan.Column
	Rows     []types.Row
	RowCount int64
}

// Query parses, analyzes, plans and executes a SQL statement and collects
// its whole result.
func (e *Engine) Query(ctx context.Context, sql string, opts QueryOptions) (*Result, error) {
	cur, err := e.Start(ctx, sql, opts)
	if err != nil {
		return nil, err
	}
	defer cur.Close()
	res := &Result{Columns: cur.Columns}
	if opts.CountOnly && cur.op != nil {
		// Vectorized plans are counted batch by batch.
		n, ok, err := exec.CountRows(cur.op, cur.maxRows)
		if err != nil {
			return nil, err
		}
		if ok {
			if cur.maxRows >= 0 && n > cur.maxRows {
				return nil, errs.New(errs.ResourceLimit, "result exceeds max_rows (%d)", cur.maxRows)
			}
			if err := cur.ctx.Err(); err != nil {
				return nil, exec.ContextError(err)
			}
			res.RowCount = n
			return res, nil
		}
	}
	for {
		row, err := cur.Next()
		if err != nil {
			return nil, err
		}
		if row == nil {
			break
		}
		if !opts.CountOnly {
			cp := append(types.Row(nil), row...)
			if err := cur.ec.Mem.Reserve(exec.RowSize(cp)); err != nil {
				return nil, err
			}
			res.Rows = append(res.Rows, cp)
		}
	}
	res.RowCount = cur.RowCount()
	return res, nil
}

// Cursor iterates over the result of a statement. The catalog snapshot the
// statement reads is fixed when the cursor is created.
type Cursor struct {
	// Columns describes the result columns.
	Columns []plan.Column

	ctx     context.Context
	cancel  context.CancelFunc
	ec      *exec.Context
	op      exec.Operator
	rows    []types.Row // precomputed result (EXPLAIN, DDL statements)
	maxRows int64
	count   int64
	done    bool
}

// Start parses, analyzes and plans a SQL statement and returns a cursor
// over its result. Statements without a row result (CREATE/DROP INDEX) are
// executed immediately. The caller must Close the cursor.
func (e *Engine) Start(ctx context.Context, sql string, opts QueryOptions) (*Cursor, error) {
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
		return e.open(ctx, p, opts)
	case *ast.Explain:
		p, err := e.plan(s.Query, opts)
		if err != nil {
			return nil, err
		}
		text := types.StringValue(physical.ExplainText(p))
		return staticCursor([]plan.Column{{Name: "plan", Type: types.String}}, []types.Row{{text}}), nil
	case *ast.CreateIndex:
		kind := index.BTree
		if s.Using == "HASH" {
			kind = index.Hash
		}
		def := index.Def{Name: s.Name, Column: s.Column, Kind: kind}
		if err := e.catalog.CreateIndex(def, s.Table, s.IfNotExists); err != nil {
			return nil, err
		}
		return staticCursor([]plan.Column{}, nil), nil
	case *ast.DropIndex:
		if err := e.catalog.DropIndex(s.Name, s.IfExists); err != nil {
			return nil, err
		}
		return staticCursor([]plan.Column{}, nil), nil
	}
	return nil, unsupportedStatement(stmt)
}

func staticCursor(cols []plan.Column, rows []types.Row) *Cursor {
	return &Cursor{Columns: cols, rows: rows, maxRows: -1, ctx: context.Background(), ec: &exec.Context{}}
}

// open builds the operator tree of a physical plan.
func (e *Engine) open(ctx context.Context, p *physical.Plan, opts QueryOptions) (*Cursor, error) {
	var cancel context.CancelFunc
	if opts.Timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, opts.Timeout)
	} else {
		// Closing the cursor stops parallel workers of unfinished queries.
		ctx, cancel = context.WithCancel(ctx)
	}
	threads := opts.Threads
	if threads <= 0 {
		threads = e.cfg.Threads
	}
	ec := &exec.Context{
		Ctx:         ctx,
		Mem:         &exec.MemTracker{Limit: e.cfg.MaxQueryMemoryMB << 20},
		MaxJoinRows: e.cfg.MaxJoinRows,
		Plan:        p,
		Vectorized:  opts.Mode != "row" && !callsSleep(p),
		Threads:     threads,
		MorselRows:  e.cfg.MorselRows,
	}
	if opts.Native && !callsSleep(p) {
		// PQ_SLEEP's evaluation count is observable; native filters
		// evaluate conjuncts in a different order, so such (test-only)
		// queries keep the engine's own code paths.
		ec.Native = e.cfg.Native
	}
	op, err := exec.BuildRoot(ec, p.Root)
	if err != nil {
		cancel()
		return nil, err
	}
	return &Cursor{Columns: p.Root.Schema(), ctx: ctx, cancel: cancel, ec: ec, op: op, maxRows: opts.MaxRows}, nil
}

// callsSleep reports whether a plan evaluates PQ_SLEEP. Such (test-only)
// queries always run row-at-a-time: PQ_SLEEP's per-row evaluation count is
// observable through timing, and batch execution would evaluate it for rows
// a LIMIT never needs.
func callsSleep(p *physical.Plan) bool {
	found := false
	var visit func(n physical.Node)
	visit = func(n physical.Node) {
		for _, e := range physical.Exprs(n) {
			plan.Walk(e, func(x plan.Expr) {
				if f, ok := x.(*plan.Func); ok && f.Name == "PQ_SLEEP" {
					found = true
				}
			})
		}
		for _, c := range n.Children() {
			visit(c)
		}
	}
	visit(p.Root)
	for _, sub := range p.Subplans {
		visit(sub)
	}
	return found
}

// Next returns the next result row, or nil at the end. The row is only
// valid until the next call. Exceeding max_rows is RESOURCE_LIMIT.
func (c *Cursor) Next() (types.Row, error) {
	if c.done {
		return nil, nil
	}
	var row types.Row
	if c.op != nil {
		var err error
		if row, err = c.op.Next(); err != nil {
			c.done = true
			return nil, err
		}
	} else if c.count < int64(len(c.rows)) {
		row = c.rows[c.count]
	}
	if row == nil {
		c.done = true
		if err := c.ctx.Err(); err != nil {
			return nil, exec.ContextError(err)
		}
		return nil, nil
	}
	c.count++
	if c.maxRows >= 0 && c.count > c.maxRows {
		c.done = true
		return nil, errs.New(errs.ResourceLimit, "result exceeds max_rows (%d)", c.maxRows)
	}
	return row, nil
}

// RowCount returns the number of rows returned so far.
func (c *Cursor) RowCount() int64 { return c.count }

// Close releases the cursor's resources.
func (c *Cursor) Close() {
	if c.cancel != nil {
		c.cancel()
	}
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
	case *ast.CreateIndex, *ast.DropIndex:
		return errs.New(errs.InvalidRequest, "only queries can be explained")
	}
	return errs.New(errs.Unsupported, "statement %T is not supported", stmt)
}

// plan runs semantic analysis, logical optimization and physical planning.
func (e *Engine) plan(q *ast.Query, opts QueryOptions) (*physical.Plan, error) {
	snap := e.catalog.Snapshot()
	logical, err := analyzer.AnalyzeQuery(q, snap, analyzer.Config{
		TestFunctions: e.cfg.TestFunctions,
		EvalConst:     exec.EvalConstant,
	})
	if err != nil {
		return nil, err
	}
	if !opts.NoOptimize {
		logical = optimizer.Optimize(logical, optimizer.Options{EvalConst: exec.EvalConstant})
	}
	return physical.Build(logical, physical.Options{
		Join:       opts.Join,
		UseIndexes: !opts.NoIndexes,
		Indexes:    snap.IndexesOf,
		EvalConst:  exec.EvalConstant,
	})
}

// ---------------------------------------------------------------- storage

// OpenRequest describes an open operation (a PQCF file becomes a table).
type OpenRequest struct {
	Table      string
	Path       string
	Replace    bool
	Mmap       bool
	Layout     storage.Layout
	Dictionary bool
}

// Open reads a PQCF file, rebuilds the indexes listed in it and publishes
// the table atomically.
func (e *Engine) Open(req OpenRequest) (*storage.Table, error) {
	if !req.Replace && e.catalog.Exists(req.Table) {
		return nil, errs.New(errs.AlreadyExists, "table %q already exists", req.Table)
	}
	full, err := e.ResolvePath(req.Path)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, fileError(req.Path, err)
	}
	defer f.Close()
	if st, err := f.Stat(); err == nil && st.IsDir() {
		return nil, errs.New(errs.IOError, "%q is a directory", req.Path)
	}
	start := time.Now()
	t, defs, err := pqcf.Read(f, req.Table, pqcf.ReadOptions{
		Mmap: req.Mmap, Layout: req.Layout, Dictionary: req.Dictionary, MaxRows: e.cfg.MaxTableRows,
	})
	if err != nil {
		return nil, err
	}
	indexes := make([]*index.Index, 0, len(defs))
	for _, def := range defs {
		ix, err := index.Build(def, t)
		if err != nil {
			return nil, err
		}
		indexes = append(indexes, ix)
	}
	if err := e.catalog.Put(t, indexes, req.Replace); err != nil {
		return nil, err
	}
	e.cfg.Logger.Info("table opened", "table", t.Name, "rows", t.Rows, "duration_ms", time.Since(start).Milliseconds())
	return t, nil
}

// SaveRequest describes a save operation.
type SaveRequest struct {
	Table        string
	Path         string
	RowGroupSize int
	Encoding     string
}

// Save writes a table (and its index definitions) as a PQCF file,
// atomically replacing any existing file. It returns the file size.
func (e *Engine) Save(req SaveRequest) (int64, error) {
	entry, ok := e.catalog.Snapshot().Entry(req.Table)
	if !ok {
		return 0, errs.New(errs.NotFound, "table %q not found", req.Table)
	}
	full, err := e.ResolvePath(req.Path)
	if err != nil {
		return 0, err
	}
	defs := make([]index.Def, len(entry.Indexes))
	for i, ix := range entry.Indexes {
		defs[i] = ix.Def
	}
	return pqcf.Write(full, entry.Table, defs, pqcf.WriteOptions{
		RowGroupSize: req.RowGroupSize, Encoding: req.Encoding, Writer: Name + " " + Version,
	})
}

// Stats returns a table and the statistics of all its columns.
func (e *Engine) Stats(name string) (*storage.Table, []storage.ColumnStats, error) {
	t, ok := e.catalog.Get(name)
	if !ok {
		return nil, nil, errs.New(errs.NotFound, "table %q not found", name)
	}
	out := make([]storage.ColumnStats, len(t.Columns))
	for i := range t.Columns {
		st, err := t.ColumnStats(i)
		if err != nil {
			return nil, nil, err
		}
		out[i] = st
	}
	return t, out, nil
}
