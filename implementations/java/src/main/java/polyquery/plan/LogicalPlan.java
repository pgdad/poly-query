package polyquery.plan;

import java.util.ArrayList;
import java.util.List;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;

/** Logical relational operators. Each node knows its output schema. */
public sealed interface LogicalPlan {
    List<ColumnSchema> schema();

    /** Full scan of a catalog table snapshot. */
    record Scan(Table table, String alias) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return table.columns();
        }
    }

    /** Exactly one row with no columns (SELECT without FROM). */
    record SingleRow() implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return List.of();
        }
    }

    record Filter(LogicalPlan input, BoundExpr predicate) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }
    }

    enum JoinKind { INNER, LEFT, CROSS }

    /**
     * Join of two inputs; output rows are the left columns followed by the right columns.
     * {@code condition} (null for CROSS) is evaluated over such a combined row.
     */
    record Join(LogicalPlan left, LogicalPlan right, JoinKind kind, BoundExpr condition) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            List<ColumnSchema> out = new ArrayList<>(left.schema());
            out.addAll(right.schema());
            return out;
        }
    }

    /** Output row: group keys followed by aggregate results. */
    record Aggregate(LogicalPlan input, List<BoundExpr> groupKeys, List<AggregateCall> aggregates)
            implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            List<ColumnSchema> out = new ArrayList<>();
            for (int i = 0; i < groupKeys.size(); i++) {
                out.add(new ColumnSchema("_key" + (i + 1), groupKeys.get(i).type()));
            }
            for (int i = 0; i < aggregates.size(); i++) {
                out.add(new ColumnSchema("_agg" + (i + 1), aggregates.get(i).type()));
            }
            return out;
        }
    }

    record Project(LogicalPlan input, List<BoundExpr> expressions, List<String> names) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            List<ColumnSchema> out = new ArrayList<>();
            for (int i = 0; i < expressions.size(); i++) {
                out.add(new ColumnSchema(names.get(i), expressions.get(i).type()));
            }
            return out;
        }
    }

    /** Removes duplicate rows (NULLs equal). */
    record Distinct(LogicalPlan input) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }
    }

    record Sort(LogicalPlan input, List<SortKey> keys) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }
    }

    /** OFFSET then LIMIT; expressions are constant INT64 (null = absent). */
    record Limit(LogicalPlan input, BoundExpr offset, BoundExpr limit) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }
    }
}
