"""Unit tests for UNION ALL (spec/changes/union-all.md): parsing, typing,
planning / EXPLAIN and execution under every execution option."""

import itertools
import unittest

from polyquery import errors
from polyquery.analysis import bound as b
from polyquery.analysis.binder import Binder
from polyquery.execution.compiler import evaluate_constant
from polyquery.planner import physical as pp
from polyquery.planner.pipeline import plan_statement
from polyquery.sql import ast
from polyquery.sql.parser import parse
from tests.helpers import EngineTestMixin

PEOPLE = "id,name,age\n1,Ann,34\n2,Bob,\n3,Cid,28\n"
ITEMS = "id,price\n1,2.50\n2,10.00\n"
ITEMS_SCHEMA = [{"name": "id", "type": "INT64"}, {"name": "price", "type": "DECIMAL(10,2)"}]


def _walk(node):
    yield node
    for child in node.inputs():
        yield from _walk(child)


class ParserTests(unittest.TestCase):
    def test_compound_branches(self):
        stmt = parse("SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 ORDER BY 1 LIMIT 2")
        query = stmt.query
        self.assertIsInstance(query.body, ast.Compound)
        self.assertEqual(len(query.body.branches), 3)
        self.assertEqual(len(query.order_by), 1)
        self.assertIsNotNone(query.limit)

    def test_single_select_is_not_a_compound(self):
        self.assertIsInstance(parse("SELECT 1").query.body, ast.Select)

    def test_errors(self):
        cases = {
            "SELECT 1 UNION SELECT 2": errors.UNSUPPORTED,
            "SELECT 1 UNION DISTINCT SELECT 2": errors.UNSUPPORTED,
            "SELECT 1 ORDER BY 1 UNION ALL SELECT 2": errors.PARSE_ERROR,
            "SELECT 1 LIMIT 1 UNION ALL SELECT 2": errors.PARSE_ERROR,
            "(SELECT 1) UNION ALL (SELECT 2)": errors.PARSE_ERROR,
            "SELECT 1 UNION ALL (SELECT 2)": errors.PARSE_ERROR,
            "SELECT 1 UNION ALL": errors.PARSE_ERROR,
        }
        for sql, code in cases.items():
            with self.assertRaises(errors.PolyQueryError, msg=sql) as cm:
                parse(sql)
            self.assertEqual(cm.exception.code, code, sql)


class UnionAllTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("people", PEOPLE)
        self.load_csv("items", ITEMS, schema=ITEMS_SCHEMA)

    def columns(self, sql: str) -> list[tuple[str, str]]:
        resp = self.query(sql)
        self.assertTrue(resp["ok"], resp)
        return [(c["name"], c["type"]) for c in resp["columns"]]

    def bind(self, sql: str) -> b.BoundStatement:
        return Binder(self.handler.engine.catalog, evaluate_constant).bind_statement(parse(sql).query)

    def test_binds_to_a_union_relation(self):
        query = self.bind("SELECT id FROM people UNION ALL SELECT 2.5").query
        self.assertIsInstance(query.from_, b.UnionRelation)
        self.assertEqual(len(query.from_.branches), 2)
        self.assertEqual([t.name for t in query.from_.types], ["DECIMAL(18,1)"])

    def test_result_types(self):
        self.assertEqual(self.columns("SELECT id AS v FROM people UNION ALL SELECT price FROM items"),
                         [("v", "DECIMAL(18,2)")])
        self.assertEqual(self.columns("SELECT 1 AS v UNION ALL SELECT 1.5e0"), [("v", "FLOAT64")])
        self.assertEqual(self.columns("SELECT NULL AS x UNION ALL SELECT DATE '2024-01-01'"), [("x", "DATE")])
        self.assertEqual(self.columns("SELECT NULL AS x UNION ALL SELECT NULL"), [("x", "STRING")])
        self.assertEqual(self.columns("SELECT name, age FROM people UNION ALL SELECT 'z', NULL"),
                         [("name", "STRING"), ("age", "INT64")])

    def test_values_are_converted(self):
        self.assertEqual(self.rows("SELECT id AS v FROM items UNION ALL SELECT price FROM items ORDER BY v"),
                         [["1.00"], ["2.00"], ["2.50"], ["10.00"]])
        self.assertEqual(self.error_code("SELECT 9223372036854775807 UNION ALL SELECT 1.5"), "NUMERIC_OVERFLOW")

    def test_semantic_and_type_errors(self):
        cases = {
            "SELECT id, name FROM people UNION ALL SELECT id FROM people": "SEMANTIC_ERROR",
            "SELECT name FROM people UNION ALL SELECT id FROM people": "TYPE_ERROR",
            "SELECT DATE '2024-01-01' UNION ALL SELECT TIMESTAMP '2024-01-01 00:00:00'": "TYPE_ERROR",
            "SELECT id FROM people UNION ALL SELECT 1 ORDER BY id + 1": "SEMANTIC_ERROR",
            "SELECT id FROM people UNION ALL SELECT 1 ORDER BY people.id": "SEMANTIC_ERROR",
            "SELECT id AS a FROM people UNION ALL SELECT 1 AS b ORDER BY b": "SEMANTIC_ERROR",
            "SELECT id FROM people UNION ALL SELECT 1 ORDER BY 2": "SEMANTIC_ERROR",
        }
        for sql, code in cases.items():
            self.assertEqual(self.error_code(sql), code, sql)

    def test_order_limit_apply_to_the_whole_result(self):
        self.assertEqual(self.rows("SELECT id FROM people UNION ALL SELECT id FROM items ORDER BY id DESC LIMIT 3 OFFSET 1"),
                         [[2], [2], [1]])
        self.assertEqual(self.rows("SELECT name FROM people UNION ALL SELECT 'Bob' ORDER BY 1"),
                         [["Ann"], ["Bob"], ["Bob"], ["Cid"]])

    def test_nested_uses(self):
        self.assertEqual(self.rows("WITH u AS (SELECT id FROM people UNION ALL SELECT id FROM items) "
                                   "SELECT COUNT(*), COUNT(DISTINCT id) FROM u"), [[5, 3]])
        self.assertEqual(self.rows("SELECT SUM(v) FROM (SELECT age AS v FROM people UNION ALL SELECT 8) t"), [[70]])
        self.assertEqual(self.rows("SELECT name FROM people WHERE id IN (SELECT 3 UNION ALL SELECT 1) ORDER BY name"),
                         [["Ann"], ["Cid"]])
        # correlated references pass through the branches
        self.assertEqual(self.rows("SELECT name FROM people p WHERE EXISTS (SELECT 1 FROM items i WHERE i.id = p.id "
                                   "UNION ALL SELECT 1 WHERE p.id = 3) ORDER BY name"),
                         [["Ann"], ["Bob"], ["Cid"]])

    def test_explain_shows_union_all_with_branch_children(self):
        plan = plan_statement(self.bind("SELECT id FROM people UNION ALL SELECT id FROM items"), pp.PlanOptions())
        unions = [n for n in _walk(plan.root) if isinstance(n, pp.UnionAll)]
        self.assertEqual(len(unions), 1)
        self.assertEqual(len(unions[0].branches), 2)
        self.assertEqual(plan.to_json()["children"][0]["op"], "UnionAll")

    def test_branches_read_only_required_columns(self):
        plan = plan_statement(
            self.bind("SELECT COUNT(*) FROM (SELECT id, name FROM people UNION ALL SELECT id, 'x' FROM items) t"),
            pp.PlanOptions(),
        )
        scans = [n for n in _walk(plan.root) if isinstance(n, pp.TableScan)]
        self.assertEqual([n.columns for n in scans], [[], []])

    def test_execution_options_agree(self):
        sql = ("SELECT k, n FROM (SELECT name AS k, age AS n FROM people UNION ALL "
               "SELECT 'i', id FROM items UNION ALL SELECT name, NULL FROM people WHERE id = 2) t ORDER BY k, n")
        expected = None
        for mode, threads, join, optimize in itertools.product(
            ("row", "vectorized"), (1, 4), ("hash", "merge", "nested_loop"), (True, False)
        ):
            resp = self.query(sql, mode=mode, threads=threads, join=join, optimize=optimize)
            self.assertTrue(resp["ok"], resp)
            if expected is None:
                expected = [list(r) for r in resp["rows"]]
            self.assertEqual([list(r) for r in resp["rows"]], expected, (mode, threads, join, optimize))
        self.assertEqual(expected, [["Ann", 34], ["Bob", None], ["Bob", None], ["Cid", 28], ["i", 1], ["i", 2]])

    def test_max_rows_applies_to_the_final_result(self):
        self.assertEqual(self.error_code("SELECT id FROM people UNION ALL SELECT id FROM items", max_rows=4),
                         "RESOURCE_LIMIT")
        resp = self.query("SELECT id FROM people UNION ALL SELECT id FROM items LIMIT 4", max_rows=4)
        self.assertTrue(resp["ok"], resp)


if __name__ == "__main__":
    unittest.main()
