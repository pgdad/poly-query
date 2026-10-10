package polyquery.physical;

import java.util.ArrayList;
import java.util.List;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;

/** Physical operators: a logical plan with concrete algorithms chosen. */
public sealed interface PhysicalPlan {
    List<ColumnSchema> schema();

    List<PhysicalPlan> children();

    record TableScan(Table table, String alias) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return table.columns();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of();
        }
    }

    /** A single row without columns. */
    record Values() implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return List.of();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of();
        }
    }

    record Filter(PhysicalPlan input, BoundExpr predicate) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }
    }

    record Project(PhysicalPlan input, List<BoundExpr> expressions, List<String> names) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            List<ColumnSchema> out = new ArrayList<>();
            for (int i = 0; i < expressions.size(); i++) {
                out.add(new ColumnSchema(names.get(i), expressions.get(i).type()));
            }
            return out;
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }
    }

    /** Hash aggregation; output rows are group keys followed by aggregate results. */
    record HashAggregate(PhysicalPlan input, List<BoundExpr> groupKeys, List<AggregateCall> aggregates)
            implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return new LogicalPlan.Aggregate(new LogicalPlan.SingleRow(), groupKeys, aggregates).schema();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }
    }

    record HashDistinct(PhysicalPlan input) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }
    }

    /**
     * Equi-join: builds a hash table on the right input keyed by {@code rightKeys} (over right
     * rows), probes with {@code leftKeys} (over left rows); {@code residual} (over the combined
     * row, may be null) filters candidate pairs.
     */
    record HashJoin(PhysicalPlan left, PhysicalPlan right, LogicalPlan.JoinKind kind, List<BoundExpr> leftKeys,
                    List<BoundExpr> rightKeys, BoundExpr residual) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return concat(left, right);
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(left, right);
        }
    }

    /** Join evaluating {@code condition} (null = TRUE) for every pair of rows. */
    record NestedLoopJoin(PhysicalPlan left, PhysicalPlan right, LogicalPlan.JoinKind kind, BoundExpr condition)
            implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return concat(left, right);
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(left, right);
        }
    }

    record Sort(PhysicalPlan input, List<SortKey> keys) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }
    }

    /** OFFSET then LIMIT; expressions are constant INT64 (null = absent). */
    record Limit(PhysicalPlan input, BoundExpr offset, BoundExpr limit) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }
    }

    private static List<ColumnSchema> concat(PhysicalPlan left, PhysicalPlan right) {
        List<ColumnSchema> out = new ArrayList<>(left.schema());
        out.addAll(right.schema());
        return out;
    }
}
