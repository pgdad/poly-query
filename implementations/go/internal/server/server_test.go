package server

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"polyquery/internal/engine"
	"polyquery/internal/errs"
)

func TestAdmissionQueueAndReject(t *testing.T) {
	a := newAdmission(1, 1)
	ctx := context.Background()
	if err := a.acquire(ctx); err != nil {
		t.Fatal(err)
	}
	granted := make(chan error, 1)
	go func() { granted <- a.acquire(ctx) }()
	waitFor(t, func() bool { _, q := a.stats(); return q == 1 })
	if err := a.acquire(ctx); !errs.Is(err, errs.Overloaded) {
		t.Fatalf("third acquire: got %v, want OVERLOADED", err)
	}
	a.release()
	if err := <-granted; err != nil {
		t.Fatalf("queued acquire: %v", err)
	}
	if r, q := a.stats(); r != 1 || q != 0 {
		t.Fatalf("stats = %d running, %d queued", r, q)
	}
	a.release()
	if r, _ := a.stats(); r != 0 {
		t.Fatalf("running = %d after release", r)
	}
}

func TestAdmissionQueuedTimeout(t *testing.T) {
	a := newAdmission(1, 4)
	if err := a.acquire(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := a.acquire(ctx); !errs.Is(err, errs.Timeout) {
		t.Fatalf("got %v, want TIMEOUT", err)
	}
	if _, q := a.stats(); q != 0 {
		t.Fatalf("timed-out waiter still queued")
	}
	a.release()
	if r, _ := a.stats(); r != 0 {
		t.Fatalf("running = %d", r)
	}
}

func TestRegistry(t *testing.T) {
	r := newRegistry()
	cancelled := false
	q, err := r.add("a", func() { cancelled = true })
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.add("a", func() {}); !errs.Is(err, errs.AlreadyExists) {
		t.Fatalf("duplicate id: %v", err)
	}
	gen, err := r.add("", func() {})
	if err != nil || gen.id == "" {
		t.Fatalf("generated id: %v %q", err, gen.id)
	}
	if len(r.list()) != 2 {
		t.Fatalf("list = %d entries", len(r.list()))
	}
	if !r.cancel("a") || !cancelled {
		t.Fatal("cancel failed")
	}
	r.remove(q)
	if r.cancel("a") {
		t.Fatal("cancel of removed query succeeded")
	}
}

func TestSplitPath(t *testing.T) {
	segs, ok := splitPath("/v1/tables/my%20table/schema/")
	if !ok || strings.Join(segs, "|") != "v1|tables|my table|schema" {
		t.Fatalf("got %q %v", segs, ok)
	}
	if p, ok := match([]string{"v1", "tables", "*"}, []string{"v1", "tables", "x"}); !ok || p[0] != "x" {
		t.Fatalf("match failed")
	}
}

func TestStatusOf(t *testing.T) {
	cases := map[errs.Code]int{
		errs.ParseError: 400, errs.AccessDenied: 403, errs.NotFound: 404, errs.Cancelled: 409,
		errs.ResourceLimit: 413, errs.IOError: 500, errs.Overloaded: 503, errs.Timeout: 504,
	}
	for code, want := range cases {
		if got := statusOf(code); got != want {
			t.Errorf("%s: got %d, want %d", code, got, want)
		}
	}
}

// ---------------------------------------------------------------- HTTP

func newTestServer(t *testing.T, cfg Config) (*Server, *httptest.Server) {
	t.Helper()
	ecfg := engine.DefaultConfig()
	ecfg.DataDir = t.TempDir()
	ecfg.TestFunctions = true
	if cfg.Workers == 0 {
		cfg.Workers = 4
	}
	if cfg.QueueDepth == 0 {
		cfg.QueueDepth = 8
	}
	if cfg.MaxRequestBytes == 0 {
		cfg.MaxRequestBytes = 1 << 20
	}
	s := New(engine.New(ecfg), cfg)
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return s, ts
}

func do(t *testing.T, method, url, body string) (int, http.Header, map[string]any) {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%s %s: non-JSON body %q", method, url, raw)
	}
	return resp.StatusCode, resp.Header, out
}

func errorCode(body map[string]any) string {
	e, _ := body["error"].(map[string]any)
	code, _ := e["code"].(string)
	return code
}

