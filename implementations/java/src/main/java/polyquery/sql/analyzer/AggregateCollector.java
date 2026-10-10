package polyquery.sql.analyzer;

import java.util.ArrayList;
import java.util.List;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;

/** Collects (deduplicated) aggregate calls of an aggregated query. */
final class AggregateCollector {
    private final List<AggregateCall> calls = new ArrayList<>();
    private final int offset;

    AggregateCollector(int groupKeyCount) {
        this.offset = groupKeyCount;
    }

    BoundExpr.AggregateRef register(AggregateCall call) {
        int idx = calls.indexOf(call);
        if (idx < 0) {
            idx = calls.size();
            calls.add(call);
        }
        return new BoundExpr.AggregateRef(offset + idx, call.type());
    }

    List<AggregateCall> calls() {
        return calls;
    }
}
