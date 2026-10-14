"""The category rules file and the budget file (pqledger.md §5)."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from decimal import Decimal

from .errors import ConfigError
from .inifile import parse_lines, read_text
from .names import ascii_upper, is_category_name

_AMOUNT = re.compile(r"([0-9]{1,16})(?:\.([0-9]{1,2}))?")


@dataclass(frozen=True)
class Rule:
    """One pattern of the rules file; ``number`` counts patterns in file order."""

    number: int
    category: str
    pattern: str  # as written, ASCII upper-cased

    def like_pattern(self) -> str:
        """The SQL LIKE pattern: ``*`` is ``%`` and ``?`` is ``_`` (patterns
        contain neither ``%`` nor ``_``)."""
        return self.pattern.replace("*", "%").replace("?", "_")


@dataclass(frozen=True)
class Budget:
    category: str
    amount: Decimal  # two fractional digits


def _category(name: str, source: str, number: int) -> str:
    if not is_category_name(name):
        raise ConfigError(f"{source}:{number}: invalid category name '{name}'")
    return name


def load_rules(path: str | None) -> list[Rule]:
    """The rules in file order; no file configured: no rules."""
    if path is None:
        return []
    return parse_rules(read_text(path, "rules file"), os.path.basename(path))


def parse_rules(text: str, source: str) -> list[Rule]:
    rules: list[Rule] = []
    for line in parse_lines(text, source, sections=False):
        category = _category(line.key, source, line.number)
        for raw in line.value.split(","):
            pattern = raw.strip(" \t")
            if not pattern:
                raise ConfigError(f"{source}:{line.number}: empty pattern")
            if "%" in pattern or "_" in pattern:
                raise ConfigError(f"{source}:{line.number}: patterns must not contain '%' or '_'")
            rules.append(Rule(len(rules) + 1, category, ascii_upper(pattern)))
    return rules


def load_budgets(path: str) -> list[Budget]:
    return parse_budgets(read_text(path, "budget file"), os.path.basename(path))


def parse_budgets(text: str, source: str) -> list[Budget]:
    budgets: dict[str, Budget] = {}
    for line in parse_lines(text, source, sections=False):
        category = _category(line.key, source, line.number)
        if category in budgets:
            raise ConfigError(f"{source}:{line.number}: category '{category}' is listed twice")
        m = _AMOUNT.fullmatch(line.value)
        if m is None:
            raise ConfigError(f"{source}:{line.number}: invalid budget amount '{line.value}'")
        cents = int(m.group(1)) * 100 + int((m.group(2) or "").ljust(2, "0"))
        budgets[category] = Budget(category, Decimal(cents).scaleb(-2))
    return list(budgets.values())
