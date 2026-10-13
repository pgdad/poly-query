"""Physical plan: concrete operator algorithms, and the planner that chooses
them from an (optimized) logical plan. Physical plans are what the executor
runs and what ``EXPLAIN`` shows (indexes-and-planning.md §4).

The physical planner alone takes the execution decisions: access paths
(table / index / lookup scans, row-group skipping), join algorithms and
order, ``TopN``, parallel pipelines (``Gather``), the execution mode and the
operators that run on native kernels."""

from __future__ import annotations

import dataclasses
import json
from dataclasses import dataclass, field
from typing import Any, Callable, Iterator

from ..analysis import bound as b
from ..limits import no_check
from ..native import NativeKernels
from ..storage.catalog import Column, Table
from ..storage.indexes import Index
from . import logical as lp
from .access import (
    ColumnPredicate,
    IndexLookup,
    choose_index,
    column_predicate,
    selectivity,
)
from .explain import render_expr

conjuncts = b.conjuncts
conjunction = b.conjunction

# execution modes (protocol option ``mode``; ``auto`` runs vectorized)
ROW = "row"
VECTORIZED = "vectorized"


@dataclass(eq=False)
class PhysicalNode:
    # estimated output cardinality, set by the planner (not a dataclass field)
    estimated_rows = 0.0

    def inputs(self) -> list[PhysicalNode]:
        return []

    @property
    def layout(self) -> list[b.ColumnKey]:
        raise NotImplementedError

    @property
    def op(self) -> str:
        return type(self).__name__

    def expressions(self) -> list[b.Expr]:
        """All expressions evaluated by this operator."""
        return []

    def describe(self) -> dict[str, Any]:
        return {}


@dataclass(eq=False)
class TableScan(PhysicalNode):
    """Full scan reading only ``columns``. Row groups whose statistics show
    that one of the ``skip`` predicates cannot hold are not read (the
    predicates are still evaluated by the Filter above)."""

    table: Table
    rel: int
    columns: list[int]
    alias: str
    skip: list[ColumnPredicate] = field(default_factory=list)

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in self.columns]

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "table": self.table.name,
            "columns": [self.table.columns[i].name for i in self.columns],
            "layout": self.table.layout,
        }
        if self.alias != self.table.name:
            out["alias"] = self.alias
        groups = self.table.row_groups()
        if self.skip and any(g.bounds is not None for g in groups):
            out["row_groups"] = len(groups)
            out["row_group_filter"] = [p.render(self.table) for p in self.skip]
        return out


@dataclass(eq=False)
class IndexScan(PhysicalNode):
    """Reads the rows an index lookup returns (in table order)."""

    table: Table
    rel: int
    columns: list[int]
    alias: str
    index: Index
    lookup: IndexLookup
    condition: str

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in self.columns]

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "table": self.table.name,
            "index": self.index.name,
            "kind": self.index.kind,
            "columns": [self.table.columns[i].name for i in self.columns],
            "condition": self.condition,
        }
        if self.alias != self.table.name:
            out["alias"] = self.alias
        return out


@dataclass(eq=False)
class LookupScan(PhysicalNode):
    """Scan of the rows whose ``key_column`` equals ``key`` (an expression over
    correlation parameters), through a hash table built once per statement.
    Used for ``inner_col = outer_col`` predicates of correlated subqueries."""

    table: Table
    rel: int
    columns: list[int]
    alias: str
    key_column: int
    key: b.Expr
    residual: b.Expr | None

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in self.columns]

    def expressions(self) -> list[b.Expr]:
        return [self.key] + ([self.residual] if self.residual is not None else [])

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "table": self.table.name,
            "columns": [self.table.columns[i].name for i in self.columns],
            "lookup": f"{self.table.columns[self.key_column].name} = {render_expr(self.key)}",
        }
        if self.residual is not None:
            out["residual"] = render_expr(self.residual)
        return out


@dataclass(eq=False)
class Values(PhysicalNode):
    """One row without columns."""

    @property
    def layout(self) -> list[b.ColumnKey]:
        return []

    def describe(self) -> dict[str, Any]:
        return {"rows": 1}


@dataclass(eq=False)
class SubqueryScan(PhysicalNode):
    input: PhysicalNode
    rel: int
    width: int
    alias: str
    # set when the statement computes the identical (uncorrelated,
    # side-effect free) input more than once, e.g. a CTE referenced twice:
    # the first execution's result is reused by the others
    shared: str | None = None

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(self.width)]

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {"alias": self.alias}
        if self.shared is not None:
            out["shared"] = True
        return out


@dataclass(eq=False)
class UnionAll(PhysicalNode):
    """Concatenates the rows of its branches, in order (spec/changes/union-all.md)."""

    branches: list[PhysicalNode]
    rel: int
    width: int

    def inputs(self) -> list[PhysicalNode]:
        return list(self.branches)

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(self.width)]


