package polyquery.physical;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import polyquery.cost.Cardinality;
import polyquery.cost.ColumnPredicates;
import polyquery.exec.ExecMode;
import polyquery.index.Index;
import polyquery.index.KeyPredicate;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;

/**
 * Physical planning: maps an (optimized) logical plan to physical operators. It alone decides
 * access paths (table vs index scans, with row-group skipping filters), join algorithms
 * (hash / sort-merge / nested loop, honouring the {@code join} option) and the hash join build
 * side — basic cost-based choices from table statistics — hash lookups for correlated
 * filters, top-N for {@code ORDER BY … LIMIT}, the columns every scan reads, and the execution
 * strategy (row or vectorized model, worker threads, native kernels).
 */
public final class PhysicalPlanner {
    /** Join algorithm preference (query option {@code join}). */
    public enum JoinStrategy { AUTO, HASH, MERGE, NESTED_LOOP }

    /**
     * Physical planning options (from the query options).
     *
     * @param joinStrategy  preferred join algorithm
     * @param useIndexes    allow index scans
     * @param topN          plan {@code ORDER BY … LIMIT} as a bounded top-N instead of a full sort
     * @param mode          requested execution model
     * @param threads       requested worker threads
     * @param nativeKernels native kernels requested and loaded
     */
    public record Options(JoinStrategy joinStrategy, boolean useIndexes, boolean topN, ExecMode mode, int threads,
                          boolean nativeKernels) {
    }

    /** An index scan is chosen when at most this fraction of the table's rows is expected to match. */
    static final double INDEX_SELECTIVITY_THRESHOLD = 0.10;
    /** ... or when at most this many rows are expected (a lookup this small never loses to a scan). */
    static final double INDEX_ROWS_THRESHOLD = 3;

    private final Options options;

    public PhysicalPlanner(Options options) {
        this.options = options;
    }

    /** Plans a query together with its execution strategy. */
    public PhysicalQuery planQuery(LogicalPlan plan) {
        // the row engine is the single-threaded baseline; native kernels are batch kernels
        boolean vectorized = options.mode() == ExecMode.VECTORIZED;
        return new PhysicalQuery(plan(plan), options.mode(), vectorized ? options.threads() : 1,
                vectorized && options.nativeKernels());
    }

    /** The operator tree of a plan (subqueries run in the strategy of their enclosing query). */
    public PhysicalPlan plan(LogicalPlan plan) {
        return ColumnPruner.prune(build(plan));
    }

