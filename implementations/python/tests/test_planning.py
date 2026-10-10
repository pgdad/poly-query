"""Unit tests for semantic analysis, logical/physical planning and EXPLAIN."""

import json
import tempfile
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

    def test_group_by_expression_with_subquery(self):
        sql = (
            "SELECT (SELECT COUNT(*) FROM orders o WHERE o.pid = p.id) AS n, COUNT(*) FROM people p "
            "GROUP BY (SELECT COUNT(*) FROM orders o WHERE o.pid = p.id) ORDER BY 1"
        )
        self.assertEqual(self.rows(sql), [[0, 1], [1, 1], [2, 1]])

    def test_round_extreme_digits_and_limit_validation(self):
        self.assertEqual(self.rows("SELECT ROUND(1.5, -100), ROUND(5, -100000000), ROUND(1e0, -5000)"), [["0", 0, 0.0]])
        self.assertEqual(self.request(op="explain", sql="SELECT 1 LIMIT -1")["error"]["code"], "INVALID_ARGUMENT")

    def test_case_typing(self):
        resp = self.query("SELECT CASE WHEN id > 1 THEN 1 ELSE 2.5 END FROM people WHERE id = 1")
        self.assertEqual(resp["columns"][0]["type"], "DECIMAL(18,1)")
        self.assertEqual(resp["rows"], [["2.5"]])


def _plan_nodes(plan: dict):
    yield plan
    for child in plan.get("children", []):
        yield from _plan_nodes(child)


