package physical_test

import (
	"encoding/json"
	"sort"
	"strings"
	"testing"

	"polyquery/internal/analyzer"
	"polyquery/internal/exec"
	"polyquery/internal/optimizer"
	"polyquery/internal/physical"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/parser"
	"polyquery/internal/testutil"
)

func build(t *testing.T, sql string, opts physical.Options) *physical.Plan {
	t.Helper()
	stmt, err := parser.Parse(sql)
	if err != nil {
		t.Fatal(err)
	}
	logical, err := analyzer.AnalyzeQuery(stmt.(*ast.Query), testutil.Catalog(t), analyzer.Config{EvalConst: exec.EvalConstant})
	if err != nil {
		t.Fatal(err)
	}
	p, err := physical.Build(optimizer.Optimize(logical, optimizer.Options{EvalConst: exec.EvalConstant}), opts)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// nodes flattens an EXPLAIN tree.
func nodes(t *testing.T, p *physical.Plan) []map[string]any {
	t.Helper()
	b, err := json.Marshal(physical.Explain(p))
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal(b, &root); err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	var walk func(n map[string]any)
	walk = func(n map[string]any) {
		out = append(out, n)
		for _, c := range n["children"].([]any) {
			walk(c.(map[string]any))
		}
	}
	walk(root)
	return out
}

func find(ns []map[string]any, op string) []map[string]any {
	var out []map[string]any
	for _, n := range ns {
		if n["op"] == op {
			out = append(out, n)
		}
	}
	return out
}

func scanColumns(n map[string]any) string {
	var cols []string
	for _, c := range n["columns"].([]any) {
		cols = append(cols, c.(string))
	}
	sort.Strings(cols)
	return strings.Join(cols, ",")
}

func TestHashJoinAndPruning(t *testing.T) {
	ns := nodes(t, build(t, "SELECT e.name, d.title FROM emp e, dept d WHERE d.code = e.dept AND e.salary > 50", physical.Options{}))
	hj := find(ns, "HashJoin")
	if len(hj) != 1 || hj[0]["join_type"] != "INNER" {
		t.Fatalf("expected one INNER HashJoin, got %v", ns)
	}
	scans := find(ns, "TableScan")
	got := map[string]string{}
	for _, s := range scans {
		got[s["table"].(string)] = scanColumns(s)
	}
	if got["emp"] != "dept,name,salary" || got["dept"] != "code,title" {
		t.Fatalf("scan columns: %v", got)
	}
	// The single-table predicate is pushed below the join.
	if f := find(ns, "Filter"); len(f) != 1 || !strings.Contains(f[0]["predicate"].(string), "salary") {
		t.Fatalf("filters: %v", f)
	}
}

func TestNestedLoopAndLeftJoin(t *testing.T) {
	ns := nodes(t, build(t, "SELECT a.id FROM emp a JOIN emp b ON a.salary < b.salary", physical.Options{}))
	if len(find(ns, "NestedLoopJoin")) != 1 {
		t.Fatalf("expected NestedLoopJoin: %v", ns)
	}
	ns = nodes(t, build(t, "SELECT a.id FROM emp a LEFT JOIN emp b ON a.boss = b.id WHERE b.name IS NULL", physical.Options{}))
	hj := find(ns, "HashJoin")
	if len(hj) != 1 || hj[0]["join_type"] != "LEFT" {
		t.Fatalf("expected LEFT HashJoin: %v", ns)
	}
	// The WHERE predicate on the null-supplying side must stay above the join.
	if ns[0]["op"] != "Project" || ns[1]["op"] != "Filter" {
		t.Fatalf("expected Filter above the LEFT join: %v", ns[:2])
	}
	ns = nodes(t, build(t, "SELECT a.id FROM emp a JOIN emp b ON a.boss = b.id", physical.Options{Join: "nested_loop"}))
	if len(find(ns, "NestedLoopJoin")) != 1 || len(find(ns, "HashJoin")) != 0 {
		t.Fatalf("forced nested loop: %v", ns)
	}
}

func TestCorrelatedSubqueryPlan(t *testing.T) {
	ns := nodes(t, build(t, "SELECT name FROM emp e WHERE EXISTS (SELECT 1 FROM emp r WHERE r.boss = e.id AND r.salary > 10)", physical.Options{}))
	if len(find(ns, "Subquery")) != 1 || len(find(ns, "ParamLookup")) != 1 {
		t.Fatalf("expected a ParamLookup inside the subquery: %v", ns)
	}
}

func TestTopN(t *testing.T) {
	p := build(t, "SELECT name FROM emp ORDER BY salary DESC LIMIT 2 OFFSET 1", physical.Options{})
	s := find(nodes(t, p), "Sort")
	if len(s) != 1 || s[0]["top_n"] != float64(3) {
		t.Fatalf("expected top-N sort of 3 rows: %v", s)
	}
}
