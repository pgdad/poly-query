"""Unit tests for semantic analysis, logical/physical planning and EXPLAIN."""

import json
import unittest

from polyquery.analysis import bound as b
from polyquery.analysis.binder import Binder
from polyquery.execution.compiler import evaluate_constant
from polyquery.planner import logical as lp
from polyquery.planner import physical as pp
from polyquery.planner.optimizer import optimize
from polyquery.planner.planner import LogicalPlanner
from polyquery.sql.parser import parse
from tests.helpers import EngineTestMixin

PEOPLE = "id,name,age,city\n1,Ann,34,Oulu\n2,Bob,,Espoo\n3,Cid,28,Oulu\n"
ORDERS = "oid,pid,amount\n10,1,5.50\n11,1,7.25\n12,3,1.00\n13,,2.00\n"


def _walk(node):
    yield node
    for child in node.inputs():
        yield from _walk(child)


class PlanningTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("people", PEOPLE)
        self.load_csv("orders", ORDERS)

    def bind(self, sql: str) -> b.BoundStatement:
        binder = Binder(self.handler.engine.catalog, evaluate_constant)
        return binder.bind_statement(parse(sql).query)

    def physical(self, sql: str, **options) -> pp.PhysicalPlan:
        return pp.plan_statement(self.bind(sql), pp.PlanOptions(**options))

    def test_binder_resolves_columns_to_range_variables(self):
        stmt = self.bind("SELECT p.name, o.amount FROM people p JOIN orders o ON o.pid = p.id")
        refs = [o.expr for o in stmt.query.outputs]
        self.assertTrue(all(isinstance(r, b.ColumnRef) for r in refs))
        self.assertNotEqual(refs[0].rel, refs[1].rel)
        join = stmt.query.from_
        self.assertIsInstance(join, b.JoinRelation)
        self.assertEqual(join.left.used, {0, 1})  # id, name

    def test_grouped_outputs_reference_the_aggregate(self):
        stmt = self.bind("SELECT city, COUNT(*) AS n FROM people GROUP BY city")
        agg = stmt.query.aggregation
        self.assertEqual(len(agg.keys), 1)
        self.assertEqual([a.name for a in agg.aggregates], ["COUNT"])
        self.assertEqual([o.expr.rel for o in stmt.query.outputs], [agg.rel, agg.rel])

    def test_correlated_subquery_records_outer_columns(self):
        stmt = self.bind("SELECT name FROM people p WHERE EXISTS (SELECT 1 FROM orders o WHERE o.pid = p.id)")
        exists = stmt.query.where
        self.assertIsInstance(exists, b.Exists)
        self.assertTrue(exists.subquery.correlated)
        self.assertEqual(len(exists.args), 1)

    def test_pushdown_moves_single_table_conjuncts_below_the_join(self):
        stmt = self.bind(
            "SELECT p.name FROM people p, orders o WHERE o.pid = p.id AND p.age > 30 AND o.amount > 2"
        )
        node = optimize(LogicalPlanner(stmt.ids).plan_query(stmt.query))
        join = next(n for n in _walk(node) if isinstance(n, lp.Join))
        self.assertEqual(join.kind, "INNER")
        self.assertIsInstance(join.left, lp.Filter)
        self.assertIsInstance(join.right, lp.Filter)
        self.assertIsInstance(join.condition, b.Compare)

    def test_left_join_keeps_where_on_nullable_side_above_the_join(self):
        stmt = self.bind("SELECT p.id FROM people p LEFT JOIN orders o ON o.pid = p.id WHERE o.oid IS NULL")
        node = optimize(LogicalPlanner(stmt.ids).plan_query(stmt.query))
        flt = next(n for n in _walk(node) if isinstance(n, lp.Filter))
        self.assertIsInstance(flt.input, lp.Join)

    def test_equi_join_becomes_hash_join(self):
        plan = self.physical("SELECT p.name FROM people p JOIN orders o ON o.pid = p.id AND o.amount > p.age")
        joins = [n for n in _walk(plan.root) if isinstance(n, (pp.HashJoin, pp.NestedLoopJoin))]
        self.assertEqual(len(joins), 1)
        self.assertIsInstance(joins[0], pp.HashJoin)
        self.assertIsNotNone(joins[0].residual)
        forced = self.physical("SELECT p.name FROM people p JOIN orders o ON o.pid = p.id", join="nested_loop")
        self.assertTrue(any(isinstance(n, pp.NestedLoopJoin) for n in _walk(forced.root)))

    def test_correlated_equality_uses_lookup_scan(self):
        plan = self.physical("SELECT name FROM people p WHERE EXISTS (SELECT 1 FROM orders o WHERE o.pid = p.id)")
        (subplan,) = plan.subplans.values()
        self.assertTrue(any(isinstance(n, pp.LookupScan) for n in _walk(subplan)))

    def test_explain_reports_scan_columns_and_join_type(self):
        resp = self.request(op="explain", sql="SELECT p.name FROM people p JOIN orders o ON o.pid = p.id")
        self.assertTrue(resp["ok"], resp)
        nodes = []

        def walk(n):
            nodes.append(n)
            for c in n["children"]:
                walk(c)

        walk(resp["plan"])
        scans = {n["table"]: set(n["columns"]) for n in nodes if n["op"] == "TableScan"}
        self.assertEqual(scans, {"people": {"id", "name"}, "orders": {"pid"}})
        self.assertIn("INNER", [n.get("join_type") for n in nodes])
        text = self.rows("EXPLAIN SELECT 1")[0][0]
        self.assertEqual(json.loads(text)["op"], "Project")


