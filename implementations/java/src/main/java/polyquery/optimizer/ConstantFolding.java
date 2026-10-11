package polyquery.optimizer;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.PolyQueryException;
import polyquery.exec.ConstantEvaluator;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;

/**
 * Constant folding: every literal-only subexpression of the plan's predicates, join
 * conditions, group keys, aggregate arguments and projections is evaluated once, at planning
 * time — unless its evaluation fails: then it is left in place and the error is raised at run
 * time by the rows that evaluate it (if any).
 */
public final class ConstantFolding implements OptimizerRule {
    @Override
    public String name() {
        return "constant_folding";
    }

    @Override
    public LogicalPlan apply(LogicalPlan plan) {
        return plan.transformUp(node -> PlanExpressions.map(node, ConstantFolding::fold));
    }

    /** Folds the constant subexpressions of {@code e}, bottom-up. */
    static BoundExpr fold(BoundExpr e) {
        List<BoundExpr> children = BoundExprs.children(e);
        if (!children.isEmpty()) {
            List<BoundExpr> folded = new ArrayList<>(children.size());
            boolean changed = false;
            for (BoundExpr c : children) {
                BoundExpr f = fold(c);
                changed |= f != c;
                folded.add(f);
            }
            if (changed) {
                e = BoundExprs.withChildren(e, folded);
            }
        }
        return foldNode(e);
    }

    /** True if {@code e} is a constant expression that is not yet a literal. */
    static boolean isFoldable(BoundExpr e) {
        return !(e instanceof BoundExpr.Literal) && BoundExprs.isConstant(e)
                && !BoundExprs.any(e, x -> x instanceof BoundExpr.Placeholder);
    }

    /** {@code e} replaced by its value if it is foldable and evaluating it succeeds, else {@code e}. */
    static BoundExpr foldNode(BoundExpr e) {
        if (!isFoldable(e)) {
            return e;
        }
        try {
            return new BoundExpr.Literal(ConstantEvaluator.evaluate(e), e.type());
        } catch (PolyQueryException ex) {
            return e; // raised at run time by the rows that evaluate it (if any)
        }
    }
}
