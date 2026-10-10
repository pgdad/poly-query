package polyquery.exec.vector;

import java.math.BigInteger;
import java.util.Arrays;
import polyquery.exec.Accumulator;
import polyquery.plan.AggregateCall;
import polyquery.types.DataType;
import polyquery.types.TypeKind;
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

    /** Adds the state of {@code other}'s group {@code from} to group {@code to}. */
    abstract void merge(AggState other, int from, int to);

    /** Final value of group g (boxed runtime value; may raise NUMERIC_OVERFLOW). */
    abstract Object result(int g);

    /** False if partial states cannot be merged (DISTINCT aggregates). */
    boolean mergeable() {
        return true;
    }

    static AggState create(AggregateCall call) {
        if (call.distinct()) {
            return new Generic(call);
        }
        DataType in = call.argument() == null ? null : call.argument().type();
        return switch (call.function()) {
            case COUNT_STAR -> new Count(false);
            case COUNT -> new Count(true);
            case SUM, AVG -> {
                boolean avg = call.function() == AggregateCall.AggregateFunction.AVG;
                yield switch (in.kind()) {
                    case FLOAT64 -> new DoubleSum(avg);
                    case DECIMAL -> new LongSum(avg, in.scale(), true);
                    case INT64 -> new LongSum(avg, 0, false);
                    default -> new Generic(call);
                };
            }
            case MIN, MAX -> {
                boolean min = call.function() == AggregateCall.AggregateFunction.MIN;
                yield switch (Vec.kindOf(in)) {
                    case LONG -> in.isNull() ? new Generic(call) : new LongMinMax(in, min);
                    case DOUBLE -> new DoubleMinMax(min);
                    default -> in.isNull() ? new Generic(call) : new StringMinMax(min);
                };
            }
        };
    }

    /** COUNT(*) ({@code nonNull == false}) or COUNT(x). */
    static final class Count extends AggState {
        private final boolean nonNull;
        private long[] counts = new long[16];

        Count(boolean nonNull) {
            this.nonNull = nonNull;
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
        private final boolean decimal;
        private long[] sums = new long[16];
        private long[] counts = new long[16];
        private BigInteger[] big;

        LongSum(boolean average, int scale, boolean decimal) {
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

    /** MIN/MAX of LONG-represented values (INT64, DECIMAL, DATE, TIMESTAMP, BOOLEAN). */
    static final class LongMinMax extends AggState {
        private final DataType type;
        private final boolean min;
        private long[] best = new long[16];
        private boolean[] has = new boolean[16];

        LongMinMax(DataType type, boolean min) {
            this.type = type;
            this.min = min;
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
        private double[] best = new double[16];
        private boolean[] has = new boolean[16];

        DoubleMinMax(boolean min) {
            this.min = min;
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

    static final class StringMinMax extends AggState {
        private final boolean min;
        private String[] best = new String[16];

        StringMinMax(boolean min) {
            this.min = min;
        }

        @Override
        void grow(int groups) {
            if (best.length < groups) {
                best = Arrays.copyOf(best, Math.max(groups, best.length * 2));
            }
        }

        private void offer(int g, String v) {
            String b = best[g];
            if (b == null) {
                best[g] = v;
            } else if (v != b) {
                int c = Values.compareStrings(v, b);
                if (min ? c < 0 : c > 0) {
                    best[g] = v;
                }
            }
        }

        @Override
        void update(Vec arg, int[] sel, int n, int[] gids) {
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!arg.isNull(i)) {
                    String s = arg.string(i);
                    if (s != null) {
                        offer(gids[i], s);
                    }
                }
            }
        }

        @Override
        void merge(AggState other, int from, int to) {
            String v = ((StringMinMax) other).best[from];
            if (v != null) {
                offer(to, v);
            }
        }

        @Override
        Object result(int g) {
            return best[g];
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

    static boolean isNullType(DataType t) {
        return t != null && t.kind() == TypeKind.NULL;
    }
}
