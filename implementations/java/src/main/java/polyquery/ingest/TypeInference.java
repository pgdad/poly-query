package polyquery.ingest;

import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.TextParsers;

/** Tracks which candidate types still match every value of a CSV column (ingestion.md §1.1). */
final class TypeInference {
    private boolean any;
    private boolean bool = true;
    private boolean int64 = true;
    private boolean float64 = true;
    private boolean date = true;
    private boolean timestamp = true;

    /** Observes a trimmed, non-empty field text. */
    void observe(String t) {
        any = true;
        if (bool && TextParsers.parseBoolean(t) == null) {
            bool = false;
        }
        if (int64) {
            try {
                if (TextParsers.parseInt64(t) == null) {
                    int64 = false;
                }
            } catch (ArithmeticException e) {
                int64 = false;
            }
        }
        if (float64) {
            try {
                if (TextParsers.parseFloat64(t) == null) {
                    float64 = false;
                }
            } catch (ArithmeticException e) {
                float64 = false;
            }
        }
        if (date || timestamp) {
            boolean isDate = DateTimes.parseDate(t) != null;
            if (!isDate) {
                date = false;
                if (timestamp && DateTimes.parseTimestamp(t, false) == null) {
                    timestamp = false;
                }
            }
        }
    }

    boolean stillNumericOrTemporal() {
        return bool || int64 || float64 || date || timestamp;
    }

    DataType result() {
        if (!any) {
            return DataType.STRING;
        }
        if (bool) {
            return DataType.BOOLEAN;
        }
        if (int64) {
            return DataType.INT64;
        }
        if (float64) {
            return DataType.FLOAT64;
        }
        if (date) {
            return DataType.DATE;
        }
        if (timestamp) {
            return DataType.TIMESTAMP;
        }
        return DataType.STRING;
    }
}
