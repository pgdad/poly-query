"""Vectorized (column-at-a-time) execution: ``mode: "vectorized"`` (and ``auto``).

Operators exchange *batches* ``(columns, n)``: one value sequence per layout
slot (NULL = ``None``) holding ``n`` rows, at most ``VECTOR_BATCH_ROWS`` for
scans. Expressions are vector functions from ``vcompiler``. Row tuples
are only built at the very end (results) or where an algorithm needs them
(DISTINCT, multi-column keys).

* Filters evaluate the predicate vector and compact every column with
  ``itertools.compress``.
* Hash joins build ``key -> row position`` tables over the materialized
  (column-wise) build input. When the build keys are unique (the usual
  primary-key join) the table maps to a single position and probing a
  whole batch is ``map(table.get, keys)`` + ``compress``; output columns are
  gathered by position. Merge and nested-loop joins work on positions too.
* Aggregation assigns dense group ids per batch (``dict.fromkeys`` finds the
  batch's new keys, ``map(index.__getitem__)`` the ids). Batches with few
  groups are sorted by group id (a C-level sort of positions) and every
  group's slice is fed to its accumulators with one ``add_batch`` call;
  batches with many groups update per-aggregate accumulator lists row by row.
* Sorts compute a permutation with C-level keys (``column.__getitem__``),
  one stable pass per key, and gather the columns once.
"""

from __future__ import annotations

import array
import itertools
import operator
from collections import Counter
from functools import partial
from itertools import compress, repeat
from typing import Any, Callable, Iterable, Iterator, Sequence

from ..analysis import bound as b
from ..planner import physical as pp
from ..planner.access import group_may_match
from . import native_ops, parallel
from .common import (
    VECTOR_BATCH_ROWS,
    JoinCounter,
    aligned_keys,
    evaluate_count,
    lookup_rows,
    merge_pairs,
    scan_range,
    sort_permutation,
    top_count,
)
from .compiler import Layout
from .context import ExecutionContext
from .group_states import GroupState, make_state, merge_partials
from .vcompiler import VecFn, compile_vector, take
from .worker_pool import PartitionTask, register_engine

_is_not_none = partial(operator.is_not, None)
_is_none = partial(operator.is_, None)

Columns = list[Sequence[Any]]
Batch = tuple[Columns, int]
Batches = Iterator[Batch]


def execute(node: pp.PhysicalNode, ctx: ExecutionContext) -> Batches:
    return _HANDLERS[type(node)](node, ctx)


def rows(node: pp.PhysicalNode, ctx: ExecutionContext) -> Iterator[tuple]:
    """The output of ``node`` as row tuples."""
    for cols, n in execute(node, ctx):
        if cols:
            yield from zip(*cols)
        else:
            yield from repeat((), n)


def to_rows(batch: Batch) -> list[tuple]:
    cols, n = batch
    return list(zip(*cols)) if cols else [()] * n


def layout_of(node: pp.PhysicalNode) -> Layout:
    return {key: i for i, key in enumerate(node.layout)}


def _compiled(node: pp.PhysicalNode, tag: str, ctx: ExecutionContext, factory: Callable[[], Any]) -> Any:
    return ctx.cached(node, "vec:" + tag, factory)


def _vectors(exprs: list, ctx: ExecutionContext, layout: Layout) -> list[VecFn]:
    return [compile_vector(e, ctx, layout) for e in exprs]


def _transpose(rows_: list[tuple], width: int) -> Columns:
    if not rows_:
        return [[] for _ in range(width)]
    return [list(c) for c in zip(*rows_)] if width else []


def _rebatch(cols: Columns, n: int, size: int = VECTOR_BATCH_ROWS) -> Batches:
    """Splits column data into batches."""
    if n <= size:
        if n:
            yield cols, n
        return
    for lo in range(0, n, size):
        yield [c[lo : lo + size] for c in cols], min(size, n - lo)


class _Collector:
    """Concatenates batches into column lists."""

    __slots__ = ("cols", "n")

    def __init__(self, width: int):
        self.cols: list[list[Any]] = [[] for _ in range(width)]
        self.n = 0

    def add(self, batch: Batch) -> None:
        cols, n = batch
        for target, values in zip(self.cols, cols):
            target.extend(values)
        self.n += n