@dataclass(eq=False)
class Filter(PhysicalNode):
    input: PhysicalNode
    predicate: b.Expr
    # kernel plan of the filter (``native: true``; see execution.native_ops)
    native: object | None = None

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout

    def expressions(self) -> list[b.Expr]:
        return [self.predicate]

    def describe(self) -> dict[str, Any]:
        return {"predicate": render_expr(self.predicate)}


@dataclass(eq=False)
class _Join(PhysicalNode):
    join_type: str  # INNER, LEFT, CROSS
    left: PhysicalNode
    right: PhysicalNode

    def inputs(self) -> list[PhysicalNode]:
        return [self.left, self.right]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.left.layout + self.right.layout


@dataclass(eq=False)
class HashJoin(_Join):
    """Builds a hash table on one input (``build``: the right input unless the
    left one is estimated to be smaller; always the right one for LEFT
    joins) and probes it with the other. Output rows are left + right."""

    left_keys: list[b.Expr] = field(default_factory=list)
    right_keys: list[b.Expr] = field(default_factory=list)
    residual: b.Expr | None = None
    build: str = "right"
    # LEFT join below a filter that keeps only its unmatched rows (anti
    # join): only the left rows without a match are produced, padded with
    # NULLs, and the build side is just a set of keys
    anti: bool = False

    def expressions(self) -> list[b.Expr]:
        out = self.left_keys + self.right_keys
        return out + [self.residual] if self.residual is not None else out

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "join_type": self.join_type,
            "build": self.build,
            "keys": [
                f"{render_expr(lk)} = {render_expr(rk)}"
                for lk, rk in zip(self.left_keys, self.right_keys)
            ],
        }
        if self.residual is not None:
            out["residual"] = render_expr(self.residual)
        if self.anti:
            out["anti"] = True
        return out


@dataclass(eq=False)
class NestedLoopJoin(_Join):
    condition: b.Expr | None = None

    def expressions(self) -> list[b.Expr]:
        return [] if self.condition is None else [self.condition]

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {"join_type": self.join_type}
        if self.condition is not None:
            out["condition"] = render_expr(self.condition)
        return out


@dataclass(eq=False)
class MergeJoin(_Join):
    """Sort-merge equi-join: both inputs are sorted on their keys (NULL keys
    never match) and merged; ``residual`` filters the matching pairs."""

    left_keys: list[b.Expr] = field(default_factory=list)
    right_keys: list[b.Expr] = field(default_factory=list)
    residual: b.Expr | None = None

    def expressions(self) -> list[b.Expr]:
        out = self.left_keys + self.right_keys
        return out + [self.residual] if self.residual is not None else out

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "join_type": self.join_type,
            "keys": [
                f"{render_expr(lk)} = {render_expr(rk)}"
                for lk, rk in zip(self.left_keys, self.right_keys)
            ],
        }
        if self.residual is not None:
            out["residual"] = render_expr(self.residual)
        return out


@dataclass(eq=False)
class HashAggregate(PhysicalNode):
    """Groups by ``keys`` (one group overall when there are none)."""

    input: PhysicalNode
    rel: int
    keys: list[b.Expr]
    aggregates: list[b.AggCall]
    # kernel plan of a scan aggregation (``native: true``; see execution.native_ops)
    native: object | None = None

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(len(self.keys) + len(self.aggregates))]

    @property
    def op(self) -> str:
        return "HashAggregate" if self.keys else "Aggregate"

    def expressions(self) -> list[b.Expr]:
        return self.keys + [a.arg for a in self.aggregates if a.arg is not None]

    def describe(self) -> dict[str, Any]:
        return {
            "group_by": [render_expr(k) for k in self.keys],
            "aggregates": [render_expr(a) for a in self.aggregates],
        }


@dataclass(eq=False)
class Project(PhysicalNode):
    input: PhysicalNode
    rel: int
    exprs: list[b.Expr]
    names: list[str] = field(default_factory=list)

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(len(self.exprs))]

    def expressions(self) -> list[b.Expr]:
        return self.exprs

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {"exprs": [render_expr(e) for e in self.exprs]}
        if self.names:
            out["columns"] = self.names
        return out


@dataclass(eq=False)
class Distinct(PhysicalNode):
    input: PhysicalNode

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout


@dataclass(eq=False)
class Sort(PhysicalNode):
    input: PhysicalNode
    keys: list[b.SortKey]

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout

    def describe(self) -> dict[str, Any]:
        return {
            "keys": [
                f"#{k.position + 1} {'DESC' if k.descending else 'ASC'} "
                f"NULLS {'FIRST' if k.nulls_first else 'LAST'}"
                for k in self.keys
            ]
        }


@dataclass(eq=False)
class TopN(PhysicalNode):
    """The first ``limit + offset`` rows of the input in sort order (``ORDER BY
    … LIMIT``), keeping only that many rows in memory; the Limit above it
    applies the offset."""

    input: PhysicalNode
    keys: list[b.SortKey]
    limit: b.Expr
    offset: b.Expr | None

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout

    def describe(self) -> dict[str, Any]:
        out = Sort.describe(self)  # type: ignore[arg-type]
        out["limit"] = render_expr(self.limit)
        if self.offset is not None:
            out["offset"] = render_expr(self.offset)
        return out