func TestHTTPEndpoints(t *testing.T) {
	_, ts := newTestServer(t, Config{MaxRequestBytes: 64})
	if st, _, b := do(t, "GET", ts.URL+"/health", ""); st != 200 || b["status"] != "ok" {
		t.Fatalf("health: %d %v", st, b)
	}
	if st, _, b := do(t, "PUT", ts.URL+"/v1/tables/t?format=csv", "a,b\n1,x\n2,y\n"); st != 201 || b["row_count"] != 2.0 {
		t.Fatalf("put: %d %v", st, b)
	}
	st, h, b := do(t, "POST", ts.URL+"/v1/query", `{"sql":"SELECT a FROM t ORDER BY a","options":{"query_id":"q1"}}`)
	if st != 200 || h.Get("X-PolyQuery-Query-Id") != "q1" || b["row_count"] != 2.0 {
		t.Fatalf("query: %d %v %v", st, h, b)
	}
	if st, _, b := do(t, "POST", ts.URL+"/v1/query", `{"sql":"SELECT nope FROM t"}`); st != 400 || errorCode(b) != "SEMANTIC_ERROR" {
		t.Fatalf("semantic error: %d %v", st, b)
	}
	if st, _, b := do(t, "POST", ts.URL+"/v1/request", `{"op":"schema","table":"zz","id":5}`); st != 404 || b["id"] != 5.0 {
		t.Fatalf("request: %d %v", st, b)
	}
	if st, _, _ := do(t, "GET", ts.URL+"/v1/query", ""); st != 405 {
		t.Fatalf("wrong method: %d", st)
	}
	if st, _, b := do(t, "GET", ts.URL+"/nope", ""); st != 404 || errorCode(b) != "NOT_FOUND" {
		t.Fatalf("unknown path: %d %v", st, b)
	}
	if st, _, b := do(t, "PUT", ts.URL+"/v1/tables/big?format=csv", "a\n"+strings.Repeat("1\n", 100)); st != 413 || errorCode(b) != "RESOURCE_LIMIT" {
		t.Fatalf("too large: %d %v", st, b)
	}
	if st, _, b := do(t, "DELETE", ts.URL+"/v1/queries/none", ""); st != 404 {
		t.Fatalf("cancel unknown: %d %v", st, b)
	}
}

func TestHTTPStream(t *testing.T) {
	_, ts := newTestServer(t, Config{})
	var csv strings.Builder
	csv.WriteString("n\n")
	for i := 0; i < 2500; i++ {
		csv.WriteString("1\n")
	}
	if st, _, b := do(t, "PUT", ts.URL+"/v1/tables/t?format=csv", csv.String()); st != 201 {
		t.Fatalf("put: %d %v", st, b)
	}
	resp, err := http.Post(ts.URL+"/v1/query/stream", "application/json", strings.NewReader(`{"sql":"SELECT n FROM t"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(resp.Header.Get("Content-Type"), "ndjson") {
		t.Fatalf("stream: %d %v", resp.StatusCode, resp.Header)
	}
	var types []string
	rows := 0
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(nil, 1<<20)
	for sc.Scan() {
		var line struct {
			Type     string  `json:"type"`
			Rows     [][]any `json:"rows"`
			RowCount int     `json:"row_count"`
		}
		if err := json.Unmarshal(sc.Bytes(), &line); err != nil {
			t.Fatal(err)
		}
		types = append(types, line.Type)
		rows += len(line.Rows)
		if line.Type == "end" && line.RowCount != 2500 {
			t.Fatalf("end row_count = %d", line.RowCount)
		}
	}
	if rows != 2500 || types[0] != "header" || types[len(types)-1] != "end" {
		t.Fatalf("stream lines %v, %d rows", types, rows)
	}
}

func TestHTTPCancelAndTimeout(t *testing.T) {
	s, ts := newTestServer(t, Config{})
	done := make(chan int, 1)
	go func() {
		st, _, _ := do(t, "POST", ts.URL+"/v1/query", `{"sql":"SELECT PQ_SLEEP(5000)","options":{"query_id":"slow"}}`)
		done <- st
	}()
	waitFor(t, func() bool { return len(s.reg.list()) == 1 })
	if st, _, b := do(t, "DELETE", ts.URL+"/v1/queries/slow", ""); st != 200 || b["cancelled"] != true {
		t.Fatalf("cancel: %d %v", st, b)
	}
	select {
	case st := <-done:
		if st != 409 {
			t.Fatalf("cancelled query status %d", st)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancelled query did not finish")
	}
	if st, _, b := do(t, "POST", ts.URL+"/v1/query", `{"sql":"SELECT PQ_SLEEP(5000)","options":{"timeout_ms":30}}`); st != 504 || errorCode(b) != "TIMEOUT" {
		t.Fatalf("timeout: %d %v", st, b)
	}
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not reached")
		}
		time.Sleep(5 * time.Millisecond)
	}
}
