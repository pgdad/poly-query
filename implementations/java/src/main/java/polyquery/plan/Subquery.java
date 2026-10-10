package polyquery.plan;

import java.util.List;

/**
 * A nested query used inside an expression.
 *
 * @param plan      the subquery's logical plan (its first output column is the value column)
 * @param frame     correlation frame of the query level whose rows the expression is evaluated on
 * @param outerRefs references to enclosing query levels made anywhere inside the subquery; the
 *                  subquery is correlated iff this is non-empty, and its result depends only on
 *                  the values of these references
 * @param frameMap  null if the expression is evaluated on rows of the level's FROM clause; for
 *                  expressions over aggregation output rows, maps each FROM column index to the
 *                  group-key slot holding its value (-1 if not grouped), so the frame row can be
 *                  reconstructed
 */
public record Subquery(LogicalPlan plan, int frame, List<BoundExpr.OuterRef> outerRefs, int[] frameMap) {
    public Subquery(LogicalPlan plan, int frame, List<BoundExpr.OuterRef> outerRefs) {
        this(plan, frame, outerRefs, null);
    }

    public boolean correlated() {
        return !outerRefs.isEmpty();
    }

    /** True if the subquery depends on the current row of correlation frame {@code id}. */
    public boolean refersTo(int id) {
        for (BoundExpr.OuterRef r : outerRefs) {
            if (r.frame() == id) {
                return true;
            }
        }
        return false;
    }

    public Subquery withFrameMap(int[] map) {
        return new Subquery(plan, frame, outerRefs, map);
    }
}
