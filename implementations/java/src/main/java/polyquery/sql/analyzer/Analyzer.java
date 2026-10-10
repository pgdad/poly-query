package polyquery.sql.analyzer;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.common.Names;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;
import polyquery.plan.Subquery;
import polyquery.sql.ast.Expr;
import polyquery.sql.ast.Query;
import polyquery.storage.Catalog;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;
import polyquery.types.TypeKind;

/**
 * Semantic analysis (semantics.md): name resolution over nested scopes, typing, aggregation
 * and ORDER BY validation. Each query level is bound into a {@link BoundQuery}, which
 * {@link LogicalPlanner} turns into a logical plan; nested levels (derived tables, CTEs,
 * subqueries) are analyzed recursively.
 */
public final class Analyzer {
    /** An analyzed and planned query: its plan, visible output columns and correlated references. */
    public record PlannedQuery(LogicalPlan plan, List<ColumnSchema> columns, List<BoundExpr.OuterRef> externalRefs) {
    }

    private record CteDef(LogicalPlan plan, List<ColumnSchema> columns, List<BoundExpr.OuterRef> externalRefs) {
    }

    /** CTEs visible at some point of the query, innermost WITH first. */
    private record CteEnv(CteEnv parent, Map<String, CteDef> defs) {
        CteDef find(String name) {
            for (CteEnv e = this; e != null; e = e.parent) {
                CteDef d = e.defs.get(Names.key(name));
                if (d != null) {
                    return d;
                }
            }
            return null;
        }
    }

    /** One select-list entry after {@code *} expansion. */
    private record SelectEntry(Expr expr, String alias, BoundExpr.ColumnRef star) {
    }

    private final Catalog catalog;
    private final FunctionRegistry functions;
    private int nextFrame;

    public Analyzer(Catalog catalog, FunctionRegistry functions) {
        this.catalog = catalog;
        this.functions = functions;
    }

