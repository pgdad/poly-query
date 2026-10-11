package polyquery.exec;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;
import polyquery.types.TypeKind;
import polyquery.types.Values;

/** Runtime implementations of the scalar functions (functions.md §1). */
final class ScalarFunctions {
    private static final BigInteger LONG_MIN = BigInteger.valueOf(Long.MIN_VALUE);
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);
    private static final long MICROS_PER_HOUR = 3_600L * DateTimes.MICROS_PER_SECOND;
    private static final long MICROS_PER_MINUTE = 60L * DateTimes.MICROS_PER_SECOND;

    private ScalarFunctions() {
    }

    private interface Fn1 {
        Object apply(Object a);
    }

    /** Applies {@code fn} to a non-null argument; NULL in ⇒ NULL out. */
    private static Evaluator strict(Evaluator a, Fn1 fn) {
        return row -> {
            Object v = a.eval(row);
            return v == null ? null : fn.apply(v);
        };
    }

    static Evaluator compile(BoundExpr.Function f, Evaluator[] args, ExecContext ctx) {
        List<BoundExpr> argExprs = f.args();
        DataType in = argExprs.isEmpty() ? null : argExprs.get(0).type();
        return switch (f.name()) {
            case "ABS" -> strict(args[0], v -> abs(v, in));
            case "ROUND" -> {
                long n = (Long) ((BoundExpr.Literal) argExprs.get(1)).value();
                DataType out = f.type();
                yield strict(args[0], v -> round(v, in, (int) n, out));
            }
            case "FLOOR" -> strict(args[0], v -> floorCeil(v, in, true));
            case "CEIL" -> strict(args[0], v -> floorCeil(v, in, false));
            case "SQRT" -> strict(args[0], v -> {
                double x = (Double) v;
                if (x < 0) {
                    throw new PolyQueryException(ErrorCode.INVALID_ARGUMENT, "SQRT of a negative number");
                }
                return Math.sqrt(x);
            });
            case "POWER" -> row -> {
                Object a = args[0].eval(row);
                Object b = args[1].eval(row);
                return a == null || b == null ? null : power((Double) a, (Double) b);
            };
            case "LENGTH" -> strict(args[0], v -> {
                String s = (String) v;
                return (long) s.codePointCount(0, s.length());
            });
            case "UPPER" -> strict(args[0], v -> asciiCase((String) v, true));
            case "LOWER" -> strict(args[0], v -> asciiCase((String) v, false));
            case "TRIM" -> strict(args[0], v -> trim((String) v, true, true));
            case "LTRIM" -> strict(args[0], v -> trim((String) v, true, false));
            case "RTRIM" -> strict(args[0], v -> trim((String) v, false, true));
            case "REPLACE" -> row -> {
                Object s = args[0].eval(row);
                Object from = args[1].eval(row);
                Object to = args[2].eval(row);
                if (s == null || from == null || to == null) {
                    return null;
                }
                return ((String) from).isEmpty() ? s : ((String) s).replace((String) from, (String) to);
            };
            case "SUBSTR" -> substr(args);
            case "CONCAT" -> concat(argExprs, args);
            case "COALESCE" -> row -> {
                for (Evaluator a : args) {
                    Object v = a.eval(row);
                    if (v != null) {
                        return v;
                    }
                }
                return null;
            };
            case "YEAR", "MONTH", "DAY" -> {
                String name = f.name();
                boolean timestamp = in.kind() == TypeKind.TIMESTAMP;
                yield strict(args[0], v -> {
                    int day = timestamp ? DateTimes.dateOf((Long) v) : (Integer) v;
                    LocalDate d = LocalDate.ofEpochDay(day);
                    return (long) switch (name) {
                        case "YEAR" -> d.getYear();
                        case "MONTH" -> d.getMonthValue();
                        default -> d.getDayOfMonth();
                    };
                });
            }
            case "HOUR" -> strict(args[0], v -> Math.floorMod((Long) v, DateTimes.MICROS_PER_DAY) / MICROS_PER_HOUR);
            case "MINUTE" -> strict(args[0], v -> Math.floorMod((Long) v, MICROS_PER_HOUR) / MICROS_PER_MINUTE);
            case "SECOND" -> strict(args[0],
                    v -> Math.floorMod((Long) v, MICROS_PER_MINUTE) / DateTimes.MICROS_PER_SECOND);
            case "DATE_TRUNC" -> {
                String unit = (String) ((BoundExpr.Literal) argExprs.get(0)).value();
                yield strict(args[1], v -> dateTrunc(unit, (Long) v));
            }
            case "DATE_DIFF" -> row -> {
                Object a = args[1].eval(row);
                Object b = args[2].eval(row);
                return a == null || b == null ? null : (long) (Integer) b - (Integer) a;
            };
            case "PQ_SLEEP" -> strict(args[0], v -> {
                long ms = (Long) v;
                if (ms < 0) {
                    throw new PolyQueryException(ErrorCode.INVALID_ARGUMENT, "PQ_SLEEP requires a non-negative argument");
                }
                sleep(ctx, ms);
                return ms;
            });
            default -> throw new PolyQueryException(ErrorCode.UNSUPPORTED, "function " + f.name() + " is not supported");
        };
    }

    // ---------------------------------------------------------------- numeric

    private static Object abs(Object v, DataType t) {
        return switch (t.kind()) {
            case INT64 -> {
                long x = (Long) v;
                if (x == Long.MIN_VALUE) {
                    throw ExpressionCompiler.overflow();
                }
                yield Math.abs(x);
            }
            case DECIMAL -> v instanceof BigInteger b ? b.abs() : (Object) Math.abs((Long) v);
            case FLOAT64 -> Math.abs((Double) v);
            default -> v;
        };
    }

    private static Object round(Object v, DataType t, int n, DataType out) {
        return switch (t.kind()) {
            case INT64 -> {
                if (n >= 0) {
                    yield v;
                }
                BigInteger r = BigDecimal.valueOf((Long) v).setScale(n, RoundingMode.HALF_UP).toBigInteger();
                if (r.compareTo(LONG_MIN) < 0 || r.compareTo(LONG_MAX) > 0) {
                    throw ExpressionCompiler.overflow();
                }
                yield r.longValue();
            }
            case DECIMAL -> {
                if (n >= t.scale()) {
                    yield v;
                }
                BigDecimal r = new BigDecimal(Decimals.toBig(v), t.scale()).setScale(n, RoundingMode.HALF_UP)
                        .setScale(out.scale(), RoundingMode.UNNECESSARY);
                yield Decimals.value(r.unscaledValue(), out);
            }
            case FLOAT64 -> {
                double r = BigDecimal.valueOf((Double) v).setScale(n, RoundingMode.HALF_UP).doubleValue();
                if (Double.isInfinite(r)) {
                    throw ExpressionCompiler.overflow();
                }
                yield r == 0.0 ? 0.0 : r;
            }
            default -> v;
        };
    }

    private static Object floorCeil(Object v, DataType t, boolean floor) {
        return switch (t.kind()) {
            case DECIMAL -> {
                if (v instanceof BigInteger b) {
                    yield new BigDecimal(b, t.scale()).setScale(0, floor ? RoundingMode.FLOOR : RoundingMode.CEILING)
                            .unscaledValue();
                }
                long p = Decimals.pow10(t.scale());
                long x = (Long) v;
                yield floor ? Math.floorDiv(x, p) : -Math.floorDiv(-x, p);
            }
            case FLOAT64 -> floor ? Math.floor((Double) v) : Math.ceil((Double) v);
            default -> v;
        };
    }

    private static double power(double x, double y) {
        if (x == 0.0 && y < 0) {
            throw ExpressionCompiler.divisionByZero();
        }
        if (x < 0 && y != Math.rint(y)) {
            throw new PolyQueryException(ErrorCode.INVALID_ARGUMENT,
                    "POWER of a negative base with a non-integral exponent");
        }
        double r = Math.pow(x, y);
        if (Double.isInfinite(r) || Double.isNaN(r)) {
            throw ExpressionCompiler.overflow();
        }
        return r;
    }

    // ---------------------------------------------------------------- strings

    /**
     * ASCII-only case mapping (functions.md: "ASCII letters only are case-mapped; other
     * characters unchanged"). Words (runs of letters and digits) that contain a non-ASCII
     * character are kept as they are, as the conformance suite expects
     * ({@code UPPER('abc Ünï') = 'ABC Ünï'}).
     */
    static String asciiCase(String s, boolean upper) {
        char[] cs = s.toCharArray();
        int i = 0;
        while (i < cs.length) {
            if (!Character.isLetterOrDigit(cs[i]) && !Character.isSurrogate(cs[i])) {
                i++;
                continue;
            }
            int end = i;
            boolean ascii = true;
            while (end < cs.length && (Character.isLetterOrDigit(cs[end]) || Character.isSurrogate(cs[end]))) {
                ascii &= cs[end] < 128;
                end++;
            }
            if (ascii) {
                for (int k = i; k < end; k++) {
                    char c = cs[k];
                    if (upper && c >= 'a' && c <= 'z') {
                        cs[k] = (char) (c - 32);
                    } else if (!upper && c >= 'A' && c <= 'Z') {
                        cs[k] = (char) (c + 32);
                    }
                }
            }
            i = end;
        }
        return new String(cs);
    }

    private static String trim(String s, boolean leading, boolean trailing) {
        int start = 0;
        int end = s.length();
        if (leading) {
            while (start < end && s.charAt(start) == ' ') {
                start++;
            }
        }
        if (trailing) {
            while (end > start && s.charAt(end - 1) == ' ') {
                end--;
            }
        }
        return s.substring(start, end);
    }

    private static Evaluator substr(Evaluator[] args) {
        boolean hasLength = args.length == 3;
        return row -> {
            Object sv = args[0].eval(row);
            Object startV = args[1].eval(row);
            Object lenV = hasLength ? args[2].eval(row) : null;
            if (sv == null || startV == null || (hasLength && lenV == null)) {
                return null;
            }
            String s = (String) sv;
            long start = (Long) startV;
            int count = s.codePointCount(0, s.length());
            long from = Math.max(start, 1);
            long toExclusive = count + 1L;
            if (hasLength) {
                long len = (Long) lenV;
                if (len < 0) {
                    throw new PolyQueryException(ErrorCode.INVALID_ARGUMENT, "SUBSTR length must not be negative");
                }
                long end = start > Long.MAX_VALUE - len ? Long.MAX_VALUE : start + len;
                toExclusive = Math.min(toExclusive, end);
            }
            if (from >= toExclusive) {
                return "";
            }
            int b = s.offsetByCodePoints(0, (int) (from - 1));
            int e = s.offsetByCodePoints(b, (int) (toExclusive - from));
            return s.substring(b, e);
        };
    }

    private static Evaluator concat(List<BoundExpr> argExprs, Evaluator[] args) {
        DataType[] types = new DataType[args.length];
        for (int i = 0; i < types.length; i++) {
            types[i] = argExprs.get(i).type();
        }
        return row -> {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < args.length; i++) {
                Object v = args[i].eval(row);
                if (v != null) {
                    sb.append(Values.toText(v, types[i]));
                }
            }
            return sb.toString();
        };
    }

    // ---------------------------------------------------------------- date/time

    private static long dateTrunc(String unit, long micros) {
        return switch (unit) {
            case "year", "month" -> {
                LocalDate d = LocalDate.ofEpochDay(DateTimes.dateOf(micros));
                d = unit.equals("year") ? d.withDayOfYear(1) : d.withDayOfMonth(1);
                yield DateTimes.timestampOf((int) d.toEpochDay());
            }
            case "day" -> Math.floorDiv(micros, DateTimes.MICROS_PER_DAY) * DateTimes.MICROS_PER_DAY;
            case "hour" -> Math.floorDiv(micros, MICROS_PER_HOUR) * MICROS_PER_HOUR;
            case "minute" -> Math.floorDiv(micros, MICROS_PER_MINUTE) * MICROS_PER_MINUTE;
            default -> throw PolyQueryException.of(ErrorCode.INVALID_ARGUMENT, "unknown DATE_TRUNC unit '%s'", unit);
        };
    }

    /** Sleeps in small slices so that timeouts/cancellation are observed within a few ms. */
    private static void sleep(ExecContext ctx, long ms) {
        long end = System.nanoTime() + ms * 1_000_000L;
        while (true) {
            ctx.checkNow();
            long left = end - System.nanoTime();
            if (left <= 0) {
                return;
            }
            // Wake up at most every 5 ms, and just after the deadline if one is near.
            long untilDeadline = Math.max(ctx.remainingNanos(), 0);
            long slice = Math.min(left, 5_000_000L);
            if (untilDeadline < slice) {
                slice = untilDeadline + 100_000L;
            }
            try {
                Thread.sleep(slice / 1_000_000L, (int) (slice % 1_000_000L));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new PolyQueryException(ErrorCode.CANCELLED, "query was interrupted");
            }
        }
    }
}
