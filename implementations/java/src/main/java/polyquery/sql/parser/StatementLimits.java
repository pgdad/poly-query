package polyquery.sql.parser;

import java.nio.charset.StandardCharsets;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * The engine's limits on the size of one statement (CR-6, {@code spec/changes/expression-limits.md}),
 * each well above the required minimum. The parser enforces them; beyond a limit the statement
 * fails with {@code RESOURCE_LIMIT} naming the measure, before any later stage sees it.
 */
public final class StatementLimits {
    /** SQL text length in UTF-8 bytes (minimum 1 MiB). */
    public static final long MAX_TEXT_BYTES = 64L << 20;
    /**
     * Nesting depth: the most constructs enclosing any expression, a chain of binary operators of
     * one precedence level counting as one (minimum 1,000).
     */
    public static final int MAX_NESTING_DEPTH = 4096;
    /** Literals, column references and {@code *} arguments (minimum 25,000). */
    public static final int MAX_OPERANDS = 200_000;

    private StatementLimits() {
    }

    /** Fails if {@code sql} is longer than {@link #MAX_TEXT_BYTES} in UTF-8. */
    static void checkTextLength(String sql) {
        // a UTF-16 char takes at most 3 UTF-8 bytes (a surrogate pair: 4 bytes for 2 chars)
        if ((long) sql.length() * 3 <= MAX_TEXT_BYTES) {
            return;
        }
        if (sql.length() > MAX_TEXT_BYTES || sql.getBytes(StandardCharsets.UTF_8).length > MAX_TEXT_BYTES) {
            throw exceeded("text_length", "statement text length exceeds " + MAX_TEXT_BYTES + " bytes",
                    MAX_TEXT_BYTES);
        }
    }

    static PolyQueryException nestingDepthExceeded() {
        return exceeded("nesting_depth", "expression nesting depth exceeds " + MAX_NESTING_DEPTH,
                MAX_NESTING_DEPTH);
    }

    static PolyQueryException operandCountExceeded() {
        return exceeded("operand_count", "statement operand count exceeds " + MAX_OPERANDS, MAX_OPERANDS);
    }

    private static PolyQueryException exceeded(String measure, String message, long limit) {
        return new PolyQueryException(ErrorCode.RESOURCE_LIMIT, message)
                .withDetail("measure", measure)
                .withDetail("limit", limit);
    }
}