def _materialize(node: pp.PhysicalNode, ctx: ExecutionContext) -> tuple[list[list[Any]], int]:
    width = len(node.layout)
    out = _Collector(width)
    for batch in execute(node, ctx):
        ctx.reserve_rows(batch[1], width)
        out.add(batch)
        ctx.check()
    return out.cols, out.n


# ------------------------------------------------------------ scans


def _table_scan(node: pp.TableScan, ctx: ExecutionContext) -> Batches:
    skip = node.skip
    keep = (lambda group: group_may_match(group, skip)) if skip else None
    start, stop = scan_range(node, ctx, node.table.row_count)
    ctx.check()
    for batch in node.table.scan_columns(node.columns, VECTOR_BATCH_ROWS, keep, start, stop):
        yield batch
        ctx.check()


def _index_scan(node: pp.IndexScan, ctx: ExecutionContext) -> Batches:
    row_ids = ctx.cached(node, "row_ids", lambda: node.lookup.row_ids(node.index))
    start, stop = scan_range(node, ctx, len(row_ids))
    row_ids = row_ids[start:stop]
    width = len(node.columns)
    ctx.check()
    for i in range(0, len(row_ids), VECTOR_BATCH_ROWS):
        chunk = row_ids[i : i + VECTOR_BATCH_ROWS]
        yield _transpose(node.table.fetch(chunk, node.columns), width), len(chunk)
        ctx.check()


def _lookup_scan(node: pp.LookupScan, ctx: ExecutionContext) -> Batches:
    found = lookup_rows(node, ctx)
    if found:
        yield from _rebatch(_transpose(found, len(node.columns)), len(found))


def _values(node: pp.Values, ctx: ExecutionContext) -> Batches:
    yield [], 1


def _subquery_scan(node: pp.SubqueryScan, ctx: ExecutionContext) -> Batches:
    return execute(node.input, ctx)


def _union_all(node: pp.UnionAll, ctx: ExecutionContext) -> Batches:
    for branch in node.branches:
        yield from execute(branch, ctx)


def _filter(node: pp.Filter, ctx: ExecutionContext) -> Batches:
    native = native_ops.native_filter(node)
    if native is not None:
        # the kernels select rows of the scan below; the engine evaluates the rest
        batches = native_ops.filtered_batches(native, ctx, VECTOR_BATCH_ROWS)
        residual = native.residual
        if residual is None:
            return batches
        fn = _compiled(node, "native:residual", ctx, lambda: compile_vector(residual, ctx, layout_of(node.input)))
        return _apply_predicate(fn, batches)
    predicate = _compiled(node, "predicate", ctx, lambda: compile_vector(node.predicate, ctx, layout_of(node.input)))
    return _apply_predicate(predicate, execute(node.input, ctx))


def _apply_predicate(predicate: VecFn, batches: Batches) -> Batches:
    for cols, n in batches:
        mask = predicate(cols, n)
        kept = mask.count(True)
        if kept == n:
            yield cols, n
        elif kept:
            yield [list(compress(c, mask)) for c in cols], kept


def _project(node: pp.Project, ctx: ExecutionContext) -> Batches:
    fns = _compiled(node, "exprs", ctx, lambda: _vectors(node.exprs, ctx, layout_of(node.input)))
    for cols, n in execute(node.input, ctx):
        yield [f(cols, n) for f in fns], n


def _gather(node: pp.Gather, ctx: ExecutionContext) -> Batches:
    """Partition outputs concatenated in partition order."""
    return parallel.iterate_partitions(
        node,
        ctx,
        lambda: execute(node.input, ctx),
        spec=PartitionTask(ENGINE, "collect", None),
        prepare=lambda: prepare_pipeline(node, ctx),
    )


def partition_batches(
    node: pp.PhysicalNode, ctx: ExecutionContext, kind: str, consumer: pp.PhysicalNode, arg: Any = None
) -> list[Any]:
    """The ``kind`` consumer (see ``_CONSUMERS``) of operator ``consumer``
    applied to the input batches of a consumer of partial results: once per
    partition if ``node`` is a Gather, else once."""
    consume = _CONSUMERS[kind](consumer, ctx, arg)
    if isinstance(node, pp.Gather):
        return parallel.run_partitions(
            node,
            ctx,
            lambda: consume(execute(node.input, ctx)),
            spec=PartitionTask(ENGINE, kind, consumer, arg),
            prepare=lambda: prepare_pipeline(node, ctx),
        )
    return [consume(execute(node, ctx))]


