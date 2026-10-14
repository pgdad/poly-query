package polyquery.api;

import java.util.Locale;

/**
 * A PolyQuery data type ({@code spec/data-types/types.md}). {@link #precision()} and
 * {@link #scale()} are only meaningful for {@link Kind#DECIMAL} (0 otherwise).
 *
 * @param kind      the type family
 * @param precision DECIMAL precision, 1–38
 * @param scale     DECIMAL scale, 0–precision
 */
public record ColumnType(Kind kind, int precision, int scale) {
    /** The type families and the Java class of their values in a {@link Result}. */
    public enum Kind {
        /** {@link Boolean}. */
        BOOLEAN,
        /** {@link Long}. */
        INT64,
        /** {@link java.math.BigDecimal} with exactly the type's scale. */
        DECIMAL,
        /** {@link Double}. */
        FLOAT64,
        /** {@link String}. */
        STRING,
        /** {@link java.time.LocalDate}. */
        DATE,
        /** {@link java.time.LocalDateTime} (no time zone, microsecond precision). */
        TIMESTAMP
    }

    /** Largest DECIMAL precision. */
    public static final int MAX_DECIMAL_PRECISION = 38;

    public static final ColumnType BOOLEAN = new ColumnType(Kind.BOOLEAN, 0, 0);
    public static final ColumnType INT64 = new ColumnType(Kind.INT64, 0, 0);
    public static final ColumnType FLOAT64 = new ColumnType(Kind.FLOAT64, 0, 0);
    public static final ColumnType STRING = new ColumnType(Kind.STRING, 0, 0);
    public static final ColumnType DATE = new ColumnType(Kind.DATE, 0, 0);
    public static final ColumnType TIMESTAMP = new ColumnType(Kind.TIMESTAMP, 0, 0);

    public ColumnType {
        if (kind == null) {
            throw new IllegalArgumentException("kind must not be null");
        }
        if (kind == Kind.DECIMAL) {
            if (precision < 1 || precision > MAX_DECIMAL_PRECISION || scale < 0 || scale > precision) {
                throw new IllegalArgumentException("invalid DECIMAL(" + precision + "," + scale + ")");
            }
        } else if (precision != 0 || scale != 0) {
            throw new IllegalArgumentException(kind + " takes no precision or scale");
        }
    }

    /** {@code DECIMAL(precision, scale)}. */
    public static ColumnType decimal(int precision, int scale) {
        return new ColumnType(Kind.DECIMAL, precision, scale);
    }

    /**
     * Parses a type name, accepting the aliases of types.md §1 ({@code BIGINT},
     * {@code NUMERIC(10,2)}, {@code TEXT}, …) case-insensitively.
     *
     * @throws IllegalArgumentException for an unknown or malformed type name
     */
    public static ColumnType parse(String name) {
        String t = name.trim();
        int paren = t.indexOf('(');
        String base = (paren < 0 ? t : t.substring(0, paren)).trim().toUpperCase(Locale.ROOT);
        int[] params = paren < 0 ? new int[0] : parameters(name, t.substring(paren));
        Kind simple = switch (base) {
            case "BOOLEAN", "BOOL" -> Kind.BOOLEAN;
            case "INT64", "INT", "INTEGER", "BIGINT" -> Kind.INT64;
            case "FLOAT64", "DOUBLE", "FLOAT", "REAL" -> Kind.FLOAT64;
            case "STRING", "VARCHAR", "TEXT" -> Kind.STRING;
            case "DATE" -> Kind.DATE;
            case "TIMESTAMP" -> Kind.TIMESTAMP;
            case "DECIMAL", "NUMERIC" -> Kind.DECIMAL;
            default -> throw new IllegalArgumentException("unknown type '" + name + "'");
        };
        if (simple != Kind.DECIMAL) {
            if (params.length > 0) {
                throw new IllegalArgumentException("type " + base + " takes no parameters");
            }
            return new ColumnType(simple, 0, 0);
        }
        return switch (params.length) {
            case 0 -> decimal(18, 0);
            case 1 -> decimal(params[0], 0);
            default -> decimal(params[0], params[1]);
        };
    }

    private static int[] parameters(String name, String text) {
        if (!text.endsWith(")")) {
            throw new IllegalArgumentException("malformed type '" + name + "'");
        }
        String[] parts = text.substring(1, text.length() - 1).split(",", -1);
        if (parts.length > 2) {
            throw new IllegalArgumentException("malformed type '" + name + "'");
        }
        int[] out = new int[parts.length];
        try {
            for (int i = 0; i < parts.length; i++) {
                out[i] = Integer.parseInt(parts[i].trim());
            }
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("malformed type '" + name + "'");
        }
        return out;
    }

    /** INT64, DECIMAL or FLOAT64. */
    public boolean isNumeric() {
        return kind == Kind.INT64 || kind == Kind.DECIMAL || kind == Kind.FLOAT64;
    }

    /** The canonical type name, e.g. {@code INT64} or {@code DECIMAL(18,2)}. */
    public String typeName() {
        return kind == Kind.DECIMAL ? "DECIMAL(" + precision + "," + scale + ")" : kind.name();
    }

    /** Same as {@link #typeName()}. */
    @Override
    public String toString() {
        return typeName();
    }
}
