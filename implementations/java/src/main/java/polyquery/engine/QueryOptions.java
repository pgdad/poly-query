package polyquery.engine;

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
 */
public record QueryOptions(long maxRows, long timeoutMs, boolean countOnly, boolean optimize,
                           JoinStrategy joinStrategy, boolean useIndexes) {
    public static final QueryOptions DEFAULT = new QueryOptions(-1, 0, false);

    /** Options with default optimization, join and index settings. */
    public QueryOptions(long maxRows, long timeoutMs, boolean countOnly) {
        this(maxRows, timeoutMs, countOnly, true, JoinStrategy.AUTO);
    }

    /** Options with indexes enabled. */
    public QueryOptions(long maxRows, long timeoutMs, boolean countOnly, boolean optimize, JoinStrategy joinStrategy) {
        this(maxRows, timeoutMs, countOnly, optimize, joinStrategy, true);
    }
}
