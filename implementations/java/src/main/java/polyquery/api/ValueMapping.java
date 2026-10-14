package polyquery.api;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;

/**
 * Conversion between the engine's runtime representation of values (see
 * {@link polyquery.types.DataType}) and the typed Java values of the public API.
 */
final class ValueMapping {
    private static final LocalDate MIN_DATE = LocalDate.of(1, 1, 1);
    private static final LocalDate MAX_DATE = LocalDate.of(9999, 12, 31);

    private ValueMapping() {
    }

    /** The API type of an engine type; the engine's NULL type is reported as STRING (types.md §1). */
    static ColumnType toApi(DataType type) {
        return switch (type.kind()) {
            case BOOLEAN -> ColumnType.BOOLEAN;
            case INT64 -> ColumnType.INT64;
            case DECIMAL -> ColumnType.decimal(type.precision(), type.scale());
            case FLOAT64 -> ColumnType.FLOAT64;
            case STRING, NULL -> ColumnType.STRING;
            case DATE -> ColumnType.DATE;
            case TIMESTAMP -> ColumnType.TIMESTAMP;
        };
    }

    static DataType toEngine(ColumnType type) {
        return switch (type.kind()) {
            case BOOLEAN -> DataType.BOOLEAN;
            case INT64 -> DataType.INT64;
            case DECIMAL -> DataType.decimal(type.precision(), type.scale());
            case FLOAT64 -> DataType.FLOAT64;
            case STRING -> DataType.STRING;
            case DATE -> DataType.DATE;
            case TIMESTAMP -> DataType.TIMESTAMP;
        };
    }

    /** An engine runtime value as the API's Java value ({@code null} for NULL). */
    static Object toApi(Object v, DataType type) {
        if (v == null) {
            return null;
        }
        return switch (type.kind()) {
            case DECIMAL -> v instanceof BigInteger big ? new BigDecimal(big, type.scale())
                    : BigDecimal.valueOf((Long) v, type.scale());
            case DATE -> LocalDate.ofEpochDay((Integer) v);
            case TIMESTAMP -> timestamp((Long) v);
            case NULL -> null;
            default -> v;
        };
    }

    private static LocalDateTime timestamp(long micros) {
        long seconds = Math.floorDiv(micros, DateTimes.MICROS_PER_SECOND);
        int nanos = (int) Math.floorMod(micros, DateTimes.MICROS_PER_SECOND) * 1000;
        return LocalDateTime.ofEpochSecond(seconds, nanos, ZoneOffset.UTC);
    }

    /**
     * An API value as the engine's runtime value of {@code type}.
     *
     * @throws DatabaseException TYPE_ERROR for a Java value of the wrong class, NUMERIC_OVERFLOW
     *                           for a DECIMAL beyond the precision, INVALID_ARGUMENT for a value
     *                           outside the type's range
     */
    static Object toEngine(Object v, DataType type, String column) {
        if (v == null) {
            return null;
        }
        Object out = switch (type.kind()) {
            case BOOLEAN -> v instanceof Boolean ? v : null;
            case INT64 -> v instanceof Long || v instanceof Integer || v instanceof Short || v instanceof Byte
                    ? (Object) ((Number) v).longValue() : null;
            case DECIMAL -> decimal(v, type, column);
            case FLOAT64 -> v instanceof Double || v instanceof Float ? finite(((Number) v).doubleValue(), column) : null;
            case STRING -> v instanceof String ? v : null;
            case DATE -> v instanceof LocalDate d ? date(d, column) : null;
            case TIMESTAMP -> v instanceof LocalDateTime t ? timestamp(t, column) : null;
            case NULL -> throw new IllegalStateException("NULL type");
        };
        if (out == null) {
            throw new DatabaseException(ErrorCode.TYPE_ERROR, "column '" + column + "' of type " + type
                    + " cannot hold a value of class " + v.getClass().getName());
        }
        return out;
    }

    private static Object decimal(Object v, DataType type, String column) {
        BigDecimal d = switch (v) {
            case BigDecimal b -> b;
            case BigInteger b -> new BigDecimal(b);
            case Long l -> BigDecimal.valueOf(l);
            case Integer i -> BigDecimal.valueOf(i);
            default -> null;
        };
        if (d == null) {
            return null;
        }
        BigInteger unscaled = d.setScale(type.scale(), RoundingMode.HALF_UP).unscaledValue();
        if (!Decimals.fitsPrecision(unscaled, type.precision())) {
            throw new DatabaseException(ErrorCode.NUMERIC_OVERFLOW, "value " + d.toPlainString()
                    + " does not fit column '" + column + "' of type " + type);
        }
        return type.isWideDecimal() ? unscaled : (Object) unscaled.longValue();
    }

    private static Double finite(double d, String column) {
        if (!Double.isFinite(d)) {
            throw new DatabaseException(ErrorCode.INVALID_ARGUMENT, "non-finite FLOAT64 value in column '" + column + "'");
        }
        return d;
    }

    private static Integer date(LocalDate d, String column) {
        if (d.isBefore(MIN_DATE) || d.isAfter(MAX_DATE)) {
            throw new DatabaseException(ErrorCode.INVALID_ARGUMENT, "date " + d + " in column '" + column
                    + "' is outside 0001-01-01..9999-12-31");
        }
        return (int) d.toEpochDay();
    }

    private static Long timestamp(LocalDateTime t, String column) {
        if (t.toLocalDate().isBefore(MIN_DATE) || t.toLocalDate().isAfter(MAX_DATE)) {
            throw new DatabaseException(ErrorCode.INVALID_ARGUMENT, "timestamp " + t + " in column '" + column
                    + "' is outside the TIMESTAMP range");
        }
        return t.toEpochSecond(ZoneOffset.UTC) * DateTimes.MICROS_PER_SECOND + t.getNano() / 1000;
    }
}
