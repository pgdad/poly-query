package polyquery.sql.analyzer;

import java.util.List;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;

/**
 * Result of semantic analysis of one SELECT.
 *
 * @param source       the FROM relation (scan) or a single empty row
 * @param where        filter over the source row, or null
 * @param aggregated   whether an aggregation step exists
 * @param groupKeys    grouping expressions over the source row
 * @param aggregates   aggregate calls over the source row
 * @param having       filter over the aggregation output row, or null
 * @param projections  output expressions (first {@code visibleCount}) followed by hidden sort keys
 * @param names        output column names (visible columns)
 * @param orderBy      sort keys referring to positions in {@code projections}
 * @param limit        constant INT64 expression or null
 * @param offset       constant INT64 expression or null
 */
public record BoundQuery(LogicalPlan source, BoundExpr where, boolean aggregated, List<BoundExpr> groupKeys,
                         List<AggregateCall> aggregates, BoundExpr having, List<BoundExpr> projections,
                         List<String> names, int visibleCount, List<SortKey> orderBy, BoundExpr limit,
                         BoundExpr offset) {
}