@dataclass(eq=False)
class Gather(PhysicalNode):
    """Parallel pipeline: ``input`` runs once per partition, each run reading
    a disjoint row range of the ``driver`` scan (the other inputs of joins in
    the pipeline are prepared once and shared). The consumer of a Gather
    (HashAggregate, TopN, Distinct) does its partial work per partition and
    merges the partial results; otherwise (also below a full Sort) the
    partition outputs are concatenated in partition order, i.e. in the order
    of a serial scan."""

    input: PhysicalNode
    partitions: int
    driver: PhysicalNode

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout

    def describe(self) -> dict[str, Any]:
        return {"partitions": self.partitions, "driver": self.driver.table.name}  # type: ignore[attr-defined]


@dataclass(eq=False)
class Limit(PhysicalNode):
    input: PhysicalNode
    limit: b.Expr | None
    offset: b.Expr | None

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return self.input.layout

    def expressions(self) -> list[b.Expr]:
        return [e for e in (self.limit, self.offset) if e is not None]

    def describe(self) -> dict[str, Any]:
        out = {}
        if self.limit is not None:
            out["limit"] = render_expr(self.limit)
        if self.offset is not None:
            out["offset"] = render_expr(self.offset)
        return out


@dataclass
class PlanOptions:
    # logical rewrites, and the physical planner's join reordering and TopN
    optimize: bool = True
    join: str = "auto"  # auto, hash, merge, nested_loop
    use_indexes: bool = True
    threads: int = 1  # > 1: parallel pipelines (Gather)
    # automatic parallelism (> 0): only pipelines whose driving scan has at
    # least this many (estimated) rows, and at least BUILD_SCAN_RATIO times
    # the rows their join build sides scan, are parallelized
    parallel_min_rows: float = 0
    mode: str = "auto"  # auto (= vectorized), row, vectorized
    # the indexes of a table (catalog lookup)
    indexes_of: Callable[[Table], list[Index]] = lambda table: []
    # evaluates a constant expression (constant folding, index lookups,
    # row-group skipping)
    evaluate: Callable[[b.Expr], Any] | None = None
    # the native kernel library (``native: true`` and loaded), and the
    # function that compiles the kernel plan of a Filter or HashAggregate
    # (None where the kernels do not apply)
    kernels: NativeKernels | None = None
    kernel_plan: Callable[[PhysicalNode], object | None] | None = None
    # the statement's deadline / cancellation check
    check: Callable[[], None] = no_check


@dataclass(eq=False)
class PhysicalPlan:
    root: PhysicalNode
    columns: list[Column]
    # physical plans of the subqueries used in expressions, by Subquery.id
    subplans: dict[int, PhysicalNode]
    mode: str = VECTORIZED  # ROW (Volcano iterators) or VECTORIZED (column batches)
    native: NativeKernels | None = None  # the kernels, if any operator uses them

    def to_json(self) -> dict[str, Any]:
        return _node_json(self.root, self.subplans)


def _node_json(node: PhysicalNode, subplans: dict[int, PhysicalNode]) -> dict[str, Any]:
    """A plan node as JSON. The plans of subqueries evaluated by the node's
    expressions follow its inputs in ``children``, marked ``"subquery": true``
    (so that every scan of the statement is part of the tree)."""
    out: dict[str, Any] = {"op": node.op, **node.describe()}
    out["estimated_rows"] = round(node.estimated_rows)
    used: list[int] = []
    for expr in node.expressions():
        for sq in b.subqueries(expr):
            if sq.id not in used:
                used.append(sq.id)
    children = [_node_json(child, subplans) for child in node.inputs()]
    for i in used:
        children.append({**_node_json(subplans[i], subplans), "subquery": True})
    out["children"] = children
    return out


