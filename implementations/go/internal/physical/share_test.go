package physical_test

import (
	"testing"

	"polyquery/internal/physical"
)

func TestSharedAggregates(t *testing.T) {
	for _, c := range []struct {
		sql    string
		shared int
	}{
		// A CTE referenced twice: both expansions share their rows.
		{"WITH s AS (SELECT dept, SUM(salary) AS t FROM emp GROUP BY dept) " +
			"SELECT COUNT(*) FROM s WHERE t > (SELECT AVG(t) FROM s)", 2},
		{"SELECT a.dept FROM (SELECT dept, COUNT(*) AS n FROM emp GROUP BY dept) a " +
			"JOIN (SELECT dept, COUNT(*) AS n FROM emp GROUP BY dept) b ON a.dept = b.dept", 2},
		// Different filters or aggregates: nothing to share.
		{"SELECT a.dept FROM (SELECT dept, COUNT(*) AS n FROM emp WHERE salary > 1 GROUP BY dept) a " +
			"JOIN (SELECT dept, COUNT(*) AS n FROM emp GROUP BY dept) b ON a.dept = b.dept", 0},
		{"SELECT a.dept FROM (SELECT dept, MAX(salary) AS n FROM emp GROUP BY dept) a " +
			"JOIN (SELECT dept, MIN(salary) AS n FROM emp GROUP BY dept) b ON a.dept = b.dept", 0},
		// Correlated: depends on the outer row.
		{"SELECT name FROM emp e WHERE salary > (SELECT AVG(salary) FROM emp r WHERE r.dept = e.dept) " +
			"AND salary < (SELECT MAX(salary) FROM emp r WHERE r.dept = e.dept)", 0},
		// Test functions are never shared.
		{"SELECT a.dept FROM (SELECT dept, COUNT(PQ_SLEEP(0)) AS n FROM emp GROUP BY dept) a " +
			"JOIN (SELECT dept, COUNT(PQ_SLEEP(0)) AS n FROM emp GROUP BY dept) b ON a.dept = b.dept", 0},
	} {
		p := build(t, c.sql, physical.Options{})
		if len(p.Shared) != c.shared {
			t.Errorf("%s: %d shared aggregations, want %d", c.sql, len(p.Shared), c.shared)
		}
	}
}

func TestAnyOrderAggregate(t *testing.T) {
	for _, c := range []struct {
		sql string
		any bool
	}{
		{"SELECT dept, COUNT(*) AS n FROM emp GROUP BY dept ORDER BY n DESC, dept LIMIT 3", true},
		{"SELECT dept, boss, COUNT(*) FROM emp GROUP BY dept, boss ORDER BY boss, dept", true},
		{"SELECT dept, COUNT(*) AS n FROM emp GROUP BY dept ORDER BY n DESC LIMIT 3", false},
		{"SELECT dept, boss, COUNT(*) FROM emp GROUP BY dept, boss ORDER BY boss", false},
		{"SELECT dept, COUNT(*) FROM emp GROUP BY dept", false},
	} {
		p := build(t, c.sql, physical.Options{})
		var found *physical.HashAggregate
		var visit func(physical.Node)
		visit = func(n physical.Node) {
			if a, ok := n.(*physical.HashAggregate); ok {
				found = a
			}
			for _, ch := range n.Children() {
				visit(ch)
			}
		}
		visit(p.Root)
		if found == nil || found.AnyOrder != c.any {
			t.Errorf("%s: AnyOrder = %v, want %v", c.sql, found != nil && found.AnyOrder, c.any)
		}
	}
}

func TestAntiJoin(t *testing.T) {
	for _, c := range []struct {
		sql  string
		anti bool
	}{
		// emp.id has no NULLs: only unmatched rows survive the filter.
		{"SELECT d.code FROM dept d LEFT JOIN emp e ON e.dept = d.code WHERE e.id IS NULL", true},
		// emp.salary has a NULL, so a matched row may pass.
		{"SELECT d.code FROM dept d LEFT JOIN emp e ON e.dept = d.code WHERE e.salary IS NULL", false},
		{"SELECT d.code FROM dept d LEFT JOIN emp e ON e.dept = d.code WHERE e.id IS NOT NULL", false},
		{"SELECT d.code FROM dept d LEFT JOIN emp e ON e.dept = d.code WHERE e.id IS NULL OR d.code = 'hr'", false},
		// A right-side ON conjunct is pushed into the right input.
		{"SELECT d.code FROM dept d LEFT JOIN emp e ON e.dept = d.code AND e.salary > 70 WHERE e.id IS NULL", true},
		// A residual decides matches during the probe.
		{"SELECT d.code FROM dept d LEFT JOIN emp e ON e.dept = d.code AND e.salary > LENGTH(d.title) WHERE e.id IS NULL", false},
	} {
		p := build(t, c.sql, physical.Options{})
		var hj *physical.HashJoin
		var visit func(physical.Node)
		visit = func(n physical.Node) {
			if j, ok := n.(*physical.HashJoin); ok {
				hj = j
			}
			for _, ch := range n.Children() {
				visit(ch)
			}
		}
		visit(p.Root)
		if hj == nil || hj.Anti != c.anti {
			t.Errorf("%s: Anti = %v, want %v", c.sql, hj != nil && hj.Anti, c.anti)
		}
	}
}
