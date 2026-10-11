package engine

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/ingest"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// newModesEngine loads a few thousand generated rows (NULLs, low-cardinality
// strings that get dictionary-encoded, decimals, dates) with tiny row
// groups' worth of morsels so that parallel execution kicks in.
func newModesEngine(t *testing.T) *Engine {
	t.Helper()
	cfg := DefaultConfig()
	cfg.DataDir = t.TempDir()
	cfg.MorselRows = 97
	e := New(cfg)
	var sb strings.Builder
	sb.WriteString("id,grp,cat,amount,price,day,flag\n")
	cats := []string{"red", "green", "blue", "", "black"}
	for i := 1; i <= 3000; i++ {
		grp := ""
		if i%7 != 0 {
			grp = fmt.Sprint(i % 13)
		}
		fmt.Fprintf(&sb, "%d,%s,%s,%d.%02d,%g,2024-%02d-%02d,%t\n",
			i, grp, cats[i%5], i%500, i%100, float64(i%37)/4, 1+i%12, 1+i%28, i%3 == 0)
	}
	data := sb.String()
	opts := ingest.DefaultOptions(ingest.CSV)
	if _, err := e.Load(LoadRequest{Table: "t", Data: &data, Options: opts}); err != nil {
		t.Fatal(err)
	}
	dim := "grp,label\n0,zero\n1,one\n2,two\n3,three\n5,five\n8,eight\n8,acht\n"
	if _, err := e.Load(LoadRequest{Table: "d", Data: &dim, Options: opts}); err != nil {
		t.Fatal(err)
	}
	return e
}

type modeConfig struct {
	mode, join string
	threads    int
	optimize   bool
}

var modeMatrix = []modeConfig{
	{"row", "nested_loop", 1, false},
	{"row", "hash", 1, true},
	{"row", "merge", 4, true},
	{"vectorized", "hash", 4, true},
	{"vectorized", "merge", 1, false},
	{"vectorized", "nested_loop", 3, true},
	{"auto", "auto", 8, true},
}

// canonical renders a result with its rows sorted (or an error code).
func canonical(e *Engine, sql string, c modeConfig) string {
	res, err := e.Query(context.Background(), sql, QueryOptions{
		MaxRows: -1, Mode: c.mode, Join: c.join, Threads: c.threads, NoOptimize: !c.optimize,
	})
	if err != nil {
		return "error " + string(errs.From(err).Code)
	}
	// FLOAT64 sums may differ in the last bits (summation order is
	// implementation-defined): compare 10 significant digits.
	parts := []string{}
	for _, c := range res.Columns {
		parts = append(parts, c.Name+":"+c.Type.ResultName())
	}
	header := strings.Join(parts, ",")
	var rows []string
	for _, row := range res.Rows {
		cells := make([]string, len(row))
		for i, v := range row {
			switch {
			case v.Null:
				cells[i] = "null"
			case res.Columns[i].Type.Kind == types.KindFloat64:
				cells[i] = strconv.FormatFloat(v.F, 'g', 10, 64)
			default:
				cells[i] = types.FormatValue(v, res.Columns[i].Type)
			}
		}
		rows = append(rows, strings.Join(cells, ","))
	}
	sort.Strings(rows)
	return header + "|" + strings.Join(rows, "|")
}