class PhysicalPlanner:
    def __init__(self, options: PlanOptions):
        self.options = options
        self.subplans: dict[int, PhysicalNode] = {}
        # ids of the uncorrelated subqueries (executed once per statement)
        self.uncorrelated: set[int] = set()
        self.logical_subqueries: dict[int, lp.LogicalNode] = {}
        # base table of every scanned range variable (for statistics)
        self.rel_tables: dict[int, Table] = {}

    def plan_statement(self, logical: lp.LogicalPlan) -> PhysicalPlan:
        self.logical_subqueries = logical.subqueries
        root = self.plan(logical.root)
        if isinstance(root, Project):
            root.names = [c.name for c in logical.columns]
        if self.options.threads > 1:
            partitions = min(self.options.threads, MAX_PARTITIONS)
            root = parallelize(root, partitions, self.options.parallel_min_rows)
            # uncorrelated subqueries run once; correlated ones (executed per
            # outer row) stay serial
            for sq_id in self.uncorrelated:
                self.subplans[sq_id] = parallelize(self.subplans[sq_id], partitions, self.options.parallel_min_rows)
        kernels = self.options.kernels
        if kernels is not None and self.options.kernel_plan is not None:
            for tree in [root, *self.subplans.values()]:
                self._bind_kernels(tree)
        if self.options.optimize:
            _share_common_subqueries([root, *self.subplans.values()], self.subplans)
        mode = ROW if self.options.mode == ROW else VECTORIZED
        return PhysicalPlan(root, logical.columns, self.subplans, mode, kernels)

    def plan(self, node: lp.LogicalNode) -> PhysicalNode:
        self.options.check()
        result = self._plan(node)
        for expr in result.expressions():
            for sq in b.subqueries(expr):
                if sq.id not in self.subplans:
                    self.subplans[sq.id] = self.plan(self.logical_subqueries[sq.id])
                    if not sq.correlated:
                        self.uncorrelated.add(sq.id)
        return result

    def _bind_kernels(self, node: PhysicalNode) -> None:
        """Attaches the kernel plans of the Filters and HashAggregates the
        native kernels can compute (inputs first: an aggregation's plan
        builds on the plan of the filter below it)."""
        for child in node.inputs():
            self._bind_kernels(child)
        if isinstance(node, (Filter, HashAggregate)):
            node.native = self.options.kernel_plan(node)  # type: ignore[misc]

    def _plan(self, node: lp.LogicalNode) -> PhysicalNode:
        if isinstance(node, lp.Scan):
            return self._scan(node, None)
        if isinstance(node, lp.Values):
            return _estimated(Values(), 1)
        if isinstance(node, lp.SubqueryScan):
            child = self.plan(node.input)
            return _estimated(SubqueryScan(child, node.rel, node.width, node.name), child.estimated_rows)
        if isinstance(node, lp.UnionAll):
            branches = [self.plan(branch) for branch in node.branches]
            rows = sum(branch.estimated_rows for branch in branches)
            return _estimated(UnionAll(branches, node.rel, node.width), rows)
        if isinstance(node, lp.Filter):
            if isinstance(node.input, lp.Scan):
                return self._scan(node.input, node.predicate)
            child = self.plan(node.input)
            if isinstance(child, HashJoin) and self.options.optimize:
                child.anti = self._keeps_only_unmatched(child, node.predicate)
            return self._filter(child, node.predicate)
        if isinstance(node, lp.Join):
            return self._plan_join(node)
        if isinstance(node, lp.Aggregate):
            child = self.plan(node.input)
            agg = HashAggregate(child, node.rel, node.keys, node.aggregates)
            return _estimated(agg, self._group_count(node.keys, child.estimated_rows))
        if isinstance(node, lp.Project):
            child = self.plan(node.input)
            return _estimated(Project(child, node.rel, node.exprs), child.estimated_rows)
        if isinstance(node, lp.Distinct):
            child = self.plan(node.input)
            return _estimated(Distinct(child), child.estimated_rows)
        if isinstance(node, lp.Sort):
            child = self.plan(node.input)
            return _estimated(Sort(child, node.keys), child.estimated_rows)
        if isinstance(node, lp.Limit):
            if self.options.optimize and isinstance(node.input, lp.Sort) and node.limit is not None:
                return self._top_n(node, node.input)
            child = self.plan(node.input)
            rows = child.estimated_rows
            if isinstance(node.limit, b.Literal) and isinstance(node.limit.value, int):
                rows = min(rows, node.limit.value)
            return _estimated(Limit(child, node.limit, node.offset), rows)
        raise AssertionError(f"unknown logical node {type(node).__name__}")

    def _top_n(self, limit: lp.Limit, sort: lp.Sort) -> PhysicalNode:
        """``ORDER BY … LIMIT`` as a TopN (the Limit applies the offset)."""
        child = self.plan(sort.input)
        rows = child.estimated_rows
        if isinstance(limit.limit, b.Literal) and isinstance(limit.limit.value, int):
            rows = min(rows, limit.limit.value)
        top = _estimated(TopN(child, sort.keys, limit.limit, limit.offset), rows)  # type: ignore[arg-type]
        return _estimated(Limit(top, limit.limit, limit.offset), rows)

    # ------------------------------------------------------------ scans

    def _scan(self, scan: lp.Scan, predicate: b.Expr | None) -> PhysicalNode:
        """Access path for a scan with the conjuncts pushed onto it: a
        LookupScan for correlated equality, an IndexScan when an index lookup
        is selective enough, else a TableScan (with row-group skipping)."""
        table = scan.table
        self.rel_tables[scan.rel] = table
        if predicate is None:
            return _estimated(TableScan(table, scan.rel, scan.columns, scan.name), table.row_count)
        lookup = _lookup_scan(scan, predicate)
        if lookup is not None:
            distinct = table.column_stats(lookup.key_column).distinct_count
            return _estimated(lookup, table.row_count / distinct if distinct else 0)

        parts = conjuncts(predicate)
        preds: list[ColumnPredicate] = []
        evaluate = self.options.evaluate
        if evaluate is not None:
            for p in parts:
                pred = column_predicate(p, scan.rel, table, evaluate)
                if pred is not None:
                    preds.append(pred)
        if self.options.use_indexes and preds:
            choice = choose_index(table, preds, self.options.indexes_of(table))
            if choice is not None:
                node: PhysicalNode = IndexScan(
                    table, scan.rel, scan.columns, scan.name, choice.index, choice.lookup, choice.description
                )
                _estimated(node, table.row_count * choice.selectivity)
                residual = [p for p in parts if not any(p is c for c in choice.consumed)]
                return self._filter(node, conjunction(residual)) if residual else node
        node = TableScan(table, scan.rel, scan.columns, scan.name, preds)
        return self._filter(_estimated(node, table.row_count), predicate)

    def _filter(self, child: PhysicalNode, predicate: b.Expr) -> PhysicalNode:
        return _estimated(Filter(child, predicate), child.estimated_rows * self._selectivity(predicate))

    def _keeps_only_unmatched(self, join: HashJoin, predicate: b.Expr) -> bool:
        """Whether a filter over a LEFT hash join (without residual condition)
        rejects every matched row: one of its conjuncts is ``c IS NULL`` for
        a right column ``c`` that is never NULL in a matched row — a right
        join key (NULL keys never match), or a column of the scanned right
        table whose (exact) statistics count no NULLs."""
        if join.join_type != "LEFT" or join.residual is not None or join.build != "right":
            return False
        right_keys = {k.key for k in join.right_keys if isinstance(k, b.ColumnRef)}
        scanned = _scanned_rel(join.right)
        for part in conjuncts(predicate):
            if not (isinstance(part, b.IsNull) and not part.negated and isinstance(part.operand, b.ColumnRef)):
                continue
            key = part.operand.key
            if key in right_keys:
                return True
            if scanned is not None and key[0] == scanned:
                found = self._resolve(key)
                if found is not None and found[0].column_stats(found[1]).null_count == 0:
                    return True
        return False

    def _selectivity(self, predicate: b.Expr) -> float:
        evaluate = self.options.evaluate
        if evaluate is None:
            return 1.0 / 3.0
        return selectivity(predicate, self._resolve, evaluate)

    def _resolve(self, key: b.ColumnKey) -> tuple[Table, int] | None:
        table = self.rel_tables.get(key[0])
        return None if table is None else (table, key[1])

    def _group_count(self, keys: list[b.Expr], input_rows: float) -> float:
        if not keys:
            return 1
        groups = 1.0
        for key in keys:
            found = self._resolve(key.key) if isinstance(key, b.ColumnRef) else None
            if found is None:
                return input_rows
            groups *= max(found[0].column_stats(found[1]).distinct_count, 1)
        return min(groups, input_rows)

    # ------------------------------------------------------------ joins

    def _plan_join(self, node: lp.Join) -> PhysicalNode:
        if self.options.optimize and node.kind in ("INNER", "CROSS"):
            leaves, conditions = _inner_join_chain(node)
            if len(leaves) > 2:
                return self._reorder_joins(leaves, conditions)
        left, right = self.plan(node.left), self.plan(node.right)
        return self._make_join(node.kind, node.condition, left, right, node.left.rels(), node.right.rels())

    def _make_join(
        self,
        kind: str,
        condition: b.Expr | None,
        left: PhysicalNode,
        right: PhysicalNode,
        left_rels: set[int],
        right_rels: set[int],
    ) -> PhysicalNode:
        join = self._join(kind, condition, left, right, left_rels, right_rels)
        return _estimated(join, self._join_rows(join.join_type, condition, left, right))

    def _join_rows(
        self, kind: str, condition: b.Expr | None, left: PhysicalNode, right: PhysicalNode
    ) -> float:
        rows_l, rows_r = left.estimated_rows, right.estimated_rows
        if condition is None:
            rows = rows_l * rows_r
        else:
            rows = rows_l * rows_r * self._selectivity(condition)
        return max(rows, rows_l) if kind == "LEFT" else rows

    def _reorder_joins(self, leaves: list[lp.LogicalNode], conditions: list[b.Expr]) -> PhysicalNode:
        """Greedy join ordering for a chain of inner/cross joins: start with
        the smallest input, then repeatedly join the input that produces
        the fewest rows, preferring inputs connected by a join condition
        (cross products come last). Each conjunct is evaluated by the first
        join that sees all the relations it references."""
        chain_rels = set().union(*(leaf.rels() for leaf in leaves))
        planned = [(self.plan(leaf), leaf.rels()) for leaf in leaves]
        pending = list(conditions)
        first = min(range(len(planned)), key=lambda i: planned[i][0].estimated_rows)
        current, current_rels = planned[first]
        remaining = [i for i in range(len(planned)) if i != first]
        while remaining:
            best = None
            for i in remaining:
                node, rels = planned[i]
                usable = [p for p in pending if _rels_within(p, chain_rels) <= current_rels | rels]
                connected = any(
                    _rels_within(p, chain_rels) & rels and _rels_within(p, chain_rels) & current_rels
                    for p in usable
                )
                rows = self._join_rows("INNER", conjunction(usable), current, node)
                rank = (not connected, rows)
                if best is None or rank < best[0]:
                    best = (rank, i, usable)
            assert best is not None
            _, i, usable = best
            node, rels = planned[i]
            pending = [p for p in pending if not any(p is u for u in usable)]
            kind = "INNER" if usable else "CROSS"
            current = self._make_join(kind, conjunction(usable), current, node, current_rels, rels)
            current_rels = current_rels | rels
            remaining.remove(i)
        if pending:  # conjuncts not referencing any relation of the chain
            current = self._filter(current, conjunction(pending))  # type: ignore[arg-type]
        return current

    def _join(
        self,
        kind: str,
        condition: b.Expr | None,
        left: PhysicalNode,
        right: PhysicalNode,
        left_rels: set[int],
        right_rels: set[int],
    ) -> _Join:
        """The join algorithm: ``join`` forces hash / merge / nested-loop for
        equi-joins (non-equi joins always use nested loops); ``auto`` picks a
        hash join for equi-joins, whose cost is linear in both inputs (a
        merge join must sort both inputs first, as no input arrives sorted)."""
        join_type = kind if condition is not None or kind != "INNER" else "CROSS"
        if condition is None or self.options.join == "nested_loop":
            return NestedLoopJoin(join_type, left, right, condition)
        both = left_rels | right_rels
        left_keys: list[b.Expr] = []
        right_keys: list[b.Expr] = []
        residual: list[b.Expr] = []
        for p in conjuncts(condition):
            if isinstance(p, b.Compare) and p.op == "=":
                lr = {k[0] for k in b.column_keys(p.left)} & both
                rr = {k[0] for k in b.column_keys(p.right)} & both
                if lr and rr and lr <= left_rels and rr <= right_rels:
                    left_keys.append(p.left)
                    right_keys.append(p.right)
                    continue
                if lr and rr and lr <= right_rels and rr <= left_rels:
                    left_keys.append(p.right)
                    right_keys.append(p.left)
                    continue
            residual.append(p)
        if not left_keys:
            return NestedLoopJoin(join_type, left, right, condition)
        if self.options.join == "merge":
            return MergeJoin(join_type, left, right, left_keys, right_keys, conjunction(residual))
        # build on the smaller input (inner joins); LEFT joins build on the right
        build = "left" if join_type == "INNER" and left.estimated_rows < right.estimated_rows else "right"
        return HashJoin(join_type, left, right, left_keys, right_keys, conjunction(residual), build)


