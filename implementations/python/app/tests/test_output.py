from __future__ import annotations

import datetime as dt
import io
import unittest
from decimal import Decimal

from pqledger import output
from pqledger.output import Table

TABLE = Table(
    ("month", "income", "n", "f", "ok", "note"),
    ("STRING", "DECIMAL(18,2)", "INT64", "FLOAT64", "BOOLEAN", "STRING"),
    [
        ("2026-08", Decimal("100.00"), 3, 0.5, True, "a, b"),
        ("2026-09", Decimal("-1200.00"), 1, -0.0000001, False, None),
    ],
)


def render(table: Table, fmt: str) -> str:
    out = io.StringIO()
    output.write(table, fmt, out)
    return out.getvalue()


class OutputTest(unittest.TestCase):
    def test_table(self) -> None:
        self.assertEqual(render(TABLE, "table"), (
            "month      income  n         f  ok     note\n"
            "-------  --------  -  --------  -----  ----\n"
            "2026-08    100.00  3  0.500000  true   a, b\n"
            "2026-09  -1200.00  1  0.000000  false\n"
            "(2 rows)\n"
        ))
        one = Table(("x",), ("INT64",), [(1,)])
        self.assertTrue(render(one, "table").endswith("(1 row)\n"))
        none = Table(("month", "net"), ("STRING", "DECIMAL(18,2)"), [])
        self.assertEqual(render(none, "table"), "month  net\n-----  ---\n(0 rows)\n")

    def test_width_counts_code_points(self) -> None:
        t = Table(("d", "v"), ("STRING", "INT64"), [("Ünïcödé ✓", 1), ("x", 22)])
        self.assertEqual(render(t, "table").splitlines()[2:4], ["Ünïcödé ✓   1", "x          22"])

    def test_csv(self) -> None:
        self.assertEqual(render(TABLE, "csv"), (
            "month,income,n,f,ok,note\n"
            '2026-08,100.00,3,0.500000,true,"a, b"\n'
            "2026-09,-1200.00,1,0.000000,false,\n"
        ))
        t = Table(("s",), ("STRING",), [("",), (" lead",), ('say "hi"',), ("a\nb",), ("tab\there",), (None,)])
        self.assertEqual(render(t, "csv"), 's\n""\n" lead"\n"say ""hi"""\n"a\nb"\ntab\there\n\n')

    def test_json(self) -> None:
        self.assertEqual(render(TABLE, "json"), (
            '{"month":"2026-08","income":"100.00","n":3,"f":0.500000,"ok":true,"note":"a, b"}\n'
            '{"month":"2026-09","income":"-1200.00","n":1,"f":0.000000,"ok":false,"note":null}\n'
        ))
        t = Table(("s", "d", "ts"), ("STRING", "DATE", "TIMESTAMP"),
                  [('q"\\\b\t\n\f\r\x01é', dt.date(1, 2, 3), dt.datetime(2026, 1, 2, 3, 4, 5, 6))])
        self.assertEqual(render(t, "json"),
                         '{"s":"q\\"\\\\\\b\\t\\n\\f\\r\\u0001é","d":"0001-02-03","ts":"2026-01-02 03:04:05.000006"}\n')
        self.assertEqual(render(Table(("x",), ("INT64",), []), "json"), "")

    def test_value_text(self) -> None:
        self.assertEqual(output.value_text(Decimal("0.0")), "0.0")
        self.assertEqual(output.value_text(Decimal("12")), "12")
        self.assertEqual(output.value_text(dt.datetime(2026, 1, 2)), "2026-01-02 00:00:00")
        self.assertEqual(output.value_text(2.0000005), "2.000001")
        self.assertEqual(output.value_text(None), "")
