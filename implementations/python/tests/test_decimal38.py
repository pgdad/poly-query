"""Unit tests for DECIMAL precision 38 (spec/changes/decimal38.md): type
rules, literals, exact comparison, arithmetic overflow, vectors and PQCF v2."""

import itertools
import os
import struct
import tempfile
import unittest

from polyquery import errors, values
from polyquery.datatypes import (
    COMPARISON_PRECISION,
    INT64,
    STRING,
    DataType,
    InvalidTypeError,
    TypeKind,
    common_numeric_type,
    comparison_type,
    decimal,
    parse_type,
)
from polyquery.storage import pqcf
from polyquery.storage.table import COLUMN, Column, make_table
from polyquery.storage.vectors import PlainVector, build_vector
from tests.helpers import EngineTestMixin

WIDE = decimal(38, 10)
BIG = "id,amt,small\n1,12345678901234567890.1234567890,1.25\n2,-0.0000000001,2.50\n3,,\n"
BIG_SCHEMA = [
    {"name": "id", "type": "INT64"},
    {"name": "amt", "type": "DECIMAL(38,10)"},
    {"name": "small", "type": "DECIMAL(10,2)"},
]


class TypeTests(unittest.TestCase):
    def test_precision_limits(self):
        self.assertEqual(parse_type("NUMERIC(38,38)"), decimal(38, 38))
        self.assertEqual(parse_type("DECIMAL"), decimal(18, 0))
        for text in ("DECIMAL(39,0)", "DECIMAL(0,0)", "DECIMAL(30,31)"):
            with self.assertRaises(InvalidTypeError):
                parse_type(text)

    def test_wide_and_narrow(self):
        self.assertTrue(decimal(19, 0).is_wide)
        self.assertFalse(decimal(18, 2).is_wide)
        self.assertFalse(INT64.is_wide)

    def test_result_precision(self):
        self.assertEqual(common_numeric_type(decimal(10, 2), INT64), decimal(18, 2))
        self.assertEqual(common_numeric_type(decimal(19, 1), decimal(5, 3)), decimal(38, 3))

    def test_comparison_type_never_overflows(self):
        t = comparison_type([INT64, decimal(38, 38)])
        self.assertEqual(t, DataType(TypeKind.DECIMAL, COMPARISON_PRECISION, 38))
        self.assertTrue(values.decimal_fits(values.INT64_MIN * values.POW10[38], t.precision))
        self.assertEqual(comparison_type([INT64, INT64]), INT64)
        self.assertEqual(comparison_type([STRING, STRING]), STRING)

    def test_literal_types(self):
        self.assertEqual(values.decimal_literal_type("12345678901234567890.5"), (123456789012345678905, 21, 1))
        self.assertIsNone(values.decimal_literal_type("1" * 39 + ".0"))