def _inner_join_chain(node: lp.LogicalNode) -> tuple[list[lp.LogicalNode], list[b.Expr]]:
    """The inputs and conjuncts of a maximal tree of inner/cross joins."""
    if isinstance(node, lp.Join) and node.kind in ("INNER", "CROSS"):
        left, lc = _inner_join_chain(node.left)
        right, rc = _inner_join_chain(node.right)
        return left + right, lc + rc + conjuncts(node.condition)
    return [node], []


def _rels_within(expr: b.Expr, rels: set[int]) -> set[int]:
    return {key[0] for key in b.column_keys(expr)} & rels


# ------------------------------------------------------------ parallel pipelines


def pipeline_path(node: PhysicalNode) -> list[PhysicalNode] | None:
    """The nodes from ``node`` down to the scan driving it, if ``node`` is a
    pipeline that can run partitioned: only streaming operators on the path
    (Filter, Project, SubqueryScan, and joins through their probe / outer
    input), ending in a TableScan or IndexScan."""
    path: list[PhysicalNode] = []
    while True:
        path.append(node)
        if isinstance(node, (TableScan, IndexScan)):
            return path
        if isinstance(node, (Filter, Project, SubqueryScan)):
            node = node.input
        elif isinstance(node, HashJoin):
            node = node.left if node.build == "right" else node.right
        elif isinstance(node, (NestedLoopJoin, MergeJoin)):
            node = node.left
        else:
            return None