def prepare_pipeline(gather: pp.Gather, ctx: ExecutionContext) -> None:
    """Builds the shared join inputs of a parallel pipeline once, before its
    partitions run (forked workers inherit them)."""
    for node in pp.pipeline_path(gather.input) or []:
        if isinstance(node, pp.HashJoin):
            ctx.prepare(node, "vec:build", lambda: _build_hash_side(node, ctx))
        elif isinstance(node, pp.NestedLoopJoin):
            ctx.prepare(node.right, "vec:materialized", lambda: _materialize(node.right, ctx))
        elif isinstance(node, pp.MergeJoin):
            ctx.prepare(node, "vec:merge_right", lambda: _build_merge_right(node, ctx))


# ------------------------------------------------------------ joins


def _key_vector(fns: list[VecFn], cols: Columns, n: int) -> Sequence[Any]:
    """Join / group keys of a batch: values for one key, tuples for several."""
    if len(fns) == 1:
        return fns[0](cols, n)
    return list(zip(*[f(cols, n) for f in fns]))


class _HashSide:
    """The build input of a hash join: its columns (with a trailing NULL
    padding slot at position ``n``, used for unmatched LEFT join rows) and
    the table key -> position (``unique``) or key -> positions."""

    __slots__ = ("cols", "n", "table", "unique")

    def __init__(self, cols: list[list[Any]], n: int, table: dict, unique: bool):
        self.cols = cols
        self.n = n
        self.table = table
        self.unique = unique


def _key_fns(node: pp.HashJoin | pp.MergeJoin, ctx: ExecutionContext) -> tuple[list[VecFn], list[VecFn]]:
    def build() -> tuple[list[VecFn], list[VecFn]]:
        left_keys, right_keys = aligned_keys(node.left_keys, node.right_keys)
        return _vectors(left_keys, ctx, layout_of(node.left)), _vectors(right_keys, ctx, layout_of(node.right))

    return _compiled(node, "keys", ctx, build)


def _residual(node: pp.HashJoin | pp.MergeJoin | pp.NestedLoopJoin, ctx: ExecutionContext) -> VecFn | None:
    expr = node.condition if isinstance(node, pp.NestedLoopJoin) else node.residual
    if expr is None:
        return None
    return _compiled(node, "residual", ctx, lambda: compile_vector(expr, ctx, layout_of(node)))


def _valid_keys(keys: Sequence[Any], multi: bool) -> list[bool] | None:
    """Per-row 'key has no NULL' flags, or None if no key has a NULL."""
    if multi:
        if not any(None in k for k in keys):
            return None
        return [None not in k for k in keys]
    if None not in keys:
        return None
    return list(map(_is_not_none, keys))


def _build_hash_side(node: pp.HashJoin, ctx: ExecutionContext) -> _HashSide:
    left_fns, right_fns = _key_fns(node, ctx)
    side, fns = (node.right, right_fns) if node.build == "right" else (node.left, left_fns)
    cols, n = _materialize(side, ctx)
    keys = _key_vector(fns, cols, n)
    valid = _valid_keys(keys, len(fns) > 1)
    positions: Iterable[int] = range(n) if valid is None else compress(range(n), valid)
    usable = keys if valid is None else list(compress(keys, valid))
    table: dict = dict(zip(usable, positions))
    unique = len(table) == len(usable)
    if not unique:
        table = {}
        for key, i in zip(usable, range(n) if valid is None else compress(range(n), valid)):
            bucket = table.get(key)
            if bucket is None:
                table[key] = [i]
            else:
                bucket.append(i)
    for c in cols:
        c.append(None)  # padding slot
    ctx.check()
    return _HashSide(cols, n, table, unique)


def _probe(side: _HashSide, keys: Sequence[Any], n: int) -> tuple[list[int], list[int]]:
    """(probe position, build position) of every matching pair, in probe order."""
    found = list(map(side.table.get, keys))
    if side.unique:
        mask = list(map(_is_not_none, found))
        return list(compress(range(n), mask)), list(compress(found, mask))
    probe: list[int] = []
    build: list[int] = []
    for i, matches in enumerate(found):
        if matches is not None:
            probe.extend(repeat(i, len(matches)))
            build.extend(matches)
    return probe, build


