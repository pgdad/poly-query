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

// HandleLine executes one request given as JSON text and returns the
// single-line JSON response (without trailing newline).
func (h *Handler) HandleLine(line []byte) []byte {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
		return errorResponse(nil, errs.New(errs.InvalidRequest, "request is not a JSON object"))
	}
	req := &request{id: []byte("null"), fields: fields}
	if raw, ok := fields["id"]; ok {
		var buf bytes.Buffer
		if json.Compact(&buf, raw) == nil {
			req.id = buf.Bytes()
		}
	}
	return h.handle(req)
}

func (h *Handler) handle(req *request) (resp []byte) {
	start := time.Now()
	op, _ := req.str("op")
	defer func() {
		if r := recover(); r != nil {
			h.log.Error("internal error", "op", op, "panic", fmt.Sprint(r), "stack", string(debug.Stack()))
			resp = errorResponse(req.id, errs.New(errs.InternalError, "internal error: %v", r))
		}
	}()
	resp, err := h.dispatch(req)
	if err != nil {
		e := errs.From(err)
		h.log.Debug("request failed", "op", op, "code", string(e.Code), "duration_ms", time.Since(start).Milliseconds())
		return errorResponse(req.id, e)
	}
	h.log.Debug("request done", "op", op, "duration_ms", time.Since(start).Milliseconds())
	return resp
}

func (h *Handler) dispatch(req *request) ([]byte, error) {
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
		return h.query(req)
	case "sleep":
		return h.sleep(req)
	case "explain", "save", "open", "stats":
		return nil, errs.New(errs.Unsupported, "operation %q is not supported by this engine", op)
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

func errorResponse(id []byte, e *errs.Error) []byte {
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
	t, ok := h.eng.Catalog().Get(name)
	if !ok {
		return nil, errs.New(errs.NotFound, "table %q not found", name)
	}
	w := req.ok()
	w.key("table")
	w.str(t.Name)
	w.key("row_count")
	w.int(int64(t.Rows))
	writeColumns(w, t.Columns)
	w.key("indexes")
	w.beginArray()
	w.endArray()
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
	if raw, ok := opts["layout"]; ok {
		var l string
		if json.Unmarshal(raw, &l) != nil || (l != "row" && l != "column") {
			return nil, invalid("layout must be \"row\" or \"column\"")
		}
	}
	if f == ingest.CSV && !lr.Options.Header && lr.Options.Schema == nil {
		return nil, invalid("header=false requires an explicit schema")
	}
	t, err := h.eng.Load(lr)
	if err != nil {
		return nil, err
	}
	w := req.ok()
	w.key("table")
	w.str(t.Name)
	w.key("row_count")
	w.int(int64(t.Rows))
	writeColumns(w, t.Columns)
	return finish(w), nil
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

func (h *Handler) query(req *request) ([]byte, error) {
	sql, err := req.requiredStr("sql")
	if err != nil {
		return nil, err
	}
	qo, err := parseQueryOptions(req)
	if err != nil {
		return nil, err
	}
	start := time.Now()
	res, err := h.eng.Query(context.Background(), sql, qo)
	if err != nil {
		return nil, err
	}
	elapsed := time.Since(start)
	w := req.ok()
	w.key("columns")
	w.beginArray()
	for _, c := range res.Columns {
		w.beginObject()
		w.key("name")
		w.str(c.Name)
		w.key("type")
		w.str(c.Type.ResultName())
		w.endObject()
	}
	w.endArray()
	if !qo.CountOnly {
		w.key("rows")
		w.beginArray()
		for _, row := range res.Rows {
			w.beginArray()
			for i, v := range row {
				w.value(v, res.Columns[i].Type)
			}
			w.endArray()
		}
		w.endArray()
	}
	w.key("row_count")
	w.int(res.RowCount)
	w.key("stats")
	w.beginObject()
	w.key("elapsed_us")
	w.int(elapsed.Microseconds())
	w.endObject()
	return finish(w), nil
}

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
			if err := enum(name, "auto", "row"); err != nil {
				return qo, err
			}
		case "join":
			if err := enum(name, "auto", "hash", "merge", "nested_loop"); err != nil {
				return qo, err
			}
		case "threads":
			n, err := decodeCount(raw, name)
			if err != nil || n < 1 {
				return qo, invalid("option \"threads\" must be a positive integer")
			}
		case "optimize", "use_indexes", "native":
			if _, err := decodeBool(raw, name); err != nil {
				return qo, err
			}
		case "query_id":
			var s string
			if json.Unmarshal(raw, &s) != nil || len(raw) == 0 || raw[0] != '"' {
				return qo, invalid("option \"query_id\" must be a string")
			}
		}
	}
	return qo, nil
}

// ---------------------------------------------------------------- sleep

func (h *Handler) sleep(req *request) ([]byte, error) {
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
	time.Sleep(time.Duration(ms) * time.Millisecond)
	return finish(req.ok()), nil
}
