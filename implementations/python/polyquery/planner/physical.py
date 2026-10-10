"""Physical plan: concrete operator algorithms, and the planner that chooses
them from a logical plan. Physical plans are what the executor runs and what
``EXPLAIN`` shows (indexes-and-planning.md §4)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..analysis import bound as b
from ..storage.catalog import Column, Table
from . import logical as lp
from .explain import render_expr
from .optimizer import conjunction, conjuncts, optimize
from .planner import LogicalPlanner


@dataclass(eq=False)
class PhysicalNode:
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
    table: Table
    rel: int
    columns: list[int]
    alias: str

    @property
    def layout(self) -> list[b.ColumnKey]:
        return [(self.rel, i) for i in self.columns]

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "table": self.table.name,
            "columns": [self.table.columns[i].name for i in self.columns],
        }
        if self.alias != self.table.name:
            out["alias"] = self.alias
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
    """Builds a hash table on the right input, probes it with the left input."""

    left_keys: list[b.Expr] = field(default_factory=list)
    right_keys: list[b.Expr] = field(default_factory=list)
    residual: b.Expr | None = None

    def expressions(self) -> list[b.Expr]:
        out = self.left_keys + self.right_keys
        return out + [self.residual] if self.residual is not None else out

    def describe(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "join_type": self.join_type,
            "build": "right",
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


@dataclass(eq=False)
class PhysicalPlan:
    root: PhysicalNode
    columns: list[Column]
    # physical plans of the subqueries used in expressions, by Subquery.id
    subplans: dict[int, PhysicalNode]

    def to_json(self) -> dict[str, Any]:
        return _node_json(self.root, self.subplans)


def _node_json(node: PhysicalNode, subplans: dict[int, PhysicalNode]) -> dict[str, Any]:
    out: dict[str, Any] = {"op": node.op, **node.describe()}
    used: list[int] = []
    for expr in node.expressions():
        for sq in b.subqueries(expr):
            if sq.id not in used:
                used.append(sq.id)
    if used:
        out["subqueries"] = [_node_json(subplans[i], subplans) for i in used]
    out["children"] = [_node_json(child, subplans) for child in node.inputs()]
    return out


class PhysicalPlanner:
    def __init__(self, ids: b.IdGenerator, options: PlanOptions):
        self.ids = ids
        self.options = options
        self.subplans: dict[int, PhysicalNode] = {}

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
            return TableScan(node.table, node.rel, node.columns, node.name)
        if isinstance(node, lp.Values):
            return Values()
        if isinstance(node, lp.SubqueryScan):
            return SubqueryScan(self.plan(node.input), node.rel, node.width, node.name)
        if isinstance(node, lp.Filter):
            return Filter(self.plan(node.input), node.predicate)
        if isinstance(node, lp.Join):
            return self._plan_join(node)
        if isinstance(node, lp.Aggregate):
            return HashAggregate(self.plan(node.input), node.rel, node.keys, node.aggregates)
        if isinstance(node, lp.Project):
            return Project(self.plan(node.input), node.rel, node.exprs)
        if isinstance(node, lp.Distinct):
            return Distinct(self.plan(node.input))
        if isinstance(node, lp.Sort):
            return Sort(self.plan(node.input), node.keys)
        if isinstance(node, lp.Limit):
            return Limit(self.plan(node.input), node.limit, node.offset)
        raise AssertionError(f"unknown logical node {type(node).__name__}")

    def _plan_join(self, node: lp.Join) -> PhysicalNode:
        left, right = self.plan(node.left), self.plan(node.right)
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
        return HashJoin(join_type, left, right, left_keys, right_keys, conjunction(residual))


def plan_statement(statement: b.BoundStatement, options: PlanOptions) -> PhysicalPlan:
    return PhysicalPlanner(statement.ids, options).plan_statement(statement.query)
