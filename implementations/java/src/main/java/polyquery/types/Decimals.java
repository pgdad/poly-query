package polyquery.types;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * Exact fixed-point arithmetic. Narrow DECIMALs (precision ≤ 18) use unscaled {@code long}
 * values with 64-bit fast paths, falling back to {@link BigInteger} intermediates whenever 64
 * bits are not enough; wide DECIMALs (precision 19–38) use unscaled {@link BigInteger} values.
 * The generic methods taking {@code Object} operands accept either representation (and INT64
 * {@code Long}s, which are unscaled values of scale 0).
 */
public final class Decimals {
    public static final long MAX_UNSCALED = 999_999_999_999_999_999L;
    private static final long[] POW10 = new long[19];
    private static final BigInteger BIG_MAX = BigInteger.valueOf(MAX_UNSCALED);
    /** 10^0 … 10^77: enough to rescale any wide value and to bound products of two of them. */
    private static final BigInteger[] BIG_POW10 = new BigInteger[78];

    static {
        POW10[0] = 1;
        for (int i = 1; i < POW10.length; i++) {
            POW10[i] = POW10[i - 1] * 10;
        }
        BIG_POW10[0] = BigInteger.ONE;
        for (int i = 1; i < BIG_POW10.length; i++) {
            BIG_POW10[i] = BIG_POW10[i - 1].multiply(BigInteger.TEN);
        }
    }

    private Decimals() {
    }

    public static long pow10(int n) {
        return POW10[n];
    }

    /** 10^n as a BigInteger (0 ≤ n ≤ 77). */
    public static BigInteger bigPow10(int n) {
        return n < BIG_POW10.length ? BIG_POW10[n] : BigInteger.TEN.pow(n);
    }

    /** True if {@code |unscaled| < 10^precision}. */
    public static boolean fitsPrecision(long unscaled, int precision) {
        if (unscaled == Long.MIN_VALUE) {
            return false;
        }
        return Math.abs(unscaled) < (precision >= 19 ? Long.MAX_VALUE : POW10[precision]);
    }

    public static PolyQueryException overflow() {
        return new PolyQueryException(ErrorCode.NUMERIC_OVERFLOW, "decimal value out of range");
    }

    /** Checks the 18-digit limit of any DECIMAL result. */
    public static long check18(long v) {
        if (v > MAX_UNSCALED || v < -MAX_UNSCALED) {
            throw overflow();
        }
        return v;
    }

    public static long check18(BigInteger v) {
        if (v.abs().compareTo(BIG_MAX) > 0) {
            throw overflow();
        }
        return v.longValue();
    }

    /** Multiplies by 10^n exactly (n ≥ 0), result limited to 18 digits. */
    public static long upscale(long v, int n) {
        if (n == 0) {
            return check18(v);
        }
        if (n > 18) {
            if (v == 0) {
                return 0;
            }
            throw overflow();
        }
        try {
            return check18(Math.multiplyExact(v, POW10[n]));
        } catch (ArithmeticException e) {
            throw overflow();
        }
    }

    /** Rescales between scales, rounding half away from zero when reducing scale. */
    public static long rescale(long v, int fromScale, int toScale) {
        if (toScale >= fromScale) {
            return upscale(v, toScale - fromScale);
        }
        int d = fromScale - toScale;
        long div = POW10[d];
        long q = v / div;
        long r = v % div;
        if (Math.abs(r) * 2 >= div) {
            q += v < 0 ? -1 : 1;
        }
        return check18(q);
    }

    /** Truncates toward zero to an integer. */
    public static long truncateToInteger(long v, int scale) {
        return v / POW10[scale];
    }

    public static long add(long a, int sa, long b, int sb, int resultScale) {
        try {
            long x = Math.multiplyExact(a, POW10[resultScale - sa]);
            long y = Math.multiplyExact(b, POW10[resultScale - sb]);
            return check18(Math.addExact(x, y));
        } catch (ArithmeticException e) {
            return check18(big(a, resultScale - sa).add(big(b, resultScale - sb)));
        }
    }

    public static long subtract(long a, int sa, long b, int sb, int resultScale) {
        try {
            long x = Math.multiplyExact(a, POW10[resultScale - sa]);
            long y = Math.multiplyExact(b, POW10[resultScale - sb]);
            return check18(Math.subtractExact(x, y));
        } catch (ArithmeticException e) {
            return check18(big(a, resultScale - sa).subtract(big(b, resultScale - sb)));
        }
    }

    /** Product of unscaled values; the result scale is the sum of the operand scales. */
    public static long multiply(long a, long b) {
        try {
            return check18(Math.multiplyExact(a, b));
        } catch (ArithmeticException e) {
            throw overflow();
        }
    }

    private static BigInteger big(long v, int upscale) {
        return BigInteger.valueOf(v).multiply(BigInteger.TEN.pow(upscale));
    }

    public static int compare(long a, int sa, long b, int sb) {
        if (sa == sb) {
            return Long.compare(a, b);
        }
        int s = Math.max(sa, sb);
        try {
            long x = Math.multiplyExact(a, POW10[s - sa]);
            long y = Math.multiplyExact(b, POW10[s - sb]);
            return Long.compare(x, y);
        } catch (ArithmeticException e) {
            return big(a, s - sa).compareTo(big(b, s - sb));
        }
    }

    public static double toDouble(long unscaled, int scale) {
        if (scale == 0) {
            return (double) unscaled;
        }
        if (Math.abs(unscaled) < (1L << 53)) {
            return unscaled / (double) POW10[scale];
        }
        return BigDecimal.valueOf(unscaled, scale).doubleValue();
    }

