package polyquery.sql.analyzer;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExpr.ArithOp;
import polyquery.plan.BoundExpr.CompareOp;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/** Static typing rules: comparability, numeric promotion and common types (types.md §2, semantics.md §13). */
final class TypeCoercion {
    private TypeCoercion() {
    }

    static PolyQueryException typeError(String fmt, Object... args) {
        return PolyQueryException.of(ErrorCode.TYPE_ERROR, fmt, args);
    }

    /** Wraps {@code e} in an implicit cast to {@code t} unless it already has that type. */
    static BoundExpr implicit(BoundExpr e, DataType t) {
        if (e.type().equals(t)) {
            return e;
        }
        if (e instanceof BoundExpr.Literal l && l.value() == null) {
            return new BoundExpr.Literal(null, t);
        }
        return new BoundExpr.Cast(e, t, true);
    }

    static void requireBoolean(DataType t, String what) {
        if (t.kind() != TypeKind.BOOLEAN && !t.isNull()) {
            throw typeError("%s requires BOOLEAN operands, got %s", what, t);
        }
    }

    static BoundExpr comparison(CompareOp op, BoundExpr l, BoundExpr r, String what) {
        BoundExpr[] pair = comparablePair(l, r, what);
        return new BoundExpr.Comparison(op, pair[0], pair[1]);
    }

    /** Coerces both operands of a comparison to a comparable pair (types.md §2, §5). */
    static BoundExpr[] comparablePair(BoundExpr l, BoundExpr r, String what) {
        DataType lt = l.type();
        DataType rt = r.type();
        if (lt.isNull() || rt.isNull()) {
            return new BoundExpr[] {l, r};
        }
        TypeKind lk = lt.kind();
        TypeKind rk = rt.kind();
        if (lt.isNumeric() && rt.isNumeric()) {
            if (lk == rk) {
                return new BoundExpr[] {l, r};
            }
            if (lk == TypeKind.FLOAT64 || rk == TypeKind.FLOAT64) {
                return new BoundExpr[] {implicit(l, DataType.FLOAT64), implicit(r, DataType.FLOAT64)};
            }
            // INT64 / DECIMAL: compared by exact value (CR-2 §4). INT64 and narrow DECIMAL operands
            // of any scales are compared as they are; with a wide operand both become wide.
            if (lt.isWideDecimal() || rt.isWideDecimal()) {
                return new BoundExpr[] {implicit(l, wide(lt)), implicit(r, wide(rt))};
            }
            return new BoundExpr[] {l, r};
        }
        if (lk.isTemporal() && rk.isTemporal()) {
            if (lk == rk) {
                return new BoundExpr[] {l, r};
            }
            return new BoundExpr[] {
                lk == TypeKind.DATE ? implicit(l, DataType.TIMESTAMP) : l,
                rk == TypeKind.DATE ? implicit(r, DataType.TIMESTAMP) : r};
        }
        if (lk == rk) {
            return new BoundExpr[] {l, r};
        }
        throw typeError("cannot compare %s with %s (%s)", lt, rt, what);
    }

    /**
     * Common type of CASE results / COALESCE arguments: numeric promotion, otherwise all non-NULL
     * types must be equal. Returns the null type if all inputs have it.
     */
    static DataType commonType(List<DataType> types, String what) {
        DataType result = null;
        for (DataType t : types) {
            if (t.isNull()) {
                continue;
            }
            if (result == null || result.equals(t)) {
                result = t;
                continue;
            }
            if (result.isNumeric() && t.isNumeric()) {
                result = promote(result, t);
                continue;
            }
            throw typeError("incompatible types %s and %s in %s", result, t, what);
        }
        return result == null ? DataType.NULL : result;
    }

    private static DataType promote(DataType a, DataType b) {
        if (a.kind() == TypeKind.FLOAT64 || b.kind() == TypeKind.FLOAT64) {
            return DataType.FLOAT64;
        }
        if (a.kind() == TypeKind.INT64 && b.kind() == TypeKind.INT64) {
            return DataType.INT64;
        }
        int scale = Math.max(a.exactScale(), b.exactScale());
        return DataType.decimal(resultPrecision(a, b), scale);
    }

    /**
     * The result precision W of a rule involving DECIMAL operands (CR-2 §2): 38 if one of them is
     * a wide DECIMAL, else 18 (INT64 operands do not count).
     */
    static int resultPrecision(DataType... operands) {
        for (DataType t : operands) {
            if (t.isWideDecimal()) {
                return DataType.MAX_DECIMAL_PRECISION;
            }
        }
        return DataType.NARROW_DECIMAL_PRECISION;
    }

    /** The wide DECIMAL type holding every value of the exact numeric type {@code t} exactly. */
    private static DataType wide(DataType t) {
        return t.isWideDecimal() ? t : DataType.decimal(DataType.MAX_DECIMAL_PRECISION, t.exactScale());
    }

    /** Casts every expression to the common type. */
    static List<BoundExpr> castAll(List<BoundExpr> exprs, DataType t) {
        List<BoundExpr> out = new ArrayList<>(exprs.size());
        for (BoundExpr e : exprs) {
            out.add(t.isNull() ? e : implicit(e, t));
        }
        return out;
    }

    static BoundExpr arithmetic(ArithOp op, BoundExpr l, BoundExpr r, String symbol) {
        DataType lt = l.type();
        DataType rt = r.type();
        if ((!lt.isNumeric() && !lt.isNull()) || (!rt.isNumeric() && !rt.isNull())) {
            throw typeError("operator %s requires numeric operands, got %s and %s", symbol, lt, rt);
        }
        if (lt.isNull() && rt.isNull()) {
            return new BoundExpr.Literal(null, DataType.NULL);
        }
        // A NULL literal takes the family of the other operand.
        if (lt.isNull()) {
            l = new BoundExpr.Literal(null, rt.kind() == TypeKind.DECIMAL ? DataType.INT64 : rt);
            lt = l.type();
        }
        if (rt.isNull()) {
            r = new BoundExpr.Literal(null, lt.kind() == TypeKind.DECIMAL ? DataType.INT64 : lt);
            rt = r.type();
        }
        TypeKind lk = lt.kind();
        TypeKind rk = rt.kind();
        if (lk == TypeKind.INT64 && rk == TypeKind.INT64) {
            return new BoundExpr.Arithmetic(op, l, r, DataType.INT64);
        }
        if (op == ArithOp.MOD) {
            throw typeError("operator %% requires INT64 operands, got %s and %s", lt, rt);
        }
        if (lk == TypeKind.FLOAT64 || rk == TypeKind.FLOAT64 || op == ArithOp.DIV) {
            return new BoundExpr.Arithmetic(op, implicit(l, DataType.FLOAT64), implicit(r, DataType.FLOAT64),
                    DataType.FLOAT64);
        }
        // DECIMAL arithmetic with result precision W; an INT64 operand becomes DECIMAL(W,0).
        int w = resultPrecision(lt, rt);
        if (lk == TypeKind.INT64) {
            l = implicit(l, DataType.decimal(w, 0));
        }
        if (rk == TypeKind.INT64) {
            r = implicit(r, DataType.decimal(w, 0));
        }
        int s1 = l.type().scale();
        int s2 = r.type().scale();
        int scale = op == ArithOp.MUL ? s1 + s2 : Math.max(s1, s2);
        if (scale > w) {
            throw typeError("result scale %d of DECIMAL multiplication exceeds %d", scale, w);
        }
        return new BoundExpr.Arithmetic(op, l, r, DataType.decimal(w, scale));
    }
}
