"""Compiles bound expressions into Python closures ``fn(row) -> value``.

Rows are tuples; NULL is ``None``. Every closure implements SQL NULL
propagation and the runtime error rules of types.md §4.
"""

from __future__ import annotations

import operator
from typing import Any, Callable

from .. import errors, values
from ..analysis import bound as b
from ..datatypes import TypeKind
from .casts import cast_function
from .context import ExecutionContext

RowFn = Callable[[tuple], Any]

INT64_MIN = values.INT64_MIN
INT64_MAX = values.INT64_MAX
DEC_LIMIT = values.POW10[18]
_INF = float("inf")


def _overflow() -> errors.PolyQueryError:
    return errors.numeric_overflow("numeric overflow")


def _div_zero() -> errors.PolyQueryError:
    return errors.division_by_zero("division by zero")


# ------------------------------------------------------------ scalar kernels
# Kernels take two non-NULL operands.


def _int_add(a: int, c: int) -> int:
    v = a + c
    if INT64_MIN <= v <= INT64_MAX:
        return v
    raise _overflow()


def _int_sub(a: int, c: int) -> int:
    v = a - c
    if INT64_MIN <= v <= INT64_MAX:
        return v
    raise _overflow()


def _int_mul(a: int, c: int) -> int:
    v = a * c
    if INT64_MIN <= v <= INT64_MAX:
        return v
    raise _overflow()


def _int_div(a: int, c: int) -> int:
    if c == 0:
        raise _div_zero()
    q = abs(a) // abs(c)
    if (a < 0) != (c < 0):
        q = -q
    if q > INT64_MAX:
        raise _overflow()
    return q


def _int_mod(a: int, c: int) -> int:
    if c == 0:
        raise _div_zero()
    r = abs(a) % abs(c)
    return -r if a < 0 else r


def _float_check(v: float) -> float:
    if v == _INF or v == -_INF or v != v:
        raise _overflow()
    return v


def _float_add(a: float, c: float) -> float:
    return _float_check(a + c)


def _float_sub(a: float, c: float) -> float:
    return _float_check(a - c)


def _float_mul(a: float, c: float) -> float:
    return _float_check(a * c)


def _float_div(a: float, c: float) -> float:
    if c == 0.0:
        raise _div_zero()
    return _float_check(a / c)


def _decimal_kernel(op: str, s1: int, s2: int) -> Callable[[int, int], Any]:
    if op in ("+", "-"):
        scale = max(s1, s2)
        f1, f2 = values.POW10[scale - s1], values.POW10[scale - s2]
        sign = 1 if op == "+" else -1

        def addsub(a: int, c: int) -> int:
            v = a * f1 + sign * c * f2
            if -DEC_LIMIT < v < DEC_LIMIT:
                return v
            raise _overflow()

        return addsub
    if op == "*":

        def mul(a: int, c: int) -> int:
            v = a * c
            if -DEC_LIMIT < v < DEC_LIMIT:
                return v
            raise _overflow()

        return mul
    # '/': exact quotient rounded once to FLOAT64
    m1, m2 = values.POW10[s2], values.POW10[s1]

    def div(a: int, c: int) -> float:
        if c == 0:
            raise _div_zero()
        return _float_check((a * m1) / (c * m2))

    return div


_INT_KERNELS = {"+": _int_add, "-": _int_sub, "*": _int_mul, "/": _int_div, "%": _int_mod}
_FLOAT_KERNELS = {"+": _float_add, "-": _float_sub, "*": _float_mul, "/": _float_div}
_COMPARE = {
    "=": operator.eq,
    "<>": operator.ne,
    "<": operator.lt,
    "<=": operator.le,
    ">": operator.gt,
    ">=": operator.ge,
}


def _binary(left: RowFn, right: RowFn, kernel: Callable[[Any, Any], Any]) -> RowFn:
    def fn(row: tuple) -> Any:
        a = left(row)
        if a is None:
            return None
        c = right(row)
        if c is None:
            return None
        return kernel(a, c)

    return fn


