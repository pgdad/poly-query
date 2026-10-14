from __future__ import annotations

import unittest
from decimal import Decimal

from pqledger.errors import ConfigError
from pqledger.merchant import normalize
from pqledger.rules import parse_budgets, parse_rules


class RulesTest(unittest.TestCase):
    def test_rules_in_file_order(self) -> None:
        rules = parse_rules("; c\ngroceries = WHOLE FOODS*, trader joe?\n\ncoffee = Café*\ngroceries = SAFEWAY\n", "r")
        self.assertEqual([(r.number, r.category, r.pattern) for r in rules], [
            (1, "groceries", "WHOLE FOODS*"), (2, "groceries", "TRADER JOE?"),
            (3, "coffee", "CAFé*"), (4, "groceries", "SAFEWAY"),
        ])
        self.assertEqual(rules[1].like_pattern(), "TRADER JOE_")
        self.assertEqual(rules[0].like_pattern(), "WHOLE FOODS%")

    def test_rule_errors(self) -> None:
        for text in ("groceries = SAFE_WAY\n", "groceries = 50%\n", "groceries = A,,B\n", "groceries =\n",
                     "Groceries = A\n", "uncategorized = A\n", "[section]\n", "no equals\n"):
            with self.subTest(text=text), self.assertRaises(ConfigError):
                parse_rules(text, "r")

    def test_budgets(self) -> None:
        budgets = parse_budgets("groceries = 600\ncoffee = 30.5\nrent = 1234567890123456.99\n", "b")
        self.assertEqual([(b.category, str(b.amount)) for b in budgets],
                         [("groceries", "600.00"), ("coffee", "30.50"), ("rent", "1234567890123456.99")])
        self.assertIsInstance(budgets[0].amount, Decimal)
        for text in ("a = 12.345\n", "a = -1\n", "a = 1\na = 2\n", "a = 12345678901234567\n", "a = 1.\n", "a = x\n"):
            with self.subTest(text=text), self.assertRaises(ConfigError):
                parse_budgets(text, "b")


class MerchantTest(unittest.TestCase):
    def test_spec_examples(self) -> None:
        cases = {
            "Whole Foods Market #10234": "WHOLE FOODS MARKET",
            "SQ *Blue  Bottle 4421": "SQ *BLUE BOTTLE",
            "Rent 2026": "RENT",
            "7-Eleven 12": "7-ELEVEN 12",
            "#123": "#123",
            "Café\tMélange  #9": "CAFé MéLANGE",
            "Shop 12 345": "SHOP 12",
            "REI #": "REI #",
            "": "",
            "  a\t\tb  ": "A B",
            "Line\nbreak": "LINE\nBREAK",
        }
        for description, merchant in cases.items():
            self.assertEqual(normalize(description), merchant, description)
