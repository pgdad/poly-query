package polyquery.exec.vector;

/**
 * A scalar expression compiled for batch evaluation. Implementations evaluate exactly the rows
 * the row engine would evaluate (or more, as long as the extra work cannot change a result):
 * any error they raise makes the caller re-evaluate the batch row by row (see
 * {@link BatchExprs}), which determines the exact row-at-a-time error semantics.
 */
interface VecExpr {
    /**
     * Evaluates the expression at positions {@code sel[0..n)} of {@code b} ({@code sel == null}:
     * positions {@code 0..n-1}). The returned vector holds the results at those positions; it is
     * either a vector of the batch or a buffer owned by this expression, and must not be modified.
     */
    Vec eval(Batch b, int[] sel, int n);
}
