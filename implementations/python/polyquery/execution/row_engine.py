"""Row-at-a-time (Volcano / iterator model) execution: ``mode: "row"``.

Every operator is an iterator of row tuples pulling single rows from its
inputs; expressions are the compiled row closures of ``compiler``. This is
the unoptimized baseline of the Phase 5 measurements. Scans check for
cancellation / timeout every ``_CHECK_ROWS`` rows, blocking operators
(joins, aggregation, sort) at least every ``CHECK_INTERVAL_ROWS`` rows of
work.
"""

from __future__ import annotations

import itertools
from typing import Any, Callable, Iterable, Iterator

from ..planner import physical as pp
from ..planner.access import group_may_match
from . import native_ops, parallel
from .aggregates import accumulator_factory
from .common import (
    CHECK_INTERVAL_ROWS,
    JoinCounter,
    aligned_keys,
    evaluate_count,
    lookup_rows,
    merge_pairs,
    scan_range,
    sort_rows,
    top_count,
)
from .compiler import Layout, compile_expr, compile_row
from .context import ExecutionContext

Rows = Iterator[tuple]

_CHECK_ROWS = 4096


def execute(node: pp.PhysicalNode, ctx: ExecutionContext) -> Rows:
    return _HANDLERS[type(node)](node, ctx)


def layout_of(node: pp.PhysicalNode) -> Layout:
    return {key: i for i, key in enumerate(node.layout)}


def _checked(rows: Iterable[tuple], ctx: ExecutionContext) -> Rows:
    """Passes rows through, checking for cancellation every few thousand rows."""
    it = iter(rows)
    while True:
        ctx.check()
        chunk = list(itertools.islice(it, _CHECK_ROWS))
        if not chunk:
            return
        yield from chunk


# ------------------------------------------------------------ scans


def _table_scan(node: pp.TableScan, ctx: ExecutionContext) -> Rows:
    skip = node.skip
    keep = (lambda group: group_may_match(group, skip)) if skip else None
    start, stop = scan_range(node, ctx, node.table.row_count)
    return _checked(node.table.scan(node.columns, keep, start, stop), ctx)


def _index_scan(node: pp.IndexScan, ctx: ExecutionContext) -> Rows:
    row_ids = ctx.cached(node, "row_ids", lambda: node.lookup.row_ids(node.index))
    start, stop = scan_range(node, ctx, len(row_ids))
    row_ids = row_ids[start:stop]
    ctx.check()
    for i in range(0, len(row_ids), _CHECK_ROWS):
        yield from node.table.fetch(row_ids[i : i + _CHECK_ROWS], node.columns)
        ctx.check()


def _lookup_scan(node: pp.LookupScan, ctx: ExecutionContext) -> Rows:
    return iter(lookup_rows(node, ctx))


def _values(node: pp.Values, ctx: ExecutionContext) -> Rows:
    yield ()


def _subquery_scan(node: pp.SubqueryScan, ctx: ExecutionContext) -> Rows:
    return execute(node.input, ctx)


def _union_all(node: pp.UnionAll, ctx: ExecutionContext) -> Rows:
    for branch in node.branches:
        yield from execute(branch, ctx)


def _filter(node: pp.Filter, ctx: ExecutionContext) -> Rows:
    native = native_ops.native_filter(node)
    if native is not None:
        # the kernels select rows of the scan below; the engine evaluates the rest
        residual = native.residual
        rows = itertools.chain.from_iterable(
            zip(*cols) if cols else itertools.repeat((), n)
            for cols, n in native_ops.filtered_batches(native, ctx, _CHECK_ROWS)
        )
        if residual is None:
            yield from rows
            return
        predicate = ctx.cached(node, "row:native_residual", lambda: compile_expr(residual, ctx, layout_of(node.input)))
    else:
        predicate = ctx.cached(node, "row:predicate", lambda: compile_expr(node.predicate, ctx, layout_of(node.input)))
        rows = execute(node.input, ctx)
    for row in rows:
        if predicate(row) is True:
            yield row


def _project(node: pp.Project, ctx: ExecutionContext) -> Rows:
    make_row = ctx.cached(node, "row:row", lambda: compile_row(node.exprs, ctx, layout_of(node.input)))
    for row in execute(node.input, ctx):
        yield make_row(row)


def _gather(node: pp.Gather, ctx: ExecutionContext) -> Rows:
    """Partition outputs concatenated in partition order."""
    prepare_pipeline(node, ctx)
    return parallel.iterate_partitions(node, ctx, lambda: execute(node.input, ctx))


