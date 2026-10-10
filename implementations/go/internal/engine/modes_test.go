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
