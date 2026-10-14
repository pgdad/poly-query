"""Command-line parsing (pqledger.md §2)."""

from __future__ import annotations

import calendar
import datetime as dt
import re
from dataclasses import dataclass, field

from .config import FORMATS
from .errors import UsageError
from .names import UNCATEGORIZED, is_account_name, is_category_name
from .sql import Filters

USAGE = """\
usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGS]

commands:
  init                                  create the ledger in data_dir
  import FILE --account NAME            import a bank-statement CSV export
  report monthly [FILTERS]              income, expenses and net per month
  report categories [FILTERS]           spending per category with shares
  report merchants [FILTERS] [--top N]  the N merchants with the most spending (10)
  budget --month M [--account NAME]     spending per budget category in month M
  accounts                              transactions, balance and dates per account
  list [FILTERS] [--category C | --uncategorized]
                                        transactions ordered by date
  export [FILTERS]                      all columns, ordered by id
  set-category ID CATEGORY              override the category of a transaction
  set-category ID --clear               remove the override
  query SQL                             run SQL on the ledger tables
  help                                  show this help
  version                               show the version

filters: --month YYYY-MM | --from YYYY-MM --to YYYY-MM (inclusive), --account NAME

The configuration file is --config PATH, else $PQLEDGER_CONFIG, else
./pqledger.conf. See APP.md for the configuration reference.
"""

FILTER_OPTIONS = ("--month", "--from", "--to", "--account")
_MONTH = re.compile(r"([0-9]{4})-([0-9]{2})")
_POSITIVE = re.compile(r"[0-9]+")
INT64_MAX = 2**63 - 1


@dataclass(frozen=True)
class CommandSpec:
    positionals: tuple[str, ...] = ()
    options: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()


COMMANDS: dict[str, CommandSpec] = {
    "init": CommandSpec(),
    "import": CommandSpec(("FILE",), ("--account",)),
    "report monthly": CommandSpec((), FILTER_OPTIONS),
    "report categories": CommandSpec((), FILTER_OPTIONS),
    "report merchants": CommandSpec((), (*FILTER_OPTIONS, "--top")),
    "budget": CommandSpec((), ("--month", "--account")),
    "accounts": CommandSpec(),
    "list": CommandSpec((), (*FILTER_OPTIONS, "--category"), ("--uncategorized",)),
    "export": CommandSpec((), FILTER_OPTIONS),
    "set-category": CommandSpec(("ID", "CATEGORY"), (), ("--clear",)),
    "query": CommandSpec(("SQL",)),
    "help": CommandSpec(),
    "version": CommandSpec(),
}
REPORTS = ("monthly", "categories", "merchants")


@dataclass
class Invocation:
    """A parsed command line."""

    command: str
    config: str | None = None
    format: str | None = None
    positionals: list[str] = field(default_factory=list)
    options: dict[str, str] = field(default_factory=dict)
    flags: set[str] = field(default_factory=set)

    # ------------------------------------------------------------ typed values

    def filters(self) -> Filters:
        month = self.options.get("--month")
        start = end = None
        if month is not None:
            if "--from" in self.options or "--to" in self.options:
                raise UsageError("--month cannot be combined with --from or --to")
            start, end = month_range(month, "--month")
        if "--from" in self.options:
            start = month_range(self.options["--from"], "--from")[0]
        if "--to" in self.options:
            end = month_range(self.options["--to"], "--to")[1]
        if start is not None and end is not None and start > end:
            raise UsageError("--from is later than --to")
        return Filters(start, end, self.account())

    def account(self, required: bool = False) -> str | None:
        name = self.options.get("--account")
        if name is None:
            if required:
                raise UsageError("--account NAME is required")
            return None
        if not is_account_name(name):
            raise UsageError(f"invalid account name '{name}' (expected [a-z0-9_-]{{1,32}})")
        return name


def month_range(text: str, option: str) -> tuple[dt.date, dt.date]:
    """The first and last day of the month ``YYYY-MM``."""
    m = _MONTH.fullmatch(text)
    if m is None or not 1 <= int(m.group(1)) <= 9999 or not 1 <= int(m.group(2)) <= 12:
        raise UsageError(f"{option}: invalid month '{text}' (expected YYYY-MM)")
    year, month = int(m.group(1)), int(m.group(2))
    return dt.date(year, month, 1), dt.date(year, month, calendar.monthrange(year, month)[1])


def positive_int(text: str, what: str) -> int:
    if not _POSITIVE.fullmatch(text) or int(text) < 1:
        raise UsageError(f"{what} must be a positive integer, not '{text}'")
    return int(text)


def category_name(text: str) -> str:
    if not is_category_name(text):
        raise UsageError(f"invalid category name '{text}' (expected [a-z0-9_-]{{1,32}}, not '{UNCATEGORIZED}')")
    return text


def parse_args(argv: list[str]) -> Invocation:
    args = list(argv)
    config = fmt = None
    seen: set[str] = set()
    while args and args[0].startswith("--"):
        option = args.pop(0)
        if option in seen:
            raise UsageError(f"option {option} is repeated")
        seen.add(option)
        if option == "--help":
            return Invocation("help")
        if option not in ("--config", "--format"):
            raise UsageError(f"unknown option {option}")
        if not args:
            raise UsageError(f"option {option} needs a value")
        value = args.pop(0)
        if option == "--config":
            config = value
        elif value not in FORMATS:
            raise UsageError(f"--format must be table, csv or json, not '{value}'")
        else:
            fmt = value
    if not args:
        raise UsageError("no command given (see 'pqledger help')")
    command = args.pop(0)
    if command == "report":
        if not args or args[0] not in REPORTS:
            raise UsageError("report needs one of: " + ", ".join(REPORTS))
        command = "report " + args.pop(0)
    spec = COMMANDS.get(command)
    if spec is None:
        raise UsageError(f"unknown command '{command}' (see 'pqledger help')")
    inv = Invocation(command, config, fmt)
    while args:
        arg = args.pop(0)
        if arg.startswith("--") and len(arg) > 2:
            if arg in inv.options or arg in inv.flags:
                raise UsageError(f"option {arg} is repeated")
            if arg in spec.flags:
                inv.flags.add(arg)
            elif arg in spec.options:
                if not args:
                    raise UsageError(f"option {arg} needs a value")
                inv.options[arg] = args.pop(0)
            else:
                raise UsageError(f"unknown option {arg} for '{command}'")
        else:
            inv.positionals.append(arg)
    _check_arity(inv, spec)
    return inv


def _check_arity(inv: Invocation, spec: CommandSpec) -> None:
    wanted = len(spec.positionals)
    if inv.command == "set-category" and "--clear" in inv.flags:
        wanted = 1
    if len(inv.positionals) > wanted:
        raise UsageError(f"unexpected argument '{inv.positionals[wanted]}'")
    if len(inv.positionals) < wanted:
        missing = spec.positionals[len(inv.positionals)]
        raise UsageError(f"'{inv.command}' needs {missing}")
