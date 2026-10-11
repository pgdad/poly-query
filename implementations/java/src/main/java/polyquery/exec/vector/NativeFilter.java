package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import polyquery.ffi.NativeKernels;
import polyquery.plan.BoundExpr.CompareOp;

/**
 * Native evaluation of conjuncts of a WHERE clause with the filter and bitmap kernels of
 * {@code libpqkernels}.
 *
 * <p>Eligible conjuncts compare LONG-represented values (INT64, DECIMAL, DATE, TIMESTAMP,
 * BOOLEAN): {@code column op constant} (either side; DECIMAL constants of another scale are
 * rescaled exactly to the column's scale), {@code column op column} of one scale,
 * {@code column BETWEEN constant AND constant}, and {@code column IS [NOT] NULL}.
 *
 * <p>Order of evaluation: the leading conjuncts that cannot raise an error (comparisons, IS NULL,
 * LIKE, IN, BETWEEN over columns and constants) form the <em>safe prefix</em>; their order does
 * not matter, since three-valued AND is commutative and none of them fails. The eligible ones
 * among them are evaluated natively first, over every row of the batch, the others then by the
 * engine's kernels on the surviving rows, followed by the remaining conjuncts in their order.
 *
 * <p>Three-valued logic is kept exact: a row is dropped only where a conjunct is FALSE. When
 * conjuncts that may fail follow the safe prefix, rows on which the native conjuncts are NULL
 * (none FALSE, one NULL) stay selected for them — the row engine evaluates them on those rows
 * too — and are flagged in {@code sawNull} so they never pass the filter.
 *
 * <p>Per conjunct: {@code pqk_filter_i64_bitmap} (or {@code pqk_compare_i64} for two columns;
 * validity bitmaps for IS NULL) gives the TRUE rows; {@code pqk_bitmap_and} intersects them,
 * {@code pqk_bitmap_andnot} removes FALSE rows from the NULL-tolerant "keep" set. The common
 * case of a single comparison writes the selection vector directly with {@code pqk_filter_i64}.
 * Applies to dense batches (straight from a scan) whose vectors carry validity bitmaps.
 */
final class NativeFilter {
    /** A conjunct the kernels evaluate. */
    private sealed interface Pred {
    }

    /** {@code column op a} or {@code column BETWEEN a AND b}. */
    private record ConstPred(int slot, int op, long a, long b) implements Pred {
    }

    /** {@code left op right} over two columns. */
    private record ColumnsPred(int left, int right, int op) implements Pred {
    }

    /** {@code column IS NULL} ({@code negated}: IS NOT NULL). */
    private record NullPred(int slot, boolean negated) implements Pred {
    }

    private final NativeKernels kernels;
    private final Pred[] preds;
    /** Conjunct index of each of {@link #preds}. */
    private final int[] conjunctOf;
    /** True if no conjunct can fail: rows can be dropped as soon as a conjunct is NULL. */
    private final boolean allSafe;
    /** Per conjunct: evaluated by the last {@link #select}. */
    final boolean[] evaluated;
    /** Whether the last {@link #select} flagged rows in {@code sawNull}. */
    boolean sawNulls;
    private final Pred[] active;
    private long[] pass = new long[0];
    private long[] keep;
    private long[] bits;
    private long[] falseBits;
    private long[] valid;
    private long[] ones;

    private NativeFilter(NativeKernels kernels, Pred[] preds, int[] conjunctOf, int conjuncts, boolean allSafe) {
        this.kernels = kernels;
        this.preds = preds;
        this.conjunctOf = conjunctOf;
        this.allSafe = allSafe;
        this.evaluated = new boolean[conjuncts];
        this.active = new Pred[preds.length];
    }

    /** A native evaluator of the eligible conjuncts of the safe prefix, or null if there is none (or no library). */
    static NativeFilter create(NativeKernels kernels, VecExpr[] conjuncts) {
        if (kernels == null) {
            return null;
        }
        List<Pred> preds = new ArrayList<>();
        List<Integer> index = new ArrayList<>();
        int safe = 0;
        while (safe < conjuncts.length && cannotFail(conjuncts[safe])) {
            Pred p = analyze(conjuncts[safe]);
            if (p != null) {
                preds.add(p);
                index.add(safe);
            }
            safe++;
        }
        if (preds.isEmpty()) {
            return null;
        }
        return new NativeFilter(kernels, preds.toArray(Pred[]::new), index.stream().mapToInt(Integer::intValue).toArray(),
                conjuncts.length, safe == conjuncts.length);
    }

