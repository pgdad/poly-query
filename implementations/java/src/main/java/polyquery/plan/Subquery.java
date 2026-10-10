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
 */
public record Subquery(LogicalPlan plan, int frame, List<BoundExpr.OuterRef> outerRefs) {
    public boolean correlated() {
        return !outerRefs.isEmpty();
    }
}