def _filter_pairs(
    residual: VecFn | None, left: Columns, right: Columns, li: list[int], ri: list[int]
) -> tuple[list[int], list[int]]:
    """The pairs for which the residual join condition is TRUE."""
    if residual is None or not li:
        return li, ri
    out_l: list[int] = []
    out_r: list[int] = []
    for lo in range(0, len(li), VECTOR_BATCH_ROWS):
        cl, cr = li[lo : lo + VECTOR_BATCH_ROWS], ri[lo : lo + VECTOR_BATCH_ROWS]
        cols = [take(c, cl) for c in left] + [take(c, cr) for c in right]
        mask = residual(cols, len(cl))
        out_l.extend(compress(cl, mask))
        out_r.extend(compress(cr, mask))
    return out_l, out_r


def _with_unmatched(li: list[int], ri: list[int], n: int, pad: int) -> tuple[list[int], list[int]]:
    """Adds the left rows 0..n-1 without a pair (paired with the padding
    slot ``pad``), keeping the pairs in left order."""
    matched = set(li)
    if len(matched) == n:
        return li, ri
    unmatched = list(itertools.filterfalse(matched.__contains__, range(n)))
    if not li:
        return unmatched, [pad] * len(unmatched)
    all_l = li + unmatched
    all_r = ri + [pad] * len(unmatched)
    order = sorted(range(len(all_l)), key=all_l.__getitem__)
    return take(all_l, order), take(all_r, order)


def _emit_pairs(
    left: Columns, right: Columns, li: list[int], ri: list[int], identity: str | None = None
) -> Batches:
    """Output batches of the pairs: left columns gathered at ``li``, right at
    ``ri``. ``identity`` ("left" / "right") says that the positions of that
    side are exactly 0, 1, …, n-1, so its columns are passed on as they are."""
    if identity is not None and len(li) <= VECTOR_BATCH_ROWS:
        out_left = list(left) if identity == "left" else [take(c, li) for c in left]
        out_right = list(right) if identity == "right" else [take(c, ri) for c in right]
        yield out_left + out_right, len(li)
        return
    for lo in range(0, len(li), VECTOR_BATCH_ROWS):
        cl, cr = li[lo : lo + VECTOR_BATCH_ROWS], ri[lo : lo + VECTOR_BATCH_ROWS]
        yield [take(c, cl) for c in left] + [take(c, cr) for c in right], len(cl)


def _hash_join(node: pp.HashJoin, ctx: ExecutionContext) -> Batches:
    left_fns, right_fns = _key_fns(node, ctx)
    residual = _residual(node, ctx)
    side: _HashSide = ctx.shared(node, "vec:build", lambda: _build_hash_side(node, ctx))
    counter = JoinCounter(ctx)
    if node.build == "left":  # INNER join probing with the right input
        for cols, n in execute(node.right, ctx):
            pi, bi = _probe(side, _key_vector(right_fns, cols, n), n)
            bi, pi = _filter_pairs(residual, side.cols, cols, bi, pi)
            counter.add(len(pi))
            # a unique build side matches each probe row at most once
            yield from _emit_pairs(side.cols, cols, bi, pi, "right" if side.unique and len(pi) == n else None)
            ctx.check()
        return
    is_left = node.join_type == "LEFT"
    for cols, n in execute(node.left, ctx):
        pi, bi = _probe(side, _key_vector(left_fns, cols, n), n)
        pi, bi = _filter_pairs(residual, cols, side.cols, pi, bi)
        if is_left:
            pi, bi = _with_unmatched(pi, bi, n, side.n)
        counter.add(len(pi))
        yield from _emit_pairs(cols, side.cols, pi, bi, "left" if side.unique and len(pi) == n else None)
        ctx.check()


