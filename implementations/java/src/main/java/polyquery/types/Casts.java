package polyquery.types;

import java.math.BigInteger;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/** CAST conversion rules (types.md §8). */
public final class Casts {
    private Casts() {
    }

    /** Whether {@code CAST(from AS to)} is a valid conversion (else TYPE_ERROR at validation). */
    public static boolean allowed(DataType from, DataType to) {
        TypeKind f = from.kind();
        TypeKind t = to.kind();
        if (f == TypeKind.NULL || f == t || t == TypeKind.STRING || f == TypeKind.STRING) {
            return true;
        }
        return switch (f) {
            case BOOLEAN -> t == TypeKind.INT64;
            case INT64 -> t == TypeKind.BOOLEAN || t == TypeKind.DECIMAL || t == TypeKind.FLOAT64;
            case DECIMAL, FLOAT64 -> t == TypeKind.INT64 || t == TypeKind.DECIMAL || t == TypeKind.FLOAT64;
            case DATE -> t == TypeKind.TIMESTAMP;
            case TIMESTAMP -> t == TypeKind.DATE;
            default -> false;
        };
    }

    private static PolyQueryException conversion(String text, DataType to) {
        return PolyQueryException.of(ErrorCode.CONVERSION_ERROR, "cannot convert '%s' to %s",
                text.length() > 100 ? text.substring(0, 100) + "..." : text, to);
    }

    private static PolyQueryException overflow(DataType to) {
        return PolyQueryException.of(ErrorCode.NUMERIC_OVERFLOW, "value out of range for %s", to);
    }

    /** Converts a value; {@code null} stays {@code null}. */
    public static Object cast(Object v, DataType from, DataType to) {
        if (v == null) {
            return null;
        }
        TypeKind t = to.kind();
        switch (from.kind()) {
            case BOOLEAN -> {
                boolean b = (Boolean) v;
                return switch (t) {
                    case BOOLEAN -> v;
                    case INT64 -> b ? 1L : 0L;
                    case STRING -> b ? "true" : "false";
                    default -> throw unsupported(from, to);
                };
            }
            case INT64 -> {
                long x = (Long) v;
                return switch (t) {
                    case INT64 -> v;
                    case BOOLEAN -> x != 0;
                    case DECIMAL -> {
                        if (!to.isWideDecimal()) {
                            long u;
                            try {
                                u = to.scale() == 0 ? x : Math.multiplyExact(x, Decimals.pow10(to.scale()));
                            } catch (ArithmeticException e) {
                                throw overflow(to);
                            }
                            if (!Decimals.fitsPrecision(u, to.precision())) {
                                throw overflow(to);
                            }
                            yield u;
                        }
                        yield toDecimal(Decimals.upscale(BigInteger.valueOf(x), to.scale()), to);
                    }
                    case FLOAT64 -> (double) x;
                    case STRING -> Long.toString(x);
                    default -> throw unsupported(from, to);
                };
            }
            case DECIMAL -> {
                int s = from.scale();
                if (from.isWideDecimal()) {
                    BigInteger u = (BigInteger) v;
                    return switch (t) {
                        case DECIMAL -> toDecimal(Decimals.rescale(u, s, to.scale()), to);
                        case INT64 -> {
                            BigInteger i = Decimals.truncateToInteger(u, s);
                            if (i.bitLength() > 63) {
                                throw overflow(to);
                            }
                            yield i.longValue();
                        }
                        case FLOAT64 -> Decimals.toDouble(u, s);
                        case STRING -> Decimals.toString(u, s);
                        default -> throw unsupported(from, to);
                    };
                }
                long u = (Long) v;
                return switch (t) {
                    case DECIMAL -> {
                        if (to.isWideDecimal()) {
                            yield toDecimal(Decimals.rescale(BigInteger.valueOf(u), s, to.scale()), to);
                        }
                        long r;
                        try {
                            r = Decimals.rescale(u, s, to.scale());
                        } catch (PolyQueryException e) {
                            throw overflow(to);
                        }
                        if (!Decimals.fitsPrecision(r, to.precision())) {
                            throw overflow(to);
                        }
                        yield r;
                    }
                    case INT64 -> Decimals.truncateToInteger(u, s);
                    case FLOAT64 -> Decimals.toDouble(u, s);
                    case STRING -> Decimals.toString(u, s);
                    default -> throw unsupported(from, to);
                };
            }
            case FLOAT64 -> {
                double d = (Double) v;
                return switch (t) {
                    case FLOAT64 -> v;
                    case INT64 -> {
                        if (d >= 9.223372036854775807E18 || d < -9.223372036854775808E18) {
                            throw overflow(to);
                        }
                        yield (long) d;
                    }
                    case DECIMAL -> toDecimal(Decimals.fromDouble(d, to.scale()), to);
                    case STRING -> Values.formatDouble(d);
                    default -> throw unsupported(from, to);
                };
            }
            case STRING -> {
                return fromString((String) v, to);
            }
            case DATE -> {
                return switch (t) {
                    case DATE -> v;
                    case TIMESTAMP -> DateTimes.timestampOf((Integer) v);
                    case STRING -> DateTimes.formatDate((Integer) v);
                    default -> throw unsupported(from, to);
                };
            }
            case TIMESTAMP -> {
                return switch (t) {
                    case TIMESTAMP -> v;
                    case DATE -> DateTimes.dateOf((Long) v);
                    case STRING -> DateTimes.formatTimestamp((Long) v);
                    default -> throw unsupported(from, to);
                };
            }
            case NULL -> {
                return null;
            }
            default -> throw unsupported(from, to);
        }
    }

    /** The runtime value of unscaled {@code u} of DECIMAL type {@code to}; NUMERIC_OVERFLOW if it does not fit. */
    private static Object toDecimal(BigInteger u, DataType to) {
        if (!Decimals.fitsPrecision(u, to.precision())) {
            throw overflow(to);
        }
        return to.isWideDecimal() ? u : (Object) u.longValue();
    }

    private static String trimAll(String s) {
        return s.strip();
    }

    private static Object fromString(String text, DataType to) {
        if (to.kind() == TypeKind.STRING) {
            return text;
        }
        String s = trimAll(text);
        try {
            Object r = switch (to.kind()) {
                case BOOLEAN -> TextParsers.parseBoolean(s);
                case INT64 -> TextParsers.parseInt64(s);
                case FLOAT64 -> TextParsers.parseFloat64(s);
                case DECIMAL -> TextParsers.parseDecimal(s, to.precision(), to.scale(), true);
                case DATE -> DateTimes.parseDate(s);
                case TIMESTAMP -> DateTimes.parseTimestamp(s, true);
                default -> null;
            };
            if (r == null) {
                throw conversion(text, to);
            }
            return r;
        } catch (ArithmeticException e) {
            throw overflow(to);
        }
    }

    private static PolyQueryException unsupported(DataType from, DataType to) {
        return PolyQueryException.of(ErrorCode.TYPE_ERROR, "cannot cast %s to %s", from, to);
    }
}
