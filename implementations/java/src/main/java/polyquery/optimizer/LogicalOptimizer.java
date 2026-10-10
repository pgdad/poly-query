package polyquery.optimizer;

import java.util.ArrayList;
import java.util.List;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;

/**
 * Rule-based logical optimization. Currently predicate pushdown: WHERE conjuncts and join
 * conditions are moved as close to the scans as semantics allow, and cross joins with a
 * pushed-down join predicate become inner joins.
 *
 * <p>Predicates containing correlated subqueries are never moved: their correlation frame is
 * the row layout of the operator they were bound against.
 */
public final class LogicalOptimizer {
    private LogicalOptimizer() {
    }

    public static LogicalPlan optimize(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> s;
            case LogicalPlan.SingleRow s -> s;
            case LogicalPlan.Filter f -> pushInto(optimize(f.input()), BoundExprs.conjuncts(f.predicate()));
            case LogicalPlan.Join j -> pushInto(
                    new LogicalPlan.Join(optimize(j.left()), optimize(j.right()), j.kind(), j.condition()), List.of());
            case LogicalPlan.Aggregate a -> new LogicalPlan.Aggregate(optimize(a.input()), a.groupKeys(), a.aggregates());
            case LogicalPlan.Project p -> new LogicalPlan.Project(optimize(p.input()), p.expressions(), p.names());
            case LogicalPlan.Distinct d -> new LogicalPlan.Distinct(optimize(d.input()));
            case LogicalPlan.Sort s -> new LogicalPlan.Sort(optimize(s.input()), s.keys());
            case LogicalPlan.Limit l -> new LogicalPlan.Limit(optimize(l.input()), l.offset(), l.limit());
        };
    }

    private static boolean movable(BoundExpr e) {
        return !BoundExprs.containsCorrelatedSubquery(e);
    }

    /** Applies the conjunctive predicates to {@code node}, pushing them below it where possible. */
    private static LogicalPlan pushInto(LogicalPlan node, List<BoundExpr> preds) {
        if (node instanceof LogicalPlan.Filter f) {
            List<BoundExpr> all = new ArrayList<>(BoundExprs.conjuncts(f.predicate()));
            all.addAll(preds);
            return pushInto(f.input(), all);
        }
        if (!(node instanceof LogicalPlan.Join j)) {
            return filter(node, preds);
        }
        int leftWidth = j.left().schema().size();
        boolean left = j.kind() == LogicalPlan.JoinKind.LEFT;
        List<BoundExpr> toLeft = new ArrayList<>();
        List<BoundExpr> toRight = new ArrayList<>();
        List<BoundExpr> joinPreds = new ArrayList<>();
        List<BoundExpr> above = new ArrayList<>();

        // Conjuncts of the join condition itself.
        if (j.condition() != null) {
            for (BoundExpr c : BoundExprs.conjuncts(j.condition())) {
                int[] range = BoundExprs.columnRange(c);
                if (!movable(c) || range[1] < 0) {
                    joinPreds.add(c);
                } else if (range[0] >= leftWidth) {
                    toRight.add(BoundExprs.shiftColumns(c, -leftWidth));
                } else if (range[1] < leftWidth && !left) {
                    toLeft.add(c);
                } else {
                    joinPreds.add(c);
                }
            }
        }
        // Conjuncts of a filter above the join.
        for (BoundExpr c : preds) {
            int[] range = BoundExprs.columnRange(c);
            if (!movable(c) || range[1] < 0) {
                above.add(c);
            } else if (range[1] < leftWidth) {
                toLeft.add(c);
            } else if (range[0] >= leftWidth && !left) {
                toRight.add(BoundExprs.shiftColumns(c, -leftWidth));
            } else if (!left) {
                joinPreds.add(c);
            } else {
                above.add(c);
            }
        }
        LogicalPlan.JoinKind kind = j.kind();
        if (kind == LogicalPlan.JoinKind.CROSS && !joinPreds.isEmpty()) {
            kind = LogicalPlan.JoinKind.INNER;
        }
        BoundExpr cond = BoundExprs.and(joinPreds);
        if (kind == LogicalPlan.JoinKind.INNER && cond == null) {
            kind = LogicalPlan.JoinKind.CROSS;
        }
        LogicalPlan joined = new LogicalPlan.Join(pushInto(j.left(), toLeft), pushInto(j.right(), toRight), kind,
                kind == LogicalPlan.JoinKind.CROSS ? null : cond);
        return filter(joined, above);
    }

    private static LogicalPlan filter(LogicalPlan node, List<BoundExpr> preds) {
        BoundExpr p = BoundExprs.and(preds);
        return p == null ? node : new LogicalPlan.Filter(node, p);
    }
}