def partition_rows(node: pp.PhysicalNode, ctx: ExecutionContext, consume: Callable[[Rows], Any]) -> list[Any]:
    """``consume`` applied to the input rows of a consumer of partial
    results: once per partition if ``node`` is a Gather, else once."""
    if isinstance(node, pp.Gather):
        prepare_pipeline(node, ctx)
        return parallel.run_partitions(node, ctx, lambda: consume(execute(node.input, ctx)))
    return [consume(execute(node, ctx))]


def prepare_pipeline(gather: pp.Gather, ctx: ExecutionContext) -> None:
    """Builds the shared (non-partitioned) join inputs of a parallel pipeline
    before its partitions run, so that every partition (and every forked
    worker) reuses them."""
    path = pp.pipeline_path(gather.input) or []
    for node in path:
        if isinstance(node, pp.HashJoin):
            ctx.prepare(node, "row:hash_table", lambda: _build_hash_table(node, ctx))
        elif isinstance(node, pp.NestedLoopJoin):
            ctx.prepare(node.right, "row:materialized", lambda: _materialize(node.right, ctx))
        elif isinstance(node, pp.MergeJoin):
            ctx.prepare(node, "row:merge_right", lambda: _build_merge_right(node, ctx))


# ------------------------------------------------------------ joins


def _materialize(node: pp.PhysicalNode, ctx: ExecutionContext) -> list[tuple]:
    rows: list[tuple] = []
    width = len(node.layout)
    for row in execute(node, ctx):
        rows.append(row)
        if len(rows) % _CHECK_ROWS == 0:
            ctx.reserve_rows(_CHECK_ROWS, width)
    ctx.reserve_rows(len(rows) % _CHECK_ROWS, width)
    return rows


def _materialized(node: pp.PhysicalNode, ctx: ExecutionContext) -> list[tuple]:
    return ctx.shared(node, "row:materialized", lambda: _materialize(node, ctx))


def _compile_hash_join(node: pp.HashJoin | pp.MergeJoin, ctx: ExecutionContext) -> tuple:
    left_keys, right_keys = aligned_keys(node.left_keys, node.right_keys)
    left_key = compile_row(left_keys, ctx, layout_of(node.left))
    right_key = compile_row(right_keys, ctx, layout_of(node.right))
    residual = compile_expr(node.residual, ctx, layout_of(node)) if node.residual is not None else None
    return left_key, right_key, residual


def _build_hash_table(node: pp.HashJoin, ctx: ExecutionContext) -> dict[tuple, list[tuple]]:
    """The hash table over the build input (NULL keys never match)."""
    left_key, right_key, _ = ctx.cached(node, "row:join", lambda: _compile_hash_join(node, ctx))
    side, key_fn = (node.right, right_key) if node.build == "right" else (node.left, left_key)
    table: dict[tuple, list[tuple]] = {}
    width = len(side.layout)
    for n, row in enumerate(execute(side, ctx), 1):
        key = key_fn(row)
        if n % _CHECK_ROWS == 0:
            ctx.reserve_rows(_CHECK_ROWS, width)
        if None in key:
            continue
        bucket = table.get(key)
        if bucket is None:
            table[key] = [row]
        else:
            bucket.append(row)
    return table


def _hash_table(node: pp.HashJoin, ctx: ExecutionContext) -> dict[tuple, list[tuple]]:
    return ctx.shared(node, "row:hash_table", lambda: _build_hash_table(node, ctx))


def _hash_join(node: pp.HashJoin, ctx: ExecutionContext) -> Rows:
    left_key, right_key, residual = ctx.cached(node, "row:join", lambda: _compile_hash_join(node, ctx))
    table = _hash_table(node, ctx)
    counter = JoinCounter(ctx)
    if node.build == "left":  # INNER join probing with the right input
        for rrow in execute(node.right, ctx):
            key = right_key(rrow)
            matches = None if None in key else table.get(key)
            if not matches:
                continue
            for lrow in matches:
                row = lrow + rrow
                if residual is None or residual(row) is True:
                    counter.add(1)
                    yield row
        return
    is_left = node.join_type == "LEFT"
    padding = (None,) * len(node.right.layout)
    for lrow in execute(node.left, ctx):
        key = left_key(lrow)
        matches = None if None in key else table.get(key)
        matched = False
        if matches:
            for rrow in matches:
                row = lrow + rrow
                if residual is None or residual(row) is True:
                    matched = True
                    counter.add(1)
                    yield row
        if is_left and not matched:
            counter.add(1)
            yield lrow + padding


