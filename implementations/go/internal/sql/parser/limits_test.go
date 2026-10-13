package parser

import (
	"context"
	"strings"
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/interrupt"
)

// depthLimit parses sql with only the nesting depth limited.
func depthLimit(sql string, max int) error {
	_, err := ParseWith(sql, Options{Limits: Limits{MaxDepth: max}})
	return err
}

func where(pred string) string { return "SELECT count(*) FROM n WHERE " + pred }

// TestNestingDepthMeasure checks the CR-6 measure: each construct adds a
// level, a chain of one precedence level adds one level whatever its length.
func TestNestingDepthMeasure(t *testing.T) {
	cases := []struct {
		sql   string
		depth int
	}{
		{"SELECT x FROM n", 0},
		{where("x >= 0"), 1},
		{where(strings.Repeat("(", 998) + "x >= 0" + strings.Repeat(")", 998)), 999},
		{where(strings.Repeat("ABS(", 998) + "x" + strings.Repeat(")", 998) + " >= 0"), 999},
		{where(strings.Repeat("- ", 998) + "x >= 0"), 999},
		{where(strings.Repeat("NOT ", 998) + "x >= 0"), 999},
		{where("x = 1 OR x = 2 OR x = 3 OR x = 4"), 2},                 // chain + comparison
		{"SELECT x + 1 - 2 + 3 FROM n", 1},                             // one chain
		{"SELECT (x + 1) + 2 FROM n", 3},                               // chain, parens, chain
		{"SELECT x * 2 + 1 FROM n", 2},                                 // two precedence levels
		{where("x = 1 AND y = 2 OR z = 3"), 3},                         // OR chain, AND chain, comparison
		{where("x IN (1, 2, 3)"), 1},                                   // IN
		{where("x IN (SELECT y FROM m WHERE y > 0)"), 2},               // IN subquery, comparison
		{"SELECT CASE WHEN x > 0 THEN ABS(x) END FROM n", 2},           // CASE, comparison / call
		{"SELECT CAST(x AS VARCHAR) FROM n", 1},                        // CAST
		{"SELECT (SELECT (SELECT 1)) FROM n", 2},                       // scalar subqueries
		{"SELECT * FROM (SELECT * FROM (SELECT x FROM n) a) b", 2},     // derived tables
		{"WITH c AS (SELECT x FROM n WHERE x > 0) SELECT x FROM c", 2}, // CTE, comparison
		{where("x BETWEEN 1 AND ABS(y)"), 2},                           // BETWEEN, call
		{where("x IS NULL"), 0},                                        // IS NULL is not a level
	}
	for _, c := range cases {
		if err := depthLimit(c.sql, c.depth); err != nil {
			t.Errorf("depth %d: %v\n%.80s", c.depth, err, c.sql)
		}
		if c.depth <= 1 {
			continue // a limit of 0 is no limit
		}
		err := depthLimit(c.sql, c.depth-1)
		if !errs.Is(err, errs.ResourceLimit) || !strings.Contains(err.Error(), "nesting depth exceeds") {
			t.Errorf("depth %d with limit %d: got %v\n%.80s", c.depth, c.depth-1, err, c.sql)
		}
	}
}

// TestLimitsStopEarly checks that statements far beyond the limits fail
// with RESOURCE_LIMIT without exhausting the stack or memory.
func TestLimitsStopEarly(t *testing.T) {
	deep := where(strings.Repeat("(", 5_000_000) + "x" + strings.Repeat(")", 5_000_000))
	if _, err := Parse(deep); !errs.Is(err, errs.ResourceLimit) || !strings.Contains(err.Error(), "nesting depth exceeds 4096") {
		t.Errorf("5,000,000 parentheses: %v", err)
	}
	wide := where("x IN (" + strings.Repeat("1, ", 300_000) + "1)")
	if _, err := Parse(wide); !errs.Is(err, errs.ResourceLimit) || !strings.Contains(err.Error(), "operand count exceeds 250000") {
		t.Errorf("300,001 operands: %v", err)
	}
	long := where("'" + strings.Repeat("a", 17<<20) + "' = ''")
	if _, err := Parse(long); !errs.Is(err, errs.ResourceLimit) || !strings.Contains(err.Error(), "text length") {
		t.Errorf("17 MiB text: %v", err)
	}
	joins := "SELECT 1 FROM " + strings.Repeat("(", 5000) + "n" + strings.Repeat(")", 5000)
	if _, err := Parse(joins); !errs.Is(err, errs.ResourceLimit) {
		t.Errorf("5,000 parenthesized FROM items: %v", err)
	}
}

// TestMinimums checks that statements at the CR-6 minimums parse.
func TestMinimums(t *testing.T) {
	terms := make([]string, 10_000)
	for i := range terms {
		terms[i] = "x = 1"
	}
	for _, sql := range []string{
		where(strings.Join(terms, " OR ")),
		where("x IN (" + strings.Repeat("1, ", 24_998) + "1)"),
		where(strings.Repeat("(", 999) + "x" + strings.Repeat(")", 999)),
		where("'" + strings.Repeat("a", 1<<20) + "' = x"),
	} {
		if _, err := Parse(sql); err != nil {
			t.Errorf("%.60s…: %v", sql, err)
		}
	}
}

// TestOperandCount counts literals, column references and * arguments.
func TestOperandCount(t *testing.T) {
	sql := "SELECT count(*), a + 1, 'x', NULL, TRUE, DATE '2020-01-01' FROM t WHERE t.b IN (1, 2)"
	// count(*), a, 1, 'x', NULL, TRUE, DATE, t.b, 1, 2
	if _, err := ParseWith(sql, Options{Limits: Limits{MaxOperands: 10}}); err != nil {
		t.Errorf("10 operands within a limit of 10: %v", err)
	}
	if _, err := ParseWith(sql, Options{Limits: Limits{MaxOperands: 9}}); !errs.Is(err, errs.ResourceLimit) {
		t.Errorf("10 operands beyond a limit of 9: %v", err)
	}
}

// TestLexicalErrorPrecedence: tokens are read lazily, but a lexical error
// later in the text is still reported in preference to a syntax error.
func TestLexicalErrorPrecedence(t *testing.T) {
	_, err := Parse("SELECT FROM WHERE 'unterminated")
	e := errs.From(err)
	if e == nil || e.Code != errs.ParseError || !strings.Contains(e.Message, "unterminated") {
		t.Fatalf("got %v", err)
	}
	if _, err := Parse("SELECT 1 FROM t WHERE x = 1 #"); err == nil || !strings.Contains(err.Error(), "unexpected character") {
		t.Fatalf("got %v", err)
	}
}

// TestParseObservesDeadline: an expired context stops the parse with TIMEOUT.
func TestParseObservesDeadline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 0)
	defer cancel()
	sql := where("x IN (" + strings.Repeat("1, ", 20_000) + "1)")
	_, err := ParseWith(sql, Options{Limits: DefaultLimits, Interrupt: interrupt.New(ctx)})
	if !errs.Is(err, errs.Timeout) {
		t.Fatalf("got %v", err)
	}
}
