from __future__ import annotations

import io
import os
import tempfile
import unittest
from decimal import Decimal

import polyquery

from pqledger import errors
from pqledger.cli import parse_args
from pqledger.main import main
from pqledger.commands import share_of
from pqledger.errors import UsageError

CONFIG = """[ledger]
data_dir = books
rules_file = rules.conf
budget_file = budgets.conf

[account card]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
invert_sign = true
"""
RULES = "groceries = WHOLE FOODS*, SAFEWAY\ncoffee = STARBUCKS*\nincome = PAYROLL*\n"
BUDGETS = "groceries = 100\ncoffee = 5\n"
CHECKING = """Date,Description,Amount
2026-01-02,Whole Foods Market #12,-50.00
2026-01-03,Starbucks Store 4606,-4.50
2026-01-03,Starbucks Store 4606,-4.50
2026-01-15,PAYROLL ACME,1000.00
2026-02-01,SAFEWAY 1234,-30.25
"""
CARD = '"Transaction Date",Description,Amount\n01/20/2026,Starbucks Store 1,$3.00\n01/21/2026,Mystery,($1.00)\n'


class ParseArgsTest(unittest.TestCase):
    def test_valid(self) -> None:
        inv = parse_args(["--format", "csv", "--config", "x.conf", "report", "merchants", "--top", "3", "--month", "2026-01"])
        self.assertEqual((inv.command, inv.format, inv.config), ("report merchants", "csv", "x.conf"))
        self.assertEqual(inv.options, {"--top": "3", "--month": "2026-01"})
        inv = parse_args(["import", "--account", "a", "f.csv"])
        self.assertEqual((inv.positionals, inv.account()), (["f.csv"], "a"))
        inv = parse_args(["set-category", "--clear", "7"])
        self.assertEqual((inv.positionals, inv.flags), (["7"], {"--clear"}))
        self.assertEqual(parse_args(["--help", "whatever"]).command, "help")
        f = parse_args(["list", "--from", "2026-02", "--to", "2026-03"]).filters()
        self.assertEqual((str(f.start), str(f.end)), ("2026-02-01", "2026-03-31"))
        f = parse_args(["list", "--month", "2024-02"]).filters()
        self.assertEqual((str(f.start), str(f.end)), ("2024-02-01", "2024-02-29"))

    def test_usage_errors(self) -> None:
        for argv in (
            [], ["frobnicate"], ["report"], ["report", "weekly"], ["accounts", "extra"],
            ["report", "monthly", "--bogus"], ["report", "monthly", "--month"],
            ["report", "monthly", "--month", "2026-01", "--month", "2026-02"],
            ["--format", "xml", "accounts"], ["--config", "a", "--config", "b", "init"], ["--bogus", "init"],
            ["import"], ["set-category", "1"], ["set-category", "1", "x", "--clear"], ["query"],
            ["accounts", "--format", "csv"], ["help", "me"],
        ):
            with self.subTest(argv=argv), self.assertRaises(UsageError):
                parse_args(argv)
        for argv in (["list", "--month", "2026-13"], ["list", "--month", "0000-01"], ["list", "--month", "2026-1"],
                     ["list", "--month", "2026-01", "--from", "2026-01"], ["list", "--from", "2026-03", "--to", "2026-02"],
                     ["list", "--account", "Bad Name"]):
            with self.subTest(argv=argv), self.assertRaises(UsageError):
                parse_args(argv).filters()

    def test_share_rounds_half_away_from_zero(self) -> None:
        self.assertEqual(share_of(39701, 40001), Decimal("99.3"))
        self.assertEqual(share_of(1, 3), Decimal("33.3"))
        self.assertEqual(share_of(1, 8), Decimal("12.5"))
        self.assertEqual(share_of(1, 16), Decimal("6.3"))  # 6.25 -> 6.3
        self.assertEqual(share_of(5, 5), Decimal("100.0"))
        self.assertEqual(str(share_of(0, 7)), "0.0")


