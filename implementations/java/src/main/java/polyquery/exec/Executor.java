package polyquery.exec;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.physical.PhysicalPlan;
import polyquery.plan.LogicalPlan;
import polyquery.storage.ColumnSchema;

/** Runs a physical plan to completion, collecting the result rows or passing them to a sink. */
public final class Executor {
    private Executor() {
    }

    /**
     * @param subqueryPlanner optimizes and physically plans subqueries met in expressions
     */
    public static QueryResult run(PhysicalPlan plan, ExecContext ctx, boolean collectRows,
                                  Function<LogicalPlan, PhysicalPlan> subqueryPlanner) {
        List<Object[]> rows = collectRows ? new ArrayList<>() : null;
        long count = stream(plan, ctx, subqueryPlanner, new ResultSink() {
            @Override
            public void columns(List<ColumnSchema> columns) {
            }

            @Override
            public void row(Object[] row) {
                if (rows != null) {
                    ctx.reserve(ExecContext.estimateRow(row));
                    rows.add(row);
                }
            }
        });
        return new QueryResult(plan.schema(), rows, count);
    }

    /** Streams the result rows of a plan into {@code sink}; returns the row count. */
    public static long stream(PhysicalPlan plan, ExecContext ctx, Function<LogicalPlan, PhysicalPlan> subqueryPlanner,
                              ResultSink sink) {
        Operator root = new OperatorBuilder(ctx, subqueryPlanner).build(plan);
        sink.columns(plan.schema());
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
                sink.row(row);
                ctx.checkpoint();
            }
            ctx.checkNow();
        } finally {
            root.close();
        }
        return count;
    }
}
