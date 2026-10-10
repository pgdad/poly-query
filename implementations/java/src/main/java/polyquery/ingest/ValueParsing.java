package polyquery.ingest;

import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.TextParsers;

/** Field-text conversion rules for ingestion with a known column type (ingestion.md §1.2). */
final class ValueParsing {
    private ValueParsing() {
    }

    /**
     * Converts already-trimmed, non-empty text to a non-STRING type.
     * Returns {@code null} if the text is not acceptable for the type.
     */
    static Object parse(String t, DataType type) {
        try {
            return switch (type.kind()) {
                case BOOLEAN -> TextParsers.parseBoolean(t);
                case INT64 -> TextParsers.parseInt64(t);
                case FLOAT64 -> TextParsers.parseFloat64(t);
                case DECIMAL -> TextParsers.parseDecimal(t, type.precision(), type.scale(), false);
                case DATE -> DateTimes.parseDate(t);
                case TIMESTAMP -> DateTimes.parseTimestamp(t, true);
                case STRING, NULL -> t;
            };
        } catch (ArithmeticException e) {
            return null;
        }
    }
}
