package polyquery.plan;

import polyquery.types.DataType;

/** An aggregate function application; {@code argument} is null for {@code COUNT(*)}. */
public record AggregateCall(AggregateFunction function, BoundExpr argument, boolean distinct, DataType type) {

    public enum AggregateFunction { COUNT_STAR, COUNT, SUM, AVG, MIN, MAX }
}
