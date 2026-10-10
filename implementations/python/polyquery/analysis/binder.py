"""Semantic analysis: name resolution, type checking and aggregate extraction
(spec/sql/semantics.md). Produces a :class:`BoundQuery` from the AST."""

from __future__ import annotations

from dataclasses import dataclass, field

from .. import errors, values
from ..datatypes import (
    BOOLEAN,
    DATE,
    FLOAT64,
    INT64,
    NULL,
    STRING,
    TIMESTAMP,
    DataType,
    InvalidTypeError,
    TypeKind,
    resolve_type,
)
from ..names import same_name
from ..sql import ast
from ..storage.catalog import Catalog, Table
from . import bound as b
from . import typing_rules as tr
from .functions import (
    AGGREGATE_FUNCTIONS,
    SCALAR_FUNCTIONS,
    UNIMPLEMENTED_FUNCTIONS,
    aggregate_result_type,
)


def _pos(node: ast.Node) -> dict[str, int]:
    return {"line": node.pos[0], "column": node.pos[1]}


def _with_pos(error: errors.PolyQueryError, node: ast.Node) -> errors.PolyQueryError:
    if error.details is None:
        error.details = _pos(node)
    return error


@dataclass
class Scope:
    """The range variable of a single-table FROM clause (or none)."""

    table: Table | None
    range_name: str | None
    slots: dict[int, int] = field(default_factory=dict)  # table column -> input slot
    scan_columns: list[int] = field(default_factory=list)

    def resolve(self, ref: ast.ColumnRef) -> b.ColumnSlot:
        full = f"{ref.qualifier}.{ref.name}" if ref.qualifier else ref.name
        if self.table is None or self.range_name is None:
            raise errors.semantic_error(f"unknown column '{full}'", **_pos(ref))
        if ref.qualifier is not None and not same_name(ref.qualifier, self.range_name):
            raise errors.semantic_error(f"unknown table or alias '{ref.qualifier}'", **_pos(ref))
        index = self.table.column_index(ref.name)
        if index is None:
            raise errors.semantic_error(f"unknown column '{full}'", **_pos(ref))
        return self.slot_for(index)

    def slot_for(self, index: int) -> b.ColumnSlot:
        assert self.table is not None
        slot = self.slots.get(index)
        if slot is None:
            slot = len(self.scan_columns)
            self.slots[index] = slot
            self.scan_columns.append(index)
        column = self.table.columns[index]
        return b.ColumnSlot(column.type, slot, column.name)


@dataclass
class ExprContext:
    """Rules in force while binding one expression."""

    scope: Scope
    clause: str
    # Aggregated query, outside aggregate arguments: column references are
    # not allowed and aggregate calls are collected here.
    aggregates: list[b.AggCall] | None = None
    aggregates_allowed: bool = False
    in_aggregate: bool = False

    @property
    def columns_allowed(self) -> bool:
        return self.aggregates is None or self.in_aggregate


