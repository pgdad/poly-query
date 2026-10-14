package polyquery.api;

/**
 * The stable error codes of the PolyQuery specification ({@code spec/errors/error-codes.json}),
 * carried by every {@link DatabaseException}.
 */
public enum ErrorCode {
    PARSE_ERROR,
    SEMANTIC_ERROR,
    TYPE_ERROR,
    NUMERIC_OVERFLOW,
    DIVISION_BY_ZERO,
    CONVERSION_ERROR,
    INVALID_ARGUMENT,
    SUBQUERY_CARDINALITY,
    INVALID_REQUEST,
    INGEST_ERROR,
    UNSUPPORTED,
    ACCESS_DENIED,
    NOT_FOUND,
    ALREADY_EXISTS,
    CANCELLED,
    RESOURCE_LIMIT,
    IO_ERROR,
    STORAGE_CORRUPT,
    STORAGE_VERSION_UNSUPPORTED,
    INTERNAL_ERROR,
    OVERLOADED,
    SHUTTING_DOWN,
    TIMEOUT
}
