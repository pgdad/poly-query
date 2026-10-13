package physical_test

import (
	"testing"

	"polyquery/internal/analyzer"
	"polyquery/internal/catalog"
	"polyquery/internal/exec"
	"polyquery/internal/index"
	"polyquery/internal/optimizer"
	"polyquery/internal/physical"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/parser"
	"polyquery/internal/testutil"
)

// indexed returns a fixture catalog with indexes on emp.id (HASH) and
// emp.salary (BTREE).
func indexed(t *testing.T) *catalog.Catalog {
	cat := testutil.Catalog(t)
	for _, d := range []index.Def{{Name: "emp_id", Column: "id", Kind: index.Hash}, {Name: "emp_sal", Column: "salary", Kind: index.BTree}} {
		if err := cat.CreateIndex(d, "emp", false); err != nil {
			t.Fatal(err)
		}
	}
	return cat
}

func planWith(t *testing.T, cat *catalog.Catalog, sql string, useIndexes bool) []map[string]any {
	t.Helper()
	stmt, err := parser.Parse(sql)
	if err != nil {
		t.Fatal(err)
	}
	snap := cat.Snapshot()
	logical, err := analyzer.AnalyzeQuery(stmt.(*ast.Query), snap, analyzer.Config{EvalConst: exec.EvalConstant})
	if err != nil {
		t.Fatal(err)
	}
	optimized, err := optimizer.Optimize(logical, optimizer.Options{EvalConst: exec.EvalConstant})
	if err != nil {
		t.Fatal(err)
	}
	p, err := physical.Build(optimized, physical.Options{
		UseIndexes: useIndexes, Indexes: snap.IndexesOf, EvalConst: exec.EvalConstant,
	})
	if err != nil {
		t.Fatal(err)
	}
	return nodes(t, p)
}

func TestIndexSelection(t *testing.T) {
	cat := indexed(t)
	cases := []struct {
		sql   string
		index string // "" = no index scan
	}{
		{"SELECT name FROM emp WHERE id = 3", "emp_id"},
		{"SELECT name FROM emp WHERE id IN (2, 4) AND name <> 'x'", "emp_id"},
		{"SELECT name FROM emp WHERE id = 2.5", "emp_id"}, // provably empty
		{"SELECT name FROM emp WHERE salary BETWEEN 99 AND 100", "emp_sal"},
		{"SELECT name FROM emp WHERE salary > 0", ""},
		{"SELECT name FROM emp WHERE id > 3", ""}, // hash indexes cannot answer ranges
		{"SELECT name FROM emp WHERE id = 3 OR id = 4", ""},
	}
	for _, c := range cases {
		ns := planWith(t, cat, c.sql, true)
		ix := find(ns, "IndexScan")
		switch {
		case c.index == "" && len(ix) != 0:
			t.Errorf("%s: unexpected index scan %v", c.sql, ix)
		case c.index != "" && (len(ix) != 1 || ix[0]["index"] != c.index):
			t.Errorf("%s: expected index %s, got %v", c.sql, c.index, ns)
		}
		if len(find(planWith(t, cat, c.sql, false), "IndexScan")) != 0 {
			t.Errorf("%s: index used with use_indexes=false", c.sql)
		}
	}
}

func TestIndexScanColumnsAndResidual(t *testing.T) {
	ns := planWith(t, indexed(t), "SELECT name FROM emp WHERE id = 3 AND dept = 'eng'", true)
	ix := find(ns, "IndexScan")
	if len(ix) != 1 || scanColumns(ix[0]) != "dept,id,name" {
		t.Fatalf("index scan columns: %v", ix)
	}
	if f := find(ns, "Filter"); len(f) != 1 || f[0]["predicate"] != "(dept = 'eng')" {
		t.Fatalf("residual filter: %v", f)
	}
}

func TestRowGroupFilters(t *testing.T) {
	ns := planWith(t, indexed(t), "SELECT name FROM emp WHERE salary >= 60 AND salary < 90.5 AND dept IN ('eng', 'ops')", false)
	scan := find(ns, "TableScan")
	if len(scan) != 1 {
		t.Fatalf("plan: %v", ns)
	}
	filters, _ := scan[0]["row_group_filters"].([]any)
	if len(filters) != 2 || filters[0] != "salary >= 60 AND salary <= 90" || filters[1] != "dept IN (eng, ops)" {
		t.Fatalf("row group filters: %v", filters)
	}
}

func TestPushdownThroughDerivedTables(t *testing.T) {
	cat := indexed(t)
	for _, sql := range []string{
		"WITH e AS (SELECT id, name, salary * 2 AS s FROM emp) SELECT name FROM e WHERE id = 3 AND s > 1",
		"SELECT name FROM (SELECT DISTINCT id, name FROM emp ORDER BY name) d WHERE d.id IN (1, 2)",
	} {
		ix := find(planWith(t, cat, sql, true), "IndexScan")
		if len(ix) != 1 || ix[0]["index"] != "emp_id" {
			t.Errorf("%s: expected the predicate to reach the emp_id index", sql)
		}
	}
}
