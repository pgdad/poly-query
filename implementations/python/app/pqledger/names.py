"""Account and category names (pqledger.md §3.3) and ASCII case mapping."""

from __future__ import annotations

import re

_NAME = re.compile(r"[a-z0-9_-]{1,32}")
UNCATEGORIZED = "uncategorized"

_ASCII_UPPER = str.maketrans("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def is_account_name(text: str) -> bool:
    return _NAME.fullmatch(text) is not None


def is_category_name(text: str) -> bool:
    return _NAME.fullmatch(text) is not None and text != UNCATEGORIZED


def ascii_upper(text: str) -> str:
    """Upper-cases ASCII letters only; other characters are unchanged."""
    return text.translate(_ASCII_UPPER)


def ascii_lower(text: str) -> str:
    return text.translate(_ASCII_LOWER)
