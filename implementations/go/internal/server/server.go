// Package server implements the PolyQuery HTTP/1.1 API (protocol.md §7):
// routing, admission control with bounded queueing, query timeouts and
// cancellation, streamed NDJSON results with backpressure, Prometheus
// metrics, structured logs and graceful shutdown (concurrency.md).
package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"polyquery/internal/engine"
	"polyquery/internal/errs"
	"polyquery/internal/protocol"
)

// Config holds the serve-mode options (protocol.md §2).
type Config struct {
	Host            string
	Port            int
	Workers         int           // max concurrently executing queries
	QueueDepth      int           // max queries waiting for a worker
	QueryTimeout    time.Duration // default query timeout; 0 = none
	ShutdownGrace   time.Duration // time running queries get on shutdown
	MaxRequestBytes int64         // max request body size
}

// Server serves one engine over HTTP.
type Server struct {
	cfg Config
	eng *engine.Engine
	h   *protocol.Handler
	log *slog.Logger
	adm *admission
	reg *registry
	met *metrics

	shutting atomic.Bool
	// base is cancelled when the shutdown grace period expires; every query
	// and long-running request is cancelled with it.
	base  context.Context
	abort context.CancelFunc
	// active counts requests being handled.
	active sync.WaitGroup
}

// New creates a server for an engine.
func New(eng *engine.Engine, cfg Config) *Server {
	base, abort := context.WithCancel(context.Background())
	return &Server{
		cfg:   cfg,
		eng:   eng,
		h:     protocol.NewHandler(eng),
		log:   eng.Config().Logger,
		adm:   newAdmission(cfg.Workers, cfg.QueueDepth),
		reg:   newRegistry(),
		met:   newMetrics(),
		base:  base,
		abort: abort,
	}
}

// Listen opens the server's TCP listener.
func (s *Server) Listen() (net.Listener, error) {
	return net.Listen("tcp", net.JoinHostPort(s.cfg.Host, strconv.Itoa(s.cfg.Port)))
}

// ListeningEvent renders the startup line printed to stdout.
func ListeningEvent(host string, ln net.Listener) []byte {
	port := 0
	if addr, ok := ln.Addr().(*net.TCPAddr); ok {
		port = addr.Port
	}
	b, _ := json.Marshal(struct {
		Event string `json:"event"`
		Host  string `json:"host"`
		Port  int    `json:"port"`
	}{"listening", host, port})
	return b
}

// Serve handles connections on ln until stop is closed, then shuts down
// gracefully (concurrency.md §5): new connections are refused, running and
// queued queries get the grace period to finish, the rest are cancelled.
func (s *Server) Serve(ln net.Listener, stop <-chan struct{}) error {
	srv := &http.Server{
		Handler:           s,
		ErrorLog:          slog.NewLogLogger(s.log.Handler(), slog.LevelWarn),
		ReadHeaderTimeout: 30 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	s.log.Info("server listening", "addr", ln.Addr().String(), "workers", s.cfg.Workers, "queue_depth", s.cfg.QueueDepth)
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()
	select {
	case err := <-served:
		return err
	case <-stop:
	}

	s.shutting.Store(true)
	s.log.Info("shutdown started", "grace_ms", s.cfg.ShutdownGrace.Milliseconds())
	graceCtx, cancel := context.WithTimeout(context.Background(), s.cfg.ShutdownGrace)
	defer cancel()
	if err := srv.Shutdown(graceCtx); err != nil {
		// Grace period expired: cancel what is still running, give the
		// handlers a moment to answer CANCELLED, then close connections.
		s.log.Warn("shutdown grace period expired; cancelling queries", "queries", len(s.reg.list()))
		s.abort()
		s.reg.cancelAll()
		waitTimeout(&s.active, 2*time.Second)
		srv.Close()
	}
	s.abort()
	s.log.Info("shutdown complete")
	return nil
}

func waitTimeout(wg *sync.WaitGroup, d time.Duration) {
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(d):
	}
}

// ---------------------------------------------------------------- routing

type handlerFunc func(s *Server, w http.ResponseWriter, r *http.Request, params []string)