func TestExecutionModesAgree(t *testing.T) {
	e := newModesEngine(t)
	queries := []string{
		"SELECT COUNT(*), SUM(amount), AVG(price), MIN(day), MAX(cat), COUNT(grp) FROM t",
		"SELECT grp, COUNT(*), SUM(amount), MIN(price), MAX(price), AVG(amount) FROM t GROUP BY grp",
		"SELECT cat, grp, COUNT(DISTINCT price), SUM(DISTINCT id % 10) FROM t WHERE flag GROUP BY cat, grp",
		"SELECT UPPER(cat) AS u, COUNT(*) FROM t GROUP BY UPPER(cat)",
		"SELECT id, amount * 2, price / 3, id % 7, -id FROM t WHERE amount > 100.5 AND cat <> 'red'",
		"SELECT id FROM t WHERE grp IS NULL OR (price BETWEEN 2 AND 3 AND cat IN ('blue', 'black'))",
		"SELECT id, CASE WHEN grp IS NULL THEN 'none' ELSE cat END FROM t WHERE cat LIKE 'b%'",
		"SELECT t.id, d.label FROM t JOIN d ON CAST(t.grp AS INT64) = d.grp WHERE t.id < 200",
		"SELECT t.id, d.label FROM t LEFT JOIN d ON CAST(t.grp AS INT64) = d.grp AND d.label <> 'two' WHERE t.id < 300",
		"SELECT d.label, COUNT(*), SUM(t.amount) FROM t JOIN d ON CAST(t.grp AS INT64) = d.grp GROUP BY d.label",
		"SELECT DISTINCT cat, flag FROM t",
		"SELECT id, amount FROM t ORDER BY amount DESC, id LIMIT 17",
		"SELECT id FROM t WHERE id > 2990 ORDER BY id LIMIT 5 OFFSET 2",
		"SELECT COUNT(*) FROM t a, d b, d c WHERE CAST(a.grp AS INT64) = b.grp AND b.grp = c.grp",
		"SELECT SUM(id * 3074457345618258602) FROM t",
		"SELECT id / (id - id) FROM t",
		"SELECT COUNT(*) FROM t WHERE 1 / (id - 1500) > 0",
		"SELECT COUNT(*) FROM t WHERE id <> 1500 AND 1 / (id - 1500) > 0",
		"SELECT grp FROM t WHERE id IN (SELECT grp FROM d) ORDER BY grp",
		"SELECT COUNT(*) FROM t WHERE NULL",
		"SELECT id FROM t WHERE TRUE AND id < 3",
		"SELECT COUNT(*), SUM(amount), MAX(cat) FROM t WHERE id < 0",
		"SELECT grp, COUNT(*) FROM t WHERE id < 0 GROUP BY grp",
		"SELECT id FROM t ORDER BY id LIMIT 0",
		"SELECT id FROM t ORDER BY id DESC LIMIT 5 OFFSET 2990",
		"SELECT COUNT(*) FROM t JOIN d ON CAST(t.grp AS INT64) = d.grp",
		"SELECT COUNT(*) FROM t CROSS JOIN d WHERE t.id < 10",
		"SELECT id FROM t WHERE EXISTS (SELECT 1 FROM d WHERE d.grp = t.id) ORDER BY id",
		"SELECT id, (SELECT MAX(label) FROM d WHERE d.grp = t.id % 13) FROM t WHERE id < 40",
		"SELECT d.label, (SELECT COUNT(*) FROM t WHERE t.cat = 'red') FROM d",
		"SELECT t.id FROM t LEFT JOIN d ON CAST(t.grp AS INT64) = d.grp WHERE d.grp IS NULL AND t.id < 100",
		"SELECT cat, SUM(price) FILTERED FROM t GROUP BY cat",
		"SELECT COALESCE(grp, 'none'), NULLIF(cat, 'red'), ROUND(price, 1) FROM t WHERE id % 97 = 0",
		"WITH x AS (SELECT grp, COUNT(*) AS n FROM t GROUP BY grp) SELECT a.grp, a.n + b.n FROM x a JOIN x b ON a.grp = b.grp",
		// Vectorized evaluation fails (100 / 0) where row-at-a-time
		// evaluation skips the operand (grp is NULL): batches are then
		// evaluated row by row.
		"SELECT NULLIF(grp, 100 / (id % 7)) AS k, COUNT(*) FROM t GROUP BY NULLIF(grp, 100 / (id % 7))",
		"SELECT NULLIF(d.grp, 100 / (t.id % 7)) AS k, COUNT(*) FROM t LEFT JOIN d ON t.grp = d.grp GROUP BY NULLIF(d.grp, 100 / (t.id % 7))",
		"SELECT NULLIF(t.grp, 100 / (t.id % 7)) AS k, COUNT(*) FROM t JOIN d ON t.flag = (d.grp > 3) GROUP BY NULLIF(t.grp, 100 / (t.id % 7))",
		"SELECT COUNT(*) FROM t JOIN d ON NULLIF(t.grp, 100 / (t.id % 7)) = d.grp",
		"SELECT COUNT(*) FROM d JOIN t a ON d.grp = a.grp JOIN t b ON NULLIF(d.grp, 100 / (a.id % 7)) = b.id",
		// Join tables addressed directly (dense keys incl. negative ones,
		// duplicates) or by hash (sparse keys).
		"SELECT COUNT(*), SUM(a.id) FROM t a JOIN t b ON a.id - 1500 = 1500 - b.id WHERE b.id % 3 = 0",
		"SELECT COUNT(*), MIN(b.id) FROM t a JOIN t b ON a.id * 1000000 = b.id * 1000 + 999000",
		"SELECT d.label, COUNT(*) FROM t JOIN d ON t.grp = d.grp GROUP BY d.label",
		// Vector kernels: CASE, COALESCE, casts, calendar functions.
		"SELECT CASE WHEN amount < 100 THEN 'low' WHEN grp IS NULL THEN NULL WHEN amount < 300 THEN cat ELSE 'high' END AS c, COUNT(*) FROM t GROUP BY 1",
		"SELECT SUM(CASE WHEN flag THEN amount ELSE 0 END), SUM(CASE WHEN cat = 'red' THEN 1 END), MAX(CASE WHEN id > 10 THEN price END) FROM t",
		"SELECT CASE WHEN id % 2 = 0 THEN 100 / (id % 3) ELSE 0 END FROM t WHERE id < 50",
		"SELECT COALESCE(grp, id % 5, 0), COALESCE(NULLIF(cat, 'red'), cat, 'x') FROM t WHERE id % 11 = 0",
		"SELECT YEAR(day), MONTH(day), DAY(day), COUNT(*) FROM t GROUP BY YEAR(day), MONTH(day), DAY(day)",
		"SELECT DATE_TRUNC('month', day), HOUR(CAST(day AS TIMESTAMP)), SUM(CAST(amount AS FLOAT64)), AVG(CAST(id AS FLOAT64)) FROM t GROUP BY DATE_TRUNC('month', day), HOUR(CAST(day AS TIMESTAMP))",
		// Subqueries: uncorrelated scalar / IN over strings, correlated aggregates, NOT EXISTS.
		"SELECT COUNT(*) FROM t WHERE amount > (SELECT AVG(amount) FROM t)",
		"SELECT COUNT(*) FROM t WHERE amount > (SELECT AVG(amount) FROM t WHERE id < 0)",
		"SELECT cat, COUNT(*) FROM t WHERE cat NOT IN (SELECT label FROM d) GROUP BY cat",
		"SELECT cat, COUNT(*) FROM t WHERE grp NOT IN (SELECT grp FROM d WHERE label <> 'one') GROUP BY cat",
		"SELECT COUNT(*) FROM t WHERE cat NOT IN (SELECT CASE WHEN grp = 1 THEN NULL ELSE label END FROM d)",
		"SELECT COUNT(*) FROM t WHERE cat IN (SELECT CASE WHEN grp = 1 THEN 'red' ELSE 'blue' END FROM d)",
		"SELECT id, (SELECT COUNT(*) FROM d WHERE d.grp = t.id % 13 AND d.label <> 'acht') FROM t WHERE id < 60",
		"SELECT id FROM t WHERE NOT EXISTS (SELECT 1 FROM d WHERE d.grp = t.id % 13 AND d.label LIKE '%e%') AND id < 80",
		"SELECT d.label FROM d WHERE d.grp < (SELECT COUNT(*) FROM t WHERE CAST(t.grp AS INT64) = d.grp) / 100",
	}
	for _, q := range queries {
		want := canonical(e, q, modeConfig{"row", "hash", 1, true})
		for _, c := range modeMatrix {
			if got := canonical(e, q, c); got != want {
				t.Errorf("%s\n  %+v:\n  got  %.300s\n  want %.300s", q, c, got, want)
			}
		}
	}
}

