// Package protocol implements the PolyQuery JSON request/response protocol
// (spec/protocol/protocol.md §3–§6) on top of the engine.
package protocol

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"runtime"
	"runtime/debug"
	"time"

	"polyquery/internal/engine"
	"polyquery/internal/errs"
	"polyquery/internal/exec"
	"polyquery/internal/ingest"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Handler executes protocol requests against an engine.
type Handler struct {
	eng *engine.Engine
	log *slog.Logger
}

// NewHandler creates a handler.
func NewHandler(eng *engine.Engine) *Handler {
	return &Handler{eng: eng, log: eng.Config().Logger}
}

// request is a decoded request object.
type request struct {
	id     []byte
	fields map[string]json.RawMessage
}

// Request is a decoded protocol request (protocol.md §4).
type Request = request

// DecodeRequest decodes a request object given as JSON text.
func DecodeRequest(line []byte) (*Request, *errs.Error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
		return nil, errs.New(errs.InvalidRequest, "request is not a JSON object")
	}
	req := &request{id: []byte("null"), fields: fields}
	if raw, ok := fields["id"]; ok {
		var buf bytes.Buffer
		if json.Compact(&buf, raw) == nil {
			req.id = buf.Bytes()
		}
	}
	return req, nil
}

// NewRequest creates a request for op with the given string fields.
func NewRequest(op string, fields map[string]string) *Request {
	req := &request{id: []byte("null"), fields: map[string]json.RawMessage{}}
	for k, v := range fields {
		req.Set(k, v)
	}
	req.Set("op", op)
	return req
}

// Set sets a field of the request to a JSON-encoded value.
func (r *request) Set(name string, v any) {
	raw, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	r.fields[name] = raw
}

// ID returns the request's id as JSON text.
func (r *request) ID() []byte { return r.id }

// Op returns the request's operation (empty if missing or not a string).
func (r *request) Op() string {
	op, _ := r.str("op")
	return op
}

// HandleLine executes one request given as JSON text and returns the
// single-line JSON response (without trailing newline).
func (h *Handler) HandleLine(line []byte) []byte {
	req, e := DecodeRequest(line)
	if e != nil {
		return ErrorResponse(nil, e)
	}
	resp, _ := h.Execute(context.Background(), req)
	return resp
}

// Execute runs a request and returns its single-line JSON response. If the
// request failed, the error is returned as well (the response then is the
// matching error response). ctx cancels long-running operations.
func (h *Handler) Execute(ctx context.Context, req *Request) ([]byte, *errs.Error) {
	return h.guard(req, func() ([]byte, error) { return h.dispatch(ctx, req) })
}

// RunQuery executes a "query" request like Execute and also returns the
// number of result rows.
func (h *Handler) RunQuery(ctx context.Context, req *Request) (resp []byte, rows int64, failure *errs.Error) {
	resp, failure = h.guard(req, func() ([]byte, error) {
		var err error
		resp, rows, err = h.query(ctx, req)
		return resp, err
	})
	return resp, rows, failure
}

// guard runs fn, converting errors and panics into error responses.
func (h *Handler) guard(req *Request, fn func() ([]byte, error)) (resp []byte, failure *errs.Error) {
	start := time.Now()
	op := req.Op()
	defer func() {
		if r := recover(); r != nil {
			h.log.Error("internal error", "op", op, "panic", fmt.Sprint(r), "stack", string(debug.Stack()))
			failure = errs.New(errs.InternalError, "internal error: %v", r)
			resp = ErrorResponse(req.id, failure)
		}
	}()
	resp, err := fn()
	if err != nil {
		e := errs.From(err)
		h.log.Debug("request failed", "op", op, "code", string(e.Code), "duration_ms", time.Since(start).Milliseconds())
		return ErrorResponse(req.id, e), e
	}
	h.log.Debug("request done", "op", op, "duration_ms", time.Since(start).Milliseconds())
	return resp, nil
}

