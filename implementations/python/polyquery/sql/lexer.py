"""SQL lexer (spec/sql/grammar.md §1)."""

from __future__ import annotations

import bisect
import enum
import re
from collections.abc import Iterator
from dataclasses import dataclass

from .. import errors
from ..limits import Check, no_check

RESERVED_KEYWORDS = frozenset(
    """ALL AND AS ASC BETWEEN BY CASE CAST CREATE CROSS DATE DESC DISTINCT DROP ELSE
    END EXISTS EXPLAIN FALSE FIRST FROM FULL GROUP HAVING IF IN INDEX INNER IS JOIN
    LAST LEFT LIKE LIMIT NOT NULL NULLS OFFSET ON OR ORDER OUTER RIGHT SELECT THEN
    TIMESTAMP TRUE UNION USING WHEN WHERE WITH""".split()
)
# reserved only for future syntax (grammar.md §1): no construct starts with
# them, so after an explicit AS they are accepted as an alias
FUTURE_KEYWORDS = frozenset({"FULL", "RIGHT"})


class TokenKind(enum.Enum):
    KEYWORD = "keyword"
    IDENT = "identifier"
    NUMBER = "number"
    STRING = "string"
    OP = "operator"
    EOF = "end of input"


@dataclass(frozen=True, slots=True)
class Token:
    kind: TokenKind
    value: str  # keyword (upper case), identifier text, literal text or operator
    line: int
    column: int
    quoted: bool = False  # for identifiers written as "..."
    text: str = ""  # the source spelling of a keyword

    def is_keyword(self, *words: str) -> bool:
        return self.kind is TokenKind.KEYWORD and self.value in words

    def is_op(self, *ops: str) -> bool:
        return self.kind is TokenKind.OP and self.value in ops

    def describe(self) -> str:
        if self.kind is TokenKind.EOF:
            return "end of input"
        return f"'{self.value}'"


_TWO_CHAR_OPS = frozenset({"||", "<=", ">=", "<>", "!="})
_ONE_CHAR_OPS = frozenset("+-*/%=<>(),.;")
_WHITESPACE = frozenset(" \t\r\n")
# runs of characters scanned in C (long statements must lex in linear time
# with a small constant: the deadline is only checked between tokens)
_WHITESPACE_RUN = re.compile(r"[ \t\r\n]+")
_IDENT_CHARS = re.compile(r"[A-Za-z0-9_]*")
_DIGITS = re.compile(r"[0-9]*")


def _is_ident_start(c: str) -> bool:
    return ("a" <= c <= "z") or ("A" <= c <= "Z") or c == "_"


def _is_ident_char(c: str) -> bool:
    return _is_ident_start(c) or ("0" <= c <= "9")


def _is_digit(c: str) -> bool:
    return "0" <= c <= "9"


# tokens between two deadline checks
_CHECK_INTERVAL = 1024


def _line_starts(text: str) -> list[int]:
    starts = [0]
    i = text.find("\n")
    while i >= 0:
        starts.append(i + 1)
        i = text.find("\n", i + 1)
    return starts


class Lexer:
    def __init__(self, text: str, check: Check = no_check):
        self.text = text
        self.check = check
        self._line_starts = _line_starts(text)

    def _error(self, message: str, pos: int) -> errors.PolyQueryError:
        line, column = self._location(pos)
        return errors.parse_error(f"{message} at line {line}, column {column}", line=line, column=column)

    def _location(self, pos: int) -> tuple[int, int]:
        line = bisect.bisect_right(self._line_starts, pos)
        return line, pos - self._line_starts[line - 1] + 1

    def tokenize(self) -> list[Token]:
        return list(self.tokens())

    def tokens(self) -> Iterator[Token]:
        """Produces the tokens lazily (the parser stops early on errors and
        on statements beyond the size limits), ending with EOF."""
        text = self.text
        n = len(text)
        i = 0
        countdown = _CHECK_INTERVAL
        while True:
            countdown -= 1
            if not countdown:
                countdown = _CHECK_INTERVAL
                self.check()
            # skip whitespace and comments
            while i < n:
                c = text[i]
                if c in _WHITESPACE:
                    i = _WHITESPACE_RUN.match(text, i).end()  # type: ignore[union-attr]
                elif c == "-" and text.startswith("--", i):
                    end = text.find("\n", i)
                    i = n if end < 0 else end + 1
                elif c == "/" and text.startswith("/*", i):
                    end = text.find("*/", i + 2)
                    if end < 0:
                        raise self._error("unterminated block comment", i)
                    i = end + 2
                else:
                    break
            if i >= n:
                line, col = self._location(n)
                yield Token(TokenKind.EOF, "", line, col)
                return
            start = i
            c = text[i]
            line, col = self._location(start)
            if _is_ident_start(c):
                i = _IDENT_CHARS.match(text, i + 1).end()  # type: ignore[union-attr]
                word = text[start:i]
                upper = word.upper()
                if upper in RESERVED_KEYWORDS:
                    yield Token(TokenKind.KEYWORD, upper, line, col, text=word)
                else:
                    yield Token(TokenKind.IDENT, word, line, col)
            elif _is_digit(c) or (c == "." and i + 1 < n and _is_digit(text[i + 1])):
                i = self._scan_number(i)
                if i < n and _is_ident_char(text[i]):
                    raise self._error("invalid numeric literal", start)
                yield Token(TokenKind.NUMBER, text[start:i], line, col)
            elif c == "'":
                value, i = self._scan_quoted(i, "'", "string literal")
                yield Token(TokenKind.STRING, value, line, col)
            elif c == '"':
                value, i = self._scan_quoted(i, '"', "quoted identifier")
                if value == "":
                    raise self._error("empty quoted identifier", start)
                yield Token(TokenKind.IDENT, value, line, col, quoted=True)
            elif text[i : i + 2] in _TWO_CHAR_OPS:
                yield Token(TokenKind.OP, text[i : i + 2], line, col)
                i += 2
            elif c in _ONE_CHAR_OPS:
                yield Token(TokenKind.OP, c, line, col)
                i += 1
            else:
                raise self._error(f"unexpected character {c!r}", i)

    def _scan_number(self, i: int) -> int:
        text, n = self.text, len(self.text)
        i = _DIGITS.match(text, i).end()  # type: ignore[union-attr]
        if i < n and text[i] == ".":
            i = _DIGITS.match(text, i + 1).end()  # type: ignore[union-attr]
        if i < n and text[i] in "eE":
            j = i + 1
            if j < n and text[j] in "+-":
                j += 1
            if j < n and _is_digit(text[j]):
                i = _DIGITS.match(text, j).end()  # type: ignore[union-attr]
            else:
                raise self._error("invalid exponent in numeric literal", i)
        return i

    def _scan_quoted(self, i: int, quote: str, what: str) -> tuple[str, int]:
        text = self.text
        parts = []
        pos = i + 1
        while True:
            end = text.find(quote, pos)
            if end < 0:
                raise self._error(f"unterminated {what}", i)
            parts.append(text[pos:end])
            if text.startswith(quote, end + 1):
                parts.append(quote)
                pos = end + 2
            else:
                return "".join(parts), end + 1


def tokenize(text: str, check: Check = no_check) -> list[Token]:
    return Lexer(text, check).tokenize()
