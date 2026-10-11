"""Algorithms shared by the row-at-a-time and the vectorized executors:
join key alignment and limits, sort orders, the merge-join pairing, LIMIT
evaluation and the LookupScan hash tables."""

from __future__ import annotations

import operator
from typing import Any, Callable, Sequence

from .. import errors
from ..analysis import bound as b
from ..datatypes import COMPARISON_PRECISION, DataType, TypeKind
from ..planner import physical as pp
from .compiler import compile_expr
from .context import ExecutionContext

# rows per batch handed to the protocol layer / produced by vectorized operators
OUTPUT_BATCH_ROWS = 2048
VECTOR_BATCH_ROWS = 4096
# operators whose work is not proportional to their output check for
# cancellation / timeout after at most this many rows (concurrency.md §4)
CHECK_INTERVAL_ROWS = 65_536


class JoinCounter:
    """Enforces --max-join-rows on the rows produced by one join."""

    __slots__ = ("limit", "rows")

    def __init__(self, ctx: ExecutionContext):
        self.limit = ctx.max_join_rows
        self.rows = 0

    def add(self, n: int) -> None:
        self.rows += n
        if self.rows > self.limit:
            raise errors.resource_limit(f"join produced more than {self.limit} rows (--max-join-rows)")


def _decimal_scale(t: DataType) -> int | None:
    return t.scale if t.kind is TypeKind.DECIMAL else None


def aligned_keys(left: list[b.Expr], right: list[b.Expr]) -> tuple[list[b.Expr], list[b.Expr]]:
    """Makes equal key values hash (and sort) equally: DECIMAL keys of
    different scales are rescaled to the larger scale (other promotions were
    added by the binder)."""
    out_left, out_right = [], []
    for lk, rk in zip(left, right):
        ls, rs = _decimal_scale(lk.type), _decimal_scale(rk.type)
        if ls is not None and rs is not None and ls != rs:
            # exact rescaling: the comparison precision never overflows
            target = DataType(TypeKind.DECIMAL, COMPARISON_PRECISION, max(ls, rs))
            lk = lk if ls == target.scale else b.Cast(target, lk, implicit=True)
            rk = rk if rs == target.scale else b.Cast(target, rk, implicit=True)
        out_left.append(lk)
        out_right.append(rk)
    return out_left, out_right


def evaluate_count(expr: b.Expr | None, ctx: ExecutionContext, clause: str) -> int | None:
    """Evaluates a constant LIMIT/OFFSET expression."""
    if expr is None:
        return None
    value = compile_expr(expr, ctx)(())
    if value is not None and value < 0:
        raise errors.invalid_argument(f"{clause} must not be negative")
    return value


def top_count(node: pp.TopN, ctx: ExecutionContext) -> int | None:
    """How many sorted rows a TopN keeps (None: all)."""
    limit = evaluate_count(node.limit, ctx, "LIMIT")
    if limit is None:
        return None
    return limit + (evaluate_count(node.offset, ctx, "OFFSET") or 0)


# ------------------------------------------------------------ sorting


def _null_rank(key: b.SortKey) -> tuple:
    """Sort key of NULL: rank 0 sorts before non-NULLs (rank 1), rank 2 after;
    ``reverse`` flips the ranks as well, hence the XOR."""
    return (0,) if key.nulls_first != key.descending else (2,)


def sort_rows(rows: list[tuple], keys: list[b.SortKey]) -> None:
    """Sorts row tuples in place: one stable pass per key, least significant first."""
    for key in reversed(keys):
        pos = key.position
        if not any(row[pos] is None for row in rows):
            rows.sort(key=operator.itemgetter(pos), reverse=key.descending)
            continue
        null_key = _null_rank(key)

        def sort_key(row: tuple, pos: int = pos, null_key: tuple = null_key) -> tuple:
            v = row[pos]
            return null_key if v is None else (1, v)

        rows.sort(key=sort_key, reverse=key.descending)


def sort_permutation(columns: Sequence[Sequence[Any]], length: int, keys: list[b.SortKey]) -> list[int]:
    """The row order of column data sorted by ``keys`` (stable). Every pass
    sorts the permutation with a C-level key (``column.__getitem__``); NULLs
    are split off first and placed before or after the sorted non-NULLs,
    which is exactly a stable sort with NULLs ranked first or last."""
    perm = list(range(length))
    for key in reversed(keys):
        column = columns[key.position]
        get = column.__getitem__
        if None not in column:
            perm.sort(key=get, reverse=key.descending)
            continue
        nulls = [i for i in perm if column[i] is None]
        values = [i for i in perm if column[i] is not None]
        values.sort(key=get, reverse=key.descending)
        perm = nulls + values if key.nulls_first else values + nulls
    return perm


# ------------------------------------------------------------ merge join


def _valid_key(key: Any) -> bool:
    if key is None:
        return False
    return not (isinstance(key, tuple) and None in key)


def merge_pairs(left_keys: list[Any], right_keys: list[Any]) -> tuple[list[int], list[int]]:
    """Sort-merge pairing: the (left, right) positions of all pairs with
    equal keys (a key is a value or a tuple of values; keys containing NULL
    never match). Both sides are sorted by key, then merged run by run."""
    lorder = sorted((i for i, k in enumerate(left_keys) if _valid_key(k)), key=left_keys.__getitem__)
    rorder = sorted((i for i, k in enumerate(right_keys) if _valid_key(k)), key=right_keys.__getitem__)
    out_left: list[int] = []
    out_right: list[int] = []
    i = j = 0
    nl, nr = len(lorder), len(rorder)
    while i < nl and j < nr:
        lk = left_keys[lorder[i]]
        rk = right_keys[rorder[j]]
        if lk < rk:
            i += 1
        elif rk < lk:
            j += 1
        else:
            i_end = i + 1
            while i_end < nl and left_keys[lorder[i_end]] == lk:
                i_end += 1
            j_end = j + 1
            while j_end < nr and right_keys[rorder[j_end]] == rk:
                j_end += 1
            run = rorder[j:j_end]
            for li in lorder[i:i_end]:
                out_left.extend([li] * len(run))
                out_right.extend(run)
            i, j = i_end, j_end
    return out_left, out_right


# ------------------------------------------------------------ lookup scans


def lookup_table(node: pp.LookupScan, ctx: ExecutionContext) -> dict[Any, list[tuple]]:
    """The hash table (key column value -> rows) of a LookupScan, built once
    per statement."""
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


def lookup_rows(node: pp.LookupScan, ctx: ExecutionContext) -> list[tuple]:
    """The rows of a LookupScan for the current correlation parameters."""
    table, key, residual = ctx.cached(node, "lookup", lambda: (lookup_table(node, ctx), *_compile_lookup(node, ctx)))
    value = key(())
    rows = table.get(value, ()) if value is not None else ()
    if residual is not None:
        return [row for row in rows if residual(row) is True]
    return list(rows)


def _compile_lookup(node: pp.LookupScan, ctx: ExecutionContext) -> tuple[Callable, Callable | None]:
    key = compile_expr(node.key, ctx)
    layout = {k: i for i, k in enumerate(node.layout)}
    residual = compile_expr(node.residual, ctx, layout) if node.residual is not None else None
    return key, residual


def scan_range(node: pp.PhysicalNode, ctx: ExecutionContext, total: int) -> tuple[int, int | None]:
    """The row range a (possibly partitioned) driver scan reads."""
    part = ctx.partitions.get(id(node))
    if part is None:
        return 0, None
    index, count = part
    return total * index // count, total * (index + 1) // count
