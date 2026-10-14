package polyquery.api;

import java.util.Map;

/**
 * An error reported by the engine: a specification {@link ErrorCode} and a message, plus
 * optional structured details (e.g. {@code line} and {@code column} of a {@code PARSE_ERROR}).
 * The {@link Database} that threw it stays usable.
 */
public final class DatabaseException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    private final ErrorCode code;
    private final transient Map<String, Object> details;

    public DatabaseException(ErrorCode code, String message) {
        this(code, message, Map.of());
    }

    public DatabaseException(ErrorCode code, String message, Map<String, Object> details) {
        super(message);
        this.code = code;
        this.details = Map.copyOf(details);
    }

    /** The specification's error code, e.g. {@link ErrorCode#PARSE_ERROR}. */
    public ErrorCode code() {
        return code;
    }

    /** Structured details of the error (unmodifiable, often empty). */
    public Map<String, Object> details() {
        return details;
    }

    /** {@code CODE: message}. */
    @Override
    public String toString() {
        return code + ": " + getMessage();
    }
}
