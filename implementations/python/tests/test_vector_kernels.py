"""Vectorized kernel fast paths (whole-vector arithmetic, per-distinct-value
evaluation of functions and LIKE) must match the row engine exactly,
including errors."""

import unittest

from tests.helpers import EngineTestMixin

N = 3000  # several batches with many repeated values
DATA = "id,a,b,d,e,s\n" + "".join(
    f"{i},{(i * 7919) % 201 - 100},{(i % 13) - 6 if i % 11 else ''},{i % 50}.{i % 100:02d},"
    f"{(i * 31) % 1000 / 10:.1f},{['alpha', 'Beta', 'gamma', '', 'x1'][i % 5] if i % 17 else ''}\n"
    for i in range(1, N + 1)
)
SCHEMA = [
    {"name": "id", "type": "INT64"},
    {"name": "a", "type": "INT64"},
    {"name": "b", "type": "INT64"},
    {"name": "d", "type": "DECIMAL(6,2)"},
    {"name": "e", "type": "DECIMAL(5,1)"},
    {"name": "s", "type": "STRING"},
]

SAME = [
    "SELECT id % 7, id / 7, a % 7, a / 7, a % 3 - a / 3 FROM t",
    "SELECT a % b, a / b FROM t WHERE b <> 0",
    "SELECT d + e, d - e, e - d, d * e, d * 3, 2 * e, d + 1, a - d FROM t",
    "SELECT UPPER(s), LOWER(s), LENGTH(s), SUBSTR(s, 2, 2), s LIKE '%a%', s NOT LIKE 'B%' FROM t",
    "SELECT COALESCE(s, 'none'), CASE WHEN s LIKE '_e%' THEN 1 ELSE 0 END FROM t",
]
ERRORS = [
    "SELECT a % (b - b) FROM t",
    "SELECT id / (a - a) FROM t",
    "SELECT d * d * d * d * d * d * d * d * d FROM t",
    "SELECT CAST(s AS INT64) FROM t",
]


class VectorKernelTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("t", DATA, schema=SCHEMA)

    def test_results_match_the_row_engine(self):
        for sql in SAME:
            row = self.query(sql, mode="row")
            self.assertTrue(row["ok"], (sql, row))
            for threads in (1, 4):
                vec = self.query(sql, mode="vectorized", threads=threads)
                self.assertEqual(vec["rows"], row["rows"], (sql, threads))

    def test_errors_match_the_row_engine(self):
        for sql in ERRORS:
            expected = self.error_code(sql, mode="row")
            self.assertEqual(self.error_code(sql, mode="vectorized"), expected, sql)


if __name__ == "__main__":
    unittest.main()
