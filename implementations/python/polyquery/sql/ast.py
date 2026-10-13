"""Abstract syntax tree for PolyQuery SQL v1 (spec/sql/grammar.md §2).

The parser covers the complete v1 grammar; which constructs are executable is
decided during semantic analysis.
"""

from __future__ import annotations

from dataclasses import dataclass, field

Pos = tuple[int, int]  # (line, column), 1-based


@dataclass(eq=False)
class Node:
    pos: Pos


# ------------------------------------------------------------------ expressions


@dataclass(eq=False)
class Expr(Node):
    pass


@dataclass(eq=False)
class NumberLit(Expr):
    text: str  # literal text, possibly prefixed with '-' when unary minus was folded


@dataclass(eq=False)
class StringLit(Expr):
    value: str


@dataclass(eq=False)
class BoolLit(Expr):
    value: bool


@dataclass(eq=False)
class NullLit(Expr):
    pass


@dataclass(eq=False)
class TypedLit(Expr):
    """``DATE '...'`` or ``TIMESTAMP '...'``."""

    type_name: str
    text: str


@dataclass(eq=False)
class ColumnRef(Expr):
    qualifier: str | None
    name: str


@dataclass(eq=False)
class UnaryOp(Expr):
    op: str  # '-', '+', 'NOT'
    operand: Expr


@dataclass(eq=False)
class BinaryOp(Expr):
    op: str  # + - * / % || = <> < <= > >= AND OR
    left: Expr
    right: Expr


@dataclass(eq=False)
class IsNull(Expr):
    operand: Expr
    negated: bool


@dataclass(eq=False)
class Between(Expr):
    operand: Expr
    low: Expr
    high: Expr
    negated: bool


@dataclass(eq=False)
class InList(Expr):
    operand: Expr
    items: list[Expr]
    negated: bool


@dataclass(eq=False)
class InSubquery(Expr):
    operand: Expr
    query: Query
    negated: bool


@dataclass(eq=False)
class Like(Expr):
    operand: Expr
    pattern: Expr
    negated: bool


@dataclass(eq=False)
class FunctionCall(Expr):
    name: str
    args: list[Expr]
    distinct: bool = False
    star: bool = False  # COUNT(*)


@dataclass(eq=False)
class TypeName(Node):
    name: str
    params: list[int]


@dataclass(eq=False)
class Cast(Expr):
    operand: Expr
    target: TypeName


@dataclass(eq=False)
class Case(Expr):
    operand: Expr | None
    whens: list[tuple[Expr, Expr]]
    else_: Expr | None


@dataclass(eq=False)
class Exists(Expr):
    query: Query


@dataclass(eq=False)
class ScalarSubquery(Expr):
    query: Query


# ------------------------------------------------------------------ queries


@dataclass(eq=False)
class SelectItem(Node):
    expr: Expr | None  # None for '*' / 'r.*'
    alias: str | None = None
    star_qualifier: str | None = None
    is_star: bool = False


@dataclass(eq=False)
class FromItem(Node):
    pass


@dataclass(eq=False)
class TableRef(FromItem):
    name: str
    alias: str | None


@dataclass(eq=False)
class DerivedTable(FromItem):
    query: Query
    alias: str


@dataclass(eq=False)
class Join(FromItem):
    kind: str  # 'INNER', 'LEFT', 'CROSS'
    left: FromItem
    right: FromItem
    condition: Expr | None


@dataclass(eq=False)
class OrderItem(Node):
    expr: Expr
    descending: bool = False
    nulls_first: bool | None = None  # None = default for the direction


@dataclass(eq=False)
class CommonTableExpr(Node):
    name: str
    column_names: list[str] | None
    query: Query


@dataclass(eq=False)
class Select(Node):
    items: list[SelectItem]
    distinct: bool = False
    from_: FromItem | None = None
    where: Expr | None = None
    group_by: list[Expr] = field(default_factory=list)
    having: Expr | None = None


@dataclass(eq=False)
class Compound(Node):
    """``select_core UNION ALL select_core …`` (spec/changes/union-all.md)."""

    branches: list[Select]


@dataclass(eq=False)
class Query(Node):
    body: Select | Compound
    ctes: list[CommonTableExpr] = field(default_factory=list)
    order_by: list[OrderItem] = field(default_factory=list)
    limit: Expr | None = None
    offset: Expr | None = None


class Fingerprints:
    """Structural ids of AST subtrees (positions ignored): two subtrees get
    the same id from one instance iff they are textually equivalent.

    Each node is fingerprinted once (nested subqueries fingerprint their
    inner subqueries again), and a node's key refers to its children by
    their ids, so the work stays linear in the size of the statement."""

    def __init__(self) -> None:
        self._ids: dict[tuple, int] = {}
        self._memo: dict[int, tuple[Node, int]] = {}  # id(node) -> (node, its id)

    def of(self, node: object) -> object:
        if isinstance(node, Node):
            memo = self._memo.get(id(node))
            if memo is not None and memo[0] is node:
                return memo[1]
            key = (type(node).__name__,) + tuple(
                (k, self.of(v)) for k, v in vars(node).items() if k != "pos"
            )
            fp = self._ids.setdefault(key, len(self._ids))
            self._memo[id(node)] = (node, fp)
            return fp
        if isinstance(node, (list, tuple)):
            return tuple(self.of(v) for v in node)
        return node


# ------------------------------------------------------------------ statements


@dataclass(eq=False)
class Statement(Node):
    pass


@dataclass(eq=False)
class QueryStatement(Statement):
    query: Query


@dataclass(eq=False)
class Explain(Statement):
    query: Query


@dataclass(eq=False)
class CreateIndex(Statement):
    name: str
    table: str
    column: str
    kind: str  # 'BTREE' or 'HASH'
    if_not_exists: bool


@dataclass(eq=False)
class DropIndex(Statement):
    name: str
    if_exists: bool
