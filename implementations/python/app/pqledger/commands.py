"""The commands (pqledger.md §6-§10). Every report and listing is one SQL
statement executed by the embedded engine; the host only formats the result
(and computes the ``share`` column of ``report categories``)."""

from __future__ import annotations

import os
from collections import defaultdict
from collections.abc import Callable
from decimal import Decimal
from typing import TextIO

import polyquery

from . import VERSION, config as configuration, errors, output
from .bankcsv import parse_statement, read_file
from .cli import USAGE, INT64_MAX, Invocation, category_name, positive_int
from .config import Config
from .errors import ConfigError, LedgerStateError, QueryError
from .ledger import Ledger
from .rules import Budget, Rule, load_budgets, load_rules
from .sql import BUDGETS_COLUMNS, RULES_COLUMNS, Filters, date_literal, literal, where, with_ledger

LIST_COLUMNS = 'id, "date", account, description, amount, category'
EXPORT_COLUMNS = 'id, account, "date", description, merchant, amount, category, batch'
DEFAULT_TOP = 10


# ------------------------------------------------------------ context


class Context:
    """What a ledger command needs: the configuration, the rules and the open
    ledger with the ``rules`` (and ``budgets``) tables loaded."""

    def __init__(self, inv: Invocation, *, budgets: bool = False, require_budgets: bool = False):
        self.config: Config = configuration.load(inv.config)
        self.format = inv.format or self.config.output_format
        self.rules: list[Rule] = load_rules(self.config.rules_file)
        self.budgets: list[Budget] = []
        if require_budgets and self.config.budget_file is None:
            raise ConfigError("budget needs a budget_file in [ledger]")
        if budgets and self.config.budget_file is not None:
            self.budgets = load_budgets(self.config.budget_file)
        self.ledger = Ledger.open(self.config.data_dir, self.config.threads, self.config.memory_mb)
        try:
            self.ledger.create("rules", RULES_COLUMNS, [(r.number, r.category, r.pattern) for r in self.rules])
            if budgets:
                self.ledger.create("budgets", BUDGETS_COLUMNS, [(b.category, b.amount) for b in self.budgets])
        except BaseException:
            self.ledger.close()
            raise

    def __enter__(self) -> Context:
        return self

    def __exit__(self, *exc: object) -> None:
        self.ledger.close()

    def query(self, sql: str) -> polyquery.Result:
        return self.ledger.query(sql)

    def print(self, result: polyquery.Result | output.Table, out: TextIO) -> None:
        table = result if isinstance(result, output.Table) else output.Table(result.columns, result.types, result.rows)
        output.write(table, self.format, out)


# ------------------------------------------------------------ init, import


def cmd_init(inv: Invocation, out: TextIO) -> None:
    config = configuration.load(inv.config)
    Ledger.initialize(config.data_dir, config.threads, config.memory_mb).close()
    out.write("initialized ledger\n")


def cmd_import(inv: Invocation, out: TextIO) -> None:
    account = inv.account(required=True)
    path = inv.positionals[0]
    with Context(inv) as ctx:
        source = path
        records = parse_statement(read_file(path, source), ctx.config.settings_for(account), source)
        ledger = ctx.ledger

        # duplicates (§6.4): per key (date, amount, merchant) of this account,
        # the ledger's l transactions match the first l of the file's f records
        existing: dict[tuple, int] = {}
        if records:
            first = min(r.date for r in records)
            last = max(r.date for r in records)
            result = ctx.query(
                'SELECT "date", amount, merchant, COUNT(*) AS n FROM transactions'
                + where(f"account = {literal(account)}", f'"date" >= {date_literal(first)}', f'"date" <= {date_literal(last)}')
                + ' GROUP BY "date", amount, merchant'
            )
            for day, amount, merchant, n in result:
                existing[(day, int(amount.scaleb(2)), merchant)] = n
        by_key: dict[tuple, list[int]] = defaultdict(list)
        for i, r in enumerate(records):
            by_key[(r.date, r.cents, r.merchant)].append(i)
        keep = [False] * len(records)
        for key, indexes in by_key.items():
            new = max(0, len(indexes) - existing.get(key, 0))
            for i in indexes[len(indexes) - new:]:
                keep[i] = True

        max_id, max_tx_batch = ctx.query("SELECT MAX(id), MAX(batch) FROM transactions").rows[0]
        max_batch = ctx.query("SELECT MAX(batch) FROM batches").scalar()
        next_id = (max_id or 0) + 1
        batch = max(max_batch or 0, max_tx_batch or 0) + 1
        rows = []
        for r, kept in zip(records, keep):
            if kept:
                amount = Decimal(r.cents).scaleb(-2)
                rows.append((next_id + len(rows), account, r.date, r.description, r.merchant, amount, batch))
        duplicates = len(records) - len(rows)
        if rows:
            ledger.append("transactions", rows)
        ledger.append("batches", [(batch, account, os.path.basename(path), len(rows), duplicates)])
        if rows:
            ledger.save("transactions")
        ledger.save("batches")
    out.write(f"batch {batch}: imported {len(rows)}, duplicates {duplicates}\n")


