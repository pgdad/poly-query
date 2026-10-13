package polyquery.plan;

import java.util.ArrayList;
import java.util.List;
import java.util.function.UnaryOperator;
import polyquery.common.Checkpoint;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;

/**
 * Logical relational operators: what a query computes, independent of how (access paths, join
 * algorithms and the execution model are chosen by physical planning). Each node knows its
 * output schema. Subqueries are part of expressions ({@link Subquery} holds their plan); derived
 * tables and CTE references are inlined as the plan of their query. {@link LogicalPlanPrinter}
 * renders a plan for debugging.
 */
public sealed interface LogicalPlan {
    List<ColumnSchema> schema();

    /**
     * The number of output columns, {@code schema().size()} without building the schema (which
     * a deep join or filter tree would assemble from all of its levels on every call).
     */
    default int width() {
        return schema().size();
    }

    /** Input plans, in order. */
    List<LogicalPlan> children();

    /** This node with its inputs replaced by {@code inputs} (same number, same order). */
    LogicalPlan withChildren(List<LogicalPlan> inputs);

    /** Rewrites the plan bottom-up: {@code rule} is applied to every node after its inputs were rewritten. */
    default LogicalPlan transformUp(UnaryOperator<LogicalPlan> rule) {
        Checkpoint.poll();
        List<LogicalPlan> inputs = children();
        if (inputs.isEmpty()) {
            return rule.apply(this);
        }
        List<LogicalPlan> rewritten = new ArrayList<>(inputs.size());
        for (LogicalPlan input : inputs) {
            rewritten.add(input.transformUp(rule));
        }
        return rule.apply(withChildren(rewritten));
    }

    /** Full scan of a catalog table snapshot. */
    record Scan(Table table, String alias) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return table.columns();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of();
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return this;
        }
    }

    /** Exactly one row with no columns (SELECT without FROM). */
    record SingleRow() implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return List.of();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of();
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return this;
        }
    }

    record Filter(LogicalPlan input, BoundExpr predicate) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public int width() {
            return input.width();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of(input);
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return new Filter(inputs.getFirst(), predicate);
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
            List<ColumnSchema> out = new ArrayList<>(width());
            appendSchema(this, out);
            return out;
        }

        /** Appends the schema of {@code plan}; joins append their inputs' (no copy per level of a join tree). */
        private static void appendSchema(LogicalPlan plan, List<ColumnSchema> out) {
            if (plan instanceof Join j) {
                appendSchema(j.left(), out);
                appendSchema(j.right(), out);
            } else {
                out.addAll(plan.schema());
            }
        }

        @Override
        public int width() {
            return left.width() + right.width();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of(left, right);
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return new Join(inputs.get(0), inputs.get(1), kind, condition);
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

        @Override
        public List<LogicalPlan> children() {
            return List.of(input);
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return new Aggregate(inputs.getFirst(), groupKeys, aggregates);
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

        @Override
        public int width() {
            return expressions.size();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of(input);
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return new Project(inputs.getFirst(), expressions, names);
        }
    }

    /** Removes duplicate rows (NULLs equal). */
    record Distinct(LogicalPlan input) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public int width() {
            return input.width();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of(input);
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return new Distinct(inputs.getFirst());
        }
    }

    record Sort(LogicalPlan input, List<SortKey> keys) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public int width() {
            return input.width();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of(input);
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return new Sort(inputs.getFirst(), keys);
        }
    }

    /**
     * Concatenation of the rows of its inputs, in order, duplicates kept ({@code UNION ALL}).
     * Every input already produces {@code columns}' types; the names are the first branch's.
     */
    record UnionAll(List<LogicalPlan> inputs, List<ColumnSchema> columns) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return columns;
        }

        @Override
        public List<LogicalPlan> children() {
            return inputs;
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> newInputs) {
            return new UnionAll(List.copyOf(newInputs), columns);
        }
    }

    /** OFFSET then LIMIT; expressions are constant INT64 (null = absent). */
    record Limit(LogicalPlan input, BoundExpr offset, BoundExpr limit) implements LogicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public int width() {
            return input.width();
        }

        @Override
        public List<LogicalPlan> children() {
            return List.of(input);
        }

        @Override
        public LogicalPlan withChildren(List<LogicalPlan> inputs) {
            return new Limit(inputs.getFirst(), offset, limit);
        }
    }
}
