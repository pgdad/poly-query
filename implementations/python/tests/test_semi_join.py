"""Unit tests for correlated EXISTS evaluated as a hash semi-join
(execution/semi_join.py)."""

import itertools
import json
import unittest

from polyquery.analysis import bound as b
from polyquery.execution.context import ExecutionContext
from polyquery.execution.semi_join import exists_semi_join
from polyquery.sql.parser import parse
from polyquery.service import QueryOptions
from tests.helpers import EngineTestMixin

C = "id,k,name\n1,10,a\n2,20,b\n3,,c\n4,40,d\n5,50,e\n"
O = "oid,ck,status,x\n1,10,open,1\n2,10,done,0\n3,20,done,2\n4,,open,3\n5,40,open,0\n6,99,open,0\n"


class SemiJoinTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("c", C)
        self.load_csv("o", O)

    def result(self, sql, **options):
        resp = self.query(sql, **options)
        self.assertTrue(resp["ok"], resp)
        return [json.dumps(r, separators=(",", ":")) for r in resp["rows"]]

    def semi_join(self, sql):
        """The SemiJoin of the first EXISTS in ``sql`` (or None)."""
        engine = self.handler.engine
        plan = engine._plan(parse(sql).query, QueryOptions())
        ctx = ExecutionContext()
        ctx.subplans = plan.subplans
        exists = []

        def walk(node):
            for expr in node.expressions():
                exists.extend(e for e in b.walk(expr) if isinstance(e, b.Exists))
            for child in node.inputs():
                walk(child)

        walk(plan.root)
        return exists_semi_join(exists[0], ctx)

    def test_exists_and_not_exists_in_every_mode(self):
        queries = [
            "SELECT id FROM c WHERE EXISTS (SELECT 1 FROM o WHERE o.ck = c.k AND o.status = 'open') ORDER BY id",
            "SELECT id FROM c WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.ck = c.k AND o.status = 'open') ORDER BY id",
            "SELECT id, EXISTS (SELECT o.oid FROM o WHERE c.k = o.ck) FROM c ORDER BY id",
            "SELECT id FROM c WHERE EXISTS (SELECT DISTINCT status FROM o WHERE o.ck = c.k + 10) ORDER BY id",
            "SELECT COUNT(*) FROM c WHERE k > 10 AND EXISTS (SELECT 1 FROM o WHERE o.ck = c.k AND o.x >= 2)",
        ]
        expected = [
            ['[1]', '[4]'],
            ['[2]', '[3]', '[5]'],
            ['[1,true]', '[2,true]', '[3,false]', '[4,true]', '[5,false]'],
            ['[1]'],
            ['[1]'],
        ]
        for sql, rows in zip(queries, expected):
            self.assertIsNotNone(self.semi_join(sql), sql)
            for mode, threads in itertools.product(("row", "vectorized"), (1, 3)):
                self.assertEqual(self.result(sql, mode=mode, threads=threads), rows, (sql, mode, threads))

    def test_conditions_that_may_fail_keep_per_row_execution(self):
        # 10 / o.x fails for oid 6, whose key matches no outer row: never evaluated
        sql = "SELECT id FROM c WHERE EXISTS (SELECT 1 FROM o WHERE o.ck = c.k AND 10 / o.x > 4) ORDER BY id"
        self.assertIsNone(self.semi_join(sql))
        for mode in ("row", "vectorized"):
            self.assertEqual(self.error_code(sql, mode=mode), "DIVISION_BY_ZERO")  # oid 2 (key 10) divides by zero
        sql = "SELECT id FROM c WHERE id = 2 AND EXISTS (SELECT 1 FROM o WHERE o.ck = c.k AND 10 / o.x > 4) ORDER BY id"
        for mode in ("row", "vectorized"):
            self.assertEqual(self.result(sql, mode=mode), ['[2]'])

    def test_other_correlated_conditions_keep_per_row_execution(self):
        sql = "SELECT id FROM c WHERE EXISTS (SELECT 1 FROM o WHERE o.ck = c.k AND o.oid > c.id) ORDER BY id"
        self.assertIsNone(self.semi_join(sql))
        self.assertEqual(self.result(sql), ["[1]", "[2]", "[4]"])

    def test_aggregating_or_limited_subqueries_are_not_semi_joins(self):
        sql = "SELECT id FROM c WHERE EXISTS (SELECT COUNT(*) FROM o WHERE o.ck = c.k) ORDER BY id"
        self.assertIsNone(self.semi_join(sql))
        self.assertEqual(len(self.result(sql)), 5)  # an aggregate always has a row
        sql = "SELECT id FROM c WHERE EXISTS (SELECT 1 FROM o WHERE o.ck = c.k LIMIT 0)"
        self.assertIsNone(self.semi_join(sql))
        self.assertEqual(self.result(sql), [])


if __name__ == "__main__":
    unittest.main()
