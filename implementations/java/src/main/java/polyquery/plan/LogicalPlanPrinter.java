package polyquery.plan;

import java.util.ArrayList;
import java.util.List;

/**
 * Renders a logical plan as an indented text tree, one operator per line, for debugging and
 * tests (not part of the protocol). Plans of subqueries are printed below the operator whose
 * expressions contain them, marked {@code subquery:}.
 */
public final class LogicalPlanPrinter {
    private static final String INDENT = "  ";

    private LogicalPlanPrinter() {
    }

    public static String print(LogicalPlan plan) {
        StringBuilder out = new StringBuilder();
        print(plan, "", out);
        return out.toString();
    }

    private static void print(LogicalPlan plan, String indent, StringBuilder out) {
        out.append(indent).append(describe(plan)).append('\n');
        for (BoundExpr e : expressions(plan)) {
            BoundExprs.any(e, x -> {
                Subquery sub = BoundExprs.subqueryOf(x);
                if (sub != null) {
                    out.append(indent).append(INDENT).append("subquery:\n");
                    print(sub.plan(), indent + INDENT + INDENT, out);
                }
                return false;
            });
        }
        for (LogicalPlan input : plan.children()) {
            print(input, indent + INDENT, out);
        }
    }

    /** One-line description of an operator (without its inputs). */
    static String describe(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> "Scan " + s.table().name()
                    + (s.alias() == null || s.alias().equals(s.table().name()) ? "" : " AS " + s.alias());
            case LogicalPlan.SingleRow s -> "SingleRow";
            case LogicalPlan.Filter f -> "Filter " + ExprFormatter.format(f.predicate());
            case LogicalPlan.Join j -> "Join " + j.kind()
                    + (j.condition() == null ? "" : " ON " + ExprFormatter.format(j.condition()));
            case LogicalPlan.Aggregate a -> {
                List<String> calls = new ArrayList<>();
                for (AggregateCall c : a.aggregates()) {
                    calls.add(ExprFormatter.aggregate(c));
                }
                yield "Aggregate keys=" + formatAll(a.groupKeys()) + " aggregates=" + calls;
            }
            case LogicalPlan.Project p -> {
                List<String> columns = new ArrayList<>();
                for (int i = 0; i < p.expressions().size(); i++) {
                    columns.add(p.names().get(i) + " := " + ExprFormatter.format(p.expressions().get(i)));
                }
                yield "Project " + columns;
            }
            case LogicalPlan.Distinct d -> "Distinct";
            case LogicalPlan.Sort s -> {
                List<String> keys = new ArrayList<>();
                for (SortKey k : s.keys()) {
                    keys.add(ExprFormatter.sortKey(k, s.input().schema()));
                }
                yield "Sort " + keys;
            }
            case LogicalPlan.Limit l -> "Limit"
                    + (l.offset() == null ? "" : " offset=" + ExprFormatter.format(l.offset()))
                    + (l.limit() == null ? "" : " limit=" + ExprFormatter.format(l.limit()));
            case LogicalPlan.UnionAll u -> "UnionAll";
        };
    }

    /** The expressions an operator evaluates (where subqueries may occur). */
    private static List<BoundExpr> expressions(LogicalPlan plan) {
        List<BoundExpr> out = new ArrayList<>();
        switch (plan) {
            case LogicalPlan.Filter f -> out.add(f.predicate());
            case LogicalPlan.Join j -> {
                if (j.condition() != null) {
                    out.add(j.condition());
                }
            }
            case LogicalPlan.Aggregate a -> {
                out.addAll(a.groupKeys());
                for (AggregateCall c : a.aggregates()) {
                    if (c.argument() != null) {
                        out.add(c.argument());
                    }
                }
            }
            case LogicalPlan.Project p -> out.addAll(p.expressions());
            default -> {
            }
        }
        return out;
    }

    private static List<String> formatAll(List<BoundExpr> exprs) {
        List<String> out = new ArrayList<>();
        for (BoundExpr e : exprs) {
            out.add(ExprFormatter.format(e));
        }
        return out;
    }
}