class Phase2QueryTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("people", PEOPLE)
        self.load_csv("orders", ORDERS)

    def test_group_by_having_order(self):
        self.assertEqual(
            self.rows("SELECT city, COUNT(*) AS n, MAX(age) FROM people GROUP BY city HAVING COUNT(*) > 0 ORDER BY n DESC, city"),
            [["Oulu", 2, 34], ["Espoo", 1, None]],
        )
        self.assertEqual(self.error_code("SELECT name FROM people GROUP BY city"), "SEMANTIC_ERROR")

    def test_joins(self):
        self.assertEqual(
            self.rows("SELECT p.name, SUM(o.amount) FROM people p LEFT JOIN orders o ON o.pid = p.id GROUP BY p.name ORDER BY 1"),
            [["Ann", 12.75], ["Bob", None], ["Cid", 1.0]],
        )
        self.assertEqual(self.rows("SELECT COUNT(*) FROM people, orders"), [[12]])
        self.assertEqual(self.error_code("SELECT id FROM people p JOIN people q ON p.id = q.id"), "SEMANTIC_ERROR")

    def test_subqueries(self):
        self.assertEqual(self.rows("SELECT name FROM people WHERE id IN (SELECT pid FROM orders) ORDER BY 1"), [["Ann"], ["Cid"]])
        self.assertEqual(self.rows("SELECT name FROM people WHERE id NOT IN (SELECT pid FROM orders)"), [])
        self.assertEqual(
            self.rows("SELECT name, (SELECT COUNT(*) FROM orders o WHERE o.pid = p.id) FROM people p ORDER BY 1"),
            [["Ann", 2], ["Bob", 0], ["Cid", 1]],
        )
        self.assertEqual(self.error_code("SELECT (SELECT id FROM people)"), "SUBQUERY_CARDINALITY")

    def test_ctes_and_derived_tables(self):
        self.assertEqual(
            self.rows("WITH t(a) AS (SELECT id FROM people), u AS (SELECT a * 10 AS b FROM t) SELECT SUM(b) FROM u"), [[60]]
        )
        self.assertEqual(self.rows("SELECT d.n FROM (SELECT COUNT(*) AS n FROM orders) d"), [[4]])
        self.assertEqual(self.error_code("WITH a AS (SELECT * FROM a) SELECT 1"), "SEMANTIC_ERROR")

    def test_scalar_functions(self):
        self.assertEqual(
            self.rows(
                "SELECT ROUND(2.345, 2), SUBSTR('hello', 2, 3), COALESCE(NULL, 'x'), "
                "DATE_DIFF('day', DATE '2024-01-01', DATE '2024-02-01')"
            ),
            [["2.35", "ell", "x", 31]],
        )
        self.assertEqual(self.rows("SELECT UPPER('abc'), LOWER('ÄB'), 'a%' LIKE 'a_', 2 BETWEEN 1 AND 3"),
                         [["ABC", "ÄB", True, True]])
        self.assertEqual(self.error_code("SELECT SQRT(-1)"), "INVALID_ARGUMENT")
        self.assertEqual(self.error_code("SELECT CONCAT(1.5e0)"), "TYPE_ERROR")

    def test_case_typing(self):
        resp = self.query("SELECT CASE WHEN id > 1 THEN 1 ELSE 2.5 END FROM people WHERE id = 1")
        self.assertEqual(resp["columns"][0]["type"], "DECIMAL(18,1)")
        self.assertEqual(resp["rows"], [["2.5"]])


if __name__ == "__main__":
    unittest.main()