# partitions of a parallel pipeline (``threads`` beyond this add no parallelism)
MAX_PARTITIONS = 64
# a pipeline whose rows all go back to the parent (at the root, below a full
# sort) is parallelized only if it is expected to return at most this
# fraction of the rows it scans: every row of a worker process is pickled
ROOT_GATHER_MAX_SELECTIVITY = 0.25
# automatic parallelism: the driving scan must read at least this many times
# the rows scanned to build the pipeline's join hash tables (each worker
# builds them; 16 workers doing so contend for memory bandwidth)
BUILD_SCAN_RATIO = 2.0
# full sorts of pipelines scanning fewer rows are not parallelized unless
# the pipeline is selective (range partitioning pays off for large inputs)
RANGE_SORT_MIN_ROWS = 100_000


def parallelize(root: PhysicalNode, partitions: int, min_rows: float = 0) -> PhysicalNode:
    """Inserts Gathers below the operators that merge partial results
    (aggregation, top-N, distinct), and above selective pipelines that
    filter or join at the root or below a full sort (whose input rows are
    all returned to the parent anyway). Pipelines driven by scans of fewer
    than ``min_rows`` estimated rows stay serial."""
    _parallelize_inputs(root, partitions, min_rows)
    return _gather_selective(root, partitions, min_rows)


