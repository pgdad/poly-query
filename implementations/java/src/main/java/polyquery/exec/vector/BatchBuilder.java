package polyquery.exec.vector;

import java.util.List;
import polyquery.exec.ExecContext;
import polyquery.exec.Operator;
import polyquery.exec.OperatorBuilder;
import polyquery.physical.PhysicalPlan;
import polyquery.physical.PlanKeys;
import polyquery.plan.LogicalPlan;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;

/**
 * Turns a physical plan into batch operators. Scans, filters, projections, hash aggregation,
 * DISTINCT, hash joins, UNION ALL, sorts, top-N and LIMIT run vectorized; the remaining operators (merge
 * and nested-loop joins, correlated lookups) are the row engine's, connected through row/batch
 * adapters. Pipelines over large tables are executed by parallel workers when the
 * query may use several threads (see {@link Parallel}).
 */
public final class BatchBuilder {
    /** Default rows per batch (positions per vector); system property {@code polyquery.batchSize}. */
    static final int DEFAULT_BATCH_SIZE = 2048;
    /** Default rows per morsel (unit of work of parallel scans); property {@code polyquery.morselRows}. */
    static final int DEFAULT_MORSEL_ROWS = 65536;

    private final int batchSize = Math.max(1, Integer.getInteger("polyquery.batchSize", DEFAULT_BATCH_SIZE));
    private final int morselRows = Math.max(1, Integer.getInteger("polyquery.morselRows", DEFAULT_MORSEL_ROWS));
    private final ExecContext ctx;
    private final OperatorBuilder rows;
    private final VecCompiler compiler;
    private final int threads;

    /** @param threads maximum worker threads of parallel pipelines (1 = sequential) */
    public BatchBuilder(OperatorBuilder rows, int threads) {
        this.rows = rows;
        this.ctx = rows.context();
        this.compiler = new VecCompiler(ctx, rows.compiler());
        this.threads = threads;
        rows.setDelegate(this::rowOperator);
    }

    /** Whether the root node of {@code plan} has a batch implementation. */
    private static boolean vectorized(PhysicalPlan plan) {
        return switch (plan) {
            case PhysicalPlan.TableScan s -> true;
            case PhysicalPlan.IndexScan s -> true;
            case PhysicalPlan.Values v -> true;
            case PhysicalPlan.Filter f -> true;
            case PhysicalPlan.Project p -> true;
            case PhysicalPlan.HashAggregate a -> true;
            case PhysicalPlan.HashDistinct d -> true;
            case PhysicalPlan.UnionAll u -> true;
            case PhysicalPlan.HashJoin j -> true;
            case PhysicalPlan.Limit l -> true;
            case PhysicalPlan.Sort s -> true;
            case PhysicalPlan.TopN t -> true;
            default -> false;
        };
    }

    /** Row operator for a plan: the row engine's operator, or a batch tree behind an adapter. */
    private Operator rowOperator(PhysicalPlan plan) {
        if (vectorized(plan)) {
            return new BatchOperators.BatchToRow(build(plan), plan.schema().size());
        }
        return rows.buildNode(plan);
    }

    /** Batch operator tree for a plan. */
    public BatchOperator build(PhysicalPlan plan) {
        if (threads > 1) {
            BatchOperator parallel = Parallel.tryBuild(this, plan);
            if (parallel != null) {
                return parallel;
            }
        }
        return buildSequential(plan);
    }