    /** True if evaluating {@code e} can never raise an error (whatever the row values). */
    static boolean cannotFail(VecExpr e) {
        return switch (e) {
            case Kernels.ColumnRef c -> true;
            case Kernels.Constant c -> true;
            case Kernels.Operand o -> true;
            case Kernels.LongCompare c -> cannotFail(c.left) && cannotFail(c.right);
            case Kernels.DecimalCompare c -> cannotFail(c.left) && cannotFail(c.right);
            case Kernels.DoubleCompare c -> cannotFail(c.left) && cannotFail(c.right);
            case Kernels.StringCompare c -> cannotFail(c.left) && cannotFail(c.right);
            case Kernels.IsNull n -> cannotFail(n.input);
            case Kernels.Not n -> cannotFail(n.input);
            case Kernels.AndOr a -> cannotFail(a.left) && cannotFail(a.right);
            case Kernels.Between b -> cannotFail(b.operand) && cannotFail(b.bounds);
            case Kernels.Like l -> cannotFail(l.input);
            case Kernels.InSet i -> cannotFail(i.operand);
            case Kernels.InList i -> cannotFail(i.operand) && java.util.Arrays.stream(i.comparisons)
                    .allMatch(NativeFilter::cannotFail);
            default -> false;
        };
    }

    private static int nativeOp(CompareOp op) {
        return switch (op) {
            case EQ -> NativeKernels.EQ;
            case NEQ -> NativeKernels.NE;
            case LT -> NativeKernels.LT;
            case LE -> NativeKernels.LE;
            case GT -> NativeKernels.GT;
            case GE -> NativeKernels.GE;
        };
    }

    private static CompareOp flip(CompareOp op) {
        return switch (op) {
            case LT -> CompareOp.GT;
            case LE -> CompareOp.GE;
            case GT -> CompareOp.LT;
            case GE -> CompareOp.LE;
            default -> op;
        };
    }

    /** The non-null constant of a constant kernel as its LONG representation, or null. */
    private static Long constant(VecExpr e) {
        return e instanceof Kernels.Constant c && c.value != null ? Vec.longValue(c.value) : null;
    }

    private static final long[] POW10 = new long[19];

    static {
        POW10[0] = 1;
        for (int i = 1; i < POW10.length; i++) {
            POW10[i] = POW10[i - 1] * 10;
        }
    }

    /**
     * {@code x op k / 10^ks} over unscaled column values x of scale {@code xs} as an integer
     * predicate {@code x op' k'} (exact), or null if the constant does not fit.
     */
    private static ConstPred rescaled(int slot, CompareOp op, int xs, long k, int ks) {
        if (ks <= xs) {
            if (xs - ks >= POW10.length) {
                return null;
            }
            try {
                return new ConstPred(slot, nativeOp(op), Math.multiplyExact(k, POW10[xs - ks]), 0);
            } catch (ArithmeticException e) {
                return null;
            }
        }
        if (ks - xs >= POW10.length) {
            return null;
        }
        long p = POW10[ks - xs];
        long f = Math.floorDiv(k, p); // x is an integer: compare with floor(k / p)
        boolean exact = Math.floorMod(k, p) == 0;
        return switch (op) {
            case EQ -> exact ? new ConstPred(slot, NativeKernels.EQ, f, 0) : new ConstPred(slot, NativeKernels.BETWEEN, 1, 0);
            case NEQ -> exact ? new ConstPred(slot, NativeKernels.NE, f, 0)
                    : new ConstPred(slot, NativeKernels.BETWEEN, Long.MIN_VALUE, Long.MAX_VALUE);
            case LT -> new ConstPred(slot, exact ? NativeKernels.LT : NativeKernels.LE, f, 0);
            case LE -> new ConstPred(slot, NativeKernels.LE, f, 0);
            case GT -> new ConstPred(slot, NativeKernels.GT, f, 0);
            case GE -> new ConstPred(slot, exact ? NativeKernels.GE : NativeKernels.GT, f, 0);
        };
    }

    /** {@code column op constant} of a LONG or DECIMAL comparison kernel ({@code operand}: the column side). */
    private static ConstPred withConstant(VecExpr e, VecExpr column) {
        switch (e) {
            case Kernels.LongCompare c -> {
                if (c.left == column) {
                    Long k = constant(c.right);
                    return k == null ? null : new ConstPred(-1, nativeOp(c.op), k, 0);
                }
                Long k = c.right == column ? constant(c.left) : null;
                return k == null ? null : new ConstPred(-1, nativeOp(flip(c.op)), k, 0);
            }
            case Kernels.DecimalCompare c -> {
                if (c.left == column) {
                    Long k = constant(c.right);
                    return k == null ? null : rescaled(-1, c.op, c.s1, k, c.s2);
                }
                Long k = c.right == column ? constant(c.left) : null;
                return k == null ? null : rescaled(-1, flip(c.op), c.s2, k, c.s1);
            }
            default -> {
                return null;
            }
        }
    }