func (h *Handler) dispatch(ctx context.Context, req *request) ([]byte, error) {
	op, err := req.requiredStr("op")
	if err != nil {
		return nil, err
	}
	switch op {
	case "capabilities":
		w := req.ok()
		writeCapabilities(w)
		return finish(w), nil
	case "version":
		w := req.ok()
		writeVersion(w)
		return finish(w), nil
	case "tables":
		return h.tables(req), nil
	case "schema":
		return h.schema(req)
	case "drop":
		name, err := req.requiredStr("table")
		if err != nil {
			return nil, err
		}
		if err := h.eng.Catalog().Drop(name); err != nil {
			return nil, err
		}
		return finish(req.ok()), nil
	case "reset":
		h.eng.Catalog().Reset()
		return finish(req.ok()), nil
	case "load":
		return h.load(req)
	case "query":
		resp, _, err := h.query(ctx, req)
		return resp, err
	case "sleep":
		return h.sleep(ctx, req)
	case "explain":
		return h.explain(req)
	case "save":
		return h.save(req)
	case "open":
		return h.open(req)
	case "stats":
		return h.stats(req)
	}
	return nil, errs.New(errs.InvalidRequest, "unknown op %q", op)
}

// ---------------------------------------------------------------- field access

func invalid(format string, args ...any) error {
	return errs.New(errs.InvalidRequest, format, args...)
}

func (r *request) has(name string) bool {
	raw, ok := r.fields[name]
	return ok && string(raw) != "null"
}

func (r *request) str(name string) (string, bool) {
	var s string
	if raw, ok := r.fields[name]; ok && json.Unmarshal(raw, &s) == nil && len(raw) > 0 && raw[0] == '"' {
		return s, true
	}
	return "", false
}

func (r *request) requiredStr(name string) (string, error) {
	if !r.has(name) {
		return "", invalid("missing required field %q", name)
	}
	s, ok := r.str(name)
	if !ok {
		return "", invalid("field %q must be a string", name)
	}
	return s, nil
}

func decodeBool(raw json.RawMessage, name string) (bool, error) {
	var b bool
	if err := json.Unmarshal(raw, &b); err != nil {
		return false, invalid("field %q must be a boolean", name)
	}
	return b, nil
}

// decodeCount decodes a non-negative integral JSON number.
func decodeCount(raw json.RawMessage, name string) (int64, error) {
	var f float64
	if err := json.Unmarshal(raw, &f); err != nil || f < 0 || f != math.Trunc(f) || f > math.MaxInt64 {
		return 0, invalid("field %q must be a non-negative integer", name)
	}
	var i int64
	if err := json.Unmarshal(raw, &i); err == nil {
		return i, nil
	}
	return int64(f), nil
}

