"""The configuration file (pqledger.md §3): locating, parsing, validating."""

from __future__ import annotations

import os
import re
from collections.abc import Callable
from dataclasses import dataclass, field, replace

from .errors import ConfigError
from .inifile import Line, parse_lines, read_text
from .names import is_account_name

CONFIG_ENV = "PQLEDGER_CONFIG"
DEFAULT_CONFIG = "pqledger.conf"

FORMATS = ("table", "csv", "json")
DATE_FORMATS = ("YYYY-MM-DD", "YYYYMMDD", "MM/DD/YYYY", "DD/MM/YYYY", "DD.MM.YYYY")
AMOUNT_MODES = ("signed", "debit_credit")
THOUSANDS = {"none": "", ",": ",", ".": ".", "space": " ", "'": "'"}

_DIGITS = re.compile(r"[0-9]+")


@dataclass(frozen=True)
class ColumnRef:
    """A column of a bank file: a 1-based ``position`` or a header ``name``."""

    position: int | None = None
    name: str | None = None

    def __str__(self) -> str:
        return f"column {self.position}" if self.position is not None else f"column '{self.name}'"


def column_ref(text: str) -> ColumnRef:
    if _DIGITS.fullmatch(text) and int(text) > 0:
        return ColumnRef(position=int(text))
    return ColumnRef(name=text)


@dataclass(frozen=True)
class ImportSettings:
    """How one account's bank files are read (``[import]`` / ``[account NAME]``)."""

    delimiter: str = ","
    header: bool = True
    skip_lines: int = 0
    date_column: ColumnRef = ColumnRef(name="Date")
    date_format: str = "YYYY-MM-DD"
    description_column: ColumnRef = ColumnRef(name="Description")
    amount_mode: str = "signed"
    amount_column: ColumnRef = ColumnRef(name="Amount")
    debit_column: ColumnRef = ColumnRef(name="Debit")
    credit_column: ColumnRef = ColumnRef(name="Credit")
    decimal_separator: str = "."
    thousands_separator: str = ""  # "" = none
    currency_symbol: str = ""
    invert_sign: bool = False

    def columns(self) -> list[tuple[str, ColumnRef]]:
        """The columns this mode reads, by configuration key."""
        refs = [("date_column", self.date_column), ("description_column", self.description_column)]
        if self.amount_mode == "signed":
            refs.append(("amount_column", self.amount_column))
        else:
            refs += [("debit_column", self.debit_column), ("credit_column", self.credit_column)]
        return refs


@dataclass
class Config:
    path: str
    data_dir: str
    rules_file: str | None = None
    budget_file: str | None = None
    output_format: str = "table"
    threads: int | None = None
    memory_mb: int | None = None
    import_settings: ImportSettings = field(default_factory=ImportSettings)
    accounts: dict[str, ImportSettings] = field(default_factory=dict)

    def settings_for(self, account: str) -> ImportSettings:
        return self.accounts.get(account, self.import_settings)


# ------------------------------------------------------------ value parsers


def _boolean(text: str) -> bool:
    if text not in ("true", "false"):
        raise ValueError("expected true or false")
    return text == "true"


def _count(text: str, minimum: int) -> int:
    if not _DIGITS.fullmatch(text) or int(text) < minimum:
        raise ValueError(f"expected an integer >= {minimum}")
    return int(text)


def _choice(choices: tuple[str, ...]) -> Callable[[str], str]:
    def parse(text: str) -> str:
        if text not in choices:
            raise ValueError("expected one of " + ", ".join(choices))
        return text

    return parse


def _delimiter(text: str) -> str:
    if text == "tab":
        return "\t"
    if len(text) != 1 or not text.isascii() or text in '"\r\n':
        raise ValueError("expected one ASCII character or 'tab'")
    return text


def _column(text: str) -> ColumnRef:
    if text == "":
        raise ValueError("expected a column position or header name")
    return column_ref(text)


def _thousands(text: str) -> str:
    if text not in THOUSANDS:
        raise ValueError("expected none, ',', '.', space or \"'\"")
    return THOUSANDS[text]


def _path(text: str) -> str:
    if text == "":
        raise ValueError("expected a path")
    return text


