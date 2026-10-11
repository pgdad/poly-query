package polyquery.exec.vector;

import java.math.BigInteger;
import java.util.Arrays;
import polyquery.exec.Accumulator;
import polyquery.ffi.NativeKernels;
import polyquery.plan.AggregateCall;
import polyquery.types.DataType;
import polyquery.types.Values;

/**
 * The running state of one aggregate function for all groups, as primitive arrays indexed by
 * group id (struct of arrays: no per-group objects). Semantics are those of the row engine's
 * {@link Accumulator}s; partial states of parallel workers can be merged exactly.
 */
abstract class AggState {
    /** Makes room for groups {@code 0 .. groups-1}. */
    abstract void grow(int groups);

    /** Adds the values of {@code arg} (null for COUNT(*)) at the active positions to their groups. */
    abstract void update(Vec arg, int[] sel, int n, int[] gids);

    /**
     * Adds the values at the active positions to group 0 (aggregation without GROUP BY).
     * Implementations use reduction loops the JIT can vectorize.
     */
    void updateSingle(Vec arg, int[] sel, int n, int[] zeros) {
        update(arg, sel, n, zeros);
    }

    /** Adds the state of {@code other}'s group {@code from} to group {@code to}. */
    abstract void merge(AggState other, int from, int to);

    /** Final value of group g (boxed runtime value; may raise NUMERIC_OVERFLOW). */
    abstract Object result(int g);

    /** False if partial states cannot be merged. */
    boolean mergeable() {
        return true;
    }

    /**
     * Called on a parallel worker's partial state once it is complete, before it is merged
     * (concurrently, for different groups) into the final tables.
     */
    void prepareMerge() {
    }

    /**
     * The state of {@code call}; with {@code kernels} (option {@code native}), COUNT(x), INT64/
     * DECIMAL SUM/AVG and MIN/MAX of INT64-like and FLOAT64 values use the native kernels where
     * they give the same result (see {@link NativeAgg}).
     */
    static AggState create(AggregateCall call, NativeKernels kernels) {
        DataType in = call.argument() == null ? null : call.argument().type();
        if (call.distinct()) {
            if (in == null || in.isNull() || in.isWideDecimal()) {
                return new Generic(call);
            }
            AggregateCall plain = new AggregateCall(call.function(), call.argument(), false, call.type());
            return new Distinct(create(plain, kernels), in);
        }
        // wide DECIMAL arguments never go to the kernels (their ABI covers 64-bit values only)
        NativeAgg nat = kernels == null || in != null && in.isWideDecimal() ? null : new NativeAgg(kernels);
        return switch (call.function()) {
            case COUNT_STAR -> new Count(false, null);
            case COUNT -> new Count(true, nat);
            case SUM, AVG -> {
                boolean avg = call.function() == AggregateCall.AggregateFunction.AVG;
                yield switch (in.kind()) {
                    case FLOAT64 -> new DoubleSum(avg); // native sums reassociate: not bit-identical
                    case DECIMAL -> in.isWideDecimal() ? new WideSum(avg, in.scale(), avg ? null : call.type())
                            : new LongSum(avg, in.scale(), avg ? null : call.type(), nat);
                    case INT64 -> new LongSum(avg, 0, null, nat);
                    default -> new Generic(call);
                };
            }
            case MIN, MAX -> {
                boolean min = call.function() == AggregateCall.AggregateFunction.MIN;
                yield switch (Vec.kindOf(in)) {
                    case LONG -> in.isNull() ? new Generic(call) : new LongMinMax(in, min, nat);
                    case DOUBLE -> new DoubleMinMax(min, nat);
                    default -> in.isNull() ? new Generic(call) : new ObjectMinMax(in, min);
                };
            }
        };
    }

    /** COUNT(*) ({@code nonNull == false}) or COUNT(x). */
    static final class Count extends AggState {
        private final boolean nonNull;
        private final NativeAgg nat;
        private long[] counts = new long[16];

        Count(boolean nonNull, NativeAgg nat) {
            this.nonNull = nonNull;
            this.nat = nat;
        }

