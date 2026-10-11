package polyquery.exec.vector;

import java.util.Arrays;
import java.util.BitSet;
import java.util.List;
import polyquery.common.PolyQueryException;
import polyquery.exec.Evaluator;
import polyquery.exec.ExecContext;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;

/**
 * The expressions an operator evaluates per input row (e.g. a projection list, or group keys
 * followed by aggregate arguments), evaluated batch-wise with the row engine's error semantics.
 *
 * <p>The kernels run first. If one raises a data error, the batch is re-evaluated row by row
 * (row-major, expressions in order) with the row engine's compiled code: the first row that
 * fails determines the error, the batch is truncated to the rows before it and the error is
 * deferred to the consumer ({@link Batch#error}). Errors that must stop the query at once
 * (timeout, cancellation, resource limits) are never deferred.
 */
final class BatchExprs {
    private final List<BoundExpr> exprs;
    private final VecExpr[] kernels;
    private final VecCompiler compiler;
    private final Vec[] results;
    private Evaluator[] rowCode;
    private int[] slots;
    private Vec[] fallback;
    private Object[] row = new Object[0];

    BatchExprs(VecCompiler compiler, List<BoundExpr> exprs) {
        this.compiler = compiler;
        this.exprs = List.copyOf(exprs);
        this.kernels = new VecExpr[exprs.size()];
        for (int i = 0; i < kernels.length; i++) {
            kernels[i] = compiler.compile(exprs.get(i));
        }
        this.results = new Vec[kernels.length];
    }

    int size() {
        return kernels.length;
    }

    /** True if an error may be deferred to the row that causes it (a data-dependent error). */
    static boolean deferrable(PolyQueryException e) {
        return ExecContext.isDataError(e);
    }

    /**
     * Evaluates all expressions at the active rows of {@code b} (at least one); may truncate
     * {@code b} (see the class comment). The returned array and vectors are reused by the next call.
     */
    Vec[] eval(Batch b) {
        try {
            for (int j = 0; j < kernels.length; j++) {
                results[j] = kernels[j].eval(b, b.sel, b.count);
            }
            return results;
        } catch (PolyQueryException e) {
            if (!deferrable(e)) {
                throw e;
            }
        }
        return evalRows(b);
    }

    /** Row-by-row evaluation (see the class comment); may truncate {@code b}. */
    Vec[] evalRows(Batch b) {
        if (rowCode == null) {
            rowCode = new Evaluator[exprs.size()];
            fallback = new Vec[exprs.size()];
            BitSet read = new BitSet();
            for (int j = 0; j < rowCode.length; j++) {
                rowCode[j] = compiler.rowCompiler().compile(exprs.get(j));
                fallback[j] = new Vec(exprs.get(j).type(), 16);
                for (int s : BoundExprs.inputSlots(exprs.get(j))) {
                    read.set(s);
                }
            }
            slots = read.stream().toArray();
        }
        if (row.length < b.cols.length) {
            row = new Object[b.cols.length];
        }
        for (Vec v : fallback) {
            v.ensure(b.size);
            v.nullMask(b.size);
        }
        try {
            for (int k = 0; k < b.count; k++) {
                int i = b.pos(k);
                for (int s : slots) {
                    row[s] = b.cols[s] == null ? null : b.cols[s].get(i);
                }
                for (int j = 0; j < rowCode.length; j++) {
                    Object v;
                    try {
                        v = rowCode[j].eval(row);
                    } catch (PolyQueryException e) {
                        if (!deferrable(e)) {
                            throw e;
                        }
                        b.truncate(k, e);
                        return fallback;
                    }
                    fallback[j].set(i, v);
                }
            }
        } finally {
            Arrays.fill(row, null);
        }
        return fallback;
    }
}
