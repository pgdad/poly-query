"""Change request CR-6: statement size limits (spec/changes/expression-limits.md)."""

import random
import re
import time
import unittest
from unittest import mock

from polyquery import errors, limits
from polyquery.analysis import bound as b
from polyquery.datatypes import BOOLEAN, FLOAT64, INT64
from polyquery.execution.compiler import like_matcher
from polyquery.limits import run_with_large_stack
from polyquery.planner.explain import render_expr
from polyquery.sql.parser import parse
from tests.helpers import make_handler

MODES = (
    {"mode": "row", "threads": 1},
    {"mode": "vectorized", "threads": 1},
    {"mode": "vectorized", "threads": 4},
    {},
)


def parse_error(sql: str) -> errors.PolyQueryError:
    try:
        run_with_large_stack(lambda: parse(sql))
    except errors.PolyQueryError as e:
        return e
    raise AssertionError("statement was accepted")


class MeasureTests(unittest.TestCase):
    def test_nesting_depth(self):
        within = "SELECT " + "(" * 4000 + "1" + ")" * 4000
        run_with_large_stack(lambda: parse(within))
        e = parse_error("SELECT " + "(" * 100_000 + "1" + ")" * 100_000)
        self.assertEqual(e.code, errors.RESOURCE_LIMIT)
        self.assertIn("nesting depth exceeds", e.message)
        self.assertEqual(e.details, {"measure": "nesting_depth"})

    def test_each_construct_is_a_level(self):
        constructs = {
            "parentheses": ("(", ")"),
            "function": ("ABS(", ")"),
            "minus": ("- ", ""),
            "not": ("NOT ", ""),
            "cast": ("CAST(", " AS BIGINT)"),
            "case": ("CASE WHEN TRUE THEN ", " END"),
            "subquery": ("(SELECT ", ")"),
            "in_list": ("1 IN (", ")"),
        }
        for name, (open_, close) in constructs.items():
            with self.subTest(name), mock.patch.object(limits, "MAX_NESTING_DEPTH", 50):
                run_with_large_stack(lambda: parse("SELECT " + open_ * 40 + "1" + close * 40))
                e = parse_error("SELECT " + open_ * 60 + "1" + close * 60)
                self.assertEqual(e.code, errors.RESOURCE_LIMIT)

    def test_a_chain_of_one_operator_is_one_level(self):
        with mock.patch.object(limits, "MAX_NESTING_DEPTH", 10):
            for op in (" OR ", " AND ", " + ", " - ", " * ", " || "):
                parse("SELECT " + op.join(["x"] * 1000) + " FROM t")
            parse("SELECT ((x + 1) * 2 - 3) || 'a' FROM t WHERE (a = 1 OR b = 2) AND NOT c")

    def test_operand_count(self):
        with mock.patch.object(limits, "MAX_OPERANDS", 100):
            # *, t and x are three of them (every leaf counts: a table
            # reference and an empty argument list too)
            parse("SELECT count(*) FROM t WHERE x IN (" + ", ".join(["1"] * 97) + ")")
            e = parse_error("SELECT count(*) FROM t WHERE x IN (" + ", ".join(["1"] * 98) + ")")
            self.assertEqual((e.code, e.details), (errors.RESOURCE_LIMIT, {"measure": "operand_count"}))
            self.assertIn("operand count exceeds 100", e.message)
            # function names, keywords and operators are not operands
            parse("SELECT " + " + ".join(["ABS(DATE '2020-01-01' - DATE '2020-01-02')"] * 50))
            self.assertEqual(parse_error("SELECT " + " + ".join(["f()"] * 101)).code, errors.RESOURCE_LIMIT)
            self.assertEqual(parse_error("SELECT 1 FROM " + ", ".join(["t"] * 100)).code, errors.RESOURCE_LIMIT)

    def test_text_length(self):
        with mock.patch.object(limits, "MAX_SQL_BYTES", 64):
            parse("SELECT '" + "é" * 27 + "'")  # 63 bytes
            e = parse_error("SELECT '" + "é" * 28 + "'")
            self.assertEqual((e.code, e.details), (errors.RESOURCE_LIMIT, {"measure": "text_length"}))

    def test_limit_takes_precedence_over_parse_errors(self):
        e = parse_error("SELECT " + "(" * 100_000 + "1")  # unbalanced as well
        self.assertEqual(e.code, errors.RESOURCE_LIMIT)

    def test_lexical_errors_precede_unsupported(self):
        e = parse_error("SELECT * FROM a FULL JOIN b ON TRUE WHERE 'unterminated")
        self.assertEqual(e.code, errors.PARSE_ERROR)


