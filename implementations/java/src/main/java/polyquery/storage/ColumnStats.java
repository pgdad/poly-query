package polyquery.storage;

/**
 * Statistics of one column.
 *
 * @param nullCount     exact number of NULLs
 * @param distinctCount number of distinct non-null values (exact for small columns, else approximate)
 * @param min           smallest non-null value (runtime representation) or null
 * @param max           largest non-null value or null
 */
public record ColumnStats(long nullCount, long distinctCount, Object min, Object max) {
}
