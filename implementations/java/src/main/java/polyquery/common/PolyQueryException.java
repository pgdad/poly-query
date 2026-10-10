package polyquery.common;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The single exception type used to report protocol-visible failures. Carries a stable
 * {@link ErrorCode}, a human readable message and optional structured details.
 */
public class PolyQueryException extends RuntimeException {
    private final ErrorCode code;
    private final Map<String, Object> details;

    public PolyQueryException(ErrorCode code, String message) {
        this(code, message, null);
    }

    public PolyQueryException(ErrorCode code, String message, Map<String, Object> details) {
        super(message, null, false, false);
        this.code = code;
        this.details = details == null ? new LinkedHashMap<>() : new LinkedHashMap<>(details);
    }

    public ErrorCode code() {
        return code;
    }

    public Map<String, Object> details() {
        return details;
    }

    public PolyQueryException withDetail(String key, Object value) {
        details.put(key, value);
        return this;
    }

    public static PolyQueryException of(ErrorCode code, String format, Object... args) {
        return new PolyQueryException(code, args.length == 0 ? format : String.format(format, args));
    }

    public static PolyQueryException parse(String message, int line, int column) {
        PolyQueryException e = new PolyQueryException(ErrorCode.PARSE_ERROR, message);
        e.details.put("line", (long) line);
        e.details.put("column", (long) column);
        return e;
    }
}