func (r *request) object(name string) (map[string]json.RawMessage, error) {
	if !r.has(name) {
		return nil, nil
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(r.fields[name], &m); err != nil || m == nil {
		return nil, invalid("field %q must be an object", name)
	}
	return m, nil
}

// ---------------------------------------------------------------- responses

func (r *request) ok() *writer {
	w := &writer{}
	w.beginObject()
	w.key("id")
	w.raw(r.id)
	w.key("ok")
	w.bool(true)
	return w
}

func finish(w *writer) []byte {
	w.endObject()
	return w.b
}

func writeError(w *writer, e *errs.Error) {
	w.beginObject()
	w.key("code")
	w.str(string(e.Code))
	w.key("message")
	w.str(e.Message)
	if len(e.Details) > 0 {
		w.key("details")
		w.any(e.Details)
	}
	w.endObject()
}

// ErrorResponse renders an error response with the given request id
// (JSON text; nil means null).
func ErrorResponse(id []byte, e *errs.Error) []byte {
	if id == nil {
		id = []byte("null")
	}
	w := &writer{}
	w.beginObject()
	w.key("id")
	w.raw(id)
	w.key("ok")
	w.bool(false)
	w.key("error")
	writeError(w, e)
	w.endObject()
	return w.b
}

func writeCapabilities(w *writer) {
	w.key("protocol_version")
	w.int(engine.ProtocolVersion)
	w.key("capabilities")
	w.beginArray()
	for _, c := range engine.Capabilities {
		w.str(c)
	}
	w.endArray()
}

func writeVersion(w *writer) {
	w.key("engine")
	w.str(engine.Name)
	w.key("engine_version")
	w.str(engine.Version)
	w.key("language")
	w.str("go")
	w.key("protocol_version")
	w.int(engine.ProtocolVersion)
	w.key("spec_version")
	w.str(engine.SpecVersion)
	w.key("runtime")
	w.str(runtime.Version())
	w.key("build")
	w.beginObject()
	w.key("profile")
	w.str("release")
	w.key("flags")
	w.str("-trimpath")
	w.endObject()
}

// CapabilitiesJSON renders the capabilities object (CLI mode).
func CapabilitiesJSON() []byte {
	w := &writer{}
	w.beginObject()
	w.key("ok")
	w.bool(true)
	writeCapabilities(w)
	return finish(w)
}

// VersionJSON renders the version object (CLI mode).
func VersionJSON() []byte {
	w := &writer{}
	w.beginObject()
	w.key("ok")
	w.bool(true)
	writeVersion(w)
	return finish(w)
}

func writeColumns(w *writer, cols []storage.ColumnDef) {
	w.key("columns")
	w.beginArray()
	for _, c := range cols {
		w.beginObject()
		w.key("name")
		w.str(c.Name)
		w.key("type")
		w.str(c.Type.ResultName())
		w.endObject()
	}
	w.endArray()
}

// ---------------------------------------------------------------- catalog ops

func (h *Handler) tables(req *request) []byte {
	w := req.ok()
	w.key("tables")
	w.beginArray()
	for _, t := range h.eng.Catalog().List() {
		w.beginObject()
		w.key("name")
		w.str(t.Name)
		w.key("row_count")
		w.int(int64(t.Rows))
		w.endObject()
	}
	w.endArray()
	return finish(w)
}

func (h *Handler) schema(req *request) ([]byte, error) {
	name, err := req.requiredStr("table")
	if err != nil {
		return nil, err
	}
	entry, ok := h.eng.Catalog().Snapshot().Entry(name)
	if !ok {
		return nil, errs.New(errs.NotFound, "table %q not found", name)
	}
	t := entry.Table
	w := req.ok()
	w.key("table")
	w.str(t.Name)
	w.key("row_count")
	w.int(int64(t.Rows))
	writeColumns(w, t.Columns)
	w.key("indexes")
	w.beginArray()
	for _, ix := range entry.Indexes {
		w.beginObject()
		w.key("name")
		w.str(ix.Name)
		w.key("column")
		w.str(ix.Column)
		w.key("kind")
		w.str(string(ix.Kind))
		w.endObject()
	}
	w.endArray()
	w.key("layout")
	w.str(t.Layout.String())
	return finish(w), nil
}

func (h *Handler) load(req *request) ([]byte, error) {
	name, err := req.requiredStr("table")
	if err != nil {
		return nil, err
	}
	if name == "" {
		return nil, invalid("table name must not be empty")
	}
	format, err := req.requiredStr("format")
	if err != nil {
		return nil, err
	}
	f := ingest.Format(format)
	if f != ingest.CSV && f != ingest.JSON && f != ingest.JSONL {
		return nil, invalid("unknown format %q", format)
	}
	lr := engine.LoadRequest{Table: name, Options: ingest.DefaultOptions(f)}
	hasPath, hasData := req.has("path"), req.has("data")
	switch {
	case hasPath == hasData:
		return nil, invalid("exactly one of \"path\" and \"data\" is required")
	case hasPath:
		if lr.Path, err = req.requiredStr("path"); err != nil {
			return nil, err
		}
	default:
		data, err := req.requiredStr("data")
		if err != nil {
			return nil, err
		}
		lr.Data = &data
	}
	if raw, ok := req.fields["replace"]; ok && string(raw) != "null" {
		if lr.Replace, err = decodeBool(raw, "replace"); err != nil {
			return nil, err
		}
	}
	if req.has("schema") {
		if lr.Options.Schema, err = decodeSchema(req.fields["schema"]); err != nil {
			return nil, err
		}
	}
	opts, err := req.object("options")
	if err != nil {
		return nil, err
	}
	if raw, ok := opts["header"]; ok {
		if lr.Options.Header, err = decodeBool(raw, "header"); err != nil {
			return nil, err
		}
	}
	if raw, ok := opts["delimiter"]; ok {
		var d string
		if json.Unmarshal(raw, &d) != nil || len(d) != 1 || d[0] >= 0x80 || d[0] == '"' || d[0] == '\n' || d[0] == '\r' {
			return nil, invalid("delimiter must be a single ASCII character")
		}
		lr.Options.Delimiter = d[0]
	}
	if lr.Build, err = buildOptions(opts); err != nil {
		return nil, err
	}
	if f == ingest.CSV && !lr.Options.Header && lr.Options.Schema == nil {
		return nil, invalid("header=false requires an explicit schema")
	}
	t, err := h.eng.Load(lr)
	if err != nil {
		return nil, err
	}
	return tableResponse(req, t), nil
}

func tableResponse(req *request, t *storage.Table) []byte {
	w := req.ok()
	w.key("table")
	w.str(t.Name)
	w.key("row_count")
	w.int(int64(t.Rows))
	writeColumns(w, t.Columns)
	return finish(w)
}

// buildOptions decodes the in-memory layout options of load/open.
func buildOptions(opts map[string]json.RawMessage) (storage.BuildOptions, error) {
	var bo storage.BuildOptions
	if raw, ok := opts["layout"]; ok {
		var l string
		var valid bool
		if json.Unmarshal(raw, &l) == nil {
			bo.Layout, valid = storage.ParseLayout(l)
		}
		if !valid {
			return bo, invalid("layout must be \"row\" or \"column\"")
		}
	}
	if raw, ok := opts["dictionary"]; ok {
		var err error
		if bo.Dictionary, err = decodeBool(raw, "dictionary"); err != nil {
			return bo, err
		}
	}
	return bo, nil
}

func decodeSchema(raw json.RawMessage) ([]storage.ColumnDef, error) {
	var items []map[string]json.RawMessage
	if err := json.Unmarshal(raw, &items); err != nil {
		return nil, invalid("schema must be an array of {\"name\",\"type\"} objects")
	}
	cols := make([]storage.ColumnDef, 0, len(items))
	for _, it := range items {
		var name, typ string
		if it == nil || json.Unmarshal(it["name"], &name) != nil || json.Unmarshal(it["type"], &typ) != nil {
			return nil, invalid("schema entries must have string \"name\" and \"type\"")
		}
		t, err := types.ParseTypeName(typ)
		if err != nil {
			return nil, invalid("schema column %q: %s", name, errs.From(err).Message)
		}
		cols = append(cols, storage.ColumnDef{Name: name, Type: t})
	}
	return cols, nil
}

// ---------------------------------------------------------------- query

func (h *Handler) query(ctx context.Context, req *request) ([]byte, int64, error) {
	sql, err := req.requiredStr("sql")
	if err != nil {
		return nil, 0, err
	}
	qo, err := parseQueryOptions(req)
	if err != nil {
		return nil, 0, err
	}
	start := time.Now()
	res, err := h.eng.Query(ctx, sql, qo)
	if err != nil {
		return nil, 0, err
	}
	elapsed := time.Since(start)
	w := req.ok()
	writeResultColumns(w, res.Columns)
	if !qo.CountOnly {
		w.key("rows")
		writeRows(w, res.Rows, res.Columns)
	}
	w.key("row_count")
	w.int(res.RowCount)
	w.key("stats")
	w.beginObject()
	w.key("elapsed_us")
	w.int(elapsed.Microseconds())
	w.endObject()
	return finish(w), res.RowCount, nil
}

func (h *Handler) explain(req *request) ([]byte, error) {
	sql, err := req.requiredStr("sql")
	if err != nil {
		return nil, err
	}
	qo, err := parseQueryOptions(req)
	if err != nil {
		return nil, err
	}
	tree, err := h.eng.Explain(sql, qo)
	if err != nil {
		return nil, err
	}
	text, err := json.Marshal(tree)
	if err != nil {
		return nil, errs.New(errs.InternalError, "cannot render plan: %v", err)
	}
	w := req.ok()
	w.key("plan")
	w.raw(text)
	return finish(w), nil
}

// ParseQueryOptions validates the "options" object of a query request.
func ParseQueryOptions(req *Request) (engine.QueryOptions, error) {
	return parseQueryOptions(req)
}

// maxThreads caps the threads option (more workers than this never help).
const maxThreads = 256

func parseQueryOptions(req *request) (engine.QueryOptions, error) {
	qo := engine.QueryOptions{MaxRows: -1}
	opts, err := req.object("options")
	if err != nil {
		return qo, err
	}
	enum := func(name string, allowed ...string) error {
		raw, ok := opts[name]
		if !ok {
			return nil
		}
		var s string
		if json.Unmarshal(raw, &s) != nil || len(raw) == 0 || raw[0] != '"' {
			return invalid("option %q must be a string", name)
		}
		for _, a := range allowed {
			if s == a {
				return nil
			}
		}
		return errs.New(errs.Unsupported, "option %s=%q is not supported", name, s)
	}
	for name, raw := range opts {
		switch name {
		case "max_rows":
			if qo.MaxRows, err = decodeCount(raw, name); err != nil {
				return qo, err
			}
		case "timeout_ms":
			ms, err := decodeCount(raw, name)
			if err != nil {
				return qo, err
			}
			qo.Timeout = time.Duration(ms) * time.Millisecond
		case "result":
			if err := enum(name, "rows", "count"); err != nil {
				return qo, err
			}
			var s string
			_ = json.Unmarshal(raw, &s)
			qo.CountOnly = s == "count"
		case "mode":
			if err := enum(name, "auto", "row", "vectorized"); err != nil {
				return qo, err
			}
			_ = json.Unmarshal(raw, &qo.Mode)
		case "join":
			if err := enum(name, "auto", "hash", "merge", "nested_loop"); err != nil {
				return qo, err
			}
			_ = json.Unmarshal(raw, &qo.Join)
		case "threads":
			n, err := decodeCount(raw, name)
			if err != nil || n < 1 {
				return qo, invalid("option \"threads\" must be a positive integer")
			}
			qo.Threads = int(min(n, maxThreads))
		case "optimize":
			b, err := decodeBool(raw, name)
			if err != nil {
				return qo, err
			}
			qo.NoOptimize = !b
		case "use_indexes":
			b, err := decodeBool(raw, name)
			if err != nil {
				return qo, err
			}
			qo.NoIndexes = !b
		case "native":
			b, err := decodeBool(raw, name)
			if err != nil {
				return qo, err
			}
			qo.Native = b
		case "query_id":
			var s string
			if json.Unmarshal(raw, &s) != nil || len(raw) == 0 || raw[0] != '"' {
				return qo, invalid("option \"query_id\" must be a string")
			}
			qo.QueryID = s
		}
	}
	return qo, nil
}

// ---------------------------------------------------------------- sleep

func (h *Handler) sleep(ctx context.Context, req *request) ([]byte, error) {
	if !h.eng.Config().TestFunctions {
		return nil, invalid("the sleep operation requires --enable-test-functions")
	}
	raw, ok := req.fields["ms"]
	if !ok {
		return nil, invalid("missing required field \"ms\"")
	}
	ms, err := decodeCount(raw, "ms")
	if err != nil {
		return nil, err
	}
	timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-ctx.Done():
		return nil, exec.ContextError(ctx.Err())
	}
	return finish(req.ok()), nil
}

