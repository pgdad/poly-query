package polyquery.physical;

import java.util.ArrayList;
import java.util.List;
import polyquery.index.Index;
import polyquery.index.KeyPredicate;
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

    /**
     * A sargable predicate on one column of a scan, used to skip row groups whose min/max
     * statistics exclude it.
     */
    record ColumnFilter(int column, KeyPredicate predicate) {
    }

    /**
     * Full scan. Output rows have the table's full width (positions are stable), but only the
     * slots listed in {@code columns} (ascending; null = all) are read and filled — the others
     * are null (column pruning). Row groups excluded by {@code skipFilters} are not read.
     */
    record TableScan(Table table, String alias, int[] columns, List<ColumnFilter> skipFilters)
            implements PhysicalPlan {
        public TableScan(Table table, String alias) {
            this(table, alias, null, List.of());
        }

        public TableScan withColumns(int[] cols) {
            return new TableScan(table, alias, cols, skipFilters);
        }

        @Override
        public List<ColumnSchema> schema() {
            return table.columns();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of();
        }
    }

    /**
     * Rows of {@code table} whose {@code column} satisfies {@code lookup}, found through
     * {@code index}, in ascending row order. Row layout and pruning as for {@link TableScan}.
     */
    record IndexScan(Table table, String alias, Index index, KeyPredicate lookup, String lookupText, int[] columns,
                     double estimatedRows) implements PhysicalPlan {
        public IndexScan withColumns(int[] cols) {
            return new IndexScan(table, alias, index, lookup, lookupText, cols, estimatedRows);
        }

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
     * Equi-join: builds a hash table on one input (the right one unless {@code buildLeft}, which
     * is only used for INNER joins) keyed by its join keys and probes it with the other;
     * {@code leftKeys} are over left rows, {@code rightKeys} over right rows; {@code residual}
     * (over the combined row, may be null) filters candidate pairs. Output rows are always the
     * left columns followed by the right columns.
     */
    record HashJoin(PhysicalPlan left, PhysicalPlan right, LogicalPlan.JoinKind kind, List<BoundExpr> leftKeys,
                    List<BoundExpr> rightKeys, BoundExpr residual, boolean buildLeft) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return concat(left, right);
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(left, right);
        }
    }

    /**
     * Sort-merge equi-join (INNER or LEFT): both inputs are sorted on their join keys and merged;
     * keys and residual as for {@link HashJoin}. Output rows are the left columns followed by
     * the right columns.
     */
    record MergeJoin(PhysicalPlan left, PhysicalPlan right, LogicalPlan.JoinKind kind, List<BoundExpr> leftKeys,
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

    /**
     * {@code ORDER BY … OFFSET o LIMIT n} computed with a bounded heap of {@code o + n} rows
     * instead of a full sort (ties keep their input order, exactly like the stable sort).
     */
    record TopN(PhysicalPlan input, List<SortKey> keys, BoundExpr offset, BoundExpr limit) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return input.schema();
        }

        @Override
        public List<PhysicalPlan> children() {
            return List.of(input);
        }
    }

    /** The rows of every input, one input after the other, duplicates kept ({@code UNION ALL}). */
    record UnionAll(List<PhysicalPlan> inputs, List<ColumnSchema> columns) implements PhysicalPlan {
        @Override
        public List<ColumnSchema> schema() {
            return columns;
        }

        @Override
        public List<PhysicalPlan> children() {
            return inputs;
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
    public static List<BoundExpr> expressions(PhysicalPlan p) {
        List<BoundExpr> out = new ArrayList<>();
        switch (p) {
            case TableScan t -> { }
            case IndexScan t -> { }
            case Values v -> { }
            case HashDistinct d -> { }
            case UnionAll u -> { }
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
            case MergeJoin j -> {
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
            case TopN t -> {
                if (t.offset() != null) {
                    out.add(t.offset());
                }
                out.add(t.limit());
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
