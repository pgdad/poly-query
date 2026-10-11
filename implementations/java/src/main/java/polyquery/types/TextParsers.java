package polyquery.types;

import polyquery.common.Names;
import java.math.BigInteger;

/**
 * Strict text → value parsers shared by CAST and ingestion. Each parser returns {@code null}
 * when the text is syntactically invalid and throws {@link ArithmeticException} when the
 * syntax is valid but the value does not fit the target type.
 */
public final class TextParsers {
    private static final BigInteger LONG_MIN = BigInteger.valueOf(Long.MIN_VALUE);
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);

    private TextParsers() {
    }

    private static boolean isDigit(char c) {
        return c >= '0' && c <= '9';
    }

    /** Trims ASCII spaces and tabs. */
    public static String trimSpaceTab(String s) {
        int b = 0;
        int e = s.length();
        while (b < e && (s.charAt(b) == ' ' || s.charAt(b) == '\t')) {
            b++;
        }
        while (e > b && (s.charAt(e - 1) == ' ' || s.charAt(e - 1) == '\t')) {
            e--;
        }
        return b == 0 && e == s.length() ? s : s.substring(b, e);
    }

    public static Boolean parseBoolean(String s) {
        if (Names.equal(s, "true")) {
            return Boolean.TRUE;
        }
        if (Names.equal(s, "false")) {
            return Boolean.FALSE;
        }
        return null;
    }

    /** {@code ^[+-]?[0-9]+$} within INT64 range. */
    public static Long parseInt64(String s) {
        int n = s.length();
        int i = 0;
        if (n > 0 && (s.charAt(0) == '+' || s.charAt(0) == '-')) {
            i = 1;
        }
        if (i == n) {
            return null;
        }
        for (int j = i; j < n; j++) {
            if (!isDigit(s.charAt(j))) {
                return null;
            }
        }
        if (n - i <= 18) {
            return Long.parseLong(s.charAt(0) == '+' ? s.substring(1) : s);
        }
        BigInteger v = new BigInteger(s.charAt(0) == '+' ? s.substring(1) : s);
        if (v.compareTo(LONG_MIN) < 0 || v.compareTo(LONG_MAX) > 0) {
            throw new ArithmeticException("integer out of range");
        }
        return v.longValue();
    }

    /** {@code ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$}, finite. */
    public static Double parseFloat64(String s) {
        if (!isFloatSyntax(s)) {
            return null;
        }
        double d = Double.parseDouble(s);
        if (Double.isInfinite(d) || Double.isNaN(d)) {
            throw new ArithmeticException("float out of range");
        }
        return d;
    }

    public static boolean isFloatSyntax(String s) {
        int n = s.length();
        int i = 0;
        if (i < n && (s.charAt(i) == '+' || s.charAt(i) == '-')) {
            i++;
        }
        int intDigits = 0;
        while (i < n && isDigit(s.charAt(i))) {
            i++;
            intDigits++;
        }
        int fracDigits = 0;
        if (i < n && s.charAt(i) == '.') {
            i++;
            while (i < n && isDigit(s.charAt(i))) {
                i++;
                fracDigits++;
            }
        }
        if (intDigits == 0 && fracDigits == 0) {
            return false;
        }
        if (i < n && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
            i++;
            if (i < n && (s.charAt(i) == '+' || s.charAt(i) == '-')) {
                i++;
            }
            int expDigits = 0;
            while (i < n && isDigit(s.charAt(i))) {
                i++;
                expDigits++;
            }
            if (expDigits == 0) {
                return false;
            }
        }
        return i == n;
    }

    /**
     * Parses {@code ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$} into an unscaled value of the given
     * scale. With {@code round}, extra fractional digits are rounded half away from zero;
     * without it they make the value invalid (ArithmeticException). The value must fit
     * {@code precision} digits. Returns the runtime value: a {@code Long} for a narrow
     * precision (≤ 18), a {@code BigInteger} for a wide one.
     */
    public static Object parseDecimal(String s, int precision, int scale, boolean round) {
        int n = s.length();
        int i = 0;
        boolean neg = false;
        if (i < n && (s.charAt(i) == '+' || s.charAt(i) == '-')) {
            neg = s.charAt(i) == '-';
            i++;
        }
        int intStart = i;
        while (i < n && isDigit(s.charAt(i))) {
            i++;
        }
        int intEnd = i;
        int fracStart = i;
        int fracEnd = i;
        if (i < n && s.charAt(i) == '.') {
            i++;
            fracStart = i;
            while (i < n && isDigit(s.charAt(i))) {
                i++;
            }
            fracEnd = i;
        }
        if (i != n || (intEnd == intStart && fracEnd == fracStart)) {
            return null;
        }
        String intPart = s.substring(intStart, intEnd);
        String fracPart = s.substring(fracStart, fracEnd);
        boolean roundUp = false;
        if (fracPart.length() > scale) {
            if (!round) {
                throw new ArithmeticException("too many fractional digits");
            }
            roundUp = fracPart.charAt(scale) >= '5';
            fracPart = fracPart.substring(0, scale);
        }
        StringBuilder digits = new StringBuilder(intPart).append(fracPart);
        digits.repeat('0', scale - fracPart.length());
        BigInteger v = digits.isEmpty() ? BigInteger.ZERO : new BigInteger(digits.toString());
        if (roundUp) {
            v = v.add(BigInteger.ONE);
        }
        if (!Decimals.fitsPrecision(v, precision)) {
            throw new ArithmeticException("decimal out of range");
        }
        if (neg) {
            v = v.negate();
        }
        return precision > DataType.NARROW_DECIMAL_PRECISION ? v : (Object) v.longValue();
    }
}
