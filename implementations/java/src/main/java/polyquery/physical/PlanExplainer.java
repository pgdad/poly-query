package polyquery.physical;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.ExprFormatter;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;
import polyquery.plan.Subquery;
import polyquery.storage.ColumnSchema;

/** Renders a physical plan as the EXPLAIN JSON tree (indexes-and-planning.md §4). */
public final class PlanExplainer {
    private final Function<LogicalPlan, PhysicalPlan> subqueryPlanner;

    /** @param subqueryPlanner plans subqueries found in expressions so they can be shown too */
    public PlanExplainer(Function<LogicalPlan, PhysicalPlan> subqueryPlanner) {
        this.subqueryPlanner = subqueryPlanner;
    }

    public Map<String, Object> explain(PhysicalPlan plan) {
        Map<String, Object> node = new LinkedHashMap<>();
        switch (plan) {
            case PhysicalPlan.TableScan s -> {
                node.put("op", "TableScan");
                node.put("table", s.table().name());
                node.put("alias", s.alias());
                node.put("columns", names(s.schema()));
            }
            case PhysicalPlan.Values v -> node.put("op", "Values");
            case PhysicalPlan.Filter f -> {
                node.put("op", "Filter");
                node.put("predicate", ExprFormatter.format(f.predicate()));
            }
            case PhysicalPlan.HashLookupFilter h -> {
                node.put("op", "HashLookupFilter");
                node.put("inner_keys", formatAll(h.innerKeys()));
                node.put("outer_keys", formatAll(h.outerKeys()));
                if (h.staticPredicate() != null) {
                    node.put("predicate", ExprFormatter.format(h.staticPredicate()));
                }
                if (h.dynamicPredicate() != null) {
                    node.put("correlated_predicate", ExprFormatter.format(h.dynamicPredicate()));
                }
            }
            case PhysicalPlan.Project p -> {
                node.put("op", "Project");
                node.put("columns", p.names());
                node.put("expressions", formatAll(p.expressions()));
            }
            case PhysicalPlan.HashAggregate a -> {
                node.put("op", "Aggregate");
                node.put("group_by", formatAll(a.groupKeys()));
                List<String> aggs = new ArrayList<>();
                for (AggregateCall c : a.aggregates()) {
                    aggs.add(aggregate(c));
                }
                node.put("aggregates", aggs);
            }
            case PhysicalPlan.HashDistinct d -> node.put("op", "Distinct");
            case PhysicalPlan.HashJoin j -> {
                node.put("op", "HashJoin");
                node.put("join_type", j.kind().name());
                node.put("left_keys", formatAll(j.leftKeys()));
                node.put("right_keys", formatAll(j.rightKeys()));
                node.put("build_side", "right");
                if (j.residual() != null) {
                    node.put("residual", ExprFormatter.format(j.residual()));
                }
            }
            case PhysicalPlan.NestedLoopJoin j -> {
                node.put("op", "NestedLoopJoin");
                node.put("join_type", j.kind().name());
                if (j.condition() != null) {
                    node.put("condition", ExprFormatter.format(j.condition()));
                }
            }
            case PhysicalPlan.Sort s -> {
                node.put("op", "Sort");
                List<String> keys = new ArrayList<>();
                List<ColumnSchema> schema = s.input().schema();
                for (SortKey k : s.keys()) {
                    keys.add(schema.get(k.column()).name() + (k.descending() ? " DESC" : " ASC")
                            + (k.nullsFirst() ? " NULLS FIRST" : " NULLS LAST"));
                }
                node.put("keys", keys);
            }
            case PhysicalPlan.Limit l -> {
                node.put("op", "Limit");
                if (l.offset() != null) {
                    node.put("offset", ExprFormatter.format(l.offset()));
                }
                if (l.limit() != null) {
                    node.put("limit", ExprFormatter.format(l.limit()));
                }
            }
        }
        List<Object> subqueries = new ArrayList<>();
        for (BoundExpr e : PhysicalPlan.expressions(plan)) {
            collectSubqueries(e, subqueries);
        }
        if (!subqueries.isEmpty()) {
            node.put("subqueries", subqueries);
        }
        List<Object> children = new ArrayList<>();
        for (PhysicalPlan c : plan.children()) {
            children.add(explain(c));
        }
        node.put("children", children);
        return node;
    }

    private void collectSubqueries(BoundExpr e, List<Object> out) {
        BoundExprs.any(e, x -> {
            Subquery sub = BoundExprs.subqueryOf(x);
            if (sub != null) {
                out.add(explain(subqueryPlanner.apply(sub.plan())));
            }
            return false;
        });
    }

    private static String aggregate(AggregateCall c) {
        String name = c.function() == AggregateCall.AggregateFunction.COUNT_STAR ? "COUNT" : c.function().name();
        if (c.argument() == null) {
            return name + "(*)";
        }
        return name + "(" + (c.distinct() ? "DISTINCT " : "") + ExprFormatter.format(c.argument()) + ")";
    }

    private static List<String> formatAll(List<BoundExpr> exprs) {
        List<String> out = new ArrayList<>();
        for (BoundExpr e : exprs) {
            out.add(ExprFormatter.format(e));
        }
        return out;
    }

    private static List<String> names(List<ColumnSchema> schema) {
        List<String> out = new ArrayList<>();
        for (ColumnSchema c : schema) {
            out.add(c.name());
        }
        return out;
    }
}
