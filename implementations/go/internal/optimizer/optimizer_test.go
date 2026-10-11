package optimizer_test

import (
	"reflect"
	"strings"
	"testing"

	"polyquery/internal/analyzer"
	"polyquery/internal/exec"
	"polyquery/internal/optimizer"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/sql/parser"
	"polyquery/internal/testutil"
)

// Fixture tables (testutil): emp(id, name, dept, salary, boss) with 5 rows
// and dept(code, title) with 3 rows.

// logical returns the analyzed, unoptimized logical plan of a query.
func logical(t *testing.T, sql string) plan.Node {
	t.Helper()
	stmt, err := parser.Parse(sql)
	if err != nil {
		t.Fatal(err)
	}
	n, err := analyzer.AnalyzeQuery(stmt.(*ast.Query), testutil.Catalog(t), analyzer.Config{EvalConst: exec.EvalConstant})
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// apply runs the given rules in order on the plan of sql and returns the
// printed result; it also checks that the rules leave their input intact.
func apply(t *testing.T, sql string, rules ...optimizer.Rule) string {
	t.Helper()
	n := logical(t, sql)
	before := plan.Format(n)
	out := (&optimizer.Optimizer{Rules: rules}).Optimize(n)
	if plan.Format(n) != before {
		t.Errorf("rules modified their input plan:\n%s", before)
	}
	return plan.Format(out)
}

func expectLines(t *testing.T, got string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(got, w) {
			t.Errorf("plan lacks %q:\n%s", w, got)
		}
	}
}

func rejectLines(t *testing.T, got string, unwanted ...string) {
	t.Helper()
	for _, w := range unwanted {
		if strings.Contains(got, w) {
			t.Errorf("plan unexpectedly contains %q:\n%s", w, got)
		}
	}
}

var folding = optimizer.ConstantFolding{Eval: exec.EvalConstant}

func TestRuleNames(t *testing.T) {
	var names []string
	for _, r := range optimizer.New(optimizer.Options{EvalConst: exec.EvalConstant}).Rules {
		names = append(names, r.Name())
	}
	want := []string{"constant_folding", "predicate_pushdown", "join_reorder", "column_pruning"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("default rules %v, want %v", names, want)
	}
}

func TestDisabledAppliesNoRule(t *testing.T) {
	o := optimizer.New(optimizer.Options{Disabled: true, EvalConst: exec.EvalConstant})
	if len(o.Rules) != 0 {
		t.Fatalf("optimize: false must apply no rules, got %d", len(o.Rules))
	}
	n := logical(t, "SELECT name FROM emp e, dept d WHERE e.dept = d.code AND salary > 1 + 1")
	if out := optimizer.Optimize(n, optimizer.Options{Disabled: true}); out != n {
		t.Fatalf("disabled optimizer changed the plan:\n%s", plan.Format(out))
	}
}

func TestConstantFolding(t *testing.T) {
	got := apply(t, "SELECT salary * (2 + 3) AS s FROM emp WHERE salary > 50 + 10", folding)
	expectLines(t, got, "(#4:salary * 5)", "Filter (#4:salary > 60)")

	// A constant whose evaluation fails is kept, so that the error is raised
	// only if the expression is evaluated.
	got = apply(t, "SELECT 1 / 0 AS x FROM emp", folding)
	expectLines(t, got, "(1 / 0)")

	// Constants inside the plans of subqueries that form a whole
	// expression are folded as well.
	got = apply(t, "SELECT name FROM emp e WHERE EXISTS (SELECT 1 FROM emp r WHERE r.salary > 10 * 2)", folding)
	expectLines(t, got, "Filter (#9:salary > 20)")

	// Without an evaluator the rule does nothing.
	n := logical(t, "SELECT 1 + 1 AS two FROM emp")
	if out := (optimizer.ConstantFolding{}).Apply(n); out != n {
		t.Fatalf("folding without evaluator changed the plan")
	}
}

func TestBooleanSimplification(t *testing.T) {
	got := apply(t, "SELECT id FROM emp WHERE 1 = 1 AND salary > 10", folding)
	expectLines(t, got, "Filter (#4:salary > 10)")

	got = apply(t, "SELECT id FROM emp WHERE 1 = 2 AND salary > 10", folding)
	expectLines(t, got, "Filter false")

	got = apply(t, "SELECT id FROM emp WHERE salary > 10 OR 1 = 2", folding)
	expectLines(t, got, "Filter (#4:salary > 10)")

	// x AND FALSE keeps x: it is evaluated first and may fail.
	got = apply(t, "SELECT id FROM emp WHERE salary / 0 > 1 AND 1 = 2", folding)
	expectLines(t, got, "Filter (((#4:salary / 0) > 1) AND false)")
}