func TestUnionAllModesAgree(t *testing.T) {
	e := newModesEngine(t)
	queries := []string{
		"SELECT id, cat FROM t WHERE id < 50 UNION ALL SELECT grp, label FROM d UNION ALL SELECT id, cat FROM t WHERE id < 50",
		"SELECT grp AS g, COUNT(*) AS n FROM t GROUP BY grp UNION ALL SELECT label, grp FROM d",
		"SELECT amount AS v FROM t WHERE id % 11 = 0 UNION ALL SELECT id FROM t WHERE id % 13 = 0 UNION ALL SELECT price FROM t WHERE id % 17 = 0",
		"SELECT v, COUNT(*), SUM(v) FROM (SELECT id % 10 AS v FROM t UNION ALL SELECT grp FROM d UNION ALL SELECT NULL) u GROUP BY v",
		"SELECT id, amount FROM t UNION ALL SELECT grp, NULL FROM d ORDER BY amount DESC, id LIMIT 13 OFFSET 4",
		"SELECT u.k, d.label FROM (SELECT CAST(grp AS INT64) AS k FROM t WHERE id < 100 UNION ALL SELECT grp FROM d) u JOIN d ON u.k = d.grp",
		"SELECT COUNT(*) FROM (SELECT * FROM t UNION ALL SELECT * FROM t) u WHERE u.flag AND u.cat = 'red'",
		"WITH x AS (SELECT cat FROM t WHERE id < 20 UNION ALL SELECT label FROM d) SELECT a.cat, COUNT(*) FROM x a JOIN x b ON a.cat = b.cat GROUP BY a.cat",
		"SELECT id FROM t WHERE id IN (SELECT grp FROM d UNION ALL SELECT 2999) ORDER BY id",
		"SELECT id FROM t WHERE id < 30 AND EXISTS (SELECT 1 FROM d WHERE d.grp = t.id UNION ALL SELECT 1 FROM t s WHERE s.id = t.id + 2990)",
		"SELECT id, (SELECT COUNT(*) FROM (SELECT grp FROM d WHERE d.grp = t.id % 13 UNION ALL SELECT 1) s) FROM t WHERE id < 40",
		"SELECT DISTINCT cat FROM t UNION ALL SELECT DISTINCT cat FROM t",
		"SELECT id FROM t WHERE id < 0 UNION ALL SELECT grp FROM d WHERE grp < 0",
		"SELECT 9223372036854775807 AS v UNION ALL SELECT CAST(amount AS DECIMAL(10,2)) FROM t",
		"SELECT id / (id - 1500) FROM t UNION ALL SELECT 1",
	}
	for _, q := range queries {
		want := canonical(e, q, modeConfig{"row", "hash", 1, true})
		for _, c := range modeMatrix {
			if got := canonical(e, q, c); got != want {
				t.Errorf("%s\n  %+v:\n  got  %.300s\n  want %.300s", q, c, got, want)
			}
		}
	}
	if got := canonical(e, "SELECT 9223372036854775807 AS v UNION ALL SELECT CAST(amount AS DECIMAL(10,2)) FROM t", modeMatrix[0]); got != "error NUMERIC_OVERFLOW" {
		t.Errorf("INT64 not fitting DECIMAL(18,2): %s", got)
	}
	res, err := e.Query(context.Background(), "SELECT id FROM t UNION ALL SELECT id FROM t ORDER BY id DESC LIMIT 3", QueryOptions{MaxRows: -1, Mode: "vectorized", Threads: 4})
	if err != nil || len(res.Rows) != 3 || res.Rows[0][0].I != 3000 || res.Rows[1][0].I != 3000 || res.Rows[2][0].I != 2999 {
		t.Errorf("ORDER BY/LIMIT over UNION ALL: %v %v", res, err)
	}
	if _, err := e.Query(context.Background(), "SELECT id FROM t UNION ALL SELECT id FROM t", QueryOptions{MaxRows: 5000}); !errs.Is(err, errs.ResourceLimit) {
		t.Errorf("max_rows applies to the whole result: %v", err)
	}
}

