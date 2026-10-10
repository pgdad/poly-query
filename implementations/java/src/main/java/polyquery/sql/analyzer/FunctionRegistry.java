package polyquery.sql.analyzer;

import java.util.Locale;
import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.AggregateCall.AggregateFunction;

/** Knows which function names exist and their arities (functions.md). */
public final class FunctionRegistry {
    private record Arity(int min, int max) {
    }

    private static final int MANY = Integer.MAX_VALUE;

    private static final Map<String, Arity> SCALARS = Map.ofEntries(
            Map.entry("ABS", new Arity(1, 1)),
            Map.entry("ROUND", new Arity(1, 2)),
            Map.entry("FLOOR", new Arity(1, 1)),
            Map.entry("CEIL", new Arity(1, 1)),
            Map.entry("CEILING", new Arity(1, 1)),
            Map.entry("SQRT", new Arity(1, 1)),
            Map.entry("POWER", new Arity(2, 2)),
            Map.entry("MOD", new Arity(2, 2)),
            Map.entry("LENGTH", new Arity(1, 1)),
            Map.entry("UPPER", new Arity(1, 1)),
            Map.entry("LOWER", new Arity(1, 1)),
            Map.entry("SUBSTR", new Arity(2, 3)),
            Map.entry("SUBSTRING", new Arity(2, 3)),
            Map.entry("TRIM", new Arity(1, 1)),
            Map.entry("LTRIM", new Arity(1, 1)),
            Map.entry("RTRIM", new Arity(1, 1)),
            Map.entry("REPLACE", new Arity(3, 3)),
            Map.entry("CONCAT", new Arity(1, MANY)),
            Map.entry("COALESCE", new Arity(1, MANY)),
            Map.entry("NULLIF", new Arity(2, 2)),
            Map.entry("YEAR", new Arity(1, 1)),
            Map.entry("MONTH", new Arity(1, 1)),
            Map.entry("DAY", new Arity(1, 1)),
            Map.entry("HOUR", new Arity(1, 1)),
            Map.entry("MINUTE", new Arity(1, 1)),
            Map.entry("SECOND", new Arity(1, 1)),
            Map.entry("DATE_TRUNC", new Arity(2, 2)),
            Map.entry("DATE_DIFF", new Arity(3, 3)));

    private final boolean testFunctions;

    public FunctionRegistry(boolean testFunctions) {
        this.testFunctions = testFunctions;
    }

    public static AggregateFunction aggregate(String name) {
        return switch (name.toUpperCase(Locale.ROOT)) {
            case "COUNT" -> AggregateFunction.COUNT;
            case "SUM" -> AggregateFunction.SUM;
            case "AVG" -> AggregateFunction.AVG;
            case "MIN" -> AggregateFunction.MIN;
            case "MAX" -> AggregateFunction.MAX;
            default -> null;
        };
    }

    public boolean isTestFunction(String upperName) {
        return testFunctions && upperName.equals("PQ_SLEEP");
    }

    static boolean isScalar(String upperName) {
        return SCALARS.containsKey(upperName);
    }

    /** SEMANTIC_ERROR unless the scalar function accepts {@code n} arguments. */
    static void checkArity(String upperName, int n) {
        Arity a = SCALARS.get(upperName);
        if (n < a.min() || n > a.max()) {
            String expected = a.min() == a.max() ? Integer.toString(a.min())
                    : a.max() == MANY ? "at least " + a.min() : a.min() + " to " + a.max();
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "%s takes %s argument(s), got %d",
                    upperName, expected, n);
        }
    }
}