    private static PolyQueryException semantic(String fmt, Object... args) {
        return PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, fmt, args);
    }

    /** Analyzes a top-level query and returns its logical plan. */
    public LogicalPlan analyze(Query q) {
        return planQuery(q, null, false, null).plan();
    }

    private PlannedQuery planQuery(Query q, Scope parent, boolean barrier, CteEnv env) {
        Scope scope = new Scope(parent, barrier, nextFrame++);
        CteEnv inner = bindWith(q.with(), scope, env);
        BoundQuery bound = bindQuery(q, scope, inner);
        List<ColumnSchema> columns = new ArrayList<>();
        for (int i = 0; i < bound.visibleCount(); i++) {
            columns.add(new ColumnSchema(bound.names().get(i), bound.projections().get(i).type()));
        }
        return new PlannedQuery(LogicalPlanner.plan(bound), columns, scope.externalRefs());
    }

    private ExpressionBinder.SubqueryPlanner subqueryPlanner(CteEnv env) {
        return (q, parent) -> planQuery(q, parent, false, env);
    }

    private ExpressionBinder binder(Scope scope, AggregateCollector aggs, String clause, CteEnv env) {
        return new ExpressionBinder(scope, functions, aggs, clause, subqueryPlanner(env));
    }

    // ---------------------------------------------------------------- WITH

    private CteEnv bindWith(List<Query.Cte> ctes, Scope scope, CteEnv env) {
        if (ctes.isEmpty()) {
            return env;
        }
        CteEnv out = new CteEnv(env, new HashMap<>());
        for (Query.Cte cte : ctes) {
            String key = Names.key(cte.name());
            if (out.defs().containsKey(key)) {
                throw semantic("duplicate CTE name '%s'", cte.name());
            }
            // The CTE body sees earlier CTEs of this WITH (already in 'out'), but not itself.
            PlannedQuery pq = planQuery(cte.query(), scope, true, out);
            List<ColumnSchema> columns = pq.columns();
            if (cte.columnNames() != null) {
                if (cte.columnNames().size() != columns.size()) {
                    throw semantic("CTE '%s' has %d columns but %d column names were given", cte.name(),
                            columns.size(), cte.columnNames().size());
                }
                List<ColumnSchema> renamed = new ArrayList<>();
                for (int i = 0; i < columns.size(); i++) {
                    renamed.add(new ColumnSchema(cte.columnNames().get(i), columns.get(i).type()));
                }
                columns = renamed;
            }
            out.defs().put(key, new CteDef(pq.plan(), List.copyOf(columns), pq.externalRefs()));
        }
        return out;
    }

    // ---------------------------------------------------------------- FROM

    private LogicalPlan bindFrom(Query.FromItem item, Scope scope, CteEnv env) {
        return switch (item) {
            case Query.TableRef ref -> {
                String rangeName = ref.alias() != null ? ref.alias() : ref.name();
                CteDef cte = env == null ? null : env.find(ref.name());
                if (cte != null) {
                    scope.add(rangeName, cte.columns());
                    for (BoundExpr.OuterRef r : cte.externalRefs()) {
                        scope.markExternal(r);
                    }
                    yield cte.plan();
                }
                Table table = catalog.find(ref.name());
                if (table == null) {
                    throw semantic("unknown table '%s'", ref.name());
                }
                scope.add(rangeName, table.columns());
                yield new LogicalPlan.Scan(table, rangeName);
            }
            case Query.DerivedTable dt -> {
                PlannedQuery pq = planQuery(dt.query(), scope, true, env);
                scope.add(dt.alias(), pq.columns());
                yield pq.plan();
            }
            case Query.Join join -> bindJoin(join, scope, env);
        };
    }

    private LogicalPlan bindJoin(Query.Join join, Scope scope, CteEnv env) {
        int start = scope.width();
        LogicalPlan left = bindFrom(join.left(), scope, env);
        LogicalPlan right = bindFrom(join.right(), scope, env);
        if (join.kind() == Query.JoinKind.CROSS) {
            return new LogicalPlan.Join(left, right, LogicalPlan.JoinKind.CROSS, null);
        }
        BoundExpr cond = binder(scope, null, "ON", env).bind(join.condition());
        requireCondition(cond, "ON");
        if (start > 0) {
            // A parenthesized join nested on the right: its rows start at 'start' in the scope layout.
            if (BoundExprs.columnRange(cond)[0] < start) {
                throw PolyQueryException.of(ErrorCode.UNSUPPORTED,
                        "a nested join condition cannot reference tables outside the parenthesized join");
            }
            if (BoundExprs.dependsOnFrame(cond, scope.frame())) {
                throw PolyQueryException.of(ErrorCode.UNSUPPORTED,
                        "correlated subqueries in a nested join condition are not supported");
            }
            cond = BoundExprs.shiftColumns(cond, -start);
        }
        LogicalPlan.JoinKind kind = join.kind() == Query.JoinKind.LEFT ? LogicalPlan.JoinKind.LEFT
                : LogicalPlan.JoinKind.INNER;
        return new LogicalPlan.Join(left, right, kind, cond);
    }

    // ---------------------------------------------------------------- query level

    private BoundQuery bindQuery(Query q, Scope scope, CteEnv env) {
        Query.Select sel = q.select();
        LogicalPlan source = sel.from() == null ? new LogicalPlan.SingleRow() : bindFrom(sel.from(), scope, env);

        BoundExpr where = null;
        if (sel.where() != null) {
            where = binder(scope, null, "WHERE", env).bind(sel.where());
            requireCondition(where, "WHERE");
        }

        List<SelectEntry> entries = expandSelectList(sel, scope);
        boolean aggregated = !sel.groupBy().isEmpty() || sel.having() != null || containsAggregate(sel, q.orderBy());

        List<BoundExpr> keys = new ArrayList<>();
        for (Expr g : sel.groupBy()) {
            keys.add(bindGroupKey(g, entries, scope, env));
        }
        AggregateCollector aggs = aggregated ? new AggregateCollector(keys.size()) : null;
        ExpressionBinder selectBinder = binder(scope, aggs, "SELECT", env);

        List<BoundExpr> projections = new ArrayList<>();
        List<String> names = new ArrayList<>();
        for (SelectEntry entry : entries) {
            BoundExpr e = entry.star() != null ? entry.star() : selectBinder.bind(entry.expr());
            names.add(outputName(entry, e, projections.size() + 1));
            projections.add(aggregated ? finishAggregated(e, keys, scope) : e);
        }
        int visible = projections.size();

        BoundExpr having = null;
        if (sel.having() != null) {
            having = binder(scope, aggs, "HAVING", env).bind(sel.having());
            requireCondition(having, "HAVING");
            having = finishAggregated(having, keys, scope);
        }

        ExpressionBinder orderBinder = binder(scope, aggs, "ORDER BY", env);
        List<SortKey> orderBy = new ArrayList<>();
        for (Query.OrderItem item : q.orderBy()) {
            int column = resolveOrderItem(item.expr(), projections, names, visible, orderBinder, keys, scope,
                    aggregated, sel.distinct());
            boolean nullsFirst = item.nullsFirst() != null ? item.nullsFirst() : !item.descending();
            orderBy.add(new SortKey(column, item.descending(), nullsFirst));
        }

        BoundExpr limit = q.limit() == null ? null : constantInt(q.limit(), "LIMIT");
        BoundExpr offset = q.offset() == null ? null : constantInt(q.offset(), "OFFSET");

        return new BoundQuery(source, where, aggregated, List.copyOf(keys),
                aggs == null ? List.of() : List.copyOf(aggs.calls()), having, projections, names, visible,
                sel.distinct(), orderBy, limit, offset);
    }

    static void requireCondition(BoundExpr e, String clause) {
        TypeKind k = e.type().kind();
        if (k != TypeKind.BOOLEAN && k != TypeKind.NULL) {
            throw PolyQueryException.of(ErrorCode.TYPE_ERROR, "%s condition must be BOOLEAN, got %s", clause, e.type());
        }
    }

    private static List<SelectEntry> expandSelectList(Query.Select sel, Scope scope) {
        List<SelectEntry> entries = new ArrayList<>();
        for (Query.SelectItem item : sel.items()) {
            switch (item) {
                case Query.ExprItem ei -> entries.add(new SelectEntry(ei.expr(), ei.alias(), null));
                case Query.Star star -> {
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
                            entries.add(new SelectEntry(null, null,
                                    new BoundExpr.ColumnRef(rv.offset() + i, c.type(), c.name())));
                        }
                    }
                }
            }
        }
        return entries;
    }

    private static String outputName(SelectEntry entry, BoundExpr bound, int position) {
        if (entry.alias() != null) {
            return entry.alias();
        }
        if (entry.star() != null) {
            return entry.star().name();
        }
        if (entry.expr() instanceof Expr.ColumnRef) {
            if (bound instanceof BoundExpr.ColumnRef ref) {
                return ref.name();
            }
            if (bound instanceof BoundExpr.OuterRef ref) {
                return ref.name();
            }
        }
        return "_col" + position;
    }

    // ---------------------------------------------------------------- aggregation

    private BoundExpr bindGroupKey(Expr g, List<SelectEntry> entries, Scope scope, CteEnv env) {
        ExpressionBinder b = binder(scope, null, "GROUP BY", env);
        Integer ordinal = ordinal(g);
        if (ordinal != null) {
            if (ordinal < 1 || ordinal > entries.size()) {
                throw semantic("GROUP BY position %d is out of range", ordinal);
            }
            SelectEntry entry = entries.get(ordinal - 1);
            return entry.star() != null ? entry.star() : b.bind(entry.expr());
        }
        if (g instanceof Expr.ColumnRef c && c.qualifier() == null && scope.resolveLocal(null, c.name()) == null) {
            for (SelectEntry entry : entries) {
                if (entry.alias() != null && Names.equal(entry.alias(), c.name())) {
                    return b.bind(entry.expr());
                }
            }
        }
        return b.bind(g);
    }

    /** Positive or zero integer literal used as an ordinal, else null. */
    private static Integer ordinal(Expr e) {
        if (e instanceof Expr.NumberLiteral n && n.text().chars().allMatch(Character::isDigit)) {
            try {
                return Integer.parseInt(n.text());
            } catch (NumberFormatException ex) {
                return Integer.MAX_VALUE;
            }
        }
        return null;
    }

    /**
     * Rewrites an expression of an aggregated query over the aggregation output: GROUP BY
     * expressions become key slots; any remaining input column is a grouping violation.
     * Correlated subqueries that read this level's row get a frame map that rebuilds that row
     * from the group keys (they may only use grouped columns).
     */
    private static BoundExpr finishAggregated(BoundExpr e, List<BoundExpr> keys, Scope scope) {
        BoundExpr r = BoundExprs.rewrite(e, x -> groupedNode(x, keys, scope));
        if (BoundExprs.containsColumnRef(r)) {
            throw semantic("column must appear in GROUP BY or be used in an aggregate function");
        }
        return r;
    }

    private static BoundExpr groupedNode(BoundExpr x, List<BoundExpr> keys, Scope scope) {
        int i = keys.indexOf(x);
        if (i >= 0) {
            return new BoundExpr.AggregateRef(i, x.type());
        }
        Subquery sq = BoundExprs.subqueryOf(x);
        if (sq == null || !sq.refersTo(scope.frame())) {
            return null;
        }
        int[] map = new int[scope.width()];
        java.util.Arrays.fill(map, -1);
        for (BoundExpr.OuterRef ref : sq.outerRefs()) {
            if (ref.frame() != scope.frame()) {
                continue;
            }
            int slot = -1;
            for (int k = 0; k < keys.size() && slot < 0; k++) {
                if (keys.get(k) instanceof BoundExpr.ColumnRef c && c.index() == ref.index()) {
                    slot = k;
                }
            }
            if (slot < 0) {
                throw semantic("column '%s' used in a subquery must appear in GROUP BY", ref.name());
            }
            map[ref.index()] = slot;
        }
        BoundExpr out = BoundExprs.withSubquery(x, sq.withFrameMap(map));
        if (out instanceof BoundExpr.InSubquery in) {
            BoundExpr operand = BoundExprs.rewrite(in.operand(), y -> groupedNode(y, keys, scope));
            out = new BoundExpr.InSubquery(operand, in.subquery(), in.valueCast(), in.negated());
        }
        return out;
    }

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

    // ---------------------------------------------------------------- ORDER BY / LIMIT

    private static int resolveOrderItem(Expr expr, List<BoundExpr> projections, List<String> names, int visible,
                                        ExpressionBinder binder, List<BoundExpr> keys, Scope scope,
                                        boolean aggregated, boolean distinct) {
        Integer ordinal = ordinal(expr);
        if (ordinal != null) {
            if (ordinal < 1 || ordinal > visible) {
                throw semantic("ORDER BY position %d is out of range", ordinal);
            }
            return ordinal - 1;
        }
        if (expr instanceof Expr.ColumnRef c && c.qualifier() == null) {
            int match = -1;
            for (int i = 0; i < visible; i++) {
                if (Names.equal(names.get(i), c.name())) {
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
            e = finishAggregated(e, keys, scope);
        }
        int existing = projections.indexOf(e);
        if (distinct && (existing < 0 || existing >= visible)) {
            throw semantic("ORDER BY expressions must appear in the select list of a SELECT DISTINCT");
        }
        if (existing >= 0) {
            return existing;
        }
        projections.add(e);
        return projections.size() - 1;
    }

    private BoundExpr constantInt(Expr expr, String clause) {
        BoundExpr e = binder(Scope.empty(), null, clause, null).bind(expr);
        if (!BoundExprs.isConstant(e)) {
            throw semantic("%s requires a constant expression", clause);
        }
        if (e.type().kind() != TypeKind.INT64 && !e.type().isNull()) {
            throw PolyQueryException.of(ErrorCode.TYPE_ERROR, "%s requires an INT64 expression, got %s", clause,
                    e.type());
        }
        return e;
    }
}
