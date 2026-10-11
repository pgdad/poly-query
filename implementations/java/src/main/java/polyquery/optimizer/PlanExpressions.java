package polyquery.optimizer;

import java.util.ArrayList;
import java.util.List;
import java.util.function.UnaryOperator;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;

/** Rewrites the expressions evaluated by one logical operator. */
final class PlanExpressions {
    private PlanExpressions() {
    }

    /**
     * {@code node} with {@code fn} applied to its predicate, join condition, group keys,
     * aggregate arguments or projections (LIMIT/OFFSET constants and sort keys are untouched).
     */
    static LogicalPlan map(LogicalPlan node, UnaryOperator<BoundExpr> fn) {
        return switch (node) {
            case LogicalPlan.Filter f -> new LogicalPlan.Filter(f.input(), fn.apply(f.predicate()));
            case LogicalPlan.Join j -> new LogicalPlan.Join(j.left(), j.right(), j.kind(),
                    j.condition() == null ? null : fn.apply(j.condition()));
            case LogicalPlan.Aggregate a -> {
                List<AggregateCall> calls = new ArrayList<>(a.aggregates().size());
                for (AggregateCall c : a.aggregates()) {
                    calls.add(c.argument() == null ? c
                            : new AggregateCall(c.function(), fn.apply(c.argument()), c.distinct(), c.type()));
                }
                yield new LogicalPlan.Aggregate(a.input(), mapAll(a.groupKeys(), fn), calls);
            }
            case LogicalPlan.Project p -> new LogicalPlan.Project(p.input(), mapAll(p.expressions(), fn), p.names());
            default -> node;
        };
    }

    private static List<BoundExpr> mapAll(List<BoundExpr> exprs, UnaryOperator<BoundExpr> fn) {
        List<BoundExpr> out = new ArrayList<>(exprs.size());
        for (BoundExpr e : exprs) {
            out.add(fn.apply(e));
        }
        return out;
    }
}
