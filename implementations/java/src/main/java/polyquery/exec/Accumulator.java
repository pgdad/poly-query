package polyquery.exec;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.MathContext;
import java.util.HashSet;
import java.util.Set;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.AggregateCall;
import polyquery.types.DataType;
import polyquery.types.Decimals;
import polyquery.types.Values;

/** Running state of one aggregate function for one group (functions.md §2). */
public abstract class Accumulator {
    /** Adds one input value (already evaluated; may be null). */
    public abstract void add(Object v);

    public abstract Object result();

    public static Accumulator create(AggregateCall call) {
        Accumulator acc = createPlain(call);
        return call.distinct() ? new Distinct(acc) : acc;
    }

    private static Accumulator createPlain(AggregateCall call) {
        DataType in = call.argument() == null ? null : call.argument().type();
        return switch (call.function()) {
            case COUNT_STAR, COUNT -> new Count();
            case SUM -> switch (in.kind()) {
                case FLOAT64 -> new FloatSum(false);
                case DECIMAL -> new ExactSum(false, in.scale(), call.type());
                default -> new ExactSum(false, 0, null);
            };
            case AVG -> switch (in.kind()) {
                case FLOAT64 -> new FloatSum(true);
                case DECIMAL -> new ExactSum(true, in.scale(), null);
                default -> new ExactSum(true, 0, null);
            };
            case MIN -> new MinMax(in, true);
            case MAX -> new MinMax(in, false);
        };
    }

    private static PolyQueryException overflow() {
        return new PolyQueryException(ErrorCode.NUMERIC_OVERFLOW, "aggregate result out of range");
    }

    /** Feeds only the first occurrence of each distinct non-NULL value to the wrapped accumulator. */
    static final class Distinct extends Accumulator {
        private final Accumulator inner;
        private final Set<Object> seen = new HashSet<>();

        Distinct(Accumulator inner) {
            this.inner = inner;
        }

        @Override
        public void add(Object v) {
            if (v != null && seen.add(HashKeys.normalizeZero(v))) {
                inner.add(v);
            }
        }

        @Override
        public Object result() {
            return inner.result();
        }
    }

    /** COUNT(x); COUNT(*) feeds a non-null marker for every row. */
    static final class Count extends Accumulator {
        private long count;

        @Override
        public void add(Object v) {
            if (v != null) {
                count++;
            }
        }

        @Override
        public Object result() {
            return count;
        }
    }

    /**
     * Exact SUM/AVG over INT64 or unscaled DECIMAL values (narrow or wide), widening to
     * BigInteger on overflow.
     */
    static final class ExactSum extends Accumulator {
        private final boolean average;
        private final int scale;
        private final DataType decimal;
        private long sum;
        private BigInteger big;
        private long count;

        /** @param decimal the DECIMAL result type of a DECIMAL SUM, else null */
        ExactSum(boolean average, int scale, DataType decimal) {
            this.average = average;
            this.scale = scale;
            this.decimal = decimal;
        }

        @Override
        public void add(Object v) {
            if (v == null) {
                return;
            }
            if (v instanceof BigInteger w) {
                count++;
                big = (big != null ? big : BigInteger.valueOf(sum)).add(w);
                return;
            }
            long x = (Long) v;
            count++;
            if (big != null) {
                big = big.add(BigInteger.valueOf(x));
                return;
            }
            long r = sum + x;
            if (((sum ^ r) & (x ^ r)) < 0) {
                big = BigInteger.valueOf(sum).add(BigInteger.valueOf(x));
            } else {
                sum = r;
            }
        }

        @Override
        public Object result() {
            return exactSumResult(average, scale, decimal, sum, big, count);
        }
    }

    /**
     * Final value of an exact SUM/AVG over INT64 or DECIMAL inputs: {@code big} (if non-null)
     * or {@code sum} is the exact total of {@code count} non-null values; {@code decimal} is the
     * result type of a DECIMAL SUM (null for INT64 sums and averages).
     */
    public static Object exactSumResult(boolean average, int scale, DataType decimal, long sum, BigInteger big,
                                        long count) {
        if (count == 0) {
            return null;
        }
        if (average) {
            BigDecimal total = big != null ? new BigDecimal(big, scale) : BigDecimal.valueOf(sum, scale);
            return total.divide(BigDecimal.valueOf(count), MathContext.DECIMAL128).doubleValue();
        }
        if (decimal != null) {
            // DECIMAL: final result limited to W digits (the precision of the result type).
            if (big == null && !decimal.isWideDecimal()) {
                return Decimals.check18(sum);
            }
            return Decimals.value(big != null ? big : BigInteger.valueOf(sum), decimal);
        }
        if (big != null) {
            if (big.bitLength() > 63) {
                throw overflow();
            }
            return big.longValue();
        }
        return sum;
    }

    /** Final value of a FLOAT64 SUM/AVG of {@code count} non-null values. */
    public static Object floatSumResult(boolean average, double sum, long count) {
        if (count == 0) {
            return null;
        }
        double r = average ? sum / count : sum;
        if (Double.isInfinite(r) || Double.isNaN(r)) {
            throw overflow();
        }
        return r;
    }

    static final class FloatSum extends Accumulator {
        private final boolean average;
        private double sum;
        private long count;

        FloatSum(boolean average) {
            this.average = average;
        }

        @Override
        public void add(Object v) {
            if (v != null) {
                sum += (Double) v;
                count++;
            }
        }

        @Override
        public Object result() {
            return floatSumResult(average, sum, count);
        }
    }

    static final class MinMax extends Accumulator {
        private final DataType type;
        private final boolean min;
        private Object best;

        MinMax(DataType type, boolean min) {
            this.type = type;
            this.min = min;
        }

        @Override
        public void add(Object v) {
            if (v == null) {
                return;
            }
            if (best == null) {
                best = v;
                return;
            }
            int c = Values.compare(v, best, type);
            if (min ? c < 0 : c > 0) {
                best = v;
            }
        }

        @Override
        public Object result() {
            return best;
        }
    }
}