// TestWideDecimalModesAgree runs wide DECIMAL (CR-2) queries — arithmetic,
// exact INT64/DECIMAL comparisons, grouping, joins on mixed key types,
// sorting, overflow errors — in every execution configuration.
func TestWideDecimalModesAgree(t *testing.T) {
	e := newModesEngine(t)
	var sb strings.Builder
	sb.WriteString("id,g,w,big,n,i\n")
	for k := 1; k <= 2500; k++ {
		w := fmt.Sprintf("%d%019d.%010d", k%97-48, uint64(k)*7919%1e19, k*31%1e10)
		if k%5 == 0 {
			w = fmt.Sprintf("%d.%02d", k%300, k%100) // equal to n for some rows
		}
		big := fmt.Sprint(k % 61)
		if k%3 == 0 {
			big = fmt.Sprintf("%d%019d", k%13+1, k)
		}
		n := fmt.Sprintf("%d.%02d", k%300, k%100)
		i := fmt.Sprint(k%61 - 30)
		if k%11 == 0 {
			i = "9223372036854775807"
		}
		if k%17 == 0 {
			w, i = "", ""
		}
		fmt.Fprintf(&sb, "%d,%d,%s,%s,%s,%s\n", k, k%7, w, big, n, i)
	}
	data := sb.String()
	opts := ingest.DefaultOptions(ingest.CSV)
	opts.Schema = []storage.ColumnDef{
		{Name: "id", Type: types.Int64}, {Name: "g", Type: types.Int64}, {Name: "w", Type: types.Decimal(38, 10)},
		{Name: "big", Type: types.Decimal(30, 0)}, {Name: "n", Type: types.Decimal(10, 2)}, {Name: "i", Type: types.Int64},
	}
	if _, err := e.Load(LoadRequest{Table: "w", Data: &data, Options: opts}); err != nil {
		t.Fatal(err)
	}
	queries := []string{
		"SELECT id, w + n, w - big, big * n, -w, ABS(w), w * 2 FROM w WHERE id % 7 = 0",
		"SELECT id FROM w WHERE w > n OR big >= i",
		"SELECT id FROM w WHERE big > 9223372036854775807 AND w < 0.5",
		"SELECT id FROM w WHERE i > 1.5 AND n <= 150 AND w BETWEEN -10 AND 12345678901234567890.5",
		"SELECT id FROM w WHERE big IN (1, 2, 3, 40000000000000000003.) OR w = n",
		"SELECT g, COUNT(w), SUM(w), MIN(w), MAX(big), AVG(w), SUM(big) FROM w GROUP BY g",
		"SELECT big, COUNT(*) FROM w GROUP BY big",
		"SELECT DISTINCT big FROM w WHERE big < 100",
		"SELECT COUNT(DISTINCT w), COUNT(DISTINCT big) FROM w",
		"SELECT id, w FROM w ORDER BY w DESC, id LIMIT 23",
		"SELECT id, big FROM w ORDER BY big, id",
		"SELECT a.id, b.id FROM w a JOIN w b ON a.big = b.i WHERE a.id < 400",
		"SELECT a.id, b.id FROM w a JOIN w b ON a.w = b.n WHERE a.id < 300 AND b.id < 300",
		"SELECT COUNT(*) FROM w a JOIN t b ON a.n = b.amount",
		"SELECT ROUND(w, 2), ROUND(w, -3), FLOOR(w), CEIL(w), CAST(w AS INT64) FROM w WHERE ABS(w) < 1000000",
		"SELECT CAST(w AS DECIMAL(20,2)), CAST(w AS FLOAT64), CAST(w AS STRING) FROM w WHERE id < 100",
		"SELECT CAST(w AS INT64) FROM w",
		"SELECT SUM(w * w) FROM w",
		"SELECT SUM(big) FROM w",
		"SELECT w * big FROM w",
		"SELECT COALESCE(w, n), CASE WHEN g = 1 THEN w ELSE n END, NULLIF(big, i) FROM w WHERE id < 200",
		"SELECT id FROM w WHERE w IN (SELECT n FROM w WHERE id < 500)",
		"SELECT id FROM w o WHERE big = (SELECT MAX(big) FROM w x WHERE x.g = o.g)",
		"SELECT v FROM (SELECT w AS v FROM w WHERE id < 50 UNION ALL SELECT n FROM w WHERE id < 50 UNION ALL SELECT i FROM w WHERE id < 20) u",
	}
	for _, q := range queries {
		want := canonical(e, q, modeConfig{"row", "hash", 1, true})
		for _, c := range modeMatrix {
			if got := canonical(e, q, c); got != want {
				t.Errorf("%s\n  %+v:\n  got  %.300s\n  want %.300s", q, c, got, want)
			}
		}
	}
	for q, want := range map[string]string{
		"SELECT CAST(w AS INT64) FROM w":                              "error NUMERIC_OVERFLOW",
		"SELECT w * big FROM w":                                       "error NUMERIC_OVERFLOW",
		"SELECT SUM(w) AS s, MAX(w) AS m FROM w WHERE id = 5":         "s:DECIMAL(38,10),m:DECIMAL(38,10)|5.0500000000,5.0500000000",
		"SELECT COUNT(*) AS c FROM w WHERE i > 9223372036854775806.5": "c:INT64|214",
	} {
		if got := canonical(e, q, modeConfig{"vectorized", "hash", 4, true}); got != want {
			t.Errorf("%s: %s, want %s", q, got, want)
		}
	}
}

