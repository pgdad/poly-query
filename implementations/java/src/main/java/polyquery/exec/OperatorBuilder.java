package polyquery.exec;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.function.Function;
import java.util.function.UnaryOperator;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.physical.PhysicalPlan;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;
import polyquery.types.Decimals;
import polyquery.types.TypeKind;
import polyquery.types.Values;

/**
 * Turns a physical plan into a tree of row-at-a-time (Volcano) operators. Child operators (and
 * the plans of subqueries) are built through a replaceable {@link #setDelegate delegate}, which
 * lets the vectorized engine substitute batch operators wherever it has them.
 */
public final class OperatorBuilder {
    private final ExecContext ctx;
    private final Function<LogicalPlan, PhysicalPlan> subqueryPlanner;
    private final ExpressionCompiler compiler;
    private Function<PhysicalPlan, Operator> delegate = this::buildNode;

    /** @param subqueryPlanner optimizes and physically plans subqueries met in expressions */
    public OperatorBuilder(ExecContext ctx, Function<LogicalPlan, PhysicalPlan> subqueryPlanner) {
        this.ctx = ctx;
        this.subqueryPlanner = subqueryPlanner;
        this.compiler = new ExpressionCompiler(ctx, logical -> build(this.subqueryPlanner.apply(logical)));
    }

    /** Replaces how plans are turned into operators (default: {@link #buildNode}). */
    public void setDelegate(Function<PhysicalPlan, Operator> delegate) {
        this.delegate = delegate;
    }

    public ExecContext context() {
        return ctx;
    }

    public Function<LogicalPlan, PhysicalPlan> subqueryPlanner() {
        return subqueryPlanner;
    }

    /** The expression compiler of this query (shared by all its operators; not thread-safe). */
    public ExpressionCompiler compiler() {
        return compiler;
    }

    /** Operator tree for a plan (through the delegate). */
    public Operator build(PhysicalPlan plan) {
        return delegate.apply(plan);
    }

    /** A row operator for the root node of {@code plan}; its children are built with {@link #build}. */
    public Operator buildNode(PhysicalPlan plan) {
        return switch (plan) {
            case PhysicalPlan.TableScan s -> new ScanOperators.TableScan(s, ctx);
            case PhysicalPlan.IndexScan s -> new ScanOperators.IndexScan(s, ctx);
            case PhysicalPlan.Values v -> new Operators.SingleRow();
            case PhysicalPlan.Filter f -> new Operators.Filter(build(f.input()), compiler.compile(f.predicate()), ctx);
            case PhysicalPlan.HashLookupFilter h -> new HashLookupFilter(build(h.input()), compileAll(h.innerKeys()),
                    compileAll(h.outerKeys()), types(h.innerKeys()), types(h.outerKeys()),
                    h.staticPredicate() == null ? null : compiler.compile(h.staticPredicate()),
                    h.dynamicPredicate() == null ? null : compiler.compile(h.dynamicPredicate()), ctx);
            case PhysicalPlan.Project p -> new Operators.Project(build(p.input()), compileAll(p.expressions()));
            case PhysicalPlan.HashAggregate a -> {
                Evaluator[] args = new Evaluator[a.aggregates().size()];
                for (int i = 0; i < args.length; i++) {
                    AggregateCall call = a.aggregates().get(i);
                    args[i] = call.argument() == null ? null : compiler.compile(call.argument());
                }
                yield new AggregateOperator(build(a.input()), compileAll(a.groupKeys()), a.aggregates(), args, ctx);
            }
            case PhysicalPlan.HashDistinct d -> new DistinctOperator(build(d.input()), ctx);
            case PhysicalPlan.UnionAll u -> new Operators.UnionAll(u.inputs().stream().map(this::build).toList());
            case PhysicalPlan.HashJoin j -> hashJoin(j);
            case PhysicalPlan.NestedLoopJoin j -> new JoinOperators.NestedLoopJoin(build(j.left()), build(j.right()),
                    j.condition() == null ? null : compiler.compile(j.condition()),
                    j.kind() == LogicalPlan.JoinKind.LEFT, j.right().schema().size(), ctx);
            case PhysicalPlan.MergeJoin j -> mergeJoin(j);
            case PhysicalPlan.Sort s -> new Operators.Sort(build(s.input()), comparator(s.keys(), s.input().schema()), ctx);
            case PhysicalPlan.TopN t -> {
                long offset = t.offset() == null ? 0 : constant(t.offset(), "OFFSET", 0);
                long limit = constant(t.limit(), "LIMIT", -1);
                Comparator<Object[]> order = comparator(t.keys(), t.input().schema());
                if (limit < 0) { // LIMIT NULL: a full sort
                    yield new Operators.Limit(new Operators.Sort(build(t.input()), order, ctx), offset, -1);
                }
                yield new Operators.TopN(build(t.input()), order, offset, limit, ctx);
            }
            case PhysicalPlan.Limit l -> {
                long offset = l.offset() == null ? 0 : constant(l.offset(), "OFFSET", 0);
                long limit = l.limit() == null ? -1 : constant(l.limit(), "LIMIT", -1);
                yield new Operators.Limit(build(l.input()), offset, limit);
            }
        };
    }

