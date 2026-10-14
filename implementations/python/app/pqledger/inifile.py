"""The line syntax shared by the configuration, rules and budget files
(pqledger.md §3.2, §5)."""

from __future__ import annotations

from dataclasses import dataclass

from .errors import ConfigError

_BLANKS = " \t"


@dataclass(frozen=True)
class Line:
    """A meaningful line: a section header (``key`` None, ``section`` set)
    or an assignment ``key = value`` (value unquoted)."""

    number: int
    section: str | None = None
    key: str | None = None
    value: str = ""


def read_text(path: str, what: str) -> str:
    """The UTF-8 text of a file."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        raise ConfigError(f"{what} {path} does not exist") from None
    except OSError as e:
        raise ConfigError(f"cannot read {what} {path}: {e.strerror}") from None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ConfigError(f"{path}: {what} is not valid UTF-8 (byte {e.start})") from None
    return text


def unquote(value: str) -> str:
    """``"…"`` loses its quotes; inside, ``\\"`` is ``"`` and ``\\\\`` is ``\\``."""
    if len(value) < 2 or not (value.startswith('"') and value.endswith('"')):
        return value
    inner, out, i = value[1:-1], [], 0
    while i < len(inner):
        c = inner[i]
        if c == "\\" and i + 1 < len(inner) and inner[i + 1] in '"\\':
            out.append(inner[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def parse_lines(text: str, source: str, *, sections: bool) -> list[Line]:
    """Splits ``text`` into section headers and assignments, skipping a
    leading BOM, blank lines and comments. Any other line is a ConfigError naming
    ``source:LINE``."""
    out: list[Line] = []
    if text.startswith("\ufeff"):
        text = text[1:]
    lines = text.split("\n")
    for number, raw in enumerate(lines, 1):
        if raw.endswith("\r"):
            raw = raw[:-1]
        line = raw.strip(_BLANKS)
        if not line or line[0] in "#;":
            continue
        if sections and line.startswith("[") and line.endswith("]"):
            out.append(Line(number, section=line[1:-1]))
            continue
        key, eq, value = line.partition("=")
        key = key.strip(_BLANKS)
        if not eq or not key:
            raise ConfigError(f"{source}:{number}: expected KEY = VALUE" + (" or [SECTION]" if sections else ""))
        out.append(Line(number, key=key, value=unquote(value.strip(_BLANKS))))
    return out