class Binder:
    def __init__(self, catalog: Catalog, *, test_functions: bool = False):
        self.catalog = catalog
        self.test_functions = test_functions

    # ------------------------------------------------------------ queries

    def bind_query(self, query: ast.Query) -> b.BoundQuery:
        if query.ctes:
            raise errors.unsupported("WITH (common table expressions) is not supported", **_pos(query))
        select = query.body
        if select.group_by:
            raise errors.unsupported("GROUP BY is not supported", **_pos(select.group_by[0]))
        if select.having is not None:
            raise errors.unsupported("HAVING is not supported", **_pos(select.having))

        scope = self._bind_from(select.from_)
        aggregated = any(
            _contains_aggregate(item.expr) for item in select.items if item.expr is not None
        ) or any(_contains_aggregate(item.expr) for item in query.order_by)
        aggregates: list[b.AggCall] = []

        def output_context(clause: str) -> ExprContext:
            if aggregated:
                return ExprContext(scope, clause, aggregates=aggregates, aggregates_allowed=True)
            return ExprContext(scope, clause, aggregates_allowed=True)

        outputs = self._bind_select_items(select.items, scope, output_context("SELECT"))

        where = None
        if select.where is not None:
            where = self.bind_expr(select.where, ExprContext(scope, "WHERE"))
            tr.require_boolean(where, "WHERE condition")

        hidden: list[b.Expr] = []
        order = [
            self._bind_order_item(item, outputs, hidden, select.distinct, output_context("ORDER BY"))
            for item in query.order_by
        ]

        limit = self._bind_limit(query.limit, "LIMIT")
        offset = self._bind_limit(query.offset, "OFFSET")
        return b.BoundQuery(
            table=scope.table,
            scan_columns=scope.scan_columns,
            where=where,
            aggregated=aggregated,
            aggregates=aggregates,
            outputs=outputs,
            hidden=hidden,
            order=order,
            distinct=select.distinct,
            limit=limit,
            offset=offset,
        )

    def _bind_from(self, from_: ast.FromItem | None) -> Scope:
        if from_ is None:
            return Scope(None, None)
        if isinstance(from_, ast.Join):
            raise errors.unsupported("joins are not supported", **_pos(from_))
        if isinstance(from_, ast.DerivedTable):
            raise errors.unsupported("derived tables are not supported", **_pos(from_))
        assert isinstance(from_, ast.TableRef)
        table = self.catalog.get(from_.name)
        if table is None:
            raise errors.semantic_error(f"unknown table '{from_.name}'", **_pos(from_))
        return Scope(table, from_.alias or from_.name)

    def _bind_select_items(
        self, items: list[ast.SelectItem], scope: Scope, ctx: ExprContext
    ) -> list[b.OutputColumn]:
        outputs: list[b.OutputColumn] = []
        for item in items:
            if item.is_star:
                if scope.table is None:
                    raise errors.semantic_error("SELECT * requires a FROM clause", **_pos(item))
                if item.star_qualifier is not None and (
                    not same_name(item.star_qualifier, scope.range_name or "")
                ):
                    raise errors.semantic_error(
                        f"unknown table or alias '{item.star_qualifier}'", **_pos(item)
                    )
                if not ctx.columns_allowed:
                    raise errors.semantic_error(
                        "column references outside aggregate functions are not allowed "
                        "in an aggregated query without GROUP BY",
                        **_pos(item),
                    )
                for index, column in enumerate(scope.table.columns):
                    outputs.append(b.OutputColumn(column.name, scope.slot_for(index)))
                continue
            assert item.expr is not None
            expr = self.bind_expr(item.expr, ctx)
            if item.alias is not None:
                name = item.alias
            elif isinstance(item.expr, ast.ColumnRef) and isinstance(expr, b.ColumnSlot):
                name = expr.name
            else:
                name = f"_col{len(outputs) + 1}"
            outputs.append(b.OutputColumn(name, expr))
        return outputs

    def _bind_order_item(
        self,
        item: ast.OrderItem,
        outputs: list[b.OutputColumn],
        hidden: list[b.Expr],
        distinct: bool,
        ctx: ExprContext,
    ) -> b.SortKey:
        nulls_first = (not item.descending) if item.nulls_first is None else item.nulls_first
        expr = item.expr
        position: int | None = None
        if isinstance(expr, ast.NumberLit) and values.INT_RE.fullmatch(expr.text):
            k = int(expr.text)
            if not 1 <= k <= len(outputs):
                raise errors.semantic_error(f"ORDER BY position {k} is out of range", **_pos(expr))
            position = k - 1
        elif isinstance(expr, ast.ColumnRef) and expr.qualifier is None:
            matches = [i for i, o in enumerate(outputs) if same_name(o.name, expr.name)]
            if matches:
                first = outputs[matches[0]].expr
                if any(outputs[i].expr != first for i in matches[1:]):
                    raise errors.semantic_error(
                        f"ORDER BY name '{expr.name}' is ambiguous", **_pos(expr)
                    )
                position = matches[0]
        if position is None:
            bound_expr = self.bind_expr(expr, ctx)
            for i, o in enumerate(outputs):
                if o.expr == bound_expr:
                    position = i
                    break
            else:
                if distinct:
                    raise errors.semantic_error(
                        "ORDER BY expressions must appear in the select list for SELECT DISTINCT",
                        **_pos(expr),
                    )
                for i, h in enumerate(hidden):
                    if h == bound_expr:
                        position = len(outputs) + i
                        break
                else:
                    hidden.append(bound_expr)
                    position = len(outputs) + len(hidden) - 1
        return b.SortKey(position, item.descending, nulls_first)

    def _bind_limit(self, expr: ast.Expr | None, clause: str) -> b.Expr | None:
        if expr is None:
            return None
        bound_expr = self.bind_expr(expr, ExprContext(Scope(None, None), clause))
        if not b.is_constant(bound_expr):
            raise errors.semantic_error(f"{clause} must be a constant expression", **_pos(expr))
        if bound_expr.type.kind not in (TypeKind.INT64, TypeKind.NULL):
            raise errors.type_error(f"{clause} must be an INT64 expression", **_pos(expr))
        return bound_expr

    # ------------------------------------------------------------ expressions

    def bind_expr(self, node: ast.Expr, ctx: ExprContext) -> b.Expr:
        try:
            method = getattr(self, "_bind_" + type(node).__name__)
        except AttributeError:
            raise errors.unsupported(
                f"{type(node).__name__} expressions are not supported", **_pos(node)
            ) from None
        try:
            return method(node, ctx)
        except errors.PolyQueryError as e:
            raise _with_pos(e, node)

    def _bind_NumberLit(self, node: ast.NumberLit, ctx: ExprContext) -> b.Expr:
        text = node.text
        negative = text.startswith("-")
        digits = text[1:] if negative else text
        if "e" in digits or "E" in digits:
            value = float(text)
            if value in (float("inf"), float("-inf")):
                raise errors.numeric_overflow(f"numeric literal {text[:40]} is out of range")
            return b.Literal(FLOAT64, value)
        if "." in digits:
            info = values.decimal_literal_type(digits)
            if info is None:
                value = float(text)
                if value in (float("inf"), float("-inf")):
                    raise errors.numeric_overflow(f"numeric literal {text[:40]} is out of range")
                return b.Literal(FLOAT64, value)
            unscaled, precision, scale = info
            return b.Literal(
                DataType(TypeKind.DECIMAL, precision, scale), -unscaled if negative else unscaled
            )
        value = values.int_from_digits(text)
        if not values.INT64_MIN <= value <= values.INT64_MAX:
            raise errors.numeric_overflow(f"integer literal {text[:40]} is out of range")
        return b.Literal(INT64, value)

    def _bind_StringLit(self, node: ast.StringLit, ctx: ExprContext) -> b.Expr:
        return b.Literal(STRING, node.value)

    def _bind_BoolLit(self, node: ast.BoolLit, ctx: ExprContext) -> b.Expr:
        return b.Literal(BOOLEAN, node.value)

    def _bind_NullLit(self, node: ast.NullLit, ctx: ExprContext) -> b.Expr:
        return b.Literal(NULL, None)

    def _bind_TypedLit(self, node: ast.TypedLit, ctx: ExprContext) -> b.Expr:
        if node.type_name == "DATE":
            days = values.parse_date(node.text)
            if days is None:
                raise errors.conversion_error(f"invalid DATE literal '{node.text}'")
            return b.Literal(DATE, days)
        micros = values.parse_timestamp(node.text, allow_date=False)
        if micros is None:
            raise errors.conversion_error(f"invalid TIMESTAMP literal '{node.text}'")
        return b.Literal(TIMESTAMP, micros)

    def _bind_ColumnRef(self, node: ast.ColumnRef, ctx: ExprContext) -> b.Expr:
        slot = ctx.scope.resolve(node)
        if not ctx.columns_allowed:
            raise errors.semantic_error(
                f"column '{node.name}' must be used inside an aggregate function "
                "(GROUP BY is required for non-aggregated columns)"
            )
        return slot

    def _bind_UnaryOp(self, node: ast.UnaryOp, ctx: ExprContext) -> b.Expr:
        operand = self.bind_expr(node.operand, ctx)
        if node.op == "NOT":
            tr.require_boolean(operand, "operand of NOT")
            return b.Not(BOOLEAN, operand)
        return tr.negate(node.op, operand)

    def _bind_BinaryOp(self, node: ast.BinaryOp, ctx: ExprContext) -> b.Expr:
        left = self.bind_expr(node.left, ctx)
        right = self.bind_expr(node.right, ctx)
        op = node.op
        if op in ("AND", "OR"):
            return tr.logical(op, left, right)
        if op == "||":
            return tr.concat(left, right)
        if op in ("+", "-", "*", "/", "%"):
            return tr.arithmetic(op, left, right)
        return tr.comparison(op, left, right)

    def _bind_IsNull(self, node: ast.IsNull, ctx: ExprContext) -> b.Expr:
        return b.IsNull(BOOLEAN, self.bind_expr(node.operand, ctx), node.negated)

    def _bind_Cast(self, node: ast.Cast, ctx: ExprContext) -> b.Expr:
        operand = self.bind_expr(node.operand, ctx)
        try:
            target = resolve_type(node.target.name, node.target.params)
        except InvalidTypeError as e:
            raise errors.semantic_error(str(e), **_pos(node.target)) from None
        tr.check_cast(operand.type, target)
        return b.Cast(target, operand)

    def _bind_Between(self, node: ast.Between, ctx: ExprContext) -> b.Expr:
        raise errors.unsupported("BETWEEN is not supported")

    def _bind_InList(self, node: ast.InList, ctx: ExprContext) -> b.Expr:
        raise errors.unsupported("IN is not supported")

    def _bind_Like(self, node: ast.Like, ctx: ExprContext) -> b.Expr:
        raise errors.unsupported("LIKE is not supported")

    def _bind_Case(self, node: ast.Case, ctx: ExprContext) -> b.Expr:
        raise errors.unsupported("CASE is not supported")

    def _bind_FunctionCall(self, node: ast.FunctionCall, ctx: ExprContext) -> b.Expr:
        name = node.name.upper()
        if name in AGGREGATE_FUNCTIONS:
            return self._bind_aggregate(name, node, ctx)
        function = SCALAR_FUNCTIONS.get(name)
        if function is None or (function.test_only and not self.test_functions):
            if name in UNIMPLEMENTED_FUNCTIONS:
                raise errors.unsupported(f"function {name} is not supported")
            raise errors.semantic_error(f"unknown function '{node.name}'")
        if node.star or node.distinct:
            raise errors.semantic_error(f"invalid use of '*' or DISTINCT with {name}")
        if not function.min_args <= len(node.args) <= function.max_args:
            raise errors.semantic_error(f"wrong number of arguments for {name}")
        args = [self.bind_expr(a, ctx) for a in node.args]
        result_type = function.resolve(args)
        return b.Function(result_type, name, tuple(args))

    def _bind_aggregate(self, name: str, node: ast.FunctionCall, ctx: ExprContext) -> b.Expr:
        if not ctx.aggregates_allowed:
            raise errors.semantic_error(f"aggregate function {name} is not allowed in {ctx.clause}")
        if ctx.in_aggregate:
            raise errors.semantic_error("aggregate function calls cannot be nested")
        if node.star:
            if name != "COUNT":
                raise errors.semantic_error(f"{name}(*) is not allowed")
            arg = None
        else:
            if len(node.args) != 1:
                raise errors.semantic_error(f"{name} takes exactly one argument")
            inner = ExprContext(
                ctx.scope, ctx.clause, ctx.aggregates, aggregates_allowed=True, in_aggregate=True
            )
            arg = self.bind_expr(node.args[0], inner)
        call = b.AggCall(aggregate_result_type(name, arg), name, arg, node.distinct)
        assert ctx.aggregates is not None
        for i, existing in enumerate(ctx.aggregates):
            if existing == call:
                return b.AggRef(call.type, i)
        ctx.aggregates.append(call)
        return b.AggRef(call.type, len(ctx.aggregates) - 1)

    def _bind_ScalarSubquery(self, node: ast.ScalarSubquery, ctx: ExprContext) -> b.Expr:
        raise errors.unsupported("subqueries are not supported")

    def _bind_Exists(self, node: ast.Exists, ctx: ExprContext) -> b.Expr:
        raise errors.unsupported("subqueries are not supported")

    def _bind_InSubquery(self, node: ast.InSubquery, ctx: ExprContext) -> b.Expr:
        raise errors.unsupported("subqueries are not supported")


def _contains_aggregate(node: ast.Expr | None) -> bool:
    """Whether an expression contains an aggregate call (not looking into subqueries)."""
    if node is None:
        return False
    if isinstance(node, ast.FunctionCall):
        if node.name.upper() in AGGREGATE_FUNCTIONS:
            return True
        return any(_contains_aggregate(a) for a in node.args)
    if isinstance(node, (ast.ScalarSubquery, ast.Exists)):
        return False
    for value in vars(node).values():
        if isinstance(value, ast.Expr) and _contains_aggregate(value):
            return True
        if isinstance(value, list):
            for v in value:
                if isinstance(v, ast.Expr) and _contains_aggregate(v):
                    return True
                if isinstance(v, tuple) and any(_contains_aggregate(x) for x in v):
                    return True
    return False