# ------------------------------------------------------------ reports


def cmd_report_monthly(inv: Invocation, out: TextIO) -> None:
    filters = inv.filters()
    with Context(inv) as ctx:
        month = 'SUBSTR(CAST("date" AS STRING), 1, 7)'
        result = ctx.query(
            f"SELECT {month} AS month,"
            " SUM(CASE WHEN amount > 0 THEN amount ELSE 0.00 END) AS income,"
            " -SUM(CASE WHEN amount < 0 THEN amount ELSE 0.00 END) AS expenses,"
            " SUM(amount) AS net,"
            " COUNT(*) AS transactions"
            f" FROM transactions{where(filters.conditions())}"
            f" GROUP BY {month} ORDER BY month"
        )
        ctx.print(result, out)


def cmd_report_categories(inv: Invocation, out: TextIO) -> None:
    filters = inv.filters()
    with Context(inv) as ctx:
        result = ctx.query(
            with_ledger(
                "SELECT category, -SUM(amount) AS spent, COUNT(*) AS transactions FROM ledger"
                + where("amount < 0", filters.conditions())
                + " GROUP BY category ORDER BY spent DESC, category"
            )
        )
        cents = [int(spent.scaleb(2)) for _, spent, _ in result]
        total = sum(cents)
        rows = [
            (category, spent, share_of(c, total), n) for (category, spent, n), c in zip(result, cents)
        ]
        types = (result.types[0], result.types[1], "DECIMAL(18,1)", result.types[2])
        ctx.print(output.Table(("category", "spent", "share", "transactions"), types, rows), out)


def share_of(part: int, total: int) -> Decimal:
    """``100 × part ÷ total`` rounded half away from zero to one fractional
    digit, exactly (part, total ≥ 0 in cents)."""
    tenths = (2000 * part + total) // (2 * total)
    return Decimal(tenths).scaleb(-1)


def cmd_report_merchants(inv: Invocation, out: TextIO) -> None:
    filters = inv.filters()
    top = DEFAULT_TOP
    if "--top" in inv.options:
        top = min(positive_int(inv.options["--top"], "--top"), INT64_MAX)
    with Context(inv) as ctx:
        result = ctx.query(
            "SELECT merchant, -SUM(amount) AS spent, COUNT(*) AS transactions FROM transactions"
            + where("amount < 0", filters.conditions())
            + f" GROUP BY merchant ORDER BY spent DESC, merchant LIMIT {top}"
        )
        ctx.print(result, out)


def cmd_budget(inv: Invocation, out: TextIO) -> int:
    if "--month" not in inv.options:
        raise errors.UsageError("budget needs --month M")
    filters = inv.filters()
    with Context(inv, budgets=True, require_budgets=True) as ctx:
        spent = "COALESCE(s.spent, 0.00)"
        result = ctx.query(
            with_ledger(
                "SELECT b.category, b.amount AS budget,"
                f" {spent} AS spent,"
                f" b.amount - {spent} AS remaining,"
                f" CASE WHEN {spent} <= b.amount THEN 'ok' ELSE 'over' END AS status"
                " FROM budgets b LEFT JOIN month_spent s ON s.category = b.category"
                " ORDER BY b.category",
                "month_spent AS (SELECT category, -SUM(amount) AS spent FROM ledger"
                + where("amount < 0", filters.conditions())
                + " GROUP BY category)",
            )
        )
        ctx.print(result, out)
    over = any(row[4] == "over" for row in result)
    return errors.OVER_BUDGET if over else errors.OK


