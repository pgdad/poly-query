package polyquery.sql.analyzer;

import java.util.List;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;

/**
 * Result of semantic analysis of one query level (one SELECT with its ORDER BY / LIMIT).
 *
 * @param source       the FROM relation (scans, joins, derived tables) or a single empty row
 * @param where        filter over the source row, or null
 * @param aggregated   whether an aggregation step exists
 * @param groupKeys    grouping expressions over the source row
 * @param aggregates   aggregate calls over the source row
 * @param having       filter over the aggregation output row, or null
 * @param projections  output expressions (first {@code visibleCount}) followed by hidden sort keys;
 *                     over the aggregation output row if aggregated, else over the source row
 * @param names        output column names (visible columns)
 * @param distinct     SELECT DISTINCT
 * @param orderBy      sort keys referring to positions in {@code projections}
 * @param limit        constant INT64 expression or null
 * @param offset       constant INT64 expression or null
 */
public record BoundQuery(LogicalPlan source, BoundExpr where, boolean aggregated, List<BoundExpr> groupKeys,
                         List<AggregateCall> aggregates, BoundExpr having, List<BoundExpr> projections,
                         List<String> names, int visibleCount, boolean distinct, List<SortKey> orderBy,
                         BoundExpr limit, BoundExpr offset) {
}
