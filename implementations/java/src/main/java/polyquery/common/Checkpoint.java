package polyquery.common;

import java.util.function.Supplier;

/**
 * Cooperative timeout and cancellation checks for the stages of a query that run before (or
 * outside) its operators: lexing, parsing, binding, optimization, physical planning and
 * expression compilation (CR-6 §4: the timeout covers every stage). These layers have no
 * query control object at hand, so the engine installs the query's check for the current
 * thread ({@link #with}) and the stages call {@link #poll()} inside every loop or recursion
 * whose work grows with the size of the statement.
 *
 * <p>{@link #poll()} is cheap: it runs the installed check only every {@value #INTERVAL} calls.
 */
public final class Checkpoint {
    /** Polls between two real checks (a check reads the clock). */
    static final int INTERVAL = 256;

    private static final ThreadLocal<Scope> CURRENT = new ThreadLocal<>();

    private Checkpoint() {
    }

    /** The check installed on one thread, with the polls left until it runs. */
    private static final class Scope {
        private final Runnable check;
        private int countdown = INTERVAL;

        private Scope(Runnable check) {
            this.check = check;
        }
    }

    /**
     * Runs {@code body} with {@code check} (which throws, e.g. {@code TIMEOUT} or
     * {@code CANCELLED}, when the query must stop) installed for the current thread.
     */
    public static <T> T with(Runnable check, Supplier<T> body) {
        Scope previous = CURRENT.get();
        CURRENT.set(new Scope(check));
        try {
            return body.get();
        } finally {
            if (previous == null) {
                CURRENT.remove();
            } else {
                CURRENT.set(previous);
            }
        }
    }

    /** Runs the installed check every {@value #INTERVAL} calls (no-op without one). */
    public static void poll() {
        Scope scope = CURRENT.get();
        if (scope != null && --scope.countdown <= 0) {
            scope.countdown = INTERVAL;
            scope.check.run();
        }
    }

    /** Runs the installed check now (no-op without one). */
    public static void check() {
        Scope scope = CURRENT.get();
        if (scope != null) {
            scope.countdown = INTERVAL;
            scope.check.run();
        }
    }
}
