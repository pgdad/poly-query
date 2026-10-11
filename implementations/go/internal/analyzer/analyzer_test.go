package analyzer

import (
	"strings"
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/parser"
	"polyquery/internal/testutil"
	"polyquery/internal/types"
)

func analyze(t *testing.T, sql string) (plan.Node, error) {
	t.Helper()
	stmt, err := parser.Parse(sql)
	if err != nil {
		t.Fatalf("%s: parse: %v", sql, err)
	}
	cfg := Config{EvalConst: func(e plan.Expr) (types.Value, error) {
		if l, ok := e.(*plan.Literal); ok {
			return l.Val, nil
		}
		return types.NullValue, errs.New(errs.InternalError, "not a literal")
	}}
	return AnalyzeQuery(stmt.(*ast.Query), testutil.Catalog(t), cfg)
}

func schemaString(n plan.Node) string {
	var parts []string
	for _, c := range n.Schema() {
		parts = append(parts, c.Name+":"+c.Type.ResultName())
	}
	return strings.Join(parts, ",")
}

func TestOutputSchema(t *testing.T) {
	cases := map[string]string{
		"SELECT * FROM emp e JOIN dept d ON e.dept = d.code":          "id:INT64,name:STRING,dept:STRING,salary:INT64,boss:INT64,code:STRING,title:STRING",
		"SELECT d.*, 1 FROM dept d":                                   "code:STRING,title:STRING,_col3:INT64",
		"SELECT dept, COUNT(*), AVG(salary) AS a FROM emp GROUP BY 1": "dept:STRING,_col2:INT64,a:FLOAT64",
		"WITH t(x) AS (SELECT name FROM emp) SELECT x FROM t":         "x:STRING",
		"SELECT s.n FROM (SELECT COUNT(*) AS n FROM emp) s":           "n:INT64",
		"SELECT CASE WHEN id > 1 THEN 1 ELSE 2.5 END FROM emp":        "_col1:DECIMAL(18,1)",
		"SELECT COALESCE(salary, 1.5e0), NULLIF(name, 'x') FROM emp":  "_col1:FLOAT64,_col2:STRING",
		"SELECT ROUND(1.2345, 2), FLOOR(2.5), ROUND(7, -1)":           "_col1:DECIMAL(18,2),_col2:DECIMAL(18,0),_col3:INT64",
		"SELECT (SELECT MAX(salary) FROM emp), EXISTS (SELECT 1)":     "_col1:INT64,_col2:BOOLEAN",
		"SELECT name FROM emp ORDER BY salary DESC LIMIT 2":           "name:STRING",
		"SELECT DISTINCT dept AS d FROM emp ORDER BY d":               "d:STRING",
		"SELECT salary / 10 AS band, COUNT(*) FROM emp GROUP BY band": "band:INT64,_col2:INT64",
		"SELECT DATE_TRUNC('month', DATE '2024-02-03'), YEAR(NULL)":   "_col1:TIMESTAMP,_col2:INT64",
	}
	for sql, want := range cases {
		n, err := analyze(t, sql)
		if err != nil {
			t.Errorf("%s: %v", sql, err)
			continue
		}
		if got := schemaString(n); got != want {
			t.Errorf("%s:\n got %s\nwant %s", sql, got, want)
		}
	}
}

func TestErrors(t *testing.T) {
	cases := map[string]errs.Code{
		"SELECT name FROM emp GROUP BY dept":                       errs.SemanticError,
		"SELECT dept FROM emp GROUP BY dept HAVING salary > 1":     errs.SemanticError,
		"SELECT salary + 1 FROM emp GROUP BY salary + 2":           errs.SemanticError,
		"SELECT COUNT(*) FROM emp GROUP BY COUNT(*)":               errs.SemanticError,
		"SELECT id FROM emp WHERE COUNT(*) > 1":                    errs.SemanticError,
		"SELECT MAX(MIN(id)) FROM emp":                             errs.SemanticError,
		"SELECT DISTINCT name FROM emp ORDER BY salary":            errs.SemanticError,
		"SELECT name FROM emp e JOIN dept e ON 1 = 1":              errs.SemanticError,
		"SELECT x FROM emp JOIN dept ON emp.dept = dept.code, emp": errs.SemanticError,
		"SELECT code FROM dept a, dept b":                          errs.SemanticError,
		"WITH a AS (SELECT * FROM a) SELECT 1":                     errs.SemanticError,
		"WITH a AS (SELECT 1), a AS (SELECT 2) SELECT 1":           errs.SemanticError,
		"WITH a(x, y) AS (SELECT 1) SELECT 1":                      errs.SemanticError,
		"SELECT (SELECT id, name FROM emp)":                        errs.SemanticError,
		"SELECT id IN (SELECT name FROM emp) FROM emp":             errs.TypeError,
		"SELECT * FROM emp JOIN dept ON emp.id":                    errs.TypeError,
		"SELECT CASE WHEN TRUE THEN 1 ELSE 'a' END":                errs.TypeError,
		"SELECT 1 LIKE 'a'":                                        errs.TypeError,
		"SELECT 'a' BETWEEN 1 AND 2":                               errs.TypeError,
		"SELECT ROUND(1.5, id) FROM emp":                           errs.SemanticError,
		"SELECT DATE_TRUNC('week', DATE '2024-01-01')":             errs.InvalidArgument,
		"SELECT HOUR(DATE '2024-01-01')":                           errs.TypeError,
		"SELECT CONCAT('a', 1.5e0)":                                errs.TypeError,
		"SELECT LENGTH('a', 'b')":                                  errs.SemanticError,
		"SELECT nope(1)":                                           errs.SemanticError,
		"SELECT PQ_SLEEP(1)":                                       errs.SemanticError,
		"SELECT name FROM emp ORDER BY 3":                          errs.SemanticError,
		"SELECT name FROM emp GROUP BY 2":                          errs.SemanticError,
		"SELECT name AS x, id AS x FROM emp ORDER BY x":            errs.SemanticError,
		"SELECT id FROM emp LIMIT id":                              errs.SemanticError,
		"SELECT * FROM (SELECT 1 AS a, 2 AS a) t WHERE t.a = 1":    errs.SemanticError,
		"SELECT COUNT(DISTINCT id, name) FROM emp":                 errs.SemanticError,
	}
	for sql, code := range cases {
		_, err := analyze(t, sql)
		if !errs.Is(err, code) {
			t.Errorf("%s: got %v, want %s", sql, err, code)
		}
	}
}