// route maps a path pattern ("*" matches one segment) to handlers by method.
type route struct {
	pattern []string
	methods map[string]handlerFunc
}

var routes = []route{
	{[]string{"health"}, map[string]handlerFunc{"GET": (*Server).health}},
	{[]string{"metrics"}, map[string]handlerFunc{"GET": (*Server).metrics}},
	{[]string{"v1", "version"}, map[string]handlerFunc{"GET": (*Server).version}},
	{[]string{"v1", "capabilities"}, map[string]handlerFunc{"GET": (*Server).capabilities}},
	{[]string{"v1", "query"}, map[string]handlerFunc{"POST": (*Server).query}},
	{[]string{"v1", "query", "stream"}, map[string]handlerFunc{"POST": (*Server).queryStream}},
	{[]string{"v1", "explain"}, map[string]handlerFunc{"POST": (*Server).explain}},
	{[]string{"v1", "tables"}, map[string]handlerFunc{"GET": (*Server).tables}},
	{[]string{"v1", "tables", "*"}, map[string]handlerFunc{"PUT": (*Server).putTable, "DELETE": (*Server).dropTable}},
	{[]string{"v1", "tables", "*", "schema"}, map[string]handlerFunc{"GET": (*Server).tableSchema}},
	{[]string{"v1", "tables", "*", "stats"}, map[string]handlerFunc{"GET": (*Server).tableStats}},
	{[]string{"v1", "request"}, map[string]handlerFunc{"POST": (*Server).request}},
	{[]string{"v1", "queries"}, map[string]handlerFunc{"GET": (*Server).listQueries}},
	{[]string{"v1", "queries", "*"}, map[string]handlerFunc{"DELETE": (*Server).cancelQuery}},
}

// ServeHTTP dispatches a request to its route.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.active.Add(1)
	defer s.active.Done()
	segs, ok := splitPath(r.URL.EscapedPath())
	if ok {
		for _, rt := range routes {
			params, matched := match(rt.pattern, segs)
			if !matched {
				continue
			}
			fn, allowed := rt.methods[r.Method]
			if !allowed {
				e := errs.New(errs.InvalidRequest, "method %s is not allowed for %s", r.Method, r.URL.Path)
				writeJSON(w, http.StatusMethodNotAllowed, protocol.ErrorResponse(nil, e))
				return
			}
			fn(s, w, r, params)
			return
		}
	}
	s.writeError(w, errs.New(errs.NotFound, "unknown path %s", r.URL.Path))
}

// splitPath splits an escaped URL path into unescaped segments, ignoring a
// trailing slash.
func splitPath(p string) ([]string, bool) {
	var segs []string
	for len(p) > 0 {
		if p[0] != '/' {
			return nil, false
		}
		p = p[1:]
		end := 0
		for end < len(p) && p[end] != '/' {
			end++
		}
		seg, err := url.PathUnescape(p[:end])
		if err != nil {
			return nil, false
		}
		if seg != "" || end < len(p) {
			segs = append(segs, seg)
		}
		p = p[end:]
	}
	return segs, true
}

func match(pattern, segs []string) ([]string, bool) {
	if len(pattern) != len(segs) {
		return nil, false
	}
	var params []string
	for i, p := range pattern {
		if p == "*" {
			if segs[i] == "" {
				return nil, false
			}
			params = append(params, segs[i])
		} else if p != segs[i] {
			return nil, false
		}
	}
	return params, true
}

// ---------------------------------------------------------------- responses

// statusOf maps an error code to its HTTP status (protocol.md §7.1).
func statusOf(code errs.Code) int {
	switch code {
	case errs.AccessDenied:
		return http.StatusForbidden
	case errs.NotFound:
		return http.StatusNotFound
	case errs.AlreadyExists, errs.Cancelled:
		return http.StatusConflict
	case errs.ResourceLimit:
		return http.StatusRequestEntityTooLarge
	case errs.InternalError, errs.IOError, errs.StorageCorrupt, errs.StorageVersion:
		return http.StatusInternalServerError
	case errs.Overloaded, errs.ShuttingDown:
		return http.StatusServiceUnavailable
	case errs.Timeout:
		return http.StatusGatewayTimeout
	}
	return http.StatusBadRequest
}