func TestJoinAlgorithmSelection(t *testing.T) {
	e := newModesEngine(t)
	q := "SELECT t.id FROM t JOIN d ON CAST(t.grp AS INT64) = d.grp"
	for join, op := range map[string]string{"hash": "HashJoin", "merge": "MergeJoin", "nested_loop": "NestedLoopJoin", "auto": "HashJoin"} {
		p, err := e.Explain(q, QueryOptions{Join: join})
		if err != nil {
			t.Fatal(err)
		}
		b, _ := p.MarshalJSON()
		if !strings.Contains(string(b), `"op":"`+op+`"`) {
			t.Errorf("join %s: plan lacks %s: %s", join, op, b)
		}
	}
	// Non-equi joins always use a nested loop.
	p, err := e.Explain("SELECT t.id FROM t JOIN d ON t.id < d.grp", QueryOptions{Join: "merge"})
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := p.MarshalJSON(); !strings.Contains(string(b), "NestedLoopJoin") {
		t.Errorf("non-equi join: %s", b)
	}
}

func TestOptimizerFoldsConstants(t *testing.T) {
	e := newModesEngine(t)
	p, err := e.Explain("SELECT id FROM t WHERE amount > 100 * 2 + 0.5 AND 1 = 1", QueryOptions{})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := p.MarshalJSON()
	if !strings.Contains(string(b), "200.5") || strings.Contains(string(b), "(1 = 1)") {
		t.Errorf("constants not folded: %s", b)
	}
	p, err = e.Explain("SELECT id FROM t WHERE amount > 100 * 2 + 0.5 AND 1 = 1", QueryOptions{NoOptimize: true})
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := p.MarshalJSON(); !strings.Contains(string(b), "(1 = 1)") {
		t.Errorf("optimize=false folded constants: %s", b)
	}
	// A failing constant is not folded: the error only surfaces when evaluated.
	res, err := e.Query(context.Background(), "SELECT 1 / 0 FROM t WHERE id < 0", QueryOptions{MaxRows: -1})
	if err != nil || len(res.Rows) != 0 {
		t.Errorf("1/0 over no rows: %v %v", res, err)
	}
}