def _nested_loop_join(node: pp.NestedLoopJoin, ctx: ExecutionContext) -> Batches:
    """Block nested loops: blocks of about VECTOR_BATCH_ROWS row pairs (left
    rows × a chunk of right rows) are gathered and the condition is evaluated
    as one vector."""
    right, m = ctx.shared(node.right, "vec:materialized", lambda: _materialize(node.right, ctx))
    condition = _residual(node, ctx)
    is_left = node.join_type == "LEFT"
    pad_right = [c + [None] for c in right] if is_left else right
    counter = JoinCounter(ctx)
    chunk = min(max(m, 1), VECTOR_BATCH_ROWS)
    per_block = max(1, VECTOR_BATCH_ROWS // chunk)
    for left, n in execute(node.left, ctx):
        li: list[int] = []
        ri: list[int] = []
        for a in range(0, n, per_block):
            rows_ = range(a, min(a + per_block, n))
            for r0 in range(0, m, chunk):
                width = min(chunk, m - r0)
                bl = list(itertools.chain.from_iterable(repeat(i, width) for i in rows_))
                br = list(range(r0, r0 + width)) * len(rows_)
                if condition is not None:
                    cols = [take(c, bl) for c in left] + [c[r0 : r0 + width] * len(rows_) for c in right]
                    mask = condition(cols, len(bl))
                    bl = list(compress(bl, mask))
                    br = list(compress(br, mask))
                li.extend(bl)
                ri.extend(br)
                counter.add(len(bl))  # checked while the pairs are collected
            ctx.check()
        if is_left:
            matched = len(li)
            li, ri = _with_unmatched(li, ri, n, m)
            counter.add(len(li) - matched)
        yield from _emit_pairs(left, pad_right, li, ri)


def _build_merge_right(node: pp.MergeJoin, ctx: ExecutionContext) -> tuple[list[list[Any]], int, Sequence[Any]]:
    _, right_fns = _key_fns(node, ctx)
    cols, n = _materialize(node.right, ctx)
    keys = _key_vector(right_fns, cols, n)
    for c in cols:
        c.append(None)  # padding slot
    return cols, n, keys


def _merge_join(node: pp.MergeJoin, ctx: ExecutionContext) -> Batches:
    """Sort-merge join; output in key order, unmatched LEFT rows in place."""
    left_fns, _ = _key_fns(node, ctx)
    residual = _residual(node, ctx)
    right, m, right_keys = ctx.shared(node, "vec:merge_right", lambda: _build_merge_right(node, ctx))
    left, n = _materialize(node.left, ctx)
    left_keys = _key_vector(left_fns, left, n)
    li, ri = merge_pairs(list(left_keys), list(right_keys))
    ctx.check()
    li, ri = _filter_pairs(residual, left, right, li, ri)
    if node.join_type == "LEFT":
        li, ri = _with_unmatched(li, ri, n, m)
    JoinCounter(ctx).add(len(li))
    yield from _emit_pairs(left, right, li, ri)


# ------------------------------------------------------------ aggregation


def _aggregate_partition(
    node: pp.HashAggregate, ctx: ExecutionContext, batches: Batches
) -> tuple[list[Any], list[GroupState]]:
    """Partial aggregation: the group keys in first-seen order (values for
    one GROUP BY expression, else tuples) and the columnar state of every
    aggregate, indexed by group id."""

    def compile_() -> tuple[list[VecFn], list[VecFn | None]]:
        layout = layout_of(node.input)
        args = [None if c.arg is None else compile_vector(c.arg, ctx, layout) for c in node.aggregates]
        return _vectors(node.keys, ctx, layout), args

    key_fns, arg_fns = _compiled(node, "agg", ctx, compile_)
    states = [make_state(call) for call in node.aggregates]
    if not node.keys:
        for state in states:
            state.grow(1)
        for cols, n in batches:
            runs = [(0, 0, n)]
            for state, fn in zip(states, arg_fns):
                state.update_runs(runs, None if fn is None else fn(cols, n))
            ctx.check()
        return [()], states

    index: dict[Any, int] = {}  # group key -> dense group id
    width = len(node.layout)
    # native: SUM / AVG / COUNT states are folded by pqk_group_sum_i64
    native = native_ops.NativeGroupSums(ctx.native, states) if ctx.native is not None else None
    if native is not None and not native.buffers:
        native = None
    rest = [k for k in range(len(states)) if native is None or not native.handles(k)]
    rest_states = [states[k] for k in rest]
    for cols, n in batches:
        keys = _key_vector(key_fns, cols, n)
        batch_keys = dict.fromkeys(keys)
        before = len(index)
        for key in batch_keys:
            if key not in index:
                index[key] = len(index)
        if len(index) > before:
            for state in states:
                state.grow(len(index) - before)
            ctx.reserve_rows(len(index) - before, width)
        vectors = [None if fn is None else fn(cols, n) for fn in arg_fns]
        ids: list[int] | None = None
        if native is not None:
            if len(batch_keys) == 1:
                native_ids = array.array("I", [index[keys[0]]]) * n
            else:
                ids = list(map(index.__getitem__, keys))
                native_ids = array.array("I", ids)
            for k in native.buffers:
                native.add(k, native_ids, vectors[k])
            native.flush_if_full()
            vectors = [vectors[k] for k in rest]
            if not rest:
                ctx.check()
                continue
        if len(batch_keys) == 1:
            runs = [(index[keys[0]], 0, n)]
            for state, vector in zip(rest_states, vectors):
                state.update_runs(runs, vector)
        elif len(batch_keys) * 8 <= n:
            _update_sorted(ids or list(map(index.__getitem__, keys)), vectors, rest_states)
        else:
            ids = ids or list(map(index.__getitem__, keys))
            for state, vector in zip(rest_states, vectors):
                state.update_rows(ids, vector)
        ctx.check()
    if native is not None:
        native.flush()
    return list(index), states


def _update_sorted(ids: list[int], vectors: list, states: list[GroupState]) -> None:
    """Few groups in the batch: sort the positions by group id (C-level) and
    reduce every group's slice with one call per aggregate."""
    order = sorted(range(len(ids)), key=ids.__getitem__)
    runs: list[tuple[int, int, int]] = []  # (group id, start, end) in sorted order
    start = 0
    counts = Counter(ids)
    for gid in sorted(counts):
        end = start + counts[gid]
        runs.append((gid, start, end))
        start = end
    for state, vector in zip(states, vectors):
        state.update_runs(runs, None if vector is None else take(vector, order))


def _hash_aggregate(node: pp.HashAggregate, ctx: ExecutionContext) -> Batches:
    native = native_ops.native_scan_aggregate(node)
    done = None if native is None else native_ops.run_scan_aggregate(native, node, ctx)
    if done is not None:  # aggregated by the kernels from the column storage
        keys, states = done
    else:
        partials = partition_batches(node.input, ctx, "aggregate", node)
        keys, states = merge_partials(partials)
    n = len(keys)
    if not n:
        return
    if not node.keys:
        key_cols: Columns = []
    elif len(node.keys) == 1:
        key_cols = [keys]
    else:
        key_cols = [list(c) for c in zip(*keys)]
    cols = key_cols + [state.results() for state in states]
    if not cols:
        yield [], n
        return
    ctx.check()
    yield from _rebatch(cols, n)


# ------------------------------------------------------------ distinct / sort / limit


def _distinct_rows(batches: Iterable[Batch], seen: set, ctx: ExecutionContext, width: int) -> Batches:
    """New distinct rows (first occurrences, in input order) of each batch."""
    for cols, n in batches:
        keys = cols[0] if width == 1 else list(zip(*cols))
        new = [k for k in dict.fromkeys(keys) if k not in seen]
        if not new:
            continue
        seen.update(new)
        ctx.reserve_rows(len(new), width)
        if width == 1:
            yield [new], len(new)
        else:
            yield [list(c) for c in zip(*new)], len(new)


def _distinct(node: pp.Distinct, ctx: ExecutionContext) -> Batches:
    width = len(node.layout)
    if isinstance(node.input, pp.Gather):
        parts = partition_batches(node.input, ctx, "distinct", node)
        return _distinct_rows(itertools.chain.from_iterable(parts), set(), ctx, width)
    return _distinct_rows(execute(node.input, ctx), set(), ctx, width)


def _sorted_partition(batches: Batches, node: pp.Sort | pp.TopN, ctx: ExecutionContext, keep: int | None) -> Batch:
    width = len(node.layout)
    buffer = _Collector(width)
    limit = None if keep is None else max(2 * keep, VECTOR_BATCH_ROWS)
    bound: Callable[[Columns, int], Batch] | None = None
    for batch in batches:
        if bound is not None:
            batch = bound(*batch)
        buffer.add(batch)
        if keep is None:
            ctx.reserve_rows(batch[1], width)
        elif buffer.n >= limit:  # type: ignore[operator]
            cols, buffer.n = _sorted(buffer.cols, buffer.n, node, keep)
            buffer.cols = [list(c) for c in cols]
            if buffer.n == keep:
                bound = _top_bound(node.keys[0], buffer.cols, keep)
        ctx.check()
    cols, n = _sorted(buffer.cols, buffer.n, node, keep)
    if keep is not None:
        ctx.reserve_rows(n, width)
    return cols, n


def _top_bound(key: b.SortKey, cols: Columns, n: int) -> Callable[[Columns, int], Batch] | None:
    """A top-N prefilter: drops the rows whose first sort key is strictly
    worse than that of the last of the ``n`` rows kept so far (such a row
    sorts after ``n`` kept rows, so it cannot be in the top ``n``). Rows that
    tie on the first key are kept for the full sort."""
    column = key.position
    last = cols[column][n - 1]
    nulls_first = key.nulls_first
    if last is None and not nulls_first:
        return None  # NULLs sort last: every row ties or is better
    compare = operator.ge if key.descending else operator.le

    def prefilter(batch_cols: Columns, size: int) -> Batch:
        values = batch_cols[column]
        if last is None:  # only NULLs tie
            mask = list(map(_is_none, values))
        elif None in values:
            mask = [nulls_first if v is None else compare(v, last) for v in values]
        else:
            mask = list(map(compare, values, repeat(last)))
        kept = mask.count(True)
        if kept == size:
            return batch_cols, size
        return [list(compress(c, mask)) for c in batch_cols], kept

    return prefilter


def _sorted(cols: Columns, n: int, node: pp.Sort | pp.TopN, keep: int | None) -> tuple[Columns, int]:
    perm = sort_permutation(cols, n, node.keys)
    if keep is not None:
        del perm[keep:]
    return [take(c, perm) for c in cols], len(perm)


def _sort(node: pp.Sort | pp.TopN, ctx: ExecutionContext) -> Batches:
    keep = top_count(node, ctx) if isinstance(node, pp.TopN) else None
    if keep == 0:
        return
    if keep is None and isinstance(node.input, pp.Gather):
        # full sort: partitions only collect, the rows are sorted once
        merged = _Collector(len(node.layout))
        for part in partition_batches(node.input, ctx, "collect", node):
            for batch in part:
                merged.add(batch)
        ctx.reserve_rows(merged.n, len(node.layout))
        cols, n = _sorted(merged.cols, merged.n, node, None)
        parts = []
    else:
        parts = partition_batches(node.input, ctx, "sort", node, keep)
    if len(parts) == 1:
        cols, n = parts[0]
    elif parts:
        # partial top-Ns in partition order: the stable re-sort merges them
        merged = _Collector(len(node.layout))
        for part in parts:
            merged.add(part)
        cols, n = _sorted(merged.cols, merged.n, node, keep)
    ctx.check()
    yield from _rebatch(cols, n)


def _limit(node: pp.Limit, ctx: ExecutionContext) -> Batches:
    limit = evaluate_count(node.limit, ctx, "LIMIT")
    offset = evaluate_count(node.offset, ctx, "OFFSET") or 0
    if limit == 0:
        return
    remaining = limit
    for cols, n in execute(node.input, ctx):
        if offset:
            if offset >= n:
                offset -= n
                continue
            cols, n = [c[offset:] for c in cols], n - offset
            offset = 0
        if remaining is not None and n >= remaining:
            yield [c[:remaining] for c in cols], remaining
            return
        if remaining is not None:
            remaining -= n
        yield cols, n


# per-partition work of the consumers of parallel pipelines, by kind:
# (consumer operator, ctx, argument) -> function of the partition's batches
_CONSUMERS: dict[str, Callable[[Any, ExecutionContext, Any], Callable[[Batches], Any]]] = {
    "aggregate": lambda node, ctx, arg: partial(_aggregate_partition, node, ctx),
    "distinct": lambda node, ctx, arg: lambda batches: list(_distinct_rows(batches, set(), ctx, len(node.layout))),
    "collect": lambda node, ctx, arg: list,
    "sort": lambda node, ctx, arg: lambda batches: _sorted_partition(batches, node, ctx, arg),
}

_HANDLERS: dict[type, Callable[[Any, ExecutionContext], Batches]] = {
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
ENGINE = "vec"
register_engine(ENGINE, execute, prepare_pipeline, _CONSUMERS)
