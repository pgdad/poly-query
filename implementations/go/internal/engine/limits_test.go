package engine

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"polyquery/internal/errs"
	"polyquery/internal/ingest"
	"polyquery/internal/types"
)

// newNumbers returns an engine with table n(x) = 0..99, split into small
// morsels so that parallel execution really uses several workers.
func newNumbers(t *testing.T) *Engine {
	t.Helper()
	cfg := DefaultConfig()
	cfg.DataDir = t.TempDir()
	cfg.MorselRows = 16
	e := New(cfg)
	var sb strings.Builder
	sb.WriteString("x\n")
	for i := 0; i < 100; i++ {
		fmt.Fprintf(&sb, "%d\n", i)
	}
	data := sb.String()
	if _, err := e.Load(LoadRequest{Table: "n", Data: &data, Options: ingest.DefaultOptions(ingest.CSV)}); err != nil {
		t.Fatal(err)
	}
	return e
}

var limitModes = []QueryOptions{
	{MaxRows: -1, Mode: "row", Threads: 1},
	{MaxRows: -1, Mode: "vectorized", Threads: 1},
	{MaxRows: -1, Mode: "vectorized", Threads: 8},
	{MaxRows: -1, Mode: "row", Threads: 8},
	{MaxRows: -1},
}

func firstCell(t *testing.T, e *Engine, sql string, opts QueryOptions) (string, error) {
	t.Helper()
	res, err := e.Query(context.Background(), sql, opts)
	if err != nil {
		return "", err
	}
	v := res.Rows[0][0]
	if v.Null {
		return "NULL", nil
	}
	return types.FormatValue(v, res.Columns[0].Type), nil
}

func joinTerms(n int, format, sep string) string {
	terms := make([]string, n)
	for i := range terms {
		terms[i] = fmt.Sprintf(format, i)
	}
	return strings.Join(terms, sep)
}

// TestExpressionLimitMinimums runs statements at the CR-6 minimums in
// every execution mode.
func TestExpressionLimitMinimums(t *testing.T) {
	e := newNumbers(t)
	where := func(p string) string { return "SELECT count(*) FROM n WHERE " + p }
	cases := []struct{ sql, want string }{
		{where(strings.Repeat("(", 998) + "x >= 0" + strings.Repeat(")", 998)), "100"},
		{where(strings.Repeat("ABS(", 998) + "x" + strings.Repeat(")", 998) + " >= 0"), "100"},
		{where(strings.Repeat("NOT ", 998) + "x >= 0"), "100"},
		{where(joinTerms(10_000, "x = %d", " OR ")), "100"},
		{where(joinTerms(10_000, "x <> -%d - 1", " AND ")), "100"},
		{"SELECT max(x" + strings.Repeat(" + 1", 9_999) + ") FROM n", "10098"},
		{where("x IN (" + joinTerms(10_000, "%d", ", ") + ")"), "100"},
		{"SELECT sum(CASE " + joinTerms(5_000, "WHEN x = %[1]d THEN %[1]d", " ") + " ELSE 0 END) FROM n", "4950"},
		{"SELECT max(length(CAST(x AS VARCHAR)" + strings.Repeat(" || 'a'", 9_999) + ")) FROM n", "10001"},
		{"SELECT count(*) FROM (SELECT x FROM n GROUP BY x HAVING " + joinTerms(10_000, "x = %d", " OR ") + ") z", "100"},
		{"SELECT count(*) FROM (SELECT x" + strings.Repeat(" + 1", 5_000) + " AS k FROM n GROUP BY x" + strings.Repeat(" + 1", 5_000) + ") z", "100"},
	}
	for _, c := range cases {
		for _, opts := range limitModes {
			got, err := firstCell(t, e, c.sql, opts)
			if err != nil || got != c.want {
				t.Errorf("%s/%d threads: got %s, %v; want %s\n%.80s…", opts.Mode, opts.Threads, got, err, c.want, c.sql)
			}
		}
	}
}

