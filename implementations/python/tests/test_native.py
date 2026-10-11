"""Unit tests for the native kernel integration: the ``ctypes`` binding
(against Python reference computations) and the native execution paths
(``native: true`` must return exactly what the engine's own code returns).

The library is looked up at ``$PQ_NATIVE_KERNELS`` or at
``native-kernels/build/<machine>/libpqkernels.so`` of the workspace (built
with ``make -C native-kernels``); tests that need it are skipped when it is
absent. The fallback without a library is always tested."""

import array
import os
import platform
import random
import tempfile
import unittest
from pathlib import Path

from polyquery.native import kernels as nk
from polyquery.native.kernels import address, load_kernels, new_bitmap
from polyquery.protocol.handlers import capabilities_info
from polyquery.storage import pqcf
from polyquery.storage.vectors import bits_to_flags
from tests.helpers import make_handler

_DEFAULT_LIB = (
    Path(__file__).resolve().parents[3] / "native-kernels" / "build" / platform.machine() / "libpqkernels.so"
)
LIB = os.environ.get("PQ_NATIVE_KERNELS") or str(_DEFAULT_LIB)
KERNELS = load_kernels(LIB) if os.path.exists(LIB) else None
needs_library = unittest.skipIf(KERNELS is None, f"native kernel library not found at {LIB}")

MASK64 = (1 << 64) - 1


def fmix64(k: int) -> int:
    k ^= k >> 33
    k = (k * 0xFF51AFD7ED558CCD) & MASK64
    k ^= k >> 33
    k = (k * 0xC4CEB9FE1A85EC53) & MASK64
    return k ^ (k >> 33)


