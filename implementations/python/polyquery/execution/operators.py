"""Execution of physical plan nodes.

Every operator is a generator of *batches* (lists of row tuples). Batching
amortizes per-row interpreter overhead and is the unit at which timeouts,
cancellation and memory accounting are checked. Expressions are compiled
against the layout (column key -> slot) of the operator's input rows.
"""

from __future__ import annotations

import itertools
import operator
from typing import Any, Callable, Iterator

from .. import errors
from ..analysis import bound as b
from ..datatypes import MAX_DECIMAL_PRECISION, DataType, TypeKind
from ..planner import physical as pp
from ..planner.access import group_may_match
from .aggregates import CountStar, make_accumulator
from .compiler import Layout, compile_expr, compile_row
from .context import ExecutionContext

BATCH_SIZE = 2048
# operators whose work is not proportional to their batches check for
# cancellation / timeout after at most this many rows (concurrency.md §4)
CHECK_INTERVAL_ROWS = 65_536

Batch = list[tuple]


def execute(node: pp.PhysicalNode, ctx: ExecutionContext) -> Iterator[Batch]:
    handler: Callable[[Any, ExecutionContext], Iterator[Batch]] = _HANDLERS[type(node)]
    return handler(node, ctx)


def layout_of(node: pp.PhysicalNode) -> Layout:
    return {key: i for i, key in enumerate(node.layout)}


def _batches(rows: Iterator[tuple], ctx: ExecutionContext) -> Iterator[Batch]:
    while True:
        ctx.check()
        batch = list(itertools.islice(rows, BATCH_SIZE))
        if not batch:
            return
        yield batch


def _table_scan(node: pp.TableScan, ctx: ExecutionContext) -> Iterator[Batch]:
    skip = node.skip
    keep = (lambda group: group_may_match(group, skip)) if skip else None
    return _batches(node.table.scan(node.columns, keep), ctx)


def _index_scan(node: pp.IndexScan, ctx: ExecutionContext) -> Iterator[Batch]:
    row_ids = node.lookup.row_ids(node.index)
    ctx.check()
    for i in range(0, len(row_ids), BATCH_SIZE):
        yield node.table.fetch(row_ids[i : i + BATCH_SIZE], node.columns)
        ctx.check()


def _lookup_table(node: pp.LookupScan, ctx: ExecutionContext) -> dict[Any, list[tuple]]:
    cache_key = (id(node.table), node.key_column, tuple(node.columns))
    table = ctx.lookup_tables.get(cache_key)
    if table is None:
        table = {}
        position = node.columns.index(node.key_column)
        for row in node.table.scan(node.columns):
            key = row[position]
            if key is None:
                continue
            bucket = table.get(key)
            if bucket is None:
                table[key] = [row]
            else:
                bucket.append(row)
        ctx.reserve_rows(node.table.row_count, len(node.columns))
        ctx.lookup_tables[cache_key] = table
    return table


def _lookup_scan(node: pp.LookupScan, ctx: ExecutionContext) -> Iterator[Batch]:
    table = _lookup_table(node, ctx)
    key, residual = ctx.cached(node, "lookup", lambda: _compile_lookup(node, ctx))
    value = key(())
    rows = table.get(value, ()) if value is not None else ()
    if residual is not None:
        rows = [row for row in rows if residual(row) is True]
    for i in range(0, len(rows), BATCH_SIZE):
        yield list(rows[i : i + BATCH_SIZE])
    ctx.check()


def _compile_lookup(node: pp.LookupScan, ctx: ExecutionContext) -> tuple:
    key = compile_expr(node.key, ctx)
    residual = (
        compile_expr(node.residual, ctx, layout_of(node)) if node.residual is not None else None
    )
    return key, residual


def _values(node: pp.Values, ctx: ExecutionContext) -> Iterator[Batch]:
    yield [()]


def _subquery_scan(node: pp.SubqueryScan, ctx: ExecutionContext) -> Iterator[Batch]:
    return execute(node.input, ctx)


