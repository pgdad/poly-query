package pqledger.output;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.LocalDateTime;
import polyquery.api.ColumnType;

/** The value text of spec §7, used by the table and CSV formats. */
public final class ValueText {
    private ValueText() {
    }

    /** The text of {@code value} (a Java value of the API) in a column of {@code type}; "" for NULL. */
    public static String of(Object value, ColumnType type) {
        if (value == null) {
            return "";
        }
        return switch (type.kind()) {
            case DECIMAL -> ((BigDecimal) value).toPlainString();
            case FLOAT64 -> float64((Double) value);
            case DATE -> date((LocalDate) value);
            case TIMESTAMP -> timestamp((LocalDateTime) value);
            case BOOLEAN, INT64, STRING -> value.toString();
        };
    }

    /** Like C {@code printf("%.6f")}, with {@code -0.000000} printed as {@code 0.000000}. */
    static String float64(double d) {
        if (Double.isNaN(d)) {
            return "nan";
        }
        if (Double.isInfinite(d)) {
            return d > 0 ? "inf" : "-inf";
        }
        // BigDecimal(double) is exact; HALF_EVEN on the exact value is what printf does
        return new BigDecimal(d).setScale(6, RoundingMode.HALF_EVEN).toPlainString();
    }

    /** {@code YYYY-MM-DD} (ISO-8601 pads years 1–999 to four digits). */
    static String date(LocalDate d) {
        return d.toString();
    }

    static String timestamp(LocalDateTime t) {
        String s = date(t.toLocalDate()) + String.format(" %02d:%02d:%02d", t.getHour(), t.getMinute(), t.getSecond());
        int micros = t.getNano() / 1000;
        return micros == 0 ? s : s + String.format(".%06d", micros);
    }
}