    private Operator hashJoin(PhysicalPlan.HashJoin j) {
        int n = j.leftKeys().size();
        List<UnaryOperator<Object>> leftNorm = new ArrayList<>(n);
        List<UnaryOperator<Object>> rightNorm = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            DataType lt = j.leftKeys().get(i).type();
            DataType rt = j.rightKeys().get(i).type();
            if (lt.kind() == TypeKind.DECIMAL && rt.kind() == TypeKind.DECIMAL && lt.scale() != rt.scale()) {
                leftNorm.add(v -> HashKeys.normalize(v, lt));
                rightNorm.add(v -> HashKeys.normalize(v, rt));
            } else {
                leftNorm.add(HashKeys::normalizeZero);
                rightNorm.add(HashKeys::normalizeZero);
            }
        }
        Evaluator residual = j.residual() == null ? null : compiler.compile(j.residual());
        if (j.buildLeft()) {
            return new JoinOperators.HashJoinBuildLeft(build(j.left()), build(j.right()), compileAll(j.leftKeys()),
                    compileAll(j.rightKeys()), leftNorm, rightNorm, residual, ctx);
        }
        return new JoinOperators.HashJoin(build(j.left()), build(j.right()), compileAll(j.leftKeys()),
                compileAll(j.rightKeys()), leftNorm, rightNorm, residual,
                j.kind() == LogicalPlan.JoinKind.LEFT, j.right().schema().size(), ctx);
    }

    private Operator mergeJoin(PhysicalPlan.MergeJoin j) {
        int n = j.leftKeys().size();
        DataType[] lt = types(j.leftKeys());
        DataType[] rt = types(j.rightKeys());
        Evaluator residual = j.residual() == null ? null : compiler.compile(j.residual());
        return new JoinOperators.MergeJoin(build(j.left()), build(j.right()), compileAll(j.leftKeys()),
                compileAll(j.rightKeys()), keyOrder(lt, lt, n), keyOrder(rt, rt, n), keyOrder(lt, rt, n), residual,
                j.kind() == LogicalPlan.JoinKind.LEFT, j.right().schema().size(), ctx);
    }

    /** Lexicographic order of non-null key tuples of types {@code a} (left operand) and {@code b}. */
    static Comparator<Object[]> keyOrder(DataType[] a, DataType[] b, int n) {
        return (x, y) -> {
            for (int i = 0; i < n; i++) {
                int c = compareKeys(x[i], a[i], y[i], b[i]);
                if (c != 0) {
                    return c;
                }
            }
            return 0;
        };
    }

    /** Compares two non-null values of comparable types (DECIMALs of different scales allowed). */
    static int compareKeys(Object x, DataType xt, Object y, DataType yt) {
        if (xt.kind() == TypeKind.DECIMAL && yt.kind() == TypeKind.DECIMAL && xt.scale() != yt.scale()) {
            return Decimals.compare((Long) x, xt.scale(), (Long) y, yt.scale());
        }
        return Values.compare(x, y, xt);
    }

    private Evaluator[] compileAll(List<BoundExpr> exprs) {
        Evaluator[] out = new Evaluator[exprs.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = compiler.compile(exprs.get(i));
        }
        return out;
    }

    private static DataType[] types(List<BoundExpr> exprs) {
        DataType[] out = new DataType[exprs.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = exprs.get(i).type();
        }
        return out;
    }

    /** Value of a constant LIMIT/OFFSET expression ({@code ifNull} for NULL; negative ⇒ INVALID_ARGUMENT). */
    public long constant(BoundExpr e, String clause, long ifNull) {
        Object v = compiler.compile(e).eval(new Object[0]);
        if (v == null) {
            return ifNull;
        }
        long n = (Long) v;
        if (n < 0) {
            throw PolyQueryException.of(ErrorCode.INVALID_ARGUMENT, "%s must not be negative", clause);
        }
        return n;
    }

    /** Lexicographic row comparator honoring direction and NULL placement per key. */
    public static Comparator<Object[]> comparator(List<SortKey> keys, List<ColumnSchema> schema) {
        int n = keys.size();
        int[] cols = new int[n];
        DataType[] types = new DataType[n];
        boolean[] desc = new boolean[n];
        boolean[] nullsFirst = new boolean[n];
        for (int i = 0; i < n; i++) {
            SortKey k = keys.get(i);
            cols[i] = k.column();
            types[i] = schema.get(k.column()).type();
            desc[i] = k.descending();
            nullsFirst[i] = k.nullsFirst();
        }
        return (a, b) -> {
            for (int i = 0; i < n; i++) {
                Object x = a[cols[i]];
                Object y = b[cols[i]];
                int c;
                if (x == null || y == null) {
                    if (x == y) {
                        continue;
                    }
                    c = (x == null) == nullsFirst[i] ? -1 : 1;
                } else {
                    c = Values.compare(x, y, types[i]);
                    if (desc[i]) {
                        c = -c;
                    }
                }
                if (c != 0) {
                    return c;
                }
            }
            return 0;
        };
    }
}
