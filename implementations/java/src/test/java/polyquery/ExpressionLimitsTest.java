package polyquery;

import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import polyquery.common.Checkpoint;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.engine.LoadRequest;
import polyquery.engine.QueryOptions;
import polyquery.exec.ExecMode;
import polyquery.physical.PhysicalPlanner.JoinStrategy;
import polyquery.sql.parser.Parser;
import polyquery.sql.parser.StatementLimits;

/** CR-6 (spec/changes/expression-limits.md): statement size limits, timeouts in every stage. */
final class ExpressionLimitsTest {
    private ExpressionLimitsTest() {
    }

    /** Runs {@code body} on a thread with the engine's query-thread stack size (deep statements recurse). */
    private static void deep(Runnable body) {
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread t = new Thread(null, () -> {
            try {
                body.run();
            } catch (Throwable e) {
                failure.set(e);
            }
        }, "deep-test", 512L << 20);
        t.start();
        try {
            t.join();
        } catch (InterruptedException e) {
            throw new AssertionError(e);
        }
        if (failure.get() instanceof RuntimeException r) {
            throw r;
        }
        if (failure.get() instanceof Error e) {
            throw e;
        }
    }

    private static String nest(int n, String open, String core, String close) {
        return open.repeat(n) + core + close.repeat(n);
    }

    private static String where(String predicate) {
        return "SELECT count(*) FROM n WHERE " + predicate;
    }

    private static String chain(int terms, String op, String term) {
        StringBuilder sb = new StringBuilder(term.replace("#", "0"));
        for (int i = 1; i < terms; i++) {
            sb.append(' ').append(op).append(' ').append(term.replace("#", String.valueOf(i)));
        }
        return sb.toString();
    }

    private static void limitExceeded(String measure, String sql) {
        try {
            Parser.parse(sql);
        } catch (PolyQueryException e) {
            Assert.eq(ErrorCode.RESOURCE_LIMIT, e.code());
            Assert.eq(measure, e.details().get("measure"));
            return;
        }
        throw new AssertionError("expected RESOURCE_LIMIT (" + measure + ")");
    }

    static void testNestingDepthIsMeasuredAsSpecified() {
        deep(() -> {
            int max = StatementLimits.MAX_NESTING_DEPTH;
            // the comparison is one level, each parenthesis one more
            Parser.parse(where(nest(max - 1, "(", "x >= 0", ")")));
            limitExceeded("nesting_depth", where(nest(max, "(", "x >= 0", ")")));
            limitExceeded("nesting_depth", where(nest(100_000, "(", "x >= 0", ")")));
            // a chain of one precedence level is one level, whatever its length
            Parser.parse(where(nest(max - 2, "(", chain(5_000, "OR", "x = #"), ")")));
            Parser.parse("SELECT " + nest(max - 1, "ABS(", chain(5_000, "+", "#"), ")"));
            limitExceeded("nesting_depth", "SELECT " + nest(max, "ABS(", chain(2, "+", "#"), ")"));
            // a construct's left operand is enclosed by it too: ((…) = TRUE) nests two levels a time
            Parser.parse(where(nest(max / 2 - 1, "(", "x >= 0", ") = TRUE")));
            limitExceeded("nesting_depth", where(nest(max / 2, "(", "x >= 0", ") = TRUE")));
            // prefix constructs and subqueries
            limitExceeded("nesting_depth", where("NOT ".repeat(max) + "x >= 0"));
            limitExceeded("nesting_depth", where("- ".repeat(max) + "x >= 0"));
            limitExceeded("nesting_depth", where("x >= " + nest(max, "(SELECT ", "1", ")")));
            Parser.parse("SELECT * FROM " + nest(max, "(SELECT * FROM ", "n", ") t"));
            limitExceeded("nesting_depth", "SELECT * FROM " + nest(max + 1, "(SELECT * FROM ", "n", ") t"));
        });
    }

    static void testMinimumsParse() {
        deep(() -> {
            Parser.parse(where(nest(998, "(", "x >= 0", ")")));
            Parser.parse(where(nest(998, "ABS(", "x", ")") + " >= 0"));
            Parser.parse(where("- ".repeat(998) + "x >= 0"));
            Parser.parse(where("NOT ".repeat(998) + "x >= 0"));
            Parser.parse(where(nest(998, "CAST(", "x", " AS BIGINT)") + " >= 0"));
            Parser.parse(where("x >= " + nest(997, "(SELECT ", "0", ")")));
            Parser.parse("SELECT count(*) FROM " + nest(998, "(SELECT * FROM ", "n", ") t"));
            Parser.parse(where(chain(12_500, "OR", "x = #")));
            String lit = "a".repeat(524_000);
            Parser.parse(where("'" + lit + "' = '" + lit + "'"));
        });
    }

