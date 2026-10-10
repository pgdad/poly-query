"""Physical plan: concrete operator algorithms, and the planner that chooses
them from a logical plan. Physical plans are what the executor runs and what
``EXPLAIN`` shows (indexes-and-planning.md §4)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

from ..analysis import bound as b
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
from .optimizer import conjunction, conjuncts, optimize, prune_columns
from .planner import LogicalPlanner


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

    def inputs(self) -> list[PhysicalNode]:
        return [self.input]

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in range(self.width)]

    def describe(self) -> dict[str, Any]:
        return {"alias": self.alias}


@dataclass(eq=False)
class Filter(PhysicalNode):
    input: PhysicalNode
    predicate: b.Expr

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
    (HashAggregate, Sort, TopN, Distinct) does its partial work per
    partition and merges the partial results; otherwise the partition
    outputs are concatenated in partition order, i.e. in the order of a
    serial scan."""

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
    optimize: bool = True
    join: str = "auto"  # auto, hash, merge, nested_loop
    use_indexes: bool = True
    threads: int = 1  # > 1: parallel pipelines (Gather)
    # the indexes of a table (catalog lookup)
    indexes_of: Callable[[Table], list[Index]] = lambda table: []
    # evaluates a constant expression (for index lookups / row-group skipping)
    evaluate: Callable[[b.Expr], Any] | None = None


@dataclass(eq=False)
class PhysicalPlan:
    root: PhysicalNode
    columns: list[Column]
    # physical plans of the subqueries used in expressions, by Subquery.id
    subplans: dict[int, PhysicalNode]

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
    def __init__(self, ids: b.IdGenerator, options: PlanOptions):
        self.ids = ids
        self.options = options
        self.subplans: dict[int, PhysicalNode] = {}
        # base table of every scanned range variable (for statistics)
        self.rel_tables: dict[int, Table] = {}

    def plan_statement(self, query: b.BoundQuery) -> PhysicalPlan:
        root = self.plan_query(query)
        if isinstance(root, Project):
            root.names = [o.name for o in query.outputs]
        if self.options.threads > 1:
            # subquery plans (executed per outer row) stay serial
            root = parallelize(root, self.options.threads)
        columns = [Column(o.name, o.expr.type) for o in query.outputs]
        return PhysicalPlan(root, columns, self.subplans)

    def plan_query(self, query: b.BoundQuery) -> PhysicalNode:
        logical = LogicalPlanner(self.ids).plan_query(query)
        if self.options.optimize:
            logical = prune_columns(optimize(logical))
        return self.plan(logical)

    def plan(self, node: lp.LogicalNode) -> PhysicalNode:
        result = self._plan(node)
        for expr in result.expressions():
            for sq in b.subqueries(expr):
                if sq.id not in self.subplans:
                    self.subplans[sq.id] = self.plan_query(sq.query)
        return result

    def _plan(self, node: lp.LogicalNode) -> PhysicalNode:
        if isinstance(node, lp.Scan):
            return self._scan(node, None)
        if isinstance(node, lp.Values):
            return _estimated(Values(), 1)
        if isinstance(node, lp.SubqueryScan):
            child = self.plan(node.input)
            return _estimated(SubqueryScan(child, node.rel, node.width, node.name), child.estimated_rows)
        if isinstance(node, lp.Filter):
            if isinstance(node.input, lp.Scan):
                return self._scan(node.input, node.predicate)
            child = self.plan(node.input)
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


_PARTIAL_CONSUMERS = (HashAggregate, Sort, TopN, Distinct)


def parallelize(root: PhysicalNode, partitions: int) -> PhysicalNode:
    """Inserts Gathers below the operators that can merge partial results
    (aggregation, sort, top-N, distinct) and at the root when it is a
    pipeline that filters or joins (so that there is work to split)."""
    _parallelize_inputs(root, partitions)
    path = pipeline_path(root)
    if path is not None and any(isinstance(n, (Filter, _Join)) for n in path):
        return _estimated(Gather(root, partitions, path[-1]), root.estimated_rows)
    return root


def _parallelize_inputs(node: PhysicalNode, partitions: int) -> None:
    for child in node.inputs():
        _parallelize_inputs(child, partitions)
    if isinstance(node, _PARTIAL_CONSUMERS):
        path = pipeline_path(node.input)
        if path is not None:
            node.input = _estimated(Gather(node.input, partitions, path[-1]), node.input.estimated_rows)


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


def plan_statement(statement: b.BoundStatement, options: PlanOptions) -> PhysicalPlan:
    return PhysicalPlanner(statement.ids, options).plan_statement(statement.query)