        @Override
        void grow(int groups) {
            if (counts.length < groups) {
                counts = Arrays.copyOf(counts, Math.max(groups, counts.length * 2));
            }
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            long[] c = counts;
            boolean checkNull = nonNull && arg.hasNulls;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!(checkNull && arg.nulls[i])) {
                    c[gids[i]]++;
                }
            }
        }

        @Override
        void updateSingle(Vec arg, int[] sel, int n, int[] zeros) {
            if (!nonNull || !arg.hasNulls) {
                counts[0] += n;
                return;
            }
            if (nat != null && sel == null && arg.validityKnown) {
                counts[0] += nat.kernels.popcount(arg.validity, n);
                return;
            }
            long c = 0;
            boolean[] nulls = arg.nulls;
            for (int k = 0; k < n; k++) {
                c += nulls[sel == null ? k : sel[k]] ? 0 : 1;
            }
            counts[0] += c;
        }

        @Override
        void merge(AggState other, int from, int to) {
            counts[to] += ((Count) other).counts[from];
        }

        @Override
        Object result(int g) {
            return counts[g];
        }
    }

    /** Exact SUM/AVG of INT64 or DECIMAL values: long sums that widen to BigInteger on overflow. */
    static final class LongSum extends AggState {
        private final boolean average;
        private final int scale;
        private final DataType decimal;
        private final NativeAgg nat;
        private long[] sums = new long[16];
        private long[] counts = new long[16];
        private BigInteger[] big;

        /** @param decimal the result type of a DECIMAL SUM, else null */
        LongSum(boolean average, int scale, DataType decimal, NativeAgg nat) {
            this.average = average;
            this.scale = scale;
            this.decimal = decimal;
            this.nat = nat;
        }

        @Override
        void grow(int groups) {
            if (sums.length < groups) {
                int n = Math.max(groups, sums.length * 2);
                sums = Arrays.copyOf(sums, n);
                counts = Arrays.copyOf(counts, n);
                if (big != null) {
                    big = Arrays.copyOf(big, n);
                }
            }
        }

        private void addSlow(int g, long x) {
            if (big == null) {
                big = new BigInteger[sums.length];
            }
            if (big[g] == null) {
                big[g] = BigInteger.valueOf(sums[g]);
                sums[g] = 0;
            }
            big[g] = big[g].add(BigInteger.valueOf(x));
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            if (nat != null && big == null && nat.groupSum(arg, sel, n, gids, sums, counts)) {
                return; // exact: no sum wrapped
            }
            long[] x = arg.longs;
            boolean nul = arg.hasNulls;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (nul && arg.nulls[i]) {
                    continue;
                }
                int g = gids[i];
                long v = x[i];
                counts[g]++;
                if (big != null && big[g] != null) {
                    big[g] = big[g].add(BigInteger.valueOf(v));
                    continue;
                }
                long s = sums[g];
                long r = s + v;
                if (((s ^ r) & (v ^ r)) < 0) {
                    addSlow(g, v);
                } else {
                    sums[g] = r;
                }
            }
        }

        @Override
        void updateSingle(Vec arg, int[] sel, int n, int[] zeros) {
            if (nat != null && (big == null || big[0] == null) && nat.sum(arg, sel, n)) {
                addExact(nat.sum, nat.valid);
                return;
            }
            if (arg.hasNulls) {
                update(arg, sel, n, zeros);
                return;
            }
            // Exact sum as high and low 32-bit halves: two overflow-free reductions (|n| < 2^31).
            long[] x = arg.longs;
            long lo = 0;
            long hi = 0;
            if (sel == null) {
                for (int i = 0; i < n; i++) {
                    long v = x[i];
                    lo += v & 0xFFFFFFFFL;
                    hi += v >> 32;
                }
            } else {
                for (int k = 0; k < n; k++) {
                    long v = x[sel[k]];
                    lo += v & 0xFFFFFFFFL;
                    hi += v >> 32;
                }
            }
            counts[0] += n;
            long hiShifted = hi << 32;
            long total = hiShifted + lo;
            boolean exact = (hiShifted >> 32) == hi && ((hiShifted ^ total) & (lo ^ total)) >= 0;
            if (exact && (big == null || big[0] == null)) {
                long s0 = sums[0];
                long r = s0 + total;
                if (((s0 ^ r) & (total ^ r)) >= 0) {
                    sums[0] = r;
                    return;
                }
            }
            BigInteger add = BigInteger.valueOf(hi).shiftLeft(32).add(BigInteger.valueOf(lo));
            if (big == null) {
                big = new BigInteger[sums.length];
            }
            big[0] = total(0).add(add);
            sums[0] = 0;
        }

        /** Adds the exact sum {@code total} of {@code valid} values to group 0 (widening on overflow). */
        private void addExact(long total, long valid) {
            counts[0] += valid;
            long s0 = sums[0];
            long r = s0 + total;
            if (((s0 ^ r) & (total ^ r)) >= 0) {
                sums[0] = r;
                return;
            }
            if (big == null) {
                big = new BigInteger[sums.length];
            }
            big[0] = BigInteger.valueOf(s0).add(BigInteger.valueOf(total));
            sums[0] = 0;
        }

        /** Exact sum of a group as BigInteger. */
        private BigInteger total(int g) {
            return big != null && big[g] != null ? big[g] : BigInteger.valueOf(sums[g]);
        }

        @Override
        void merge(AggState other, int from, int to) {
            LongSum o = (LongSum) other;
            counts[to] += o.counts[from];
            boolean otherBig = o.big != null && o.big[from] != null;
            if (!otherBig && (big == null || big[to] == null)) {
                long s = sums[to];
                long v = o.sums[from];
                long r = s + v;
                if (((s ^ r) & (v ^ r)) >= 0) {
                    sums[to] = r;
                    return;
                }
            }
            BigInteger t = total(to).add(o.total(from));
            if (big == null) {
                big = new BigInteger[sums.length];
            }
            big[to] = t;
            sums[to] = 0;
        }

        @Override
        Object result(int g) {
            BigInteger b = big != null ? big[g] : null;
            return Accumulator.exactSumResult(average, scale, decimal, b == null ? sums[g] : 0, b, counts[g]);
        }
    }

    /** SUM/AVG of FLOAT64 values. */
    static final class DoubleSum extends AggState {
        private final boolean average;
        private double[] sums = new double[16];
        private long[] counts = new long[16];

        DoubleSum(boolean average) {
            this.average = average;
        }

        @Override
        void grow(int groups) {
            if (sums.length < groups) {
                int n = Math.max(groups, sums.length * 2);
                sums = Arrays.copyOf(sums, n);
                counts = Arrays.copyOf(counts, n);
            }
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            double[] x = arg.doubles;
            boolean nul = arg.hasNulls;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (nul && arg.nulls[i]) {
                    continue;
                }
                int g = gids[i];
                sums[g] += x[i];
                counts[g]++;
            }
        }

        @Override
        void updateSingle(Vec arg, int[] sel, int n, int[] zeros) {
            if (arg.hasNulls) {
                update(arg, sel, n, zeros);
                return;
            }
            double[] x = arg.doubles;
            double sum = sums[0];
            for (int k = 0; k < n; k++) {
                sum += x[sel == null ? k : sel[k]];
            }
            sums[0] = sum;
            counts[0] += n;
        }

        @Override
        void merge(AggState other, int from, int to) {
            DoubleSum o = (DoubleSum) other;
            sums[to] += o.sums[from];
            counts[to] += o.counts[from];
        }

        @Override
        Object result(int g) {
            return Accumulator.floatSumResult(average, sums[g], counts[g]);
        }
    }

    /** Exact SUM/AVG of wide DECIMAL values (BigInteger unscaled values; never passed to native kernels). */
    static final class WideSum extends AggState {
        private final boolean average;
        private final int scale;
        private final DataType decimal;
        private BigInteger[] sums = new BigInteger[16];
        private long[] counts = new long[16];

        /** @param decimal the result type of a SUM, null for AVG */
        WideSum(boolean average, int scale, DataType decimal) {
            this.average = average;
            this.scale = scale;
            this.decimal = decimal;
        }

        @Override
        void grow(int groups) {
            if (sums.length < groups) {
                int n = Math.max(groups, sums.length * 2);
                sums = Arrays.copyOf(sums, n);
                counts = Arrays.copyOf(counts, n);
            }
        }

        private void add(int g, BigInteger v) {
            BigInteger s = sums[g];
            sums[g] = s == null ? v : s.add(v);
            counts[g]++;
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            Object[] x = arg.objects;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!arg.isNull(i)) {
                    add(gids[i], (BigInteger) x[i]);
                }
            }
        }

        @Override
        void merge(AggState other, int from, int to) {
            WideSum o = (WideSum) other;
            if (o.counts[from] > 0) {
                BigInteger s = sums[to];
                sums[to] = s == null ? o.sums[from] : s.add(o.sums[from]);
                counts[to] += o.counts[from];
            }
        }

        @Override
        Object result(int g) {
            return Accumulator.exactSumResult(average, scale, decimal, 0, sums[g], counts[g]);
        }
    }

    /** MIN/MAX of LONG-represented values (INT64, DECIMAL, DATE, TIMESTAMP, BOOLEAN). */
    static final class LongMinMax extends AggState {
        private final DataType type;
        private final boolean min;
        private final NativeAgg nat;
        private long[] best = new long[16];
        private boolean[] has = new boolean[16];

        LongMinMax(DataType type, boolean min, NativeAgg nat) {
            this.type = type;
            this.min = min;
            this.nat = nat;
        }

        @Override
        void grow(int groups) {
            if (best.length < groups) {
                int n = Math.max(groups, best.length * 2);
                best = Arrays.copyOf(best, n);
                has = Arrays.copyOf(has, n);
            }
        }

        private void offer(int g, long v) {
            if (!has[g]) {
                has[g] = true;
                best[g] = v;
            } else if (min ? v < best[g] : v > best[g]) {
                best[g] = v;
            }
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            long[] x = arg.longs;
            boolean nul = arg.hasNulls;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!(nul && arg.nulls[i])) {
                    offer(gids[i], x[i]);
                }
            }
        }

        @Override
        void updateSingle(Vec arg, int[] sel, int n, int[] zeros) {
            if (nat != null && n > 0 && nat.minMax(arg, sel, n)) {
                if (nat.valid > 0) {
                    offer(0, min ? nat.min : nat.max);
                }
                return;
            }
            if (arg.hasNulls || n == 0) {
                update(arg, sel, n, zeros);
                return;
            }
            long[] x = arg.longs;
            long b = min ? Long.MAX_VALUE : Long.MIN_VALUE;
            if (sel == null) {
                if (min) {
                    for (int i = 0; i < n; i++) {
                        b = Math.min(b, x[i]);
                    }
                } else {
                    for (int i = 0; i < n; i++) {
                        b = Math.max(b, x[i]);
                    }
                }
            } else {
                for (int k = 0; k < n; k++) {
                    b = min ? Math.min(b, x[sel[k]]) : Math.max(b, x[sel[k]]);
                }
            }
            offer(0, b);
        }

        @Override
        void merge(AggState other, int from, int to) {
            LongMinMax o = (LongMinMax) other;
            if (o.has[from]) {
                offer(to, o.best[from]);
            }
        }

        @Override
        Object result(int g) {
            if (!has[g]) {
                return null;
            }
            long v = best[g];
            return switch (type.kind()) {
                case BOOLEAN -> v != 0;
                case DATE -> (int) v;
                default -> v;
            };
        }
    }

    static final class DoubleMinMax extends AggState {
        private final boolean min;
        private final NativeAgg nat;
        private double[] best = new double[16];
        private boolean[] has = new boolean[16];

        DoubleMinMax(boolean min, NativeAgg nat) {
            this.min = min;
            this.nat = nat;
        }

        @Override
        void grow(int groups) {
            if (best.length < groups) {
                int n = Math.max(groups, best.length * 2);
                best = Arrays.copyOf(best, n);
                has = Arrays.copyOf(has, n);
            }
        }

        private void offer(int g, double v) {
            if (!has[g]) {
                has[g] = true;
                best[g] = v;
            } else if (min ? v < best[g] : v > best[g]) {
                best[g] = v;
            }
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            double[] x = arg.doubles;
            boolean nul = arg.hasNulls;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!(nul && arg.nulls[i])) {
                    offer(gids[i], x[i]);
                }
            }
        }

        @Override
        void updateSingle(Vec arg, int[] sel, int n, int[] zeros) {
            if (nat != null && n > 0 && nat.minMaxDouble(arg, sel, n)) {
                double v = min ? nat.minDouble : nat.maxDouble;
                if (nat.valid == 0) {
                    return;
                }
                if (v != 0.0) { // for ±0.0, the engine keeps the zero it meets first
                    offer(0, v);
                    return;
                }
            }
            update(arg, sel, n, zeros);
        }

        @Override
        void merge(AggState other, int from, int to) {
            DoubleMinMax o = (DoubleMinMax) other;
            if (o.has[from]) {
                offer(to, o.best[from]);
            }
        }

        @Override
        Object result(int g) {
            return has[g] ? best[g] : null;
        }
    }

    /** MIN/MAX of STRING and wide DECIMAL values (object representation). */
    static final class ObjectMinMax extends AggState {
        private final DataType type;
        private final boolean min;
        private Object[] best = new Object[16];

        ObjectMinMax(DataType type, boolean min) {
            this.type = type;
            this.min = min;
        }

        @Override
        void grow(int groups) {
            if (best.length < groups) {
                best = Arrays.copyOf(best, Math.max(groups, best.length * 2));
            }
        }

        private void offer(int g, Object v) {
            Object b = best[g];
            if (b == null) {
                best[g] = v;
            } else if (v != b) {
                int c = Values.compare(v, b, type);
                if (min ? c < 0 : c > 0) {
                    best[g] = v;
                }
            }
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            boolean dict = arg.kind == Vec.Kind.DICT;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!arg.isNull(i)) {
                    Object v = dict ? arg.dict[arg.codes[i]] : arg.objects[i];
                    if (v != null) {
                        offer(gids[i], v);
                    }
                }
            }
        }

        @Override
        void merge(AggState other, int from, int to) {
            Object v = ((ObjectMinMax) other).best[from];
            if (v != null) {
                offer(to, v);
            }
        }

        @Override
        Object result(int g) {
            return best[g];
        }
    }

    /**
     * A DISTINCT aggregate over INT64-like, FLOAT64 or STRING values: every (group, value) pair
     * is passed on to the plain state of the function once, in order of first appearance (as
     * the row engine's distinct accumulator does). Values are encoded as longs (FLOAT64 by their
     * bits with -0.0 = 0.0, strings by an interned id) and the pairs seen are kept in a primitive
     * hash set, plus a list in insertion order so partial states of parallel workers can be merged.
     */
    static final class Distinct extends AggState {
        private final AggState inner;
        private final DataType type;
        private final Vec.Kind kind;
        private final PairSet seen = new PairSet();
        /** Pairs in insertion order: group and raw value (FLOAT64: raw bits; STRING: interned id). */
        private int[] pairGroup = new int[16];
        private long[] pairValue = new long[16];
        private int pairs;
        // STRING interning, with a code -> id cache per dictionary
        private final java.util.Map<Object, Integer> ids;
        private final java.util.List<Object> strings;
        private String[] seenDict;
        private int[] dictIds;
        private int[] fresh = new int[0];
        // merge support: pairs of each group (built by prepareMerge), scratch vectors
        private int[] groupStart;
        private int[] byGroup;
        private Vec scratch;
        private int[] scratchGids = new int[0];

        Distinct(AggState inner, DataType type) {
            this.inner = inner;
            this.type = type;
            this.kind = Vec.kindOf(type);
            boolean str = kind == Vec.Kind.OBJECT;
            this.ids = str ? new java.util.HashMap<>() : null;
            this.strings = str ? new java.util.ArrayList<>() : null;
        }

        @Override
        void grow(int groups) {
            inner.grow(groups);
        }

        private int intern(Object v) {
            Integer id = ids.get(v);
            if (id == null) {
                id = strings.size();
                ids.put(v, id);
                strings.add(v);
            }
            return id;
        }

        private long raw(Vec arg, int i) {
            return switch (arg.kind) {
                case LONG -> arg.longs[i];
                case DOUBLE -> Double.doubleToRawLongBits(arg.doubles[i]);
                case DICT -> {
                    if (seenDict != arg.dict) {
                        seenDict = arg.dict;
                        dictIds = new int[arg.dict.length];
                        Arrays.fill(dictIds, -1);
                    }
                    int c = arg.codes[i];
                    int id = dictIds[c];
                    if (id < 0) {
                        id = intern(arg.dict[c]);
                        dictIds[c] = id;
                    }
                    yield id;
                }
                case OBJECT -> intern(arg.objects[i]);
            };
        }

        /** The set key of a raw value: FLOAT64 values compare by value (-0.0 = 0.0, NaN = NaN). */
        private long key(long raw) {
            if (kind == Vec.Kind.DOUBLE) {
                double d = Double.longBitsToDouble(raw);
                return Double.doubleToLongBits(d == 0.0 ? 0.0 : d);
            }
            return raw;
        }

        private boolean add(int g, long raw) {
            if (!seen.add(g, key(raw))) {
                return false;
            }
            if (pairs == pairGroup.length) {
                pairGroup = Arrays.copyOf(pairGroup, pairs * 2);
                pairValue = Arrays.copyOf(pairValue, pairs * 2);
            }
            pairGroup[pairs] = g;
            pairValue[pairs] = raw;
            pairs++;
            return true;
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            if (fresh.length < n) {
                fresh = new int[Math.max(n, 16)];
            }
            int m = 0;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!arg.isNull(i) && add(gids[i], raw(arg, i))) {
                    fresh[m++] = i;
                }
            }
            if (m > 0) {
                inner.update(arg, fresh, m, gids);
            }
        }

        @Override
        void prepareMerge() {
            int groups = 0;
            for (int p = 0; p < pairs; p++) {
                groups = Math.max(groups, pairGroup[p] + 1);
            }
            groupStart = new int[groups + 1];
            for (int p = 0; p < pairs; p++) {
                groupStart[pairGroup[p] + 1]++;
            }
            for (int g = 0; g < groups; g++) {
                groupStart[g + 1] += groupStart[g];
            }
            int[] fill = Arrays.copyOf(groupStart, groups);
            byGroup = new int[pairs];
            for (int p = 0; p < pairs; p++) {
                byGroup[fill[pairGroup[p]]++] = p;
            }
        }

        @Override
        void merge(AggState other, int from, int to) {
            Distinct o = (Distinct) other;
            if (o.groupStart == null || from + 1 >= o.groupStart.length) {
                return; // no values in that group
            }
            int start = o.groupStart[from];
            int end = o.groupStart[from + 1];
            if (start == end) {
                return;
            }
            int cap = end - start;
            if (scratch == null || scratchGids.length < cap) {
                scratch = new Vec(type, Math.max(cap, 16));
                scratchGids = new int[Math.max(cap, 16)];
            }
            int m = 0;
            for (int q = start; q < end; q++) {
                long raw = o.pairValue[o.byGroup[q]];
                Object str = null;
                if (kind == Vec.Kind.OBJECT) {
                    str = o.strings.get((int) raw);
                    raw = intern(str);
                }
                if (add(to, raw)) {
                    switch (kind) {
                        case LONG -> scratch.longs[m] = raw;
                        case DOUBLE -> scratch.doubles[m] = Double.longBitsToDouble(raw);
                        default -> scratch.objects[m] = str;
                    }
                    scratchGids[m] = to;
                    m++;
                }
            }
            if (m > 0) {
                scratch.hasNulls = false;
                inner.update(scratch, null, m, scratchGids);
            }
        }

        @Override
        Object result(int g) {
            return inner.result(g);
        }
    }

    /** A hash set of (group id, long value) pairs: open addressing with linear probing. */
    static final class PairSet {
        private int[] groups = new int[64];
        private long[] values = new long[64];
        private int mask = 63;
        private int size;

        PairSet() {
            Arrays.fill(groups, -1);
        }

        private static int slot(int g, long v, int mask) {
            long h = (v ^ ((long) g << 32 | g)) * 0x9E3779B97F4A7C15L;
            return (int) (h ^ (h >>> 29)) & mask;
        }

        /** Adds the pair; true if it was not present. */
        boolean add(int g, long v) {
            int s = slot(g, v, mask);
            while (true) {
                int x = groups[s];
                if (x < 0) {
                    groups[s] = g;
                    values[s] = v;
                    if (++size * 2 > groups.length) {
                        rehash();
                    }
                    return true;
                }
                if (x == g && values[s] == v) {
                    return false;
                }
                s = (s + 1) & mask;
            }
        }

        private void rehash() {
            int[] og = groups;
            long[] ov = values;
            int cap = og.length * 2;
            groups = new int[cap];
            values = new long[cap];
            Arrays.fill(groups, -1);
            mask = cap - 1;
            for (int i = 0; i < og.length; i++) {
                if (og[i] >= 0) {
                    int s = slot(og[i], ov[i], mask);
                    while (groups[s] >= 0) {
                        s = (s + 1) & mask;
                    }
                    groups[s] = og[i];
                    values[s] = ov[i];
                }
            }
        }
    }

    /** Any aggregate (notably DISTINCT ones) through the row engine's accumulators, one per group. */
    static final class Generic extends AggState {
        private static final Object PRESENT = Boolean.TRUE;
        private final AggregateCall call;
        private Accumulator[] accs = new Accumulator[16];

        Generic(AggregateCall call) {
            this.call = call;
        }

        @Override
        void grow(int groups) {
            if (accs.length < groups) {
                accs = Arrays.copyOf(accs, Math.max(groups, accs.length * 2));
            }
        }

        private Accumulator acc(int g) {
            Accumulator a = accs[g];
            if (a == null) {
                a = Accumulator.create(call);
                accs[g] = a;
            }
            return a;
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                acc(gids[i]).add(arg == null ? PRESENT : arg.get(i));
            }
        }

        @Override
        boolean mergeable() {
            return false;
        }

        @Override
        void merge(AggState other, int from, int to) {
            throw new UnsupportedOperationException("DISTINCT aggregates are not merged");
        }

        @Override
        Object result(int g) {
            return acc(g).result();
        }
    }
}
