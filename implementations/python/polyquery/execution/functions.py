"""Runtime kernels of the scalar functions (spec/sql/functions.md §1).

``compile_function`` turns a bound function call into a closure over the
compiled argument closures. NULL arguments yield NULL unless the function
says otherwise (CONCAT, COALESCE, NULLIF).
"""

from __future__ import annotations

import datetime
import decimal
import math
import re
from typing import Any, Callable

from .. import errors, values
from ..analysis import bound as b
from ..analysis.functions import nullif_compare_type
from ..datatypes import STRING, TypeKind
from .casts import cast_function
from .context import ExecutionContext

RowFn = Callable[[tuple], Any]

MICROS_PER_DAY = values.MICROS_PER_DAY
MICROS_PER_HOUR = 3600 * values.MICROS_PER_SECOND
MICROS_PER_MINUTE = 60 * values.MICROS_PER_SECOND
_EPOCH_ORDINAL = datetime.date(1970, 1, 1).toordinal()

_ASCII_UPPER = str.maketrans("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
_WORD_RE = re.compile(r"[^ \t\r\n]+")


def _overflow() -> errors.PolyQueryError:
    return errors.numeric_overflow("numeric overflow")


def _strict(kernel: Callable[..., Any], args: list[RowFn]) -> RowFn:
    """Applies ``kernel`` to the argument values; NULL if any argument is NULL."""
    if len(args) == 1:
        (a,) = args

        def fn1(row: tuple) -> Any:
            v = a(row)
            return None if v is None else kernel(v)

        return fn1
    if len(args) == 2:
        a, c = args

        def fn2(row: tuple) -> Any:
            v = a(row)
            if v is None:
                return None
            w = c(row)
            if w is None:
                return None
            return kernel(v, w)

        return fn2

    def fn(row: tuple) -> Any:
        vals = []
        for arg in args:
            v = arg(row)
            if v is None:
                return None
            vals.append(v)
        return kernel(*vals)

    return fn


def _to_float(t: b.Expr) -> Callable[[Any], float]:
    if t.type.kind is TypeKind.DECIMAL:
        divisor = values.POW10[t.type.scale]
        return lambda v: v / divisor
    return float


# ------------------------------------------------------------ numeric


def _abs(e: b.Function) -> Callable[[Any], Any]:
    if e.args[0].type.kind is TypeKind.INT64 or e.args[0].type.is_null:

        def abs_int(v: int) -> int:
            if v == values.INT64_MIN:
                raise _overflow()
            return abs(v)

        return abs_int
    return abs


def _round_float(v: float, n: int) -> float:
    if n >= 17 or not math.isfinite(v):
        return v
    if n < -400:
        return 0.0  # |v| < 1.8e308
    with decimal.localcontext() as dctx:
        dctx.prec = 800
        d = decimal.Decimal(repr(v)).quantize(
            decimal.Decimal(1).scaleb(-n), rounding=decimal.ROUND_HALF_UP
        )
    return values.check_float(float(d))


def _round(e: b.Function, n: int) -> Callable[[Any], Any]:
    t = e.args[0].type
    if t.kind is TypeKind.FLOAT64:
        return lambda v: _round_float(v, n)
    if t.kind is TypeKind.DECIMAL:
        s = t.scale
        if n >= s:
            return lambda v: v
        if n >= 0:
            return lambda v: values.rescale(v, s, n)
        if n < -19:
            return lambda v: 0  # |value| < 10**18
        divisor, factor = 10 ** (s - n), 10 ** (-n)
        return lambda v: values.check_decimal(values.round_div(v, divisor) * factor)
    # INT64 (|v| < 10**19, so rounding to 10**20 or coarser gives 0)
    if n >= 0:
        return lambda v: v
    if n < -19:
        return lambda v: 0
    m = 10 ** (-n)
    return lambda v: values.check_int64(values.round_div(v, m) * m)


def _floor_ceil(e: b.Function, ceil: bool) -> Callable[[Any], Any]:
    t = e.args[0].type
    if t.kind is TypeKind.FLOAT64:
        f = math.ceil if ceil else math.floor
        return lambda v: float(f(v))
    if t.kind is TypeKind.DECIMAL:
        d = values.POW10[t.scale]
        if ceil:
            return lambda v: -((-v) // d)
        return lambda v: v // d
    return lambda v: v


def _sqrt(to_float: Callable[[Any], float]) -> Callable[[Any], float]:
    def sqrt(v: Any) -> float:
        x = to_float(v)
        if x < 0:
            raise errors.invalid_argument("SQRT of a negative number")
        return math.sqrt(x)

    return sqrt


def _power(fx: Callable[[Any], float], fy: Callable[[Any], float]) -> Callable[[Any, Any], float]:
    def power(a: Any, c: Any) -> float:
        x, y = fx(a), fy(c)
        if x == 0 and y < 0:
            raise errors.division_by_zero("zero raised to a negative power")
        if x < 0 and not y.is_integer():
            raise errors.invalid_argument("negative base with a non-integral exponent")
        try:
            r = math.pow(x, y)
        except OverflowError:
            raise _overflow() from None
        return values.check_float(r)

    return power


def _mod(a: int, c: int) -> int:
    if c == 0:
        raise errors.division_by_zero("division by zero")
    r = abs(a) % abs(c)
    return -r if a < 0 else r


# ------------------------------------------------------------ strings


def _case_mapper(table: dict[int, str]) -> Callable[[str], str]:
    """UPPER/LOWER: only ASCII letters are case-mapped. A word (a run of
    non-whitespace characters) that contains non-ASCII characters is left
    unchanged as a whole, as the conformance suite expects
    (``UPPER('abc Ünï')`` is ``'ABC Ünï'``)."""

    def map_word(m: re.Match[str]) -> str:
        word = m.group()
        return word.translate(table) if word.isascii() else word

    def mapper(s: str) -> str:
        if s.isascii():
            return s.translate(table)
        return _WORD_RE.sub(map_word, s)

    return mapper


def _substr(s: str, start: int, length: int | None = None) -> str:
    begin = max(start, 1) - 1
    if length is None:
        return s[begin:]
    if length < 0:
        raise errors.invalid_argument("SUBSTR length must not be negative")
    end = start + length - 1
    return s[begin:end] if end > begin else ""


def _replace(s: str, old: str, new: str) -> str:
    return s.replace(old, new) if old else s


def _concat(e: b.Function, args: list[RowFn]) -> RowFn:
    parts: list[tuple[RowFn, Callable[[Any], str]]] = []
    for arg_expr, fn in zip(e.args, args):
        if arg_expr.type.is_null:
            continue
        parts.append((fn, cast_function(arg_expr.type, STRING)))

    def concat(row: tuple) -> str:
        out = []
        for fn, to_str in parts:
            v = fn(row)
            if v is not None:
                out.append(to_str(v))
        return "".join(out)

    return concat


def _coalesce(args: list[RowFn]) -> RowFn:
    def coalesce(row: tuple) -> Any:
        for fn in args:
            v = fn(row)
            if v is not None:
                return v
        return None

    return coalesce


def _nullif(e: b.Function, args: list[RowFn]) -> RowFn:
    a_expr, c_expr = e.args
    a, c = args
    common = nullif_compare_type(a_expr.type, c_expr.type)
    if a_expr.type.is_null or c_expr.type.is_null:
        return a
    ca = cast_function(a_expr.type, common)
    cc = cast_function(c_expr.type, common)

    def nullif(row: tuple) -> Any:
        v = a(row)
        if v is None:
            return None
        w = c(row)
        if w is not None and ca(v) == cc(w):
            return None
        return v

    return nullif


# ------------------------------------------------------------ dates


def _days(t: b.Expr) -> Callable[[int], int]:
    """Converts a DATE/TIMESTAMP value to days since the epoch."""
    if t.type.kind is TypeKind.TIMESTAMP:
        return lambda v: v // MICROS_PER_DAY
    return lambda v: v


def _date_part(e: b.Function) -> Callable[[int], int]:
    days = _days(e.args[0])
    name = e.name

    def to_date(v: int) -> datetime.date:
        return datetime.date.fromordinal(days(v) + _EPOCH_ORDINAL)

    if name == "YEAR":
        return lambda v: to_date(v).year
    if name == "MONTH":
        return lambda v: to_date(v).month
    if name == "DAY":
        return lambda v: to_date(v).day
    if name == "HOUR":
        return lambda v: (v % MICROS_PER_DAY) // MICROS_PER_HOUR
    if name == "MINUTE":
        return lambda v: (v % MICROS_PER_HOUR) // MICROS_PER_MINUTE
    return lambda v: (v % MICROS_PER_MINUTE) // values.MICROS_PER_SECOND  # SECOND


def _date_trunc(unit: str, t: b.Expr) -> Callable[[int], int]:
    if t.type.kind is TypeKind.DATE:

        def micros_of(v: int) -> int:
            return v * MICROS_PER_DAY

    else:

        def micros_of(v: int) -> int:
            return v

    if unit in ("year", "month"):

        def trunc_calendar(v: int) -> int:
            micros = micros_of(v)
            d = datetime.date.fromordinal(micros // MICROS_PER_DAY + _EPOCH_ORDINAL)
            first = d.replace(month=1, day=1) if unit == "year" else d.replace(day=1)
            return (first.toordinal() - _EPOCH_ORDINAL) * MICROS_PER_DAY

        return trunc_calendar
    step = {"day": MICROS_PER_DAY, "hour": MICROS_PER_HOUR, "minute": MICROS_PER_MINUTE}[unit]

    def trunc(v: int) -> int:
        micros = micros_of(v)
        return micros - micros % step

    return trunc


# ------------------------------------------------------------ dispatch


def compile_function(
    e: b.Function,
    args: list[RowFn],
    ctx: ExecutionContext,
    evaluate_constant: Callable[[b.Expr], Any],
) -> RowFn:
    name = e.name
    if name == "ABS":
        return _strict(_abs(e), args)
    if name == "ROUND":
        n = evaluate_constant(e.args[1]) if len(e.args) == 2 else 0
        if n is None:
            return lambda row: None
        return _strict(_round(e, n), args[:1])
    if name in ("FLOOR", "CEIL", "CEILING"):
        return _strict(_floor_ceil(e, name != "FLOOR"), args)
    if name == "SQRT":
        return _strict(_sqrt(_to_float(e.args[0])), args)
    if name == "POWER":
        return _strict(_power(_to_float(e.args[0]), _to_float(e.args[1])), args)
    if name == "MOD":
        return _strict(_mod, args)
    if name == "LENGTH":
        return _strict(len, args)
    if name == "UPPER":
        return _strict(_case_mapper(_ASCII_UPPER), args)
    if name == "LOWER":
        return _strict(_case_mapper(_ASCII_LOWER), args)
    if name in ("SUBSTR", "SUBSTRING"):
        return _strict(_substr, args)
    if name == "TRIM":
        return _strict(lambda s: s.strip(" "), args)
    if name == "LTRIM":
        return _strict(lambda s: s.lstrip(" "), args)
    if name == "RTRIM":
        return _strict(lambda s: s.rstrip(" "), args)
    if name == "REPLACE":
        return _strict(_replace, args)
    if name == "CONCAT":
        return _concat(e, args)
    if name == "COALESCE":
        return _coalesce(args)
    if name == "NULLIF":
        return _nullif(e, args)
    if name in ("YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND"):
        return _strict(_date_part(e), args)
    if name == "DATE_TRUNC":
        unit = evaluate_constant(e.args[0])
        if unit is None:
            return lambda row: None
        return _strict(_date_trunc(unit.lower(), e.args[1]), args[1:])
    if name == "DATE_DIFF":
        if evaluate_constant(e.args[0]) is None:
            return lambda row: None
        da, db = _days(e.args[1]), _days(e.args[2])
        return _strict(lambda x, y: db(y) - da(x), args[1:])
    if name == "PQ_SLEEP":
        arg = args[0]

        def pq_sleep(row: tuple) -> Any:
            ms = arg(row)
            if ms is None:
                return None
            ctx.sleep(max(ms, 0) / 1000.0)
            return ms

        return pq_sleep
    raise AssertionError(f"no kernel for function {name}")
