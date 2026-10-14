from __future__ import annotations

import datetime as dt
import unittest
from dataclasses import replace

from pqledger.bankcsv import RecordError, amount_parser, csv_records, date_parser, parse_statement
from pqledger.config import ColumnRef, ImportSettings
from pqledger.errors import ImportDataError


class AmountTest(unittest.TestCase):
    def convert(self, text: str, **settings) -> int:
        return amount_parser(replace(ImportSettings(), **settings))(text)

    def test_signed(self) -> None:
        self.assertEqual(self.convert(" -12.5 "), -1250)
        self.assertEqual(self.convert("+7"), 700)
        self.assertEqual(self.convert("(31.06)"), -3106)
        self.assertEqual(self.convert("0.00"), 0)
        self.assertEqual(self.convert("-0.00"), 0)

    def test_symbols_and_separators(self) -> None:
        us = {"currency_symbol": "$", "thousands_separator": ","}
        self.assertEqual(self.convert("$1,248.23", **us), 124823)
        self.assertEqual(self.convert("($31.06)", **us), -3106)
        self.assertEqual(self.convert("-$ 5", **us), -500)
        de = {"decimal_separator": ",", "thousands_separator": ".", "currency_symbol": "EUR"}
        self.assertEqual(self.convert("1.120,00 EUR", **de), 112000)
        self.assertEqual(self.convert("1 234,5", decimal_separator=",", thousands_separator=" "), 123450)
        self.assertEqual(self.convert("1'000.05", thousands_separator="'"), 100005)

    def test_invalid(self) -> None:
        for text in ("", "12.345", "1e3", "--1", "$5", "1,000", "12345678901234567", ".5", "5."):
            with self.subTest(text=text), self.assertRaises(RecordError):
                self.convert(text)
        self.assertEqual(self.convert("1234567890123456.99"), 123456789012345699)


class DateTest(unittest.TestCase):
    def test_formats(self) -> None:
        self.assertEqual(date_parser("YYYY-MM-DD")(" 2026-02-28 "), dt.date(2026, 2, 28))
        self.assertEqual(date_parser("YYYYMMDD")("20260228"), dt.date(2026, 2, 28))
        self.assertEqual(date_parser("MM/DD/YYYY")("2/3/2026"), dt.date(2026, 2, 3))
        self.assertEqual(date_parser("DD/MM/YYYY")("2/3/2026"), dt.date(2026, 3, 2))
        self.assertEqual(date_parser("DD.MM.YYYY")("01.12.2025"), dt.date(2025, 12, 1))

    def test_invalid(self) -> None:
        for fmt, text in (("YYYY-MM-DD", "2026-02-30"), ("YYYY-MM-DD", "2026-2-3"), ("YYYY-MM-DD", "0000-01-01"),
                          ("MM/DD/YYYY", "13/01/2026"), ("DD.MM.YYYY", "1.1.26"), ("YYYYMMDD", "2026-01-01")):
            with self.subTest(text=text), self.assertRaises(RecordError):
                date_parser(fmt)(text)


class StatementTest(unittest.TestCase):
    def test_records_and_line_numbers(self) -> None:
        text = 'pre\namble\nA,B\r\n\n1,"x\ny"\r\n2,"a ""q"""\n'
        self.assertEqual(list(csv_records(text, ",", 2, "f")),
                         [(3, ["A", "B"]), (5, ["1", "x\ny"]), (7, ["2", 'a "q"'])])

    def test_signed_statement(self) -> None:
        text = "Date,Description,Amount\n2026-01-05, Lunch  #12 ,-12.00\n2026-01-06,\"Pay, Inc\",100\n"
        records = parse_statement(text, ImportSettings(), "f.csv")
        self.assertEqual([(r.line, r.date, r.description, r.merchant, r.cents) for r in records], [
            (2, dt.date(2026, 1, 5), "Lunch  #12", "LUNCH", -1200),
            (3, dt.date(2026, 1, 6), "Pay, Inc", "PAY, INC", 10000),
        ])

    def test_debit_credit_positions_without_header(self) -> None:
        settings = ImportSettings(delimiter=";", header=False, date_format="DD.MM.YYYY",
                                  date_column=ColumnRef(position=1), description_column=ColumnRef(position=2),
                                  amount_mode="debit_credit", debit_column=ColumnRef(position=3),
                                  credit_column=ColumnRef(position=4), decimal_separator=",",
                                  thousands_separator=".", invert_sign=True)
        records = parse_statement("01.01.2026;Miete;1.120,00;\n02.01.2026;Refund;;5\n", settings, "g")
        self.assertEqual([r.cents for r in records], [112000, -500])

    def test_header_names_are_case_insensitive_and_trimmed(self) -> None:
        settings = ImportSettings(date_column=ColumnRef(name="transaction date"))
        records = parse_statement(" Transaction Date ,DESCRIPTION,amount\n2026-01-01,x,1\n", settings, "f")
        self.assertEqual(records[0].cents, 100)

    def test_errors_name_file_and_line(self) -> None:
        cases = {
            "Date,Description,Amount\n2026-01-05,a,1\n\n2026-01-06,\"b\nc\",1\n2026-01-07,d,1,x\n": "f:6:",
            "Date,Description,Amount\n2026-02-30,a,1\n": "f:2:",
            "Date,Description,Amount\n2026-01-01,a,1.001\n": "f:2:",
            "Date,Description,Amount\n2026-01-01,a,\n": "f:2:",
            'Date,Description,Amount\n2026-01-01,"a"b,1\n': "f:2:",
            'Date,Description,Amount\n2026-01-01,"open,1\n': "f:2:",
            "Day,Description,Amount\n2026-01-01,a,1\n": "f:",
            "": "f:",
        }
        for text, where in cases.items():
            with self.subTest(text=text), self.assertRaises(ImportDataError) as cm:
                parse_statement(text, ImportSettings(), "f")
            self.assertIn(where, cm.exception.message)
        settings = ImportSettings(amount_column=ColumnRef(position=9))
        with self.assertRaises(ImportDataError):
            parse_statement("Date,Description,Amount\n2026-01-01,a,1\n", settings, "f")
        settings = ImportSettings(amount_mode="debit_credit")
        with self.assertRaises(ImportDataError) as cm:
            parse_statement("Date,Description,Debit,Credit\n2026-01-01,a, , \n", settings, "f")
        self.assertIn("f:2:", cm.exception.message)
