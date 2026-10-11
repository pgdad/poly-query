"""End-to-end tests through the protocol request handler."""

import unittest

from tests.helpers import EngineTestMixin

PEOPLE = "id,name,age,score,joined\n1,Ann,34,1.5,2020-01-15\n2,bob,,2.25,\n3,Cid,28,,2019-07-30\n"


class QueryTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("people", PEOPLE)

    def test_projection_filter_order(self):
        self.assertEqual(self.rows("SELECT name, age + 1 AS a FROM people WHERE age IS NOT NULL ORDER BY a DESC"),
                         [["Ann", 35], ["Cid", 29]])

    def test_nulls_ordering(self):
        self.assertEqual(self.rows("SELECT id FROM people ORDER BY age"), [[2], [3], [1]])
        self.assertEqual(self.rows("SELECT id FROM people ORDER BY age DESC"), [[1], [3], [2]])
        self.assertEqual(self.rows("SELECT id FROM people ORDER BY age NULLS LAST"), [[3], [1], [2]])
        self.assertEqual(self.rows("SELECT id FROM people ORDER BY score DESC NULLS FIRST, id"), [[3], [2], [1]])

    def test_output_names_and_types(self):
        resp = self.query("SELECT id, id * 2, p.name, 1.50 AS d, NULL FROM people p LIMIT 1")
        self.assertEqual([(c["name"], c["type"]) for c in resp["columns"]],
                         [("id", "INT64"), ("_col2", "INT64"), ("name", "STRING"), ("d", "DECIMAL(3,2)"),
                          ("_col5", "STRING")])

    def test_aggregates(self):
        self.assertEqual(self.rows("SELECT COUNT(*), COUNT(age), SUM(age), AVG(age), MIN(name), MAX(joined) FROM people"),
                         [[3, 2, 62, 31.0, "Ann", "2020-01-15"]])
        self.assertEqual(self.rows("SELECT COUNT(*), SUM(age) FROM people WHERE id > 10"), [[0, None]])

    def test_decimal_arithmetic(self):
        self.assertEqual(self.rows("SELECT 1.25 + 2.5, 1.25 * 2.5, 1.5 * 2, 10.00 / 4"), [["3.75", "3.125", "3.0", 2.5]])

    def test_three_valued_logic(self):
        self.assertEqual(self.rows("SELECT NULL AND FALSE, NULL OR TRUE, NOT NULL, NULL = NULL"),
                         [[False, True, None, None]])

    def test_casts(self):
        self.assertEqual(self.rows("SELECT CAST('1.005' AS DECIMAL(4,2)), CAST(-3.75 AS INT64), CAST(DATE '2024-03-01' AS TIMESTAMP)"),
                         [["1.01", -3, "2024-03-01 00:00:00"]])

    def test_limit_offset(self):
        self.assertEqual(self.rows("SELECT id FROM people ORDER BY id LIMIT 1 OFFSET 1"), [[2]])
        self.assertEqual(self.rows("SELECT id FROM people ORDER BY id OFFSET 2"), [[3]])

    def test_error_codes(self):
        cases = {
            "SELECT nope FROM people": "SEMANTIC_ERROR",
            "SELECT * FROM nope": "SEMANTIC_ERROR",
            "SELECT name, COUNT(*) FROM people": "SEMANTIC_ERROR",
            "SELECT id FROM people WHERE COUNT(*) > 1": "SEMANTIC_ERROR",
            "SELECT SUM(COUNT(*)) FROM people": "SEMANTIC_ERROR",
            "SELECT 1 = '1'": "TYPE_ERROR",
            "SELECT id FROM people WHERE age": "TYPE_ERROR",
            "SELECT 1 / 0": "DIVISION_BY_ZERO",
            "SELECT 9223372036854775807 + 1": "NUMERIC_OVERFLOW",
            "SELECT 9223372036854775808": "NUMERIC_OVERFLOW",
            "SELECT DATE '2023-02-29'": "CONVERSION_ERROR",
            "SELECT CAST('x' AS INT64)": "CONVERSION_ERROR",
            "SELECT id FROM people LIMIT -1": "INVALID_ARGUMENT",
            "SELECT id FROM people LIMIT id": "SEMANTIC_ERROR",
            "SELECT id FROM people ORDER BY 5": "SEMANTIC_ERROR",
            "SELECT CAST(1 AS WIDGET)": "SEMANTIC_ERROR",
            "SELECT a FROM people GROUP BY a": "SEMANTIC_ERROR",
            "SELECT id FROM people FULL JOIN people q ON TRUE": "UNSUPPORTED",
            "CREATE INDEX i ON nope (id)": "SEMANTIC_ERROR",
            "CREATE INDEX i ON people (nope)": "SEMANTIC_ERROR",
            "DROP INDEX nope": "NOT_FOUND",
        }
        for sql, code in cases.items():
            self.assertEqual(self.error_code(sql), code, sql)

    def test_int_decimal_comparison_promotion(self):
        self.assertEqual(self.rows("SELECT 1 = 1.0, 2 > 1.5, 0.10 = 0.1, 99999999999999999.9 > 0.01"),
                         [[True, True, True, True]])
        # exact since CR-2 (decimal38.md §4): no NUMERIC_OVERFLOW
        self.assertEqual(self.rows("SELECT 100000000000000000 > 0.5, 9223372036854775807 > 1.5"), [[True, True]])

    def test_null_literal_typing(self):
        resp = self.query("SELECT -NULL, NULL * 1.5, NULL / 0")
        self.assertEqual([c["type"] for c in resp["columns"]], ["STRING", "DECIMAL(18,2)", "INT64"])

    def test_signed_order_by_literal_is_constant(self):
        self.assertEqual(self.rows("SELECT id FROM people ORDER BY -1, id DESC"), [[3], [2], [1]])
        self.assertEqual(self.error_code("SELECT id FROM people ORDER BY 0"), "SEMANTIC_ERROR")

    def test_limits(self):
        self.assertEqual(self.error_code("SELECT id FROM people", max_rows=2), "RESOURCE_LIMIT")
        self.assertEqual(self.error_code("SELECT PQ_SLEEP(2000)", timeout_ms=20), "TIMEOUT")


