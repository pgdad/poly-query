package polyquery.exec;

import java.math.BigDecimal;
import java.util.Arrays;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/** Canonical forms of values for hashing, so that values comparing equal are {@code equals}. */
public final class HashKeys {
    private HashKeys() {
    }

    /**
     * Canonical form independent of the DECIMAL scale ({@code 1.50} and {@code 1.5} map to the
     * same key) and of the sign of floating-point zero.
     */
    public static Object normalize(Object v, DataType type) {
        if (v == null) {
            return null;
        }
        if (type.kind() == TypeKind.DECIMAL) {
            return BigDecimal.valueOf((Long) v, type.scale()).stripTrailingZeros();
        }
        return normalizeZero(v);
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
