"""Unit tests for the Phase 5 executors: row vs vectorized execution, join
algorithms, parallel (partitioned / forked) pipelines, the vector
expression compiler, and columnar group states."""

import gc
import itertools
import json
import unittest

from polyquery.analysis import bound as b
from polyquery.datatypes import INT64
from polyquery.execution import context
from polyquery.execution.aggregates import make_accumulator
from polyquery.execution.common import merge_pairs, sort_permutation
from polyquery.execution.group_states import make_state
from tests.helpers import EngineTestMixin, make_handler

T = "id,g,v,s,f\n" + "".join(
    f"{i},{i % 4 if i % 7 else ''},{(i * 37) % 23 - 5 if i % 5 else ''},{'abc'[i % 3] if i % 6 else ''},{i / 8}\n"
    for i in range(1, 121)
)
U = "uid,tid,w\n" + "".join(f"{i},{(i * 13) % 130 if i % 9 else ''},{i % 3}\n" for i in range(1, 91))

QUERIES = [
    "SELECT g, COUNT(*), SUM(v), AVG(f), MIN(s), MAX(v), COUNT(DISTINCT s) FROM t GROUP BY g",
    "SELECT COUNT(*), SUM(v * 2), MIN(f) FROM t WHERE v > 0",
    "SELECT t.id, u.uid, u.w FROM t JOIN u ON u.tid = t.id AND u.w > 0",
    "SELECT t.id, u.uid FROM t LEFT JOIN u ON u.tid = t.id AND u.w = 1",
    "SELECT t.id, u.uid FROM t JOIN u ON u.tid > t.id + 100",
    "SELECT t.s, COUNT(*) FROM t JOIN u ON u.tid = t.id GROUP BY t.s",
    "SELECT DISTINCT g, s FROM t",
    "SELECT id, v FROM t ORDER BY v DESC NULLS FIRST, id LIMIT 7 OFFSET 2",
    "SELECT id FROM t WHERE s LIKE 'a%' OR v IS NULL ORDER BY id",
    "SELECT id, CASE WHEN v > 3 THEN 'hi' WHEN v < 0 THEN 'lo' END FROM t WHERE id IN (SELECT tid FROM u)",
]


class ModeEquivalenceTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("t", T)
        self.load_csv("u", U)

    def result(self, sql, **options):
        resp = self.query(sql, **options)
        self.assertTrue(resp["ok"], resp)
        return sorted(json.dumps(r) for r in resp["rows"])

    def test_every_option_combination_returns_the_same_rows(self):
        for sql in QUERIES:
            expected = self.result(sql, mode="row", optimize=False)
            for mode, join, threads, optimize in itertools.product(
                ("row", "vectorized", "auto"), ("auto", "hash", "merge", "nested_loop"), (1, 3), (True, False)
            ):
                got = self.result(sql, mode=mode, join=join, threads=threads, optimize=optimize)
                self.assertEqual(got, expected, (sql, mode, join, threads, optimize))

    def test_forked_workers_return_the_same_rows(self):
        forked = make_handler(parallel_min_rows=1)
        for name, data in (("t", T), ("u", U)):
            self.assertTrue(forked.handle({"op": "load", "table": name, "format": "csv", "data": data})["ok"])
        for sql in QUERIES:
            expected = self.result(sql)
            for mode in ("row", "vectorized"):
                resp = forked.handle({"op": "query", "sql": sql, "options": {"mode": mode, "threads": 4}})
                self.assertTrue(resp["ok"], resp)
                self.assertEqual(sorted(json.dumps(r) for r in resp["rows"]), expected, (sql, mode))
        resp = forked.handle({"op": "query", "sql": "SELECT SUM(id * 4611686018427387904) FROM t", "options": {"threads": 4}})
        self.assertEqual(resp["error"]["code"], "NUMERIC_OVERFLOW")

    def test_errors_are_the_same_in_every_mode(self):
        for mode, threads in itertools.product(("row", "vectorized"), (1, 4)):
            self.assertEqual(self.error_code("SELECT id / (g - g) FROM t", mode=mode, threads=threads), "DIVISION_BY_ZERO")
            self.assertEqual(
                self.error_code("SELECT SUM(id * 4611686018427387904) FROM t", mode=mode, threads=threads),
                "NUMERIC_OVERFLOW",
            )

    def test_guarded_operands_are_not_evaluated(self):
        sql = "SELECT id FROM t WHERE g <> 0 AND 12 / g > 3 ORDER BY id"
        expected = self.result(sql, mode="row")
        self.assertEqual(self.result(sql, mode="vectorized"), expected)
        sql = "SELECT CASE WHEN g = 0 THEN -1 ELSE 12 / g END FROM t"
        self.assertEqual(self.result(sql, mode="vectorized"), self.result(sql, mode="row"))

    def test_unknown_mode_and_join_are_unsupported(self):
        self.assertEqual(self.error_code("SELECT 1", mode="quantum"), "UNSUPPORTED")
        self.assertEqual(self.error_code("SELECT 1", join="teleport"), "UNSUPPORTED")
        self.assertEqual(self.error_code("SELECT 1", threads=0), "INVALID_REQUEST")


class PlanShapeTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("t", T)
        self.load_csv("u", U)
        self.load_csv("small", "k,name\n1,a\n2,b\n")

    def ops(self, sql, **options):
        resp = self.request(op="explain", sql=sql, options=options)
        self.assertTrue(resp["ok"], resp)
        out = []

        def walk(node):
            out.append(node)
            for child in node["children"]:
                walk(child)

        walk(resp["plan"])
        return out

    def test_join_option_selects_the_algorithm(self):
        sql = "SELECT * FROM t JOIN u ON u.tid = t.id"
        for join, op in (("hash", "HashJoin"), ("merge", "MergeJoin"), ("nested_loop", "NestedLoopJoin"), ("auto", "HashJoin")):
            self.assertIn(op, [n["op"] for n in self.ops(sql, join=join)], join)
        # non-equi joins always use nested loops
        self.assertIn("NestedLoopJoin", [n["op"] for n in self.ops("SELECT * FROM t JOIN u ON u.tid < t.id", join="merge")])

    def test_top_n_only_with_optimization(self):
        sql = "SELECT id FROM t ORDER BY v LIMIT 3"
        self.assertIn("TopN", [n["op"] for n in self.ops(sql)])
        ops = [n["op"] for n in self.ops(sql, optimize=False)]
        self.assertNotIn("TopN", ops)
        self.assertIn("Sort", ops)

    def test_threads_insert_gathers(self):
        ops = self.ops("SELECT g, COUNT(*) FROM t WHERE v > 1 GROUP BY g", threads=4)
        gather = next(n for n in ops if n["op"] == "Gather")
        self.assertEqual(gather["partitions"], 4)
        self.assertNotIn("Gather", [n["op"] for n in self.ops("SELECT g, COUNT(*) FROM t GROUP BY g")])

    def test_join_reordering_starts_with_the_smallest_input(self):
        sql = "SELECT * FROM t, u, small WHERE u.tid = t.id AND small.k = u.w"
        ops = self.ops(sql)
        scans = [n["table"] for n in ops if n["op"] == "TableScan"]
        self.assertEqual(scans[0], "small")
        self.assertNotIn("CROSS", [n.get("join_type") for n in ops])
        unordered = [n.get("join_type") for n in self.ops(sql, optimize=False)]
        self.assertIn("CROSS", unordered)

    def test_constant_folding_and_simplification(self):
        filters = [n for n in self.ops("SELECT id FROM t WHERE 1 + 1 = 2 AND v > 2 * 3") if n["op"] == "Filter"]
        self.assertEqual([f["predicate"] for f in filters], ["(v > 6)"])
        # failing constants stay unevaluated: no rows, no error
        self.assertEqual(self.rows("SELECT 1 / 0 FROM t WHERE id < 0"), [])


class KernelTests(unittest.TestCase):
    def test_merge_pairs_skips_nulls_and_pairs_runs(self):
        li, ri = merge_pairs([3, None, 1, 3], [3, 3, None, 2])
        self.assertEqual(sorted(zip(li, ri)), [(0, 0), (0, 1), (3, 0), (3, 1)])
        li, ri = merge_pairs([(1, None), (1, 2)], [(1, 2), (1, None)])
        self.assertEqual(list(zip(li, ri)), [(1, 0)])

    def test_sort_permutation_is_stable_with_null_placement(self):
        col = [2, None, 1, 2, None]
        asc = b.SortKey(0, descending=False, nulls_first=True)
        self.assertEqual(sort_permutation([col], 5, [asc]), [1, 4, 2, 0, 3])
        desc = b.SortKey(0, descending=True, nulls_first=False)
        self.assertEqual(sort_permutation([col], 5, [desc]), [0, 3, 2, 1, 4])

    def test_group_states_match_accumulators_and_merge(self):
        values = [5, None, -3, 7, 7, None, 2]
        ids = [0, 1, 0, 2, 1, 1, 0]
        arg = b.ColumnRef(INT64, 1, 0, "x")
        for name, distinct in (("SUM", False), ("COUNT", False), ("MIN", False), ("MAX", False), ("AVG", False), ("COUNT", True)):
            call = b.AggCall(INT64, name, arg, distinct)
            expected = []
            for g in range(3):
                acc = make_accumulator(call)
                for i, v in zip(ids, values):
                    if i == g:
                        acc.add(v)
                expected.append(acc.result())
            whole = make_state(call)
            whole.grow(3)
            whole.update_rows(ids, values)
            self.assertEqual(whole.results(), expected, name)
            # two partial states merged (the second sees the groups in another order)
            first, second = make_state(call), make_state(call)
            first.grow(3)
            first.update_rows(ids[:3], values[:3])
            second.grow(3)
            second.update_rows([{0: 2, 1: 0, 2: 1}[i] for i in ids[3:]], values[3:])
            first.merge(second, [1, 2, 0])  # second's group g is first's group mapping[g]
            self.assertEqual(first.results(), expected, name)

    def test_gc_pauses_nest(self):
        was = gc.isenabled()
        gc.enable()
        try:
            with context.gc_paused():
                with context.gc_paused():
                    self.assertFalse(gc.isenabled())
                self.assertFalse(gc.isenabled())
            self.assertTrue(gc.isenabled())
        finally:
            if not was:
                gc.disable()


if __name__ == "__main__":
    unittest.main()
