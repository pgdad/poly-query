package polyquery.common;

/** Stable error codes of the PolyQuery protocol (spec/errors/error-codes.json). */
public enum ErrorCode {
    PARSE_ERROR(400),
    SEMANTIC_ERROR(400),
    TYPE_ERROR(400),
    NUMERIC_OVERFLOW(400),
    DIVISION_BY_ZERO(400),
    CONVERSION_ERROR(400),
    INVALID_ARGUMENT(400),
    SUBQUERY_CARDINALITY(400),
    INVALID_REQUEST(400),
    INGEST_ERROR(400),
    UNSUPPORTED(400),
    ACCESS_DENIED(403),
    NOT_FOUND(404),
    ALREADY_EXISTS(409),
    CANCELLED(409),
    RESOURCE_LIMIT(413),
    IO_ERROR(500),
    STORAGE_CORRUPT(500),
    STORAGE_VERSION_UNSUPPORTED(500),
    INTERNAL_ERROR(500),
    OVERLOADED(503),
    SHUTTING_DOWN(503),
    TIMEOUT(504);

    private final int httpStatus;

    ErrorCode(int httpStatus) {
        this.httpStatus = httpStatus;
    }

    public int httpStatus() {
        return httpStatus;
    }
}
