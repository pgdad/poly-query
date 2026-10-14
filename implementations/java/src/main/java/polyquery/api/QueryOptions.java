package polyquery.api;

/**
 * Per-query options (the protocol's query {@code options}). Immutable; the {@code with…}
 * methods return modified copies:
 *
 * <pre>{@code
 * QueryOptions opts = QueryOptions.DEFAULT.withThreads(4).withTimeoutMs(5_000);
 * }</pre>
 *
 * @param threads   worker threads for the query, 1–1024; 0 = the instance's default
 *                  ({@link DatabaseConfig#threads()})
 * @param timeoutMs time limit in milliseconds ({@code TIMEOUT} beyond it); 0 = none
 * @param maxRows   largest allowed result ({@code RESOURCE_LIMIT} beyond it); -1 = unlimited
 */
public record QueryOptions(int threads, long timeoutMs, long maxRows) {
    /** Largest {@link #threads()} value. */
    public static final int MAX_THREADS = 1024;

    /** Default threads, no timeout, no row limit. */
    public static final QueryOptions DEFAULT = new QueryOptions(0, 0, -1);

    public QueryOptions {
        if (threads < 0 || threads > MAX_THREADS) {
            throw new IllegalArgumentException("threads must be between 0 and " + MAX_THREADS);
        }
        if (timeoutMs < 0) {
            throw new IllegalArgumentException("timeoutMs must be >= 0");
        }
        if (maxRows < -1) {
            throw new IllegalArgumentException("maxRows must be >= 0, or -1 for no limit");
        }
    }

    public QueryOptions withThreads(int newThreads) {
        return new QueryOptions(newThreads, timeoutMs, maxRows);
    }

    public QueryOptions withTimeoutMs(long newTimeoutMs) {
        return new QueryOptions(threads, newTimeoutMs, maxRows);
    }

    public QueryOptions withMaxRows(long newMaxRows) {
        return new QueryOptions(threads, timeoutMs, newMaxRows);
    }
}
