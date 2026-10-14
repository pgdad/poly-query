"""The embedding API (polyquery.api, spec/apps/embedding.md)."""

from __future__ import annotations

import datetime as dt
import os
import tempfile
import threading
import unittest
from decimal import Decimal
from unittest import mock

import polyquery

CSV = "id,name,amount,day\n1,ann,10.50,2026-01-01\n2,bob,-3.25,2026-01-02\n3,\"c, d\",0.75,2026-01-02\n"
SCHEMA = [("id", "INT64"), ("name", "STRING"), ("amount", "DECIMAL(10,2)"), ("day", "DATE")]


class DatabaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.db = polyquery.Database(self.dir.name)
        self.addCleanup(self.dir.cleanup)
        self.addCleanup(self.db.close)

    def write(self, name: str, text: str) -> None:
        with open(os.path.join(self.dir.name, name), "w", encoding="utf-8") as f:
            f.write(text)

    def code_of(self, fn, *args, **kwargs) -> str:
        with self.assertRaises(polyquery.Error) as cm:
            fn(*args, **kwargs)
        return cm.exception.code

    # ------------------------------------------------------------ loading

    def test_load_text_infers_schema(self) -> None:
        info = self.db.load("t", text=CSV)
        self.assertEqual(info.row_count, 3)
        self.assertEqual(
            [(c.name, c.type) for c in info.columns],
            [("id", "INT64"), ("name", "STRING"), ("amount", "FLOAT64"), ("day", "DATE")],
        )

    def test_load_path_with_schema_and_options(self) -> None:
        self.write("t.csv", CSV.replace(",", ";").replace('"c; d"', "cd"))
        info = self.db.load("t", path="t.csv", schema=SCHEMA, delimiter=";")
        self.assertEqual(info.columns[2].type, "DECIMAL(10,2)")
        self.write("n.csv", "1,x\n2,y\n")
        self.db.load("n", path="n.csv", schema=[("a", "INT64"), ("b", "STRING")], header=False)
        self.assertEqual(self.db.query("SELECT b FROM n ORDER BY a").rows, [("x",), ("y",)])

    def test_load_requires_exactly_one_source_and_replace(self) -> None:
        self.assertEqual(self.code_of(self.db.load, "t"), "INVALID_ARGUMENT")
        self.assertEqual(self.code_of(self.db.load, "t", header=False, text="1\n"), "INVALID_ARGUMENT")
        self.db.load("t", text=CSV)
        self.assertEqual(self.code_of(self.db.load, "t", text=CSV), "ALREADY_EXISTS")
        self.assertEqual(self.db.load("t", text="x\n1\n", replace=True).row_count, 1)

    def test_path_safety(self) -> None:
        self.assertEqual(self.code_of(self.db.load, "t", path="/etc/passwd"), "ACCESS_DENIED")
        self.assertEqual(self.code_of(self.db.load, "t", path="../x.csv"), "ACCESS_DENIED")
        self.assertEqual(self.code_of(self.db.load, "t", path="missing.csv"), "NOT_FOUND")
        self.db.load("t", text=CSV)
        self.assertEqual(self.code_of(self.db.save, "t", "../t.pqcf"), "ACCESS_DENIED")

    def test_missing_data_dir(self) -> None:
        with self.assertRaises(polyquery.Error) as cm:
            polyquery.Database(os.path.join(self.dir.name, "nope"))
        self.assertEqual(cm.exception.code, "NOT_FOUND")

    # ------------------------------------------------------------ queries

    def test_value_mapping(self) -> None:
        self.db.load("t", text=CSV, schema=SCHEMA)
        r = self.db.query(
            "SELECT id, name, amount, day, amount * 2 > 0 AS pos, CAST(id AS FLOAT64) / 4 AS f,"
            " CAST(day AS TIMESTAMP) AS ts, CAST(NULL AS STRING) AS n FROM t ORDER BY id"
        )
        self.assertEqual(r.columns, ("id", "name", "amount", "day", "pos", "f", "ts", "n"))
        self.assertEqual(
            r.types, ("INT64", "STRING", "DECIMAL(10,2)", "DATE", "BOOLEAN", "FLOAT64", "TIMESTAMP", "STRING")
        )
        self.assertEqual(r.row_count, 3)
        first = r.rows[0]
        self.assertEqual(first[0], 1)
        self.assertEqual(first[1], "ann")
        self.assertEqual(str(first[2]), "10.50")
        self.assertIsInstance(first[2], Decimal)
        self.assertEqual(first[3], dt.date(2026, 1, 1))
        self.assertIs(first[4], True)
        self.assertEqual(first[5], 0.25)
        self.assertEqual(first[6], dt.datetime(2026, 1, 1))
        self.assertIsNone(first[7])
        self.assertEqual(str(r.rows[1][2]), "-3.25")
        self.assertEqual(r.column("name"), ["ann", "bob", "c, d"])
        self.assertEqual(len(list(r)), 3)

    def test_wide_decimals_are_exact(self) -> None:
        r = self.db.query("SELECT CAST('12345678901234567890123456789012.345678' AS DECIMAL(38,6)) AS d")
        self.assertEqual(r.scalar(), Decimal("12345678901234567890123456789012.345678"))
        self.assertEqual(self.db.query("SELECT CAST(0 AS DECIMAL(5,2)) AS z").scalar().as_tuple().exponent, -2)

    def test_errors_carry_codes_and_leave_the_instance_usable(self) -> None:
        self.db.load("t", text=CSV)
        cases = {
            "SELEC 1": "PARSE_ERROR",
            "SELECT nope FROM t": "SEMANTIC_ERROR",
            "SELECT 1 / 0": "DIVISION_BY_ZERO",
            "SELECT name + 1 FROM t": "TYPE_ERROR",
        }
        for sql, code in cases.items():
            with self.assertRaises(polyquery.Error) as cm:
                self.db.query(sql)
            self.assertEqual(cm.exception.code, code)
            self.assertTrue(cm.exception.message)
        self.assertEqual(self.db.query("SELECT COUNT(*) FROM t").scalar(), 3)

    def test_query_options(self) -> None:
        self.db.load("t", text=CSV)
        self.assertEqual(self.code_of(self.db.query, "SELECT * FROM t", max_rows=2), "RESOURCE_LIMIT")
        self.assertEqual(len(self.db.query("SELECT * FROM t", max_rows=3, threads=2, timeout_ms=10_000)), 3)
        self.assertEqual(self.code_of(self.db.query, "SELECT 1", threads=0), "INVALID_ARGUMENT")
        self.assertEqual(self.code_of(self.db.query, "SELECT 1", mode="fast"), "UNSUPPORTED")

    def test_no_worker_processes_by_default(self) -> None:
        rows = "\n".join(f"{i},{i % 7}" for i in range(60_000))
        self.db.load("big", text="a,b\n" + rows)
        with mock.patch("os.fork", side_effect=AssertionError("forked")):
            r = self.db.query("SELECT b, COUNT(*) AS n FROM big GROUP BY b ORDER BY b", threads=4)
        self.assertEqual(sum(n for _, n in r), 60_000)

    # ------------------------------------------------------------ storage and catalog

    def test_save_open_drop_tables_schema(self) -> None:
        self.db.load("t", text=CSV, schema=SCHEMA)
        self.assertGreater(self.db.save("t", "t.pqcf"), 0)
        info = self.db.open("u", "t.pqcf")
        self.assertEqual(info.row_count, 3)
        self.assertEqual(self.code_of(self.db.open, "u", "t.pqcf"), "ALREADY_EXISTS")
        self.db.open("u", "t.pqcf", replace=True, mmap=True)
        self.assertEqual([t.name for t in self.db.tables()], ["t", "u"])
        self.assertEqual(self.db.schema("u").columns[2], polyquery.ColumnInfo("amount", "DECIMAL(10,2)"))
        self.assertEqual(
            self.db.query("SELECT SUM(amount) FROM u").scalar(), Decimal("8.00")
        )
        self.db.drop("u")
        self.assertFalse(self.db.exists("u"))
        self.assertEqual(self.code_of(self.db.drop, "u"), "NOT_FOUND")
        self.assertEqual(self.code_of(self.db.schema, "u"), "NOT_FOUND")
        self.assertEqual(self.code_of(self.db.open, "v", "missing.pqcf"), "NOT_FOUND")

    def test_create_table_from_native_values(self) -> None:
        schema = [("i", "INT64"), ("d", "DECIMAL(18,2)"), ("s", "STRING"), ("day", "DATE"),
                  ("ts", "TIMESTAMP"), ("b", "BOOLEAN"), ("f", "FLOAT64")]
        rows = [
            (1, Decimal("1.5"), "", dt.date(1970, 1, 2), dt.datetime(1970, 1, 1, 0, 0, 1, 5), True, 0.5),
            (None, None, None, None, None, None, None),
        ]
        self.db.create_table("n", schema, rows)
        r = self.db.query("SELECT * FROM n")
        self.assertEqual(r.rows[0], (1, Decimal("1.50"), "", dt.date(1970, 1, 2),
                                     dt.datetime(1970, 1, 1, 0, 0, 1, 5), True, 0.5))
        self.assertEqual(r.rows[1], (None,) * 7)
        bad = [
            [("d", "DECIMAL(18,2)")], [(Decimal("1.234"),)],
        ]
        self.assertEqual(self.code_of(self.db.create_table, "x", *bad), "CONVERSION_ERROR")
        self.assertEqual(self.code_of(self.db.create_table, "x", [("i", "INT64")], [("1",)]), "CONVERSION_ERROR")
        self.assertEqual(self.code_of(self.db.create_table, "x", [("i", "INT64")], [(2**63,)]), "CONVERSION_ERROR")
        self.assertEqual(self.code_of(self.db.create_table, "x", [("i", "INT64")], [(1, 2)]), "INVALID_ARGUMENT")
        self.assertEqual(self.code_of(self.db.create_table, "x", [("i", "BIGNUM")], []), "INVALID_ARGUMENT")
        self.assertEqual(self.db.create_table("e", [("i", "INT64")], []).row_count, 0)

    def test_create_table_as_may_replace_its_input(self) -> None:
        self.db.load("t", text=CSV, schema=SCHEMA)
        self.db.create_table("more", SCHEMA, [(4, "dee", Decimal("1"), dt.date(2026, 2, 1))])
        info = self.db.create_table_as("t", "SELECT * FROM t UNION ALL SELECT * FROM more ORDER BY id", replace=True)
        self.assertEqual(info.row_count, 4)
        self.assertEqual(self.db.query("SELECT MAX(id) FROM t").scalar(), 4)
        self.assertEqual(self.code_of(self.db.create_table_as, "t", "SELECT 1 AS x"), "ALREADY_EXISTS")

    # ------------------------------------------------------------ lifecycle and threads

    def test_close(self) -> None:
        with polyquery.Database(self.dir.name) as db:
            db.load("t", text=CSV)
        self.assertTrue(db.closed)
        self.assertEqual(self.code_of(db.query, "SELECT 1"), "INVALID_REQUEST")
        db.close()  # idempotent

    def test_instances_are_independent(self) -> None:
        with polyquery.Database(self.dir.name) as other:
            other.load("t", text="x\n1\n")
            self.db.load("t", text=CSV)
            self.assertEqual(other.query("SELECT COUNT(*) FROM t").scalar(), 1)
            self.assertEqual(self.db.query("SELECT COUNT(*) FROM t").scalar(), 3)

    def test_concurrent_queries(self) -> None:
        self.db.load("t", text=CSV)
        failures: list[BaseException] = []

        def work() -> None:
            try:
                for _ in range(20):
                    assert self.db.query("SELECT SUM(id) FROM t").scalar() == 6
            except BaseException as e:  # noqa: BLE001 - reported below
                failures.append(e)

        threads = [threading.Thread(target=work) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
