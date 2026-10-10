package polyquery.exec;

import java.util.Comparator;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;
import polyquery.types.Values;

/** Turns a logical plan into a tree of row-at-a-time physical operators. */
public final class PhysicalPlanner {
    private final ExecContext ctx;
    private final ExpressionCompiler compiler;

    public PhysicalPlanner(ExecContext ctx) {
        this.ctx = ctx;
        this.compiler = new ExpressionCompiler(ctx);
    }

    public Operator build(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> new Operators.Scan(s.table(), ctx);
            case LogicalPlan.SingleRow s -> new Operators.SingleRow();
            case LogicalPlan.Filter f -> new Operators.Filter(build(f.input()), compiler.compile(f.predicate()), ctx);
            case LogicalPlan.Project p -> new Operators.Project(build(p.input()), compileAll(p.expressions()));
            case LogicalPlan.Aggregate a -> {
                Evaluator[] args = new Evaluator[a.aggregates().size()];
                for (int i = 0; i < args.length; i++) {
                    AggregateCall call = a.aggregates().get(i);
                    args[i] = call.argument() == null ? null : compiler.compile(call.argument());
                }
                yield new AggregateOperator(build(a.input()), compileAll(a.groupKeys()), a.aggregates(), args, ctx);
            }
            case LogicalPlan.Sort s -> new Operators.Sort(build(s.input()), comparator(s.keys(), s.input().schema()), ctx);
            case LogicalPlan.Limit l -> {
                long offset = l.offset() == null ? 0 : constant(l.offset(), "OFFSET", 0);
                long limit = l.limit() == null ? -1 : constant(l.limit(), "LIMIT", -1);
                yield new Operators.Limit(build(l.input()), offset, limit);
            }
        };
    }

    private Evaluator[] compileAll(List<BoundExpr> exprs) {
        Evaluator[] out = new Evaluator[exprs.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = compiler.compile(exprs.get(i));
        }
        return out;
    }

    private long constant(BoundExpr e, String clause, long ifNull) {
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
    static Comparator<Object[]> comparator(List<SortKey> keys, List<ColumnSchema> schema) {
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
