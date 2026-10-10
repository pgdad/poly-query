package polyquery.physical;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import polyquery.exec.ConstantEvaluator;
import polyquery.index.KeyDomain;
import polyquery.index.KeyPredicate;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExpr.CompareOp;
import polyquery.plan.BoundExprs;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;
import polyquery.types.TypeKind;

/**
 * Extracts "sargable" conjuncts of a scan's filter — {@code col <op> constant},
 * {@code col BETWEEN c1 AND c2}, {@code col IN (constants)} — as {@link KeyPredicate}s on the
 * column's key domain. The result is used for index selection and row-group skipping; the
 * filter itself is still evaluated on every produced row.
 */
final class ColumnPredicates {
    private ColumnPredicates() {
    }

    /**
     * Sargable conjuncts of a filter.
     *
     * @param columns        per column position, the conjunction of all sargable conjuncts on it
     * @param otherConjuncts number of conjuncts that are not sargable
     */
    record Extraction(Map<Integer, KeyPredicate> columns, int otherConjuncts) {
    }

    static Extraction extract(BoundExpr predicate, List<ColumnSchema> schema) {
        List<DataType> columnTypes = new ArrayList<>();
        for (ColumnSchema c : schema) {
            columnTypes.add(c.type());
        }
        Map<Integer, KeyPredicate> out = new TreeMap<>();
        int others = 0;
        for (BoundExpr c : BoundExprs.conjuncts(predicate)) {
            Sarg s = sarg(c, columnTypes);
            if (s != null) {
                out.merge(s.column, s.predicate, KeyPredicate::and);
            } else {
                others++;
            }
        }
        return new Extraction(out, others);
    }

    private record Sarg(int column, KeyPredicate predicate) {
    }

    private static Sarg sarg(BoundExpr c, List<DataType> types) {
        try {
            return switch (c) {
                case BoundExpr.Comparison cmp -> comparison(cmp, types);
                case BoundExpr.Between b when !b.negated() -> between(b, types);
                case BoundExpr.InList in when !in.negated() -> inList(in, types);
                default -> null;
            };
        } catch (RuntimeException e) {
            // e.g. a constant that fails to evaluate: leave the conjunct to the filter
            return null;
        }
    }

    private static Sarg comparison(BoundExpr.Comparison cmp, List<DataType> types) {
        if (cmp.op() == CompareOp.NEQ) {
            return null;
        }
        Integer col = columnOf(cmp.left());
        if (col != null && isConstant(cmp.right())) {
            KeyPredicate p = keyPredicate(cmp.op(), types.get(col), cmp.right().type(), eval(cmp.right()));
            return p == null || !castAllowed(cmp.left()) ? null : new Sarg(col, p);
        }
        col = columnOf(cmp.right());
        if (col != null && isConstant(cmp.left())) {
            KeyPredicate p = keyPredicate(flip(cmp.op()), types.get(col), cmp.left().type(), eval(cmp.left()));
            return p == null || !castAllowed(cmp.right()) ? null : new Sarg(col, p);
        }
        return null;
    }

    private static Sarg between(BoundExpr.Between b, List<DataType> types) {
        Integer col = columnOf(b.operand());
        if (col == null || !castAllowed(b.operand())) {
            return null;
        }
        KeyPredicate lower = placeholderBound(b.lower(), types.get(col));
        KeyPredicate upper = placeholderBound(b.upper(), types.get(col));
        return lower == null || upper == null ? null : new Sarg(col, lower.and(upper));
    }

    private static Sarg inList(BoundExpr.InList in, List<DataType> types) {
        Integer col = columnOf(in.operand());
        if (col == null || !castAllowed(in.operand())) {
            return null;
        }
        KeyPredicate result = new KeyPredicate.Empty();
        List<Object> points = new ArrayList<>();
        for (BoundExpr item : in.comparisons()) {
            KeyPredicate p = placeholderBound(item, types.get(col));
            switch (p) {
                case null -> {
                    return null;
                }
                case KeyPredicate.Points pts -> points.addAll(pts.keys());
                case KeyPredicate.Empty e -> {
                }
                case KeyPredicate.Range r -> {
                    return null;
                }
            }
        }
        if (!points.isEmpty()) {
            result = KeyPredicate.Points.of(points);
        }
        return new Sarg(col, result);
    }

    /** {@code placeholder <op> constant} (placeholder possibly implicitly cast). */
    private static KeyPredicate placeholderBound(BoundExpr e, DataType columnType) {
        if (!(e instanceof BoundExpr.Comparison cmp) || !isPlaceholder(cmp.left()) || !isConstant(cmp.right())) {
            return null;
        }
        if (cmp.left() instanceof BoundExpr.Cast cast && !allowedCast(columnType, cast)) {
            return null;
        }
        return keyPredicate(cmp.op(), columnType, cmp.right().type(), eval(cmp.right()));
    }

    // ---------------------------------------------------------------- shapes

    /** Column position if {@code e} is a column reference, possibly under an exact implicit cast. */
    private static Integer columnOf(BoundExpr e) {
        if (e instanceof BoundExpr.ColumnRef c) {
            return c.index();
        }
        if (e instanceof BoundExpr.Cast cast && cast.implicit() && cast.input() instanceof BoundExpr.ColumnRef c) {
            return c.index();
        }
        return null;
    }