def _nested_loop_join(node: pp.NestedLoopJoin, ctx: ExecutionContext) -> Rows:
    right_rows = _materialized(node.right, ctx)
    condition = ctx.cached(
        node,
        "row:condition",
        lambda: None if node.condition is None else compile_expr(node.condition, ctx, layout_of(node)),
    )
    is_left = node.join_type == "LEFT"
    padding = (None,) * len(node.right.layout)
    counter = JoinCounter(ctx)
    work = 0
    for lrow in execute(node.left, ctx):
        work += len(right_rows)
        if work >= CHECK_INTERVAL_ROWS:
            ctx.check()
            work = 0
        matched = False
        for rrow in right_rows:
            row = lrow + rrow
            if condition is None or condition(row) is True:
                matched = True
                counter.add(1)
                yield row
        if is_left and not matched:
            counter.add(1)
            yield lrow + padding


def _build_merge_right(node: pp.MergeJoin, ctx: ExecutionContext) -> tuple[list[tuple], list[Any]]:
    """The materialized right input of a merge join and its keys."""
    _, right_key, _ = ctx.cached(node, "row:join", lambda: _compile_hash_join(node, ctx))
    rows = _materialize(node.right, ctx)
    return rows, [right_key(row) for row in rows]


def _merge_right(node: pp.MergeJoin, ctx: ExecutionContext) -> tuple[list[tuple], list[Any]]:
    return ctx.shared(node, "row:merge_right", lambda: _build_merge_right(node, ctx))


def _merge_join(node: pp.MergeJoin, ctx: ExecutionContext) -> Rows:
    """Sort-merge join; the output follows the key order, followed (LEFT
    join) by the unmatched left rows in input order."""
    left_key, _, residual = ctx.cached(node, "row:join", lambda: _compile_hash_join(node, ctx))
    right_rows, right_keys = _merge_right(node, ctx)
    left_rows = list(execute(node.left, ctx))
    ctx.reserve_rows(len(left_rows), len(node.left.layout))
    left_keys = [left_key(row) for row in left_rows]
    ctx.check()
    li, ri = merge_pairs(left_keys, right_keys)
    ctx.check()
    counter = JoinCounter(ctx)
    matched = [False] * len(left_rows) if node.join_type == "LEFT" else None
    work = 0
    for i, j in zip(li, ri):
        row = left_rows[i] + right_rows[j]
        work += 1
        if work >= CHECK_INTERVAL_ROWS:
            ctx.check()
            work = 0
        if residual is None or residual(row) is True:
            if matched is not None:
                matched[i] = True
            counter.add(1)
            yield row
    if matched is not None:
        padding = (None,) * len(node.right.layout)
        for i, lrow in enumerate(left_rows):
            if not matched[i]:
                counter.add(1)
                yield lrow + padding


# ------------------------------------------------------------ aggregation


def _aggregate_partition(node: pp.HashAggregate, ctx: ExecutionContext, rows: Rows) -> dict[tuple, list]:
    """Partial aggregation: group key -> accumulators, in first-seen order."""
    layout = layout_of(node.input)
    key_fn, getters = ctx.cached(
        node,
        "row:agg",
        lambda: (
            compile_row(node.keys, ctx, layout),
            [None if call.arg is None else compile_expr(call.arg, ctx, layout) for call in node.aggregates],
        ),
    )
    make = accumulator_factory(node.aggregates)
    groups: dict[tuple, list] = {}
    pairs = list(enumerate(getters))
    work = 0
    for row in rows:
        key = key_fn(row)
        accs = groups.get(key)
        if accs is None:
            accs = groups[key] = make()
            ctx.reserve_rows(1, len(node.layout))
        for i, getter in pairs:
            accs[i].add(None if getter is None else getter(row))
        work += 1
        if work >= CHECK_INTERVAL_ROWS:
            ctx.check()
            work = 0
    return groups


def merge_groups(partials: list[dict[tuple, list]]) -> dict[tuple, list]:
    """Merges partial aggregation states in partition order (so groups keep
    the order of their first appearance in a serial scan)."""
    merged = partials[0]
    for part in partials[1:]:
        for key, accs in part.items():
            mine = merged.get(key)
            if mine is None:
                merged[key] = accs
            else:
                for a, other in zip(mine, accs):
                    a.merge(other)
    return merged


