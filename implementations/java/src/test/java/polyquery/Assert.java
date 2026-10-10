package polyquery;

import java.util.Objects;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/** Tiny assertion helpers. */
final class Assert {
    private Assert() {
    }

    static void eq(Object expected, Object actual) {
        if (!Objects.equals(expected, actual)) {
            throw new AssertionError("expected <" + expected + "> but got <" + actual + ">");
        }
    }

    static void check(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError(msg);
        }
    }

    static void fails(ErrorCode code, Runnable r) {
        try {
            r.run();
        } catch (PolyQueryException e) {
            if (e.code() != code) {
                throw new AssertionError("expected " + code + " but got " + e.code() + ": " + e.getMessage());
            }
            return;
        }
        throw new AssertionError("expected " + code + " but succeeded");
    }
}
