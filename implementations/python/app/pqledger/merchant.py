"""Merchant normalization (pqledger.md §6.3)."""

from __future__ import annotations

import re

from .names import ascii_upper

_BLANK_RUNS = re.compile(r"[ \t]+")
_STORE_NUMBER = re.compile(r"#[0-9]+|[0-9]{3,}")


def normalize(description: str) -> str:
    """``Whole Foods Market #10234`` → ``WHOLE FOODS MARKET``: ASCII upper
    case, runs of blanks collapsed, a trailing store-number token removed."""
    text = _BLANK_RUNS.sub(" ", ascii_upper(description)).strip(" ")
    head, space, last = text.rpartition(" ")
    if space and _STORE_NUMBER.fullmatch(last):
        return head
    return text
