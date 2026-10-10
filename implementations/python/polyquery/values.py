"""Value parsing, formatting and exact numeric helpers (types.md §3, §8, §9).

All functions here operate on the runtime representation documented in
:mod:`polyquery.types`.
"""

from __future__ import annotations

import datetime
import math
import re

from . import errors
from .names import fold

INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1

MICROS_PER_SECOND = 1_000_000
MICROS_PER_DAY = 86_400 * MICROS_PER_SECOND
_EPOCH_ORDINAL = datetime.date(1970, 1, 1).toordinal()
MIN_DATE = datetime.date(1, 1, 1).toordinal() - _EPOCH_ORDINAL
MAX_DATE = datetime.date(9999, 12, 31).toordinal() - _EPOCH_ORDINAL

POW10 = [10**i for i in range(40)]
MAX_DECIMAL_DIGITS = 18

INT_RE = re.compile(r"[+-]?[0-9]+")
FLOAT_RE = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
DECIMAL_RE = re.compile(r"([+-]?)([0-9]+(?:\.[0-9]*)?|\.[0-9]+)")
DATE_RE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})")
TIMESTAMP_RE = re.compile(
    r"([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?"
)
BOOL_TEXT = {"true": True, "false": False}


# ---------------------------------------------------------------- integers


def check_int64(v: int) -> int:
    if v < INT64_MIN or v > INT64_MAX:
        raise errors.numeric_overflow("INT64 overflow")
    return v


def int_from_digits(text: str) -> int:
    """Converts ``[+-]?[0-9]+`` text to an int. Values with more than 19
    significant digits (certainly outside INT64) map to INT64_MAX + 1 or
    INT64_MIN - 1, which avoids unbounded conversions of huge inputs."""
    if len(text.lstrip("+-").lstrip("0")) > 19:
        return INT64_MIN - 1 if text.startswith("-") else INT64_MAX + 1
    return int(text)


def parse_int64(text: str) -> int | None:
    """Parses ``[+-]?[0-9]+``; returns None on syntax error. May be out of range."""
    if INT_RE.fullmatch(text) is None:
        return None
    return int_from_digits(text)


# ---------------------------------------------------------------- floats


def check_float(v: float) -> float:
    if math.isinf(v) or math.isnan(v):
        raise errors.numeric_overflow("non-finite FLOAT64 result")
    return v


def parse_float(text: str) -> float | None:
    """Parses the FLOAT64 syntax of ingestion.md §1.1; None on syntax error.

    The result may be infinite when the literal overflows; callers check.
    """
    if FLOAT_RE.fullmatch(text) is None:
        return None
    return float(text)


def format_float(v: float) -> str:
    if v == 0.0:
        return "0.0"
    return repr(v)


# ---------------------------------------------------------------- decimals


def decimal_fits(unscaled: int, precision: int) -> bool:
    return -POW10[precision] < unscaled < POW10[precision]


def check_decimal(unscaled: int, precision: int = 18) -> int:
    if not decimal_fits(unscaled, precision):
        raise errors.numeric_overflow(f"value does not fit DECIMAL precision {precision}")
    return unscaled


def round_div(n: int, d: int) -> int:
    """n / d rounded half away from zero (d > 0)."""
    q, r = divmod(abs(n), d)
    if 2 * r >= d:
        q += 1
    return q if n >= 0 else -q


def rescale(unscaled: int, from_scale: int, to_scale: int) -> int:
    """Changes the scale of an unscaled decimal, rounding half away from zero."""
    if to_scale >= from_scale:
        return unscaled * POW10[to_scale - from_scale]
    return round_div(unscaled, POW10[from_scale - to_scale])


def decimal_to_float(unscaled: int, scale: int) -> float:
    return unscaled / POW10[scale] if scale else float(unscaled)


def float_to_decimal(v: float, scale: int) -> int:
    """Exact float -> unscaled decimal at ``scale``, rounding half away from zero."""
    n, d = v.as_integer_ratio()
    return round_div(n * POW10[scale], d)


def format_decimal(unscaled: int, scale: int) -> str:
    sign = "-" if unscaled < 0 else ""
    digits = str(abs(unscaled))
    if scale == 0:
        return sign + digits
    if len(digits) <= scale:
        digits = "0" * (scale - len(digits) + 1) + digits
    return f"{sign}{digits[:-scale]}.{digits[-scale:]}"