    static void testOperandCount() {
        StringBuilder in = new StringBuilder("x IN (0");
        for (int i = 1; i < StatementLimits.MAX_OPERANDS - 2; i++) {
            in.append(',').append(i);
        }
        // x, the items and the * of count(*)
        Parser.parse(where(in + ")"));
        limitExceeded("operand_count", where(in + ",-1)"));
        limitExceeded("operand_count", where(chain(100_001, "OR", "x = #")));
    }

    static void testTextLength() {
        int max = (int) StatementLimits.MAX_TEXT_BYTES;
        String head = "SELECT 1 -- ";
        Parser.parse(head + "a".repeat(max - head.length()));
        limitExceeded("text_length", head + "a".repeat(max - head.length() + 1));
        // measured in UTF-8 bytes: 'é' takes two
        limitExceeded("text_length", head + "é".repeat(max / 2));
    }

    static void testParsingPollsTheTimeout() {
        String sql = where(chain(50_000, "OR", "x = #"));
        int[] polls = {0};
        Assert.fails(ErrorCode.TIMEOUT, () -> Checkpoint.with(() -> {
            if (++polls[0] > 10) {
                throw new PolyQueryException(ErrorCode.TIMEOUT, "query exceeded its timeout");
            }
        }, () -> Parser.parse(sql)));
        Parser.parse(sql); // no check installed outside the scope
    }

    private static Engine engine() {
        Engine e = EngineTest.engine();
        StringBuilder csv = new StringBuilder("x\n");
        for (int i = 0; i < 100; i++) {
            csv.append(i).append('\n');
        }
        e.load(new LoadRequest("n", "csv", null, csv.toString(), null, true, ',', false));
        return e;
    }

    /** Runs {@code sql} in every execution mode (tiny morsels: really parallel) and checks the first cell. */
    private static void inEveryMode(Engine e, String sql, Object expected) {
        String saved = System.getProperty("polyquery.morselRows");
        System.setProperty("polyquery.morselRows", "16");
        try {
            for (QueryOptions o : List.of(
                    new QueryOptions(-1, 0, false, true, JoinStrategy.AUTO, true, ExecMode.ROW, 1),
                    new QueryOptions(-1, 0, false, true, JoinStrategy.AUTO, true, ExecMode.VECTORIZED, 1),
                    new QueryOptions(-1, 0, false, true, JoinStrategy.AUTO, true, ExecMode.VECTORIZED, 4),
                    new QueryOptions(-1, 0, false, false, JoinStrategy.AUTO, true, ExecMode.VECTORIZED, 4))) {
                Assert.eq(expected, e.query(sql, o).rows().getFirst()[0]);
            }
        } finally {
            if (saved == null) {
                System.clearProperty("polyquery.morselRows");
            } else {
                System.setProperty("polyquery.morselRows", saved);
            }
        }
    }

    static void testLargeStatementsInEveryMode() {
        deep(() -> {
            Engine e = engine();
            inEveryMode(e, where(chain(10_000, "OR", "x = #")), 100L);
            inEveryMode(e, where(chain(10_000, "AND", "x <> -#") + " AND x <> 0"), 99L);
            inEveryMode(e, "SELECT max(x" + " + 1".repeat(9_999) + ") FROM n", 99L + 9_999);
            inEveryMode(e, "SELECT max(length(CAST(x AS VARCHAR)" + " || 'ab'".repeat(9_999) + ")) FROM n",
                    2L + 2 * 9_999);
            inEveryMode(e, where(nest(998, "ABS(", "x", ")") + " >= 0"), 100L);
            inEveryMode(e, where("x >= " + nest(997, "(SELECT ", "0", ")")), 100L);
            inEveryMode(e, "SELECT count(*) FROM " + nest(998, "(SELECT x FROM ", "n", " WHERE x >= 0) t"), 100L);
        });
    }

    static void testConcatChainSemantics() {
        Engine e = engine();
        inEveryMode(e, "SELECT max('a' || CAST(x AS VARCHAR) || 'b' || 'c') FROM n WHERE x = 7", "a7bc");
        inEveryMode(e, "SELECT count('a' || CASE WHEN x > 5 THEN NULL ELSE 'x' END || 'b') FROM n", 6L);
    }

    static void testFailingConstantsKeepTheirErrors() {
        deep(() -> {
            Engine e = engine();
            String failing = "(1 / 0" + " + 1".repeat(5_000) + ")";
            inEveryMode(e, "SELECT count(*) FROM n WHERE x < 0 AND x + " + failing + " > 0", 0L);
            inEveryMode(e, "SELECT count(*) FROM n WHERE x < 1 AND CASE WHEN x > 5 THEN " + failing
                    + " ELSE 1 END > 0", 1L);
            Assert.fails(ErrorCode.DIVISION_BY_ZERO, () -> e.query("SELECT x + " + failing + " FROM n",
                    QueryOptions.DEFAULT));
        });
    }
}
