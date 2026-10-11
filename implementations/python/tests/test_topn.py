"""Unit tests for the vectorized TopN (``ORDER BY … LIMIT``), including its
prefilter on the first sort key, against a full sort (``optimize: false``)."""

import itertools
import unittest

from tests.helpers import EngineTestMixin

ROWS = 20_000


def _row(i: int) -> str:
    a = "" if i % 11 == 0 else (i * 7919) % 97
    b = "" if i % 13 == 0 else (i * 104729) % 1009 / 4
    s = "" if i % 17 == 0 else chr(97 + i % 26)
    return f"{i},{a},{b},{s}\n"


DATA = "id,a,b,s\n" + "".join(_row(i) for i in range(ROWS))


class TopNTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("t", DATA)

    def check(self, order_by, limit, offset=0):
        sql = f"SELECT id, a, b, s FROM t ORDER BY {order_by} LIMIT {limit} OFFSET {offset}"
        expected = self.query(sql, optimize=False, mode="vectorized")
        self.assertTrue(expected["ok"], expected)
        for threads in (1, 3):
            got = self.query(sql, mode="vectorized", threads=threads)
            self.assertEqual(got["rows"], expected["rows"], (sql, threads))

    def test_orders_with_nulls_ties_and_offsets(self):
        orders = [
            "a, id",
            "a DESC, b, id",
            "a NULLS FIRST, id DESC",
            "a DESC NULLS LAST, s, id",
            "b DESC NULLS FIRST, id",
            "s, a DESC, id",
            "s DESC NULLS FIRST, id",
        ]
        for order_by, (limit, offset) in itertools.product(orders, [(5, 0), (100, 2500), (3000, 0)]):
            self.check(order_by, limit, offset)

    def test_ties_keep_input_order(self):
        # no tie breaker: rows equal on every key come in scan order
        self.check("a", 50, 1990)
        self.check("s DESC", 2100)


if __name__ == "__main__":
    unittest.main()
