"""Unit tests for the latency optimizations: the persistent worker pool,
range-partitioned parallel sorts, hash-exchange aggregation, automatic
parallelism, the anti-join variant of LEFT hash joins and the count-only
result path. Small tables are forced through the parallel code paths by
lowering the size thresholds; every result must equal the serial one,
including the row order."""

import json
import unittest
from unittest import mock

from polyquery.execution import vector_engine
from polyquery.planner import physical
from tests.helpers import make_handler

T = "id,g,v,s,f\n" + "".join(
    f"{i},{i % 37 if i % 7 else ''},{(i * 37) % 23 - 5 if i % 5 else ''},"
    f"{'abcde'[i % 5] * (i % 3 + 1) if i % 6 else ''},{(i * 7919) % 101 / 8}\n"
    for i in range(1, 1201)
)
U = "uid,tid,w\n" + "".join(f"{i},{(i * 13) % 1300 if i % 9 else ''},{i % 3}\n" for i in range(1, 901))

ORDERED = [
    "SELECT id, s FROM t ORDER BY s, id",
    "SELECT s, v, id FROM t ORDER BY s DESC, v, id DESC",
    "SELECT g, f, id FROM t ORDER BY g DESC NULLS FIRST, f",
    "SELECT v, s FROM t ORDER BY v NULLS FIRST, s NULLS LAST",
    "SELECT f FROM t ORDER BY f",
    "SELECT id, v * 2 AS w FROM t WHERE id > 50 ORDER BY w DESC, id",
    "SELECT t.id, u.uid FROM t JOIN u ON u.tid = t.id ORDER BY u.w, t.id DESC",
]
GROUPED = [
    "SELECT id % 500, COUNT(*), SUM(v), AVG(f), MIN(s), MAX(v) FROM t GROUP BY id % 500",
    "SELECT g, s, COUNT(DISTINCT v), SUM(f) FROM t GROUP BY g, s",
    "SELECT v, COUNT(*) FROM t GROUP BY v",
    "SELECT u.tid, COUNT(*), SUM(t.v) FROM t JOIN u ON u.tid = t.id GROUP BY u.tid",
]
ANTI = [
    "SELECT COUNT(*) FROM t LEFT JOIN u ON u.tid = t.id WHERE u.uid IS NULL",
    "SELECT t.id, u.w FROM t LEFT JOIN u ON u.tid = t.id WHERE u.tid IS NULL AND t.id > 10",
    "SELECT t.id FROM t LEFT JOIN u ON u.tid = t.g WHERE u.uid IS NULL",
]


def _load(handler):
    for name, data in (("t", T), ("u", U)):
        assert handler.handle({"op": "load", "table": name, "format": "csv", "data": data})["ok"]


class PoolResultTests(unittest.TestCase):
    """Parallel execution in pool workers returns exactly the serial rows."""

    @classmethod
    def setUpClass(cls):
        cls.serial = make_handler(threads=1)
        _load(cls.serial)

    def rows(self, handler, sql, **options):
        resp = handler.handle({"op": "query", "sql": sql, "options": options})
        self.assertTrue(resp["ok"], (sql, resp))
        return [list(row) for row in resp["rows"]]

    def check(self, queries, threads=(3, 4, 7)):
        pooled = make_handler(parallel_min_rows=1)
        _load(pooled)
        try:
            for sql in queries:
                expected = self.rows(self.serial, sql)
                for n in threads:
                    self.assertEqual(self.rows(pooled, sql, threads=n), expected, (sql, n))
        finally:
            pooled.engine.close()

    def test_range_partitioned_sorts(self):
        with mock.patch.object(physical, "RANGE_SORT_MIN_ROWS", 0):
            self.check(ORDERED)

    def test_hash_exchange_aggregation_keeps_group_order(self):
        with mock.patch.object(vector_engine, "EXCHANGE_MIN_GROUPS", 0):
            self.check(GROUPED)

    def test_anti_joins(self):
        self.check(ANTI, threads=(1, 4))

    def test_worker_errors_are_reported(self):
        pooled = make_handler(parallel_min_rows=1)
        _load(pooled)
        try:
            resp = pooled.handle({"op": "query", "sql": "SELECT SUM(id / (g - g)) FROM t", "options": {"threads": 4}})
            self.assertEqual(resp["error"]["code"], "DIVISION_BY_ZERO")
            # the pool keeps working after a failed task
            self.assertEqual(self.rows(pooled, "SELECT COUNT(*) FROM t", threads=4), [[1200]])
        finally:
            pooled.engine.close()

    def test_pool_sees_catalog_changes(self):
        pooled = make_handler(parallel_min_rows=1)
        _load(pooled)
        try:
            sql = "SELECT COUNT(*), SUM(v) FROM t WHERE id > 0"
            self.assertEqual(self.rows(pooled, sql, threads=4), self.rows(self.serial, sql))
            data = "id,v\n" + "".join(f"{i},{i}\n" for i in range(1, 101))
            resp = pooled.handle({"op": "load", "table": "t", "format": "csv", "data": data, "replace": True})
            self.assertTrue(resp["ok"], resp)
            self.assertEqual(self.rows(pooled, sql, threads=4), [[100, 5050]])
        finally:
            pooled.engine.close()


