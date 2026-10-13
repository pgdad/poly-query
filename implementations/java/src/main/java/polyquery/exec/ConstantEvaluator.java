package polyquery.exec;

import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;

/** Evaluates constant expressions during semantic analysis (e.g. ROUND digits, DATE_TRUNC units). */
public final class ConstantEvaluator {
    private ConstantEvaluator() {
    }

    /** Value of an expression without row inputs (see {@code BoundExprs.isConstant}). */
    public static Object evaluate(BoundExpr e) {
        return evaluate(e, Map.of());
    }

    /**
     * Value of an expression without row inputs, where the subexpressions (by identity) in
     * {@code knownFailures} are not evaluated again but raise their recorded error.
     */
    public static Object evaluate(BoundExpr e, Map<BoundExpr, PolyQueryException> knownFailures) {
        ExecContext ctx = new ExecContext(0, Long.MAX_VALUE, -1, Long.MAX_VALUE);
        ExpressionCompiler compiler = new ExpressionCompiler(ctx, plan -> {
            throw new PolyQueryException(ErrorCode.INTERNAL_ERROR, "subquery in a constant expression");
        });
        compiler.knownFailures(knownFailures);
        return compiler.compile(e).eval(new Object[0]);
    }
}
