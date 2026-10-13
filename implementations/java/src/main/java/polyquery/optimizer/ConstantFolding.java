package polyquery.optimizer;

import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
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
 *
 * <p>The work is linear in the size of an expression: constness is memoized
 * ({@link Constness}) and a subexpression whose evaluation failed is not evaluated again by its
 * ancestors — they see its error directly.
 */
public final class ConstantFolding implements OptimizerRule {
    @Override
    public String name() {
        return "constant_folding";
    }

    @Override
    public LogicalPlan apply(LogicalPlan plan) {
        Folder folder = new Folder();
        return plan.transformUp(node -> PlanExpressions.map(node, folder::fold));
    }

    /** The folding state of one rule application. */
    static final class Folder {
        private final Constness constness = new Constness();
        /** Constant subexpressions whose evaluation failed, with their error. */
        private final Map<BoundExpr, PolyQueryException> failures = new IdentityHashMap<>();

        /** Folds the constant subexpressions of {@code e}, bottom-up. */
        BoundExpr fold(BoundExpr e) {
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

        boolean isFoldable(BoundExpr e) {
            return constness.isFoldable(e);
        }

        /** {@code e} replaced by its value if it is foldable and evaluating it succeeds, else {@code e}. */
        BoundExpr foldNode(BoundExpr e) {
            if (!isFoldable(e)) {
                return e;
            }
            try {
                return new BoundExpr.Literal(ConstantEvaluator.evaluate(e, failures), e.type());
            } catch (PolyQueryException ex) {
                failures.put(e, ex);
                return e; // raised at run time by the rows that evaluate it (if any)
            }
        }
    }
}
