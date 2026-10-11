"""Compiles bound expressions into *vector* functions ``fn(columns, n) -> values``
for vectorized execution.

``columns`` are the value sequences of a batch (one per layout slot, NULL =
``None``) and ``n`` its row count; the result is a sequence of ``n`` values.
Results may share storage with the inputs and must not be mutated.

Kernels are written so that the per-row work happens inside C-implemented
builtins wherever possible (``map`` over ``operator`` functions,
``itertools.compress``, ``list.count`` / ``in``, ``min`` / ``max``): a batch
without NULLs takes a branch-free fast path (the CPython analogue of a
SIMD-friendly loop: one tight loop over homogeneous values, range checks
done once per batch with ``min``/``max``), batches with NULLs take a
NULL-aware comprehension. Semantics are exactly those of the row closures in
``compiler`` (same scalar kernels, same error checks); expression kinds
without a dedicated vector kernel (subqueries, non-constant LIKE patterns,
…) evaluate their row closure over just the columns they reference.

Operands that may raise an error are evaluated only for the rows whose
result depends on them, exactly like the short-circuiting row closures: the
right operand of AND / OR, CASE branches, and the right operand of
NULL-propagating operators (``b <> 0 AND a / b > 1`` never divides by
zero, ``NULL * <overflowing constant>`` is NULL).
"""

from __future__ import annotations

import operator
from functools import partial
from itertools import compress
from typing import Any, Callable, Sequence

from .. import errors, values
from ..analysis import bound as b
from ..datatypes import TypeKind
from .casts import cast_function, identity
from .compiler import (
    INT64_MAX,
    INT64_MIN,
    Layout,
    arith_kernel,
    compare_kernel,
    compile_expr,
    evaluate_constant,
    like_regex,
)
from .context import ExecutionContext
from .functions import compile_function

Columns = Sequence[Sequence[Any]]
VecFn = Callable[[Columns, int], Sequence[Any]]

_INF = float("inf")
_is_none = partial(operator.is_, None)
_is_not_none = partial(operator.is_not, None)
_is_true = partial(operator.is_, True)
_is_not_true = partial(operator.is_not, True)
_is_not_false = partial(operator.is_not, False)
_FAST_OPS = {"+": operator.add, "-": operator.sub, "*": operator.mul}
_COMPARE_OPS = {
    "=": operator.eq,
    "<>": operator.ne,
    "<": operator.lt,
    "<=": operator.le,
    ">": operator.gt,
    ">=": operator.ge,
}


def take(values: Sequence[Any], positions: Sequence[int]) -> Sequence[Any]:
    """Gathers ``values[i]`` for every ``i`` in ``positions`` (a list or a
    tuple). ``itemgetter`` gathers in one C loop without a call per value."""
    if len(positions) < 2:
        return [values[i] for i in positions]
    return operator.itemgetter(*positions)(values)


def true_positions(mask: Sequence[Any]) -> list[int]:
    """Positions where a boolean vector is TRUE (not FALSE / NULL)."""
    return list(compress(range(len(mask)), map(_is_true, mask)))


def _overflow() -> errors.PolyQueryError:
    return errors.numeric_overflow("numeric overflow")


def _check_int64(out: list[Any]) -> list[Any]:
    if out and (max(out) > INT64_MAX or min(out) < INT64_MIN):
        raise _overflow()
    return out


def _decimal_check(precision: int) -> Callable[[list[Any]], list[Any]]:
    """The batch overflow check of DECIMAL results of ``precision``."""
    limit = values.POW10[precision]

    def check(out: list[Any]) -> list[Any]:
        if out and (max(out) >= limit or min(out) <= -limit):
            raise _overflow()
        return out

    return check


def _check_float(out: list[Any]) -> list[Any]:
    # operands are finite, so +, -, * can only overflow to ±inf (never NaN)
    if out and (max(out) == _INF or min(out) == -_INF):
        raise _overflow()
    return out


def _and3(x: Any, y: Any) -> Any:
    if x is False or y is False:
        return False
    if x is None or y is None:
        return None
    return True


def _or3(x: Any, y: Any) -> Any:
    if x is True or y is True:
        return True
    if x is None or y is None:
        return None
    return False


def _not3(v: Any) -> Any:
    return None if v is None else not v


def _between3(v: Any, lo: Any, hi: Any) -> Any:
    if v is None:
        return None
    ge = None if lo is None else v >= lo
    le = None if hi is None else v <= hi
    if ge is False or le is False:
        return False
    if ge is None or le is None:
        return None
    return True


