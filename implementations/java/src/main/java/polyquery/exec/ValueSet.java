package polyquery.exec;

import java.util.Set;

/**
 * The rows of an IN subquery: the distinct non-NULL values of its column as hash keys
 * ({@link HashKeys#normalize}), whether the column contained NULL and whether there were no rows.
 */
public record ValueSet(Set<Object> values, boolean hasNull, boolean isEmpty) {
    public boolean contains(Object v) {
        return values.contains(v);
    }
}