class LargeStatementTests(unittest.TestCase):
    """The CR-6 minimums execute in every mode (in worker processes too)."""

    @classmethod
    def setUpClass(cls):
        cls.handler = make_handler(parallel_min_rows=1)
        data = "x\n" + "".join(f"{i}\n" for i in range(100))
        assert cls.handler.handle({"op": "load", "table": "n", "format": "csv", "data": data})["ok"]

    @classmethod
    def tearDownClass(cls):
        cls.handler.engine.close()

    def check(self, sql, expected):
        for options in MODES:
            with self.subTest(sql=sql[:40], **options):
                request = {"op": "query", "sql": sql, "options": options}
                response = run_with_large_stack(lambda: self.handler.handle(request))
                self.assertTrue(response["ok"], response)
                self.assertEqual(response["rows"][0][0], expected)

    def where(self, predicate):
        return f"SELECT count(*) FROM n WHERE {predicate}"

    def test_nesting(self):
        self.check(self.where("(" * 998 + "x >= 0" + ")" * 998), 100)
        self.check(self.where("ABS(" * 998 + "x" + ")" * 998 + " >= 0"), 100)
        self.check(self.where("- " * 998 + "x >= 0"), 100)
        self.check(self.where("NOT " * 998 + "x >= 0"), 100)
        self.check("SELECT " + "(SELECT " * 500 + "1" + ")" * 500 + " FROM n LIMIT 1", 1)
        self.check("SELECT count(*) FROM " + "(SELECT * FROM " * 500 + "n" + ") t" * 500, 100)

    def test_long_chains_and_lists(self):
        self.check(self.where(" OR ".join(f"x = {i}" for i in range(10_000))), 100)
        self.check(self.where(" AND ".join(f"x <> {-i - 1}" for i in range(10_000))), 100)
        self.check("SELECT max(x" + " + 1" * 9_999 + ") FROM n", 99 + 9_999)
        self.check(self.where("x IN (" + ", ".join(str(i) for i in range(10_000)) + ")"), 100)
        case = " ".join(f"WHEN x = {i} THEN {i}" for i in range(5_000))
        self.check(f"SELECT sum(CASE {case} ELSE 0 END) FROM n", 4950)

    def test_text_of_one_mebibyte(self):
        literal = "a" * 524_000
        self.check(self.where(f"'{literal}' = '{literal}'"), 100)

    def test_beyond_the_limits(self):
        for sql in (
            self.where("(" * 100_000 + "x >= 0" + ")" * 100_000),
            self.where(" OR ".join(f"x = {i}" for i in range(100_001))),
        ):
            response = run_with_large_stack(lambda: self.handler.handle({"op": "query", "sql": sql}))
            self.assertEqual(response["error"]["code"], errors.RESOURCE_LIMIT)


class LargeNumberTests(unittest.TestCase):
    def test_huge_ordinals_and_type_parameters(self):
        handler = make_handler()
        handler.handle({"op": "load", "table": "n", "format": "csv", "data": "x\n1\n"})
        digits = "1" + "0" * 5000  # beyond Python's int/str conversion limit
        for sql, code in (
            (f"SELECT x FROM n ORDER BY {digits}", errors.SEMANTIC_ERROR),
            (f"SELECT x FROM n GROUP BY {digits}", errors.SEMANTIC_ERROR),
            (f"SELECT CAST(x AS DECIMAL({digits}, 2)) FROM n", errors.SEMANTIC_ERROR),
            (f"SELECT x FROM n LIMIT {digits}", errors.NUMERIC_OVERFLOW),
        ):
            response = handler.handle({"op": "query", "sql": sql})
            self.assertEqual(response["error"]["code"], code, sql[:40])


class TimeoutTests(unittest.TestCase):
    def test_timeout_covers_parsing_binding_and_planning(self):
        handler = make_handler()
        handler.handle({"op": "load", "table": "n", "format": "csv", "data": "x\n1\n"})
        sql = "SELECT count(*) FROM n WHERE " + " OR ".join(f"x = {i}" for i in range(50_000))
        for op in ("query", "explain"):
            started = time.monotonic()
            response = run_with_large_stack(
                lambda: handler.handle({"op": op, "sql": sql, "options": {"timeout_ms": 1}})
            )
            self.assertEqual(response["error"]["code"], errors.TIMEOUT, op)
            self.assertLess(time.monotonic() - started, 1.0)
            handler.release_failed()

    def test_timeout_while_planning_a_long_join_chain(self):
        handler = make_handler()
        handler.handle({"op": "load", "table": "o", "format": "csv", "data": "y\n1\n"})
        tables = [f"o t{i}" if i == 0 else f"o t{i} ON t{i}.y = t{i - 1}.y" for i in range(3000)]
        request = {"op": "query", "sql": "SELECT count(*) FROM " + " JOIN ".join(tables), "options": {"timeout_ms": 300}}
        started = time.monotonic()
        response = run_with_large_stack(lambda: handler.handle(request))
        self.assertEqual(response["error"]["code"], errors.TIMEOUT)
        self.assertLess(time.monotonic() - started, 1.3)
        handler.release_failed()

    def test_deadline_check(self):
        limits.no_check()
        self.assertIs(limits.deadline_check(None), limits.no_check)
        with self.assertRaises(errors.PolyQueryError) as cm:
            limits.deadline_check(time.monotonic() - 1)()
        self.assertEqual(cm.exception.code, errors.TIMEOUT)


