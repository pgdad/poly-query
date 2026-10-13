package polyquery.optimizer;

import java.util.IdentityHashMap;
import java.util.Map;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;

/**
 * Memoized "is this subexpression foldable" test for one rule application. Bottom-up rewrites
 * ask it about every node of an expression; without the memo each question would scan the
 * node's whole subtree, which is quadratic for long operator chains (CR-6). Nodes are keyed by
 * identity: expression records compare structurally, which is itself a subtree walk.
 */
final class Constness {
    private final Map<BoundExpr, Boolean> memo = new IdentityHashMap<>();

    /** True if {@code e} has no row inputs and no placeholders (literals included). */
    boolean isConstant(BoundExpr e) {
        Boolean known = memo.get(e);
        if (known != null) {
            return known;
        }
        boolean constant = !BoundExprs.isRowInput(e) && !(e instanceof BoundExpr.Placeholder);
        if (constant) {
            for (BoundExpr c : BoundExprs.children(e)) {
                if (!isConstant(c)) {
                    constant = false;
                    break;
                }
            }
        }
        memo.put(e, constant);
        return constant;
    }

    /** True if {@code e} is a constant expression that is not yet a literal. */
    boolean isFoldable(BoundExpr e) {
        return !(e instanceof BoundExpr.Literal) && isConstant(e);
    }
}