def _like_predicate(pattern: str) -> Callable[[str], bool]:
    """A matcher for a constant LIKE pattern; patterns that are a literal
    prefix / suffix / infix use ``str`` methods instead of a regex."""
    if "_" not in pattern:
        inner = pattern.strip("%")
        if "%" not in inner:
            starts, ends = pattern.startswith("%"), pattern.endswith("%")
            if starts and ends:
                return lambda v: inner in v
            if ends and inner:
                return lambda v: v.startswith(inner)
            if starts and inner:
                return lambda v: v.endswith(inner)
            if not starts and not ends:
                return partial(operator.eq, pattern)
    match = like_regex(pattern).fullmatch
    return lambda v: match(v) is not None


class VectorCompiler:
    def __init__(self, ctx: ExecutionContext, layout: Layout):
        self.ctx = ctx
        self.layout = layout

    def compile(self, expr: b.Expr) -> VecFn:
        if not isinstance(expr, b.Literal) and b.is_constant(expr) and not b.has_side_effects(expr):
            return self._constant(expr)
        method = getattr(self, "_v_" + type(expr).__name__, None)
        if method is None:
            return self._row_fallback(expr)
        return method(expr)

    # ------------------------------------------------------------ generic

    def _constant(self, expr: b.Expr) -> VecFn:
        """A constant subexpression, evaluated once per (non-empty) batch."""
        fn = compile_expr(expr, self.ctx)
        return lambda cols, n: [fn(())] * n if n else []

    def _row_fallback(self, expr: b.Expr) -> VecFn:
        """Evaluates the row closure of ``expr`` per row, over just the
        columns it references."""
        keys = sorted(k for k in b.column_keys(expr) if k in self.layout)
        slots = [self.layout[k] for k in keys]
        fn = compile_expr(expr, self.ctx, {k: i for i, k in enumerate(keys)})
        if not slots:
            return lambda cols, n: [fn(()) for _ in range(n)]
        if len(slots) == 1:
            (slot,) = slots
            return lambda cols, n: list(map(fn, zip(cols[slot])))
        return lambda cols, n: list(map(fn, zip(*[cols[s] for s in slots])))

    def _slots(self, expr: b.Expr) -> list[int]:
        return sorted({self.layout[k] for k in b.column_keys(expr) if k in self.layout})

    def _selective(self, expr: b.Expr) -> Callable[[Columns, list[int]], Sequence[Any]]:
        """``fn(columns, positions)``: ``expr`` evaluated only for the rows at
        ``positions`` (gathering just the columns it references)."""
        fn = self.compile(expr)
        slots = self._slots(expr)

        def run(cols: Columns, positions: list[int]) -> Sequence[Any]:
            sub: list[Sequence[Any]] = [()] * len(cols)
            for s in slots:
                sub[s] = take(cols[s], positions)
            return fn(sub, len(positions))

        return run

    def _operands(self, left_expr: b.Expr, right_expr: b.Expr) -> Callable[[Columns, int], tuple]:
        """The operand vectors of a NULL-propagating binary operator. Like the
        row closures, an operand on the right that may raise an error is only
        evaluated for the rows whose left operand is not NULL."""
        left = self.compile(left_expr)
        right_all = self.compile(right_expr)
        right_some = self._selective(right_expr) if b.may_fail(right_expr) else None

        def operands(cols: Columns, n: int) -> tuple:
            a = left(cols, n)
            if right_some is None or None not in a:
                return a, right_all(cols, n)
            positions = list(compress(range(n), map(_is_not_none, a)))
            c: list[Any] = [None] * n
            if positions:
                for i, v in zip(positions, right_some(cols, positions)):
                    c[i] = v
            return a, c

        return operands

    # ------------------------------------------------------------ leaves

    def _v_Literal(self, e: b.Literal) -> VecFn:
        value = e.value
        return lambda cols, n: [value] * n

    def _v_ColumnRef(self, e: b.ColumnRef) -> VecFn:
        slot = self.layout.get(e.key)
        if slot is not None:
            return lambda cols, n: cols[slot]
        params, key = self.ctx.params, e.key  # correlation parameter
        return lambda cols, n: [params[key]] * n

    # ------------------------------------------------------------ arithmetic

    def _v_Unary(self, e: b.Unary) -> VecFn:
        operand = self.compile(e.operand)
        if e.op == "pos":
            return operand
        is_int = e.operand.type.kind is TypeKind.INT64

        def neg(cols: Columns, n: int) -> Sequence[Any]:
            a = operand(cols, n)
            if is_int and INT64_MIN in a:
                raise _overflow()
            if None in a:
                return [None if v is None else -v for v in a]
            return list(map(operator.neg, a))

        return neg

    def _v_Arith(self, e: b.Arith) -> VecFn:
        operands = self._operands(e.left, e.right)
        kernel = arith_kernel(e)
        lt, rt = e.left.type.kind, e.right.type.kind
        fast: Callable[[Any, Any], Any] | None = None
        check: Callable[[list[Any]], list[Any]] | None = None
        if e.op in _FAST_OPS:
            if e.type.kind is TypeKind.INT64:
                fast, check = _FAST_OPS[e.op], _check_int64
            elif e.type.kind is TypeKind.FLOAT64 and TypeKind.DECIMAL not in (lt, rt):
                fast, check = _FAST_OPS[e.op], _check_float
            elif lt is TypeKind.DECIMAL and rt is TypeKind.DECIMAL and (
                e.op == "*" or e.left.type.scale == e.right.type.scale
            ):
                fast, check = _FAST_OPS[e.op], _decimal_check(e.type.precision)

        def arith(cols: Columns, n: int) -> Sequence[Any]:
            a, c = operands(cols, n)
            if None in a or None in c:
                return [None if x is None or y is None else kernel(x, y) for x, y in zip(a, c)]
            if fast is None:
                return list(map(kernel, a, c))
            return check(list(map(fast, a, c)))  # type: ignore[misc]

        return arith

    def _v_Concat(self, e: b.Concat) -> VecFn:
        operands = self._operands(e.left, e.right)

        def concat(cols: Columns, n: int) -> Sequence[Any]:
            a, c = operands(cols, n)
            if None in a or None in c:
                return [None if x is None or y is None else x + y for x, y in zip(a, c)]
            return list(map(operator.add, a, c))

        return concat

    def _v_Cast(self, e: b.Cast) -> VecFn:
        if e.operand.type.is_null:
            return lambda cols, n: [None] * n
        operand = self.compile(e.operand)
        convert = cast_function(e.operand.type, e.type)
        if convert is identity:
            return operand

        def cast(cols: Columns, n: int) -> Sequence[Any]:
            a = operand(cols, n)
            if None in a:
                return [None if v is None else convert(v) for v in a]
            return list(map(convert, a))

        return cast

    # ------------------------------------------------------------ predicates

    def _v_Compare(self, e: b.Compare) -> VecFn:
        operands = self._operands(e.left, e.right)
        cmp = compare_kernel(e)

        def compare(cols: Columns, n: int) -> Sequence[Any]:
            a, c = operands(cols, n)
            if None in a or None in c:
                return [None if x is None or y is None else cmp(x, y) for x, y in zip(a, c)]
            return list(map(cmp, a, c))

        return compare

    def _v_Logical(self, e: b.Logical) -> VecFn:
        left = self.compile(e.left)
        is_and = e.op == "AND"
        # the value of the left operand that decides the result alone
        decisive = False if is_and else True
        combine3 = _and3 if is_and else _or3
        fast = operator.and_ if is_and else operator.or_
        undecided = _is_not_false if is_and else _is_not_true
        right_all = self.compile(e.right)
        right_some = self._selective(e.right) if b.may_fail(e.right) else None

        def logical(cols: Columns, n: int) -> Sequence[Any]:
            a = left(cols, n)
            if right_some is not None and decisive in a:
                positions = list(compress(range(n), map(undecided, a)))
                out = [decisive] * n
                if positions:
                    for i, y in zip(positions, right_some(cols, positions)):
                        out[i] = combine3(a[i], y)
                return out
            c = right_all(cols, n)
            if None in a or None in c:
                return list(map(combine3, a, c))
            return list(map(fast, a, c))

        return logical

    def _v_Not(self, e: b.Not) -> VecFn:
        operand = self.compile(e.operand)

        def not_(cols: Columns, n: int) -> Sequence[Any]:
            a = operand(cols, n)
            if None in a:
                return list(map(_not3, a))
            return list(map(operator.not_, a))

        return not_

    def _v_IsNull(self, e: b.IsNull) -> VecFn:
        operand = self.compile(e.operand)
        test = _is_not_none if e.negated else _is_none
        return lambda cols, n: list(map(test, operand(cols, n)))

    def _v_Like(self, e: b.Like) -> VecFn:
        if not isinstance(e.pattern, b.Literal):
            return self._row_fallback(e)
        if e.pattern.value is None:
            return lambda cols, n: [None] * n
        operand = self.compile(e.operand)
        matches = _like_predicate(e.pattern.value)
        negated = e.negated

        def like(cols: Columns, n: int) -> Sequence[Any]:
            a = operand(cols, n)
            if None in a:
                out = [None if v is None else matches(v) for v in a]
                return [None if v is None else not v for v in out] if negated else out
            out = list(map(matches, a))
            return list(map(operator.not_, out)) if negated else out

        return like

    def _v_Between(self, e: b.Between) -> VecFn:
        if b.may_fail(e.low) or b.may_fail(e.high):
            return self._row_fallback(e)  # bounds are only evaluated for non-NULL operands
        operand, low, high = (self.compile(x) for x in (e.operand, e.low, e.high))
        negated = e.negated

        def between(cols: Columns, n: int) -> Sequence[Any]:
            v = operand(cols, n)
            lo = low(cols, n)
            hi = high(cols, n)
            if None in v or None in lo or None in hi:
                out = list(map(_between3, v, lo, hi))
                return list(map(_not3, out)) if negated else out
            out = list(map(operator.and_, map(operator.le, lo, v), map(operator.le, v, hi)))
            return list(map(operator.not_, out)) if negated else out

        return between

    def _v_InList(self, e: b.InList) -> VecFn:
        if not all(b.is_constant(item) for item in e.items):
            return self._row_fallback(e)
        operand = self.compile(e.operand)
        consts = [compile_expr(item, self.ctx)(()) for item in e.items]
        members = frozenset(v for v in consts if v is not None)
        has_null = any(v is None for v in consts)
        negated = e.negated
        contains = members.__contains__

        def in_list(cols: Columns, n: int) -> Sequence[Any]:
            a = operand(cols, n)
            if not has_null and None not in a:
                out = list(map(contains, a))
                return list(map(operator.not_, out)) if negated else out
            out = [None if v is None else (True if v in members else (None if has_null else False)) for v in a]
            return list(map(_not3, out)) if negated else out

        return in_list

    def _v_Case(self, e: b.Case) -> VecFn:
        whens = [(self.compile(cond), self._selective(result)) for cond, result in e.whens]
        else_ = self._selective(e.else_) if e.else_ is not None else None
        cond_slots = sorted({s for cond, _ in e.whens for s in self._slots(cond)})

        def case(cols: Columns, n: int) -> Sequence[Any]:
            out: list[Any] = [None] * n
            # rows not decided yet: positions into the batch, and the batch
            # restricted to them (conditions are evaluated only for those)
            remaining = list(range(n))
            current: Columns = cols
            for cond, result in whens:
                if not remaining:
                    return out
                mask = cond(current, len(remaining))
                hits = true_positions(mask)
                if not hits:
                    continue
                rows = hits if current is cols else take(remaining, hits)
                for i, v in zip(rows, result(cols, rows)):
                    out[i] = v
                if len(hits) == len(remaining):
                    return out
                keep = list(compress(range(len(remaining)), map(_is_not_true, mask)))
                remaining = take(remaining, keep)
                restricted: list[Sequence[Any]] = [()] * len(cols)
                for s in cond_slots:
                    restricted[s] = take(cols[s], remaining)
                current = restricted
            if else_ is not None and remaining:
                for i, v in zip(remaining, else_(cols, remaining)):
                    out[i] = v
            return out

        return case

    def _v_Function(self, e: b.Function) -> VecFn:
        """Arguments are evaluated as vectors; the scalar kernel is mapped over
        them. Function kernels evaluate their arguments lazily (strict
        functions stop at the first NULL, COALESCE at the first non-NULL), so
        a call with a later argument that may fail runs its row closure."""
        if any(b.may_fail(a) for a in e.args[1:]):
            return self._row_fallback(e)
        args = [self.compile(a) for a in e.args]
        getters = [operator.itemgetter(i) for i in range(len(args))]
        scalar = compile_function(e, getters, self.ctx, evaluate_constant)  # type: ignore[arg-type]
        if not args:
            return lambda cols, n: [scalar(()) for _ in range(n)]

        def function(cols: Columns, n: int) -> Sequence[Any]:
            return list(map(scalar, zip(*[arg(cols, n) for arg in args])))

        return function


def compile_vector(expr: b.Expr, ctx: ExecutionContext, layout: Layout) -> VecFn:
    return VectorCompiler(ctx, layout).compile(expr)
