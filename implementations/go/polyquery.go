package polyquery

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"polyquery/internal/engine"
	"polyquery/internal/ingest"
	"polyquery/internal/native"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Version is the engine version.
const Version = engine.Version

// Capabilities returns the capability strings the engine implements
// (the same list as `polyquery capabilities`).
func Capabilities() []string { return append([]string(nil), engine.Capabilities...) }

// Config configures an instance. The zero value of every field selects
// the default of the polyquery CLI option named in its comment.
type Config struct {
	// DataDir is the root directory for the paths of LoadFile, SaveTable
	// and OpenTable (--data-dir; default "."). It must exist. Paths are
	// checked as in protocol.md §6: they must be relative and must not
	// contain "..".
	DataDir string
	// MaxQueryMemoryMB is the per-query memory budget (--max-query-memory-mb;
	// default 4096).
	MaxQueryMemoryMB int64
	// Threads is the default number of worker threads per query
	// (--threads; default min(16, number of CPUs)).
	Threads int
	// MaxIngestBytes limits the size of loaded input (--max-ingest-bytes;
	// default 4 GiB).
	MaxIngestBytes int64
	// MaxTableRows limits the rows of one table (--max-table-rows; default
	// 500,000,000).
	MaxTableRows int64
	// MaxJoinRows limits the rows a join may produce (--max-join-rows;
	// default 100,000,000).
	MaxJoinRows int64
	// EnableTestFunctions enables PQ_SLEEP (--enable-test-functions).
	EnableTestFunctions bool
	// NativeKernels is the path of the native kernel library libpqkernels
	// (--native-kernels; default none). Queries with QueryOptions.Native
	// use it.
	NativeKernels string
	// Logger receives the engine's structured log records (default:
	// discarded).
	Logger *slog.Logger
}

// DB is an engine instance: a catalog of in-memory tables plus a
// configuration. A DB is safe for concurrent use by multiple goroutines.
// Several instances may exist in one process; they share nothing.
type DB struct {
	eng    *engine.Engine
	closed atomic.Bool
}

