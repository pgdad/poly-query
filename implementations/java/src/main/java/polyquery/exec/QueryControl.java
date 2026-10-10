package polyquery.exec;

import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * Lifetime control of one query, shared between the thread executing it and the threads that
 * may stop it: an absolute deadline (timeout, counted from arrival so queueing time counts)
 * and an asynchronous cancellation flag (concurrency.md §3–§4).
 */
public final class QueryControl {
    private volatile long deadlineNanos;
    private volatile String cancelReason;

    /** A control without deadline; it can be cancelled before the query starts. */
    public QueryControl() {
    }

    /** A control whose deadline is {@code timeoutMillis} from now (0 = no timeout). */
    public static QueryControl withTimeout(long timeoutMillis) {
        QueryControl c = new QueryControl();
        c.setTimeout(timeoutMillis);
        return c;
    }

    /** Sets the deadline to {@code timeoutMillis} from now (0 = no timeout). */
    public void setTimeout(long timeoutMillis) {
        if (timeoutMillis <= 0) {
            deadlineNanos = 0;
            return;
        }
        long deadline = System.nanoTime() + Math.min(timeoutMillis, Long.MAX_VALUE / 2_000_000L) * 1_000_000L;
        deadlineNanos = deadline == 0 ? 1 : deadline;
    }

    /** Requests cancellation; the query fails with CANCELLED at its next check. */
    public void cancel(String reason) {
        if (cancelReason == null) {
            cancelReason = reason;
        }
    }

    public boolean isCancelled() {
        return cancelReason != null;
    }

    public boolean hasDeadline() {
        return deadlineNanos != 0;
    }

    /** Throws CANCELLED or TIMEOUT if the query must stop. */
    public void check() {
        String reason = cancelReason;
        if (reason != null) {
            throw new PolyQueryException(ErrorCode.CANCELLED, "query was cancelled (" + reason + ")");
        }
        long deadline = deadlineNanos;
        if (deadline != 0 && System.nanoTime() - deadline >= 0) {
            throw new PolyQueryException(ErrorCode.TIMEOUT, "query exceeded its timeout");
        }
    }

    /** Nanoseconds until the deadline (Long.MAX_VALUE if none). */
    public long remainingNanos() {
        long deadline = deadlineNanos;
        return deadline == 0 ? Long.MAX_VALUE : deadline - System.nanoTime();
    }
}
