package polyquery.types;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * Exact fixed-point arithmetic on unscaled {@code long} values (at most 18 digits).
 * Intermediates fall back to {@link BigInteger} whenever 64 bits are not enough.
 */
public final class Decimals {
    public static final long MAX_UNSCALED = 999_999_999_999_999_999L;
    private static final long[] POW10 = new long[19];
    private static final BigInteger BIG_MAX = BigInteger.valueOf(MAX_UNSCALED);

    static {
        POW10[0] = 1;
        for (int i = 1; i < POW10.length; i++) {
            POW10[i] = POW10[i - 1] * 10;
        }
    }

    private Decimals() {
    }

    public static long pow10(int n) {
        return POW10[n];
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

    public static BigDecimal toBigDecimal(long unscaled, int scale) {
        return BigDecimal.valueOf(unscaled, scale);
    }

    /** Converts a finite double, rounding half away from zero, to the given precision/scale. */
    public static long fromDouble(double d, int precision, int scale) {
        BigDecimal bd = new BigDecimal(Double.toString(d)).setScale(scale, RoundingMode.HALF_UP);
        BigInteger u = bd.unscaledValue();
        if (u.bitLength() > 63) {
            throw overflow();
        }
        long v = u.longValue();
        if (!fitsPrecision(v, precision)) {
            throw overflow();
        }
        return v;
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
}