// New creates an instance with an empty catalog.
func New(cfg Config) (*DB, error) {
	ec := engine.DefaultConfig()
	if cfg.DataDir != "" {
		ec.DataDir = cfg.DataDir
	}
	st, err := os.Stat(ec.DataDir)
	switch {
	case err != nil:
		return nil, newError(CodeNotFound, "data directory %q: %v", ec.DataDir, err)
	case !st.IsDir():
		return nil, newError(CodeIOError, "data directory %q is not a directory", ec.DataDir)
	}
	limits := []struct {
		name string
		v    int64
		dst  *int64
	}{
		{"MaxQueryMemoryMB", cfg.MaxQueryMemoryMB, &ec.MaxQueryMemoryMB},
		{"MaxIngestBytes", cfg.MaxIngestBytes, &ec.MaxIngestBytes},
		{"MaxTableRows", cfg.MaxTableRows, &ec.MaxTableRows},
		{"MaxJoinRows", cfg.MaxJoinRows, &ec.MaxJoinRows},
	}
	for _, l := range limits {
		if l.v < 0 {
			return nil, newError(CodeInvalidArgument, "%s must not be negative", l.name)
		}
		if l.v > 0 {
			*l.dst = l.v
		}
	}
	if cfg.Threads < 0 {
		return nil, newError(CodeInvalidArgument, "Threads must not be negative")
	}
	if cfg.Threads > 0 {
		ec.Threads = cfg.Threads
	}
	ec.TestFunctions = cfg.EnableTestFunctions
	ec.Logger = cfg.Logger
	if ec.Logger == nil {
		ec.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if cfg.NativeKernels != "" {
		lib, err := native.Load(cfg.NativeKernels)
		if err != nil {
			return nil, newError(CodeIOError, "cannot load native kernels %q: %v", cfg.NativeKernels, err)
		}
		ec.Native = lib
	}
	return &DB{eng: engine.New(ec)}, nil
}

// Close drops every table and releases the instance's resources (memory
// mappings are released once no result refers to them). Operations on a
// closed instance fail with INVALID_REQUEST. Close is idempotent.
func (db *DB) Close() error {
	if db.closed.Swap(true) {
		return nil
	}
	db.eng.Catalog().Reset()
	return nil
}

func (db *DB) check() error {
	if db.closed.Load() {
		return newError(CodeInvalidRequest, "the instance is closed")
	}
	return nil
}

// ---------------------------------------------------------------- tables

// TableInfo describes a table.
type TableInfo struct {
	Name     string
	RowCount int64
	Columns  []Column
	// Indexes lists the table's indexes (filled by Schema only).
	Indexes []IndexInfo
}

// IndexInfo describes an index created with CREATE INDEX or restored by
// OpenTable.
type IndexInfo struct {
	Name   string
	Column string
	Kind   string // "HASH" or "BTREE"
}

func tableInfo(t *storage.Table) *TableInfo {
	return &TableInfo{Name: t.Name, RowCount: int64(t.Rows), Columns: fromColumnDefs(t.Columns)}
}

// Format is an input format of LoadFile and LoadText.
type Format string

// The input formats (spec/data-types/ingestion.md).
const (
	CSV   Format = "csv"
	JSON  Format = "json"
	JSONL Format = "jsonl"
)

// LoadOptions are the options of LoadFile and LoadText. A nil
// *LoadOptions selects the defaults.
type LoadOptions struct {
	// Format is the input format (default CSV).
	Format Format
	// Schema gives the columns explicitly; nil infers them.
	Schema []Column
	// NoHeader means the first CSV record is data, not a header
	// (requires Schema).
	NoHeader bool
	// Delimiter is the CSV field delimiter (default ',').
	Delimiter byte
	// Replace replaces an existing table of the same name.
	Replace bool
}

// LoadFile loads a file (a path relative to Config.DataDir) as a table.
func (db *DB) LoadFile(table, path string, opts *LoadOptions) (*TableInfo, error) {
	return db.load(engine.LoadRequest{Table: table, Path: path}, opts)
}

// LoadText loads in-memory text as a table.
func (db *DB) LoadText(table, data string, opts *LoadOptions) (*TableInfo, error) {
	return db.load(engine.LoadRequest{Table: table, Data: &data}, opts)
}

func (db *DB) load(req engine.LoadRequest, opts *LoadOptions) (info *TableInfo, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	if opts == nil {
		opts = &LoadOptions{}
	}
	if req.Table == "" {
		return nil, newError(CodeInvalidRequest, "table name must not be empty")
	}
	f := ingest.Format(opts.Format)
	if f == "" {
		f = ingest.CSV
	}
	if f != ingest.CSV && f != ingest.JSON && f != ingest.JSONL {
		return nil, newError(CodeInvalidRequest, "unknown format %q", opts.Format)
	}
	req.Options = ingest.DefaultOptions(f)
	req.Replace = opts.Replace
	if opts.Schema != nil {
		if req.Options.Schema, err = toColumnDefs(opts.Schema); err != nil {
			return nil, err
		}
	}
	req.Options.Header = !opts.NoHeader
	if d := opts.Delimiter; d != 0 {
		if d >= 0x80 || d == '"' || d == '\n' || d == '\r' {
			return nil, newError(CodeInvalidRequest, "delimiter must be a single ASCII character")
		}
		req.Options.Delimiter = d
	}
	if f == ingest.CSV && opts.NoHeader && opts.Schema == nil {
		return nil, newError(CodeInvalidRequest, "NoHeader requires an explicit schema")
	}
	t, err := db.eng.Load(req)
	if err != nil {
		return nil, wrapError(err)
	}
	return tableInfo(t), nil
}

// CreateOptions are the options of CreateTable and CreateTableAs.
type CreateOptions struct {
	// Replace replaces an existing table of the same name.
	Replace bool
	// Query holds the query options of CreateTableAs.
	Query QueryOptions
}

// CreateTable creates a table from in-memory rows. Each value must be nil
// (NULL) or of the Go type of its column (see the package
// documentation); DECIMAL columns also accept int64 and int, and
// Decimals of another scale that convert exactly; DATE and TIMESTAMP
// columns also accept time.Time.
func (db *DB) CreateTable(table string, columns []Column, rows [][]any, opts *CreateOptions) (info *TableInfo, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	if opts == nil {
		opts = &CreateOptions{}
	}
	defs, err := toColumnDefs(columns)
	if err != nil {
		return nil, err
	}
	data := make([]types.Row, len(rows))
	cells := make([]types.Value, len(rows)*len(defs))
	for r, row := range rows {
		if len(row) != len(defs) {
			return nil, newError(CodeInvalidArgument, "row %d has %d values, expected %d", r+1, len(row), len(defs))
		}
		out := cells[r*len(defs) : (r+1)*len(defs)]
		for c, x := range row {
			if out[c], err = fromNative(x, defs[c].Type); err != nil {
				e := err.(*Error)
				e.Message = "row " + strconv.Itoa(r+1) + ", column " + defs[c].Name + ": " + e.Message
				return nil, e
			}
		}
		data[r] = out
	}
	t, err := db.eng.Create(engine.CreateRequest{Table: table, Columns: defs, Rows: data, Replace: opts.Replace})
	if err != nil {
		return nil, wrapError(err)
	}
	return tableInfo(t), nil
}

// CreateTableAs runs a query and stores its result as a table (like
// CREATE TABLE … AS SELECT). Result columns of the untyped NULL literal
// become STRING columns.
func (db *DB) CreateTableAs(ctx context.Context, table, sql string, opts *CreateOptions) (info *TableInfo, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	if opts == nil {
		opts = &CreateOptions{}
	}
	qo, err := opts.Query.internal()
	if err != nil {
		return nil, err
	}
	t, err := db.eng.CreateAs(ctx, table, sql, qo, opts.Replace)
	if err != nil {
		return nil, wrapError(err)
	}
	return tableInfo(t), nil
}

// SaveOptions are the options of SaveTable.
type SaveOptions struct {
	// RowGroupSize is the number of rows per row group (default 65536).
	RowGroupSize int
	// Encoding forces a column encoding: "auto" (default), "plain",
	// "dict" or "rle".
	Encoding string
}

// SaveTable writes a table (and its index definitions) to a PQCF file at
// path (relative to Config.DataDir), atomically replacing an existing
// file. It returns the file size in bytes.
func (db *DB) SaveTable(table, path string, opts *SaveOptions) (n int64, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return 0, err
	}
	if opts == nil {
		opts = &SaveOptions{}
	}
	if opts.RowGroupSize < 0 {
		return 0, newError(CodeInvalidRequest, "RowGroupSize must be positive")
	}
	switch opts.Encoding {
	case "", "auto", "plain", "dict", "rle":
	default:
		return 0, newError(CodeInvalidRequest, "unknown encoding %q", opts.Encoding)
	}
	n, err = db.eng.Save(engine.SaveRequest{Table: table, Path: path, RowGroupSize: opts.RowGroupSize, Encoding: opts.Encoding})
	return n, wrapError(err)
}

