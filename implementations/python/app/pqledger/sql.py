"""SQL text of pqledger's queries: literals, filters and the resolved
``ledger`` relation (category resolution, pqledger.md §5.1)."""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass

from .names import UNCATEGORIZED

RULES_COLUMNS = (("rule_no", "INT64"), ("category", "STRING"), ("pattern", "STRING"))
BUDGETS_COLUMNS = (("category", "STRING"), ("amount", "DECIMAL(18,2)"))

LEDGER_COLUMNS = 't.id, t.account, t."date", t.description, t.merchant, t.amount, t.batch'


def literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def date_literal(day: dt.date) -> str:
    return f"DATE '{day.isoformat()}'"


@dataclass(frozen=True)
class Filters:
    """The common filter options: an inclusive date range and an account."""

    start: dt.date | None = None
    end: dt.date | None = None
    account: str | None = None

    def conditions(self) -> list[str]:
        out = []
        if self.start is not None:
            out.append(f'"date" >= {date_literal(self.start)}')
        if self.end is not None:
            out.append(f'"date" <= {date_literal(self.end)}')
        if self.account is not None:
            out.append(f"account = {literal(self.account)}")
        return out


def where(*conditions: str | list[str]) -> str:
    flat: list[str] = []
    for c in conditions:
        flat.extend([c] if isinstance(c, str) else c)
    return " WHERE " + " AND ".join(flat) if flat else ""


# The category of a transaction: its override, else the category of the
# first rule (lowest rule_no) whose pattern matches the merchant (ASCII
# case-insensitively: merchants are compared upper-cased, patterns are
# stored upper-cased; * and ? become the LIKE wildcards % and _), else
# 'uncategorized'. Patterns are matched once per distinct merchant.
LEDGER_CTE = f"""rule_matches AS (
  SELECT d.merchant, MIN(r.rule_no) AS rule_no
  FROM (SELECT DISTINCT merchant FROM transactions) d
  JOIN rules r ON UPPER(d.merchant) LIKE REPLACE(REPLACE(r.pattern, '*', '%'), '?', '_')
  GROUP BY d.merchant
), merchant_categories AS (
  SELECT m.merchant, r.category FROM rule_matches m JOIN rules r ON r.rule_no = m.rule_no
), ledger AS (
  SELECT {LEDGER_COLUMNS},
         COALESCE(o.category, mc.category, {literal(UNCATEGORIZED)}) AS category
  FROM transactions t
  LEFT JOIN overrides o ON o.id = t.id
  LEFT JOIN merchant_categories mc ON mc.merchant = t.merchant
)"""


def with_ledger(query: str, *ctes: str) -> str:
    """``query`` (which reads ``ledger`` and the further ``ctes``, each
    ``name AS (...)``) with the ledger CTEs."""
    return "WITH " + ", ".join((LEDGER_CTE, *ctes)) + " " + query