def _filter(node: pp.Filter, ctx: ExecutionContext) -> Iterator[Batch]:
    predicate = ctx.cached(
        node, "predicate", lambda: compile_expr(node.predicate, ctx, layout_of(node.input))
    )
    for batch in execute(node.input, ctx):
        out = [row for row in batch if predicate(row) is True]
        if out:
            yield out
        ctx.check()


def _project(node: pp.Project, ctx: ExecutionContext) -> Iterator[Batch]:
    make_row = ctx.cached(node, "row", lambda: compile_row(node.exprs, ctx, layout_of(node.input)))
    for batch in execute(node.input, ctx):
        yield list(map(make_row, batch))
        ctx.check()


# ------------------------------------------------------------ joins


class _JoinCounter:
    """Enforces --max-join-rows on the rows produced by one join."""

    def __init__(self, ctx: ExecutionContext):
        self.ctx = ctx
        self.rows = 0

    def add(self, n: int) -> None:
        self.rows += n
        if self.rows > self.ctx.max_join_rows:
            raise errors.resource_limit(
                f"join produced more than {self.ctx.max_join_rows} rows (--max-join-rows)"
            )


def _materialize(node: pp.PhysicalNode, ctx: ExecutionContext) -> list[tuple]:
    rows: list[tuple] = []
    width = len(node.layout)
    for batch in execute(node, ctx):
        ctx.reserve_rows(len(batch), width)
        rows.extend(batch)
    return rows


def _decimal_scale(t: DataType) -> int | None:
    return t.scale if t.kind is TypeKind.DECIMAL else None


def _aligned_keys(left: list[b.Expr], right: list[b.Expr]) -> tuple[list[b.Expr], list[b.Expr]]:
    """Makes equal key values hash equally: DECIMAL keys of different scales are
    rescaled to the larger scale (other promotions were added by the binder)."""
    out_left, out_right = [], []
    for lk, rk in zip(left, right):
        ls, rs = _decimal_scale(lk.type), _decimal_scale(rk.type)
        if ls is not None and rs is not None and ls != rs:
            target = DataType(TypeKind.DECIMAL, MAX_DECIMAL_PRECISION, max(ls, rs))
            lk = lk if ls == target.scale else b.Cast(target, lk, implicit=True)
            rk = rk if rs == target.scale else b.Cast(target, rk, implicit=True)
        out_left.append(lk)
        out_right.append(rk)
    return out_left, out_right


def _compile_hash_join(node: pp.HashJoin, ctx: ExecutionContext) -> tuple:
    left_keys, right_keys = _aligned_keys(node.left_keys, node.right_keys)
    left_key = compile_row(left_keys, ctx, layout_of(node.left))
    right_key = compile_row(right_keys, ctx, layout_of(node.right))
    residual = (
        compile_expr(node.residual, ctx, layout_of(node)) if node.residual is not None else None
    )
    return left_key, right_key, residual


def _hash_join(node: pp.HashJoin, ctx: ExecutionContext) -> Iterator[Batch]:
    left_key, right_key, residual = ctx.cached(node, "join", lambda: _compile_hash_join(node, ctx))
    if node.build == "left":
        return _hash_join_build_left(node, ctx, left_key, right_key, residual)
    return _hash_join_build_right(node, ctx, left_key, right_key, residual)


def _build_hash_table(
    node: pp.PhysicalNode, key_fn: Callable[[tuple], tuple], ctx: ExecutionContext
) -> dict[tuple, list[tuple]]:
    table: dict[tuple, list[tuple]] = {}
    width = len(node.layout)
    for batch in execute(node, ctx):
        ctx.reserve_rows(len(batch), width)
        for row in batch:
            key = key_fn(row)
            if None in key:
                continue  # NULL keys never match
            bucket = table.get(key)
            if bucket is None:
                table[key] = [row]
            else:
                bucket.append(row)
        ctx.check()
    return table


