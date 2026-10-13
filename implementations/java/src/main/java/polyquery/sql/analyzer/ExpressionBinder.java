package polyquery.sql.analyzer;

import static polyquery.sql.analyzer.TypeCoercion.typeError;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import polyquery.common.Checkpoint;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.AggregateCall;
import polyquery.plan.AggregateCall.AggregateFunction;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExpr.ArithOp;
import polyquery.plan.BoundExpr.CompareOp;
import polyquery.plan.Subquery;
import polyquery.sql.ast.Expr;
import polyquery.sql.ast.Query;
import polyquery.types.Casts;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.TypeKind;

/** Resolves names and assigns types to expressions (types.md §2–§8, semantics.md §8, §11–§13). */
final class ExpressionBinder {
    /** Where aggregate calls may appear in the expression being bound. */
    enum AggMode { NOT_ALLOWED, ALLOWED, INSIDE_AGGREGATE }

    /** Plans nested queries on behalf of the binder. */
    interface SubqueryPlanner {
        /** Analyzes and plans {@code q} as a subquery evaluated within {@code parent}. */
        Analyzer.PlannedQuery plan(Query q, Scope parent);
    }

    private static final BigInteger LONG_MIN = BigInteger.valueOf(Long.MIN_VALUE);
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);

    private final Scope scope;
    private final FunctionRegistry functions;
    private final AggregateCollector aggregates;
    private final String clause;
    private final SubqueryPlanner subqueries;

    ExpressionBinder(Scope scope, FunctionRegistry functions, AggregateCollector aggregates, String clause,
                     SubqueryPlanner subqueries) {
        this.scope = scope;
        this.functions = functions;
        this.aggregates = aggregates;
        this.clause = clause;
        this.subqueries = subqueries;
    }

    BoundExpr bind(Expr e) {
        return bind(e, aggregates == null ? AggMode.NOT_ALLOWED : AggMode.ALLOWED);
    }

    private static PolyQueryException semantic(String fmt, Object... args) {
        return PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, fmt, args);
    }

    private BoundExpr bind(Expr e, AggMode mode) {
        try {
            Checkpoint.poll();
            return bindInner(e, mode);
        } catch (PolyQueryException ex) {
            if (!ex.details().containsKey("line") && ex.code() != ErrorCode.UNSUPPORTED
                    && ex.code() != ErrorCode.TIMEOUT && ex.code() != ErrorCode.CANCELLED) {
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
            case Expr.Between b -> between(b, mode);
            case Expr.InList i -> inList(i, mode);
            case Expr.Like l -> like(l, mode);
            case Expr.Case c -> caseExpr(c, mode);
            case Expr.Exists x -> new BoundExpr.Exists(subquery(x.query()));
            case Expr.ScalarSubquery s -> scalarSubquery(s);
            case Expr.InSubquery i -> inSubquery(i, mode);
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
        DataType type = DataType.decimal(precision, scale);
        BigInteger unscaled = all.isEmpty() ? BigInteger.ZERO : new BigInteger(all);
        if (negative) {
            unscaled = unscaled.negate();
        }
        return new BoundExpr.Literal(type.isWideDecimal() ? unscaled : (Object) unscaled.longValue(), type);
    }

    private static BoundExpr.Literal floatLiteral(String text) {
        double d = Double.parseDouble(text);
        if (Double.isInfinite(d)) {
            throw PolyQueryException.of(ErrorCode.NUMERIC_OVERFLOW, "float literal %s is out of range", text);
        }
        return new BoundExpr.Literal(d == 0.0 ? 0.0 : d, DataType.FLOAT64);
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
            TypeCoercion.requireBoolean(t, "NOT");
            return new BoundExpr.Not(in);
        }
        if (!t.isNumeric() && !t.isNull()) {
            throw typeError("unary %s requires a numeric operand, got %s", u.op() == Expr.UnaryOp.NEG ? "-" : "+", t);
        }
        return u.op() == Expr.UnaryOp.NEG ? new BoundExpr.Negate(in, t) : in;
    }

    private BoundExpr binary(Expr.Binary b, AggMode mode) {
        BoundExpr l = bind(b.left(), mode);
        BoundExpr r = bind(b.right(), mode);
        return switch (b.op()) {
            case AND, OR -> {
                TypeCoercion.requireBoolean(l.type(), b.op().name());
                TypeCoercion.requireBoolean(r.type(), b.op().name());
                yield b.op() == Expr.BinaryOp.AND ? new BoundExpr.And(l, r) : new BoundExpr.Or(l, r);
            }
            case CONCAT -> {
                requireString(l.type(), "||");
                requireString(r.type(), "||");
                yield new BoundExpr.Concat(l, r);
            }
            case EQ, NEQ, LT, LE, GT, GE -> TypeCoercion.comparison(compareOp(b.op()), l, r, b.op().symbol());
            case ADD -> TypeCoercion.arithmetic(ArithOp.ADD, l, r, "+");
            case SUB -> TypeCoercion.arithmetic(ArithOp.SUB, l, r, "-");
            case MUL -> TypeCoercion.arithmetic(ArithOp.MUL, l, r, "*");
            case DIV -> TypeCoercion.arithmetic(ArithOp.DIV, l, r, "/");
            case MOD -> TypeCoercion.arithmetic(ArithOp.MOD, l, r, "%");
        };
    }

    private static void requireString(DataType t, String what) {
        if (t.kind() != TypeKind.STRING && !t.isNull()) {
            throw typeError("%s requires STRING operands, got %s", what, t);
        }
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

    private BoundExpr cast(Expr.Cast c, AggMode mode) {
        BoundExpr in = bind(c.operand(), mode);
        Expr.TypeName tn = c.type();
        DataType target;
        try {
            target = DataType.fromName(tn.name(), tn.precision(), tn.scale());
        } catch (IllegalArgumentException e) {
            throw semantic("unknown type '%s'", tn.name());
        }
        if (!Casts.allowed(in.type(), target)) {
            throw typeError("cannot cast %s to %s", in.type(), target);
        }
        return new BoundExpr.Cast(in, target, false);
    }

    private BoundExpr between(Expr.Between b, AggMode mode) {
        BoundExpr x = bind(b.operand(), mode);
        BoundExpr low = bind(b.low(), mode);
        BoundExpr high = bind(b.high(), mode);
        BoundExpr p = new BoundExpr.Placeholder(x.type());
        return new BoundExpr.Between(x, TypeCoercion.comparison(CompareOp.GE, p, low, "BETWEEN"),
                TypeCoercion.comparison(CompareOp.LE, p, high, "BETWEEN"), b.negated());
    }

    private BoundExpr inList(Expr.InList i, AggMode mode) {
        BoundExpr x = bind(i.operand(), mode);
        BoundExpr p = new BoundExpr.Placeholder(x.type());
        List<BoundExpr> comparisons = new ArrayList<>();
        for (Expr item : i.items()) {
            comparisons.add(TypeCoercion.comparison(CompareOp.EQ, p, bind(item, mode), "IN"));
        }
        return new BoundExpr.InList(x, List.copyOf(comparisons), i.negated());
    }

    private BoundExpr like(Expr.Like l, AggMode mode) {
        BoundExpr s = bind(l.operand(), mode);
        BoundExpr p = bind(l.pattern(), mode);
        requireString(s.type(), "LIKE");
        requireString(p.type(), "LIKE");
        return new BoundExpr.Like(s, p, l.negated());
    }

    private BoundExpr caseExpr(Expr.Case c, AggMode mode) {
        BoundExpr operand = c.operand() == null ? null : bind(c.operand(), mode);
        List<BoundExpr> conditions = new ArrayList<>();
        List<BoundExpr> results = new ArrayList<>();
        List<DataType> types = new ArrayList<>();
        for (Expr.When w : c.whens()) {
            if (operand != null) {
                BoundExpr p = new BoundExpr.Placeholder(operand.type());
                conditions.add(TypeCoercion.comparison(CompareOp.EQ, p, bind(w.condition(), mode), "CASE"));
            } else {
                BoundExpr cond = bind(w.condition(), mode);
                Analyzer.requireCondition(cond, "CASE WHEN");
                conditions.add(cond);
            }
            BoundExpr r = bind(w.result(), mode);
            results.add(r);
            types.add(r.type());
        }
        BoundExpr elseResult = c.elseExpr() == null ? null : bind(c.elseExpr(), mode);
        if (elseResult != null) {
            types.add(elseResult.type());
        }
        DataType t = TypeCoercion.commonType(types, "CASE");
        List<BoundExpr> cast = TypeCoercion.castAll(results, t);
        if (elseResult != null && !t.isNull()) {
            elseResult = TypeCoercion.implicit(elseResult, t);
        }
        return new BoundExpr.Case(operand, List.copyOf(conditions), cast, elseResult, t);
    }

    // ---------------------------------------------------------------- subqueries

    private Subquery subquery(Query q) {
        Analyzer.PlannedQuery pq = subqueries.plan(q, scope);
        return new Subquery(pq.plan(), scope.frame(), pq.externalRefs());
    }

    private Analyzer.PlannedQuery singleColumn(Query q, String what) {
        Analyzer.PlannedQuery pq = subqueries.plan(q, scope);
        if (pq.columns().size() != 1) {
            throw semantic("%s must return exactly one column, got %d", what, pq.columns().size());
        }
        return pq;
    }

    private BoundExpr scalarSubquery(Expr.ScalarSubquery s) {
        Analyzer.PlannedQuery pq = singleColumn(s.query(), "scalar subquery");
        return new BoundExpr.ScalarSubquery(new Subquery(pq.plan(), scope.frame(), pq.externalRefs()),
                pq.columns().get(0).type());
    }

    private BoundExpr inSubquery(Expr.InSubquery i, AggMode mode) {
        BoundExpr x = bind(i.operand(), mode);
        Analyzer.PlannedQuery pq = singleColumn(i.query(), "IN subquery");
        BoundExpr[] pair = TypeCoercion.comparablePair(x, new BoundExpr.Placeholder(pq.columns().get(0).type()), "IN");
        return new BoundExpr.InSubquery(pair[0], new Subquery(pq.plan(), scope.frame(), pq.externalRefs()), pair[1],
                i.negated());
    }

    // ---------------------------------------------------------------- functions

    private BoundExpr function(Expr.FunctionCall f, AggMode mode) {
        String name = f.name().toUpperCase(Locale.ROOT);
        AggregateFunction agg = FunctionRegistry.aggregate(name);
        if (agg != null) {
            return aggregate(f, agg, mode);
        }
        if (f.star()) {
            throw semantic("'*' is only allowed in COUNT(*)");
        }
        if (f.distinct()) {
            throw semantic("DISTINCT is only allowed in aggregates");
        }
        if (functions.isTestFunction(name)) {
            if (f.args().size() != 1) {
                throw semantic("PQ_SLEEP takes exactly one argument");
            }
            BoundExpr arg = bind(f.args().get(0), mode);
            if (arg.type().kind() != TypeKind.INT64 && !arg.type().isNull()) {
                throw typeError("PQ_SLEEP requires an INT64 argument, got %s", arg.type());
            }
            return new BoundExpr.Function(name, List.of(arg), DataType.INT64);
        }
        if (!FunctionRegistry.isScalar(name)) {
            throw semantic("unknown function '%s'", f.name());
        }
        FunctionRegistry.checkArity(name, f.args().size());
        List<BoundExpr> args = new ArrayList<>();
        for (Expr a : f.args()) {
            args.add(bind(a, mode));
        }
        return ScalarFunctionBinder.bind(name, args);
    }

    private BoundExpr aggregate(Expr.FunctionCall f, AggregateFunction fn, AggMode mode) {
        String name = fn == AggregateFunction.COUNT ? "COUNT" : fn.name();
        if (mode == AggMode.INSIDE_AGGREGATE) {
            throw semantic("aggregate calls cannot be nested");
        }
        if (mode == AggMode.NOT_ALLOWED) {
            throw semantic("aggregate %s is not allowed in %s", name, clause);
        }
        if (f.star()) {
            if (fn != AggregateFunction.COUNT) {
                throw semantic("'*' is only allowed in COUNT(*)");
            }
            return aggregates.register(new AggregateCall(AggregateFunction.COUNT_STAR, null, false, DataType.INT64));
        }
        if (f.args().size() != 1) {
            throw semantic("%s takes exactly one argument", name);
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
                    case DECIMAL -> DataType.decimal(TypeCoercion.resultPrecision(t), t.scale());
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
        // MIN/MAX(DISTINCT x) is the same as MIN/MAX(x).
        boolean distinct = f.distinct() && fn != AggregateFunction.MIN && fn != AggregateFunction.MAX;
        return aggregates.register(new AggregateCall(fn, arg, distinct, result));
    }
}
