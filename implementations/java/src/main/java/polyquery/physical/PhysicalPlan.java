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

    /**
     * Filter of a correlated subquery whose predicate equates input expressions with outer
     * references: the (uncorrelated) input is hashed once on {@code innerKeys} after applying
     * {@code staticPredicate}; each execution returns the rows whose keys equal the current
     * values of {@code outerKeys}, filtered by {@code dynamicPredicate}. Predicates may be null.
     */
    record HashLookupFilter(PhysicalPlan input, List<BoundExpr> innerKeys, List<BoundExpr> outerKeys,
                            BoundExpr staticPredicate, BoundExpr dynamicPredicate) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }

        /** Expressions of a node, for correlation analysis. */
        public List<BoundExpr> expressions() {
            List<BoundExpr> out = new ArrayList<>(innerKeys);
            out.addAll(outerKeys);
            if (staticPredicate != null) {
                out.add(staticPredicate);
            }
            if (dynamicPredicate != null) {
                out.add(dynamicPredicate);
            }
            return out;
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

    /** The expressions evaluated by a node itself (not its children). */
    static List<BoundExpr> expressions(PhysicalPlan p) {
        List<BoundExpr> out = new ArrayList<>();
        switch (p) {
            case TableScan t -> { }
            case Values v -> { }
            case HashDistinct d -> { }
            case Sort s -> { }
            case Filter f -> out.add(f.predicate());
            case HashLookupFilter h -> out.addAll(h.expressions());
            case Project pr -> out.addAll(pr.expressions());
            case HashAggregate a -> {
                out.addAll(a.groupKeys());
                for (AggregateCall c : a.aggregates()) {
                    if (c.argument() != null) {
                        out.add(c.argument());
                    }
                }
            }
            case HashJoin j -> {
                out.addAll(j.leftKeys());
                out.addAll(j.rightKeys());
                if (j.residual() != null) {
                    out.add(j.residual());
                }
            }
            case NestedLoopJoin j -> {
                if (j.condition() != null) {
                    out.add(j.condition());
                }
            }
            case Limit l -> {
                if (l.offset() != null) {
                    out.add(l.offset());
                }
                if (l.limit() != null) {
                    out.add(l.limit());
                }
            }
        }
        return out;
    }

    private static List<ColumnSchema> concat(PhysicalPlan left, PhysicalPlan right) {
        List<ColumnSchema> out = new ArrayList<>(left.schema());
        out.addAll(right.schema());
        return out;
    }
}