func writeJSON(w http.ResponseWriter, status int, body []byte) {
	h := w.Header()
	h.Set("Content-Type", "application/json")
	h.Set("Content-Length", strconv.Itoa(len(body)+1))
	w.WriteHeader(status)
	_, _ = w.Write(append(body, '\n'))
}

// writeError writes an error response.
func (s *Server) writeError(w http.ResponseWriter, e *errs.Error) {
	writeJSON(w, statusOf(e.Code), protocol.ErrorResponse(nil, e))
}

// respond writes the response of a protocol operation with the status of
// its error (if any) or okStatus.
func (s *Server) respond(w http.ResponseWriter, resp []byte, e *errs.Error, okStatus int) {
	if e != nil {
		writeJSON(w, statusOf(e.Code), resp)
		return
	}
	writeJSON(w, okStatus, resp)
}

// readBody reads the request body, enforcing --max-request-bytes.
func (s *Server) readBody(r *http.Request) ([]byte, *errs.Error) {
	max := s.cfg.MaxRequestBytes
	tooLarge := func() *errs.Error {
		// Drain (a bounded amount of) the rest so that the client sees
		// the response instead of a reset connection.
		_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 256<<20))
		return errs.New(errs.ResourceLimit, "request body exceeds the limit of %d bytes", max)
	}
	if r.ContentLength > max {
		return nil, tooLarge()
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, max+1))
	if err != nil {
		return nil, errs.New(errs.InvalidRequest, "cannot read request body: %v", err)
	}
	if int64(len(body)) > max {
		return nil, tooLarge()
	}
	return body, nil
}

// decodeBody reads a JSON request object from the body.
func (s *Server) decodeBody(r *http.Request) (*protocol.Request, *errs.Error) {
	body, e := s.readBody(r)
	if e != nil {
		return nil, e
	}
	return protocol.DecodeRequest(body)
}

// requestContext returns a context cancelled when the client disconnects
// or the shutdown grace period expires.
func (s *Server) requestContext(r *http.Request) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(r.Context())
	stop := context.AfterFunc(s.base, cancel)
	return ctx, func() {
		stop()
		cancel()
	}
}

// refuseIfShutting answers SHUTTING_DOWN once shutdown has begun.
func (s *Server) refuseIfShutting(w http.ResponseWriter) bool {
	if !s.shutting.Load() {
		return false
	}
	s.writeError(w, errs.New(errs.ShuttingDown, "server is shutting down"))
	return true
}

// ---------------------------------------------------------------- endpoints

func (s *Server) health(w http.ResponseWriter, _ *http.Request, _ []string) {
	if s.shutting.Load() {
		writeJSON(w, http.StatusServiceUnavailable, []byte(`{"status":"shutting_down"}`))
		return
	}
	writeJSON(w, http.StatusOK, []byte(`{"status":"ok"}`))
}

func (s *Server) version(w http.ResponseWriter, _ *http.Request, _ []string) {
	writeJSON(w, http.StatusOK, protocol.VersionJSON())
}

func (s *Server) capabilities(w http.ResponseWriter, _ *http.Request, _ []string) {
	writeJSON(w, http.StatusOK, protocol.CapabilitiesJSON())
}

func (s *Server) metrics(w http.ResponseWriter, _ *http.Request, _ []string) {
	running, queued := s.adm.stats()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	s.met.write(w, gauges{running: running, queued: queued, tables: len(s.eng.Catalog().List())})
}

// execute runs a non-query protocol request.
func (s *Server) execute(w http.ResponseWriter, r *http.Request, req *protocol.Request, okStatus int) {
	ctx, cancel := s.requestContext(r)
	defer cancel()
	resp, e := s.h.Execute(ctx, req)
	s.respond(w, resp, e, okStatus)
}

