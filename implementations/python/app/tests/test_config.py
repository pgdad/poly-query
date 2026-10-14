from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

from pqledger import config
from pqledger.config import ColumnRef
from pqledger.errors import ConfigError

EXAMPLE = """﻿# example of pqledger.md §3.3
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = /abs/budgets.conf

[import]
date_column = Date
description_column = 2
amount_column = Amount

[account visa]
date_format = MM/DD/YYYY
invert_sign = true
currency_symbol = " $ "

[account sparkonto]
delimiter = ;
date_format = DD.MM.YYYY
decimal_separator = ,
thousands_separator = .
amount_mode = debit_credit
debit_column = Soll
credit_column = Haben

[output]
format = json

[engine]
threads = 2
memory_mb = 512
"""


def parse(text: str) -> config.Config:
    return config.parse(text, "/home/u/books/pqledger.conf")


class ConfigTest(unittest.TestCase):
    def test_example(self) -> None:
        c = parse(EXAMPLE.replace("\n", "\r\n"))
        self.assertEqual(c.data_dir, "/home/u/books/ledger")
        self.assertEqual(c.rules_file, "/home/u/books/rules.conf")
        self.assertEqual(c.budget_file, "/abs/budgets.conf")
        self.assertEqual((c.output_format, c.threads, c.memory_mb), ("json", 2, 512))
        self.assertEqual(c.import_settings.description_column, ColumnRef(position=2))
        visa = c.settings_for("visa")
        self.assertEqual((visa.date_format, visa.invert_sign, visa.currency_symbol), ("MM/DD/YYYY", True, " $ "))
        self.assertEqual(visa.description_column, ColumnRef(position=2))  # inherited from [import]
        spar = c.settings_for("sparkonto")
        self.assertEqual((spar.delimiter, spar.decimal_separator, spar.thousands_separator), (";", ",", "."))
        self.assertEqual(spar.debit_column, ColumnRef(name="Soll"))
        self.assertEqual(c.settings_for("other"), c.import_settings)

    def test_defaults(self) -> None:
        c = parse("[ledger]\ndata_dir = l\n")
        s = c.import_settings
        self.assertEqual((s.delimiter, s.header, s.skip_lines, s.amount_mode), (",", True, 0, "signed"))
        self.assertEqual(s.columns(), [("date_column", ColumnRef(name="Date")),
                                       ("description_column", ColumnRef(name="Description")),
                                       ("amount_column", ColumnRef(name="Amount"))])
        self.assertEqual((c.rules_file, c.budget_file, c.output_format, c.threads), (None, None, "table", None))

    def test_values(self) -> None:
        c = parse('[ledger]\ndata_dir = "  l "\n[import]\ndelimiter = tab\nthousands_separator = space\n'
                  'currency_symbol = "\\"\\\\"\nskip_lines = 3\n')
        self.assertEqual(c.data_dir, "/home/u/books/  l ")
        s = c.import_settings
        self.assertEqual((s.delimiter, s.thousands_separator, s.currency_symbol, s.skip_lines), ("\t", " ", '"\\', 3))
        self.assertEqual(config.column_ref("0"), ColumnRef(name="0"))
        self.assertEqual(config.column_ref("007"), ColumnRef(position=7))

    def test_errors_name_the_line(self) -> None:
        bad = {
            "[ledger]\ndata_dir = l\ncolour = blue\n": ":3:",
            "[ledger]\ndata_dir = l\ndata_dir = m\n": ":3:",
            "data_dir = l\n[ledger]\n": ":1:",
            "[ledger]\ndata_dir = l\n[output]\nformat = xml\n": ":4:",
            "[ledger]\ndata_dir = l\n[import]\nheader = yes\n": ":4:",
            "[ledger]\ndata_dir = l\n[accounts]\n": ":3:",
            "[ledger]\ndata_dir = l\n[ledger]\n": ":3:",
            "[ledger]\ndata_dir = l\n[account Visa]\n": ":3:",
            "[ledger]\ndata_dir = l\n[import]\ndelimiter = ab\n": ":4:",
            "[ledger]\ndata_dir = l\n[import]\nskip_lines = -1\n": ":4:",
            "[ledger]\ndata_dir = l\n[engine]\nthreads = 0\n": ":4:",
            "[ledger]\ndata_dir = l\njust text\n": ":3:",
            "[ledger]\ndata_dir =\n": ":2:",
        }
        for text, where in bad.items():
            with self.subTest(text=text), self.assertRaises(ConfigError) as cm:
                parse(text)
            self.assertIn(where, cm.exception.message)

    def test_semantic_errors(self) -> None:
        for text in (
            "[ledger]\nrules_file = r\n",
            "[import]\n",
            "[ledger]\ndata_dir = l\n[account eu]\ndecimal_separator = ,\nthousands_separator = ,\n",
            "[ledger]\ndata_dir = l\n[import]\nheader = false\n",
        ):
            with self.subTest(text=text), self.assertRaises(ConfigError):
                parse(text)
        c = parse("[ledger]\ndata_dir = l\n[import]\nheader = false\ndate_column = 1\n"
                  "description_column = 2\namount_column = 3\n")
        self.assertFalse(c.import_settings.header)

    def test_locate(self) -> None:
        with mock.patch.dict(os.environ, {"PQLEDGER_CONFIG": "env.conf"}):
            self.assertEqual(config.locate("opt.conf"), "opt.conf")
            self.assertEqual(config.locate(None), "env.conf")
        with mock.patch.dict(os.environ, {"PQLEDGER_CONFIG": ""}):
            self.assertEqual(config.locate(None), "pqledger.conf")

    def test_load_missing_file(self) -> None:
        with tempfile.TemporaryDirectory() as d, self.assertRaises(ConfigError):
            config.load(os.path.join(d, "nope.conf"))
