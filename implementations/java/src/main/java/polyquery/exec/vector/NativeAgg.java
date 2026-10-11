package polyquery.exec.vector;

import polyquery.ffi.NativeKernels;

/**
 * Native aggregation primitives for one {@link AggState} (option {@code native}): exact INT64
 * sums ({@code pqk_sum_i64}), grouped sums ({@code pqk_group_sum_i64}), MIN/MAX
 * ({@code pqk_minmax_i64/f64}) and, through its {@link #kernels}, non-NULL counts
 * ({@code pqk_bitmap_popcount}). Selected rows are first gathered into a dense buffer
 * ({@code pqk_gather_i64}).
 *
 * <p>Every method returns false when the kernels do not apply to the batch — NULLs without a
 * validity bitmap, NULLs under a selection, or a result that would not be identical to the
 * engine's — and the caller then runs its own code. Overflow flags are honoured exactly: a batch
 * whose exact sum leaves the INT64 range, or whose grouped sums may have wrapped (the outputs
 * are then restored with the inverse wrapping subtraction), is recomputed by the engine's exact
 * (BigInteger-widening) code. Holds per-state scratch buffers: one instance per state, so per
 * thread.
 */
final class NativeAgg {
    final NativeKernels kernels;
    /** Results of the last successful call. */
    long sum;
    long valid;
    long min;
    long max;
    double minDouble;
    double maxDouble;
    private final long[] pair = new long[2];
    private final double[] doublePair = new double[2];
    private long[] values = new long[0];
    private double[] doubles = new double[0];
    private int[] groups = new int[0];

    NativeAgg(NativeKernels kernels) {
        this.kernels = kernels;
    }

    /** True if the active rows of {@code arg} can be passed to a kernel (see the class comment). */
    private static boolean applicable(Vec arg, int[] sel) {
        return !arg.hasNulls || sel == null && arg.validityKnown;
    }

    private static long[] validity(Vec arg) {
        return arg.hasNulls ? arg.validity : null;
    }

    /** The LONG values of the active rows, densely: the vector's own array or a gathered copy. */
    private long[] dense(Vec arg, int[] sel, int n) {
        if (sel == null) {
            return arg.longs;
        }
        if (values.length < n) {
            values = new long[Math.max(n, 64)];
        }
        kernels.gather(arg.longs, sel, n, values);
        return values;
    }

    private long validCount(long[] validity, int n) {
        return validity == null ? n : kernels.popcount(validity, n);
    }

    /** Exact sum ({@link #sum}) and number ({@link #valid}) of the non-NULL active values. */
    boolean sum(Vec arg, int[] sel, int n) {
        if (!applicable(arg, sel)) {
            return false;
        }
        long[] v = validity(arg);
        if (kernels.sum(dense(arg, sel, n), v, n, pair) != NativeKernels.OK) {
            return false; // the exact sum is outside INT64: the engine widens to BigInteger
        }
        sum = pair[0];
        valid = validCount(v, n);
        return true;
    }

    /** {@link #min}, {@link #max} and {@link #valid} of the active LONG values. */
    boolean minMax(Vec arg, int[] sel, int n) {
        if (!applicable(arg, sel)) {
            return false;
        }
        valid = kernels.minMax(dense(arg, sel, n), validity(arg), n, pair);
        min = pair[0];
        max = pair[1];
        return true;
    }

    /**
     * {@link #minDouble}, {@link #maxDouble} and {@link #valid} of the active FLOAT64 values. The
     * caller must not use a result of ±0.0: which zero the engine keeps depends on the row order.
     */
    boolean minMaxDouble(Vec arg, int[] sel, int n) {
        if (!applicable(arg, sel)) {
            return false;
        }
        double[] x = arg.doubles;
        if (sel != null) {
            if (doubles.length < n) {
                doubles = new double[Math.max(n, 64)];
            }
            kernels.gather(arg.doubles, sel, n, doubles);
            x = doubles;
        }
        valid = kernels.minMax(x, validity(arg), n, doublePair);
        minDouble = doublePair[0];
        maxDouble = doublePair[1];
        return true;
    }

    /**
     * Adds the non-NULL active values to {@code sums[gids[i]]} and counts them in
     * {@code counts[gids[i]]}. False (state unchanged) if the kernel does not apply or an
     * addition may have wrapped.
     */
    boolean groupSum(Vec arg, int[] sel, int n, int[] gids, long[] sums, long[] counts) {
        if (!applicable(arg, sel)) {
            return false;
        }
        long[] x = dense(arg, sel, n);
        long[] v = validity(arg);
        int[] g = gids;
        if (sel != null) {
            if (groups.length < n) {
                groups = new int[Math.max(n, 64)];
            }
            for (int k = 0; k < n; k++) {
                groups[k] = gids[sel[k]];
            }
            g = groups;
        }
        int status = kernels.groupSum(g, x, v, n, sums, counts, Math.min(sums.length, counts.length));
        if (status == NativeKernels.OK) {
            return true;
        }
        if (status != NativeKernels.OVERFLOW) {
            throw new IllegalStateException("group sum kernel rejected its input (status " + status + ")");
        }
        // Some sum may have wrapped: undo the wrapping additions exactly (two's complement
        // addition is invertible), so the engine can redo the batch with exact arithmetic.
        for (int i = 0; i < n; i++) {
            if (v == null || (v[i >>> 6] >>> i & 1) != 0) {
                sums[g[i]] -= x[i];
                counts[g[i]]--;
            }
        }
        return false;
    }
}