class EndToEndTest(unittest.TestCase):
    """Runs whole invocations in-process against a temporary ledger."""

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for name, text in (("pqledger.conf", CONFIG), ("rules.conf", RULES), ("budgets.conf", BUDGETS),
                           ("chk.csv", CHECKING), ("card.csv", CARD)):
            with open(os.path.join(self.dir.name, name), "w", encoding="utf-8") as f:
                f.write(text)
        cwd = os.getcwd()
        os.chdir(self.dir.name)
        self.addCleanup(os.chdir, cwd)

    def run_cli(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        status = main(list(argv), out, err)
        if status not in (0, 3):
            self.assertEqual(out.getvalue(), "")
            self.assertTrue(err.getvalue().startswith("pqledger: error: "), err.getvalue())
        return status, out.getvalue(), err.getvalue()

    def ok(self, *argv: str) -> str:
        status, out, err = self.run_cli(*argv)
        self.assertEqual(status, 0, err)
        return out

    def test_workflow(self) -> None:
        self.assertEqual(self.run_cli("accounts")[0], errors.LEDGER_STATE)
        self.assertEqual(self.ok("init"), "initialized ledger\n")
        self.assertEqual(self.run_cli("init")[0], errors.LEDGER_STATE)
        self.assertEqual(self.ok("import", "chk.csv", "--account", "checking"), "batch 1: imported 5, duplicates 0\n")
        self.assertEqual(self.ok("import", "card.csv", "--account", "card"), "batch 2: imported 2, duplicates 0\n")
        self.assertEqual(self.ok("import", "chk.csv", "--account", "checking"), "batch 3: imported 0, duplicates 5\n")
        self.assertEqual(self.ok("--format", "csv", "accounts"),
                         "account,transactions,balance,first,last\n"
                         "card,2,-2.00,2026-01-20,2026-01-21\n"
                         "checking,5,910.75,2026-01-02,2026-02-01\n")
        self.assertEqual(self.ok("--format", "csv", "report", "monthly"),
                         "month,income,expenses,net,transactions\n"
                         "2026-01,1001.00,62.00,939.00,6\n"
                         "2026-02,0.00,30.25,-30.25,1\n")
        self.assertEqual(self.ok("--format", "csv", "report", "categories", "--month", "2026-01"),
                         "category,spent,share,transactions\n"
                         "groceries,50.00,80.6,1\n"
                         "coffee,12.00,19.4,3\n")
        self.assertEqual(self.ok("--format", "json", "report", "merchants", "--top", "1", "--account", "checking"),
                         '{"merchant":"WHOLE FOODS MARKET","spent":"50.00","transactions":1}\n')
        self.assertEqual(self.ok("set-category", "7", "coffee"), "transaction 7: category coffee\n")
        self.assertEqual(self.run_cli("set-category", "99", "coffee")[0], errors.LEDGER_STATE)
        status, out, _ = self.run_cli("--format", "csv", "budget", "--month", "2026-01")
        self.assertEqual(status, errors.OVER_BUDGET)
        self.assertEqual(out, "category,budget,spent,remaining,status\n"
                              "coffee,5.00,12.00,-7.00,over\n"
                              "groceries,100.00,50.00,50.00,ok\n")
        self.assertEqual(self.ok("--format", "csv", "list", "--uncategorized"),
                         "id,date,account,description,amount,category\n")
        self.assertEqual(self.ok("set-category", "7", "--clear"), "transaction 7: category cleared\n")
        self.assertEqual(self.ok("--format", "csv", "list", "--uncategorized"),
                         "id,date,account,description,amount,category\n"
                         "7,2026-01-21,card,Mystery,1.00,uncategorized\n")
        self.assertEqual(self.ok("--format", "csv", "query", "SELECT COUNT(*) AS n, MAX(rule_no) AS r FROM ledger, rules"),
                         "n,r\n28,4\n")
        status, _, err = self.run_cli("query", "SELECT nope FROM ledger")
        self.assertEqual(status, errors.QUERY)
        self.assertTrue(err.startswith("pqledger: error: SEMANTIC_ERROR: "))

    def test_ledger_files_are_readable_by_the_engine(self) -> None:
        self.ok("init")
        self.ok("import", "chk.csv", "--account", "checking")
        self.ok("set-category", "2", "coffee")
        with polyquery.Database(os.path.join(self.dir.name, "books")) as db:
            info = db.open("t", "transactions.pqcf")
            self.assertEqual([(c.name, c.type) for c in info.columns], [
                ("id", "INT64"), ("account", "STRING"), ("date", "DATE"), ("description", "STRING"),
                ("merchant", "STRING"), ("amount", "DECIMAL(18,2)"), ("batch", "INT64")])
            self.assertEqual(db.query("SELECT id FROM t ORDER BY id").column("id"), [1, 2, 3, 4, 5])
            db.open("b", "batches.pqcf")
            self.assertEqual(db.query("SELECT * FROM b").rows, [(1, "checking", "chk.csv", 5, 0)])
            db.open("o", "overrides.pqcf")
            self.assertEqual(db.query("SELECT * FROM o").rows, [(2, "coffee")])

    def test_failed_import_changes_nothing(self) -> None:
        self.ok("init")
        with open("bad.csv", "w", encoding="utf-8") as f:
            f.write("Date,Description,Amount\n2026-01-01,a,1\n2026-01-02,b,x\n")
        status, _, err = self.run_cli("import", "bad.csv", "--account", "a")
        self.assertEqual(status, errors.IMPORT_DATA)
        self.assertIn("bad.csv:3:", err)
        self.assertEqual(self.ok("--format", "csv", "accounts"), "account,transactions,balance,first,last\n")

    def test_configuration_errors(self) -> None:
        self.assertEqual(self.run_cli("--config", "missing.conf", "init")[0], errors.CONFIG)
        with open("rules.conf", "w", encoding="utf-8") as f:
            f.write("groceries = SAFE_WAY\n")
        self.ok("init")
        self.assertEqual(self.run_cli("accounts")[0], errors.CONFIG)

    def test_help_and_version_need_no_configuration(self) -> None:
        os.remove("pqledger.conf")
        self.assertIn("usage: pqledger", self.ok("help"))
        self.assertTrue(self.ok("version").startswith("pqledger "))


class SelectNewTest(unittest.TestCase):
    def test_last_records_of_a_key_are_new(self) -> None:
        import datetime as dt

        from pqledger.bankcsv import Record
        from pqledger.importer import select_new

        day = dt.date(2026, 3, 2)
        coffee = [Record(n, day, "Starbucks", "STARBUCKS", -450) for n in (2, 3, 4, 5)]
        other = Record(6, day, "Starbucks", "STARBUCKS", -500)
        records = [*coffee, other]
        self.assertEqual(select_new(records, {}), [True] * 5)
        self.assertEqual(select_new(records, {(day, -450, "STARBUCKS"): 3}), [False, False, False, True, True])
        self.assertEqual(select_new(records, {(day, -450, "STARBUCKS"): 9, (day, -500, "STARBUCKS"): 1}), [False] * 5)
