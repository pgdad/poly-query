import unittest

from polyquery import errors
from polyquery.datatypes import BOOLEAN, DATE, FLOAT64, INT64, STRING, TIMESTAMP, decimal
from polyquery.ingest.limits import IngestLimits
from polyquery.ingest.loader import load_table
from polyquery.storage.catalog import Column

CSV = {"header": True, "delimiter": ","}


def load(fmt, text, schema=None, options=CSV, limits=IngestLimits()):
    return load_table("t", fmt, text, schema, options if fmt == "csv" else {}, limits)


def code_of(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except errors.PolyQueryError as e:
        return e.code
    return None


class CsvTests(unittest.TestCase):
    def test_inference(self):
        t = load("csv", "b,i,f,d,ts,s,n\ntrue,1,1,2024-01-01,2024-01-01,x,\nFALSE,-2,2.5,2024-02-29,2024-01-01 10:00:00,1,\n")
        self.assertEqual([c.type for c in t.columns], [BOOLEAN, INT64, FLOAT64, DATE, TIMESTAMP, STRING, STRING])
        self.assertEqual(t.column_values(1), [1, -2])
        self.assertEqual(t.column_values(6), [None, None])

    def test_quoting_and_nulls(self):
        t = load("csv", '﻿n,s\n"",""\n,\n" 7 ","a,""b""\nc"\n')
        self.assertEqual(t.columns[0].type, INT64)
        self.assertEqual(t.column_values(0), [None, None, 7])
        self.assertEqual(t.column_values(1), ["", None, 'a,"b"\nc'])

    def test_int_overflow_infers_float(self):
        self.assertEqual(load("csv", "n\n9223372036854775808\n").columns[0].type, FLOAT64)

    def test_explicit_schema(self):
        schema = [Column("a", decimal(5, 2)), Column("b", TIMESTAMP)]
        t = load("csv", "A,B\n1.5,2024-01-01\n-0.25,\n", schema)
        self.assertEqual(t.column_values(0), [150, -25])
        self.assertEqual(t.columns[0].name, "a")

    def test_header_false(self):
        t = load("csv", "1,x\n", [Column("a", INT64), Column("b", STRING)], {"header": False, "delimiter": ","})
        self.assertEqual(t.row_count, 1)

    def test_errors(self):
        self.assertEqual(code_of(load, "csv", "a,b\n1\n"), errors.INGEST_ERROR)
        self.assertEqual(code_of(load, "csv", "a,a\n1,2\n"), errors.INGEST_ERROR)
        self.assertEqual(code_of(load, "csv", 'a\n"x\n'), errors.INGEST_ERROR)
        self.assertEqual(code_of(load, "csv", "a,,c\n1,2,3\n"), errors.INGEST_ERROR)
        self.assertEqual(code_of(load, "csv", "a\n1.005\n", [Column("a", decimal(4, 2))]), errors.CONVERSION_ERROR)
        self.assertEqual(code_of(load, "csv", "a\n123.4\n", [Column("a", decimal(3, 1))]), errors.CONVERSION_ERROR)
        self.assertEqual(code_of(load, "csv", "a\nNaN\n", [Column("a", FLOAT64)]), errors.CONVERSION_ERROR)
        self.assertEqual(code_of(load, "csv", "x\n1\n", [Column("a", INT64)]), errors.INGEST_ERROR)
        self.assertEqual(code_of(load, "csv", "a\n1\n2\n", limits=IngestLimits(max_rows=1)), errors.RESOURCE_LIMIT)


class JsonTests(unittest.TestCase):
    def test_jsonl_union_of_keys(self):
        t = load("jsonl", '{"a": 1}\n\n{"b": "x", "a": 2}\n{"c": true}\n')
        self.assertEqual([(c.name, c.type) for c in t.columns], [("a", INT64), ("b", STRING), ("c", BOOLEAN)])
        self.assertEqual(t.column_values(0), [1, 2, None])

    def test_json_inference(self):
        t = load("json", '[{"i": 1, "f": 1, "d": "2024-01-01", "ts": "2024-01-01", "n": null},'
                         ' {"i": 2, "f": 2.5, "d": "2024-01-02", "ts": "2024-01-01T00:00:01"}]')
        self.assertEqual([c.type for c in t.columns], [INT64, FLOAT64, DATE, TIMESTAMP, STRING])

    def test_json_schema_conversion(self):
        schema = [Column("amt", decimal(8, 3)), Column("day", DATE)]
        t = load("json", '[{"amt": 12.5, "day": "2024-01-31"}, {"amt": "-0.125"}]', schema)
        self.assertEqual(t.column_values(0), [12500, -125])
        self.assertEqual(code_of(load, "jsonl", '{"amt": true}\n', schema), errors.CONVERSION_ERROR)
        self.assertEqual(code_of(load, "jsonl", '{"x": 1}\n', schema), errors.INGEST_ERROR)

    def test_errors(self):
        for fmt, text in [
            ("json", '{"a": 1}'),
            ("json", '[{"a": 1}, 2]'),
            ("json", '[{"a": 1},]'),
            ("jsonl", '{"a": 1, "a": 2}\n'),
            ("jsonl", '{"a": NaN}\n'),
            ("jsonl", '{"a": [1]}\n'),
            ("jsonl", '{"a": {"b": 1}}\n'),
            ("json", '[{"a": 1}, {"a": "x"}]'),
        ]:
            self.assertEqual(code_of(load, fmt, text), errors.INGEST_ERROR, text)

    def test_empty_array(self):
        t = load("json", "[]")
        self.assertEqual((t.columns, t.row_count), ([], 0))


if __name__ == "__main__":
    unittest.main()