// TestConcatChain checks that an n-ary || chain keeps the semantics of
// nested binary concatenations (NULL operands, evaluation errors).
func TestConcatChain(t *testing.T) {
	e := newNumbers(t)
	cases := []struct{ sql, want string }{
		{"SELECT min('a' || CAST(x AS VARCHAR) || 'b' || 'c') FROM n", "a0bc"},
		{"SELECT max('a' || CAST(NULLIF(x, x) AS VARCHAR) || 'b' || 'c') FROM n", "NULL"},
		{"SELECT max(CAST(x AS VARCHAR) || '-' || CAST(x * 2 AS VARCHAR) || '-' || CAST(x * 3 AS VARCHAR)) FROM n", "99-198-297"},
	}
	for _, c := range cases {
		for _, opts := range limitModes {
			if got, err := firstCell(t, e, c.sql, opts); err != nil || got != c.want {
				t.Errorf("%s/%d threads: %s: got %s, %v; want %s", opts.Mode, opts.Threads, c.sql, got, err, c.want)
			}
		}
	}
	sql := "SELECT max('a' || CAST(10 / (x - x) AS VARCHAR) || 'b' || 'c') FROM n"
	for _, opts := range limitModes {
		if _, err := firstCell(t, e, sql, opts); !errs.Is(err, errs.DivisionByZero) {
			t.Errorf("%s/%d threads: got %v, want DIVISION_BY_ZERO", opts.Mode, opts.Threads, err)
		}
	}
}

// TestBeyondLimits checks RESOURCE_LIMIT naming the measure.
func TestBeyondLimits(t *testing.T) {
	e := newNumbers(t)
	cases := []struct{ sql, measure string }{
		{"SELECT count(*) FROM n WHERE " + strings.Repeat("(", 100_000) + "x >= 0" + strings.Repeat(")", 100_000), "nesting depth"},
		{"SELECT count(*) FROM n WHERE x IN (" + joinTerms(300_000, "%d", ", ") + ")", "operand count"},
	}
	for _, c := range cases {
		_, err := e.Query(context.Background(), c.sql, QueryOptions{MaxRows: -1})
		if !errs.Is(err, errs.ResourceLimit) || !strings.Contains(err.Error(), c.measure) {
			t.Errorf("got %v, want RESOURCE_LIMIT naming %s", err, c.measure)
		}
	}
}

// TestTimeoutCoversEveryStage: the timeout counts from the arrival of the
// request, so a query whose deadline passed before parsing fails with
// TIMEOUT, and a long statement stops promptly in any stage.
func TestTimeoutCoversEveryStage(t *testing.T) {
	e := newNumbers(t)
	_, err := e.Query(context.Background(), "SELECT x FROM n", QueryOptions{
		MaxRows: -1, Timeout: time.Millisecond, Received: time.Now().Add(-time.Second),
	})
	if !errs.Is(err, errs.Timeout) {
		t.Errorf("expired before parsing: got %v", err)
	}
	if _, err := e.Explain(context.Background(), "SELECT x FROM n", QueryOptions{
		Timeout: time.Millisecond, Received: time.Now().Add(-time.Second),
	}); !errs.Is(err, errs.Timeout) {
		t.Errorf("explain expired before parsing: got %v", err)
	}
	sql := "SELECT count(*) FROM n WHERE " + joinTerms(100_000, "x = %d", " OR ")
	for _, timeout := range []time.Duration{time.Millisecond, 20 * time.Millisecond, 100 * time.Millisecond} {
		for _, opts := range limitModes {
			opts.Timeout = timeout
			start := time.Now()
			_, err := e.Query(context.Background(), sql, opts)
			if late := time.Since(start) - timeout; err != nil && (!errs.Is(err, errs.Timeout) || late > time.Second) {
				t.Errorf("%s/%d threads, timeout %v: %v after %v", opts.Mode, opts.Threads, timeout, err, time.Since(start))
			}
		}
	}
}

// TestCTEChain checks that a long chain of CTEs is analyzed in linear time
// and that every CTE is still validated.
func TestCTEChain(t *testing.T) {
	e := newNumbers(t)
	var sb strings.Builder
	sb.WriteString("WITH c0 AS (SELECT x FROM n)")
	for i := 1; i < 5000; i++ {
		fmt.Fprintf(&sb, ", c%d AS (SELECT x FROM c%d)", i, i-1)
	}
	sb.WriteString(" SELECT count(*) FROM c4999")
	start := time.Now()
	if got, err := firstCell(t, e, sb.String(), QueryOptions{MaxRows: -1}); err != nil || got != "100" {
		t.Errorf("5,000 CTEs: got %s, %v", got, err)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("5,000 CTEs took %v", d)
	}
	bad := []string{
		"WITH a AS (SELECT x FROM n), b AS (SELECT y FROM a) SELECT 1",
		"WITH a AS (SELECT x FROM n), b AS (SELECT x FROM a), c AS (SELECT x + 'q' FROM b) SELECT 1",
		"WITH a(p, q) AS (SELECT x FROM n) SELECT 1",
	}
	for _, sql := range bad {
		_, err := e.Query(context.Background(), sql, QueryOptions{MaxRows: -1})
		if !errs.Is(err, errs.SemanticError) && !errs.Is(err, errs.TypeError) {
			t.Errorf("%s: got %v, want a semantic or type error", sql, err)
		}
	}
	// Columns renamed by a CTE's column list keep their names through
	// validation stubs.
	sql := "WITH a(v) AS (SELECT x FROM n), b AS (SELECT v FROM a WHERE v > 90) SELECT count(*) FROM b"
	if got, err := firstCell(t, e, sql, QueryOptions{MaxRows: -1}); err != nil || got != "9" {
		t.Errorf("renamed CTE columns: got %s, %v", got, err)
	}
}

