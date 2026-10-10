package polyquery.protocol;

import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

final class RequestException {
    private RequestException() {
    }

    static PolyQueryException invalid(String fmt, Object... args) {
        return PolyQueryException.of(ErrorCode.INVALID_REQUEST, fmt, args);
    }
}
