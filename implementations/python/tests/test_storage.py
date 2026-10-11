"""Unit tests for the storage layer: vectors, layouts, statistics, indexes,
the catalog and the PQCF v1 reader/writer."""

import os
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

from polyquery import errors
from polyquery.datatypes import BOOLEAN, DATE, FLOAT64, INT64, STRING, TIMESTAMP, decimal
from polyquery.storage import pqcf
from polyquery.storage.catalog import Catalog
from polyquery.storage.indexes import BTREE, HASH, build_index
from polyquery.storage.table import COLUMN, ROW, Column, make_table
from polyquery.storage.vectors import (
    DictVector,
    PlainVector,
    bits_to_flags,
    build_vector,
    flags_to_bits,
)

COLUMNS = [
    Column("i", INT64),
    Column("b", BOOLEAN),
    Column("f", FLOAT64),
    Column("d", decimal(10, 2)),
    Column("s", STRING),
    Column("day", DATE),
    Column("ts", TIMESTAMP),
]
DATA = [
    [1, 2, None, 4, 5, 5, 5],
    [True, None, False, True, True, True, False],
    [0.5, -1.25, None, 3.0, 1e300, 0.0, 2.5],
    [150, -25, 0, None, 99999, 99999, 99999],
    ["a", "", None, "ünï", "a", "a", "b"],
    [0, -719162, 2932896, None, 19000, 19000, 19000],
    [0, 253402300799999999, None, -62135596800000000, 1, 1, 1],
]