    /** Batch operator for the root node of {@code plan} without parallelizing it (children may be). */
    BatchOperator buildSequential(PhysicalPlan plan) {
        return switch (plan) {
            case PhysicalPlan.TableScan s -> new ScanBatches.TableScan(s, ctx, batchSize,
                    Morsel.of(s, Integer.MAX_VALUE));
            case PhysicalPlan.IndexScan s -> new ScanBatches.IndexScan(s, ctx, batchSize);
            case PhysicalPlan.Values v -> new ScanBatches.SingleRow();
            case PhysicalPlan.Filter f -> new BatchOperators.Filter(build(f.input()), compiler, f.predicate(),
                    f.schema().size());
            case PhysicalPlan.Project p -> new BatchOperators.Project(build(p.input()), compiler, p.expressions());
            case PhysicalPlan.HashAggregate a -> new AggregateBatches.HashAggregate(build(a.input()), a.groupKeys(),
                    a.aggregates(), compiler, ctx, batchSize, PlanKeys.resultKey(a));
            case PhysicalPlan.HashDistinct d -> new AggregateBatches.Distinct(build(d.input()), types(d.schema()), ctx);
            case PhysicalPlan.UnionAll u -> new BatchOperators.UnionAll(u.inputs().stream().map(this::build).toList());
            case PhysicalPlan.HashJoin j -> hashJoin(j, build(j.buildLeft() ? j.right() : j.left()), null, compiler,
                    new JoinBatches.JoinCounter(ctx.maxJoinRows()));
            case PhysicalPlan.Limit l -> {
                long offset = l.offset() == null ? 0 : rows.constant(l.offset(), "OFFSET", 0);
                long limit = l.limit() == null ? -1 : rows.constant(l.limit(), "LIMIT", -1);
                yield new BatchOperators.Limit(build(l.input()), offset, limit, l.schema().size());
            }
            case PhysicalPlan.Sort s -> new SortBatches.Sort(build(s.input()), s.keys(), s.schema(), ctx, batchSize,
                    threads, 0, -1);
            case PhysicalPlan.TopN t -> {
                long offset = t.offset() == null ? 0 : rows.constant(t.offset(), "OFFSET", 0);
                long limit = rows.constant(t.limit(), "LIMIT", -1);
                BatchOperator sorted = new SortBatches.Sort(build(t.input()), t.keys(), t.schema(), ctx, batchSize,
                        threads, limit < 0 ? 0 : offset, limit);
                yield limit < 0 && offset > 0 ? new BatchOperators.Limit(sorted, offset, -1, t.schema().size())
                        : sorted;
            }
            default -> new BatchOperators.RowToBatch(rows.buildNode(plan), plan.schema(), batchSize);
        };
    }

    /**
     * A hash join probing with {@code probe} (the left input, or the right one when the build
     * side is the left input). With {@code table == null} the probe builds its own table from
     * the build input at open; parallel workers share a prebuilt table.
     */
    BatchOperator hashJoin(PhysicalPlan.HashJoin j, BatchOperator probe, JoinBatches.JoinTable table,
                           VecCompiler comp, JoinBatches.JoinCounter counter) {
        boolean buildLeft = j.buildLeft();
        PhysicalPlan buildPlan = buildLeft ? j.left() : j.right();
        PhysicalPlan probePlan = buildLeft ? j.right() : j.left();
        var buildKeyExprs = buildLeft ? j.leftKeys() : j.rightKeys();
        var probeKeyExprs = buildLeft ? j.rightKeys() : j.leftKeys();
        DataType[] keyTypes = new DataType[buildKeyExprs.size()];
        for (int i = 0; i < keyTypes.length; i++) {
            keyTypes[i] = buildKeyExprs.get(i).type();
        }
        BatchOperator buildInput = table == null ? build(buildPlan) : null;
        BatchExprs buildKeys = table == null ? new BatchExprs(comp, buildKeyExprs) : null;
        return new JoinBatches.Probe(probe, table, buildInput, buildKeys,
                JoinBatches.scaleFactors(buildKeyExprs, probeKeyExprs), keyTypes, expectedRows(buildPlan), threads,
                new BatchExprs(comp, probeKeyExprs),
                JoinBatches.scaleFactors(probeKeyExprs, buildKeyExprs),
                j.residual() == null ? null : new BatchExprs(comp, List.of(j.residual())),
                j.kind() == LogicalPlan.JoinKind.LEFT, buildLeft, j.schema(), probePlan.schema().size(), ctx,
                counter, batchSize);
    }

    /** Rows a plan produces if known exactly before running it (a plain table scan), else 0. */
    static int expectedRows(PhysicalPlan plan) {
        return plan instanceof PhysicalPlan.TableScan s && s.skipFilters().isEmpty() ? s.table().rowCount() : 0;
    }

    static DataType[] types(List<ColumnSchema> schema) {
        DataType[] out = new DataType[schema.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = schema.get(i).type();
        }
        return out;
    }

    ExecContext context() {
        return ctx;
    }

    OperatorBuilder rows() {
        return rows;
    }

    VecCompiler compiler() {
        return compiler;
    }

    int threads() {
        return threads;
    }

    int batchSize() {
        return batchSize;
    }

    int morselRows() {
        return morselRows;
    }
}