    private static ConstPred atSlot(ConstPred p, int slot) {
        return p == null ? null : new ConstPred(slot, p.op(), p.a(), p.b());
    }

    /** The bounds {@code [lo, hi]} of {@code x op k} for op GE/GT (lower) or LE/LT (upper), or null. */
    private static long[] bound(ConstPred p, boolean lower) {
        int op = p.op();
        long k = p.a();
        if (lower && op == NativeKernels.GE || !lower && op == NativeKernels.LE) {
            return new long[] {k};
        }
        if (lower && op == NativeKernels.GT) {
            return k == Long.MAX_VALUE ? null : new long[] {k + 1};
        }
        if (!lower && op == NativeKernels.LT) {
            return k == Long.MIN_VALUE ? null : new long[] {k - 1};
        }
        return null;
    }

    private static Pred analyze(VecExpr e) {
        switch (e) {
            case Kernels.DecimalCompare c -> {
                if (c.left instanceof Kernels.ColumnRef l) {
                    return atSlot(withConstant(c, c.left), l.slot());
                }
                return c.right instanceof Kernels.ColumnRef r ? atSlot(withConstant(c, c.right), r.slot()) : null;
            }
            case Kernels.LongCompare c -> {
                if (c.left instanceof Kernels.ColumnRef l) {
                    if (c.right instanceof Kernels.ColumnRef r) {
                        return new ColumnsPred(l.slot(), r.slot(), nativeOp(c.op));
                    }
                    Long k = constant(c.right);
                    return k == null ? null : new ConstPred(l.slot(), nativeOp(c.op), k, 0);
                }
                if (c.right instanceof Kernels.ColumnRef r) {
                    Long k = constant(c.left);
                    return k == null ? null : new ConstPred(r.slot(), nativeOp(flip(c.op)), k, 0);
                }
                return null;
            }
            case Kernels.Between b -> {
                // compiled as (operand >= low) AND (operand <= high) over the shared operand
                if (b.negated || !(b.operand instanceof Kernels.ColumnRef col)
                        || !(b.bounds instanceof Kernels.AndOr ao) || !ao.and) {
                    return null;
                }
                ConstPred lo = withConstant(ao.left, b.holder);
                ConstPred hi = withConstant(ao.right, b.holder);
                if (lo == null || hi == null) {
                    return null;
                }
                if (lo.op() == NativeKernels.BETWEEN || hi.op() == NativeKernels.BETWEEN) {
                    return null; // a bound equal to a non-representable value: left to the engine
                }
                long[] a = bound(lo, true);
                long[] z = bound(hi, false);
                if (a == null || z == null) {
                    return lo.op() == NativeKernels.GT || hi.op() == NativeKernels.LT
                            ? new ConstPred(col.slot(), NativeKernels.BETWEEN, 1, 0) // empty range
                            : null;
                }
                return new ConstPred(col.slot(), NativeKernels.BETWEEN, a[0], z[0]);
            }
            case Kernels.IsNull n -> {
                return n.input instanceof Kernels.ColumnRef col ? new NullPred(col.slot(), n.negated) : null;
            }
            default -> {
                return null;
            }
        }
    }

    /** True if the kernels can read vector {@code v} as is: LONG values, NULLs known as a bitmap. */
    private static boolean readable(Vec v, boolean needLongs) {
        return v != null && (!needLongs || v.kind == Vec.Kind.LONG) && (!v.hasNulls || v.validityKnown);
    }

    private static boolean applicable(Pred p, Batch in) {
        return switch (p) {
            case ConstPred c -> readable(in.cols[c.slot()], true);
            case ColumnsPred c -> readable(in.cols[c.left()], true) && readable(in.cols[c.right()], true);
            case NullPred c -> readable(in.cols[c.slot()], false);
        };
    }

    private static long[] validity(Vec v) {
        return v.hasNulls ? v.validity : null;
    }

    private void ensure(int n) {
        int words = (n + 63) >>> 6;
        if (pass.length < words) {
            pass = new long[words];
            keep = new long[words];
            bits = new long[words];
            falseBits = new long[words];
            valid = new long[words];
            ones = new long[words];
            Arrays.fill(ones, -1L);
        }
    }

