package polyquery.ingest;

import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

final class IngestErrors {
    static final int MAX_FIELD_CHARS = 16 * 1024 * 1024;

    private IngestErrors() {
    }

    static PolyQueryException ingest(String msg, long record) {
        PolyQueryException e = new PolyQueryException(ErrorCode.INGEST_ERROR,
                record > 0 ? msg + " (record " + record + ")" : msg);
        if (record > 0) {
            e.withDetail("record", record);
        }
        return e;
    }

    static PolyQueryException conversion(String value, String column, Object type, long record) {
        String shown = value.length() > 64 ? value.substring(0, 64) + "..." : value;
        PolyQueryException e = new PolyQueryException(ErrorCode.CONVERSION_ERROR,
                "cannot convert '" + shown + "' to " + type + " in column '" + column + "' (record " + record + ")");
        e.withDetail("record", record).withDetail("column_name", column);
        return e;
    }

    static PolyQueryException tooManyRows(long max) {
        return new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "table exceeds the maximum of " + max + " rows");
    }
}