def code_of(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except errors.PolyQueryError as e:
        return e.code
    return None


class VectorTests(unittest.TestCase):
    def test_bitmaps_are_lsb_first(self):
        self.assertEqual(flags_to_bits(bytes([1, 0, 0, 0, 0, 0, 0, 0, 1])), b"\x01\x01")
        self.assertEqual(bits_to_flags(b"\x05", 3), bytes([1, 0, 1]))

    def test_vectors_round_trip_values(self):
        for column, values in zip(COLUMNS, DATA):
            vector = build_vector(column.type, values)
            self.assertEqual(vector.to_list(), values, column.name)
            self.assertEqual(vector.take([6, 2, 0]), [values[6], values[2], values[0]])
            self.assertEqual(vector.null_count, values.count(None))

    def test_dictionary_encoding(self):
        values = ["x", "y", None, "x", "x", "y"]
        self.assertIsInstance(build_vector(STRING, values, dictionary=True), DictVector)
        self.assertIsInstance(build_vector(STRING, values), DictVector)  # automatic: 2 < 6/2
        self.assertIsInstance(build_vector(STRING, ["a", "b", "c"]), PlainVector)
        self.assertEqual(build_vector(STRING, values, dictionary=True).to_list(), values)
        self.assertEqual(build_vector(STRING, [None, None], dictionary=True).to_list(), [None, None])


class TableTests(unittest.TestCase):
    def test_layouts_scan_identically(self):
        row = make_table("t", COLUMNS, DATA, 7, ROW)
        col = make_table("t", COLUMNS, DATA, 7, COLUMN)
        for cols in ([], [0], [4, 1], list(range(7))):
            self.assertEqual(list(row.scan(cols)), list(col.scan(cols)))
            self.assertEqual(row.fetch([1, 5], cols), col.fetch([1, 5], cols))
        self.assertEqual(row.layout, ROW)
        self.assertEqual(col.layout, COLUMN)

    def test_statistics(self):
        table = make_table("t", COLUMNS, DATA, 7)
        stats = table.column_stats(4)
        self.assertEqual((stats.null_count, stats.distinct_count, stats.min, stats.max), (1, 4, "", "ünï"))
        empty = make_table("e", [Column("x", INT64)], [[None]], 1).column_stats(0)
        self.assertEqual((empty.null_count, empty.distinct_count, empty.min, empty.max), (1, 0, None, None))


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.table = make_table("t", [Column("k", INT64)], [[5, None, 3, 5, 9, 1]], 6)

    def test_hash_index_never_returns_nulls(self):
        index = build_index("h", self.table, 0, HASH)
        self.assertEqual(sorted(index.structure.lookup_values([5, None, 7])), [0, 3])
        self.assertFalse(index.structure.supports_ranges)

    def test_ordered_index_ranges(self):
        s = build_index("b", self.table, 0, BTREE).structure
        self.assertEqual(sorted(s.lookup_range(3, True, 5, True)), [0, 2, 3])
        self.assertEqual(sorted(s.lookup_range(3, False, None, True)), [0, 3, 4])
        self.assertEqual(s.lookup_range(None, True, 1, False), [])
        self.assertEqual(s.lookup_range(9, True, 1, True), [])
        self.assertEqual(sorted(s.lookup_values([1, 9])), [4, 5])

    def test_catalog_index_namespace(self):
        catalog = Catalog()
        catalog.put(self.table, replace=False)
        catalog.add_index(build_index("ix", self.table, 0, HASH))
        self.assertEqual(code_of(catalog.add_index, build_index("IX", self.table, 0, BTREE)), "ALREADY_EXISTS")
        replacement = make_table("T", [Column("k", INT64)], [[1]], 1)
        catalog.put(replacement, replace=True)  # drops the replaced table's indexes
        self.assertIsNone(catalog.get_index("ix"))
        catalog.add_index(build_index("ix", replacement, 0, BTREE))
        catalog.drop("t")
        self.assertIsNone(catalog.get_index("ix"))


class PqcfTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "t.pqcf")

    def tearDown(self):
        self.dir.cleanup()

    def save(self, table, encoding="auto", row_group_size=3, indexes=()):
        return pqcf.save_table(
            self.path, table, list(indexes), pqcf.SaveOptions(row_group_size, encoding)
        )

    def reopen(self, lazy=False, layout=COLUMN):
        file = pqcf.read_file(self.path, use_mmap=lazy)
        return file, pqcf.table_from_file(file, "copy", lazy=lazy, layout=layout)

    def test_crc32_check_value(self):
        self.assertEqual(zlib.crc32(b"123456789"), 0xCBF43926)

    def test_round_trip_every_encoding(self):
        table = make_table("t", COLUMNS, DATA, 7)
        for encoding in pqcf.FORCED_ENCODINGS:
            for lazy in (False, True):
                for layout in (ROW, COLUMN):
                    size = self.save(table, encoding)
                    self.assertEqual(size, os.path.getsize(self.path))
                    file, copy = self.reopen(lazy, layout)
                    self.assertEqual(file.table, "t")
                    self.assertEqual(copy.columns, COLUMNS)
                    self.assertEqual(list(copy.scan(range(7))), list(table.scan(range(7))), encoding)

    def test_layout_and_metadata(self):
        table = make_table("t", COLUMNS, DATA, 7)
        self.save(table, "plain", indexes=[{"name": "ix", "column": "s", "kind": "HASH"}])
        data = Path(self.path).read_bytes()
        self.assertEqual(data[:8], b"PQCF\x01\x00\x00\x00")
        self.assertEqual(data[-4:], b"PQCF")
        file, _ = self.reopen()
        self.assertEqual([g.row_count for g in file.groups], [3, 3, 1])
        first = file.groups[0].chunks[0]
        self.assertEqual((first.offset, first.length, first.null_count), (8, 25, 1))
        self.assertEqual((first.min, first.max), (1, 2))
        self.assertTrue(all(c.offset % 8 == 0 for g in file.groups for c in g.chunks))
        self.assertEqual(file.indexes, [("ix", 4, "HASH")])

    def test_empty_table(self):
        self.save(make_table("e", [Column("a", INT64)], [[]], 0))
        file, copy = self.reopen()
        self.assertEqual((file.row_count, file.groups, copy.row_count), (0, [], 0))

    def test_corruption_is_detected(self):
        self.save(make_table("t", COLUMNS, DATA, 7))
        original = Path(self.path).read_bytes()

        def status(data, lazy=False):
            with open(self.path, "wb") as f:
                f.write(data)
            try:
                _, table = self.reopen(lazy)
                list(table.scan(range(7)))
            except errors.PolyQueryError as e:
                return e.code
            return "OK"

        self.assertEqual(status(original), "OK")
        self.assertEqual(status(b""), "STORAGE_CORRUPT")
        self.assertEqual(status(original[:-1]), "STORAGE_CORRUPT")
        self.assertEqual(status(original[:100]), "STORAGE_CORRUPT")
        self.assertEqual(status(b"PQCF\x03\x00\x00\x00" + original[8:]), "STORAGE_VERSION_UNSUPPORTED")
        # a v2 header over v1 metadata: version mismatch (decimal38.md §7)
        self.assertEqual(status(b"PQCF\x02\x00\x00\x00" + original[8:]), "STORAGE_CORRUPT")
        self.assertEqual(status(b"PQCF\x00\x00\x00\x00" + original[8:]), "STORAGE_CORRUPT")
        self.assertEqual(status(b"PQCF\x01\x00\x01\x00" + original[8:]), "STORAGE_VERSION_UNSUPPORTED")
        flipped = bytearray(original)
        flipped[9] ^= 0x10  # inside the first chunk
        self.assertEqual(status(bytes(flipped)), "STORAGE_CORRUPT")
        self.assertEqual(status(bytes(flipped), lazy=True), "STORAGE_CORRUPT")

    def test_structural_rules(self):
        def file_with(meta_text, body=b""):
            meta = meta_text.encode()
            data = b"PQCF\x01\x00\x00\x00" + body + meta + struct.pack("<II", len(meta), zlib.crc32(meta)) + b"PQCF"
            return pqcf.parse_file(data)

        chunk = '{"offset":8,"length":16,"crc32":%d,"encoding":"%s","null_count":0}'
        body = struct.pack("<qq", 1, 2)
        good = (
            '{"format_version":1,"table":"t","row_count":2,"columns":[{"name":"a","type":"INT64"}],'
            '"row_groups":[{"row_count":2,"chunks":[%s]}],"x":1}'
        )
        file = file_with(good % (chunk % (zlib.crc32(body), "PLAIN")), body)
        self.assertEqual(file.indexes, [])
        self.assertEqual(code_of(file_with, good % (chunk % (0, "ZSTD")), body), "STORAGE_VERSION_UNSUPPORTED")
        self.assertEqual(code_of(file_with, good % (chunk % (0, "DICT")), body), "STORAGE_CORRUPT")
        dup = good.replace('{"name":"a","type":"INT64"}', '{"name":"a","type":"INT64"},{"name":"A","type":"INT64"}')
        self.assertEqual(code_of(file_with, dup % (chunk % (0, "PLAIN") + "," + chunk % (0, "PLAIN")), body), "STORAGE_CORRUPT")
        self.assertEqual(code_of(file_with, "[1]"), "STORAGE_CORRUPT")

    def test_atomic_save_leaves_no_temporary_files(self):
        self.save(make_table("t", COLUMNS, DATA, 7))
        self.save(make_table("t", COLUMNS, DATA, 7), "rle")
        self.assertEqual(os.listdir(self.dir.name), ["t.pqcf"])
        missing = os.path.join(self.dir.name, "nope", "x.pqcf")
        self.assertEqual(
            code_of(pqcf.save_table, missing, make_table("t", COLUMNS, DATA, 7), [], pqcf.SaveOptions()),
            "IO_ERROR",
        )


if __name__ == "__main__":
    unittest.main()
