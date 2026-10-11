package polyquery.exec;

import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.ffi.NativeKernels;

/**
 * Per-query execution state: lifetime control (timeout, cancellation), memory budget accounting
 * and row limits. Operators call {@link #checkpoint()} regularly so long-running queries stop promptly.
 * Parallel workers share the context: {@link #checkNow()}, {@link #reserve} and {@link #release}
 * are thread-safe; correlation frames are used only by the query's own thread.
 */
public final class ExecContext {
    private static final int CHECK_INTERVAL = 1024;

    private final QueryControl control;
    private final long memoryBudget;
    private final long maxResultRows;
    private final long maxJoinRows;
    private NativeKernels nativeKernels;
    private Object[][] frames = new Object[8][];
    private final java.util.concurrent.atomic.AtomicLong memoryUsed = new java.util.concurrent.atomic.AtomicLong();
    private int counter;

    /**
     * @param timeoutMillis 0 = no timeout
     * @param memoryBudget  bytes
     * @param maxResultRows -1 = unlimited
     * @param maxJoinRows   maximum number of rows produced by one join operator
     */
    public ExecContext(long timeoutMillis, long memoryBudget, long maxResultRows, long maxJoinRows) {
        this(QueryControl.withTimeout(timeoutMillis), memoryBudget, maxResultRows, maxJoinRows);
    }

    public ExecContext(QueryControl control, long memoryBudget, long maxResultRows, long maxJoinRows) {
        this.control = control;
        this.memoryBudget = memoryBudget;
        this.maxResultRows = maxResultRows;
        this.maxJoinRows = maxJoinRows;
    }

    /** The native kernels this query may use (option {@code native} with a loaded library), or null. */
    public NativeKernels nativeKernels() {
        return nativeKernels;
    }

    /** Lets the query use {@code kernels} (null: engine code only). */
    public ExecContext withNativeKernels(NativeKernels kernels) {
        this.nativeKernels = kernels;
        return this;
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

    public QueryControl control() {
        return control;
    }

    /** Cheap periodic check for timeout / cancellation. */
    public void checkpoint() {
        if (++counter >= CHECK_INTERVAL) {
            counter = 0;
            checkNow();
        }
    }

    public void checkNow() {
        control.check();
    }

    /** Nanoseconds until the deadline (Long.MAX_VALUE if none). */
    public long remainingNanos() {
        return control.remainingNanos();
    }

    /** Accounts for retained memory; RESOURCE_LIMIT when the budget is exceeded. Thread-safe. */
    public void reserve(long bytes) {
        if (memoryUsed.addAndGet(bytes) > memoryBudget) {
            throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                    "query exceeded its memory budget of " + (memoryBudget >> 20) + " MiB");
        }
    }

    public void release(long bytes) {
        memoryUsed.addAndGet(-bytes);
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
