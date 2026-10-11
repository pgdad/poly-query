package polyquery.index;

import java.math.BigInteger;
import polyquery.types.DataType;
import polyquery.types.Values;

/**
 * Index keys: the runtime value of a column mapped to a totally ordered key domain —
 * {@link Long} for BOOLEAN (0/1), INT64, narrow DECIMAL (unscaled), DATE (days) and TIMESTAMP,
 * {@link BigInteger} for wide DECIMAL (unscaled), {@link Double} for FLOAT64 (−0.0 normalized
 * to 0.0) and {@link String} for STRING.
 */
public final class KeyDomain {
    private KeyDomain() {
    }

    /** Key of a non-null runtime value of {@code type}. */
    public static Object key(Object value, DataType type) {
        return switch (type.kind()) {
            case BOOLEAN -> ((Boolean) value) ? 1L : 0L;
            case DATE -> (long) (Integer) value;
            case FLOAT64 -> {
                double d = (Double) value;
                yield d == 0.0 ? 0.0 : d;
            }
            default -> value;
        };
    }

    /** True if keys of {@code type} are {@link Long}s. */
    public static boolean isLongDomain(DataType type) {
        if (type.isWideDecimal()) {
            return false;
        }
        return switch (type.kind()) {
            case BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP -> true;
            default -> false;
        };
    }

    /** Compares two keys of the same domain. */
    public static int compare(Object a, Object b) {
        return switch (a) {
            case Long l -> Long.compare(l, (Long) b);
            case Double d -> Values.compareDoubles(d, (Double) b);
            case String s -> Values.compareStrings(s, (String) b);
            case BigInteger x -> x.compareTo((BigInteger) b);
            default -> throw new IllegalArgumentException("not a key: " + a);
        };
    }
}