def _worth_partitioning(path: list[PhysicalNode], min_rows: float) -> bool:
    """Automatic parallelism (``min_rows`` > 0): the driving scan is large,
    and large compared with the join build sides on the path, which every
    worker builds for itself."""
    if min_rows <= 0:
        return True
    driver_rows = path[-1].estimated_rows
    if driver_rows < min_rows:
        return False
    built = sum(_scanned_rows(build) for build in _build_inputs(path))
    return driver_rows >= BUILD_SCAN_RATIO * built


def _build_inputs(path: list[PhysicalNode]) -> list[PhysicalNode]:
    out: list[PhysicalNode] = []
    for node in path:
        if isinstance(node, HashJoin):
            out.append(node.right if node.build == "right" else node.left)
        elif isinstance(node, (NestedLoopJoin, MergeJoin)):
            out.append(node.right)
    return out


def _scanned_rows(node: PhysicalNode) -> float:
    if isinstance(node, (TableScan, IndexScan, LookupScan)):
        return node.estimated_rows
    return sum(_scanned_rows(child) for child in node.inputs())


def _gather_selective(node: PhysicalNode, partitions: int, min_rows: float) -> PhysicalNode:
    path = pipeline_path(node)
    if path is None or not any(isinstance(n, (Filter, _Join)) for n in path):
        return node
    if not _worth_partitioning(path, min_rows):
        return node
    if node.estimated_rows > ROOT_GATHER_MAX_SELECTIVITY * max(path[-1].estimated_rows, 1.0):
        return node
    return _estimated(Gather(node, partitions, path[-1]), node.estimated_rows)


def _gather_large(node: PhysicalNode, partitions: int, min_rows: float) -> PhysicalNode:
    """A Gather over a large pipeline below a full sort (which the
    vectorized engine sorts by key ranges in parallel)."""
    path = pipeline_path(node)
    if path is None or path[-1].estimated_rows < RANGE_SORT_MIN_ROWS or not _worth_partitioning(path, min_rows):
        return node
    return _estimated(Gather(node, partitions, path[-1]), node.estimated_rows)


def is_selective(gather: Gather) -> bool:
    """Whether a Gather's pipeline returns few of the rows it scans."""
    return gather.estimated_rows <= ROOT_GATHER_MAX_SELECTIVITY * max(gather.driver.estimated_rows, 1.0)


def _parallelize_inputs(node: PhysicalNode, partitions: int, min_rows: float) -> None:
    for child in node.inputs():
        _parallelize_inputs(child, partitions, min_rows)
    if isinstance(node, (HashAggregate, TopN, Distinct)):
        path = pipeline_path(node.input)
        if path is not None and _worth_partitioning(path, min_rows):
            node.input = _estimated(Gather(node.input, partitions, path[-1]), node.input.estimated_rows)
    elif isinstance(node, Sort):
        gathered = _gather_selective(node.input, partitions, min_rows)
        if gathered is node.input:
            gathered = _gather_large(node.input, partitions, min_rows)
        node.input = gathered
    elif isinstance(node, UnionAll):
        node.branches = [_gather_selective(branch, partitions, min_rows) for branch in node.branches]


def _walk(node: PhysicalNode, subplans: dict[int, PhysicalNode]) -> Iterator[PhysicalNode]:
    """A plan tree's nodes in pre-order, including the plans of the
    subqueries its expressions use (iteratively: plans of nested subqueries
    are deep)."""
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        nested = [subplans[sq.id] for expr in n.expressions() for sq in b.subqueries(expr) if sq.id in subplans]
        stack += reversed([*nested, *n.inputs()])


def _subtree_sizes(trees: list[PhysicalNode]) -> dict[int, int]:
    """The node count of every subtree (by id() of its root), computed in
    one post-order pass."""
    sizes: dict[int, int] = {}
    for tree in trees:
        stack = [tree]
        while stack:
            n = stack[-1]
            pending = [c for c in n.inputs() if id(c) not in sizes]
            if pending:
                stack += pending
                continue
            stack.pop()
            sizes[id(n)] = 1 + sum(sizes[id(c)] for c in n.inputs())
    return sizes


def _self_contained(node: PhysicalNode) -> bool:
    """Whether a subtree's result depends on nothing outside it: every
    column it references is produced inside it (no correlation parameter),
    and no expression has side effects or runs a subquery."""
    nodes = list(_walk(node, {}))
    produced = {key[0] for n in nodes for key in n.layout}
    for n in nodes:
        if getattr(n, "native", None) is not None:
            return False
        for expr in n.expressions():
            if b.has_side_effects(expr) or b.contains_subquery(expr):
                return False
            if any(key[0] not in produced for key in b.column_keys(expr)):
                return False
    return True