    /**
     * Evaluates the eligible conjuncts natively on the active rows of {@code in} (dense batches
     * only) and writes the surviving positions to {@code dst}; rows kept only because a conjunct
     * was NULL are flagged in {@code sawNull}. Returns their number, with {@link #evaluated}
     * telling which conjuncts were done and {@link #sawNulls} whether rows were flagged — or -1 if
     * the batch is not eligible.
     */
    int select(Batch in, int[] dst, boolean[] sawNull) {
        if (in.sel != null) {
            return -1;
        }
        int p = 0;
        for (int j = 0; j < preds.length; j++) {
            boolean ok = applicable(preds[j], in);
            evaluated[conjunctOf[j]] = ok;
            if (ok) {
                active[p++] = preds[j];
            }
        }
        if (p == 0) {
            return -1;
        }
        Pred[] preds = active;
        int n = in.count;
        sawNulls = false;
        boolean last = allSafe; // no failing conjunct follows: NULL rows can be dropped right away
        if (p == 1 && preds[0] instanceof ConstPred c) {
            Vec v = in.cols[c.slot()];
            if (!v.hasNulls || last) {
                return kernels.filter(v.longs, validity(v), n, c.op(), c.a(), c.b(), dst);
            }
        }
        ensure(n);
        int nbytes = (n + 7) >>> 3;
        boolean tracking = false; // keep (no conjunct FALSE) differs from pass (all TRUE)
        for (int j = 0; j < p; j++) {
            long[] t = j == 0 ? pass : bits;
            long[] v = evaluate(preds[j], in, n, nbytes, t);
            if (v != null && !last && !tracking) {
                if (j == 0) {
                    System.arraycopy(ones, 0, keep, 0, (n + 63) >>> 6);
                } else {
                    System.arraycopy(pass, 0, keep, 0, (n + 63) >>> 6);
                }
                tracking = true;
            }
            if (tracking) {
                if (v == null) {
                    kernels.and(keep, t, keep, nbytes);
                } else {
                    kernels.andNot(v, t, falseBits, nbytes); // valid and not TRUE: FALSE
                    kernels.andNot(keep, falseBits, keep, nbytes);
                }
            }
            if (j > 0) {
                kernels.and(pass, t, pass, nbytes);
            }
        }
        if (!tracking) {
            return positions(pass, n, dst);
        }
        kernels.andNot(keep, pass, bits, nbytes); // kept because of a NULL only
        sawNulls = mark(bits, n, sawNull);
        return positions(keep, n, dst);
    }

    /**
     * Writes the TRUE rows of a conjunct to {@code t}; returns the validity bitmap of the rows
     * where it is not NULL, or null if it is never NULL.
     */
    private long[] evaluate(Pred pred, Batch in, int n, int nbytes, long[] t) {
        switch (pred) {
            case ConstPred c -> {
                Vec v = in.cols[c.slot()];
                long[] vb = validity(v);
                kernels.filterBitmap(v.longs, vb, n, c.op(), c.a(), c.b(), t);
                return vb;
            }
            case ColumnsPred c -> {
                Vec x = in.cols[c.left()];
                Vec y = in.cols[c.right()];
                kernels.compare(x.longs, y.longs, n, c.op(), t);
                long[] vx = validity(x);
                long[] vy = validity(y);
                long[] vb;
                if (vx == null || vy == null) {
                    vb = vx == null ? vy : vx;
                } else {
                    kernels.and(vx, vy, valid, nbytes);
                    vb = valid;
                }
                if (vb != null) {
                    kernels.and(t, vb, t, nbytes);
                }
                return vb;
            }
            case NullPred c -> {
                long[] vb = validity(in.cols[c.slot()]);
                if (vb == null) {
                    vb = ones;
                }
                if (c.negated()) {
                    System.arraycopy(vb, 0, t, 0, (n + 63) >>> 6); // IS NOT NULL: the valid rows
                } else {
                    kernels.andNot(ones, vb, t, nbytes); // IS NULL: the invalid rows
                }
                return null;
            }
        }
    }

    /** The positions {@code < n} of the set bits of {@code b}, ascending; returns their number. */
    private static int positions(long[] b, int n, int[] dst) {
        int words = (n + 63) >>> 6;
        int m = 0;
        for (int w = 0; w < words; w++) {
            long word = b[w];
            if (w == words - 1 && (n & 63) != 0) {
                word &= (1L << n) - 1; // bits beyond n are not maintained
            }
            int base = w << 6;
            while (word != 0) {
                dst[m++] = base + Long.numberOfTrailingZeros(word);
                word &= word - 1;
            }
        }
        return m;
    }

    /** Sets {@code flags[i]} for the set bits {@code i < n} of {@code b}; true if there was one. */
    private static boolean mark(long[] b, int n, boolean[] flags) {
        int words = (n + 63) >>> 6;
        boolean any = false;
        for (int w = 0; w < words; w++) {
            long word = b[w];
            if (w == words - 1 && (n & 63) != 0) {
                word &= (1L << n) - 1;
            }
            int base = w << 6;
            while (word != 0) {
                flags[base + Long.numberOfTrailingZeros(word)] = true;
                any = true;
                word &= word - 1;
            }
        }
        return any;
    }
}
