package parser

import (
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/sql/ast"
)

func mustParse(t *testing.T, sql string) *ast.Query {
	t.Helper()
	stmt, err := Parse(sql)
	if err != nil {
		t.Fatalf("Parse(%q): %v", sql, err)
	}
	q, ok := stmt.(*ast.Query)
	if !ok {
		t.Fatalf("Parse(%q) returned %T", sql, stmt)
	}
	return q
}

func TestPrecedence(t *testing.T) {
	q := mustParse(t, "SELECT 2 + 3 * 4, -2 * 3, NOT a = b, a OR b AND c")
	add := q.Items[0].Expr.(*ast.Binary)
	if add.Op != "+" || add.R.(*ast.Binary).Op != "*" {
		t.Errorf("2 + 3 * 4 parsed wrongly")
	}
	mul := q.Items[1].Expr.(*ast.Binary)
	if mul.Op != "*" || mul.L.(*ast.Unary).Op != "-" {
		t.Errorf("-2 * 3 parsed wrongly")
	}
	not := q.Items[2].Expr.(*ast.Unary)
	if not.Op != "NOT" || not.X.(*ast.Binary).Op != "=" {
		t.Errorf("NOT a = b parsed wrongly")
	}
	or := q.Items[3].Expr.(*ast.Binary)
	if or.Op != "OR" || or.R.(*ast.Binary).Op != "AND" {
		t.Errorf("a OR b AND c parsed wrongly")
	}
}

func TestClauses(t *testing.T) {
	q := mustParse(t, `select p.*, "Full Name" AS x, y z FROM people AS p WHERE a IS NOT NULL ORDER BY 1 DESC NULLS FIRST, b OFFSET 2 LIMIT 3;`)
	if !q.Items[0].Star || q.Items[0].Qualifier != "p" {
		t.Errorf("p.* not parsed")
	}
	if q.Items[2].Alias != "z" {
		t.Errorf("implicit alias not parsed")
	}
	if ref := q.From.(*ast.TableRef); ref.Name != "people" || ref.Alias != "p" {
		t.Errorf("FROM parsed wrongly: %+v", ref)
	}
	if len(q.OrderBy) != 2 || !q.OrderBy[0].Desc || q.OrderBy[0].NullsFirst == nil || !*q.OrderBy[0].NullsFirst {
		t.Errorf("ORDER BY parsed wrongly")
	}
	if q.Limit == nil || q.Offset == nil {
		t.Errorf("LIMIT/OFFSET missing")
	}
}

func TestPhase2Syntax(t *testing.T) {
	for _, sql := range []string{
		"SELECT a, COUNT(DISTINCT b) FROM t GROUP BY a HAVING COUNT(*) > 1",
		"WITH c(x) AS (SELECT 1) SELECT x FROM c",
		"SELECT * FROM a JOIN b ON a.id = b.id LEFT OUTER JOIN c ON c.id = a.id CROSS JOIN d, e",
		"SELECT CASE WHEN a THEN 1 ELSE 2 END, x BETWEEN 1 AND 2, y NOT IN (1, 2), s LIKE 'a%'",
		"SELECT (SELECT 1), EXISTS (SELECT 1) FROM (SELECT 1 AS q) sub WHERE z IN (SELECT 2)",
		"EXPLAIN SELECT 1",
		"CREATE INDEX IF NOT EXISTS i ON t (c) USING HASH",
		"DROP INDEX IF EXISTS i",
		"SELECT CAST(x AS DATE), CAST(y AS DECIMAL(10, 2)), DATE '2024-01-01', TIMESTAMP '2024-01-01 00:00:00'",
	} {
		if _, err := Parse(sql); err != nil {
			t.Errorf("Parse(%q): %v", sql, err)
		}
	}
}

func TestErrors(t *testing.T) {
	cases := map[string]errs.Code{
		"SELECT 1 = 1 = 1":                      errs.ParseError,
		"SELECT a < b IS NULL":                  errs.ParseError,
		"SELEC name FROM people":                errs.ParseError,
		"SELECT name FROM people WHERE":         errs.ParseError,
		"SELECT 'unterminated":                  errs.ParseError,
		"SELECT 1; SELECT 2":                    errs.ParseError,
		"SELECT COUNT(*, id) FROM t":            errs.ParseError,
		"SELECT /* open":                        errs.ParseError,
		"SELECT 1 UNION SELECT 2":               errs.Unsupported,
		"SELECT * FROM a RIGHT JOIN b ON 1 = 1": errs.Unsupported,
	}
	for sql, code := range cases {
		_, err := Parse(sql)
		if !errs.Is(err, code) {
			t.Errorf("Parse(%q) = %v, want %s", sql, err, code)
		}
	}
	_, err := Parse("SELECT 1 +\n  FROM t")
	e := errs.From(err)
	if e.Details["line"] != 2 || e.Details["column"] != 3 {
		t.Errorf("error position = %v", e.Details)
	}
}
