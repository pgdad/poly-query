package polyquery.exec;

import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;

/** Evaluates constant expressions during semantic analysis (e.g. ROUND digits, DATE_TRUNC units). */
public final class ConstantEvaluator {
    private ConstantEvaluator() {
    }

    /** Value of an expression without row inputs (see {@code BoundExprs.isConstant}). */
    public static Object evaluate(BoundExpr e) {
        ExecContext ctx = new ExecContext(0, Long.MAX_VALUE, -1, Long.MAX_VALUE);
        ExpressionCompiler compiler = new ExpressionCompiler(ctx, plan -> {
            throw new PolyQueryException(ErrorCode.INTERNAL_ERROR, "subquery in a constant expression");
        });
        return compiler.compile(e).eval(new Object[0]);
    }
}