// OpenOptions are the options of OpenTable.
type OpenOptions struct {
	// Replace replaces an existing table of the same name.
	Replace bool
	// Mmap maps the file into memory and decodes column chunks lazily
	// instead of reading it whole.
	Mmap bool
}

// OpenTable reads a PQCF file (a path relative to Config.DataDir) as a
// table, restoring the indexes recorded in it.
func (db *DB) OpenTable(table, path string, opts *OpenOptions) (info *TableInfo, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	if opts == nil {
		opts = &OpenOptions{}
	}
	if table == "" {
		return nil, newError(CodeInvalidRequest, "table name must not be empty")
	}
	t, err := db.eng.Open(engine.OpenRequest{Table: table, Path: path, Replace: opts.Replace, Mmap: opts.Mmap})
	if err != nil {
		return nil, wrapError(err)
	}
	return tableInfo(t), nil
}

// DropTable removes a table and its indexes (NOT_FOUND if it does not
// exist).
func (db *DB) DropTable(table string) (err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return err
	}
	return wrapError(db.eng.Catalog().Drop(table))
}

// Tables lists the tables, ordered by name.
func (db *DB) Tables() (list []TableInfo, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	for _, t := range db.eng.Catalog().List() {
		list = append(list, *tableInfo(t))
	}
	return list, nil
}

// Schema describes a table, including its indexes (NOT_FOUND if it does
// not exist).
func (db *DB) Schema(table string) (info *TableInfo, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	entry, ok := db.eng.Catalog().Snapshot().Entry(table)
	if !ok {
		return nil, newError(CodeNotFound, "table %q not found", table)
	}
	info = tableInfo(entry.Table)
	for _, ix := range entry.Indexes {
		info.Indexes = append(info.Indexes, IndexInfo{Name: ix.Name, Column: ix.Column, Kind: string(ix.Kind)})
	}
	return info, nil
}

// ---------------------------------------------------------------- queries

// QueryOptions are per-query options. The zero value selects the
// defaults. A nil *QueryOptions is the same as the zero value.
type QueryOptions struct {
	// Threads is the number of worker threads (default Config.Threads).
	Threads int
	// Timeout bounds the whole statement (default: none); exceeding it
	// fails with TIMEOUT.
	Timeout time.Duration
	// MaxRows fails the query with RESOURCE_LIMIT if the result has more
	// rows (default: unlimited).
	MaxRows int64
	// Mode is the execution model: "" or "auto", "row", "vectorized".
	Mode string
	// Join forces a join algorithm: "" or "auto", "hash", "merge",
	// "nested_loop".
	Join string
	// NoOptimize disables the logical optimizer.
	NoOptimize bool
	// NoIndexes prevents index scans.
	NoIndexes bool
	// Native uses the native kernels if Config.NativeKernels loaded them.
	Native bool
}

// maxThreads caps QueryOptions.Threads (more workers never help).
const maxThreads = 256

