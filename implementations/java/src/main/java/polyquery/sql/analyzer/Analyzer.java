package polyquery.sql.analyzer;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;
import polyquery.sql.ast.Expr;
import polyquery.sql.ast.Query;
import polyquery.storage.Catalog;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/** Semantic analysis of a query: name resolution, typing and clause validation (semantics.md). */
public final class Analyzer {
    private final Catalog catalog;
    private final FunctionRegistry functions;

    public Analyzer(Catalog catalog, FunctionRegistry functions) {
        this.catalog = catalog;
        this.functions = functions;
    }

    private static PolyQueryException semantic(String fmt, Object... args) {
        return PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, fmt, args);
    }

    private static PolyQueryException unsupported(String feature) {
        return PolyQueryException.of(ErrorCode.UNSUPPORTED, "%s is not supported by this engine", feature);
    }

    public BoundQuery analyze(Query q) {
        if (!q.with().isEmpty()) {
            throw unsupported("WITH");
        }
        Query.Select sel = q.select();
        if (sel.distinct()) {
            throw unsupported("SELECT DISTINCT");
        }
        if (!sel.groupBy().isEmpty()) {
            throw unsupported("GROUP BY");
        }
        if (sel.having() != null) {
            throw unsupported("HAVING");
        }

        // FROM
        Scope scope = Scope.empty();
        LogicalPlan source;
        if (sel.from() == null) {
            source = new LogicalPlan.SingleRow();
        } else if (sel.from() instanceof Query.TableRef ref) {
            Table table = catalog.find(ref.name());
            if (table == null) {
                throw semantic("unknown table '%s'", ref.name());
            }
            String rangeName = ref.alias() != null ? ref.alias() : ref.name();
            scope.add(rangeName, table.columns());
            source = new LogicalPlan.Scan(table, rangeName);
        } else if (sel.from() instanceof Query.Join) {
            throw unsupported("JOIN");
        } else {
            throw unsupported("derived tables");
        }

        // WHERE
        BoundExpr where = null;
        if (sel.where() != null) {
            where = new ExpressionBinder(scope, functions, null, "WHERE").bind(sel.where());
            requireCondition(where, "WHERE");
        }

        boolean aggregated = containsAggregate(sel, q.orderBy());
        AggregateCollector aggs = aggregated ? new AggregateCollector(0) : null;
        ExpressionBinder selectBinder = new ExpressionBinder(scope, functions, aggs, "SELECT");

        // SELECT list (with * expansion)
        List<BoundExpr> projections = new ArrayList<>();
        List<String> names = new ArrayList<>();
        for (Query.SelectItem item : sel.items()) {
            switch (item) {
                case Query.Star star -> expandStar(star, scope, projections, names);
                case Query.ExprItem ei -> {
                    BoundExpr e = selectBinder.bind(ei.expr());
                    projections.add(e);
                    names.add(outputName(ei, e, projections.size()));
                }
            }
        }
        if (aggregated) {
            for (BoundExpr e : projections) {
                checkNoBareColumns(e);
            }
        }
        int visible = projections.size();

        // ORDER BY
        List<SortKey> orderBy = new ArrayList<>();
        for (Query.OrderItem item : q.orderBy()) {
            int column = resolveOrderItem(item.expr(), projections, names, visible, selectBinder, aggregated);
            boolean nullsFirst = item.nullsFirst() != null ? item.nullsFirst() : !item.descending();
            orderBy.add(new SortKey(column, item.descending(), nullsFirst));
        }

        BoundExpr limit = q.limit() == null ? null : constantInt(q.limit(), "LIMIT");
        BoundExpr offset = q.offset() == null ? null : constantInt(q.offset(), "OFFSET");

        return new BoundQuery(source, where, aggregated, List.of(),
                aggs == null ? List.of() : List.copyOf(aggs.calls()), null,
                projections, names, visible, orderBy, limit, offset);
    }

    private static void requireCondition(BoundExpr e, String clause) {
        TypeKind k = e.type().kind();
        if (k != TypeKind.BOOLEAN && k != TypeKind.NULL) {
            throw PolyQueryException.of(ErrorCode.TYPE_ERROR, "%s condition must be BOOLEAN, got %s", clause, e.type());
        }
    }

    private static void expandStar(Query.Star star, Scope scope, List<BoundExpr> projections, List<String> names) {
        if (scope.isEmpty()) {
            throw semantic("SELECT * requires a FROM clause");
        }
        List<Scope.RangeVar> vars;
        if (star.qualifier() != null) {
            Scope.RangeVar rv = scope.find(star.qualifier());
            if (rv == null) {
                throw semantic("unknown table or alias '%s'", star.qualifier());
            }
            vars = List.of(rv);
        } else {
            vars = scope.rangeVars();
        }
        for (Scope.RangeVar rv : vars) {
            for (int i = 0; i < rv.columns().size(); i++) {
                ColumnSchema c = rv.columns().get(i);
                projections.add(new BoundExpr.ColumnRef(rv.offset() + i, c.type(), c.name()));
                names.add(c.name());
            }
        }
    }

    private static String outputName(Query.ExprItem item, BoundExpr bound, int position) {
        if (item.alias() != null) {
            return item.alias();
        }
        if (item.expr() instanceof Expr.ColumnRef && bound instanceof BoundExpr.ColumnRef ref) {
            return ref.name();
        }
        return "_col" + position;
    }

    /** In an aggregated query without GROUP BY no input column may appear outside aggregates. */
    private static void checkNoBareColumns(BoundExpr e) {
        if (containsColumnRef(e)) {
            throw semantic("column must appear in GROUP BY or be used in an aggregate function");
        }
    }

    private static boolean containsColumnRef(BoundExpr e) {
        return switch (e) {
            case BoundExpr.ColumnRef c -> true;
            case BoundExpr.Literal l -> false;
            case BoundExpr.AggregateRef a -> false;
            case BoundExpr.Cast c -> containsColumnRef(c.input());
            case BoundExpr.Negate n -> containsColumnRef(n.input());
            case BoundExpr.Not n -> containsColumnRef(n.input());
            case BoundExpr.IsNull n -> containsColumnRef(n.input());
            case BoundExpr.Arithmetic a -> containsColumnRef(a.left()) || containsColumnRef(a.right());
            case BoundExpr.Comparison c -> containsColumnRef(c.left()) || containsColumnRef(c.right());
            case BoundExpr.And a -> containsColumnRef(a.left()) || containsColumnRef(a.right());
            case BoundExpr.Or o -> containsColumnRef(o.left()) || containsColumnRef(o.right());
            case BoundExpr.Concat c -> containsColumnRef(c.left()) || containsColumnRef(c.right());
            case BoundExpr.Function f -> f.args().stream().anyMatch(Analyzer::containsColumnRef);
        };
    }

    private int resolveOrderItem(Expr expr, List<BoundExpr> projections, List<String> names, int visible,
                                 ExpressionBinder binder, boolean aggregated) {
        if (expr instanceof Expr.NumberLiteral n && n.text().chars().allMatch(Character::isDigit)) {
            long k;
            try {
                k = Long.parseLong(n.text());
            } catch (NumberFormatException e) {
                k = -1;
            }
            if (k < 1 || k > visible) {
                throw semantic("ORDER BY position %s is out of range", n.text());
            }
            return (int) (k - 1);
        }
        if (expr instanceof Expr.ColumnRef c && c.qualifier() == null) {
            int match = -1;
            for (int i = 0; i < visible; i++) {
                if (names.get(i).equalsIgnoreCase(c.name())) {
                    if (match >= 0 && !projections.get(match).equals(projections.get(i))) {
                        throw semantic("ORDER BY name '%s' is ambiguous", c.name());
                    }
                    if (match < 0) {
                        match = i;
                    }
                }
            }
            if (match >= 0) {
                return match;
            }
        }
        BoundExpr e = binder.bind(expr);
        if (aggregated) {
            checkNoBareColumns(e);
        }
        int existing = projections.indexOf(e);
        if (existing >= 0) {
            return existing;
        }
        projections.add(e);
        return projections.size() - 1;
    }

    private BoundExpr constantInt(Expr expr, String clause) {
        BoundExpr e = new ExpressionBinder(Scope.empty(), functions, null, clause).bind(expr);
        if (!isConstant(e)) {
            throw semantic("%s requires a constant expression", clause);
        }
        if (e.type().kind() != TypeKind.INT64 && !e.type().isNull()) {
            throw PolyQueryException.of(ErrorCode.TYPE_ERROR, "%s requires an INT64 expression, got %s", clause, e.type());
        }
        return e;
    }

    private static boolean isConstant(BoundExpr e) {
        return switch (e) {
            case BoundExpr.ColumnRef c -> false;
            case BoundExpr.AggregateRef a -> false;
            case BoundExpr.Function f -> false;
            case BoundExpr.Literal l -> true;
            case BoundExpr.Cast c -> isConstant(c.input());
            case BoundExpr.Negate n -> isConstant(n.input());
            case BoundExpr.Not n -> isConstant(n.input());
            case BoundExpr.IsNull n -> isConstant(n.input());
            case BoundExpr.Arithmetic a -> isConstant(a.left()) && isConstant(a.right());
            case BoundExpr.Comparison c -> isConstant(c.left()) && isConstant(c.right());
            case BoundExpr.And a -> isConstant(a.left()) && isConstant(a.right());
            case BoundExpr.Or o -> isConstant(o.left()) && isConstant(o.right());
            case BoundExpr.Concat c -> isConstant(c.left()) && isConstant(c.right());
        };
    }

    // ---------------------------------------------------------------- aggregate detection

    private static boolean containsAggregate(Query.Select sel, List<Query.OrderItem> orderBy) {
        for (Query.SelectItem item : sel.items()) {
            if (item instanceof Query.ExprItem ei && hasAggregate(ei.expr())) {
                return true;
            }
        }
        for (Query.OrderItem o : orderBy) {
            if (hasAggregate(o.expr())) {
                return true;
            }
        }
        return sel.having() != null && hasAggregate(sel.having());
    }

    /** Syntactic search for aggregate calls (not descending into subqueries). */
    static boolean hasAggregate(Expr e) {
        return switch (e) {
            case Expr.FunctionCall f -> FunctionRegistry.aggregate(f.name()) != null
                    || f.args().stream().anyMatch(Analyzer::hasAggregate);
            case Expr.Unary u -> hasAggregate(u.operand());
            case Expr.Binary b -> hasAggregate(b.left()) || hasAggregate(b.right());
            case Expr.IsNull n -> hasAggregate(n.operand());
            case Expr.Between b -> hasAggregate(b.operand()) || hasAggregate(b.low()) || hasAggregate(b.high());
            case Expr.InList i -> hasAggregate(i.operand()) || i.items().stream().anyMatch(Analyzer::hasAggregate);
            case Expr.InSubquery i -> hasAggregate(i.operand());
            case Expr.Like l -> hasAggregate(l.operand()) || hasAggregate(l.pattern());
            case Expr.Cast c -> hasAggregate(c.operand());
            case Expr.Case c -> (c.operand() != null && hasAggregate(c.operand()))
                    || c.whens().stream().anyMatch(w -> hasAggregate(w.condition()) || hasAggregate(w.result()))
                    || (c.elseExpr() != null && hasAggregate(c.elseExpr()));
            default -> false;
        };
    }

    /** Output schema helper for callers. */
    public static List<ColumnSchema> outputSchema(BoundQuery q) {
        List<ColumnSchema> out = new ArrayList<>();
        for (int i = 0; i < q.visibleCount(); i++) {
            DataType t = q.projections().get(i).type();
            out.add(new ColumnSchema(q.names().get(i), t));
        }
        return out;
    }
}
