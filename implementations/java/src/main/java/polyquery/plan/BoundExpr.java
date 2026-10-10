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

    /** Scalar function call (name upper-case). */
    record Function(String name, List<BoundExpr> args, DataType type) implements BoundExpr {
    }

    /** Reference to an aggregate result / group key slot of an aggregation's output row. */
    record AggregateRef(int index, DataType type) implements BoundExpr {
    }
}
