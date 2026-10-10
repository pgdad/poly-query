package polyquery.physical;

import java.util.ArrayList;
import java.util.List;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;

/** Chooses physical algorithms for a logical plan. */
public final class PhysicalPlanner {
    /** Join algorithm preference (query option {@code join}). */
    public enum JoinStrategy { AUTO, HASH, NESTED_LOOP }

    private final JoinStrategy joinStrategy;

    public PhysicalPlanner(JoinStrategy joinStrategy) {
        this.joinStrategy = joinStrategy;
    }

    public PhysicalPlan plan(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> new PhysicalPlan.TableScan(s.table(), s.alias());
            case LogicalPlan.SingleRow s -> new PhysicalPlan.Values();
            case LogicalPlan.Filter f -> new PhysicalPlan.Filter(plan(f.input()), f.predicate());
            case LogicalPlan.Project p -> new PhysicalPlan.Project(plan(p.input()), p.expressions(), p.names());
            case LogicalPlan.Aggregate a -> new PhysicalPlan.HashAggregate(plan(a.input()), a.groupKeys(), a.aggregates());
            case LogicalPlan.Distinct d -> new PhysicalPlan.HashDistinct(plan(d.input()));
            case LogicalPlan.Sort s -> new PhysicalPlan.Sort(plan(s.input()), s.keys());
            case LogicalPlan.Limit l -> new PhysicalPlan.Limit(plan(l.input()), l.offset(), l.limit());
            case LogicalPlan.Join j -> join(j);
        };
    }

    private PhysicalPlan join(LogicalPlan.Join j) {
        PhysicalPlan left = plan(j.left());
        PhysicalPlan right = plan(j.right());
        if (j.condition() == null || joinStrategy == JoinStrategy.NESTED_LOOP) {
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
        return new PhysicalPlan.HashJoin(left, right, j.kind(), leftKeys, rightKeys, BoundExprs.and(residual));
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