class Compiler:
    def __init__(self, ctx: ExecutionContext):
        self.ctx = ctx

    def compile(self, expr: b.Expr) -> RowFn:
        return getattr(self, "_c_" + type(expr).__name__)(expr)

    def _c_Literal(self, e: b.Literal) -> RowFn:
        value = e.value
        return lambda row: value

    def _c_ColumnSlot(self, e: b.ColumnSlot) -> RowFn:
        return operator.itemgetter(e.slot)

    def _c_AggRef(self, e: b.AggRef) -> RowFn:
        return operator.itemgetter(e.index)

    def _c_Unary(self, e: b.Unary) -> RowFn:
        operand = self.compile(e.operand)
        if e.op == "pos":
            return operand
        if e.operand.type.kind is TypeKind.INT64:

            def neg_int(row: tuple) -> Any:
                v = operand(row)
                if v is None:
                    return None
                if v == INT64_MIN:
                    raise _overflow()
                return -v

            return neg_int

        def neg(row: tuple) -> Any:
            v = operand(row)
            return None if v is None else -v

        return neg

    def _c_Arith(self, e: b.Arith) -> RowFn:
        left, right = self.compile(e.left), self.compile(e.right)
        lt, rt = e.left.type, e.right.type
        if e.type.kind is TypeKind.FLOAT64 and TypeKind.DECIMAL not in (lt.kind, rt.kind):
            kernel = _FLOAT_KERNELS[e.op]
        elif TypeKind.DECIMAL in (lt.kind, rt.kind):
            s1 = lt.scale if lt.kind is TypeKind.DECIMAL else 0
            s2 = rt.scale if rt.kind is TypeKind.DECIMAL else 0
            kernel = _decimal_kernel(e.op, s1, s2)
        else:
            kernel = _INT_KERNELS[e.op]
        return _binary(left, right, kernel)

    def _c_Compare(self, e: b.Compare) -> RowFn:
        left, right = self.compile(e.left), self.compile(e.right)
        cmp = _COMPARE[e.op]
        lt, rt = e.left.type, e.right.type
        if lt.kind is TypeKind.DECIMAL and rt.kind is TypeKind.DECIMAL and lt.scale != rt.scale:
            scale = max(lt.scale, rt.scale)
            f1, f2 = values.POW10[scale - lt.scale], values.POW10[scale - rt.scale]
            return _binary(left, right, lambda a, c: cmp(a * f1, c * f2))
        return _binary(left, right, cmp)

    def _c_Logical(self, e: b.Logical) -> RowFn:
        left, right = self.compile(e.left), self.compile(e.right)
        if e.op == "AND":

            def and_(row: tuple) -> Any:
                a = left(row)
                if a is False:
                    return False
                c = right(row)
                if c is False:
                    return False
                if a is None or c is None:
                    return None
                return True

            return and_

        def or_(row: tuple) -> Any:
            a = left(row)
            if a is True:
                return True
            c = right(row)
            if c is True:
                return True
            if a is None or c is None:
                return None
            return False

        return or_

    def _c_Not(self, e: b.Not) -> RowFn:
        operand = self.compile(e.operand)

        def not_(row: tuple) -> Any:
            v = operand(row)
            return None if v is None else not v

        return not_

    def _c_IsNull(self, e: b.IsNull) -> RowFn:
        operand = self.compile(e.operand)
        if e.negated:
            return lambda row: operand(row) is not None
        return lambda row: operand(row) is None

    def _c_Concat(self, e: b.Concat) -> RowFn:
        return _binary(self.compile(e.left), self.compile(e.right), operator.add)

    def _c_Cast(self, e: b.Cast) -> RowFn:
        operand = self.compile(e.operand)
        if e.operand.type.is_null:
            return lambda row: None
        convert = cast_function(e.operand.type, e.type)

        def cast(row: tuple) -> Any:
            v = operand(row)
            return None if v is None else convert(v)

        return cast

    def _c_Function(self, e: b.Function) -> RowFn:
        args = [self.compile(a) for a in e.args]
        if e.name == "PQ_SLEEP":
            ctx = self.ctx
            arg = args[0]

            def pq_sleep(row: tuple) -> Any:
                ms = arg(row)
                if ms is None:
                    return None
                ctx.sleep(max(ms, 0) / 1000.0)
                return ms

            return pq_sleep
        raise errors.unsupported(f"function {e.name} is not supported")

    def _c_AggCall(self, e: b.AggCall) -> RowFn:
        raise AssertionError("aggregate calls are evaluated by the Aggregate operator")


def compile_expr(expr: b.Expr, ctx: ExecutionContext) -> RowFn:
    return Compiler(ctx).compile(expr)


def compile_row(exprs: list[b.Expr], ctx: ExecutionContext) -> Callable[[tuple], tuple]:
    """Compiles a list of expressions into one function producing a row tuple."""
    if all(isinstance(e, b.ColumnSlot) for e in exprs):
        slots = [e.slot for e in exprs]  # type: ignore[attr-defined]
        if not slots:
            return lambda row: ()
        if len(slots) == 1:
            s = slots[0]
            return lambda row: (row[s],)
        return operator.itemgetter(*slots)
    fns = [compile_expr(e, ctx) for e in exprs]
    namespace = {f"f{i}": fn for i, fn in enumerate(fns)}
    source = "lambda row: (" + "".join(f"f{i}(row)," for i in range(len(fns))) + ")"
    return eval(source, namespace)  # noqa: S307 - generated from trusted names only