def _signature(root: PhysicalNode) -> str:
    """A structural description of a subtree that is equal for two subtrees
    exactly when they compute the same rows: node types and all their
    fields, with the relation ids of column keys renumbered in order of
    appearance (so the copies of a CTE planned for each reference compare
    equal) and tables / indexes by identity."""
    nodes = list(_walk(root, {}))
    rels: dict[int, int] = {}
    for n in nodes:
        for key in n.layout:
            rels.setdefault(key[0], len(rels))

    def canonical(value: Any) -> Any:
        if isinstance(value, PhysicalNode):
            return None  # the subtree's structure: the walk order and input counts
        if isinstance(value, (Table, Index)):
            return ["object", id(value)]
        if isinstance(value, b.Expr):
            out: list[str] = []
            _expr_signature(value, rels, out)
            return "".join(out)
        if isinstance(value, (list, tuple)):
            return [canonical(v) for v in value]
        return repr(value)

    parts = []
    for n in nodes:
        fields = {
            f.name: canonical(getattr(n, f.name))
            for f in dataclasses.fields(n)
            if f.name not in ("rel", "estimated_rows", "shared")
        }
        layout = [[rels[key[0]], key[1]] for key in n.layout]
        parts.append([type(n).__name__, fields, layout, len(n.inputs())])
    return json.dumps(parts)


def _expr_signature(e: b.Expr, rels: dict[int, int], out: list[str]) -> None:
    """Appends the structure of ``e`` to ``out``: node types, operators,
    literal values and types, with the relation ids of column keys
    renumbered by ``rels``. Collected in one list (rendering each subtree
    as a string would copy it again at every level of a deep tree)."""
    out.append(type(e).__name__ + "(")
    for f in dataclasses.fields(e):
        value = getattr(e, f.name)
        out.append(f.name + "=")
        if isinstance(e, b.ColumnRef) and f.name == "rel":
            out.append(repr(rels[value]))
        elif isinstance(value, b.Expr):
            _expr_signature(value, rels, out)
        elif isinstance(value, tuple) and value and isinstance(value[0], (b.Expr, tuple)):
            out.append("(")
            for item in value:
                if isinstance(item, tuple):  # CASE branches
                    out.append("(")
                    for part in item:
                        _expr_signature(part, rels, out)
                        out.append(",")
                    out.append(")")
                else:
                    _expr_signature(item, rels, out)
                out.append(",")
            out.append(")")
        else:
            out.append(repr(value))
        out.append(",")
    out.append(")")


def _share_common_subqueries(trees: list[PhysicalNode], subplans: dict[int, PhysicalNode]) -> None:
    """Marks the SubqueryScans of a statement that compute identical,
    self-contained inputs (e.g. the references to one CTE), so that their
    result is computed once."""
    # Only inputs of equal size can be identical: the (costly) signatures
    # are computed for those alone. Nested scans never have equal sizes,
    # so deeply nested derived tables cost linear time.
    sizes = _subtree_sizes(trees)
    by_size: dict[int, list[SubqueryScan]] = {}
    for tree in trees:
        for node in _walk(tree, {}):
            if isinstance(node, SubqueryScan):
                by_size.setdefault(sizes[id(node.input)], []).append(node)
    groups: dict[str, list[SubqueryScan]] = {}
    for candidates in by_size.values():
        if len(candidates) < 2:
            continue
        for node in candidates:
            if _self_contained(node.input):
                groups.setdefault(_signature(node.input), []).append(node)
    for signature, scans in groups.items():
        if len(scans) > 1:
            for scan in scans:
                scan.shared = signature


def _scanned_rel(node: PhysicalNode) -> int | None:
    """The range variable of a plain (possibly filtered) table scan, whose
    output columns are the table's own values."""
    while isinstance(node, Filter):
        node = node.input
    if isinstance(node, (TableScan, IndexScan)):
        return node.rel
    return None


def _estimated(node: PhysicalNode, rows: float) -> PhysicalNode:
    node.estimated_rows = max(float(rows), 0.0)
    return node


def _lookup_scan(scan: lp.Scan, predicate: b.Expr) -> LookupScan | None:
    """A LookupScan if a conjunct equates a scanned column with an expression
    over correlation parameters only (column keys of enclosing queries)."""
    layout = set(scan.layout)
    parts = conjuncts(predicate)
    for i, p in enumerate(parts):
        if not (isinstance(p, b.Compare) and p.op == "="):
            continue
        for column, other in ((p.left, p.right), (p.right, p.left)):
            if not (isinstance(column, b.ColumnRef) and column.key in layout):
                continue
            keys = b.column_keys(other)
            if not keys or keys & layout or b.contains_subquery(other) or column.type != other.type:
                continue
            residual = conjunction(parts[:i] + parts[i + 1 :])
            return LookupScan(
                scan.table, scan.rel, scan.columns, scan.name, column.index, other, residual
            )
    return None