func (s *Server) query(w http.ResponseWriter, r *http.Request, _ []string) {
	if s.refuseIfShutting(w) {
		return
	}
	req, e := s.decodeBody(r)
	if e != nil {
		s.writeError(w, e)
		return
	}
	req.Set("op", "query")
	s.runQuery(w, r, req, false)
}

func (s *Server) queryStream(w http.ResponseWriter, r *http.Request, _ []string) {
	if s.refuseIfShutting(w) {
		return
	}
	req, e := s.decodeBody(r)
	if e != nil {
		s.writeError(w, e)
		return
	}
	req.Set("op", "query")
	s.runQuery(w, r, req, true)
}

func (s *Server) explain(w http.ResponseWriter, r *http.Request, _ []string) {
	if s.refuseIfShutting(w) {
		return
	}
	req, e := s.decodeBody(r)
	if e != nil {
		s.writeError(w, e)
		return
	}
	req.Set("op", "explain")
	s.execute(w, r, req, http.StatusOK)
}

func (s *Server) request(w http.ResponseWriter, r *http.Request, _ []string) {
	if s.refuseIfShutting(w) {
		return
	}
	req, e := s.decodeBody(r)
	if e != nil {
		s.writeError(w, e)
		return
	}
	if req.Op() == "query" {
		s.runQuery(w, r, req, false)
		return
	}
	s.execute(w, r, req, http.StatusOK)
}

func (s *Server) tables(w http.ResponseWriter, r *http.Request, _ []string) {
	s.execute(w, r, protocol.NewRequest("tables", nil), http.StatusOK)
}

func (s *Server) tableSchema(w http.ResponseWriter, r *http.Request, p []string) {
	s.execute(w, r, protocol.NewRequest("schema", map[string]string{"table": p[0]}), http.StatusOK)
}

func (s *Server) tableStats(w http.ResponseWriter, r *http.Request, p []string) {
	s.execute(w, r, protocol.NewRequest("stats", map[string]string{"table": p[0]}), http.StatusOK)
}

func (s *Server) dropTable(w http.ResponseWriter, r *http.Request, p []string) {
	if s.refuseIfShutting(w) {
		return
	}
	s.execute(w, r, protocol.NewRequest("drop", map[string]string{"table": p[0]}), http.StatusOK)
}

func (s *Server) putTable(w http.ResponseWriter, r *http.Request, p []string) {
	if s.refuseIfShutting(w) {
		return
	}
	q := r.URL.Query()
	rl := protocol.RawLoad{Table: p[0], Format: q.Get("format"), Header: true,
		Delimiter: q.Get("delimiter"), Schema: q.Get("schema")}
	if rl.Format == "" {
		s.writeError(w, errs.New(errs.InvalidRequest, "missing query parameter \"format\""))
		return
	}
	var e *errs.Error
	if rl.Replace, e = boolParam(q.Get("replace"), "replace", false); e != nil {
		s.writeError(w, e)
		return
	}
	if rl.Header, e = boolParam(q.Get("header"), "header", true); e != nil {
		s.writeError(w, e)
		return
	}
	if rl.Data, e = s.readBody(r); e != nil {
		s.writeError(w, e)
		return
	}
	resp, e := s.h.LoadRaw(rl)
	s.respond(w, resp, e, http.StatusCreated)
}

func boolParam(v, name string, def bool) (bool, *errs.Error) {
	switch v {
	case "":
		return def, nil
	case "true", "1":
		return true, nil
	case "false", "0":
		return false, nil
	}
	return false, errs.New(errs.InvalidRequest, "query parameter %q must be true or false", name)
}

func (s *Server) listQueries(w http.ResponseWriter, _ *http.Request, _ []string) {
	type entry struct {
		QueryID   string `json:"query_id"`
		State     string `json:"state"`
		ElapsedMS int64  `json:"elapsed_ms"`
	}
	out := struct {
		OK      bool    `json:"ok"`
		Queries []entry `json:"queries"`
	}{OK: true, Queries: []entry{}}
	for _, q := range s.reg.list() {
		state := "queued"
		if q.running.Load() {
			state = "running"
		}
		out.Queries = append(out.Queries, entry{q.id, state, time.Since(q.start).Milliseconds()})
	}
	b, _ := json.Marshal(out)
	writeJSON(w, http.StatusOK, b)
}