class AccessPathTests(EngineTestMixin, unittest.TestCase):
    """Index selection, column pruning, row-group skipping, build sides."""

    def setUp(self):
        super().setUp()
        rows = "\n".join(f"{i},{i % 7},{i * 0.5:.2f},c{i % 3}" for i in range(1, 1001))
        self.load_csv("t", "id,g,amount,cat\n" + rows + "\n")
        self.load_csv("small", "id,v\n1,x\n2,y\n")
        for sql in (
            "CREATE INDEX t_id ON t (id) USING HASH",
            "CREATE INDEX t_amount ON t (amount)",
            "CREATE INDEX t_g ON t (g) USING BTREE",
        ):
            self.assertTrue(self.query(sql)["ok"], sql)

    def explain(self, sql: str, **options) -> list[dict]:
        req = {"op": "explain", "sql": sql}
        if options:
            req["options"] = options
        resp = self.handler.handle(req)
        self.assertTrue(resp["ok"], resp)
        return list(_plan_nodes(resp["plan"]))

    def index_used(self, sql: str, **options) -> str | None:
        scans = [n for n in self.explain(sql, **options) if n["op"] == "IndexScan"]
        return scans[0]["index"] if scans else None

    def test_index_selection_by_selectivity(self):
        self.assertEqual(self.index_used("SELECT * FROM t WHERE id = 5"), "t_id")
        self.assertEqual(self.index_used("SELECT * FROM t WHERE id IN (1, 2)"), "t_id")
        self.assertIsNone(self.index_used("SELECT * FROM t WHERE id > 5"))  # hash: no ranges
        self.assertEqual(self.index_used("SELECT * FROM t WHERE amount BETWEEN 10 AND 20"), "t_amount")
        self.assertIsNone(self.index_used("SELECT * FROM t WHERE amount > 10"))  # ~98% of the rows
        self.assertIsNone(self.index_used("SELECT * FROM t WHERE g = 3"))  # 1/7 > 10%
        self.assertIsNone(self.index_used("SELECT * FROM t WHERE id = 5", use_indexes=False))

    def test_index_results_match_full_scans(self):
        for where in ("id = 5", "id IN (3, 999, NULL)", "amount >= 499.5", "amount < 1",
                      "amount BETWEEN 10 AND 12.25 AND cat = 'c1'", "id = 5.0", "id = 5.5"):
            sql = f"SELECT * FROM t WHERE {where} ORDER BY id"
            self.assertEqual(self.query(sql)["rows"], self.query(sql, use_indexes=False)["rows"], where)

    def test_index_lifecycle_statements(self):
        self.assertEqual(self.error_code("CREATE INDEX t_id ON small (id)"), "ALREADY_EXISTS")
        self.assertTrue(self.query("CREATE INDEX IF NOT EXISTS t_id ON small (id)")["ok"])
        self.assertTrue(self.query("DROP INDEX T_ID")["ok"])
        self.assertIsNone(self.index_used("SELECT * FROM t WHERE id = 5"))
        self.assertTrue(self.query("DROP INDEX IF EXISTS t_id")["ok"])
        schema = self.request(op="schema", table="t")
        self.assertEqual([i["name"] for i in schema["indexes"]], ["t_amount", "t_g"])

    def test_column_pruning(self):
        scans = [n for n in self.explain("SELECT COUNT(*) FROM t WHERE g = 1") if n["op"] == "TableScan"]
        self.assertEqual([s["columns"] for s in scans], [["g"]])

    def test_column_pruning_through_derived_tables(self):
        sql = "WITH w AS (SELECT * FROM t) SELECT id FROM (SELECT * FROM w) d WHERE g = 1 ORDER BY amount"
        scans = [n for n in self.explain(sql) if n["op"] == "TableScan"]
        self.assertEqual([sorted(s["columns"]) for s in scans], [["amount", "g", "id"]])
        self.assertEqual(self.rows(sql)[:2], [[1], [8]])
        scans = [n for n in self.explain("SELECT COUNT(*) FROM (SELECT DISTINCT g, cat FROM t) d") if n["op"] == "TableScan"]
        self.assertEqual([sorted(s["columns"]) for s in scans], [["cat", "g"]])

    def test_build_side_is_the_smaller_input(self):
        sql = "SELECT * FROM t JOIN small s ON s.id = t.id"
        join = next(n for n in self.explain(sql) if n["op"] == "HashJoin")
        self.assertEqual(join["build"], "right")
        sql = "SELECT * FROM small s JOIN t ON s.id = t.id"
        join = next(n for n in self.explain(sql) if n["op"] == "HashJoin")
        self.assertEqual(join["build"], "left")
        self.assertEqual(sorted(map(tuple, self.rows(sql))), [(1, "x", 1, 1, 0.5, "c1"), (2, "y", 2, 2, 1.0, "c2")])
        left = next(n for n in self.explain("SELECT * FROM small s LEFT JOIN t ON s.id = t.id") if n["op"] == "HashJoin")
        self.assertEqual(left["build"], "right")

    def test_row_group_skipping_on_pqcf_tables(self):
        with tempfile.TemporaryDirectory() as d:
            self.handler.config.data_dir = d
            self.assertTrue(self.request(op="save", table="t", path="t.pqcf", options={"row_group_size": 100})["ok"])
            self.assertEqual(self.request(op="open", table="tf", path="t.pqcf")["error"]["code"], "ALREADY_EXISTS")
            for name in ("t_id", "t_amount", "t_g"):
                self.query(f"DROP INDEX {name}")
            self.assertTrue(self.request(op="open", table="tf", path="t.pqcf", options={"mmap": True})["ok"])
            scan = next(n for n in self.explain("SELECT id FROM tf WHERE id > 950") if n["op"] == "TableScan")
            self.assertEqual(scan["row_groups"], 10)
            self.assertEqual(scan["row_group_filter"], ["id > 950"])
            for where in ("id > 950", "id BETWEEN 120 AND 130", "id IN (5, 905)", "id < 0", "amount = 250.5"):
                sql = f"SELECT id FROM tf WHERE {where} ORDER BY id"
                expected = self.query(sql.replace("tf", "t"), use_indexes=False)["rows"]
                self.assertEqual(self.query(sql)["rows"], expected, where)


if __name__ == "__main__":
    unittest.main()