    /**
     * Unscaled value of a finite double at the given scale: the exact binary value of the double,
     * rounded half away from zero (no precision check).
     */
    public static BigInteger fromDouble(double d, int scale) {
        return new BigDecimal(d).setScale(scale, RoundingMode.HALF_UP).unscaledValue();
    }

    /** Canonical text: exactly {@code scale} fractional digits, leading '-' if negative. */
    public static String toString(long unscaled, int scale) {
        if (scale == 0) {
            return Long.toString(unscaled);
        }
        StringBuilder sb = new StringBuilder(24);
        String digits;
        if (unscaled < 0) {
            sb.append('-');
            digits = unscaled == Long.MIN_VALUE ? "9223372036854775808" : Long.toString(-unscaled);
        } else {
            digits = Long.toString(unscaled);
        }
        if (digits.length() <= scale) {
            sb.append("0.");
            sb.repeat('0', scale - digits.length());
            sb.append(digits);
        } else {
            int point = digits.length() - scale;
            sb.append(digits, 0, point).append('.').append(digits, point, digits.length());
        }
        return sb.toString();
    }

    // ---------------------------------------------------------------- representation-generic (narrow and wide)

    /** Unscaled value of a DECIMAL runtime value (or an INT64) as a BigInteger. */
    public static BigInteger toBig(Object v) {
        return v instanceof BigInteger b ? b : BigInteger.valueOf((Long) v);
    }

    /** True if {@code |unscaled| < 10^precision}. */
    public static boolean fitsPrecision(BigInteger unscaled, int precision) {
        return unscaled.abs().compareTo(bigPow10(precision)) < 0;
    }

    /**
     * The runtime value of the exact unscaled result {@code u} of DECIMAL type {@code type}
     * ({@code Long} if narrow, {@code BigInteger} if wide); NUMERIC_OVERFLOW unless
     * {@code |u| < 10^precision}.
     */
    public static Object value(BigInteger u, DataType type) {
        if (!fitsPrecision(u, type.precision())) {
            throw overflow();
        }
        return type.isWideDecimal() ? u : (Object) u.longValue();
    }

    /** Exact sum {@code a + b} of two values at scales {@code sa}, {@code sb}, at scale {@code rs}. */
    public static BigInteger addExact(Object a, int sa, Object b, int sb, int rs) {
        return upscale(toBig(a), rs - sa).add(upscale(toBig(b), rs - sb));
    }

    /** Exact difference {@code a - b}, at scale {@code rs}. */
    public static BigInteger subtractExact(Object a, int sa, Object b, int sb, int rs) {
        return upscale(toBig(a), rs - sa).subtract(upscale(toBig(b), rs - sb));
    }

    /** Exact product of unscaled values (scale = sum of the operand scales). */
    public static BigInteger multiplyExact(Object a, Object b) {
        return toBig(a).multiply(toBig(b));
    }

    /** {@code v · 10^n} (n ≥ 0). */
    public static BigInteger upscale(BigInteger v, int n) {
        return n == 0 ? v : v.multiply(bigPow10(n));
    }

    /** Rescales between scales, rounding half away from zero when reducing scale (no precision check). */
    public static BigInteger rescale(BigInteger v, int fromScale, int toScale) {
        if (toScale >= fromScale) {
            return upscale(v, toScale - fromScale);
        }
        return new BigDecimal(v, fromScale).setScale(toScale, RoundingMode.HALF_UP).unscaledValue();
    }

    /**
     * Exact comparison of two exact numbers given as unscaled values and scales (any mix of
     * narrow {@code Long}s, INT64 {@code Long}s of scale 0 and wide {@code BigInteger}s).
     */
    public static int compare(Object a, int sa, Object b, int sb) {
        if (a instanceof Long x && b instanceof Long y) {
            return compare((long) x, sa, (long) y, sb);
        }
        BigInteger x = toBig(a);
        BigInteger y = toBig(b);
        if (sa < sb) {
            x = upscale(x, sb - sa);
        } else if (sb < sa) {
            y = upscale(y, sa - sb);
        }
        return x.compareTo(y);
    }

    /** Truncates toward zero to an integer (exact, any size). */
    public static BigInteger truncateToInteger(BigInteger v, int scale) {
        return scale == 0 ? v : v.divide(bigPow10(scale));
    }

    /** Nearest double of {@code unscaled / 10^scale}. */
    public static double toDouble(BigInteger unscaled, int scale) {
        if (unscaled.bitLength() < 63) {
            return toDouble(unscaled.longValue(), scale);
        }
        return new BigDecimal(unscaled, scale).doubleValue();
    }

    /** Canonical text of a wide value: exactly {@code scale} fractional digits, leading '-' if negative. */
    public static String toString(BigInteger unscaled, int scale) {
        if (unscaled.bitLength() < 64) {
            return toString(unscaled.longValue(), scale);
        }
        String digits = unscaled.abs().toString();
        StringBuilder sb = new StringBuilder(digits.length() + 3);
        if (unscaled.signum() < 0) {
            sb.append('-');
        }
        if (scale == 0) {
            return sb.append(digits).toString();
        }
        if (digits.length() <= scale) {
            sb.append("0.");
            sb.repeat('0', scale - digits.length());
            sb.append(digits);
        } else {
            int point = digits.length() - scale;
            sb.append(digits, 0, point).append('.').append(digits, point, digits.length());
        }
        return sb.toString();
    }

    /** Canonical text of a DECIMAL runtime value of either representation. */
    public static String toString(Object unscaled, int scale) {
        return unscaled instanceof BigInteger b ? toString(b, scale) : toString((long) (Long) unscaled, scale);
    }
}
