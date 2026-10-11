"""Compiles bound expressions into Python closures ``fn(row) -> value``.

Rows are tuples; NULL is ``None``. A *layout* maps column keys to row slots;
column keys that are not in the layout are correlation parameters, read from
the execution context. Every closure implements SQL NULL propagation and the
runtime error rules of types.md §4.
"""

from __future__ import annotations

import itertools
import operator
import re
from typing import Any, Callable

from .. import errors, values
from ..analysis import bound as b
from ..datatypes import TypeKind
from .casts import cast_function, identity
from .context import ExecutionContext
from .functions import compile_function

RowFn = Callable[[tuple], Any]

INT64_MIN = values.INT64_MIN
INT64_MAX = values.INT64_MAX
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


def _decimal_kernel(op: str, s1: int, s2: int, precision: int) -> Callable[[int, int], Any]:
    """Exact DECIMAL arithmetic on unscaled values (Python ints are
    unbounded, so narrow and wide operands share the kernels; only the
    result ``precision`` (18 or 38) of the overflow check differs)."""
    limit = values.POW10[precision]
    if op in ("+", "-"):
        scale = max(s1, s2)
        f1, f2 = values.POW10[scale - s1], values.POW10[scale - s2]
        sign = 1 if op == "+" else -1

        def addsub(a: int, c: int) -> int:
            v = a * f1 + sign * c * f2
            if -limit < v < limit:
                return v
            raise _overflow()

        return addsub
    if op == "*":

        def mul(a: int, c: int) -> int:
            v = a * c
            if -limit < v < limit:
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


def arith_kernel(e: b.Arith) -> Callable[[Any, Any], Any]:
    """The kernel of an arithmetic operator for two non-NULL operands."""
    lt, rt = e.left.type, e.right.type
    if e.type.kind is TypeKind.FLOAT64 and TypeKind.DECIMAL not in (lt.kind, rt.kind):
        return _FLOAT_KERNELS[e.op]
    if TypeKind.DECIMAL in (lt.kind, rt.kind):
        s1 = lt.scale if lt.kind is TypeKind.DECIMAL else 0
        s2 = rt.scale if rt.kind is TypeKind.DECIMAL else 0
        return _decimal_kernel(e.op, s1, s2, e.type.precision)
    return _INT_KERNELS[e.op]


def compare_kernel(e: b.Compare) -> Callable[[Any, Any], Any]:
    """The kernel of a comparison for two non-NULL operands (DECIMALs of
    different scales, narrow or wide, are compared exactly by value)."""
    cmp = _COMPARE[e.op]
    lt, rt = e.left.type, e.right.type
    if lt.kind is TypeKind.DECIMAL and rt.kind is TypeKind.DECIMAL and lt.scale != rt.scale:
        scale = max(lt.scale, rt.scale)
        f1, f2 = values.POW10[scale - lt.scale], values.POW10[scale - rt.scale]
        return lambda a, c: cmp(a * f1, c * f2)
    return cmp


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


Layout = dict[b.ColumnKey, int]


def _not3(v: Any) -> Any:
    return None if v is None else not v


def like_regex(pattern: str) -> re.Pattern[str]:
    """Translates a LIKE pattern (``%``, ``_``; no escape character) to a regex."""
    parts = []
    for c in pattern:
        if c == "%":
            parts.append(".*")
        elif c == "_":
            parts.append(".")
        else:
            parts.append(re.escape(c))
    return re.compile("".join(parts), re.DOTALL)