class LikeMatcherTests(unittest.TestCase):
    def test_agrees_with_a_regex(self):
        def reference(pattern):
            parts = [".*" if c == "%" else "." if c == "_" else re.escape(c) for c in pattern]
            return re.compile("".join(parts), re.DOTALL)

        rng = random.Random(7)
        for _ in range(20_000):
            pattern = "".join(rng.choice("ab%_\n") for _ in range(rng.randint(0, 6)))
            value = "".join(rng.choice("ab%_\n") for _ in range(rng.randint(0, 8)))
            expected = reference(pattern).fullmatch(value) is not None
            self.assertEqual(like_matcher(pattern)(value), expected, (pattern, value))

    def test_long_pattern(self):
        value = "b" * 600_000
        started = time.monotonic()
        self.assertTrue(like_matcher("%" + value + "%")(value))
        self.assertFalse(like_matcher("%" + value + "_%")(value))
        self.assertLess(time.monotonic() - started, 1.0)


class LinearTimeHelperTests(unittest.TestCase):
    """Helpers that run at every node of deep trees."""

    @staticmethod
    def chain(n):
        x = b.ColumnRef(INT64, 1, 0, "x")
        e: b.Expr = x
        for i in range(n):
            e = b.Arith(INT64, "+", e, b.Literal(INT64, i))
        return e

    def test_walk_and_summaries(self):
        e = b.Logical(
            BOOLEAN,
            "OR",
            b.Compare(BOOLEAN, "=", b.ColumnRef(INT64, 1, 0, "x"), b.Literal(INT64, 1)),
            b.Not(BOOLEAN, b.ColumnRef(BOOLEAN, 2, 3, "y")),
        )
        self.assertEqual(
            [type(n).__name__ for n in b.walk(e)],
            ["Logical", "Compare", "ColumnRef", "Literal", "Not", "ColumnRef"],
        )
        self.assertEqual(b.column_keys(e), {(1, 0), (2, 3)})
        self.assertFalse(b.is_constant(e))
        self.assertTrue(b.is_constant(b.Not(BOOLEAN, b.Literal(BOOLEAN, True))))
        self.assertFalse(b.may_fail(e))
        self.assertTrue(b.may_fail(self.chain(1)))

    def test_deep_chain(self):
        e = self.chain(100_000)
        self.assertEqual(sum(1 for _ in b.walk(e)), 200_001)
        self.assertEqual(b.column_keys(e), {(1, 0)})
        self.assertFalse(b.is_constant(e))
        text = render_expr(e)
        self.assertTrue(text.startswith("(" * 100_000 + "x + 0) + 1)"), text[:20])
        self.assertTrue(text.endswith(" + 99999)"))

    def test_iterative_equality_and_hash(self):
        a, c = self.chain(200_000), self.chain(200_000)  # equal, built separately
        self.assertTrue(a == c)  # deeper than the main thread's C stack allows recursing
        self.assertEqual(hash(a), hash(c))
        self.assertFalse(a == self.chain(199_999))
        x, renamed = b.ColumnRef(INT64, 1, 0, "x"), b.ColumnRef(INT64, 1, 0, "other name")
        self.assertEqual(x, renamed)  # names are not compared
        self.assertEqual(hash(x), hash(renamed))
        self.assertNotEqual(b.Literal(INT64, 1), b.Literal(BOOLEAN, True))
        nan = b.Literal(FLOAT64, float("nan"))
        self.assertNotEqual(nan, b.Literal(FLOAT64, float("nan")))
        case = b.Case(INT64, ((b.Literal(BOOLEAN, True), x),), None)
        self.assertEqual(case, b.Case(INT64, ((b.Literal(BOOLEAN, True), renamed),), None))
        self.assertNotEqual(case, b.Case(INT64, ((b.Literal(BOOLEAN, True), x),), b.Literal(INT64, 1)))

    def test_conjuncts_keep_order(self):
        parts = [b.Compare(BOOLEAN, "=", b.ColumnRef(INT64, 1, 0, "x"), b.Literal(INT64, i)) for i in range(5)]
        self.assertEqual(b.conjuncts(b.conjunction(parts)), parts)
        self.assertEqual(b.conjuncts(None), [])


if __name__ == "__main__":
    unittest.main()