def parse_decimal_text(text: str, scale: int, *, exact: bool) -> int | None:
    """Parses decimal text into an unscaled integer at ``scale``.

    Returns None on syntax error. With ``exact`` the text may not have more
    fractional digits than ``scale`` (ingestion); otherwise the value is rounded
    half away from zero (CAST).
    """
    m = DECIMAL_RE.fullmatch(text)
    if m is None:
        return None
    sign, body = m.groups()
    int_part, _, frac = body.partition(".")
    int_part = int_part.lstrip("0")
    if len(frac) > scale:
        if exact:
            raise errors.conversion_error(
                f"'{text}' has more than {scale} fractional digits"
            )
        # rounding half away from zero only depends on the first dropped digit
        frac = frac[: scale + 1]
    if len(int_part) > MAX_DECIMAL_DIGITS:
        # does not fit any DECIMAL precision; avoid converting huge digit strings
        unscaled = POW10[MAX_DECIMAL_DIGITS + scale]
    elif len(frac) > scale:
        unscaled = round_div(int((int_part or "0") + frac), POW10[len(frac) - scale])
    else:
        unscaled = int((int_part or "0") + frac) * POW10[scale - len(frac)]
    return -unscaled if sign == "-" else unscaled


def decimal_literal_type(text: str) -> tuple[int, int, int] | None:
    """For a SQL numeric literal without exponent containing '.', returns
    ``(unscaled, precision, scale)`` or None if the precision exceeds 18."""
    int_part, _, frac = text.partition(".")
    scale = len(frac)
    significant = int_part.lstrip("0")
    precision = max(len(significant) + scale, scale, 1)
    if precision > 18:
        return None
    return int((int_part or "0") + frac or "0"), precision, scale


# ---------------------------------------------------------------- dates


def _date_days(y: int, m: int, d: int) -> int | None:
    try:
        return datetime.date(y, m, d).toordinal() - _EPOCH_ORDINAL
    except ValueError:
        return None


_DATE_CACHE: dict[str, int | None] = {}
_DATE_CACHE_LIMIT = 1 << 16
_MISSING = object()


def parse_date(text: str) -> int | None:
    """Parses ``YYYY-MM-DD``; None if syntactically or calendrically invalid."""
    days = _DATE_CACHE.get(text, _MISSING)
    if days is not _MISSING:
        return days  # type: ignore[return-value]
    m = DATE_RE.fullmatch(text)
    days = None if m is None else _date_days(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    if len(_DATE_CACHE) >= _DATE_CACHE_LIMIT:
        _DATE_CACHE.clear()
    _DATE_CACHE[text] = days
    return days


def parse_timestamp(text: str, *, allow_date: bool = True) -> int | None:
    """Parses ``YYYY-MM-DD[ T]HH:MM:SS[.f{1,6}]`` (or a bare date if allowed)."""
    m = TIMESTAMP_RE.fullmatch(text)
    if m is None:
        if allow_date:
            days = parse_date(text)
            return None if days is None else days * MICROS_PER_DAY
        return None
    days = parse_date(text[:10])
    if days is None:
        return None
    _, _, _, hh, mm, ss, frac = m.groups()
    h, mi, se = int(hh), int(mm), int(ss)
    if h > 23 or mi > 59 or se > 59:
        return None
    micros = int(frac.ljust(6, "0")) if frac else 0
    return days * MICROS_PER_DAY + ((h * 60 + mi) * 60 + se) * MICROS_PER_SECOND + micros


def is_date_text(text: str) -> bool:
    return parse_date(text) is not None


def format_date(days: int) -> str:
    return datetime.date.fromordinal(days + _EPOCH_ORDINAL).isoformat()


def format_timestamp(micros: int) -> str:
    days, rem = divmod(micros, MICROS_PER_DAY)
    secs, frac = divmod(rem, MICROS_PER_SECOND)
    hh, rest = divmod(secs, 3600)
    mm, ss = divmod(rest, 60)
    text = f"{format_date(days)} {hh:02d}:{mm:02d}:{ss:02d}"
    if frac:
        text += f".{frac:06d}"
    return text


def timestamp_to_date(micros: int) -> int:
    return micros // MICROS_PER_DAY


def date_to_timestamp(days: int) -> int:
    return days * MICROS_PER_DAY


# ---------------------------------------------------------------- booleans


def parse_bool(text: str) -> bool | None:
    return BOOL_TEXT.get(fold(text))