    private static boolean castAllowed(BoundExpr e) {
        return !(e instanceof BoundExpr.Cast cast) || allowedCast(cast.input().type(), cast);
    }

    /** Exact, order-preserving implicit casts: INT64 → DECIMAL(18,s) and DATE → TIMESTAMP. */
    private static boolean allowedCast(DataType from, BoundExpr.Cast cast) {
        if (!cast.implicit()) {
            return false;
        }
        TypeKind to = cast.type().kind();
        return (from.kind() == TypeKind.INT64 && to == TypeKind.DECIMAL)
                || (from.kind() == TypeKind.DATE && to == TypeKind.TIMESTAMP);
    }

    private static boolean isPlaceholder(BoundExpr e) {
        return e instanceof BoundExpr.Placeholder
                || (e instanceof BoundExpr.Cast cast && cast.input() instanceof BoundExpr.Placeholder);
    }

    private static boolean isConstant(BoundExpr e) {
        return BoundExprs.isConstant(e);
    }

    private static Object eval(BoundExpr e) {
        return ConstantEvaluator.evaluate(e);
    }

    private static CompareOp flip(CompareOp op) {
        return switch (op) {
            case LT -> CompareOp.GT;
            case LE -> CompareOp.GE;
            case GT -> CompareOp.LT;
            case GE -> CompareOp.LE;
            default -> op;
        };
    }

    // ---------------------------------------------------------------- constants → key domain

    /**
     * The key predicate equivalent to {@code column <op> value}, where {@code value} has type
     * {@code valueType}; null if the combination is not supported.
     */
    static KeyPredicate keyPredicate(CompareOp op, DataType columnType, DataType valueType, Object value) {
        if (value == null || valueType.isNull()) {
            return new KeyPredicate.Empty(); // comparisons with NULL are never true
        }
        TypeKind ck = columnType.kind();
        TypeKind vk = valueType.kind();
        if (ck == vk && (ck != TypeKind.DECIMAL || columnType.scale() == valueType.scale())) {
            return simple(op, KeyDomain.key(value, columnType));
        }
        if (ck == TypeKind.DECIMAL && vk == TypeKind.DECIMAL) {
            return rational(op, BigInteger.valueOf((Long) value).multiply(pow10(columnType.scale())),
                    pow10(valueType.scale()));
        }
        if (ck == TypeKind.INT64 && vk == TypeKind.DECIMAL) {
            return rational(op, BigInteger.valueOf((Long) value), pow10(valueType.scale()));
        }
        if (ck == TypeKind.DATE && vk == TypeKind.TIMESTAMP) {
            return rational(op, BigInteger.valueOf((Long) value), BigInteger.valueOf(DateTimes.MICROS_PER_DAY));
        }
        return null;
    }

    private static BigInteger pow10(int n) {
        return BigInteger.valueOf(Decimals.pow10(n));
    }

    private static KeyPredicate simple(CompareOp op, Object key) {
        return switch (op) {
            case EQ -> new KeyPredicate.Points(List.of(key));
            case LT -> new KeyPredicate.Range(null, false, key, false);
            case LE -> new KeyPredicate.Range(null, false, key, true);
            case GT -> new KeyPredicate.Range(key, false, null, false);
            case GE -> new KeyPredicate.Range(key, true, null, false);
            case NEQ -> null;
        };
    }

    private static final BigInteger LONG_MIN = BigInteger.valueOf(Long.MIN_VALUE);
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);

    /** {@code k <op> num/den} for integer keys {@code k} (den > 0), as inclusive integer bounds. */
    private static KeyPredicate rational(CompareOp op, BigInteger num, BigInteger den) {
        BigInteger[] qr = num.divideAndRemainder(den);
        BigInteger floor = qr[1].signum() < 0 ? qr[0].subtract(BigInteger.ONE) : qr[0];
        BigInteger ceil = qr[1].signum() > 0 ? qr[0].add(BigInteger.ONE) : qr[0];
        return switch (op) {
            case EQ -> qr[1].signum() != 0 || floor.compareTo(LONG_MIN) < 0 || floor.compareTo(LONG_MAX) > 0
                    ? new KeyPredicate.Empty() : new KeyPredicate.Points(List.of(floor.longValueExact()));
            case GT -> lowerBound(floor.add(BigInteger.ONE));
            case GE -> lowerBound(ceil);
            case LT -> upperBound(ceil.subtract(BigInteger.ONE));
            case LE -> upperBound(floor);
            case NEQ -> null;
        };
    }

    private static KeyPredicate lowerBound(BigInteger lo) {
        if (lo.compareTo(LONG_MAX) > 0) {
            return new KeyPredicate.Empty();
        }
        return lo.compareTo(LONG_MIN) <= 0 ? new KeyPredicate.Range(null, false, null, false)
                : new KeyPredicate.Range(lo.longValueExact(), true, null, false);
    }

    private static KeyPredicate upperBound(BigInteger hi) {
        if (hi.compareTo(LONG_MIN) < 0) {
            return new KeyPredicate.Empty();
        }
        return hi.compareTo(LONG_MAX) >= 0 ? new KeyPredicate.Range(null, false, null, false)
                : new KeyPredicate.Range(null, false, hi.longValueExact(), true);
    }
}