def bitmap_of(flags: list[bool]) -> bytes:
    out = bytearray((len(flags) + 7) // 8)
    for i, f in enumerate(flags):
        if f:
            out[i >> 3] |= 1 << (i & 7)
    return bytes(out)


@needs_library
class BindingTests(unittest.TestCase):
    def setUp(self):
        rng = random.Random(7)
        self.n = 1001
        self.values = [rng.randint(-50, 50) for _ in range(self.n)]
        self.valid = [rng.random() > 0.2 for _ in range(self.n)]
        self.data = array.array("q", self.values)
        self.validity = bitmap_of(self.valid)

    def test_filter_bitmap_and_indices(self):
        k = KERNELS
        for op, a, b, pred in [
            (nk.EQ, 3, 0, lambda x: x == 3),
            (nk.NE, 3, 0, lambda x: x != 3),
            (nk.LT, -7, 0, lambda x: x < -7),
            (nk.GE, 10, 0, lambda x: x >= 10),
            (nk.BETWEEN, -5, 5, lambda x: -5 <= x <= 5),
        ]:
            expected = [v and pred(x) for x, v in zip(self.values, self.valid)]
            bits = new_bitmap(self.n)
            count = k.filter_bitmap(address(self.data), address(self.validity), self.n, op, a, b, bits)
            self.assertEqual(count, sum(expected))
            self.assertEqual(bits.tobytes(), bitmap_of(expected))
            idx = array.array("I", bytes(4 * self.n))
            found = k.filter_indices(address(self.data), address(self.validity), self.n, op, a, b, idx)
            self.assertEqual(idx[:found].tolist(), [i for i, e in enumerate(expected) if e])
            self.assertEqual(k.count(address(self.data), address(self.validity), self.n, op, a, b), sum(expected))
        with self.assertRaises(nk.NativeKernelError):
            k.filter_bitmap(address(self.data), None, self.n, 99, 0, 0, new_bitmap(self.n))

    def test_sum_minmax_overflow(self):
        k = KERNELS
        live = [x for x, v in zip(self.values, self.valid) if v]
        self.assertEqual(k.sum_i64(address(self.data), address(self.validity), self.n), sum(live))
        self.assertEqual(k.minmax_i64(address(self.data), address(self.validity), self.n), (len(live), min(live), max(live)))
        big = array.array("q", [nk.INT64_MAX, 1, 5])
        self.assertIsNone(k.sum_i64(address(big), None, 3))  # INT64_MAX + 6 does not fit
        cancel = array.array("q", [nk.INT64_MAX, 1, -1])  # intermediate overflow cancels out
        self.assertEqual(k.sum_i64(address(cancel), None, 3), nk.INT64_MAX)
        floats = array.array("d", [0.5, -2.25, 7.0])
        self.assertEqual(k.minmax_f64(address(floats), None, 3), (3, -2.25, 7.0))

    def test_bitmap_ops_and_popcount(self):
        k = KERNELS
        a = array.array("B", [0b10101100, 0xFF, 0x01])
        b = bytes([0b01100110, 0x0F, 0x01])
        x = array.array("B", a)
        k.bitmap_and(x, address(b), 3)
        self.assertEqual(x.tolist(), [p & q for p, q in zip(a, b)])
        x = array.array("B", a)
        k.bitmap_andnot(x, address(b), 3)
        self.assertEqual(x.tolist(), [p & ~q & 0xFF for p, q in zip(a, b)])
        x = array.array("B", a)
        k.bitmap_or(x, array.array("B", b), 3)
        self.assertEqual(x.tolist(), [p | q for p, q in zip(a, b)])
        self.assertEqual(k.popcount(address(bytes(a)), 17), 4 + 8 + 1)
        self.assertEqual(k.popcount(address(bytes(a)), 16), 4 + 8)

    def test_hash_matches_fmix64(self):
        out = array.array("Q", bytes(8 * self.n))
        KERNELS.hash_i64(address(self.data), self.n, 42, out)
        self.assertEqual(out.tolist(), [fmix64((x & MASK64) ^ 42) for x in self.values])

    def test_group_sum_and_gather(self):
        k = KERNELS
        ids = array.array("I", [i % 3 for i in range(self.n)])
        sums, counts = array.array("q", bytes(24)), array.array("q", bytes(24))
        ok = k.group_sum_i64(ids, address(self.data), address(self.validity), self.n, sums, counts, 3)
        self.assertTrue(ok)
        for g in range(3):
            rows = [x for i, (x, v) in enumerate(zip(self.values, self.valid)) if v and i % 3 == g]
            self.assertEqual((sums[g], counts[g]), (sum(rows), len(rows)))
        wrap = array.array("q", [nk.INT64_MAX, 1])
        self.assertFalse(k.group_sum_i64(array.array("I", [0, 0]), address(wrap), None, 2, array.array("q", [0]), None, 1))
        idx = array.array("I", [5, 0, 1000, 5])
        out = array.array("q", bytes(32))
        k.gather(address(self.data), idx, 4, out)
        self.assertEqual(out.tolist(), [self.values[i] for i in idx])

    def test_compare(self):
        other = array.array("q", reversed(self.values))
        bits = new_bitmap(self.n)
        count = KERNELS.compare(address(self.data), address(other), self.n, nk.LT, bits)
        expected = [x < y for x, y in zip(self.values, other)]
        self.assertEqual(count, sum(expected))
        self.assertEqual(bits_to_flags(bits.tobytes(), self.n), bytes(expected))


class LoadingTests(unittest.TestCase):
    def test_missing_library_falls_back(self):
        self.assertIsNone(load_kernels(None))
        with self.assertLogs("polyquery", "WARNING"):
            self.assertIsNone(load_kernels("/nonexistent/libpqkernels.so"))
            handler = make_handler(native_kernels="/nonexistent/libpqkernels.so")
        handler.handle({"op": "load", "table": "t", "format": "csv", "data": "a\n1\n2\n3\n"})
        resp = handler.handle({"op": "query", "sql": "SELECT SUM(a) FROM t WHERE a > 1", "options": {"native": True}})
        self.assertEqual([list(r) for r in resp["rows"]], [[5]])

    def test_capability_claimed(self):
        self.assertIn("native.kernels", capabilities_info()["capabilities"])

    def test_native_option_validated(self):
        handler = make_handler()
        resp = handler.handle({"op": "query", "sql": "SELECT 1", "options": {"native": "yes"}})
        self.assertEqual(resp["error"]["code"], "INVALID_REQUEST")


def _table_csv(n: int, seed: int) -> str:
    rng = random.Random(seed)
    lines = ["id,a,big,dec,d,f,s,u"]
    for i in range(n):
        lines.append(",".join([
            str(i),
            "" if rng.random() < 0.1 else str(rng.randint(-20, 20)),
            str(rng.randint(-9, 9) if i % 3 == 0 else 4 * 10**18 * (1 if i % 2 else -1)),  # sums cancel out
            "" if rng.random() < 0.1 else f"{rng.randint(-9999, 9999) / 100:.2f}",
            f"2024-0{rng.randint(1, 9)}-1{rng.randint(0, 9)}",
            repr(rng.choice([0.0, -0.0, rng.uniform(-5, 5)])),
            "" if rng.random() < 0.1 else rng.choice(["x", "y", "zz", "w"]),
            f"u{rng.randint(0, n)}",
        ]))
    return "\n".join(lines) + "\n"


NATIVE_QUERIES = [
    # filters: constants, IN, BETWEEN, <>, dictionary strings, column comparisons, NULLs
    "SELECT id, a, s FROM {t} WHERE a > 3 AND s IN ('x', 'zz') ORDER BY id",
    "SELECT id FROM {t} WHERE a BETWEEN -2 AND 2 AND dec <> 1.5 AND d >= DATE '2024-05-01'",
    "SELECT id, u FROM {t} WHERE s > 'x' AND u <> 'u7' AND a < id",
    "SELECT id FROM {t} WHERE a IN (1, 2, NULL) OR a IS NULL",
    "SELECT COUNT(*) FROM {t} WHERE a <> 0",
    "SELECT COUNT(*) FROM {t} WHERE id >= 100",
    # a conjunct that may fail after native ones: NULL rows of `a` still reach it
    "SELECT id FROM {t} WHERE a > 0 AND 10 / (a - a) = 1",
    # aggregates without GROUP BY: exact sums, overflow (also partial), -0.0 minimum
    "SELECT COUNT(*), COUNT(a), SUM(a), AVG(dec), MIN(d), MAX(dec), MIN(f), MAX(f), MIN(s) FROM {t} WHERE id < 900",
    "SELECT SUM(big) FROM {t}",
    "SELECT SUM(big) FROM {t} WHERE big > 0",
    # GROUP BY over the scan: dictionary key, many groups, multiple keys
    "SELECT s, COUNT(*), SUM(a), MAX(f), COUNT(DISTINCT a) FROM {t} GROUP BY s",
    "SELECT a, COUNT(*), SUM(dec), AVG(a) FROM {t} WHERE id > 10 GROUP BY a",
    "SELECT u, SUM(a) FROM {t} GROUP BY u",
    "SELECT a, d, SUM(dec), COUNT(s) FROM {t} GROUP BY a, d",
    "SELECT s, SUM(big) FROM {t} GROUP BY s",
]


@needs_library
class NativeExecutionTests(unittest.TestCase):
    """Every query returns the same rows (in the same order) or the same
    error with ``native: true`` as without, in every mode."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.handlers = [
            make_handler(data_dir=cls.tmp.name, native_kernels=LIB),
            make_handler(data_dir=cls.tmp.name, native_kernels=LIB, parallel_min_rows=1),  # forked workers
        ]
        csv = _table_csv(2501, 3)
        schema = [{"name": n, "type": ty} for n, ty in [
            ("id", "INT64"), ("a", "INT64"), ("big", "INT64"), ("dec", "DECIMAL(10,2)"),
            ("d", "DATE"), ("f", "FLOAT64"), ("s", "STRING"), ("u", "STRING")]]
        for h in cls.handlers:
            for req in [
                {"op": "load", "table": "t", "format": "csv", "data": csv, "schema": schema},
                # small, odd row groups: kernel windows never align with them
                {"op": "save", "table": "t", "path": "t.pqcf", "options": {"row_group_size": 333}},
                {"op": "open", "table": "p", "path": "t.pqcf", "options": {"mmap": True}},
                {"op": "load", "table": "r", "format": "csv", "data": csv, "schema": schema,
                 "options": {"layout": "row"}},
            ]:
                resp = h.handle(req)
                assert resp["ok"], resp

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_query(self, handler, sql, options):
        resp = handler.handle({"op": "query", "sql": sql, "options": options})
        if not resp["ok"]:
            return resp["error"]["code"]
        return [[repr(v) for v in row] for row in resp["rows"]]  # repr: -0.0 differs from 0.0

    def test_same_results(self):
        variants = [{"mode": "vectorized"}, {"mode": "row"}, {"mode": "vectorized", "threads": 3}]
        errors = {"SELECT SUM(big) FROM {t} WHERE big > 0", "SELECT s, SUM(big) FROM {t} GROUP BY s",
                  "SELECT id FROM {t} WHERE a > 0 AND 10 / (a - a) = 1"}
        for template in NATIVE_QUERIES:
            outcome = self.run_query(self.handlers[0], template.format(t="t"), {})
            self.assertEqual(isinstance(outcome, str), template in errors, (template, outcome))
            for table in ("t", "p", "r"):
                sql = template.format(t=table)
                for k, handler in enumerate(self.handlers):
                    for options in variants if k == 0 else variants[2:]:
                        with self.subTest(sql=sql, options=options, forked=k == 1):
                            expected = self.run_query(handler, sql, options)
                            got = self.run_query(handler, sql, {**options, "native": True})
                            self.assertEqual(got, expected)

    def test_corrupt_chunk_parity(self):
        """A corrupt chunk of a memory-mapped table fails the query even if
        the kernels select no row of its row group."""
        handler = make_handler(data_dir=self.tmp.name, native_kernels=LIB)
        csv = _table_csv(4000, 5)
        for req in [
            {"op": "load", "table": "t", "format": "csv", "data": csv},
            {"op": "save", "table": "t", "path": "c.pqcf", "options": {"row_group_size": 1000}},
        ]:
            self.assertTrue(handler.handle(req)["ok"])
        path = Path(self.tmp.name) / "c.pqcf"
        chunk = pqcf.read_file(str(path), use_mmap=False).groups[2].chunks[-1]  # column u, rows 2000..2999
        raw = bytearray(path.read_bytes())
        raw[chunk.offset + chunk.length // 2] ^= 0xFF
        path.write_bytes(bytes(raw))
        self.assertTrue(handler.handle({"op": "open", "table": "c", "path": "c.pqcf", "options": {"mmap": True}})["ok"])
        outcomes = set()
        # no row matches, but min/max statistics cannot skip row group 2
        for sql in ["SELECT id, u FROM c WHERE id = 2500 AND id = 2501",
                    "SELECT COUNT(*), SUM(a), MAX(u) FROM c WHERE id = 2500 AND id = 2501",
                    "SELECT s, COUNT(u) FROM c WHERE id = 2500 AND id = 2501 GROUP BY s"]:
            for options in ({}, {"mode": "row"}):
                expected = self.run_query(handler, sql, options)
                outcomes.add(str(expected))
                self.assertEqual(self.run_query(handler, sql, {**options, "native": True}), expected, sql)
        self.assertIn("STORAGE_CORRUPT", outcomes)

    def test_scattered_dictionary_codes(self):
        """A range over a dictionary in first-seen order matches many code
        ranges (computed in Python instead of one kernel pass each)."""
        rng = random.Random(11)
        csv = "k,x\n" + "".join(f"{i},w{rng.randint(0, 99):02d}\n" for i in range(3001))
        handler = make_handler(native_kernels=LIB)
        self.assertTrue(handler.handle({"op": "load", "table": "w", "format": "csv", "data": csv,
                                        "options": {"dictionary": True}})["ok"])
        for sql in ["SELECT k FROM w WHERE x > 'w37' AND x <= 'w91'", "SELECT COUNT(*) FROM w WHERE x < 'w50'",
                    "SELECT x, COUNT(*) FROM w WHERE x BETWEEN 'w10' AND 'w60' GROUP BY x"]:
            expected = self.run_query(handler, sql, {})
            self.assertGreater(len(expected), 0)
            self.assertEqual(self.run_query(handler, sql, {"native": True}), expected, sql)

    def test_native_paths_are_used(self):
        from polyquery.execution import native_ops

        calls = []
        original = native_ops.filtered_batches

        def spy(*args, **kwargs):
            calls.append(1)
            return original(*args, **kwargs)

        native_ops.filtered_batches = spy
        try:
            self.run_query(self.handlers[0], "SELECT id FROM t WHERE a > 3", {"native": True})
        finally:
            native_ops.filtered_batches = original
        self.assertTrue(calls)


if __name__ == "__main__":
    unittest.main()