def _hash_join_build_right(
    node: pp.HashJoin, ctx: ExecutionContext, left_key: Any, right_key: Any, residual: Any
) -> Iterator[Batch]:
    table = _build_hash_table(node.right, right_key, ctx)
    is_left = node.join_type == "LEFT"
    padding = (None,) * len(node.right.layout)
    counter = _JoinCounter(ctx)
    for batch in execute(node.left, ctx):
        out: Batch = []
        for lrow in batch:
            key = left_key(lrow)
            matches = None if None in key else table.get(key)
            if matches:
                if residual is None:
                    out.extend([lrow + r for r in matches])
                    continue
                matched = False
                for r in matches:
                    row = lrow + r
                    if residual(row) is True:
                        out.append(row)
                        matched = True
                if matched:
                    continue
            if is_left:
                out.append(lrow + padding)
        if out:
            counter.add(len(out))
            yield out
        ctx.check()


def _hash_join_build_left(
    node: pp.HashJoin, ctx: ExecutionContext, left_key: Any, right_key: Any, residual: Any
) -> Iterator[Batch]:
    """Inner join with the hash table on the left input (the smaller one)."""
    assert node.join_type == "INNER"
    table = _build_hash_table(node.left, left_key, ctx)
    counter = _JoinCounter(ctx)
    for batch in execute(node.right, ctx):
        out: Batch = []
        for rrow in batch:
            key = right_key(rrow)
            matches = None if None in key else table.get(key)
            if not matches:
                continue
            if residual is None:
                out.extend([lrow + rrow for lrow in matches])
            else:
                for lrow in matches:
                    row = lrow + rrow
                    if residual(row) is True:
                        out.append(row)
        if out:
            counter.add(len(out))
            yield out
        ctx.check()


def _nested_loop_join(node: pp.NestedLoopJoin, ctx: ExecutionContext) -> Iterator[Batch]:
    right_rows = _materialize(node.right, ctx)
    condition = ctx.cached(
        node,
        "condition",
        lambda: None if node.condition is None else compile_expr(node.condition, ctx, layout_of(node)),
    )
    is_left = node.join_type == "LEFT"
    padding = (None,) * len(node.right.layout)
    counter = _JoinCounter(ctx)
    work = 0  # row pairs examined since the last cancellation check
    for batch in execute(node.left, ctx):
        out: Batch = []
        for lrow in batch:
            work += len(right_rows)
            if work >= CHECK_INTERVAL_ROWS:
                ctx.check()
                work = 0
            if condition is None:
                if right_rows:
                    out.extend([lrow + r for r in right_rows])
                elif is_left:
                    out.append(lrow + padding)
            else:
                matched = False
                for r in right_rows:
                    row = lrow + r
                    if condition(row) is True:
                        out.append(row)
                        matched = True
                if is_left and not matched:
                    out.append(lrow + padding)
            if len(out) >= BATCH_SIZE:
                counter.add(len(out))
                yield out
                out = []
                ctx.check()
        if out:
            counter.add(len(out))
            yield out
        ctx.check()


# ------------------------------------------------------------ aggregation


def _argument_getters(node: pp.HashAggregate, ctx: ExecutionContext, layout: Layout) -> list:
    return [
        None if call.arg is None else compile_expr(call.arg, ctx, layout)
        for call in node.aggregates
    ]


def _accumulate(accumulators: list, getters: list, rows: list[tuple]) -> None:
    for acc, getter in zip(accumulators, getters):
        if getter is None:
            assert isinstance(acc, CountStar)
            acc.add_rows(len(rows))
        else:
            acc.add_batch(list(map(getter, rows)))


def _hash_aggregate(node: pp.HashAggregate, ctx: ExecutionContext) -> Iterator[Batch]:
    layout = layout_of(node.input)
    getters = ctx.cached(node, "args", lambda: _argument_getters(node, ctx, layout))
    if not node.keys:
        # one group over the whole input (also for empty input)
        accumulators = [make_accumulator(call) for call in node.aggregates]
        for batch in execute(node.input, ctx):
            _accumulate(accumulators, getters, batch)
            ctx.check()
        yield [tuple(acc.result() for acc in accumulators)]
        return

    key_fn = ctx.cached(node, "keys", lambda: compile_row(node.keys, ctx, layout))
    groups: dict[tuple, list[tuple]] = {}
    width = len(node.input.layout)
    for batch in execute(node.input, ctx):
        ctx.reserve_rows(len(batch), width)
        get = groups.get
        for row, key in zip(batch, map(key_fn, batch)):
            rows = get(key)
            if rows is None:
                groups[key] = [row]
            else:
                rows.append(row)
        ctx.check()

    out: Batch = []
    work = 0  # rows aggregated since the last cancellation check
    for key, rows in groups.items():
        accumulators = [make_accumulator(call) for call in node.aggregates]
        _accumulate(accumulators, getters, rows)
        out.append(key + tuple(acc.result() for acc in accumulators))
        work += len(rows)
        if work >= CHECK_INTERVAL_ROWS:
            ctx.check()
            work = 0
        if len(out) >= BATCH_SIZE:
            yield out
            out = []
            ctx.check()
    if out:
        yield out


