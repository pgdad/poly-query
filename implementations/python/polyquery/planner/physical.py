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
from .optimizer import conjunction, conjuncts, optimize
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
        columns = [Column(o.name, o.expr.type) for o in query.outputs]
        return PhysicalPlan(root, columns, self.subplans)

    def plan_query(self, query: b.BoundQuery) -> PhysicalNode:
        logical = LogicalPlanner(self.ids).plan_query(query)
        if self.options.optimize:
            logical = optimize(logical)
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
            child = self.plan(node.input)
            rows = child.estimated_rows
            if isinstance(node.limit, b.Literal) and isinstance(node.limit.value, int):
                rows = min(rows, node.limit.value)
            return _estimated(Limit(child, node.limit, node.offset), rows)
        raise AssertionError(f"unknown logical node {type(node).__name__}")

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
        left, right = self.plan(node.left), self.plan(node.right)
        join = self._join(node, left, right)
        rows_l, rows_r = left.estimated_rows, right.estimated_rows
        if node.condition is None:
            rows = rows_l * rows_r
        else:
            rows = rows_l * rows_r * self._selectivity(node.condition)
        if join.join_type == "LEFT":
            rows = max(rows, rows_l)
        return _estimated(join, rows)

    def _join(self, node: lp.Join, left: PhysicalNode, right: PhysicalNode) -> _Join:
        join_type = node.kind if node.condition is not None or node.kind != "INNER" else "CROSS"
        if node.condition is None or self.options.join == "nested_loop":
            return NestedLoopJoin(join_type, left, right, node.condition)
        left_rels, right_rels = node.left.rels(), node.right.rels()
        both = left_rels | right_rels
        left_keys: list[b.Expr] = []
        right_keys: list[b.Expr] = []
        residual: list[b.Expr] = []
        for p in conjuncts(node.condition):
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
            return NestedLoopJoin(join_type, left, right, node.condition)
        # build on the smaller input (inner joins); LEFT joins build on the right
        build = "left" if join_type == "INNER" and left.estimated_rows < right.estimated_rows else "right"
        return HashJoin(join_type, left, right, left_keys, right_keys, conjunction(residual), build)


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
