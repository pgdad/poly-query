package polyquery.sql.analyzer;

import java.math.BigInteger;
import java.util.List;
import java.util.Locale;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.AggregateCall;
import polyquery.plan.AggregateCall.AggregateFunction;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExpr.ArithOp;
import polyquery.plan.BoundExpr.CompareOp;
import polyquery.sql.ast.Expr;
import polyquery.types.Casts;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.TypeKind;

/** Resolves names and assigns types to expressions (types.md §2–§8). */
final class ExpressionBinder {
    /** Where aggregate calls may appear in the expression being bound. */
    enum AggMode { NOT_ALLOWED, ALLOWED, INSIDE_AGGREGATE }

    private static final BigInteger LONG_MIN = BigInteger.valueOf(Long.MIN_VALUE);
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);

    private final Scope scope;
    private final FunctionRegistry functions;
    private final AggregateCollector aggregates;
    private final String clause;

    ExpressionBinder(Scope scope, FunctionRegistry functions, AggregateCollector aggregates, String clause) {
        this.scope = scope;
        this.functions = functions;
        this.aggregates = aggregates;
        this.clause = clause;
    }

    BoundExpr bind(Expr e) {
        return bind(e, aggregates == null ? AggMode.NOT_ALLOWED : AggMode.ALLOWED);
    }

    private static PolyQueryException typeError(String fmt, Object... args) {
        return PolyQueryException.of(ErrorCode.TYPE_ERROR, fmt, args);
    }

    private static PolyQueryException unsupported(String feature) {
        return PolyQueryException.of(ErrorCode.UNSUPPORTED, "%s is not supported by this engine", feature);
    }

    private BoundExpr bind(Expr e, AggMode mode) {
        try {
            return bindInner(e, mode);
        } catch (PolyQueryException ex) {
            if (!ex.details().containsKey("line") && ex.code() != ErrorCode.UNSUPPORTED) {
                ex.withDetail("line", (long) e.pos().line()).withDetail("column", (long) e.pos().column());
            }
            throw ex;
        }
    }

    private BoundExpr bindInner(Expr e, AggMode mode) {
        return switch (e) {
            case Expr.NumberLiteral n -> numberLiteral(n.text());
            case Expr.StringLiteral s -> new BoundExpr.Literal(s.value(), DataType.STRING);
            case Expr.BooleanLiteral b -> new BoundExpr.Literal(b.value(), DataType.BOOLEAN);
            case Expr.NullLiteral n -> new BoundExpr.Literal(null, DataType.NULL);
            case Expr.TypedLiteral t -> typedLiteral(t);
            case Expr.ColumnRef c -> scope.resolve(c.qualifier(), c.name());
            case Expr.Unary u -> unary(u, mode);
            case Expr.Binary b -> binary(b, mode);
            case Expr.IsNull n -> new BoundExpr.IsNull(bind(n.operand(), mode), n.negated());
            case Expr.Cast c -> cast(c, mode);
            case Expr.FunctionCall f -> function(f, mode);
            case Expr.Between b -> throw unsupported("BETWEEN");
            case Expr.InList i -> throw unsupported("IN");
            case Expr.InSubquery i -> throw unsupported("IN (subquery)");
            case Expr.Like l -> throw unsupported("LIKE");
            case Expr.Case c -> throw unsupported("CASE");
            case Expr.Exists x -> throw unsupported("EXISTS");
            case Expr.ScalarSubquery s -> throw unsupported("scalar subquery");
        };
    }

    // ---------------------------------------------------------------- literals

    static BoundExpr.Literal numberLiteral(String text) {
        boolean hasExp = text.indexOf('e') >= 0 || text.indexOf('E') >= 0;
        if (hasExp) {
            return floatLiteral(text);
        }
        int dot = text.indexOf('.');
        if (dot < 0) {
            BigInteger v = new BigInteger(text);
            if (v.compareTo(LONG_MIN) < 0 || v.compareTo(LONG_MAX) > 0) {
                throw PolyQueryException.of(ErrorCode.NUMERIC_OVERFLOW, "integer literal %s is out of range", text);
            }
            return new BoundExpr.Literal(v.longValue(), DataType.INT64);
        }
        boolean negative = text.startsWith("-");
        String digits = negative ? text.substring(1) : text;
        int d = digits.indexOf('.');
        String intPart = digits.substring(0, d);
        String fracPart = digits.substring(d + 1);
        String sigInt = intPart.replaceFirst("^0+", "");
        int scale = fracPart.length();
        int precision = Math.max(Math.max(sigInt.length() + scale, scale), 1);
        if (precision > DataType.MAX_DECIMAL_PRECISION) {
            return floatLiteral(text);
        }
        String all = sigInt + fracPart;
        long unscaled = all.isEmpty() ? 0 : Long.parseLong(all);
        return new BoundExpr.Literal(negative ? -unscaled : unscaled, DataType.decimal(precision, scale));
    }

    private static BoundExpr.Literal floatLiteral(String text) {
        double d = Double.parseDouble(text);
        if (Double.isInfinite(d)) {
            throw PolyQueryException.of(ErrorCode.NUMERIC_OVERFLOW, "float literal %s is out of range", text);
        }
        return new BoundExpr.Literal(d, DataType.FLOAT64);
    }

    private static BoundExpr typedLiteral(Expr.TypedLiteral t) {
        if (t.typeName().equals("DATE")) {
            Integer d = DateTimes.parseDate(t.text());
            if (d == null) {
                throw PolyQueryException.of(ErrorCode.CONVERSION_ERROR, "invalid DATE literal '%s'", t.text());
            }
            return new BoundExpr.Literal(d, DataType.DATE);
        }
        Long ts = DateTimes.parseTimestamp(t.text(), false);
        if (ts == null) {
            throw PolyQueryException.of(ErrorCode.CONVERSION_ERROR, "invalid TIMESTAMP literal '%s'", t.text());
        }
        return new BoundExpr.Literal(ts, DataType.TIMESTAMP);
    }

    // ---------------------------------------------------------------- operators

    private BoundExpr unary(Expr.Unary u, AggMode mode) {
        BoundExpr in = bind(u.operand(), mode);
        DataType t = in.type();
        if (u.op() == Expr.UnaryOp.NOT) {
            requireBoolean(t, "NOT");
            return new BoundExpr.Not(in);
        }
        if (!t.isNumeric() && !t.isNull()) {
            throw typeError("unary %s requires a numeric operand, got %s", u.op() == Expr.UnaryOp.NEG ? "-" : "+", t);
        }
        return u.op() == Expr.UnaryOp.NEG ? new BoundExpr.Negate(in, t) : in;
    }

    private static void requireBoolean(DataType t, String op) {
        if (t.kind() != TypeKind.BOOLEAN && !t.isNull()) {
            throw typeError("%s requires BOOLEAN operands, got %s", op, t);
        }
    }

    private BoundExpr binary(Expr.Binary b, AggMode mode) {
        BoundExpr l = bind(b.left(), mode);
        BoundExpr r = bind(b.right(), mode);
        return switch (b.op()) {
            case AND, OR -> {
                requireBoolean(l.type(), b.op().name());
                requireBoolean(r.type(), b.op().name());
                yield b.op() == Expr.BinaryOp.AND ? new BoundExpr.And(l, r) : new BoundExpr.Or(l, r);
            }
            case CONCAT -> {
                if ((l.type().kind() != TypeKind.STRING && !l.type().isNull())
                        || (r.type().kind() != TypeKind.STRING && !r.type().isNull())) {
                    throw typeError("|| requires STRING operands, got %s and %s", l.type(), r.type());
                }
                yield new BoundExpr.Concat(l, r);
            }
            case EQ, NEQ, LT, LE, GT, GE -> comparison(b.op(), l, r);
            case ADD, SUB, MUL, DIV, MOD -> arithmetic(b.op(), l, r);
        };
    }

    private static CompareOp compareOp(Expr.BinaryOp op) {
        return switch (op) {
            case EQ -> CompareOp.EQ;
            case NEQ -> CompareOp.NEQ;
            case LT -> CompareOp.LT;
            case LE -> CompareOp.LE;
            case GT -> CompareOp.GT;
            case GE -> CompareOp.GE;
            default -> throw new IllegalArgumentException(op.name());
        };
    }

    /** Coerces both operands of a comparison to a comparable pair (types.md §2, §5). */
    static BoundExpr comparison(Expr.BinaryOp op, BoundExpr l, BoundExpr r) {
        BoundExpr[] pair = comparablePair(l, r, op.symbol());
        return new BoundExpr.Comparison(compareOp(op), pair[0], pair[1]);
    }

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
                return new BoundExpr[] {toFloat(l), toFloat(r)};
            }
            // INT64 vs DECIMAL: promote the integer to DECIMAL(18, s) of the other side.
            if (lk == TypeKind.INT64) {
                return new BoundExpr[] {implicit(l, DataType.decimal(18, rt.scale())), r};
            }
            return new BoundExpr[] {l, implicit(r, DataType.decimal(18, lt.scale()))};
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

    private static BoundExpr implicit(BoundExpr e, DataType t) {
        if (e.type().equals(t)) {
            return e;
        }
        return new BoundExpr.Cast(e, t, true);
    }

    private static BoundExpr toFloat(BoundExpr e) {
        return implicit(e, DataType.FLOAT64);
    }

    private static BoundExpr arithmetic(Expr.BinaryOp op, BoundExpr l, BoundExpr r) {
        ArithOp aop = switch (op) {
            case ADD -> ArithOp.ADD;
            case SUB -> ArithOp.SUB;
            case MUL -> ArithOp.MUL;
            case DIV -> ArithOp.DIV;
            default -> ArithOp.MOD;
        };
        DataType lt = l.type();
        DataType rt = r.type();
        if ((!lt.isNumeric() && !lt.isNull()) || (!rt.isNumeric() && !rt.isNull())) {
            throw typeError("operator %s requires numeric operands, got %s and %s", op.symbol(), lt, rt);
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
            return new BoundExpr.Arithmetic(aop, l, r, DataType.INT64);
        }
        if (aop == ArithOp.MOD) {
            throw typeError("operator %% requires INT64 operands, got %s and %s", lt, rt);
        }
        if (lk == TypeKind.FLOAT64 || rk == TypeKind.FLOAT64 || aop == ArithOp.DIV) {
            return new BoundExpr.Arithmetic(aop, toFloat(l), toFloat(r), DataType.FLOAT64);
        }
        // DECIMAL arithmetic; an INT64 operand becomes DECIMAL(18,0).
        if (lk == TypeKind.INT64) {
            l = implicit(l, DataType.decimal(18, 0));
        }
        if (rk == TypeKind.INT64) {
            r = implicit(r, DataType.decimal(18, 0));
        }
        int s1 = l.type().scale();
        int s2 = r.type().scale();
        int scale = aop == ArithOp.MUL ? s1 + s2 : Math.max(s1, s2);
        if (scale > DataType.MAX_DECIMAL_PRECISION) {
            throw typeError("result scale %d of DECIMAL multiplication exceeds 18", scale);
        }
        return new BoundExpr.Arithmetic(aop, l, r, DataType.decimal(18, scale));
    }

    private BoundExpr cast(Expr.Cast c, AggMode mode) {
        BoundExpr in = bind(c.operand(), mode);
        Expr.TypeName tn = c.type();
        DataType target;
        try {
            target = DataType.fromName(tn.name(), tn.precision(), tn.scale());
        } catch (IllegalArgumentException e) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "unknown type '%s'", tn.name());
        }
        if (!Casts.allowed(in.type(), target)) {
            throw typeError("cannot cast %s to %s", in.type(), target);
        }
        return new BoundExpr.Cast(in, target, false);
    }

    // ---------------------------------------------------------------- functions

    private BoundExpr function(Expr.FunctionCall f, AggMode mode) {
        String name = f.name().toUpperCase(Locale.ROOT);
        AggregateFunction agg = FunctionRegistry.aggregate(name);
        if (agg != null) {
            return aggregate(f, agg, mode);
        }
        if (f.star()) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "'*' is only allowed in COUNT(*)");
        }
        if (f.distinct()) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "DISTINCT is only allowed in aggregates");
        }
        if (functions.isTestFunction(name)) {
            if (f.args().size() != 1) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "PQ_SLEEP takes exactly one argument");
            }
            BoundExpr arg = bind(f.args().get(0), mode);
            if (arg.type().kind() != TypeKind.INT64 && !arg.type().isNull()) {
                throw typeError("PQ_SLEEP requires an INT64 argument, got %s", arg.type());
            }
            return new BoundExpr.Function(name, List.of(arg), DataType.INT64);
        }
        if (functions.isUnimplemented(name)) {
            throw unsupported("function " + name);
        }
        throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "unknown function '%s'", f.name());
    }

    private BoundExpr aggregate(Expr.FunctionCall f, AggregateFunction fn, AggMode mode) {
        String name = fn == AggregateFunction.COUNT ? "COUNT" : fn.name();
        if (mode == AggMode.INSIDE_AGGREGATE) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "aggregate calls cannot be nested");
        }
        if (mode == AggMode.NOT_ALLOWED) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "aggregate %s is not allowed in %s", name, clause);
        }
        if (f.star()) {
            if (fn != AggregateFunction.COUNT) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "'*' is only allowed in COUNT(*)");
            }
            return aggregates.register(new AggregateCall(AggregateFunction.COUNT_STAR, null, false, DataType.INT64));
        }
        if (f.args().size() != 1) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "%s takes exactly one argument", name);
        }
        if (f.distinct()) {
            throw unsupported(name + "(DISTINCT ...)");
        }
        BoundExpr arg = bind(f.args().get(0), AggMode.INSIDE_AGGREGATE);
        DataType t = arg.type();
        DataType result = switch (fn) {
            case COUNT -> DataType.INT64;
            case SUM -> {
                if (!t.isNumeric() && !t.isNull()) {
                    throw typeError("SUM requires a numeric argument, got %s", t);
                }
                yield switch (t.kind()) {
                    case DECIMAL -> DataType.decimal(18, t.scale());
                    case FLOAT64 -> DataType.FLOAT64;
                    default -> DataType.INT64;
                };
            }
            case AVG -> {
                if (!t.isNumeric() && !t.isNull()) {
                    throw typeError("AVG requires a numeric argument, got %s", t);
                }
                yield DataType.FLOAT64;
            }
            case MIN, MAX -> t;
            case COUNT_STAR -> throw new IllegalStateException();
        };
        return aggregates.register(new AggregateCall(fn, arg, false, result));
    }
}