def _hash_aggregate(node: pp.HashAggregate, ctx: ExecutionContext) -> Rows:
    native = native_ops.native_scan_aggregate(node)
    done = None if native is None else native_ops.run_scan_aggregate(native, node, ctx)
    if done is not None:  # aggregated by the kernels from the column storage
        keys, states = done
        results = [state.results() for state in states]
        width = len(node.keys)
        for i, key in enumerate(keys):
            prefix = () if width == 0 else (key,) if width == 1 else key
            yield prefix + tuple(r[i] for r in results)
        return
    partials = partition_rows(node.input, ctx, lambda rows: _aggregate_partition(node, ctx, rows))
    groups = merge_groups(partials)
    if not node.keys and not groups:
        groups[()] = accumulator_factory(node.aggregates)()  # one group even for empty input
    for key, accs in groups.items():
        yield key + tuple(acc.result() for acc in accs)


# ------------------------------------------------------------ distinct / sort / limit


def _distinct_partition(rows: Rows, ctx: ExecutionContext, width: int) -> list[tuple]:
    seen: set[tuple] = set()
    out: list[tuple] = []
    for row in rows:
        if row not in seen:
            seen.add(row)
            out.append(row)
    ctx.reserve_rows(len(out), width)
    return out


def _distinct(node: pp.Distinct, ctx: ExecutionContext) -> Rows:
    width = len(node.layout)
    if isinstance(node.input, pp.Gather):
        parts = partition_rows(node.input, ctx, lambda rows: _distinct_partition(rows, ctx, width))
        yield from _distinct_partition(itertools.chain.from_iterable(parts), ctx, width)
        return
    seen: set[tuple] = set()
    for row in execute(node.input, ctx):
        if row not in seen:
            seen.add(row)
            ctx.reserve_rows(1, width)
            yield row


def _sorted_partition(rows: Rows, node: pp.Sort | pp.TopN, ctx: ExecutionContext, keep: int) -> list[tuple]:
    """Top-N of one partition: a buffer of at most ~2N rows, trimmed to the
    best N whenever it is full."""
    width = len(node.layout)
    buffer: list[tuple] = []
    limit = max(2 * keep, 1024)
    for row in rows:
        buffer.append(row)
        if len(buffer) >= limit:
            sort_rows(buffer, node.keys)
            del buffer[keep:]
            ctx.check()
    sort_rows(buffer, node.keys)
    del buffer[keep:]
    ctx.reserve_rows(len(buffer), width)
    return buffer


def _sort(node: pp.Sort | pp.TopN, ctx: ExecutionContext) -> Rows:
    keep = top_count(node, ctx) if isinstance(node, pp.TopN) else None
    if keep == 0:
        return iter(())
    if keep is None:  # full sort: partitions only collect, the rows are sorted once
        rows = list(itertools.chain.from_iterable(partition_rows(node.input, ctx, list)))
        ctx.reserve_rows(len(rows), len(node.layout))
        ctx.check()
        sort_rows(rows, node.keys)
        return iter(rows)
    parts = partition_rows(node.input, ctx, lambda rows: _sorted_partition(rows, node, ctx, keep))
    if len(parts) == 1:
        return iter(parts[0])
    # partial top-Ns in partition order: the stable re-sort merges them
    rows = list(itertools.chain.from_iterable(parts))
    sort_rows(rows, node.keys)
    return iter(rows[:keep])


def _limit(node: pp.Limit, ctx: ExecutionContext) -> Rows:
    limit = evaluate_count(node.limit, ctx, "LIMIT")
    offset = evaluate_count(node.offset, ctx, "OFFSET") or 0
    if limit == 0:
        return iter(())
    stop = None if limit is None else offset + limit
    return itertools.islice(execute(node.input, ctx), offset, stop)


_HANDLERS: dict[type, Callable[[Any, ExecutionContext], Rows]] = {
    pp.TableScan: _table_scan,
    pp.IndexScan: _index_scan,
    pp.Values: _values,
    pp.LookupScan: _lookup_scan,
    pp.SubqueryScan: _subquery_scan,
    pp.UnionAll: _union_all,
    pp.Filter: _filter,
    pp.Project: _project,
    pp.Gather: _gather,
    pp.HashJoin: _hash_join,
    pp.MergeJoin: _merge_join,
    pp.NestedLoopJoin: _nested_loop_join,
    pp.HashAggregate: _hash_aggregate,
    pp.Distinct: _distinct,
    pp.Sort: _sort,
    pp.TopN: _sort,
    pp.Limit: _limit,
}
