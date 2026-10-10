package polyquery.sql.analyzer;

import java.util.ArrayList;
import java.util.List;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;

/** Builds the canonical logical plan of an analyzed query level (semantics.md §4 clause order). */
public final class LogicalPlanner {
    private LogicalPlanner() {
    }

    public static LogicalPlan plan(BoundQuery q) {
        LogicalPlan p = q.source();
        if (q.where() != null) {
            p = new LogicalPlan.Filter(p, q.where());
        }
        if (q.aggregated()) {
            p = new LogicalPlan.Aggregate(p, q.groupKeys(), q.aggregates());
            if (q.having() != null) {
                p = new LogicalPlan.Filter(p, q.having());
            }
        }
        List<String> names = new ArrayList<>(q.names());
        for (int i = q.visibleCount(); i < q.projections().size(); i++) {
            names.add("_sort" + (i - q.visibleCount() + 1));
        }
        p = new LogicalPlan.Project(p, List.copyOf(q.projections()), names);
        if (q.distinct()) {
            p = new LogicalPlan.Distinct(p);
        }
        if (!q.orderBy().isEmpty()) {
            p = new LogicalPlan.Sort(p, q.orderBy());
        }
        if (q.limit() != null || q.offset() != null) {
            p = new LogicalPlan.Limit(p, q.offset(), q.limit());
        }
        if (q.visibleCount() < q.projections().size()) {
            List<BoundExpr> keep = new ArrayList<>();
            for (int i = 0; i < q.visibleCount(); i++) {
                keep.add(new BoundExpr.ColumnRef(i, q.projections().get(i).type(), q.names().get(i)));
            }
            p = new LogicalPlan.Project(p, keep, q.names());
        }
        return p;
    }
}
