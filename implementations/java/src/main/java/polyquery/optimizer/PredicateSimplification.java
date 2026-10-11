package polyquery.optimizer;

import java.util.ArrayList;
import java.util.List;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;

/**
 * Boolean simplification with constant operands: {@code TRUE AND x → x},
 * {@code FALSE AND x → FALSE}, {@code x OR FALSE → x}, {@code NOT NOT x → x}, … and filters
 * whose predicate is {@code TRUE} disappear. AND/OR evaluate their right operand only if the
 * left one does not decide the result, so a right-hand constant decides only if the left
 * operand cannot fail. An expression that becomes literal-only through a simplification is
 * folded ({@link ConstantFolding#foldNode}).
 */
public final class PredicateSimplification implements OptimizerRule {
    @Override
    public String name() {
        return "predicate_simplification";
    }

    @Override
    public LogicalPlan apply(LogicalPlan plan) {
        return plan.transformUp(node -> {
            LogicalPlan simplified = PlanExpressions.map(node, PredicateSimplification::simplify);
            return simplified instanceof LogicalPlan.Filter f && isTrue(f.predicate()) ? f.input() : simplified;
        });
    }

    static BoundExpr simplify(BoundExpr e) {
        if (ConstantFolding.isFoldable(e)) {
            return e; // constant folding's business (or its evaluation fails)
        }
        List<BoundExpr> children = BoundExprs.children(e);
        if (!children.isEmpty()) {
            List<BoundExpr> simplified = new ArrayList<>(children.size());
            boolean changed = false;
            for (BoundExpr c : children) {
                BoundExpr s = simplify(c);
                changed |= s != c;
                simplified.add(s);
            }
            if (changed) {
                e = BoundExprs.withChildren(e, simplified);
                if (ConstantFolding.isFoldable(e)) {
                    return ConstantFolding.foldNode(e);
                }
            }
        }
        return switch (e) {
            case BoundExpr.And a when isTrue(a.left()) -> a.right();
            case BoundExpr.And a when isTrue(a.right()) -> a.left();
            case BoundExpr.And a when isFalse(a.left()) -> a.left();
            case BoundExpr.And a when isFalse(a.right()) && !ExprSafety.mayFail(a.left()) -> a.right();
            case BoundExpr.Or o when isFalse(o.left()) -> o.right();
            case BoundExpr.Or o when isFalse(o.right()) -> o.left();
            case BoundExpr.Or o when isTrue(o.left()) -> o.left();
            case BoundExpr.Or o when isTrue(o.right()) && !ExprSafety.mayFail(o.left()) -> o.right();
            case BoundExpr.Not n when n.input() instanceof BoundExpr.Not inner -> inner.input();
            default -> e;
        };
    }

    private static boolean isTrue(BoundExpr e) {
        return e instanceof BoundExpr.Literal l && Boolean.TRUE.equals(l.value());
    }

    private static boolean isFalse(BoundExpr e) {
        return e instanceof BoundExpr.Literal l && Boolean.FALSE.equals(l.value());
    }
}
