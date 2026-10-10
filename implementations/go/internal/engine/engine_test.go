package engine

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"polyquery/internal/errs"
	"polyquery/internal/ingest"
	"polyquery/internal/types"
)

const people = `id,name,age,score,joined
1,Alice,34,88.5,2020-01-15
2,Bob,28,72.25,2021-03-01
3,Carol,,91.0,2019-07-30
4,dave,52,,
`

func newEngine(t *testing.T) *Engine {
	t.Helper()
	cfg := DefaultConfig()
	cfg.DataDir = t.TempDir()
	cfg.TestFunctions = true
	e := New(cfg)
	data := people
	if _, err := e.Load(LoadRequest{Table: "people", Data: &data, Options: ingest.DefaultOptions(ingest.CSV)}); err != nil {
		t.Fatal(err)
	}
	return e
}

// render formats a result as "col:TYPE,…|v,v|v,v" for compact assertions.
func render(r *Result) string {
	var sb strings.Builder
	for i, c := range r.Columns {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(c.Name + ":" + c.Type.ResultName())
	}
	for _, row := range r.Rows {
		sb.WriteByte('|')
		for i, v := range row {
			if i > 0 {
				sb.WriteByte(',')
			}
			if v.Null {
				sb.WriteString("null")
			} else {
				sb.WriteString(types.FormatValue(v, r.Columns[i].Type))
			}
		}
	}
	return sb.String()
}

func TestQueries(t *testing.T) {
	e := newEngine(t)
	cases := map[string]string{
		"SELECT name FROM people WHERE age > 30 ORDER BY age DESC":                            "name:STRING|dave|Alice",
		"SELECT id, age FROM people ORDER BY age, id":                                         "id:INT64,age:INT64|3,null|2,28|1,34|4,52",
		"SELECT id FROM people ORDER BY age DESC NULLS FIRST LIMIT 2":                         "id:INT64|3|4",
		"SELECT id FROM people ORDER BY id LIMIT 2 OFFSET 1":                                  "id:INT64|2|3",
		"SELECT COUNT(*), COUNT(age), SUM(age), MIN(name), MAX(joined), AVG(age) FROM people": "_col1:INT64,_col2:INT64,_col3:INT64,_col4:STRING,_col5:DATE,_col6:FLOAT64|4,3,114,Alice,2021-03-01,38.0",
		"SELECT COUNT(*) AS n FROM people WHERE id > 100":                                     "n:INT64|0",
		"SELECT p.name AS who, age + 1 FROM people p WHERE p.id = 1":                          "who:STRING,_col2:INT64|Alice,35",
		"SELECT 1.25 * 2.5, 10.00 / 4, -7 % 3, CAST('1.005' AS DECIMAL(4,2))":                 "_col1:DECIMAL(18,3),_col2:FLOAT64,_col3:INT64,_col4:DECIMAL(4,2)|3.125,2.5,-1,1.01",
		"SELECT NULL AS x, NULL AND FALSE, 1 WHERE TRUE":                                      "x:STRING,_col2:BOOLEAN,_col3:INT64|null,false,1",
		"SELECT name FROM people ORDER BY score * -1 NULLS LAST LIMIT 1":                      "name:STRING|Carol",
		"SELECT PQ_SLEEP(1) AS s":                                                             "s:INT64|1",
	}
	for sql, want := range cases {
		res, err := e.Query(context.Background(), sql, QueryOptions{MaxRows: -1})
		if err != nil {
			t.Errorf("%s: %v", sql, err)
			continue
		}
		if got := render(res); got != want {
			t.Errorf("%s:\n got  %s\n want %s", sql, got, want)
		}
	}
}

func TestQueryErrors(t *testing.T) {
	e := newEngine(t)
	cases := map[string]errs.Code{
		"SELECT nope FROM people":                  errs.SemanticError,
		"SELECT name FROM nope":                    errs.SemanticError,
		"SELECT name, COUNT(*) FROM people":        errs.SemanticError,
		"SELECT id FROM people WHERE COUNT(*) > 1": errs.SemanticError,
		"SELECT SUM(COUNT(*)) FROM people":         errs.SemanticError,
		"SELECT id FROM people ORDER BY 3":         errs.SemanticError,
		"SELECT id FROM people LIMIT id":           errs.SemanticError,
		"SELECT * ":                                errs.SemanticError,
		"SELECT SUM(name) FROM people":             errs.TypeError,
		"SELECT 1 = '1'":                           errs.TypeError,
		"SELECT id FROM people WHERE age":          errs.TypeError,
		"SELECT 1.5 % 2":                           errs.TypeError,
		"SELECT CAST(1 AS DATE)":                   errs.TypeError,
		"SELECT CAST(1 AS WIDGET)":                 errs.SemanticError,
		"SELECT id FROM people LIMIT -1":           errs.InvalidArgument,
		"SELECT 9223372036854775807 + 1":           errs.NumericOverflow,
		"SELECT 9223372036854775808":               errs.NumericOverflow,
		"SELECT 1 / 0":                             errs.DivisionByZero,
		"SELECT DATE '2023-02-29'":                 errs.ConversionError,
		"SELECT UPPER(name) FROM people":           errs.Unsupported,
		"SELECT DISTINCT name FROM people":         errs.Unsupported,
	}
	for sql, code := range cases {
		_, err := e.Query(context.Background(), sql, QueryOptions{MaxRows: -1})
		if !errs.Is(err, code) {
			t.Errorf("%s: got %v, want %s", sql, err, code)
		}
	}
}

func TestLimits(t *testing.T) {
	e := newEngine(t)
	if _, err := e.Query(context.Background(), "SELECT id FROM people", QueryOptions{MaxRows: 3}); !errs.Is(err, errs.ResourceLimit) {
		t.Errorf("max_rows: got %v", err)
	}
	res, err := e.Query(context.Background(), "SELECT id FROM people", QueryOptions{MaxRows: 4, CountOnly: true})
	if err != nil || res.RowCount != 4 || res.Rows != nil {
		t.Errorf("count-only: %v %+v", err, res)
	}
	start := time.Now()
	_, err = e.Query(context.Background(), "SELECT PQ_SLEEP(5000)", QueryOptions{MaxRows: -1, Timeout: 30 * time.Millisecond})
	if !errs.Is(err, errs.Timeout) || time.Since(start) > 2*time.Second {
		t.Errorf("timeout: got %v after %v", err, time.Since(start))
	}
}

func TestLoadPaths(t *testing.T) {
	e := newEngine(t)
	dir := e.Config().DataDir
	if err := os.WriteFile(filepath.Join(dir, "x.csv"), []byte("a\n1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	opts := ingest.DefaultOptions(ingest.CSV)
	if _, err := e.Load(LoadRequest{Table: "x", Path: "x.csv", Options: opts}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Load(LoadRequest{Table: "X", Path: "x.csv", Options: opts}); !errs.Is(err, errs.AlreadyExists) {
		t.Errorf("duplicate load: %v", err)
	}
	for _, p := range []string{"/etc/passwd", "../x.csv", "a/../../x.csv", ""} {
		if _, err := e.Load(LoadRequest{Table: "y", Path: p, Options: opts}); !errs.Is(err, errs.AccessDenied) {
			t.Errorf("path %q: %v", p, err)
		}
	}
	if _, err := e.Load(LoadRequest{Table: "y", Path: "missing.csv", Options: opts}); !errs.Is(err, errs.NotFound) {
		t.Errorf("missing file: %v", err)
	}
}