// ---------------------------------------------------------------- storage

func (h *Handler) open(req *request) ([]byte, error) {
	name, err := req.requiredStr("table")
	if err != nil {
		return nil, err
	}
	if name == "" {
		return nil, invalid("table name must not be empty")
	}
	or := engine.OpenRequest{Table: name}
	if or.Path, err = req.requiredStr("path"); err != nil {
		return nil, err
	}
	if raw, ok := req.fields["replace"]; ok && string(raw) != "null" {
		if or.Replace, err = decodeBool(raw, "replace"); err != nil {
			return nil, err
		}
	}
	opts, err := req.object("options")
	if err != nil {
		return nil, err
	}
	bo, err := buildOptions(opts)
	if err != nil {
		return nil, err
	}
	or.Layout, or.Dictionary = bo.Layout, bo.Dictionary
	if raw, ok := opts["mmap"]; ok {
		if or.Mmap, err = decodeBool(raw, "mmap"); err != nil {
			return nil, err
		}
	}
	t, err := h.eng.Open(or)
	if err != nil {
		return nil, err
	}
	return tableResponse(req, t), nil
}

func (h *Handler) save(req *request) ([]byte, error) {
	name, err := req.requiredStr("table")
	if err != nil {
		return nil, err
	}
	sr := engine.SaveRequest{Table: name}
	if sr.Path, err = req.requiredStr("path"); err != nil {
		return nil, err
	}
	opts, err := req.object("options")
	if err != nil {
		return nil, err
	}
	if raw, ok := opts["row_group_size"]; ok {
		n, err := decodeCount(raw, "row_group_size")
		if err != nil || n < 1 || n > 1<<31 {
			return nil, invalid("option \"row_group_size\" must be a positive integer")
		}
		sr.RowGroupSize = int(n)
	}
	if raw, ok := opts["encoding"]; ok {
		if json.Unmarshal(raw, &sr.Encoding) != nil || len(raw) == 0 || raw[0] != '"' {
			return nil, invalid("option \"encoding\" must be a string")
		}
		switch sr.Encoding {
		case "auto", "plain", "dict", "rle":
		default:
			return nil, invalid("unknown encoding %q", sr.Encoding)
		}
	}
	n, err := h.eng.Save(sr)
	if err != nil {
		return nil, err
	}
	w := req.ok()
	w.key("path")
	w.str(sr.Path)
	w.key("bytes")
	w.int(n)
	return finish(w), nil
}

