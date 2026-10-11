package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.BitSet;
import java.util.List;
import java.util.Objects;
import java.util.SplittableRandom;
import polyquery.NativeKernelsTest;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.exec.ExpressionCompiler;
import polyquery.ffi.NativeKernels;
import polyquery.plan.AggregateCall;
import polyquery.plan.AggregateCall.AggregateFunction;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExpr.CompareOp;
import polyquery.storage.ColumnVector;
import polyquery.types.DataType;

/**
 * White-box differential tests of the native code paths of the vectorized engine: the native
 * filter, aggregate states and key hashing must give exactly the results of the engine's own
 * code on batches as table scans produce them (with validity bitmaps, NULLs, selections, extreme
 * values). Skipped when the native kernel library is not available.
 */
public final class NativeVectorTest {
    private static final int ROWS = 1500;
    private static final int BATCH = 256;
    private static final DataType DATE = DataType.DATE;

    private NativeVectorTest() {
    }

    private static void check(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError(msg);
        }
    }

    private static ExecContext ctx(NativeKernels kernels) {
        return new ExecContext(0, Long.MAX_VALUE, -1, Long.MAX_VALUE).withNativeKernels(kernels);
    }

    private static VecCompiler compiler(ExecContext ctx) {
        return new VecCompiler(ctx, new ExpressionCompiler(ctx, p -> {
            throw new UnsupportedOperationException("no subqueries here");
        }));
    }

    /**
     * Table columns: 0 INT64 with NULLs, 1 INT64 without, 2 DATE with NULLs, 3 FLOAT64 with NULLs,
     * 4 INT64 extreme, 5 and 6 FLOAT64 whose minimum resp. maximum is a mix of 0.0 and -0.0.
     */
    private static ColumnVector[] table(SplittableRandom r) {
        long[] a = new long[ROWS];
        long[] b = new long[ROWS];
        int[] d = new int[ROWS];
        double[] f = new double[ROWS];
        long[] e = new long[ROWS];
        double[] z1 = new double[ROWS];
        double[] z2 = new double[ROWS];
        BitSet na = new BitSet();
        BitSet nd = new BitSet();
        BitSet nf = new BitSet();
        for (int i = 0; i < ROWS; i++) {
            a[i] = r.nextInt(21) - 10;
            b[i] = r.nextInt(21) - 10;
            d[i] = 19000 + r.nextInt(30);
            f[i] = r.nextInt(5) == 0 ? (r.nextBoolean() ? -0.0 : 0.0) : (r.nextInt(2001) - 1000) / 8.0;
            double zero = r.nextBoolean() ? -0.0 : 0.0;
            z1[i] = r.nextInt(3) == 0 ? 1.5 : zero;
            z2[i] = r.nextInt(3) == 0 ? -1.5 : zero;
            e[i] = r.nextInt(3) == 0 ? Long.MAX_VALUE - r.nextInt(5) : r.nextInt(3) == 0 ? Long.MIN_VALUE + r.nextInt(5)
                    : r.nextLong();
            // NULL runs and isolated NULLs; whole batches without NULLs too
            if ((i / BATCH) % 3 != 1 && r.nextInt(4) == 0) {
                na.set(i);
                a[i] = 0;
            }
            if (r.nextInt(5) == 0) {
                nd.set(i);
            }
            if (r.nextInt(6) == 0) {
                nf.set(i);
            }
        }
        return new ColumnVector[] {ColumnVector.ofLongs(DataType.INT64, a, na),
            ColumnVector.ofLongs(DataType.INT64, b, new BitSet()), ColumnVector.ofInts(DATE, d, nd),
            ColumnVector.ofDoubles(f, nf), ColumnVector.ofLongs(DataType.INT64, e, new BitSet()),
            ColumnVector.ofDoubles(z1, new BitSet()), ColumnVector.ofDoubles(z2, nf)};
    }

    private static final DataType[] TYPES = {DataType.INT64, DataType.INT64, DATE, DataType.FLOAT64, DataType.INT64,
        DataType.FLOAT64, DataType.FLOAT64};

    /** Scan-like source: batches loaded with {@link ScanBatches#load}, i.e. with validity bitmaps. */
    private static final class Source implements BatchOperator {
        private final ColumnVector[] cols;
        private final Batch batch = new Batch(TYPES.length);
        private int pos;

        Source(ColumnVector[] cols) {
            this.cols = cols;
            for (int c = 0; c < cols.length; c++) {
                batch.cols[c] = new Vec(TYPES[c], BATCH);
            }
        }

        @Override
        public void open() {
            pos = 0;
        }

        @Override
        public Batch next() {
            if (pos >= ROWS) {
                return null;
            }
            int n = Math.min(BATCH - 7, ROWS - pos); // odd batch sizes: partial bytes and words
            for (int c = 0; c < cols.length; c++) {
                ScanBatches.load(cols[c], pos, n, batch.cols[c], BATCH);
            }
            pos += n;
            batch.reset(n);
            return batch;
        }
    }

    private static BoundExpr col(int i) {
        return new BoundExpr.ColumnRef(i, TYPES[i], "c" + i);
    }

    private static BoundExpr lit(long v) {
        return new BoundExpr.Literal(v, DataType.INT64);
    }

    private static BoundExpr cmp(CompareOp op, BoundExpr l, BoundExpr r) {
        return new BoundExpr.Comparison(op, l, r);
    }

    private static BoundExpr between(int c, Object lo, Object hi, DataType t) {
        BoundExpr p = new BoundExpr.Placeholder(t);
        return new BoundExpr.Between(col(c), cmp(CompareOp.GE, p, new BoundExpr.Literal(lo, t)),
                cmp(CompareOp.LE, p, new BoundExpr.Literal(hi, t)), false);
    }

    private static BoundExpr and(BoundExpr... parts) {
        BoundExpr e = parts[0];
        for (int i = 1; i < parts.length; i++) {
            e = new BoundExpr.And(e, parts[i]);
        }
        return e;
    }

    /** The output of a filter: selected rows per batch, then the error, if any. */
    private static String run(BatchOperator op) {
        StringBuilder sb = new StringBuilder();
        op.open();
        try {
            Batch b;
            while ((b = op.next()) != null) {
                for (int k = 0; k < b.count; k++) {
                    sb.append(b.cols[0].get(b.pos(k))).append('/').append(b.cols[1].get(b.pos(k))).append(' ');
                }
                sb.append('|');
                if (b.error != null) {
                    throw b.error;
                }
            }
        } catch (PolyQueryException e) {
            sb.append("error ").append(e.code());
        }
        return sb.toString();
    }

    public static void testNativeFilterMatchesEngine() {
        NativeKernels k = NativeKernelsTest.kernels();
        if (k == null) {
            return;
        }
        ColumnVector[] data = table(new SplittableRandom(5));
        BoundExpr gt = cmp(CompareOp.GT, col(0), lit(3));
        BoundExpr flipped = cmp(CompareOp.LT, lit(-4), col(0)); // constant on the left
        BoundExpr folded = cmp(CompareOp.LE, new BoundExpr.Arithmetic(BoundExpr.ArithOp.ADD, lit(1), lit(2),
                DataType.INT64), col(1));
        BoundExpr btw = between(0, -2L, 5L, DataType.INT64);
        BoundExpr cols = cmp(CompareOp.GE, col(0), col(1));
        BoundExpr dates = between(2, 19005, 19020, DATE);
        BoundExpr isNull = new BoundExpr.IsNull(col(0), false);
        BoundExpr notNull = new BoundExpr.IsNull(col(2), true);
        BoundExpr extreme = cmp(CompareOp.NEQ, col(4), lit(Long.MAX_VALUE));
        BoundExpr dbl = cmp(CompareOp.GT, col(3), new BoundExpr.Literal(0.5, DataType.FLOAT64));
        // fails on b = 0 rows — also on rows where an earlier conjunct is NULL (AND continues on NULL)
        BoundExpr failing = cmp(CompareOp.GT, new BoundExpr.Arithmetic(BoundExpr.ArithOp.DIV, lit(100), col(1),
                DataType.INT64), lit(-1000));
        // never TRUE, NULL on the NULL rows: the error comes only from rows where the native run is NULL
        BoundExpr never = cmp(CompareOp.GT, col(0), lit(100));
        BoundExpr failingA = cmp(CompareOp.GT, new BoundExpr.Arithmetic(BoundExpr.ArithOp.DIV, lit(100),
                new BoundExpr.Arithmetic(BoundExpr.ArithOp.ADD, col(1), lit(11), DataType.INT64), DataType.INT64),
                lit(-1000));
        List<BoundExpr> predicates = List.of(gt, flipped, folded, btw, cols, dates, isNull, notNull, extreme, dbl,
                and(gt, cols), and(btw, dates, extreme), and(isNull, cols), and(gt, dbl), and(dbl, gt),
                and(btw, notNull, dbl, flipped), and(gt, failing), and(cols, failing), and(dates, failingA),
                and(notNull, btw, failingA), and(failing, gt), and(cols, isNull, dates, dbl),
                and(never, failing), and(never, btw, failing), and(never, extreme, dbl, failing));
        ExecContext plain = ctx(null);
        ExecContext nat = ctx(k);
        for (BoundExpr p : predicates) {
            String expected = run(new BatchOperators.Filter(new Source(data), compiler(plain), p, TYPES.length));
            String actual = run(new BatchOperators.Filter(new Source(data), compiler(nat), p, TYPES.length));
            check(expected.equals(actual), "native filter differs for " + p + ":\n" + expected + "\n" + actual);
        }
        // the eligible conjuncts are indeed evaluated natively
        VecCompiler c = compiler(nat);
        for (BoundExpr p : List.of(gt, flipped, folded, btw, cols, dates, isNull, notNull, extreme)) {
            check(NativeFilter.create(k, new VecExpr[] {c.compile(p)}) != null, "native filter for " + p);
        }
        check(NativeFilter.create(k, new VecExpr[] {c.compile(dbl)}) == null, "no native filter for FLOAT64");
        check(NativeFilter.create(k, new VecExpr[] {c.compile(failing)}) == null, "no native filter for arithmetic");
        Source src = new Source(data);
        src.open();
        Batch b = src.next();
        NativeFilter f = NativeFilter.create(k, new VecExpr[] {c.compile(gt), c.compile(btw), c.compile(dbl)});
        int m = f.select(b, new int[BATCH], new boolean[BATCH]);
        check(m >= 0 && f.consumed == 2, "two leading conjuncts evaluated natively");
    }

    private static Object result(AggState s, int g) {
        try {
            Object v = s.result(g);
            return v instanceof Double d ? "d" + Double.doubleToRawLongBits(d) : v;
        } catch (PolyQueryException e) {
            return "error " + e.code();
        }
    }

    public static void testNativeAggregatesMatchEngine() {
        NativeKernels k = NativeKernelsTest.kernels();
        if (k == null) {
            return;
        }
        SplittableRandom r = new SplittableRandom(6);
        ColumnVector[] data = table(r);
        int[] argCols = {0, 1, 2, 3, 4, 5, 6};
        for (int c : argCols) {
            DataType t = TYPES[c];
            BoundExpr arg = col(c);
            List<AggregateCall> calls = new ArrayList<>();
            calls.add(new AggregateCall(AggregateFunction.COUNT, arg, false, DataType.INT64));
            calls.add(new AggregateCall(AggregateFunction.MIN, arg, false, t));
            calls.add(new AggregateCall(AggregateFunction.MAX, arg, false, t));
            if (t != DATE) {
                calls.add(new AggregateCall(AggregateFunction.SUM, arg, false, t));
                calls.add(new AggregateCall(AggregateFunction.AVG, arg, false, DataType.FLOAT64));
            }
            for (AggregateCall call : calls) {
                for (int mode = 0; mode < 4; mode++) { // single/grouped × dense/selected
                    boolean grouped = mode >= 2;
                    boolean selected = mode % 2 == 1;
                    AggState plain = AggState.create(call, null);
                    AggState nat = AggState.create(call, k);
                    int groups = grouped ? 7 : 1;
                    plain.grow(groups);
                    nat.grow(groups);
                    Source src = new Source(data);
                    src.open();
                    Batch b;
                    int[] gids = new int[BATCH];
                    int[] sel = new int[BATCH];
                    while ((b = src.next()) != null) {
                        Vec v = b.cols[c];
                        int n = b.count;
                        int[] s = null;
                        if (selected) {
                            n = 0;
                            for (int i = 0; i < b.count; i++) {
                                if (r.nextInt(3) != 0) {
                                    sel[n++] = i;
                                }
                            }
                            s = sel;
                        }
                        for (int i = 0; i < b.count; i++) {
                            gids[i] = grouped ? r.nextInt(groups) : 0;
                        }
                        if (grouped) {
                            plain.update(v, s, n, gids);
                            nat.update(v, s, n, gids);
                        } else {
                            plain.updateSingle(v, s, n, gids);
                            nat.updateSingle(v, s, n, gids);
                        }
                    }
                    for (int g = 0; g < groups; g++) {
                        check(Objects.equals(result(plain, g), result(nat, g)), call.function() + "(c" + c
                                + ") mode " + mode + " group " + g + ": " + result(plain, g) + " vs "
                                + result(nat, g));
                    }
                }
            }
        }
    }

    public static void testKeyHashingIdenticalWithNative() {
        NativeKernels k = NativeKernelsTest.kernels();
        if (k == null) {
            return;
        }
        ColumnVector[] data = table(new SplittableRandom(7));
        for (int c : new int[] {0, 1, 2, 3}) {
            GroupKeys plain = new GroupKeys(new DataType[] {TYPES[c]}, null);
            GroupKeys nat = new GroupKeys(new DataType[] {TYPES[c]}, k);
            Source src = new Source(data);
            src.open();
            Batch b;
            int[] g1 = new int[BATCH];
            int[] g2 = new int[BATCH];
            int[] sel = new int[BATCH];
            int round = 0;
            while ((b = src.next()) != null) {
                int n = 0;
                for (int i = 0; i < b.count; i += 1 + round % 3) {
                    sel[n++] = i;
                }
                int[] s = round++ % 2 == 0 ? null : sel;
                int cnt = s == null ? b.count : n;
                plain.groupIds(new Vec[] {b.cols[c]}, s, cnt, b.size, g1);
                nat.groupIds(new Vec[] {b.cols[c]}, s, cnt, b.size, g2);
                for (int kk = 0; kk < cnt; kk++) {
                    int i = s == null ? kk : s[kk];
                    check(g1[i] == g2[i], "group ids agree");
                }
            }
            check(plain.groupCount() == nat.groupCount(), "group counts agree");
            for (int g = 0; g < plain.groupCount(); g++) {
                check(plain.hash(g) == nat.hash(g), "hashes agree");
            }
        }
    }
}