# ------------------------------------------------------------ listing and editing


def cmd_accounts(inv: Invocation, out: TextIO) -> None:
    with Context(inv) as ctx:
        result = ctx.query(
            'SELECT account, COUNT(*) AS transactions, SUM(amount) AS balance, MIN("date") AS "first",'
            ' MAX("date") AS "last" FROM transactions GROUP BY account ORDER BY account'
        )
        ctx.print(result, out)


def cmd_list(inv: Invocation, out: TextIO) -> None:
    filters = inv.filters()
    conditions = filters.conditions()
    category = inv.options.get("--category")
    if category is not None and "--uncategorized" in inv.flags:
        raise errors.UsageError("--category and --uncategorized exclude each other")
    if "--uncategorized" in inv.flags:
        category = "uncategorized"
    elif category is not None and category != "uncategorized":
        category = category_name(category)
    if category is not None:
        conditions.append(f"category = {literal(category)}")
    with Context(inv) as ctx:
        result = ctx.query(with_ledger(f"SELECT {LIST_COLUMNS} FROM ledger{where(conditions)} ORDER BY \"date\", id"))
        ctx.print(result, out)


def cmd_export(inv: Invocation, out: TextIO) -> None:
    filters = inv.filters()
    with Context(inv) as ctx:
        result = ctx.query(with_ledger(f"SELECT {EXPORT_COLUMNS} FROM ledger{where(filters.conditions())} ORDER BY id"))
        ctx.print(result, out)


def cmd_set_category(inv: Invocation, out: TextIO) -> None:
    clear = "--clear" in inv.flags
    tx_id = positive_int(inv.positionals[0], "ID")
    category = None if clear else category_name(inv.positionals[1])
    with Context(inv) as ctx:
        known = tx_id <= INT64_MAX and ctx.query(f"SELECT COUNT(*) FROM transactions WHERE id = {tx_id}").scalar() > 0
        if not known:
            raise LedgerStateError(f"no transaction with id {tx_id}")
        others = f"SELECT id, category FROM overrides WHERE id <> {tx_id}"
        if category is None:
            ctx.ledger.rebuild("overrides", f"{others} ORDER BY id")
        else:
            ctx.ledger.create("new_override", (("id", "INT64"), ("category", "STRING")), [(tx_id, category)])
            ctx.ledger.rebuild("overrides", f"{others} UNION ALL SELECT id, category FROM new_override ORDER BY id")
        ctx.ledger.save("overrides")
    out.write(f"transaction {tx_id}: category {'cleared' if clear else category}\n")


def cmd_query(inv: Invocation, out: TextIO) -> None:
    sql = inv.positionals[0]
    with Context(inv, budgets=True) as ctx:
        ctx.ledger.rebuild("ledger", with_ledger("SELECT * FROM ledger ORDER BY id"))
        try:
            result = ctx.ledger.db.query(sql, threads=ctx.config.threads)
        except polyquery.Error as e:
            raise QueryError(f"{e.code}: {e.message}") from None
        ctx.print(result, out)


# ------------------------------------------------------------ help, version


def cmd_help(inv: Invocation, out: TextIO) -> None:
    out.write(USAGE)


def cmd_version(inv: Invocation, out: TextIO) -> None:
    out.write(f"pqledger {VERSION} (engine {polyquery.ENGINE_NAME} {polyquery.ENGINE_VERSION})\n")


HANDLERS: dict[str, Callable[[Invocation, TextIO], int | None]] = {
    "init": cmd_init,
    "import": cmd_import,
    "report monthly": cmd_report_monthly,
    "report categories": cmd_report_categories,
    "report merchants": cmd_report_merchants,
    "budget": cmd_budget,
    "accounts": cmd_accounts,
    "list": cmd_list,
    "export": cmd_export,
    "set-category": cmd_set_category,
    "query": cmd_query,
    "help": cmd_help,
    "version": cmd_version,
}
