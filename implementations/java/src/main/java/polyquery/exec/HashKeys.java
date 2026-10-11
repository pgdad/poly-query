package polyquery.exec;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.Arrays;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/** Canonical forms of values for hashing, so that values comparing equal are {@code equals}. */
public final class HashKeys {
    private HashKeys() {
    }

    /**
     * Canonical form independent of the exact numeric type ({@code 1.50}, {@code 1.5} and a wide
     * {@code 1.5} map to the same key; integral values, INT64 included, map to a {@link Long}
     * when they fit one) and of the sign of floating-point zero.
     */
    public static Object normalize(Object v, DataType type) {
        if (v == null) {
            return null;
        }
        if (type.kind() == TypeKind.DECIMAL) {
            if (v instanceof Long l && type.scale() == 0) {
                return l;
            }
            BigDecimal d = (v instanceof BigInteger b ? new BigDecimal(b, type.scale())
                    : BigDecimal.valueOf((Long) v, type.scale())).stripTrailingZeros();
            if (d.scale() <= 0) {
                BigInteger i = d.toBigIntegerExact();
                if (i.bitLength() < 64) {
                    return i.longValue();
                }
            }
            return d;
        }
        return normalizeZero(v);
    }

    /**
     * True if exact numeric values of types {@code a} and {@code b} cannot be compared by their
     * runtime values directly: different scales or representations (INT64 counts as scale 0).
     */
    public static boolean mixedExact(DataType a, DataType b) {
        return a.isExactNumeric() && b.isExactNumeric()
                && (a.exactScale() != b.exactScale() || a.isWideDecimal() != b.isWideDecimal());
    }

    /** Maps {@code -0.0} to {@code 0.0}; other values unchanged. Enough for values of one type. */
    public static Object normalizeZero(Object v) {
        return v instanceof Double d && d == 0.0 ? 0.0 : v;
    }

    /** Composite key with element-wise equality (NULLs equal each other). */
    public record RowKey(Object[] values) {
        @Override
        public boolean equals(Object o) {
            return o instanceof RowKey k && Arrays.equals(values, k.values);
        }

        @Override
        public int hashCode() {
            return Arrays.hashCode(values);
        }
    }
}
