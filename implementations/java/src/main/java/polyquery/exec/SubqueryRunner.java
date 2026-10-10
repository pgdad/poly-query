package polyquery.exec;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.function.UnaryOperator;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.plan.Subquery;

/**
 * Evaluates a subquery for the row of the enclosing query level that is currently being
 * evaluated. Uncorrelated subqueries run once; correlated ones run (logically) once per outer
 * row, with results memoized by the values of the outer references they depend on.
 */
final class SubqueryRunner {
    private static final int MAX_MEMO_ENTRIES = 100_000;
    private static final Object NO_VALUE = new Object();

    /** Distinct values of a subquery's first column, plus whether it contained NULL. */
    record ValueSet(Set<Object> values, boolean hasNull, boolean isEmpty) {
        boolean contains(Object v) {
            return values.contains(v);
        }
    }

    private final Subquery subquery;
    private final Function<LogicalPlan, Operator> builder;
    private final ExecContext ctx;
    private Operator operator;
    private Object cached = NO_VALUE;
    private Map<List<Object>, Object> memo;

    SubqueryRunner(Subquery subquery, Function<LogicalPlan, Operator> builder, ExecContext ctx) {
        this.subquery = subquery;
        this.builder = builder;
        this.ctx = ctx;
    }

    Object scalar(Object[] row) {
        return evaluate(row, op -> {
            Object[] first = op.next();
            if (first == null) {
                return null;
            }
            if (op.next() != null) {
                throw new PolyQueryException(ErrorCode.SUBQUERY_CARDINALITY, "scalar subquery returned more than one row");
            }
            return first[0];
        });
    }

    Object exists(Object[] row) {
        return evaluate(row, op -> op.next() != null);
    }

    /** @param convert maps a raw subquery value to its (non-null) hash key, or null for SQL NULL */
    ValueSet valueSet(Object[] row, UnaryOperator<Object> convert) {
        return (ValueSet) evaluate(row, op -> {
            Set<Object> values = new HashSet<>();
            boolean hasNull = false;
            boolean empty = true;
            Object[] r;
            while ((r = op.next()) != null) {
                empty = false;
                Object key = convert.apply(r[0]);
                if (key == null) {
                    hasNull = true;
                } else if (values.add(key)) {
                    ctx.reserve(48);
                }
                ctx.checkpoint();
            }
            return new ValueSet(values, hasNull, empty);
        });
    }

    private Object evaluate(Object[] row, Function<Operator, Object> compute) {
        if (!subquery.correlated()) {
            if (cached == NO_VALUE) {
                cached = run(compute);
            }
            return cached;
        }
        Object[] previous = ctx.setFrame(subquery.frame(), row);
        try {
            List<Object> key = new ArrayList<>(subquery.outerRefs().size());
            for (BoundExpr.OuterRef ref : subquery.outerRefs()) {
                key.add(HashKeys.normalizeZero(ctx.frame(ref.frame())[ref.index()]));
            }
            if (memo == null) {
                memo = new HashMap<>();
            }
            Object v = memo.getOrDefault(key, NO_VALUE);
            if (v == NO_VALUE) {
                v = run(compute);
                if (memo.size() >= MAX_MEMO_ENTRIES) {
                    memo.clear();
                }
                memo.put(key, v);
            }
            return v;
        } finally {
            ctx.setFrame(subquery.frame(), previous);
        }
    }

    private Object run(Function<Operator, Object> compute) {
        if (operator == null) {
            operator = builder.apply(subquery.plan());
        }
        operator.open();
        try {
            return compute.apply(operator);
        } finally {
            operator.close();
        }
    }
}