// TestParallelHighCardinality covers the hash-partitioned merge of partial
// aggregation tables (many groups) and the choice of the error of the
// first-appearing failing group.
func TestParallelHighCardinality(t *testing.T) {
	// Default heuristics, and workers that always switch to partitioned
	// (scattering) aggregation after a few morsels.
	for _, scatter := range []int{0, 1, 2500} {
		t.Run(fmt.Sprint("scatter", scatter), func(t *testing.T) { testParallelHighCardinality(t, scatter) })
	}
}

func testParallelHighCardinality(t *testing.T, scatterRows int) {
	cfg := DefaultConfig()
	cfg.DataDir = t.TempDir()
	cfg.MorselRows = 1000
	cfg.ScatterRows = scatterRows
	e := New(cfg)
	var sb strings.Builder
	sb.WriteString("id,v,s\n")
	for i := 1; i <= 40000; i++ {
		v := int64(i % 17)
		if i == 30001 || i == 30001+12000 {
			v = 4611686018427387904 // SUM overflows in group 6001 only
		}
		fmt.Fprintf(&sb, "%d,%d,k%d\n", i, v, i%9001)
	}
	data := sb.String()
	if _, err := e.Load(LoadRequest{Table: "h", Data: &data, Options: ingest.DefaultOptions(ingest.CSV)}); err != nil {
		t.Fatal(err)
	}
	queries := []string{
		"SELECT id % 12000 AS g, COUNT(*), SUM(v), MIN(s), MAX(v) FROM h WHERE id <> 30001 GROUP BY id % 12000",
		"SELECT s, COUNT(*), AVG(v) FROM h WHERE v < 100 GROUP BY s",
		"SELECT s, id % 3, COUNT(DISTINCT v) FROM h WHERE v < 100 GROUP BY s, id % 3",
		"SELECT DISTINCT s FROM h",
		"SELECT id % 12000 AS g, SUM(v) + SUM(v) FROM h GROUP BY id % 12000",
		"SELECT id % 12000 AS g, SUM(v) FROM h GROUP BY id % 12000",
		"SELECT CAST(id % 5000 AS FLOAT64) / 4, COUNT(*), MAX(s) FROM h GROUP BY CAST(id % 5000 AS FLOAT64) / 4",
		"SELECT s, COUNT(DISTINCT id % 7), SUM(DISTINCT v), MIN(id) FROM h WHERE v < 100 GROUP BY s",
	}
	for _, q := range queries {
		want := canonical(e, q, modeConfig{"row", "hash", 1, true})
		for _, c := range modeMatrix {
			if got := canonical(e, q, c); got != want {
				t.Errorf("%s\n  %+v:\n  got  %.300s\n  want %.300s", q, c, got, want)
			}
		}
	}
	// First-appearance order is kept by parallel aggregation.
	res, err := e.Query(context.Background(), "SELECT s FROM h GROUP BY s LIMIT 3", QueryOptions{MaxRows: -1, Mode: "vectorized", Threads: 8})
	if err != nil || render(res) != "s:STRING|k1|k2|k3" {
		t.Errorf("group order: %v %v", res, err)
	}
}

