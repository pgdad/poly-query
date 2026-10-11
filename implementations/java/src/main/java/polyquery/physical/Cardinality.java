package polyquery.physical;

import java.util.Map;
import polyquery.index.KeyDomain;
import polyquery.index.KeyPredicate;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.storage.ColumnStats;
import polyquery.storage.Table;
import polyquery.types.DataType;

/**
 * Cardinality and selectivity estimates from table statistics (indexes-and-planning.md §3):
 * equality ≈ 1/distinct, ranges by linear interpolation between min and max for
 * numeric/temporal columns (1/3 otherwise); other predicates use fixed guesses.
 */
public final class Cardinality {
    static final double DEFAULT_SELECTIVITY = 1.0 / 3;

    private Cardinality() {
    }

    /** Fraction of the table's rows satisfying {@code predicate} on column {@code column}. */
    static double selectivity(Table table, int column, KeyPredicate predicate) {
        if (predicate instanceof KeyPredicate.Empty) {
            return 0;
        }
        if (table.rowCount() == 0) {
            return 0;
        }
        ColumnStats stats = table.stats().column(column);
        if (stats.min() == null) {
            return 0; // only NULLs: no key predicate matches
        }
        DataType type = table.columnType(column);
        double distinct = Math.max(1, stats.distinctCount());
        return switch (predicate) {
            case KeyPredicate.Empty e -> 0;
            case KeyPredicate.Points p -> Math.min(1.0, p.keys().size() / distinct);
            case KeyPredicate.Range r -> range(r, KeyDomain.key(stats.min(), type), KeyDomain.key(stats.max(), type),
                    distinct);
        };
    }

    private static double range(KeyPredicate.Range r, Object min, Object max, double distinct) {
        if (!r.overlaps(min, max)) {
            return 0;
        }
        if (!(min instanceof Number)) {
            return DEFAULT_SELECTIVITY;
        }
        double lo = ((Number) min).doubleValue();
        double hi = ((Number) max).doubleValue();
        if (hi <= lo) {
            return 1.0;
        }
        double from = r.lower() == null ? lo : Math.max(lo, ((Number) r.lower()).doubleValue());
        double to = r.upper() == null ? hi : Math.min(hi, ((Number) r.upper()).doubleValue());
        return Math.min(1.0, Math.max((to - from) / (hi - lo), 1.0 / distinct));
    }

    /** Estimated output rows of a logical plan. */
    public static double rows(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> s.table().rowCount();
            case LogicalPlan.SingleRow s -> 1;
            case LogicalPlan.Filter f -> {
                double input = rows(f.input());
                if (f.input() instanceof LogicalPlan.Scan s) {
                    yield input * scanFilterSelectivity(s.table(), f.predicate());
                }
                yield input * Math.pow(DEFAULT_SELECTIVITY, BoundExprs.conjuncts(f.predicate()).size());
            }
            case LogicalPlan.Join j -> {
                double l = rows(j.left());
                double r = rows(j.right());
                yield switch (j.kind()) {
                    case CROSS -> l * r;
                    case INNER -> j.condition() == null ? l * r : Math.max(l, r);
                    case LEFT -> Math.max(l, r);
                };
            }
            case LogicalPlan.Aggregate a -> a.groupKeys().isEmpty() ? 1 : Math.max(1, rows(a.input()) / 10);
            case LogicalPlan.Project p -> rows(p.input());
            case LogicalPlan.Distinct d -> rows(d.input());
            case LogicalPlan.Sort s -> rows(s.input());
            case LogicalPlan.Limit l -> rows(l.input());
        };
    }

    /** Selectivity of a filter directly over a table scan, using column statistics for sargable conjuncts. */
    static double scanFilterSelectivity(Table table, BoundExpr predicate) {
        ColumnPredicates.Extraction x = ColumnPredicates.extract(predicate, table.columns());
        double s = 1.0;
        for (Map.Entry<Integer, KeyPredicate> e : x.columns().entrySet()) {
            s *= selectivity(table, e.getKey(), e.getValue());
        }
        return s * Math.pow(DEFAULT_SELECTIVITY, x.otherConjuncts());
    }
}
