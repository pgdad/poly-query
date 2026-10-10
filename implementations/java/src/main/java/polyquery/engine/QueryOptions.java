package polyquery.engine;

/**
 * Per-query options (protocol.md §5.2).
 *
 * @param maxRows   -1 = unlimited
 * @param timeoutMs 0 = none
 * @param countOnly omit rows from the result
 */
public record QueryOptions(long maxRows, long timeoutMs, boolean countOnly) {
    public static final QueryOptions DEFAULT = new QueryOptions(-1, 0, false);
}