class QueryTests(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("bd", BIG, schema=BIG_SCHEMA)

    def typed(self, sql):
        resp = self.query(sql)
        self.assertTrue(resp["ok"], resp)
        return [c["type"] for c in resp["columns"]], [list(r) for r in resp["rows"]]

    def test_wide_arithmetic(self):
        types, rows = self.typed("SELECT amt + small, amt * small, small + small FROM bd WHERE id = 1")
        self.assertEqual(types, ["DECIMAL(38,10)", "DECIMAL(38,12)", "DECIMAL(18,2)"])
        self.assertEqual(rows, [["12345678901234567891.3734567890", "15432098626543209862.654320986250", "2.50"]])

    def test_overflow_at_result_precision(self):
        self.assertEqual(self.error_code("SELECT 999999999999999999 + 1.0"), errors.NUMERIC_OVERFLOW)
        self.assertEqual(
            self.error_code("SELECT CAST('99999999999999999999999999999999999999' AS DECIMAL(38,0)) + 1"),
            errors.NUMERIC_OVERFLOW,
        )
        self.assertEqual(
            self.error_code("SELECT CAST(1 AS DECIMAL(38,20)) * CAST(1 AS DECIMAL(38,19))"), errors.TYPE_ERROR
        )
        self.assertEqual(self.error_code("SELECT CAST(CAST('9223372036854775808' AS DECIMAL(20,0)) AS INT64)"),
                         errors.NUMERIC_OVERFLOW)

    def test_exact_comparisons(self):
        _, rows = self.typed(
            "SELECT 9223372036854775807 > 1.5, small < 9223372036854775807, "
            "small BETWEEN 0 AND 9223372036854775807, small IN (9223372036854775807, 1.25), "
            "NULLIF(small, 1.250), CASE small WHEN 1.25 THEN 'x' ELSE 'y' END FROM bd WHERE id = 1"
        )
        self.assertEqual(rows, [[True, True, True, True, None, "x"]])
        self.assertEqual(self.rows("SELECT id FROM bd WHERE amt > 9223372036854775807"), [[1]])

    def test_options_agree(self):
        sql = "SELECT id, amt, SUM(amt) AS s FROM bd GROUP BY id, amt ORDER BY amt"
        expected = self.query(sql)
        self.assertTrue(expected["ok"], expected)
        for mode, threads, join, optimize in itertools.product(
            ("row", "vectorized"), (1, 4), ("hash", "merge", "nested_loop"), (True, False)
        ):
            resp = self.query(sql, mode=mode, threads=threads, join=join, optimize=optimize)
            self.assertEqual(resp["rows"], expected["rows"], (mode, threads, join, optimize))


class StorageTests(unittest.TestCase):
    def test_wide_vectors_have_no_int64_view(self):
        vector = build_vector(WIDE, [values.POW10[37], None, -1])
        self.assertIsInstance(vector, PlainVector)
        self.assertIsNone(vector.int64_view())
        self.assertEqual(vector.to_list(), [values.POW10[37], None, -1])
        self.assertIsNotNone(build_vector(decimal(18, 0), [1, 2]).int64_view())

    def _roundtrip(self, columns, data, encoding):
        table = make_table("t", columns, data, len(data[0]), COLUMN)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "t.pqcf")
            pqcf.save_table(path, table, [], pqcf.SaveOptions(row_group_size=3, encoding=encoding))
            with open(path, "rb") as f:
                raw = f.read()
            version = struct.unpack("<H", raw[4:6])[0]
            back = pqcf.table_from_file(pqcf.read_file(path, use_mmap=False), "t", lazy=False)
        return version, [back.column_values(i) for i in range(len(columns))]

    def test_v2_roundtrip(self):
        columns = [Column("id", INT64), Column("w", WIDE), Column("n", decimal(10, 2))]
        wide = [values.POW10[38] - 1, None, -(values.POW10[38] - 1), 5, 5, 5, 5]
        data = [list(range(7)), wide, [1, 2, None, 4, 5, 6, 7]]
        for encoding in ("plain", "rle", "auto"):
            version, back = self._roundtrip(columns, data, encoding)
            self.assertEqual(version, 2)
            self.assertEqual(back, data)

    def test_narrow_tables_stay_v1(self):
        version, _ = self._roundtrip([Column("n", decimal(18, 2))], [[1, 2]], "auto")
        self.assertEqual(version, 1)

    def test_wide_column_in_v1_is_corrupt(self):
        columns = [Column("w", WIDE)]
        table = make_table("t", columns, [[1]], 1, COLUMN)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "t.pqcf")
            pqcf.save_table(path, table, [], pqcf.SaveOptions())
            with open(path, "rb") as f:
                raw = bytearray(f.read())
            raw[4:6] = struct.pack("<H", 1)  # header says v1, metadata v2
            with self.assertRaises(errors.PolyQueryError) as ctx:
                pqcf.parse_file(bytes(raw))
            self.assertEqual(ctx.exception.code, errors.STORAGE_CORRUPT)
            raw[4:6] = struct.pack("<H", 3)
            with self.assertRaises(errors.PolyQueryError) as ctx:
                pqcf.parse_file(bytes(raw))
            self.assertEqual(ctx.exception.code, errors.STORAGE_VERSION_UNSUPPORTED)


if __name__ == "__main__":
    unittest.main()
