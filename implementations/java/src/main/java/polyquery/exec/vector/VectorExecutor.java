package polyquery.exec.vector;

import java.util.function.Function;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.exec.OperatorBuilder;
import polyquery.exec.ResultSink;
import polyquery.physical.PhysicalPlan;
import polyquery.plan.LogicalPlan;

/** Runs a physical plan with vectorized (and possibly parallel) execution. */
public final class VectorExecutor {
    private VectorExecutor() {
    }

    /** Streams the result rows of a plan into {@code sink}; returns the row count. */
    public static long stream(PhysicalPlan plan, ExecContext ctx, Function<LogicalPlan, PhysicalPlan> subqueryPlanner,
                              ResultSink sink, int threads) {
        BatchOperator root = new BatchBuilder(new OperatorBuilder(ctx, subqueryPlanner), threads, plan)
                .build(plan);
        sink.columns(plan.schema());
        int width = plan.schema().size();
        boolean rows = sink.wantsRows();
        long count = 0;
        long max = ctx.maxResultRows();
        root.open();
        try {
            Batch b;
            while ((b = root.next()) != null) {
                for (int k = 0; k < b.count; k++) {
                    count++;
                    if (max >= 0 && count > max) {
                        throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                                "result exceeds max_rows (" + max + ")");
                    }
                    if (rows) {
                        int i = b.pos(k);
                        Object[] row = new Object[width];
                        for (int c = 0; c < width; c++) {
                            Vec v = b.cols[c];
                            if (v != null) {
                                row[c] = v.get(i);
                            }
                        }
                        sink.row(row);
                    }
                }
                if (b.error != null) {
                    throw b.error;
                }
                ctx.checkNow();
            }
            ctx.checkNow();
        } finally {
            root.close();
        }
        return count;
    }
}
