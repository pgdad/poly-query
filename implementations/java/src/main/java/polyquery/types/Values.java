package polyquery.types;

/** Comparison and canonical text rendering of runtime values (see {@link DataType}). */
public final class Values {
    private Values() {
    }

    /** Compares two non-null values of the same type (types.md §5, §7). */
    public static int compare(Object a, Object b, DataType type) {
        return switch (type.kind()) {
            case BOOLEAN -> Boolean.compare((Boolean) a, (Boolean) b);
            case INT64, TIMESTAMP -> Long.compare((Long) a, (Long) b);
            case DECIMAL -> a instanceof Long x && b instanceof Long y ? Long.compare(x, y)
                    : Decimals.toBig(a).compareTo(Decimals.toBig(b));
            case DATE -> Integer.compare((Integer) a, (Integer) b);
            case FLOAT64 -> compareDoubles((Double) a, (Double) b);
            case STRING -> compareStrings((String) a, (String) b);
            case NULL -> 0;
        };
    }

    /** Numeric comparison where {@code 0.0 == -0.0} (values are never NaN). */
    public static int compareDoubles(double a, double b) {
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    /** Lexicographic comparison by Unicode code point (equivalent to UTF-8 byte order). */
    public static int compareStrings(String a, String b) {
        int n = Math.min(a.length(), b.length());
        for (int i = 0; i < n; i++) {
            char x = a.charAt(i);
            char y = b.charAt(i);
            if (x != y) {
                return fixup(x) - fixup(y);
            }
        }
        return a.length() - b.length();
    }

    private static int fixup(char c) {
        if (c >= 0xD800) {
            return c >= 0xE000 ? c - 0x800 : c + 0x2000;
        }
        return c;
    }

    /** Canonical text of a non-null value (used by CAST to STRING and CONCAT). */
    public static String toText(Object v, DataType type) {
        return switch (type.kind()) {
            case BOOLEAN -> ((Boolean) v) ? "true" : "false";
            case INT64 -> Long.toString((Long) v);
            case DECIMAL -> Decimals.toString(v, type.scale());
            case FLOAT64 -> formatDouble((Double) v);
            case STRING -> (String) v;
            case DATE -> DateTimes.formatDate((Integer) v);
            case TIMESTAMP -> DateTimes.formatTimestamp((Long) v);
            case NULL -> "";
        };
    }

    /** Round-trip text of a finite double; {@code -0.0} is normalised to {@code 0.0}. */
    public static String formatDouble(double d) {
        if (d == 0.0) {
            return "0.0";
        }
        return Double.toString(d);
    }
}