# ------------------------------------------------------------ distinct / sort / limit


def _distinct(node: pp.Distinct, ctx: ExecutionContext) -> Iterator[Batch]:
    seen: set[tuple] = set()
    for batch in execute(node.input, ctx):
        out = []
        for row in batch:
            if row not in seen:
                seen.add(row)
                out.append(row)
        if out:
            ctx.reserve_rows(len(out), len(out[0]))
            yield out
        ctx.check()


def _sort_rows(rows: list[tuple], keys: list[b.SortKey]) -> None:
    """Sorts in place: one stable pass per key, least significant key first."""
    for key in reversed(keys):
        pos = key.position
        has_null = any(row[pos] is None for row in rows)
        if not has_null:
            rows.sort(key=operator.itemgetter(pos), reverse=key.descending)
            continue
        # NULL placement: rank 0 sorts before non-NULLs (rank 1), rank 2 after;
        # ``reverse`` flips the ranks as well, hence the XOR.
        null_key = (0,) if key.nulls_first != key.descending else (2,)

        def sort_key(row: tuple, pos: int = pos, null_key: tuple = null_key) -> tuple:
            v = row[pos]
            return null_key if v is None else (1, v)

        rows.sort(key=sort_key, reverse=key.descending)


def _sort(node: pp.Sort, ctx: ExecutionContext) -> Iterator[Batch]:
    rows: list[tuple] = []
    for batch in execute(node.input, ctx):
        if batch:
            ctx.reserve_rows(len(batch), len(batch[0]))
        rows.extend(batch)
    ctx.check()
    _sort_rows(rows, node.keys)
    ctx.check()
    for i in range(0, len(rows), BATCH_SIZE):
        yield rows[i : i + BATCH_SIZE]


def evaluate_count(expr: b.Expr | None, ctx: ExecutionContext, clause: str) -> int | None:
    """Evaluates a constant LIMIT/OFFSET expression."""
    if expr is None:
        return None
    value = compile_expr(expr, ctx)(())
    if value is not None and value < 0:
        raise errors.invalid_argument(f"{clause} must not be negative")
    return value


def _limit(node: pp.Limit, ctx: ExecutionContext) -> Iterator[Batch]:
    limit = evaluate_count(node.limit, ctx, "LIMIT")
    offset = evaluate_count(node.offset, ctx, "OFFSET") or 0
    if limit == 0:
        return
    skipped = 0
    produced = 0
    for batch in execute(node.input, ctx):
        if skipped < offset:
            take = min(offset - skipped, len(batch))
            skipped += take
            batch = batch[take:]
        if not batch:
            continue
        if limit is not None and produced + len(batch) >= limit:
            yield batch[: limit - produced]
            return
        produced += len(batch)
        yield batch


_HANDLERS: dict[type, Callable[[Any, ExecutionContext], Iterator[Batch]]] = {
    pp.TableScan: _table_scan,
    pp.IndexScan: _index_scan,
    pp.Values: _values,
    pp.LookupScan: _lookup_scan,
    pp.SubqueryScan: _subquery_scan,
    pp.Filter: _filter,
    pp.Project: _project,
    pp.HashJoin: _hash_join,
    pp.NestedLoopJoin: _nested_loop_join,
    pp.HashAggregate: _hash_aggregate,
    pp.Distinct: _distinct,
    pp.Sort: _sort,
    pp.Limit: _limit,
}
