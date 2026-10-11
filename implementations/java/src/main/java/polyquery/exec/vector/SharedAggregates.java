package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.List;
import polyquery.exec.ExecContext;
import polyquery.physical.PhysicalPlan;
import polyquery.physical.PlanKeys;

/**
 * Reuse of completed aggregations within one query: an aggregation subplan identical to one
 * already computed in the query (see {@link PlanKeys}) emits that one's result instead of
 * recomputing it (e.g. a CTE with GROUP BY referenced twice). Completed aggregations are
 * registered under a cheap fingerprint (group keys and aggregate calls); the structural key
 * — a reflective walk of the subplan — is computed only when two aggregations of a query share
 * a fingerprint, so queries with a single aggregation pay nothing for it.
 */
final class SharedAggregates {
    private SharedAggregates() {
    }

    /** One aggregation subplan of the query (its structural key computed on demand). */
    static final class Candidate {
        private final PhysicalPlan.HashAggregate plan;
        private Object key;
        private boolean keyed;

        Candidate(PhysicalPlan.HashAggregate plan) {
            this.plan = plan;
        }

        private Object key() {
            if (!keyed) {
                key = PlanKeys.resultKey(plan);
                keyed = true;
            }
            return key;
        }

        private Object fingerprint() {
            return List.of(SharedAggregates.class, plan.groupKeys(), plan.aggregates());
        }
    }

    private record Entry(Candidate candidate, AggregateBatches.Shared result) {
    }

    /** The result of an identical aggregation completed earlier in this query, or null. */
    static AggregateBatches.Shared find(ExecContext ctx, Candidate c) {
        if (c == null || !(ctx.sharedResult(c.fingerprint()) instanceof List<?> entries)) {
            return null;
        }
        for (Object o : entries) {
            Entry e = (Entry) o;
            Object key = c.key();
            if (key != null && key.equals(e.candidate().key())) {
                return e.result();
            }
        }
        return null;
    }

    /** Registers the completed result of {@code c}'s aggregation for later identical ones. */
    @SuppressWarnings("unchecked")
    static void register(ExecContext ctx, Candidate c, AggregateBatches.Shared result) {
        if (c == null) {
            return;
        }
        Object fingerprint = c.fingerprint();
        List<Entry> entries = (List<Entry>) ctx.sharedResult(fingerprint);
        if (entries == null) {
            entries = new ArrayList<>(2);
            ctx.shareResult(fingerprint, entries);
        }
        entries.add(new Entry(c, result));
    }
}
