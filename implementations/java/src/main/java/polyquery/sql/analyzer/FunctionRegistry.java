package polyquery.sql.analyzer;

import java.util.Locale;
import java.util.Set;
import polyquery.plan.AggregateCall.AggregateFunction;

/** Knows which function names exist and which this engine implements. */
public final class FunctionRegistry {
    /** Scalar functions of functions.md that belong to the (unimplemented) sql.functions capability. */
    private static final Set<String> PHASE2_SCALARS = Set.of(
            "ABS", "ROUND", "FLOOR", "CEIL", "CEILING", "SQRT", "POWER", "MOD", "LENGTH", "UPPER",
            "LOWER", "SUBSTR", "SUBSTRING", "TRIM", "LTRIM", "RTRIM", "REPLACE", "CONCAT", "COALESCE",
            "NULLIF", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "DATE_TRUNC", "DATE_DIFF");

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

    public boolean isUnimplemented(String upperName) {
        return PHASE2_SCALARS.contains(upperName);
    }
}
