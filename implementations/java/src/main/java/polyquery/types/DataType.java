package polyquery.types;

import java.util.Locale;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * A PolyQuery data type. Precision and scale are only meaningful for DECIMAL.
 *
 * <p>Runtime value representation (used throughout storage and execution):
 * BOOLEAN → {@link Boolean}, INT64 → {@link Long}, narrow DECIMAL (precision ≤ 18) →
 * {@link Long} unscaled value, wide DECIMAL (precision 19–38) → {@link java.math.BigInteger}
 * unscaled value, FLOAT64 → {@link Double}, STRING → {@link String}, DATE → {@link Integer} days since epoch,
 * TIMESTAMP → {@link Long} microseconds since epoch, NULL → {@code null}.
 */
public record DataType(TypeKind kind, int precision, int scale) {
    /** Largest DECIMAL precision (CR-2). */
    public static final int MAX_DECIMAL_PRECISION = 38;
    /** Largest precision of a narrow DECIMAL; the result precision of narrow arithmetic. */
    public static final int NARROW_DECIMAL_PRECISION = 18;

    public static final DataType BOOLEAN = new DataType(TypeKind.BOOLEAN, 0, 0);
    public static final DataType INT64 = new DataType(TypeKind.INT64, 0, 0);
    public static final DataType FLOAT64 = new DataType(TypeKind.FLOAT64, 0, 0);
    public static final DataType STRING = new DataType(TypeKind.STRING, 0, 0);
    public static final DataType DATE = new DataType(TypeKind.DATE, 0, 0);
    public static final DataType TIMESTAMP = new DataType(TypeKind.TIMESTAMP, 0, 0);
    public static final DataType NULL = new DataType(TypeKind.NULL, 0, 0);

    public static DataType decimal(int precision, int scale) {
        if (precision < 1 || precision > MAX_DECIMAL_PRECISION || scale < 0 || scale > precision) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR,
                    "invalid DECIMAL parameters (%d,%d)", precision, scale);
        }
        return new DataType(TypeKind.DECIMAL, precision, scale);
    }

    /** A DECIMAL of precision 19–38, represented by a {@link java.math.BigInteger} unscaled value. */
    public boolean isWideDecimal() {
        return kind == TypeKind.DECIMAL && precision > NARROW_DECIMAL_PRECISION;
    }

    /** INT64 or DECIMAL: exact numbers, comparable with each other by value. */
    public boolean isExactNumeric() {
        return kind == TypeKind.INT64 || kind == TypeKind.DECIMAL;
    }

    /** The scale of an exact numeric type (0 for INT64). */
    public int exactScale() {
        return kind == TypeKind.DECIMAL ? scale : 0;
    }

    public boolean isNumeric() {
        return kind.isNumeric();
    }

    public boolean isNull() {
        return kind == TypeKind.NULL;
    }

    /** Canonical type name; the null type is reported as STRING (types.md §1). */
    @Override
    public String toString() {
        return switch (kind) {
            case DECIMAL -> "DECIMAL(" + precision + "," + scale + ")";
            case NULL -> "STRING";
            default -> kind.name();
        };
    }

    /**
     * Parses a type name with aliases (types.md §1), e.g. {@code int}, {@code NUMERIC(10,2)}.
     *
     * @throws IllegalArgumentException if the name is not a known type
     * @throws PolyQueryException SEMANTIC_ERROR for invalid DECIMAL parameters
     */
    public static DataType parse(String text) {
        String t = text.trim();
        int paren = t.indexOf('(');
        String base = (paren < 0 ? t : t.substring(0, paren)).trim();
        Integer p = null;
        Integer s = null;
        if (paren >= 0) {
            if (!t.endsWith(")")) {
                throw new IllegalArgumentException("malformed type '" + text + "'");
            }
            String[] parts = t.substring(paren + 1, t.length() - 1).split(",", -1);
            if (parts.length > 2) {
                throw new IllegalArgumentException("malformed type '" + text + "'");
            }
            try {
                p = Integer.parseInt(parts[0].trim());
                if (parts.length == 2) {
                    s = Integer.parseInt(parts[1].trim());
                }
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("malformed type '" + text + "'");
            }
        }
        return fromName(base, p, s);
    }

    /** Resolves a base type name plus optional parameters. */
    public static DataType fromName(String name, Integer precision, Integer scale) {
        String n = name.toUpperCase(Locale.ROOT);
        DataType simple = switch (n) {
            case "BOOLEAN", "BOOL" -> BOOLEAN;
            case "INT64", "INT", "INTEGER", "BIGINT" -> INT64;
            case "FLOAT64", "DOUBLE", "FLOAT", "REAL" -> FLOAT64;
            case "STRING", "VARCHAR", "TEXT" -> STRING;
            case "DATE" -> DATE;
            case "TIMESTAMP" -> TIMESTAMP;
            case "DECIMAL", "NUMERIC" -> null;
            default -> throw new IllegalArgumentException("unknown type '" + name + "'");
        };
        if (simple != null) {
            if (precision != null) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "type %s takes no parameters", n);
            }
            return simple;
        }
        if (precision == null) {
            return decimal(NARROW_DECIMAL_PRECISION, 0);
        }
        return decimal(precision, scale == null ? 0 : scale);
    }
}
