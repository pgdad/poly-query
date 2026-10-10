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
    private long memoryUsed;
    private int counter;
    private volatile boolean cancelled;

    /**
     * @param timeoutMillis 0 = no timeout
     * @param memoryBudget  bytes
     * @param maxResultRows -1 = unlimited
     */
    public ExecContext(long timeoutMillis, long memoryBudget, long maxResultRows) {
        this.deadlineNanos = timeoutMillis > 0 ? System.nanoTime() + timeoutMillis * 1_000_000L : 0;
        this.memoryBudget = memoryBudget;
        this.maxResultRows = maxResultRows;
    }

    public long maxResultRows() {
        return maxResultRows;
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