class Compiler:
    def __init__(self, ctx: ExecutionContext, layout: Layout):
        self.ctx = ctx
        self.layout = layout

    def compile(self, expr: b.Expr) -> RowFn:
        return getattr(self, "_c_" + type(expr).__name__)(expr)

    def _c_Literal(self, e: b.Literal) -> RowFn:
        value = e.value
        return lambda row: value

    def _c_ColumnRef(self, e: b.ColumnRef) -> RowFn:
        slot = self.layout.get(e.key)
        if slot is not None:
            return operator.itemgetter(slot)
        params, key = self.ctx.params, e.key
        return lambda row: params[key]

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
        return _binary(self.compile(e.left), self.compile(e.right), arith_kernel(e))

    def _c_Compare(self, e: b.Compare) -> RowFn:
        return _binary(self.compile(e.left), self.compile(e.right), compare_kernel(e))

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
        return lambda row: _not3(operand(row))

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
        if convert is identity:
            return operand

        def cast(row: tuple) -> Any:
            v = operand(row)
            return None if v is None else convert(v)

        return cast

    def _c_Like(self, e: b.Like) -> RowFn:
        operand = self.compile(e.operand)
        negated = e.negated
        if isinstance(e.pattern, b.Literal):
            if e.pattern.value is None:
                return lambda row: None
            match = like_regex(e.pattern.value).fullmatch

            def like_const(row: tuple) -> Any:
                v = operand(row)
                if v is None:
                    return None
                return (match(v) is None) if negated else (match(v) is not None)

            return like_const
        pattern = self.compile(e.pattern)
        cache: dict[str, re.Pattern[str]] = {}

        def like(row: tuple) -> Any:
            v = operand(row)
            if v is None:
                return None
            p = pattern(row)
            if p is None:
                return None
            regex = cache.get(p)
            if regex is None:
                if len(cache) > 1024:
                    cache.clear()
                regex = cache[p] = like_regex(p)
            return (regex.fullmatch(v) is None) if negated else (regex.fullmatch(v) is not None)

        return like

    def _c_Between(self, e: b.Between) -> RowFn:
        operand, low, high = (self.compile(x) for x in (e.operand, e.low, e.high))
        negated = e.negated

        def between(row: tuple) -> Any:
            v = operand(row)
            if v is None:
                return None
            lo, hi = low(row), high(row)
            ge = None if lo is None else v >= lo
            le = None if hi is None else v <= hi
            if ge is False or le is False:
                result: Any = False
            elif ge is None or le is None:
                result = None
            else:
                result = True
            return _not3(result) if negated else result

        return between

    def _c_InList(self, e: b.InList) -> RowFn:
        operand = self.compile(e.operand)
        negated = e.negated
        if all(b.is_constant(item) for item in e.items):
            consts = [self.compile(item)(()) for item in e.items]
            members = frozenset(v for v in consts if v is not None)
            has_null = any(v is None for v in consts)

            def in_const(row: tuple) -> Any:
                v = operand(row)
                if v is None:
                    return None
                if v in members:
                    result: Any = True
                else:
                    result = None if has_null else False
                return _not3(result) if negated else result

            return in_const
        items = [self.compile(item) for item in e.items]

        def in_list(row: tuple) -> Any:
            v = operand(row)
            if v is None:
                return None
            result: Any = False
            for item in items:
                w = item(row)
                if w is None:
                    result = None
                elif w == v:
                    result = True
                    break
            return _not3(result) if negated else result

        return in_list

    def _c_Case(self, e: b.Case) -> RowFn:
        whens = [(self.compile(c), self.compile(r)) for c, r in e.whens]
        else_ = self.compile(e.else_) if e.else_ is not None else (lambda row: None)

        def case(row: tuple) -> Any:
            for cond, result in whens:
                if cond(row) is True:
                    return result(row)
            return else_(row)

        return case

    def _c_Function(self, e: b.Function) -> RowFn:
        args = [self.compile(a) for a in e.args]
        return compile_function(e, args, self.ctx, evaluate_constant)

    def _c_AggCall(self, e: b.AggCall) -> RowFn:
        raise AssertionError("aggregate calls are evaluated by the aggregate operator")

    # ------------------------------------------------------------ subqueries

    def _subquery_rows(self, e: b.SubqueryExpr, limit: int | None) -> Callable[[tuple], list[tuple]]:
        """Returns ``fn(row)`` running the subquery (with its correlation
        parameters taken from ``row``) and returning up to ``limit`` rows.
        Results are cached per distinct parameter values."""
        from .executor import subplan_rows  # local import: the executors depend on this module

        ctx = self.ctx
        plan = ctx.subplans[e.subquery.id]
        keys = e.subquery.outer_keys
        arg_fns = [self.compile(a) for a in e.args]
        params = ctx.params
        cache: dict[tuple, list[tuple]] = {}

        def run(row: tuple) -> list[tuple]:
            args = tuple(f(row) for f in arg_fns)
            rows = cache.get(args)
            if rows is None:
                for key, value in zip(keys, args):
                    params[key] = value
                rows = list(itertools.islice(subplan_rows(plan, ctx), limit))
                cache[args] = rows
            return rows

        return run

    def _c_ScalarSubquery(self, e: b.ScalarSubquery) -> RowFn:
        run = self._subquery_rows(e, 2)

        def scalar(row: tuple) -> Any:
            rows = run(row)
            if not rows:
                return None
            if len(rows) > 1:
                raise errors.PolyQueryError(
                    errors.SUBQUERY_CARDINALITY, "scalar subquery returned more than one row"
                )
            return rows[0][0]

        return scalar

    def _c_Exists(self, e: b.Exists) -> RowFn:
        from .semi_join import exists_semi_join  # local import: semi_join uses the vector compiler

        semi = exists_semi_join(e, self.ctx)
        if semi is not None:
            # the subquery has a row iff the lookup key is one of its keys
            outer_keys = e.subquery.outer_keys
            arg_fns = [self.compile(a) for a in e.args]
            params = self.ctx.params
            key = compile_expr(semi.key, self.ctx)

            def exists(row: tuple) -> bool:
                for k, f in zip(outer_keys, arg_fns):
                    params[k] = f(row)
                return key(()) in semi.keys()  # NULL is never a key

            return exists
        run = self._subquery_rows(e, 1)
        return lambda row: bool(run(row))

    def _c_InSubquery(self, e: b.InSubquery) -> RowFn:
        run = self._subquery_rows(e, None)
        operand = self.compile(e.operand)
        negated = e.negated
        column_type = e.subquery.query.outputs[0].expr.type
        target = e.operand.type
        convert = None
        if not column_type.is_null and not target.is_null and column_type != target:
            convert = cast_function(column_type, target)
        sets: dict[int, tuple[frozenset, bool, bool]] = {}

        def value_set(row: tuple) -> tuple[frozenset, bool, bool]:
            rows = run(row)
            found = sets.get(id(rows))
            if found is None:
                vals = [r[0] for r in rows]
                has_null = any(v is None for v in vals)
                non_null = [v for v in vals if v is not None]
                if convert is not None:
                    non_null = [convert(v) for v in non_null]
                found = (frozenset(non_null), has_null, bool(vals))
                sets[id(rows)] = found
            return found

        def in_subquery(row: tuple) -> Any:
            members, has_null, non_empty = value_set(row)
            v = operand(row)
            if not non_empty:
                result: Any = False
            elif v is None:
                result = None
            elif v in members:
                result = True
            else:
                result = None if has_null else False
            return _not3(result) if negated else result

        return in_subquery


def compile_expr(expr: b.Expr, ctx: ExecutionContext, layout: Layout | None = None) -> RowFn:
    return Compiler(ctx, layout or {}).compile(expr)


def compile_row(exprs: list[b.Expr], ctx: ExecutionContext, layout: Layout) -> Callable[[tuple], tuple]:
    """Compiles a list of expressions into one function producing a row tuple."""
    if all(isinstance(e, b.ColumnRef) and e.key in layout for e in exprs):
        slots = [layout[e.key] for e in exprs]  # type: ignore[attr-defined]
        if not slots:
            return lambda row: ()
        if len(slots) == 1:
            s = slots[0]
            return lambda row: (row[s],)
        return operator.itemgetter(*slots)
    fns = [compile_expr(e, ctx, layout) for e in exprs]
    namespace = {f"f{i}": fn for i, fn in enumerate(fns)}
    source = "lambda row: (" + "".join(f"f{i}(row)," for i in range(len(fns))) + ")"
    return eval(source, namespace)  # noqa: S307 - generated from trusted names only


def evaluate_constant(expr: b.Expr) -> Any:
    """Evaluates a constant expression (no columns, aggregates or subqueries)."""
    return compile_expr(expr, ExecutionContext())(())