class AutomaticParallelismTests(unittest.TestCase):
    def ops(self, handler, sql, **options):
        plan = handler.handle({"op": "explain", "sql": sql, "options": options})["plan"]
        out = []

        def walk(node):
            out.append(node["op"])
            for child in node["children"]:
                walk(child)

        walk(plan)
        return out

    def test_small_inputs_keep_serial_plans(self):
        handler = make_handler()  # default --parallel-min-rows
        _load(handler)
        self.assertNotIn("Gather", self.ops(handler, "SELECT g, COUNT(*) FROM t GROUP BY g"))
        self.assertIn("Gather", self.ops(handler, "SELECT g, COUNT(*) FROM t GROUP BY g", threads=4))

    def test_large_inputs_are_parallelized(self):
        handler = make_handler(parallel_min_rows=100)
        _load(handler)
        try:
            self.assertIn("Gather", self.ops(handler, "SELECT g, COUNT(*) FROM t GROUP BY g"))
            # the row engine (the serial baseline) stays serial unless asked
            self.assertNotIn("Gather", self.ops(handler, "SELECT g, COUNT(*) FROM t GROUP BY g", mode="row"))
        finally:
            handler.engine.close()


class AntiJoinPlanTests(unittest.TestCase):
    def setUp(self):
        self.handler = make_handler()
        _load(self.handler)
        nullable = "uid,tid,w\n1,1,\n2,,5\n3,3,1\n"
        self.handler.handle({"op": "load", "table": "n", "format": "csv", "data": nullable})

    def join(self, sql, **options):
        plan = self.handler.handle({"op": "explain", "sql": sql, "options": options})["plan"]
        while plan["op"] != "HashJoin":
            plan = plan["children"][0]
        return plan

    def test_is_null_on_a_column_without_nulls_makes_an_anti_join(self):
        self.assertTrue(self.join(ANTI[0]).get("anti"))
        self.assertTrue(self.join(ANTI[1]).get("anti"))  # on the join key

    def test_nullable_column_or_no_optimization_keeps_the_left_join(self):
        sql = "SELECT t.id FROM t LEFT JOIN n ON n.uid = t.id WHERE n.w IS NULL"
        self.assertNotIn("anti", self.join(sql))
        self.assertNotIn("anti", self.join(ANTI[0], optimize=False))
        rows = self.handler.handle({"op": "query", "sql": sql + " AND t.id < 4"})["rows"]
        self.assertEqual(sorted(map(list, rows)), [[1]])  # id 1 matches a row whose w is NULL

    def test_anti_join_results_match_every_mode(self):
        for sql in ANTI:
            expected = sorted(
                json.dumps(r)
                for r in self.handler.handle({"op": "query", "sql": sql, "options": {"optimize": False}})["rows"]
            )
            for mode in ("row", "vectorized"):
                resp = self.handler.handle({"op": "query", "sql": sql, "options": {"mode": mode}})
                self.assertEqual(sorted(json.dumps(r) for r in resp["rows"]), expected, (sql, mode))


class CountResultTests(unittest.TestCase):
    def test_count_matches_rows_and_limits(self):
        handler = make_handler()
        _load(handler)
        for sql in ORDERED + GROUPED + ["EXPLAIN SELECT 1"]:
            for mode in ("row", "vectorized"):
                rows = handler.handle({"op": "query", "sql": sql, "options": {"mode": mode}})
                count = handler.handle({"op": "query", "sql": sql, "options": {"mode": mode, "result": "count"}})
                self.assertTrue(count["ok"], count)
                self.assertNotIn("rows", count)
                self.assertEqual(count["row_count"], rows["row_count"], sql)
                self.assertEqual(count["columns"], rows["columns"], sql)
        resp = handler.handle({"op": "query", "sql": "CREATE INDEX ix ON t (id)", "options": {"result": "count"}})
        self.assertEqual((resp["ok"], resp["row_count"]), (True, 0))
        resp = handler.handle({"op": "query", "sql": "SELECT id FROM t", "options": {"result": "count", "max_rows": 5}})
        self.assertEqual(resp["error"]["code"], "RESOURCE_LIMIT")


if __name__ == "__main__":
    unittest.main()