func (o *QueryOptions) internal() (engine.QueryOptions, error) {
	qo := engine.QueryOptions{MaxRows: -1}
	if o == nil {
		return qo, nil
	}
	if o.Threads < 0 || o.Timeout < 0 || o.MaxRows < 0 {
		return qo, newError(CodeInvalidRequest, "Threads, Timeout and MaxRows must not be negative")
	}
	switch o.Mode {
	case "", "auto", "row", "vectorized":
	default:
		return qo, newError(CodeUnsupported, "mode %q is not supported", o.Mode)
	}
	switch o.Join {
	case "", "auto", "hash", "merge", "nested_loop":
	default:
		return qo, newError(CodeUnsupported, "join %q is not supported", o.Join)
	}
	if o.MaxRows > 0 {
		qo.MaxRows = o.MaxRows
	}
	qo.Threads = min(o.Threads, maxThreads)
	qo.Timeout = o.Timeout
	qo.Mode, qo.Join = o.Mode, o.Join
	qo.NoOptimize, qo.NoIndexes, qo.Native = o.NoOptimize, o.NoIndexes, o.Native
	return qo, nil
}

// Result is the complete result of a query.
type Result struct {
	// Columns are the result columns: names and types.
	Columns []Column
	// Rows holds the values, row by row; Rows[i][j] belongs to
	// Columns[j]. A value is nil (NULL) or of the Go type of its column
	// (see the package documentation).
	Rows [][]any
}

// RowCount returns the number of rows.
func (r *Result) RowCount() int { return len(r.Rows) }

// Query executes one SQL statement and returns its whole result. ctx
// cancels the query (CANCELLED).
func (db *DB) Query(ctx context.Context, sql string, opts *QueryOptions) (res *Result, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	qo, err := opts.internal()
	if err != nil {
		return nil, err
	}
	r, err := db.eng.Query(ctx, sql, qo)
	if err != nil {
		return nil, wrapError(err)
	}
	res = &Result{Columns: make([]Column, len(r.Columns)), Rows: make([][]any, len(r.Rows))}
	ts := make([]types.Type, len(r.Columns))
	for i, c := range r.Columns {
		res.Columns[i] = Column{Name: c.Name, Type: fromInternalType(c.Type)}
		ts[i] = c.Type
	}
	cells := make([]any, len(r.Rows)*len(ts))
	for i, row := range r.Rows {
		out := cells[i*len(ts) : (i+1)*len(ts) : (i+1)*len(ts)]
		for j, v := range row {
			out[j] = toNative(v, ts[j])
		}
		res.Rows[i] = out
		r.Rows[i] = nil // let the engine row be collected early
	}
	return res, nil
}

// Rows is a streaming query result: rows are produced as they are read.
// A Rows must be closed; it is not safe for concurrent use.
type Rows struct {
	cur    *engine.Cursor
	cols   []Column
	ts     []types.Type
	values []any
	err    error
}

// QueryRows executes one SQL statement and returns a cursor over its
// result. The tables the statement reads are fixed when it starts.
func (db *DB) QueryRows(ctx context.Context, sql string, opts *QueryOptions) (rows *Rows, err error) {
	defer guard(&err)
	if err := db.check(); err != nil {
		return nil, err
	}
	qo, err := opts.internal()
	if err != nil {
		return nil, err
	}
	cur, err := db.eng.Start(ctx, sql, qo)
	if err != nil {
		return nil, wrapError(err)
	}
	rows = &Rows{cur: cur, cols: make([]Column, len(cur.Columns)), ts: make([]types.Type, len(cur.Columns))}
	for i, c := range cur.Columns {
		rows.cols[i] = Column{Name: c.Name, Type: fromInternalType(c.Type)}
		rows.ts[i] = c.Type
	}
	return rows, nil
}

// Columns returns the result columns.
func (r *Rows) Columns() []Column { return r.cols }

// Next advances to the next row; it returns false at the end or on an
// error (see Err).
func (r *Rows) Next() bool {
	if r.err != nil || r.cur == nil {
		return false
	}
	var row types.Row
	func() {
		defer guard(&r.err)
		row, r.err = r.cur.Next()
		r.err = wrapError(r.err)
	}()
	if r.err != nil || row == nil {
		r.Close()
		return false
	}
	r.values = make([]any, len(row))
	for i, v := range row {
		r.values[i] = toNative(v, r.ts[i])
	}
	return true
}

// Values returns the current row (valid until the next call of Next; the
// slice is not reused).
func (r *Rows) Values() []any { return r.values }

// Err returns the error that ended the iteration, if any.
func (r *Rows) Err() error { return r.err }

// Close releases the cursor; it is safe to call more than once.
func (r *Rows) Close() error {
	if r.cur != nil {
		r.cur.Close()
		r.cur = nil
	}
	return nil
}
