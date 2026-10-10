package polyquery.engine;

import polyquery.exec.ExecMode;
import polyquery.physical.PhysicalPlanner.JoinStrategy;

/**
 * Per-query options (protocol.md §5.2).
 *
 * @param maxRows      -1 = unlimited
 * @param timeoutMs    0 = none
 * @param countOnly    omit rows from the result
 * @param optimize     apply logical optimizations
 * @param joinStrategy preferred join algorithm
 * @param useIndexes   allow index scans
 * @param mode         execution model (row-at-a-time or vectorized)
 * @param threads      worker threads for parallel scans/aggregations; 0 = engine default
 */
public record QueryOptions(long maxRows, long timeoutMs, boolean countOnly, boolean optimize,
                           JoinStrategy joinStrategy, boolean useIndexes, ExecMode mode, int threads) {
    public static final QueryOptions DEFAULT = new QueryOptions(-1, 0, false);

    /** Options with default optimization, join and index settings. */
    public QueryOptions(long maxRows, long timeoutMs, boolean countOnly) {
        this(maxRows, timeoutMs, countOnly, true, JoinStrategy.AUTO);
    }

    /** Options with indexes enabled. */
    public QueryOptions(long maxRows, long timeoutMs, boolean countOnly, boolean optimize, JoinStrategy joinStrategy) {
        this(maxRows, timeoutMs, countOnly, optimize, joinStrategy, true);
    }

    /** Options with the default execution model and thread count. */
    public QueryOptions(long maxRows, long timeoutMs, boolean countOnly, boolean optimize, JoinStrategy joinStrategy,
                        boolean useIndexes) {
        this(maxRows, timeoutMs, countOnly, optimize, joinStrategy, useIndexes, ExecMode.VECTORIZED, 0);
    }

    public QueryOptions withMode(ExecMode newMode, int newThreads) {
        return new QueryOptions(maxRows, timeoutMs, countOnly, optimize, joinStrategy, useIndexes, newMode, newThreads);
    }
}