IMPORT_KEYS = {
    "delimiter": _delimiter,
    "header": _boolean,
    "skip_lines": lambda t: _count(t, 0),
    "date_column": _column,
    "date_format": _choice(DATE_FORMATS),
    "description_column": _column,
    "amount_mode": _choice(AMOUNT_MODES),
    "amount_column": _column,
    "debit_column": _column,
    "credit_column": _column,
    "decimal_separator": _choice((".", ",")),
    "thousands_separator": _thousands,
    "currency_symbol": lambda t: t,
    "invert_sign": _boolean,
}
LEDGER_KEYS = {"data_dir": _path, "rules_file": _path, "budget_file": _path}
OUTPUT_KEYS = {"format": _choice(FORMATS)}
ENGINE_KEYS = {"threads": lambda t: _count(t, 1), "memory_mb": lambda t: _count(t, 1)}


# ------------------------------------------------------------ loading


def locate(option: str | None) -> str:
    """The configuration file to use (§3.1), relative to the current directory."""
    if option is not None:
        return option
    env = os.environ.get(CONFIG_ENV)
    if env:
        return env
    return DEFAULT_CONFIG


def load(option: str | None) -> Config:
    path = os.path.abspath(locate(option))
    return parse(read_text(path, "configuration file"), path)


def parse(text: str, path: str) -> Config:
    """Parses and validates configuration text read from ``path``."""
    source = os.path.basename(path)
    sections: dict[str, dict[str, object]] = {}
    current: dict[str, object] | None = None
    keys: dict = {}
    for line in parse_lines(text, source, sections=True):
        if line.section is not None:
            name = line.section
            keys = _section_keys(name, line, source)
            if name in sections:
                raise ConfigError(f"{source}:{line.number}: section [{name}] is repeated")
            current = sections[name] = {}
            continue
        if current is None:
            raise ConfigError(f"{source}:{line.number}: assignment before the first section header")
        _assign(current, keys, line, source)

    ledger = sections.get("ledger")
    if ledger is None:
        raise ConfigError(f"{source}: the [ledger] section is missing")
    if "data_dir" not in ledger:
        raise ConfigError(f"{source}: [ledger] data_dir is required")
    base = os.path.dirname(path)
    config = Config(
        path=path,
        data_dir=os.path.join(base, ledger["data_dir"]),
        rules_file=os.path.join(base, ledger["rules_file"]) if "rules_file" in ledger else None,
        budget_file=os.path.join(base, ledger["budget_file"]) if "budget_file" in ledger else None,
    )
    output = sections.get("output", {})
    config.output_format = output.get("format", "table")
    engine = sections.get("engine", {})
    config.threads = engine.get("threads")
    config.memory_mb = engine.get("memory_mb")

    config.import_settings = _settings(ImportSettings(), sections.get("import", {}), source, "[import]")
    for name, values in sections.items():
        if name.startswith("account "):
            account = name[len("account "):]
            config.accounts[account] = _settings(config.import_settings, values, source, f"[{name}]")
    return config


def _section_keys(name: str, line: Line, source: str) -> dict:
    if name == "ledger":
        return LEDGER_KEYS
    if name == "import":
        return IMPORT_KEYS
    if name == "output":
        return OUTPUT_KEYS
    if name == "engine":
        return ENGINE_KEYS
    if name.startswith("account "):
        account = name[len("account "):]
        if not is_account_name(account):
            raise ConfigError(f"{source}:{line.number}: invalid account name '{account}'")
        return IMPORT_KEYS
    raise ConfigError(f"{source}:{line.number}: unknown section [{name}]")


def _assign(section: dict[str, object], keys: dict, line: Line, source: str) -> None:
    key = line.key
    parse = keys.get(key)
    if parse is None:
        raise ConfigError(f"{source}:{line.number}: unknown key '{key}'")
    if key in section:
        raise ConfigError(f"{source}:{line.number}: key '{key}' is repeated")
    try:
        section[key] = parse(line.value)
    except ValueError as e:
        raise ConfigError(f"{source}:{line.number}: invalid value for '{key}': {e}") from None


def _settings(base: ImportSettings, values: dict[str, object], source: str, where: str) -> ImportSettings:
    settings = replace(base, **values)
    if settings.thousands_separator == settings.decimal_separator:
        raise ConfigError(f"{source}: {where}: decimal_separator and thousands_separator must differ")
    if not settings.header:
        for key, ref in settings.columns():
            if ref.name is not None:
                raise ConfigError(f"{source}: {where}: {key} names a header column but header = false")
    return settings
