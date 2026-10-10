package polyquery.optimizer;

import java.math.BigDecimal;
import java.math.MathContext;
import java.util.ArrayList;
import java.util.List;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.storage.ColumnStats;
import polyquery.storage.Table;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/**
 * Static analysis deciding whether evaluating an expression can raise an error or yield NULL,
 * used to move predicates without changing results or errors. With the base-table origin of
 * the input slots, column statistics (min/max, null counts) refine the analysis: e.g.
 * {@code price * 2} cannot overflow if the stored prices are small enough. Interval arithmetic
 * is exact (BigDecimal).
 */
final class ExprSafety {
    private static final BigDecimal LONG_MIN = BigDecimal.valueOf(Long.MIN_VALUE);
    private static final BigDecimal LONG_MAX = BigDecimal.valueOf(Long.MAX_VALUE);
    private static final BigDecimal DECIMAL_LIMIT = BigDecimal.valueOf(999_999_999_999_999_999L);
    private static final BigDecimal DOUBLE_LIMIT = new BigDecimal("1e300");
    /** Scalar functions that never raise an error for valid arguments. */
    private static final List<String> TOTAL_FUNCTIONS = List.of("UPPER", "LOWER", "TRIM", "LTRIM", "RTRIM",
            "LENGTH", "REPLACE", "CONCAT", "COALESCE", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND");

    /** A stored column an input slot passes through unchanged. */
    record Origin(Table table, int column) {
        ColumnStats stats() {
            return table.stats().column(column);
        }
    }

    /** Value interval of a numeric expression ({@code null} bounds never occur; unknown = null range). */
    private record Range(BigDecimal lo, BigDecimal hi) {
        boolean contains(BigDecimal v) {
            return lo.compareTo(v) <= 0 && hi.compareTo(v) >= 0;
        }

        BigDecimal maxAbs() {
            return lo.abs().max(hi.abs());
        }
    }

    private final Origin[] origins;

    /** @param origins per input slot, its stored column (or null); null = no statistics */
    ExprSafety(Origin[] origins) {
        this.origins = origins;
    }

    /** The stored column each output slot of {@code plan} passes through, if any. */
    static Origin[] origins(LogicalPlan plan) {
        List<Origin> out = new ArrayList<>();
        collect(plan, out);
        return out.toArray(new Origin[0]);
    }

    private static void collect(LogicalPlan plan, List<Origin> out) {
        switch (plan) {
            case LogicalPlan.Scan s -> {
                for (int c = 0; c < s.table().columnCount(); c++) {
                    out.add(new Origin(s.table(), c));
                }
            }
            case LogicalPlan.Filter f -> collect(f.input(), out);
            case LogicalPlan.Join j -> {
                collect(j.left(), out);
                collect(j.right(), out);
            }
            case LogicalPlan.Project p -> {
                Origin[] in = origins(p.input());
                for (BoundExpr e : p.expressions()) {
                    out.add(e instanceof BoundExpr.ColumnRef c && c.index() < in.length ? in[c.index()] : null);
                }
            }
            default -> {
                for (int i = 0; i < plan.schema().size(); i++) {
                    out.add(null);
                }
            }
        }
    }

    private Origin origin(BoundExpr e) {
        if (e instanceof BoundExpr.ColumnRef c && origins != null && c.index() < origins.length) {
            return origins[c.index()];
        }
        return null;
    }

    // ------------------------------------------------------------------ errors

    /** False only if evaluating {@code e} can never raise an error on the rows it may see. */
    boolean canFail(BoundExpr e) {
        boolean self = switch (e) {
            case BoundExpr.Negate n -> n.type().kind() == TypeKind.INT64 && !excludes(range(n.input()), LONG_MIN);
            case BoundExpr.Cast c -> castCanFail(c);
            case BoundExpr.Arithmetic a -> arithmeticCanFail(a);
            case BoundExpr.Function f -> functionCanFail(f);
            case BoundExpr.ScalarSubquery s -> true;
            case BoundExpr.Exists x -> true;
            case BoundExpr.InSubquery i -> true;
            default -> false;
        };
        if (self) {
            return true;
        }
        for (BoundExpr c : BoundExprs.children(e)) {
            if (canFail(c)) {
                return true;
            }
        }
        return false;
    }

    private static boolean excludes(Range r, BigDecimal v) {
        return r != null && !r.contains(v);
    }

    private boolean functionCanFail(BoundExpr.Function f) {
        if (TOTAL_FUNCTIONS.contains(f.name())) {
            return false;
        }
        List<BoundExpr> args = f.args();
        return switch (f.name()) {
            case "ABS" -> args.getFirst().type().kind() == TypeKind.INT64
                    && !excludes(range(args.getFirst()), LONG_MIN);
            case "SUBSTR" -> args.size() == 3 && !(args.get(2) instanceof BoundExpr.Literal l
                    && l.value() instanceof Long n && n >= 0);
            case "ROUND", "FLOOR", "CEIL" -> {
                if (args.getFirst().type().kind() == TypeKind.FLOAT64) {
                    yield false;
                }
                Range r = range(args.getFirst());
                yield r == null || r.maxAbs().compareTo(BigDecimal.TEN.pow(15)) > 0
                        || args.size() > 1 && !(args.get(1) instanceof BoundExpr.Literal l
                        && l.value() instanceof Long n && n >= -15 && n <= 18);
            }
            case "SQRT" -> {
                Range r = range(args.getFirst());
                yield r == null || r.lo().signum() < 0;
            }
            default -> true;
        };
    }

    private boolean castCanFail(BoundExpr.Cast c) {
        DataType from = c.input().type();
        DataType to = c.type();
        TypeKind f = from.kind();
        TypeKind t = to.kind();
        if (from.equals(to) || f == TypeKind.NULL || t == TypeKind.STRING) {
            return false;
        }
        switch (f) {
            case BOOLEAN:
                return t != TypeKind.INT64;
            case DATE:
                return t != TypeKind.TIMESTAMP;
            case TIMESTAMP:
                return t != TypeKind.DATE;
            case INT64:
                if (t == TypeKind.FLOAT64 || t == TypeKind.BOOLEAN) {
                    return false;
                }
                break;
            case DECIMAL:
                if (t == TypeKind.FLOAT64 || t == TypeKind.INT64) {
                    return false;
                }
                if (t == TypeKind.DECIMAL && to.scale() >= from.scale()
                        && to.precision() - to.scale() >= from.precision() - from.scale()) {
                    return false;
                }
                break;
            case FLOAT64:
                break;
            default:
                return true;
        }
        // numeric conversions that can overflow: safe if the value range fits the target
        Range r = range(c.input());
        if (r == null) {
            return true;
        }
        BigDecimal bound = switch (t) {
            case INT64 -> LONG_MAX.subtract(BigDecimal.ONE);
            case DECIMAL -> BigDecimal.TEN.pow(to.precision() - to.scale()).subtract(BigDecimal.ONE);
            case FLOAT64 -> DOUBLE_LIMIT;
            default -> BigDecimal.ZERO;
        };
        // one unit of headroom for rounding to fewer fractional digits
        return r.maxAbs().add(BigDecimal.ONE).compareTo(bound) > 0;
    }

    private boolean arithmeticCanFail(BoundExpr.Arithmetic a) {
        DataType type = a.type();
        if (type.isNull()) {
            return false;
        }
        if (type.kind() == TypeKind.INT64 && (a.op() == BoundExpr.ArithOp.DIV || a.op() == BoundExpr.ArithOp.MOD)
                && a.right() instanceof BoundExpr.Literal l && l.value() instanceof Long d
                && d != 0 && (d != -1 || a.op() == BoundExpr.ArithOp.MOD)) {
            return false; // x / c, x % c with a safe constant
        }
        Range l = range(a.left());
        Range r = range(a.right());
        if (l == null || r == null) {
            return true;
        }
        if ((a.op() == BoundExpr.ArithOp.DIV || a.op() == BoundExpr.ArithOp.MOD) && r.contains(BigDecimal.ZERO)) {
            return true;
        }
        Range result = arithmetic(a.op(), l, r);
        if (result == null) {
            return true;
        }
        BigDecimal limit = switch (type.kind()) {
            case INT64 -> LONG_MAX.subtract(BigDecimal.ONE);
            case DECIMAL -> DECIMAL_LIMIT.movePointLeft(type.scale());
            default -> DOUBLE_LIMIT;
        };
        return result.maxAbs().compareTo(limit) > 0;
    }

    private static Range arithmetic(BoundExpr.ArithOp op, Range l, Range r) {
        return switch (op) {
            case ADD -> new Range(l.lo().add(r.lo()), l.hi().add(r.hi()));
            case SUB -> new Range(l.lo().subtract(r.hi()), l.hi().subtract(r.lo()));
            case MUL -> hull(l.lo().multiply(r.lo()), l.lo().multiply(r.hi()), l.hi().multiply(r.lo()),
                    l.hi().multiply(r.hi()));
            case DIV -> {
                if (r.contains(BigDecimal.ZERO)) {
                    yield null;
                }
                MathContext mc = MathContext.DECIMAL64;
                yield hull(l.lo().divide(r.lo(), mc), l.lo().divide(r.hi(), mc), l.hi().divide(r.lo(), mc),
                        l.hi().divide(r.hi(), mc));
            }
            case MOD -> {
                BigDecimal m = r.maxAbs();
                yield new Range(m.negate(), m);
            }
        };
    }

    private static Range hull(BigDecimal... vs) {
        BigDecimal lo = vs[0];
        BigDecimal hi = vs[0];
        for (BigDecimal v : vs) {
            lo = lo.min(v);
            hi = hi.max(v);
        }
        return new Range(lo, hi);
    }

    /** Interval of the non-null values of a numeric expression, or null if unknown. */
    private Range range(BoundExpr e) {
        return switch (e) {
            case BoundExpr.Literal l -> {
                BigDecimal v = number(l.value(), l.type());
                yield v == null ? null : new Range(v, v);
            }
            case BoundExpr.ColumnRef c -> {
                Origin o = origin(c);
                if (o == null) {
                    yield null;
                }
                ColumnStats s = o.stats();
                if (s.min() == null) {
                    yield new Range(BigDecimal.ZERO, BigDecimal.ZERO); // no non-null values at all
                }
                BigDecimal lo = number(s.min(), c.type());
                BigDecimal hi = number(s.max(), c.type());
                yield lo == null || hi == null ? null : new Range(lo, hi);
            }
            case BoundExpr.Negate n -> {
                Range r = range(n.input());
                yield r == null ? null : new Range(r.hi().negate(), r.lo().negate());
            }
            case BoundExpr.Cast c -> c.type().isNumeric() && c.input().type().isNumeric() ? widen(range(c.input()))
                    : null;
            case BoundExpr.Arithmetic a -> {
                Range l = range(a.left());
                Range r = range(a.right());
                yield l == null || r == null ? null : arithmetic(a.op(), l, r);
            }
            case BoundExpr.Function f when f.name().equals("ABS") -> {
                Range r = range(f.args().getFirst());
                yield r == null ? null : new Range(BigDecimal.ZERO, r.maxAbs());
            }
            default -> null;
        };
    }

    /** A range widened by one unit (rounding in conversions). */
    private static Range widen(Range r) {
        return r == null ? null : new Range(r.lo().subtract(BigDecimal.ONE), r.hi().add(BigDecimal.ONE));
    }

    private static BigDecimal number(Object v, DataType type) {
        if (v == null) {
            return null;
        }
        return switch (type.kind()) {
            case INT64 -> BigDecimal.valueOf((Long) v);
            case DECIMAL -> BigDecimal.valueOf((Long) v, type.scale());
            case FLOAT64 -> {
                double d = (Double) v;
                yield Double.isFinite(d) ? new BigDecimal(d) : null;
            }
            default -> null;
        };
    }

    // ------------------------------------------------------------------ NULLs

    /** True only if {@code e} can never evaluate to NULL (and is total), e.g. comparisons of non-null columns. */
    boolean neverNull(BoundExpr e) {
        return switch (e) {
            case BoundExpr.Literal l -> l.value() != null;
            case BoundExpr.ColumnRef c -> {
                Origin o = origin(c);
                yield o != null && o.table().rowCount() > 0 && o.stats().nullCount() == 0;
            }
            case BoundExpr.IsNull n -> true;
            case BoundExpr.Comparison c -> neverNull(c.left()) && neverNull(c.right());
            case BoundExpr.And a -> neverNull(a.left()) && neverNull(a.right());
            case BoundExpr.Or o -> neverNull(o.left()) && neverNull(o.right());
            case BoundExpr.Not n -> neverNull(n.input());
            case BoundExpr.Cast c -> neverNull(c.input());
            case BoundExpr.Negate n -> neverNull(n.input());
            case BoundExpr.Arithmetic a -> neverNull(a.left()) && neverNull(a.right());
            case BoundExpr.Concat c -> neverNull(c.left()) && neverNull(c.right());
            case BoundExpr.Between b -> neverNull(b.operand()) && neverNull(b.lower()) && neverNull(b.upper());
            case BoundExpr.Placeholder p -> true; // the operand checked by the enclosing node
            case BoundExpr.InList i -> neverNull(i.operand()) && i.comparisons().stream().allMatch(this::neverNull);
            case BoundExpr.Like l -> neverNull(l.operand()) && neverNull(l.pattern());
            default -> false;
        };
    }
}