// TestOrderedLimitModesAgree compares ORDER BY … LIMIT results in order
// (ties are broken by input position in every mode), for small limits
// (bounded heap) and large ones (full sort).
func TestOrderedLimitModesAgree(t *testing.T) {
	e := newModesEngine(t)
	queries := []string{
		"SELECT id, cat FROM t ORDER BY cat LIMIT 50 OFFSET 7",
		"SELECT id, cat FROM t ORDER BY cat DESC NULLS LAST LIMIT 20000 OFFSET 10",
		"SELECT id, flag FROM t ORDER BY flag, amount DESC LIMIT 100000",
		"SELECT cat, COUNT(*) FROM t GROUP BY cat ORDER BY COUNT(*) LIMIT 20000",
	}
	for _, q := range queries {
		run := func(c modeConfig) string {
			res, err := e.Query(context.Background(), q, QueryOptions{
				MaxRows: -1, Mode: c.mode, Join: c.join, Threads: c.threads, NoOptimize: !c.optimize,
			})
			if err != nil {
				return "error " + err.Error()
			}
			return render(res)
		}
		want := run(modeConfig{"row", "hash", 1, true})
		for _, c := range modeMatrix {
			if got := run(c); got != want {
				t.Errorf("%s\n  %+v:\n  got  %.300s\n  want %.300s", q, c, got, want)
			}
		}
	}
}
