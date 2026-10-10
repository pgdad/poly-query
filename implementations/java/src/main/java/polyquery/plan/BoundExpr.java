package polyquery.plan;

import java.util.List;
import polyquery.types.DataType;

/**
 * A resolved, typed expression. Produced by semantic analysis; operands of binary operators
 * have already been coerced to a common type family by explicit {@link Cast} nodes.
 */
public sealed interface BoundExpr {
    DataType type();

    /** Reference to slot {@code index} of the input row. */
    record ColumnRef(int index, DataType type, String name) implements BoundExpr {
    }

    /**
     * Correlated reference to slot {@code index} of the current row of an enclosing query
     * level, identified by its correlation {@code frame}.
     */
    record OuterRef(int frame, int index, DataType type, String name) implements BoundExpr {
    }

    /**
     * The value of the operand shared by the comparisons of an {@link InList}, {@link Between},
     * {@link Case} (simple form), {@link NullIf} or the subquery values of an {@link InSubquery}.
     */
    record Placeholder(DataType type) implements BoundExpr {
    }

    record Literal(Object value, DataType type) implements BoundExpr {
    }

    /** Explicit CAST or implicit promotion. */
    record Cast(BoundExpr input, DataType type, boolean implicit) implements BoundExpr {
    }

    record Negate(BoundExpr input, DataType type) implements BoundExpr {
    }

    record Not(BoundExpr input) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    enum ArithOp { ADD, SUB, MUL, DIV, MOD }

    /** Arithmetic on operands of one family (INT64, DECIMAL with own scales, or FLOAT64). */
    record Arithmetic(ArithOp op, BoundExpr left, BoundExpr right, DataType type) implements BoundExpr {
    }

    enum CompareOp { EQ, NEQ, LT, LE, GT, GE }

    record Comparison(CompareOp op, BoundExpr left, BoundExpr right) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    record And(BoundExpr left, BoundExpr right) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    record Or(BoundExpr left, BoundExpr right) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    record IsNull(BoundExpr input, boolean negated) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    record Concat(BoundExpr left, BoundExpr right) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.STRING;
        }
    }

    /** {@code operand [NOT] LIKE pattern}; both STRING. */
    record Like(BoundExpr operand, BoundExpr pattern, boolean negated) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    /**
     * {@code operand [NOT] IN (items)}: {@code comparisons} are equality comparisons of a
     * {@link Placeholder} (the operand, evaluated once) with each item.
     */
    record InList(BoundExpr operand, List<BoundExpr> comparisons, boolean negated) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    /**
     * {@code operand [NOT] BETWEEN low AND high} with the operand evaluated once: {@code lower} is
     * {@code placeholder >= low}, {@code upper} is {@code placeholder <= high}.
     */
    record Between(BoundExpr operand, BoundExpr lower, BoundExpr upper, boolean negated) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    /**
     * CASE expression. For the simple form {@code operand} is non-null and the conditions
     * compare a {@link Placeholder} with the WHEN values. Results are already cast to {@code type}.
     */
    record Case(BoundExpr operand, List<BoundExpr> conditions, List<BoundExpr> results, BoundExpr elseResult,
                DataType type) implements BoundExpr {
    }

    /** {@code NULLIF(operand, b)}: {@code equality} compares a {@link Placeholder} with b. */
    record NullIf(BoundExpr operand, BoundExpr equality) implements BoundExpr {
        @Override
        public DataType type() {
            return operand.type();
        }
    }

    /** Scalar function call (name upper-case). */
    record Function(String name, List<BoundExpr> args, DataType type) implements BoundExpr {
    }

    /** Reference to an aggregate result / group key slot of an aggregation's output row. */
    record AggregateRef(int index, DataType type) implements BoundExpr {
    }

    /** Scalar subquery: its single output column; NULL for no rows. */
    record ScalarSubquery(Subquery subquery, DataType type) implements BoundExpr {
    }

    /** {@code EXISTS (subquery)}. */
    record Exists(Subquery subquery) implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }

    /**
     * {@code operand [NOT] IN (subquery)}. {@code valueCast} converts a subquery value (as a
     * {@link Placeholder}) to the comparison type of {@code operand}.
     */
    record InSubquery(BoundExpr operand, Subquery subquery, BoundExpr valueCast, boolean negated)
            implements BoundExpr {
        @Override
        public DataType type() {
            return DataType.BOOLEAN;
        }
    }
}