class CatalogTests(EngineTestMixin, unittest.TestCase):
    def test_catalog_lifecycle(self):
        self.load_csv("B", "x\n1\n")
        self.load_csv("a", "x\n1\n2\n")
        self.assertEqual(self.request(op="tables")["tables"], [{"name": "a", "row_count": 2}, {"name": "B", "row_count": 1}])
        self.assertEqual(self.request(op="load", table="b", format="csv", data="x\n1\n")["error"]["code"], "ALREADY_EXISTS")
        self.assertTrue(self.request(op="load", table="b", format="csv", data="y\n1\n", replace=True)["ok"])
        self.assertEqual(self.request(op="schema", table="B")["columns"], [{"name": "y", "type": "INT64"}])
        self.assertTrue(self.request(op="drop", table="A")["ok"])
        self.assertEqual(self.request(op="drop", table="a")["error"]["code"], "NOT_FOUND")
        self.assertTrue(self.request(op="reset")["ok"])
        self.assertEqual(self.request(op="tables")["tables"], [])

    def test_invalid_requests(self):
        for req in ({"op": "nope"}, {"op": "query"}, {"op": "query", "sql": 1},
                    {"op": "load", "table": "t", "format": "xml", "data": ""},
                    {"op": "load", "table": "t", "format": "csv"}):
            self.assertEqual(self.handler.handle(req)["error"]["code"], "INVALID_REQUEST", req)

    def test_path_safety(self):
        for path in ("/etc/passwd", "../x.csv", "a/../../b.csv", ""):
            resp = self.request(op="load", table="t", format="csv", path=path)
            self.assertEqual(resp["error"]["code"], "ACCESS_DENIED", path)

    def test_id_echo(self):
        self.assertEqual(self.handler.handle({"op": "tables", "id": {"k": [1]}})["id"], {"k": [1]})


if __name__ == "__main__":
    unittest.main()
