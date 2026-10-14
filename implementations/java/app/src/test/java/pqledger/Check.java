package pqledger;

import java.util.Objects;

/** Tiny assertion helpers for the application's tests. */
public final class Check {
    private Check() {
    }

    /** Code that is expected to throw. */
    @FunctionalInterface
    public interface Failing {
        void run() throws Exception;
    }

    public static void eq(Object expected, Object actual) {
        if (!Objects.equals(expected, actual)) {
            throw new AssertionError("expected <" + expected + "> but got <" + actual + ">");
        }
    }

    public static void isTrue(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    /** Asserts that {@code code} throws an {@link AppException} with exit status {@code expected}. */
    public static AppException fails(ExitCode expected, Failing code) {
        try {
            code.run();
        } catch (AppException e) {
            if (e.exitCode() != expected) {
                throw new AssertionError("expected " + expected + " but got " + e.exitCode() + ": " + e.getMessage());
            }
            return e;
        } catch (Exception e) {
            throw new AssertionError("expected " + expected + " but got " + e, e);
        }
        throw new AssertionError("expected " + expected + " but succeeded");
    }

    /** Asserts that {@code code} throws {@link IllegalArgumentException}. */
    public static void invalid(Runnable code) {
        try {
            code.run();
        } catch (IllegalArgumentException e) {
            return;
        }
        throw new AssertionError("expected IllegalArgumentException");
    }
}