func TestPredicatePushdownIntoJoinInputs(t *testing.T) {
	got := apply(t, "SELECT e.name, d.title FROM emp e, dept d WHERE d.code = e.dept AND e.salary > 50 AND d.title <> 'x'",
		optimizer.PredicatePushdown{})
	want := `Project [#8:name := #2:name, #9:title := #7:title]
  Join INNER (#6:code = #3:dept)
    Filter (#4:salary > 50)
      Scan emp [#1:id, #2:name, #3:dept, #4:salary, #5:boss]
    Filter (#7:title <> 'x')
      Scan dept [#6:code, #7:title]
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestPredicatePushdownLeftJoin(t *testing.T) {
	// ON conjuncts on the right input filter it; WHERE conjuncts on the
	// NULL-extended side stay above the join, those on the preserved side
	// move below it.
	got := apply(t, `SELECT a.id FROM emp a LEFT JOIN emp b ON a.boss = b.id AND b.salary > 60
		WHERE b.name IS NULL AND a.salary > 10`, optimizer.PredicatePushdown{})
	want := `Project [#11:id := #1:id]
  Filter (#7:name IS NULL)
    Join LEFT (#5:boss = #6:id)
      Filter (#4:salary > 10)
        Scan emp [#1:id, #2:name, #3:dept, #4:salary, #5:boss]
      Filter (#9:salary > 60)
        Scan emp [#6:id, #7:name, #8:dept, #9:salary, #10:boss]
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestPredicatePushdownBelowProjection(t *testing.T) {
	// The predicate on a derived table's computed column is rewritten in
	// terms of the projection's input and evaluated directly on the scan.
	got := apply(t, "SELECT x.id FROM (SELECT id, salary * 2 AS s FROM emp) x WHERE x.s > 100",
		optimizer.PredicatePushdown{})
	want := `Project [#8:id := #6:id]
  Project [#6:id := #1:id, #7:s := (#4:salary * 2)]
    Filter ((#4:salary * 2) > 100)
      Scan emp [#1:id, #2:name, #3:dept, #4:salary, #5:boss]
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestPredicatePushdownStopsAtAggregateAndLimit(t *testing.T) {
	got := apply(t, "SELECT * FROM (SELECT dept, COUNT(*) AS n FROM emp GROUP BY dept) g WHERE g.n > 1",
		optimizer.PredicatePushdown{})
	expectLines(t, got, "  Filter (#")
	if strings.Index(got, "Filter") > strings.Index(got, "Aggregate") {
		t.Errorf("filter on an aggregate output moved below the aggregation:\n%s", got)
	}

	got = apply(t, "SELECT * FROM (SELECT id FROM emp LIMIT 2) l WHERE l.id > 1", optimizer.PredicatePushdown{})
	if strings.Index(got, "Filter") > strings.Index(got, "Limit") {
		t.Errorf("filter moved below LIMIT:\n%s", got)
	}
}

func TestPredicatePushdownIntoUnionBranches(t *testing.T) {
	got := apply(t, "SELECT n FROM (SELECT id AS n FROM emp UNION ALL SELECT boss FROM emp) u WHERE n > 2",
		optimizer.PredicatePushdown{})
	expectLines(t, got, "Filter (#1:id > 2)", "Filter (#11:boss > 2)")
	if strings.Index(got, "UnionAll") > strings.Index(got, "Filter") {
		t.Errorf("filter stayed above UNION ALL:\n%s", got)
	}
}

func TestPredicatePushdownRemovesTrueFilters(t *testing.T) {
	got := apply(t, "SELECT id FROM emp WHERE TRUE", optimizer.PredicatePushdown{})
	rejectLines(t, got, "Filter")
}

func TestPredicatePushdownInsideSubqueries(t *testing.T) {
	got := apply(t, `SELECT name FROM emp e WHERE EXISTS (
		SELECT 1 FROM emp r, dept d WHERE r.dept = d.code AND r.boss = e.id)`, optimizer.PredicatePushdown{})
	expectLines(t, got, "Join INNER (#8:dept = #11:code)", "Filter (#10:boss = #1:id)")
}

func TestJoinReorder(t *testing.T) {
	// FROM order emp, emp, dept: the rebuilt chain starts with dept, the
	// smallest input, and joins only along join conditions; a projection
	// restores the original column order.
	got := apply(t, `SELECT a.name, b.name, d.title FROM emp a, emp b, dept d
		WHERE a.boss = b.id AND b.dept = d.code`, optimizer.PredicatePushdown{}, optimizer.JoinReorder{})
	want := `Project [#13:name := #2:name, #14:name := #7:name, #15:title := #12:title]
  Project [#1:id := #1:id, #2:name := #2:name, #3:dept := #3:dept, #4:salary := #4:salary, #5:boss := #5:boss, #6:id := #6:id, #7:name := #7:name, #8:dept := #8:dept, #9:salary := #9:salary, #10:boss := #10:boss, #11:code := #11:code, #12:title := #12:title]
    Join INNER (#5:boss = #6:id)
      Join INNER (#8:dept = #11:code)
        Scan dept [#11:code, #12:title]
        Scan emp [#6:id, #7:name, #8:dept, #9:salary, #10:boss]
      Scan emp [#1:id, #2:name, #3:dept, #4:salary, #5:boss]
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestJoinReorderKeepsLeftJoinsAndPairs(t *testing.T) {
	sql := "SELECT a.id FROM emp a LEFT JOIN dept d ON a.dept = d.code LEFT JOIN emp b ON a.boss = b.id"
	if got, want := apply(t, sql, optimizer.JoinReorder{}), plan.Format(logical(t, sql)); got != want {
		t.Fatalf("LEFT joins were reordered:\n%s", got)
	}
	sql = "SELECT a.id FROM emp a JOIN dept d ON a.dept = d.code"
	if got, want := apply(t, sql, optimizer.JoinReorder{}), plan.Format(logical(t, sql)); got != want {
		t.Fatalf("two-way join was changed:\n%s", got)
	}
}

func TestColumnPruning(t *testing.T) {
	got := apply(t, "SELECT x.id FROM (SELECT id, name, salary * 2 AS s FROM emp) x WHERE x.id > 1",
		optimizer.ColumnPruning{})
	want := `Project [#9:id := #6:id]
  Filter (#6:id > 1)
    Project [#6:id := #1:id]
      Scan emp [#1:id]
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}

	// Scans keep the columns of filters, join conditions, sort keys and
	// aggregates; ordinals follow the table.
	n := optimizer.ColumnPruning{}.Apply(logical(t, "SELECT d.title FROM emp e JOIN dept d ON e.dept = d.code WHERE e.salary > 1 ORDER BY e.boss"))
	var scans []*plan.Scan
	var visit func(plan.Node)
	visit = func(n plan.Node) {
		if s, ok := n.(*plan.Scan); ok {
			scans = append(scans, s)
		}
		for _, c := range n.Children() {
			visit(c)
		}
	}
	visit(n)
	if len(scans) != 2 || !reflect.DeepEqual(scans[0].Ords, []int{2, 3, 4}) || !reflect.DeepEqual(scans[1].Ords, []int{0, 1}) {
		t.Fatalf("unexpected scan columns:\n%s", plan.Format(n))
	}
}

func TestColumnPruningKeepsRequiredInputs(t *testing.T) {
	// DISTINCT needs all its input columns; aggregations keep their outputs.
	got := apply(t, "SELECT COUNT(*) AS c FROM (SELECT DISTINCT name, dept FROM emp) x", optimizer.ColumnPruning{})
	expectLines(t, got, "Scan emp [#2:name, #3:dept]")

	got = apply(t, "SELECT g.dept FROM (SELECT dept, COUNT(*) AS n, MAX(salary) AS m FROM emp GROUP BY dept) g",
		optimizer.ColumnPruning{})
	expectLines(t, got, "Scan emp [#3:dept, #4:salary]")

	// The root's output columns are never pruned.
	got = apply(t, "SELECT id, name, 1 AS one FROM emp", optimizer.ColumnPruning{})
	expectLines(t, got, "Scan emp [#1:id, #2:name]", "#8:one := 1")
}

func TestColumnPruningInCorrelatedSubqueries(t *testing.T) {
	// Inside the subquery, the unused output z references the outer column
	// e.id and is kept (correlation is unchanged); the unused name is pruned.
	got := apply(t, `SELECT (SELECT COUNT(*) FROM (SELECT r.id + e.id AS z, r.name FROM emp r) s) AS c FROM emp e`,
		optimizer.ColumnPruning{})
	expectLines(t, got, ":z := (#6:id + #1:id)]", "Scan emp [#6:id]", "Scan emp [#1:id]")
	rejectLines(t, got, ":name := ")
}
