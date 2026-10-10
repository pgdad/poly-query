"""Identifier matching: ASCII case-insensitive (grammar.md §1, ingestion.md)."""

_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def fold(name: str) -> str:
    """Folds ASCII letters to lower case; other characters are unchanged."""
    return name.translate(_ASCII_LOWER)


def same_name(a: str, b: str) -> bool:
    return fold(a) == fold(b)