func TestCorrelation(t *testing.T) {
	n, err := analyze(t, "SELECT name, (SELECT COUNT(*) FROM emp r WHERE r.boss = e.id) FROM emp e")
	if err != nil {
		t.Fatal(err)
	}
	var sub *plan.Subquery
	for _, e := range n.(*plan.Project).Exprs {
		plan.Walk(e, func(x plan.Expr) {
			if s, ok := x.(*plan.Subquery); ok {
				sub = s
			}
		})
	}
	if sub == nil || len(sub.Correlated) != 1 || sub.Correlated[0].Name != "id" {
		t.Fatalf("expected a subquery correlated on e.id, got %+v", sub)
	}
	// Grouped outer references are redirected to the group key.
	if _, err := analyze(t, "SELECT dept, (SELECT COUNT(*) FROM emp r WHERE r.dept = e.dept) FROM emp e GROUP BY dept"); err != nil {
		t.Fatal(err)
	}
	if _, err := analyze(t, "SELECT dept, (SELECT COUNT(*) FROM emp r WHERE r.id = e.id) FROM emp e GROUP BY dept"); !errs.Is(err, errs.SemanticError) {
		t.Fatalf("ungrouped correlated column: %v", err)
	}
}

func TestUnionAll(t *testing.T) {
	schemas := map[string]string{
		"SELECT id AS k, name FROM emp UNION ALL SELECT 1, title FROM dept":                       "k:INT64,name:STRING",
		"SELECT id FROM emp UNION ALL SELECT 2.5 UNION ALL SELECT 1.25":                           "id:DECIMAL(18,2)",
		"SELECT 1.5 AS v UNION ALL SELECT 2e0":                                                    "v:FLOAT64",
		"SELECT NULL AS x UNION ALL SELECT 'a'":                                                   "x:STRING",
		"SELECT NULL AS x UNION ALL SELECT NULL":                                                  "x:STRING", // as SELECT NULL
		"SELECT x FROM (SELECT 1 AS x UNION ALL SELECT NULL) s ORDER BY x":                        "x:INT64",
		"WITH u AS (SELECT id FROM emp UNION ALL SELECT id FROM emp) SELECT COUNT(*) AS n FROM u": "n:INT64",
		"SELECT name FROM emp UNION ALL SELECT title FROM dept ORDER BY name DESC LIMIT 2":        "name:STRING",
	}
	for sql, want := range schemas {
		n, err := analyze(t, sql)
		if err != nil {
			t.Errorf("%s: %v", sql, err)
			continue
		}
		if got := schemaString(n); got != want {
			t.Errorf("%s:\n got %s\nwant %s", sql, got, want)
		}
	}
	errors := map[string]errs.Code{
		"SELECT id, name FROM emp UNION ALL SELECT id FROM emp":                     errs.SemanticError,
		"SELECT name FROM emp UNION ALL SELECT id FROM emp":                         errs.TypeError,
		"SELECT DATE '2024-01-01' UNION ALL SELECT TIMESTAMP '2024-01-01 00:00:00'": errs.TypeError,
		"SELECT id FROM emp UNION ALL SELECT id FROM emp ORDER BY id + 1":           errs.SemanticError,
		"SELECT id FROM emp UNION ALL SELECT id FROM emp ORDER BY emp.id":           errs.SemanticError,
		"SELECT id FROM emp UNION ALL SELECT id FROM emp ORDER BY salary":           errs.SemanticError,
		"SELECT id FROM emp UNION ALL SELECT id FROM emp ORDER BY 2":                errs.SemanticError,
		"SELECT id AS a, name AS a FROM emp UNION ALL SELECT 1, 'x' ORDER BY a":     errs.SemanticError,
		"SELECT id FROM emp UNION ALL SELECT nope FROM emp":                         errs.SemanticError,
		"SELECT (SELECT id FROM emp UNION ALL SELECT id, id FROM emp)":              errs.SemanticError,
	}
	for sql, code := range errors {
		if _, err := analyze(t, sql); !errs.Is(err, code) {
			t.Errorf("%s: got %v, want %s", sql, err, code)
		}
	}
	// The plan is a UnionAll with one input per branch; a branch whose
	// types differ from the result is converted by a projection.
	n, err := analyze(t, "SELECT id FROM emp UNION ALL SELECT 2.5 UNION ALL SELECT salary FROM emp")
	if err != nil {
		t.Fatal(err)
	}
	u, ok := n.(*plan.UnionAll)
	if !ok || len(u.Inputs) != 3 {
		t.Fatalf("expected a 3-input UnionAll, got %T", n)
	}
	for i, in := range u.Inputs {
		if got := in.Schema()[0].Type; got != u.Cols[0].Type {
			t.Errorf("branch %d produces %s, want %s", i, got, u.Cols[0].Type)
		}
	}
}
