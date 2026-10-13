"""Semantic analysis: name resolution, type checking, aggregate extraction and
grouping validation (spec/sql/semantics.md). Produces a :class:`BoundQuery`
tree from the AST."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .. import errors, values
from ..limits import Check, no_check
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
from ..names import fold, same_name
from ..sql import ast
from ..storage.catalog import Catalog, CatalogSnapshot
from . import bound as b
from . import typing_rules as tr
from .functions import (
    AGGREGATE_FUNCTIONS,
    SCALAR_FUNCTIONS,
    ConstEvaluator,
    aggregate_result_type,
)
from .scope import CteDef, CteEnv, RangeVar, Scope, pos


def _with_pos(error: errors.PolyQueryError, node: ast.Node) -> errors.PolyQueryError:
    if error.details is None:
        error.details = pos(node)
    return error


@dataclass
class ExprContext:
    """Rules in force while binding one expression."""

    scope: Scope
    clause: str
    aggregates_allowed: bool = False
    in_aggregate: bool = False


@dataclass
class _SelectEntry:
    """A select-list item after ``*`` expansion."""

    node: ast.Node
    expr_ast: ast.Expr | None  # None for columns produced by '*'
    alias: str | None
    star_column: b.ColumnRef | None = None
    # bound expression when the item is referenced by GROUP BY alias/ordinal
    group_expr: b.Expr | None = None


class Binder:
    def __init__(
        self,
        catalog: Catalog | CatalogSnapshot,
        evaluate_constant: ConstEvaluator,
        *,
        test_functions: bool = False,
        check: Check = no_check,
    ):
        self.catalog = catalog
        self.evaluate_constant = evaluate_constant
        self.test_functions = test_functions
        # the statement's deadline check, made at every expression node
        self.check = check
        self.ids = b.IdGenerator()
        self.fingerprints = ast.Fingerprints()

    def bind_statement(self, query: ast.Query) -> b.BoundStatement:
        bound, _ = self.bind_query(query, None, None)
        return b.BoundStatement(bound, self.ids)

    # ------------------------------------------------------------ queries

    def bind_query(
        self,
        query: ast.Query,
        parent: Scope | None,
        ctes: CteEnv | None,
        *,
        opaque: bool = False,
    ) -> tuple[b.BoundQuery, Scope]:
        self.check()
        scope = Scope(parent, ctes, opaque_parent=opaque)
        if query.ctes:
            scope.ctes = self._bind_ctes(query.ctes, scope)
        if isinstance(query.body, ast.Compound):
            return self._bind_compound(query, query.body, scope), scope
        select = query.body

        from_ = self._bind_from(select.from_, scope) if select.from_ is not None else None

        where = None
        if select.where is not None:
            where = self.bind_expr(select.where, ExprContext(scope, "WHERE"))
            tr.require_boolean(where, "WHERE condition")

        entries = self._expand_select_list(select.items, scope)
        aggregated = (
            bool(select.group_by)
            or select.having is not None
            or any(_contains_aggregate(e.expr_ast) for e in entries)
            or any(_contains_aggregate(item.expr) for item in query.order_by)
        )
        if aggregated:
            return self._bind_aggregated(query, scope, from_, where, entries), scope

        out_ctx = ExprContext(scope, "SELECT", aggregates_allowed=True)
        outputs = [self._bind_output(e, i, out_ctx) for i, e in enumerate(entries)]
        hidden: list[b.Expr] = []
        order_ctx = ExprContext(scope, "ORDER BY", aggregates_allowed=True)
        order = [
            self._bind_order_item(item, outputs, hidden, select.distinct, order_ctx, None)
            for item in query.order_by
        ]
        return (
            b.BoundQuery(
                from_=from_,
                where=where,
                aggregation=None,
                having=None,
                outputs=outputs,
                hidden=hidden,
                order=order,
                distinct=select.distinct,
                limit=self._bind_limit(query.limit, "LIMIT"),
                offset=self._bind_limit(query.offset, "OFFSET"),
            ),
            scope,
        )

    def _bind_compound(self, query: ast.Query, compound: ast.Compound, scope: Scope) -> b.BoundQuery:
        """``b1 UNION ALL b2 …`` as a query over a :class:`b.UnionRelation`:
        every branch is bound like a subquery of ``scope`` (which has no range
        variables of its own, so correlated references pass through it), the
        output columns take the first branch's names and the common types,
        and ORDER BY may only name output columns (spec/changes/union-all.md)."""
        branches = [self.bind_query(ast.Query(s.pos, s), scope, scope.ctes)[0] for s in compound.branches]
        width = len(branches[0].outputs)
        for select, branch in zip(compound.branches[1:], branches[1:]):
            if len(branch.outputs) != width:
                raise errors.semantic_error(
                    f"each UNION ALL branch must have {width} columns, got {len(branch.outputs)}",
                    **pos(select),
                )
        types = []
        for i in range(width):
            column_types = [branch.outputs[i].expr.type for branch in branches]
            common = tr.union_type(column_types)
            if common is None:
                names = ", ".join(t.name for t in column_types)
                raise errors.type_error(
                    f"UNION ALL column {i + 1} has incompatible types ({names})", **pos(compound)
                )
            types.append(common)
        relation = b.UnionRelation(self.ids.next(), branches, types)
        outputs = [
            b.OutputColumn(o.name, b.ColumnRef(t, relation.rel, i, o.name))
            for i, (o, t) in enumerate(zip(branches[0].outputs, types))
        ]
        order = []
        for item in query.order_by:
            position = self._output_position(item.expr, outputs)
            if position is None:
                raise errors.semantic_error(
                    "ORDER BY of a UNION ALL query must be an output column name or position",
                    **pos(item.expr),
                )
            nulls_first = (not item.descending) if item.nulls_first is None else item.nulls_first
            order.append(b.SortKey(position, item.descending, nulls_first))
        return b.BoundQuery(
            from_=relation,
            where=None,
            aggregation=None,
            having=None,
            outputs=outputs,
            hidden=[],
            order=order,
            distinct=False,
            limit=self._bind_limit(query.limit, "LIMIT"),
            offset=self._bind_limit(query.offset, "OFFSET"),
        )

    def _bind_aggregated(
        self,
        query: ast.Query,
        scope: Scope,
        from_: b.Relation | None,
        where: b.Expr | None,
        entries: list[_SelectEntry],
    ) -> b.BoundQuery:
        select = query.body
        group_ctx = ExprContext(scope, "GROUP BY")
        keys: list[b.Expr] = []
        for node in select.group_by:
            key = self._bind_group_key(node, entries, group_ctx)
            if key not in keys:
                keys.append(key)

        aggregation = b.Aggregation(self.ids.next(), keys, [])
        local_rels = scope.local_rels()

        def finish(expr: b.Expr, node: ast.Node) -> b.Expr:
            result = _substitute_grouped(expr, aggregation)
            for e in b.walk(result):
                if isinstance(e, b.ColumnRef) and e.rel in local_rels:
                    raise errors.semantic_error(
                        f"column '{e.name}' must appear in GROUP BY or be used in an "
                        "aggregate function",
                        **pos(node),
                    )
            return result

        out_ctx = ExprContext(scope, "SELECT", aggregates_allowed=True)
        outputs = []
        for i, entry in enumerate(entries):
            column = self._bind_output(entry, i, out_ctx)
            column.expr = finish(column.expr, entry.node)
            outputs.append(column)

        having = None
        if select.having is not None:
            having_ctx = ExprContext(scope, "HAVING", aggregates_allowed=True)
            having = finish(self.bind_expr(select.having, having_ctx), select.having)
            tr.require_boolean(having, "HAVING condition")

        hidden: list[b.Expr] = []
        order_ctx = ExprContext(scope, "ORDER BY", aggregates_allowed=True)
        order = [
            self._bind_order_item(item, outputs, hidden, select.distinct, order_ctx, finish)
            for item in query.order_by
        ]
        return b.BoundQuery(
            from_=from_,
            where=where,
            aggregation=aggregation,
            having=having,
            outputs=outputs,
            hidden=hidden,
            order=order,
            distinct=select.distinct,
            limit=self._bind_limit(query.limit, "LIMIT"),
            offset=self._bind_limit(query.offset, "OFFSET"),
        )

    def _bind_group_key(
        self, node: ast.Expr, entries: list[_SelectEntry], ctx: ExprContext
    ) -> b.Expr:
        if _is_ordinal(node):
            assert isinstance(node, ast.NumberLit)
            k = int(node.text)
            if not 1 <= k <= len(entries):
                raise errors.semantic_error(f"GROUP BY position {k} is out of range", **pos(node))
            return self._bind_entry_expr(entries[k - 1], ctx)
        if isinstance(node, ast.ColumnRef) and node.qualifier is None:
            if not self._resolves_locally(node, ctx.scope):
                for entry in entries:
                    if entry.alias is not None and same_name(entry.alias, node.name):
                        return self._bind_entry_expr(entry, ctx)
        return self.bind_expr(node, ctx)

    def _bind_entry_expr(self, entry: _SelectEntry, ctx: ExprContext) -> b.Expr:
        if entry.star_column is not None:
            return entry.star_column
        assert entry.expr_ast is not None
        if entry.group_expr is None:
            entry.group_expr = self.bind_expr(entry.expr_ast, ctx)
        return entry.group_expr

    @staticmethod
    def _resolves_locally(node: ast.ColumnRef, scope: Scope) -> bool:
        return any(rv.find(node.name) for rv in scope.range_vars)

    def _bind_ctes(self, ctes: list[ast.CommonTableExpr], scope: Scope) -> CteEnv:
        env = CteEnv({}, scope.ctes)
        for cte in ctes:
            key = fold(cte.name)
            if key in env.definitions:
                raise errors.semantic_error(f"duplicate CTE name '{cte.name}'", **pos(cte))
            # the CTE sees the earlier CTEs of this WITH, not itself
            query, _ = self.bind_query(cte.query, scope, env, opaque=True)
            names = [o.name for o in query.outputs]
            if cte.column_names is not None:
                if len(cte.column_names) != len(names):
                    raise errors.semantic_error(
                        f"CTE '{cte.name}' has {len(names)} columns but "
                        f"{len(cte.column_names)} column names were given",
                        **pos(cte),
                    )
                names = list(cte.column_names)
            env.definitions[key] = CteDef(cte.name, query, names)
        return env

    # ------------------------------------------------------------ FROM

    def _bind_from(self, item: ast.FromItem, scope: Scope) -> b.Relation:
        if isinstance(item, ast.Join):
            left = self._bind_from(item.left, scope)
            right = self._bind_from(item.right, scope)
            condition = None
            if item.condition is not None:
                condition = self.bind_expr(item.condition, ExprContext(scope, "ON"))
                tr.require_boolean(condition, "join condition")
            return b.JoinRelation(item.kind, left, right, condition)
        if isinstance(item, ast.DerivedTable):
            query, _ = self.bind_query(item.query, scope, scope.ctes, opaque=True)
            names = [o.name for o in query.outputs]
            relation: b.TableRelation | b.DerivedRelation = b.DerivedRelation(
                self.ids.next(), query, item.alias
            )
            scope.add(RangeVar(relation.rel, item.alias, names, query.column_types, relation), item)
            return relation
        assert isinstance(item, ast.TableRef)
        name = item.alias or item.name
        cte = scope.ctes.lookup(item.name) if scope.ctes is not None else None
        if cte is not None:
            relation = b.DerivedRelation(self.ids.next(), cte.query, name, cte=cte.name)
            rv = RangeVar(relation.rel, name, cte.column_names, cte.query.column_types, relation)
        else:
            table = self.catalog.get(item.name)
            if table is None:
                raise errors.semantic_error(f"unknown table '{item.name}'", **pos(item))
            relation = b.TableRelation(self.ids.next(), table, name)
            rv = RangeVar(
                relation.rel,
                name,
                [c.name for c in table.columns],
                [c.type for c in table.columns],
                relation,
            )
        scope.add(rv, item)
        return relation

    # ------------------------------------------------------------ SELECT list

    def _expand_select_list(self, items: list[ast.SelectItem], scope: Scope) -> list[_SelectEntry]:
        entries: list[_SelectEntry] = []
        for item in items:
            if not item.is_star:
                entries.append(_SelectEntry(item, item.expr, item.alias))
                continue
            if not scope.range_vars:
                raise errors.semantic_error("SELECT * requires a FROM clause", **pos(item))
            if item.star_qualifier is not None:
                rv = scope.find_range_var(item.star_qualifier)
                if rv is None:
                    raise errors.semantic_error(
                        f"unknown table or alias '{item.star_qualifier}'", **pos(item)
                    )
                range_vars = [rv]
            else:
                range_vars = scope.range_vars
            for rv in range_vars:
                for index, name in enumerate(rv.column_names):
                    entries.append(_SelectEntry(item, None, name, rv.column(index)))
        return entries

    def _bind_output(self, entry: _SelectEntry, position: int, ctx: ExprContext) -> b.OutputColumn:
        if entry.star_column is not None:
            return b.OutputColumn(entry.star_column.name, entry.star_column)
        assert entry.expr_ast is not None
        # reuse the GROUP BY binding so that the item matches its grouping key
        # even if it contains subqueries (which compare by identity)
        expr = entry.group_expr or self.bind_expr(entry.expr_ast, ctx)
        if entry.alias is not None:
            name = entry.alias
        elif isinstance(entry.expr_ast, ast.ColumnRef) and isinstance(expr, b.ColumnRef):
            name = expr.name
        else:
            name = f"_col{position + 1}"
        return b.OutputColumn(name, expr)

    def _bind_order_item(
        self,
        item: ast.OrderItem,
        outputs: list[b.OutputColumn],
        hidden: list[b.Expr],
        distinct: bool,
        ctx: ExprContext,
        finish: Any,
    ) -> b.SortKey:
        nulls_first = (not item.descending) if item.nulls_first is None else item.nulls_first
        expr = item.expr
        position = self._output_position(expr, outputs)
        if position is None:
            bound_expr = self.bind_expr(expr, ctx)
            if finish is not None:
                bound_expr = finish(bound_expr, expr)
            for i, o in enumerate(outputs):
                if o.expr == bound_expr:
                    position = i
                    break
            else:
                if distinct:
                    raise errors.semantic_error(
                        "ORDER BY expressions must appear in the select list for SELECT DISTINCT",
                        **pos(expr),
                    )
                for i, h in enumerate(hidden):
                    if h == bound_expr:
                        position = len(outputs) + i
                        break
                else:
                    hidden.append(bound_expr)
                    position = len(outputs) + len(hidden) - 1
        return b.SortKey(position, item.descending, nulls_first)

    @staticmethod
    def _output_position(expr: ast.Expr, outputs: list[b.OutputColumn]) -> int | None:
        """The output column an ORDER BY item denotes by 1-based position or
        by (unqualified) output name; None if it is neither."""
        if _is_ordinal(expr):
            assert isinstance(expr, ast.NumberLit)
            k = int(expr.text)
            if not 1 <= k <= len(outputs):
                raise errors.semantic_error(f"ORDER BY position {k} is out of range", **pos(expr))
            return k - 1
        if isinstance(expr, ast.ColumnRef) and expr.qualifier is None:
            matches = [i for i, o in enumerate(outputs) if same_name(o.name, expr.name)]
            if matches:
                first = outputs[matches[0]].expr
                if any(outputs[i].expr != first for i in matches[1:]):
                    raise errors.semantic_error(
                        f"ORDER BY name '{expr.name}' is ambiguous", **pos(expr)
                    )
                return matches[0]
        return None

    def _bind_limit(self, expr: ast.Expr | None, clause: str) -> b.Expr | None:
        if expr is None:
            return None
        bound_expr = self.bind_expr(expr, ExprContext(Scope(None, None), clause))
        if not b.is_constant(bound_expr):
            raise errors.semantic_error(f"{clause} must be a constant expression", **pos(expr))
        if bound_expr.type.kind not in (TypeKind.INT64, TypeKind.NULL):
            raise errors.type_error(f"{clause} must be an INT64 expression", **pos(expr))
        value = self.evaluate_constant(bound_expr)
        if value is not None and value < 0:
            raise errors.invalid_argument(f"{clause} must not be negative", **pos(expr))
        return bound_expr

    # ------------------------------------------------------------ expressions

    def bind_expr(self, node: ast.Expr, ctx: ExprContext) -> b.Expr:
        self.check()
        method = getattr(self, "_bind_" + type(node).__name__)
        try:
            return method(node, ctx)
        except errors.PolyQueryError as e:
            raise _with_pos(e, node)

    def _bind_NumberLit(self, node: ast.NumberLit, ctx: ExprContext) -> b.Expr:
        text = node.text
        negative = text.startswith("-")
        digits = text[1:] if negative else text
        if "e" in digits or "E" in digits:
            return b.Literal(FLOAT64, _float_literal(text))
        if "." in digits:
            info = values.decimal_literal_type(digits)
            if info is None:
                return b.Literal(FLOAT64, _float_literal(text))
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
        return ctx.scope.resolve(node)

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
            raise errors.semantic_error(str(e), **pos(node.target)) from None
        tr.check_cast(operand.type, target)
        return b.Cast(target, operand)

    def _bind_Between(self, node: ast.Between, ctx: ExprContext) -> b.Expr:
        return tr.between(
            self.bind_expr(node.operand, ctx),
            self.bind_expr(node.low, ctx),
            self.bind_expr(node.high, ctx),
            node.negated,
        )

    def _bind_InList(self, node: ast.InList, ctx: ExprContext) -> b.Expr:
        operand = self.bind_expr(node.operand, ctx)
        items = [self.bind_expr(item, ctx) for item in node.items]
        return tr.in_list(operand, items, node.negated)

    def _bind_Like(self, node: ast.Like, ctx: ExprContext) -> b.Expr:
        return tr.like(
            self.bind_expr(node.operand, ctx), self.bind_expr(node.pattern, ctx), node.negated
        )

    def _bind_Case(self, node: ast.Case, ctx: ExprContext) -> b.Expr:
        operand = self.bind_expr(node.operand, ctx) if node.operand is not None else None
        whens = []
        for cond_node, result_node in node.whens:
            cond = self.bind_expr(cond_node, ctx)
            if operand is not None:
                # simple CASE x WHEN v ... is CASE WHEN x = v ...
                try:
                    cond = tr.comparison("=", operand, cond)
                except errors.PolyQueryError as e:
                    raise _with_pos(e, cond_node)
            whens.append((cond, self.bind_expr(result_node, ctx)))
        else_ = self.bind_expr(node.else_, ctx) if node.else_ is not None else None
        return tr.case(whens, else_)

    def _bind_FunctionCall(self, node: ast.FunctionCall, ctx: ExprContext) -> b.Expr:
        name = node.name.upper()
        if name in AGGREGATE_FUNCTIONS:
            return self._bind_aggregate(name, node, ctx)
        function = SCALAR_FUNCTIONS.get(name)
        if function is None or (function.test_only and not self.test_functions):
            raise errors.semantic_error(f"unknown function '{node.name}'")
        if node.star or node.distinct:
            raise errors.semantic_error(f"invalid use of '*' or DISTINCT with {name}")
        n = len(node.args)
        if n < function.min_args or (function.max_args is not None and n > function.max_args):
            raise errors.semantic_error(f"wrong number of arguments for {name}")
        args = [self.bind_expr(a, ctx) for a in node.args]
        result_type, args = function.resolve(args, self.evaluate_constant)
        return b.Function(result_type, name, tuple(args))

    def _bind_aggregate(self, name: str, node: ast.FunctionCall, ctx: ExprContext) -> b.Expr:
        if not ctx.aggregates_allowed:
            raise errors.semantic_error(f"aggregate function {name} is not allowed in {ctx.clause}")
        if ctx.in_aggregate:
            raise errors.semantic_error("aggregate function calls cannot be nested")
        if node.star:
            if name != "COUNT":
                raise errors.semantic_error(f"{name}(*) is not allowed")
            return b.AggCall(INT64, name, None, False)
        if len(node.args) != 1:
            raise errors.semantic_error(f"{name} takes exactly one argument")
        inner = ExprContext(ctx.scope, ctx.clause, aggregates_allowed=True, in_aggregate=True)
        arg = self.bind_expr(node.args[0], inner)
        return b.AggCall(aggregate_result_type(name, arg), name, arg, node.distinct)

    # ------------------------------------------------------------ subqueries

    def _bind_subquery(self, query: ast.Query, ctx: ExprContext) -> tuple[b.Subquery, tuple]:
        bound, scope = self.bind_query(query, ctx.scope, ctx.scope.ctes)
        subquery = b.Subquery(
            self.ids.next(), bound, tuple(scope.outer_refs), self.fingerprints.of(query)
        )
        return subquery, tuple(scope.outer_refs.values())

    def _bind_ScalarSubquery(self, node: ast.ScalarSubquery, ctx: ExprContext) -> b.Expr:
        subquery, args = self._bind_subquery(node.query, ctx)
        outputs = subquery.query.outputs
        if len(outputs) != 1:
            raise errors.semantic_error("a scalar subquery must return exactly one column")
        return b.ScalarSubquery(outputs[0].expr.type, subquery, args)

    def _bind_Exists(self, node: ast.Exists, ctx: ExprContext) -> b.Expr:
        subquery, args = self._bind_subquery(node.query, ctx)
        return b.Exists(BOOLEAN, subquery, args)

    def _bind_InSubquery(self, node: ast.InSubquery, ctx: ExprContext) -> b.Expr:
        operand = self.bind_expr(node.operand, ctx)
        subquery, args = self._bind_subquery(node.query, ctx)
        outputs = subquery.query.outputs
        if len(outputs) != 1:
            raise errors.semantic_error("an IN subquery must return exactly one column")
        common = tr.in_subquery_type(operand, outputs[0].expr.type)
        return b.InSubquery(
            BOOLEAN, subquery, args, operand=tr.promote(operand, common), negated=node.negated
        )


# ------------------------------------------------------------------ helpers


def _float_literal(text: str) -> float:
    value = float(text)
    if value in (float("inf"), float("-inf")):
        raise errors.numeric_overflow(f"numeric literal {text[:40]} is out of range")
    return value


def _is_ordinal(node: ast.Expr) -> bool:
    """An unsigned integer literal (a folded negative literal is not an ordinal)."""
    return (
        isinstance(node, ast.NumberLit)
        and values.INT_RE.fullmatch(node.text) is not None
        and node.text[0] not in "+-"
    )


def _substitute_grouped(expr: b.Expr, aggregation: b.Aggregation) -> b.Expr:
    """Replaces GROUP BY expressions and aggregate calls by references to the
    Aggregate operator's output (semantics.md §5)."""
    for i, key in enumerate(aggregation.keys):
        if expr == key:
            name = expr.name if isinstance(expr, b.ColumnRef) else f"key{i}"
            return b.ColumnRef(expr.type, aggregation.rel, i, name)
    if isinstance(expr, b.AggCall):
        aggregates = aggregation.aggregates
        try:
            index = aggregates.index(expr)
        except ValueError:
            aggregates.append(expr)
            index = len(aggregates) - 1
        return b.ColumnRef(expr.type, aggregation.rel, len(aggregation.keys) + index, expr.name)
    return b.map_children(expr, lambda child: _substitute_grouped(child, aggregation))


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
