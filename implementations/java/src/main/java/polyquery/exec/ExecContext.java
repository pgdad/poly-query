package polyquery.exec;

import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * Per-query execution state: deadline (timeout), memory budget accounting and row limits.
 * Operators call {@link #checkpoint()} regularly so long-running queries stop promptly.
 */
public final class ExecContext {
    private static final int CHECK_INTERVAL = 1024;

    private final long deadlineNanos;
    private final long memoryBudget;
    private final long maxResultRows;
    private final long maxJoinRows;
    private Object[][] frames = new Object[8][];
    private long memoryUsed;
    private int counter;
    private volatile boolean cancelled;

    /**
     * @param timeoutMillis 0 = no timeout
     * @param memoryBudget  bytes
     * @param maxResultRows -1 = unlimited
     * @param maxJoinRows   maximum number of rows produced by one join operator
     */
    public ExecContext(long timeoutMillis, long memoryBudget, long maxResultRows, long maxJoinRows) {
        this.deadlineNanos = timeoutMillis > 0 ? System.nanoTime() + timeoutMillis * 1_000_000L : 0;
        this.memoryBudget = memoryBudget;
        this.maxResultRows = maxResultRows;
        this.maxJoinRows = maxJoinRows;
    }

    public long maxResultRows() {
        return maxResultRows;
    }

    public long maxJoinRows() {
        return maxJoinRows;
    }

    /** Current row of correlation frame {@code id} (the row an enclosing query level is evaluating). */
    public Object[] frame(int id) {
        return frames[id];
    }

    /** Sets the current row of a correlation frame and returns the previous one (for restoring). */
    public Object[] setFrame(int id, Object[] row) {
        if (id >= frames.length) {
            frames = java.util.Arrays.copyOf(frames, Math.max(id + 1, frames.length * 2));
        }
        Object[] previous = frames[id];
        frames[id] = row;
        return previous;
    }

    public void cancel() {
        cancelled = true;
    }

    /** Cheap periodic check for timeout / cancellation. */
    public void checkpoint() {
        if (++counter >= CHECK_INTERVAL) {
            counter = 0;
            checkNow();
        }
    }

    public void checkNow() {
        if (cancelled) {
            throw new PolyQueryException(ErrorCode.CANCELLED, "query was cancelled");
        }
        if (deadlineNanos != 0 && System.nanoTime() - deadlineNanos >= 0) {
            throw new PolyQueryException(ErrorCode.TIMEOUT, "query exceeded its timeout");
        }
    }

    /** Nanoseconds until the deadline (Long.MAX_VALUE if none). */
    public long remainingNanos() {
        return deadlineNanos == 0 ? Long.MAX_VALUE : deadlineNanos - System.nanoTime();
    }

    /** Accounts for retained memory; RESOURCE_LIMIT when the budget is exceeded. */
    public void reserve(long bytes) {
        memoryUsed += bytes;
        if (memoryUsed > memoryBudget) {
            throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                    "query exceeded its memory budget of " + (memoryBudget >> 20) + " MiB");
        }
    }

    public void release(long bytes) {
        memoryUsed -= bytes;
    }

    /** Rough heap size of a materialized row. */
    public static long estimateRow(Object[] row) {
        long total = 16 + 8L * row.length;
        for (Object v : row) {
            if (v instanceof String s) {
                total += 40 + s.length();
            } else if (v != null) {
                total += 16;
            }
        }
        return total;
    }
}
