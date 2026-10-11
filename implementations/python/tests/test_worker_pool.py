"""Unit tests for the persistent worker processes of parallel pipelines
(execution/worker_pool.py)."""

import json
import unittest

from tests.helpers import make_handler
from tests.test_execution import QUERIES, T, U


class WorkerPoolTests(unittest.TestCase):
    def setUp(self):
        # parallel_min_rows=1: every parallel pipeline runs in worker processes
        self.handler = make_handler(parallel_min_rows=1, test_functions=True)
        self.serial = make_handler()
        for handler in (self.handler, self.serial):
            for name, data in (("t", T), ("u", U)):
                self.load(handler, name, data)

    def tearDown(self):
        self.handler.engine.close()

    @staticmethod
    def load(handler, name, data, replace=False):
        resp = handler.handle({"op": "load", "table": name, "format": "csv", "data": data, "replace": replace})
        assert resp["ok"], resp

    def query(self, sql, handler=None, **options):
        return (handler or self.handler).handle({"op": "query", "sql": sql, "options": options})

    def rows(self, sql, handler=None, **options):
        resp = self.query(sql, handler, **options)
        self.assertTrue(resp["ok"], resp)
        return sorted(json.dumps(r) for r in resp["rows"])

    def pids(self):
        return [w.pid for w in self.handler.engine.pool._workers]

    def test_results_match_serial_execution(self):
        for sql in QUERIES:
            expected = self.rows(sql, self.serial)
            for mode in ("row", "vectorized"):
                self.assertEqual(self.rows(sql, mode=mode, threads=4), expected, (sql, mode))
        self.assertEqual(len(self.pids()), 4)

    def test_workers_are_reused_across_queries(self):
        self.rows("SELECT g, COUNT(*) FROM t GROUP BY g", threads=3)
        first = self.pids()
        self.assertEqual(len(first), 3)
        self.rows("SELECT s, SUM(v) FROM t WHERE v > 0 GROUP BY s", threads=3)
        self.rows("SELECT DISTINCT g FROM t", threads=2)  # fewer partitions: a subset of the workers
        self.assertEqual(self.pids(), first)

    def test_more_partitions_than_workers(self):
        self.rows("SELECT g FROM t GROUP BY g", threads=2)
        sql = "SELECT g, COUNT(*), SUM(v) FROM t GROUP BY g"
        self.assertEqual(self.rows(sql, threads=7), self.rows(sql, self.serial))

    def test_a_replaced_table_forks_new_workers(self):
        sql = "SELECT COUNT(*), SUM(id) FROM t WHERE id > 2"
        self.rows(sql, threads=4)
        before = self.pids()
        self.load(self.handler, "t", "id,g,v,s,f\n1,1,1,a,1.0\n5,1,1,a,1.0\n7,2,2,b,2.0\n", replace=True)
        self.assertEqual(self.rows(sql, threads=4), [json.dumps([2, 12])])
        self.assertNotEqual(self.pids(), before)

    def test_errors_are_returned_and_workers_survive(self):
        resp = self.query("SELECT SUM(id * 4611686018427387904) FROM t", threads=4)
        self.assertEqual(resp["error"]["code"], "NUMERIC_OVERFLOW")
        before = self.pids()
        self.assertEqual(self.rows("SELECT COUNT(*) FROM t WHERE v > 0", threads=4), self.rows("SELECT COUNT(*) FROM t WHERE v > 0", self.serial))
        self.assertEqual(self.pids(), before)

    def test_timeout_stops_the_workers(self):
        resp = self.query("SELECT g, SUM(PQ_SLEEP(5)) FROM t GROUP BY g", threads=4, timeout_ms=100)
        self.assertEqual(resp["error"]["code"], "TIMEOUT")
        self.assertEqual(self.pids(), [])
        self.assertEqual(self.rows("SELECT COUNT(*) FROM t", threads=4), [json.dumps([120])])

    def test_busy_pool_falls_back_to_forking_per_query(self):
        pool = self.handler.engine.pool
        sql = "SELECT g, COUNT(*), MIN(s) FROM t GROUP BY g"
        with pool._lock:  # another query holds the pool
            self.assertEqual(self.rows(sql, threads=4), self.rows(sql, self.serial))
        self.assertEqual(self.pids(), [])


if __name__ == "__main__":
    unittest.main()