func (h *Handler) stats(req *request) ([]byte, error) {
	name, err := req.requiredStr("table")
	if err != nil {
		return nil, err
	}
	t, stats, err := h.eng.Stats(name)
	if err != nil {
		return nil, err
	}
	w := req.ok()
	w.key("table")
	w.str(t.Name)
	w.key("row_count")
	w.int(int64(t.Rows))
	w.key("columns")
	w.beginArray()
	for i, c := range t.Columns {
		st := stats[i]
		w.beginObject()
		w.key("name")
		w.str(c.Name)
		w.key("type")
		w.str(c.Type.ResultName())
		w.key("null_count")
		w.int(int64(st.NullCount))
		w.key("distinct_count")
		w.int(int64(st.Distinct))
		w.key("min")
		w.value(st.Min, c.Type)
		w.key("max")
		w.value(st.Max, c.Type)
		w.endObject()
	}
	w.endArray()
	return finish(w), nil
}

// ---------------------------------------------------------------- raw loads

// RawLoad describes a load whose data is a raw HTTP request body.
type RawLoad struct {
	Table     string
	Format    string
	Data      []byte
	Replace   bool
	Header    bool
	Delimiter string // empty = default
	Schema    string // optional JSON schema array (as in the load op)
}

// LoadRaw loads raw data as a table (HTTP PUT /v1/tables/{name}) and
// returns the load response.
func (h *Handler) LoadRaw(rl RawLoad) ([]byte, *errs.Error) {
	req := NewRequest("load", map[string]string{"table": rl.Table})
	return h.guard(req, func() ([]byte, error) {
		if rl.Table == "" {
			return nil, invalid("table name must not be empty")
		}
		f := ingest.Format(rl.Format)
		if f != ingest.CSV && f != ingest.JSON && f != ingest.JSONL {
			return nil, invalid("unknown format %q", rl.Format)
		}
		data := string(rl.Data)
		lr := engine.LoadRequest{Table: rl.Table, Options: ingest.DefaultOptions(f), Data: &data, Replace: rl.Replace}
		lr.Options.Header = rl.Header
		if rl.Delimiter != "" {
			d := rl.Delimiter
			if len(d) != 1 || d[0] >= 0x80 || d[0] == '"' || d[0] == '\n' || d[0] == '\r' {
				return nil, invalid("delimiter must be a single ASCII character")
			}
			lr.Options.Delimiter = d[0]
		}
		if rl.Schema != "" {
			var err error
			if lr.Options.Schema, err = decodeSchema(json.RawMessage(rl.Schema)); err != nil {
				return nil, err
			}
		}
		if f == ingest.CSV && !lr.Options.Header && lr.Options.Schema == nil {
			return nil, invalid("header=false requires an explicit schema")
		}
		t, err := h.eng.Load(lr)
		if err != nil {
			return nil, err
		}
		return tableResponse(req, t), nil
	})
}
