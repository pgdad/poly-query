package polyquery.exec;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.LogicalPlan;

/** Runs a logical plan to completion and collects the result rows. */
public final class Executor {
    private Executor() {
    }

    public static QueryResult run(LogicalPlan plan, ExecContext ctx, boolean collectRows) {
        Operator root = new PhysicalPlanner(ctx).build(plan);
        List<Object[]> rows = collectRows ? new ArrayList<>() : null;
        long count = 0;
        long max = ctx.maxResultRows();
        root.open();
        try {
            Object[] row;
            while ((row = root.next()) != null) {
                count++;
                if (max >= 0 && count > max) {
                    throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                            "result exceeds max_rows (" + max + ")");
                }
                if (rows != null) {
                    ctx.reserve(ExecContext.estimateRow(row));
                    rows.add(row);
                }
                ctx.checkpoint();
            }
            ctx.checkNow();
        } finally {
            root.close();
        }
        return new QueryResult(plan.schema(), rows, count);
    }
}