    private PhysicalPlan build(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> new PhysicalPlan.TableScan(s.table(), s.alias());
            case LogicalPlan.SingleRow s -> new PhysicalPlan.Values();
            case LogicalPlan.Filter f when f.input() instanceof LogicalPlan.Scan s -> filter(scan(s, f.predicate()),
                    f.predicate());
            case LogicalPlan.Filter f -> filter(build(f.input()), f.predicate());
            case LogicalPlan.Project p -> new PhysicalPlan.Project(build(p.input()), p.expressions(), p.names());
            case LogicalPlan.Aggregate a -> new PhysicalPlan.HashAggregate(build(a.input()), a.groupKeys(), a.aggregates());
            case LogicalPlan.Distinct d -> new PhysicalPlan.HashDistinct(build(d.input()));
            case LogicalPlan.UnionAll u -> new PhysicalPlan.UnionAll(u.inputs().stream().map(this::build).toList(),
                    u.columns());
            case LogicalPlan.Sort s -> new PhysicalPlan.Sort(build(s.input()), s.keys());
            case LogicalPlan.Limit l
                    when options.topN() && l.limit() != null && l.input() instanceof LogicalPlan.Sort s ->
                    new PhysicalPlan.TopN(build(s.input()), s.keys(), l.offset(), l.limit());
            case LogicalPlan.Limit l -> new PhysicalPlan.Limit(build(l.input()), l.offset(), l.limit());
            case LogicalPlan.Join j -> join(j);
        };
    }

    /**
     * Access path for a scan with a filter directly above it: an index scan if some indexed
     * column has a sargable predicate selective enough, else a table scan that skips row groups
     * excluded by the sargable predicates. The filter itself is still applied above.
     */
    private PhysicalPlan scan(LogicalPlan.Scan s, BoundExpr predicate) {
        Table table = s.table();
        Map<Integer, KeyPredicate> sargs = ColumnPredicates.extract(predicate, table.columns()).columns();
        if (options.useIndexes() && !sargs.isEmpty()) {
            Index best = null;
            double bestSelectivity = Double.MAX_VALUE;
            for (Index index : table.indexes()) {
                KeyPredicate p = sargs.get(index.column());
                if (p == null || !index.structure().supports(p)) {
                    continue;
                }
                double sel = Cardinality.selectivity(table, index.column(), p);
                if (sel < bestSelectivity) {
                    best = index;
                    bestSelectivity = sel;
                }
            }
            double rows = bestSelectivity * table.rowCount();
            if (best != null && (bestSelectivity <= INDEX_SELECTIVITY_THRESHOLD || rows <= INDEX_ROWS_THRESHOLD)) {
                KeyPredicate lookup = sargs.get(best.column());
                return new PhysicalPlan.IndexScan(table, s.alias(), best, lookup,
                        describe(table.columns().get(best.column()), lookup), null, rows);
            }
        }
        List<PhysicalPlan.ColumnFilter> skip = new ArrayList<>();
        for (Map.Entry<Integer, KeyPredicate> e : sargs.entrySet()) {
            skip.add(new PhysicalPlan.ColumnFilter(e.getKey(), e.getValue()));
        }
        return new PhysicalPlan.TableScan(table, s.alias(), null, skip);
    }

    /** Human-readable form of a key predicate on a column (EXPLAIN). */
    static String describe(ColumnSchema col, KeyPredicate p) {
        String column = col.name();
        return switch (p) {
            case KeyPredicate.Empty e -> "FALSE";
            case KeyPredicate.Points pts -> {
                List<String> keys = new ArrayList<>();
                for (Object k : pts.keys()) {
                    keys.add(formatKey(k, col.type()));
                }
                yield keys.size() == 1 ? column + " = " + keys.getFirst()
                        : column + " IN (" + String.join(", ", keys) + ")";
            }
            case KeyPredicate.Range r -> {
                List<String> parts = new ArrayList<>();
                if (r.lower() != null) {
                    parts.add(column + (r.lowerInclusive() ? " >= " : " > ") + formatKey(r.lower(), col.type()));
                }
                if (r.upper() != null) {
                    parts.add(column + (r.upperInclusive() ? " <= " : " < ") + formatKey(r.upper(), col.type()));
                }
                yield parts.isEmpty() ? column + " IS NOT NULL" : String.join(" AND ", parts);
            }
        };
    }

    /**
     * A filter inside a correlated subquery that equates input expressions with outer
     * references becomes a hash lookup, so the input is processed once instead of once per
     * outer row.
     */
    private static PhysicalPlan filter(PhysicalPlan input, BoundExpr predicate) {
        List<BoundExpr> innerKeys = new ArrayList<>();
        List<BoundExpr> outerKeys = new ArrayList<>();
        List<BoundExpr> staticPreds = new ArrayList<>();
        List<BoundExpr> dynamicPreds = new ArrayList<>();
        for (BoundExpr c : BoundExprs.conjuncts(predicate)) {
            if (c instanceof BoundExpr.Comparison cmp && cmp.op() == BoundExpr.CompareOp.EQ
                    && !BoundExprs.containsSubquery(c)) {
                if (isInner(cmp.left()) && isOuter(cmp.right())) {
                    innerKeys.add(cmp.left());
                    outerKeys.add(cmp.right());
                    continue;
                }
                if (isOuter(cmp.left()) && isInner(cmp.right())) {
                    innerKeys.add(cmp.right());
                    outerKeys.add(cmp.left());
                    continue;
                }
            }
            if (BoundExprs.any(c, x -> x instanceof BoundExpr.OuterRef) || BoundExprs.containsCorrelatedSubquery(c)) {
                dynamicPreds.add(c);
            } else {
                staticPreds.add(c);
            }
        }
        if (innerKeys.isEmpty() || isCorrelated(input)) {
            return new PhysicalPlan.Filter(input, predicate);
        }
        return new PhysicalPlan.HashLookupFilter(input, innerKeys, outerKeys, BoundExprs.and(staticPreds),
                BoundExprs.and(dynamicPreds));
    }

    /** Reads input columns only (no outer references, no subqueries). */
    private static boolean isInner(BoundExpr e) {
        return BoundExprs.containsColumnRef(e) && !BoundExprs.any(e, x -> x instanceof BoundExpr.OuterRef)
                && !BoundExprs.containsSubquery(e);
    }

    /** Reads outer references only (constant for one execution of the subquery). */
    private static boolean isOuter(BoundExpr e) {
        return !BoundExprs.containsColumnRef(e) && BoundExprs.any(e, x -> x instanceof BoundExpr.OuterRef)
                && !BoundExprs.containsSubquery(e) && !BoundExprs.any(e, x -> x instanceof BoundExpr.AggregateRef);
    }

    /** True if some expression of the plan depends on outer references. */
    private static boolean isCorrelated(PhysicalPlan p) {
        for (BoundExpr e : PhysicalPlan.expressions(p)) {
            if (BoundExprs.any(e, x -> x instanceof BoundExpr.OuterRef) || BoundExprs.containsCorrelatedSubquery(e)) {
                return true;
            }
        }
        for (PhysicalPlan c : p.children()) {
            if (isCorrelated(c)) {
                return true;
            }
        }
        return false;
    }

    private PhysicalPlan join(LogicalPlan.Join j) {
        PhysicalPlan left = build(j.left());
        PhysicalPlan right = build(j.right());
        if (j.condition() == null || options.joinStrategy() == JoinStrategy.NESTED_LOOP) {
            return new PhysicalPlan.NestedLoopJoin(left, right, j.kind(), j.condition());
        }
        int leftWidth = j.left().schema().size();
        List<BoundExpr> leftKeys = new ArrayList<>();
        List<BoundExpr> rightKeys = new ArrayList<>();
        List<BoundExpr> residual = new ArrayList<>();
        for (BoundExpr c : BoundExprs.conjuncts(j.condition())) {
            if (c instanceof BoundExpr.Comparison cmp && cmp.op() == BoundExpr.CompareOp.EQ
                    && !BoundExprs.containsSubquery(c)) {
                int side = side(cmp.left(), leftWidth);
                int otherSide = side(cmp.right(), leftWidth);
                if (side == -1 && otherSide == 1) {
                    leftKeys.add(cmp.left());
                    rightKeys.add(BoundExprs.shiftColumns(cmp.right(), -leftWidth));
                    continue;
                }
                if (side == 1 && otherSide == -1) {
                    leftKeys.add(cmp.right());
                    rightKeys.add(BoundExprs.shiftColumns(cmp.left(), -leftWidth));
                    continue;
                }
            }
            residual.add(c);
        }
        if (leftKeys.isEmpty()) {
            return new PhysicalPlan.NestedLoopJoin(left, right, j.kind(), j.condition());
        }
        if (options.joinStrategy() == JoinStrategy.MERGE) {
            return new PhysicalPlan.MergeJoin(left, right, j.kind(), leftKeys, rightKeys, BoundExprs.and(residual));
        }
        // Build on the input with the smaller estimated cardinality (inner joins only; a LEFT
        // join must build on its right input).
        boolean buildLeft = j.kind() == LogicalPlan.JoinKind.INNER
                && Cardinality.rows(j.left()) < Cardinality.rows(j.right());
        return new PhysicalPlan.HashJoin(left, right, j.kind(), leftKeys, rightKeys, BoundExprs.and(residual),
                buildLeft);
    }

    private static String formatKey(Object key, DataType type) {
        return switch (type.kind()) {
            case BOOLEAN -> ((Long) key) != 0 ? "TRUE" : "FALSE";
            case INT64, FLOAT64 -> key.toString();
            case DECIMAL -> Decimals.toString((Long) key, type.scale());
            case DATE -> "DATE '" + DateTimes.formatDate((int) (long) (Long) key) + "'";
            case TIMESTAMP -> "TIMESTAMP '" + DateTimes.formatTimestamp((Long) key) + "'";
            default -> "'" + ((String) key).replace("'", "''") + "'";
        };
    }

    /** -1 if {@code e} references only left columns, 1 if only right columns, 0 otherwise. */
    private static int side(BoundExpr e, int leftWidth) {
        int[] range = BoundExprs.columnRange(e);
        if (range[1] < 0) {
            return 0;
        }
        if (range[1] < leftWidth) {
            return -1;
        }
        return range[0] >= leftWidth ? 1 : 0;
    }
}