// TestManyJoins: planning a long chain of joins is fast (no quadratic
// schema building or join ordering) and observes the deadline.
func TestManyJoins(t *testing.T) {
	e := newNumbers(t)
	from, conds := make([]string, 1000), make([]string, 999)
	for i := range from {
		from[i] = fmt.Sprintf("n t%d", i)
		if i > 0 {
			conds[i-1] = fmt.Sprintf("t%d.x = t%d.x", i-1, i)
		}
	}
	sql := "SELECT count(*) FROM " + strings.Join(from, ", ") + " WHERE " + strings.Join(conds, " AND ")
	start := time.Now()
	if got, err := firstCell(t, e, sql, QueryOptions{MaxRows: -1}); err != nil || got != "100" {
		t.Errorf("1,000 joined tables: got %s, %v", got, err)
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Errorf("1,000 joined tables took %v", d)
	}
	_, err := e.Query(context.Background(), sql, QueryOptions{MaxRows: -1, Timeout: 20 * time.Millisecond})
	if err != nil && !errs.Is(err, errs.Timeout) {
		t.Errorf("with a 20 ms timeout: %v", err)
	}
}

// TestNestedCorrelatedSubqueries: correlated subqueries nested in each
// other share their memo across evaluations of the enclosing subquery, so
// the work grows polynomially, not exponentially, with the nesting depth.
func TestNestedCorrelatedSubqueries(t *testing.T) {
	e := newNumbers(t)
	const k = 60
	s := fmt.Sprintf("SELECT max(m%d.x) FROM n m%d WHERE m%d.x <= m%d.x", k, k, k, k-1)
	for i := k - 1; i > 1; i-- {
		s = fmt.Sprintf("SELECT max(m%d.x) FROM n m%d WHERE m%d.x <= (%s) AND m%d.x <= m%d.x", i, i, i, s, i, i-1)
	}
	sql := fmt.Sprintf("SELECT count(*) FROM n m0 WHERE m0.x <= (SELECT max(m1.x) FROM n m1 WHERE m1.x <= (%s) AND m1.x <= 49)", s)
	for _, opts := range limitModes {
		opts.Timeout = 30 * time.Second
		if got, err := firstCell(t, e, sql, opts); err != nil || got != "50" {
			t.Errorf("%s/%d threads: got %s, %v; want 50", opts.Mode, opts.Threads, got, err)
		}
	}
}

// TestPlanMemoryBudget: inlining CTEs that reference their predecessor
// twice doubles the plan per CTE; analysis charges the plan against the
// query's memory budget instead of exhausting memory.
func TestPlanMemoryBudget(t *testing.T) {
	cfg := DefaultConfig()
	cfg.DataDir = t.TempDir()
	cfg.MaxQueryMemoryMB = 64
	e := New(cfg)
	var sb strings.Builder
	sb.WriteString("WITH c0 AS (SELECT 1 AS x)")
	for i := 1; i < 40; i++ {
		fmt.Fprintf(&sb, ", c%d AS (SELECT a.x FROM c%d a, c%d b WHERE a.x = b.x)", i, i-1, i-1)
	}
	sb.WriteString(" SELECT count(*) FROM c39")
	_, err := e.Query(context.Background(), sb.String(), QueryOptions{MaxRows: -1})
	if !errs.Is(err, errs.ResourceLimit) || !strings.Contains(err.Error(), "memory budget") {
		t.Fatalf("got %v, want RESOURCE_LIMIT (memory budget)", err)
	}
}