func (s *Server) cancelQuery(w http.ResponseWriter, _ *http.Request, p []string) {
	if !s.reg.cancel(p[0]) {
		s.writeError(w, errs.New(errs.NotFound, "no queued or running query with id %q", p[0]))
		return
	}
	s.log.Info("query cancellation requested", "query_id", p[0])
	writeJSON(w, http.StatusOK, []byte(`{"ok":true,"cancelled":true}`))
}

// ---------------------------------------------------------------- queries

// queryRun is the server-side state of one query request.
type queryRun struct {
	s        *Server
	q        *activeQuery
	start    time.Time
	admitted bool
	finished bool
}

// finish releases the query's worker slot and registration and records
// metrics and the completion log event. It is called before the final
// response bytes are written, so that a client seeing the response also
// sees the query gone from /v1/queries.
func (qr *queryRun) finish(rows int64, e *errs.Error) {
	if qr.finished {
		return
	}
	qr.finished = true
	if qr.admitted {
		qr.s.adm.release()
	}
	qr.s.reg.remove(qr.q)
	d := time.Since(qr.start)
	qr.s.met.observe(d, e)
	attrs := []any{"query_id", qr.q.id, "status", "ok", "duration_ms", d.Milliseconds(), "rows", rows}
	if e != nil {
		attrs[3] = "error"
		attrs = append(attrs, "code", string(e.Code))
	}
	qr.s.log.Info("query finished", attrs...)
}

// runQuery executes a query request under admission control, with its
// timeout counted from arrival (queueing included), cancellable through
// DELETE /v1/queries/{id}, client disconnect and shutdown.
func (s *Server) runQuery(w http.ResponseWriter, r *http.Request, req *protocol.Request, stream bool) {
	start := time.Now()
	qo, err := protocol.ParseQueryOptions(req)
	if err != nil {
		e := errs.From(err)
		s.met.observe(time.Since(start), e)
		s.respond(w, protocol.ErrorResponse(req.ID(), e), e, http.StatusOK)
		return
	}
	ctx, cancel := s.requestContext(r)
	defer cancel()
	timeout := qo.Timeout
	if timeout <= 0 {
		timeout = s.cfg.QueryTimeout
	}
	if timeout > 0 {
		var cancelTimeout context.CancelFunc
		ctx, cancelTimeout = context.WithTimeout(ctx, timeout)
		defer cancelTimeout()
	}
	q, err := s.reg.add(qo.QueryID, cancel)
	if err != nil {
		e := errs.From(err)
		s.met.observe(time.Since(start), e)
		s.respond(w, protocol.ErrorResponse(req.ID(), e), e, http.StatusOK)
		return
	}
	w.Header().Set("X-PolyQuery-Query-Id", q.id)
	qr := &queryRun{s: s, q: q, start: start}
	defer qr.finish(0, errs.New(errs.Cancelled, "query was cancelled"))

	if err := s.adm.acquire(ctx); err != nil {
		e := errs.From(err)
		qr.finish(0, e)
		s.respond(w, protocol.ErrorResponse(req.ID(), e), e, http.StatusOK)
		return
	}
	qr.admitted = true
	q.running.Store(true)
	if stream {
		s.stream(ctx, cancel, w, req, qr)
		return
	}
	resp, rows, e := s.h.RunQuery(ctx, req)
	qr.finish(rows, e)
	s.respond(w, resp, e, http.StatusOK)
}

// startQuery starts a streamed query, converting panics to errors.
func (s *Server) startQuery(ctx context.Context, req *protocol.Request) (cur *engine.Cursor, qo engine.QueryOptions, err error) {
	defer func() {
		if r := recover(); r != nil {
			s.log.Error("internal error", "panic", fmt.Sprint(r))
			err = errs.New(errs.InternalError, "internal error: %v", r)
		}
	}()
	return s.h.StartQuery(ctx, req)
}
