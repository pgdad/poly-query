package polyquery.exec;

import java.math.BigInteger;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.function.BinaryOperator;
import java.util.function.Function;
import java.util.function.Supplier;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.plan.LogicalPlan;
import polyquery.types.Casts;
import polyquery.types.DataType;
import polyquery.types.Decimals;
import polyquery.types.TypeKind;
import polyquery.types.Values;

/** Compiles {@link BoundExpr} trees into closures (types.md §4–§6 runtime semantics). */
public final class ExpressionCompiler {
    private final ExecContext ctx;
    private final Function<LogicalPlan, Operator> subqueryBuilder;
    /** Holder of the current shared operand while compiling the comparisons that use it. */
    private Object[] placeholderCell;

    /**
     * @param subqueryBuilder builds an executable operator tree for a subquery's logical plan
     */
    public ExpressionCompiler(ExecContext ctx, Function<LogicalPlan, Operator> subqueryBuilder) {
        this.ctx = ctx;
        this.subqueryBuilder = subqueryBuilder;
    }

    static PolyQueryException overflow() {
        return new PolyQueryException(ErrorCode.NUMERIC_OVERFLOW, "numeric overflow");
    }

    static PolyQueryException divisionByZero() {
        return new PolyQueryException(ErrorCode.DIVISION_BY_ZERO, "division by zero");
    }

    public Evaluator compile(BoundExpr e) {
        return switch (e) {
            case BoundExpr.ColumnRef c -> {
                int i = c.index();
                yield row -> row[i];
            }
            case BoundExpr.AggregateRef a -> {
                int i = a.index();
                yield row -> row[i];
            }
            case BoundExpr.OuterRef o -> {
                int f = o.frame();
                int i = o.index();
                yield row -> ctx.frame(f)[i];
            }
            case BoundExpr.Placeholder p -> {
                Object[] cell = placeholderCell;
                if (cell == null) {
                    throw new IllegalStateException("placeholder outside of its operand context");
                }
                yield row -> cell[0];
            }
            case BoundExpr.Literal l -> {
                Object v = l.value();
                yield row -> v;
            }
            case BoundExpr.Cast c -> cast(c);
            case BoundExpr.Negate n -> negate(n);
            case BoundExpr.Not n -> {
                Evaluator in = compile(n.input());
                yield row -> not(in.eval(row));
            }
            case BoundExpr.IsNull n -> {
                Evaluator in = compile(n.input());
                boolean neg = n.negated();
                yield row -> (in.eval(row) == null) != neg;
            }
            case BoundExpr.And a -> and(compile(a.left()), compile(a.right()));
            case BoundExpr.Or o -> or(compile(o.left()), compile(o.right()));
            case BoundExpr.Concat c -> {
                Evaluator l = compile(c.left());
                Evaluator r = compile(c.right());
                yield row -> {
                    Object a = l.eval(row);
                    if (a == null) {
                        return null;
                    }
                    Object b = r.eval(row);
                    return b == null ? null : (String) a + (String) b;
                };
            }
            case BoundExpr.Arithmetic a -> arithmetic(a);
            case BoundExpr.Comparison c -> comparison(c);
            case BoundExpr.Function f -> function(f);
            case BoundExpr.Like l -> like(l);
            case BoundExpr.InList i -> inList(i);
            case BoundExpr.Between b -> between(b);
            case BoundExpr.Case c -> caseExpr(c);
            case BoundExpr.NullIf n -> nullIf(n);
            case BoundExpr.ScalarSubquery s -> {
                SubqueryRunner runner = new SubqueryRunner(s, s.subquery(), subqueryBuilder, ctx);
                yield runner::scalar;
            }
            case BoundExpr.Exists x -> {
                SubqueryRunner runner = new SubqueryRunner(x, x.subquery(), subqueryBuilder, ctx);
                yield runner::exists;
            }
            case BoundExpr.InSubquery i -> inSubquery(i);
        };
    }

    /**
     * Compiles an expression whose {@link BoundExpr.Placeholder}s read {@code cell[0]} (used to
     * apply row-level code to values computed elsewhere, e.g. by vectorized execution).
     */
    public Evaluator compileWithOperand(BoundExpr e, Object[] cell) {
        return withPlaceholder(cell, List.of(e))[0];
    }

    /** Compiles {@code exprs} that read the shared operand through placeholders. */
    private Evaluator[] withPlaceholder(Object[] cell, List<BoundExpr> exprs) {
        Object[] saved = placeholderCell;
        placeholderCell = cell;
        try {
            Evaluator[] out = new Evaluator[exprs.size()];
            for (int i = 0; i < out.length; i++) {
                out[i] = compile(exprs.get(i));
            }
            return out;
        } finally {
            placeholderCell = saved;
        }
    }

    private static Object not(Object v) {
        return v == null ? null : !(Boolean) v;
    }

    private Evaluator cast(BoundExpr.Cast c) {
        Evaluator in = compile(c.input());
        DataType from = c.input().type();
        DataType to = c.type();
        if (from.equals(to)) {
            return in;
        }
        return row -> Casts.cast(in.eval(row), from, to);
    }

    private Evaluator negate(BoundExpr.Negate n) {
        Evaluator in = compile(n.input());
        return switch (n.type().kind()) {
            case INT64 -> row -> {
                Object v = in.eval(row);
                if (v == null) {
                    return null;
                }
                long x = (Long) v;
                if (x == Long.MIN_VALUE) {
                    throw overflow();
                }
                return -x;
            };
            case DECIMAL -> row -> {
                Object v = in.eval(row);
                if (v == null) {
                    return null;
                }
                return v instanceof BigInteger b ? b.negate() : (Object) (-(Long) v);
            };
            case FLOAT64 -> row -> {
                Object v = in.eval(row);
                return v == null ? null : -(Double) v;
            };
            default -> row -> null;
        };
    }

    private static Evaluator and(Evaluator l, Evaluator r) {
        return row -> and(l.eval(row), r, row);
    }

    private static Object and(Object a, Evaluator r, Object[] row) {
        if (Boolean.FALSE.equals(a)) {
            return Boolean.FALSE;
        }
        Object b = r.eval(row);
        if (Boolean.FALSE.equals(b)) {
            return Boolean.FALSE;
        }
        return a == null || b == null ? null : Boolean.TRUE;
    }

    private static Evaluator or(Evaluator l, Evaluator r) {
        return row -> {
            Object a = l.eval(row);
            if (Boolean.TRUE.equals(a)) {
                return Boolean.TRUE;
            }
            Object b = r.eval(row);
            if (Boolean.TRUE.equals(b)) {
                return Boolean.TRUE;
            }
            return a == null || b == null ? null : Boolean.FALSE;
        };
    }

    // ---------------------------------------------------------------- arithmetic

    private interface LongOp {
        long apply(long a, long b);
    }

    private interface DoubleOp {
        double apply(double a, double b);
    }

    private Evaluator arithmetic(BoundExpr.Arithmetic a) {
        Evaluator l = compile(a.left());
        Evaluator r = compile(a.right());
        DataType type = a.type();
        return switch (type.kind()) {
            case INT64 -> longArith(l, r, switch (a.op()) {
                case ADD -> (x, y) -> {
                    try {
                        return Math.addExact(x, y);
                    } catch (ArithmeticException ex) {
                        throw overflow();
                    }
                };
                case SUB -> (x, y) -> {
                    try {
                        return Math.subtractExact(x, y);
                    } catch (ArithmeticException ex) {
                        throw overflow();
                    }
                };
                case MUL -> (x, y) -> {
                    try {
                        return Math.multiplyExact(x, y);
                    } catch (ArithmeticException ex) {
                        throw overflow();
                    }
                };
                case DIV -> (x, y) -> {
                    if (y == 0) {
                        throw divisionByZero();
                    }
                    if (x == Long.MIN_VALUE && y == -1) {
                        throw overflow();
                    }
                    return x / y;
                };
                case MOD -> (x, y) -> {
                    if (y == 0) {
                        throw divisionByZero();
                    }
                    return y == -1 ? 0 : x % y;
                };
            });
            case DECIMAL -> {
                int s1 = a.left().type().scale();
                int s2 = a.right().type().scale();
                int rs = type.scale();
                if (type.isWideDecimal()) {
                    yield wideArith(l, r, type, switch (a.op()) {
                        case ADD -> (x, y) -> Decimals.addExact(x, s1, y, s2, rs);
                        case SUB -> (x, y) -> Decimals.subtractExact(x, s1, y, s2, rs);
                        case MUL -> Decimals::multiplyExact;
                        default -> throw new IllegalStateException("DECIMAL " + a.op());
                    });
                }
                yield longArith(l, r, switch (a.op()) {
                    case ADD -> (x, y) -> Decimals.add(x, s1, y, s2, rs);
                    case SUB -> (x, y) -> Decimals.subtract(x, s1, y, s2, rs);
                    case MUL -> Decimals::multiply;
                    default -> throw new IllegalStateException("DECIMAL " + a.op());
                });
            }
            case FLOAT64 -> doubleArith(l, r, switch (a.op()) {
                case ADD -> (x, y) -> x + y;
                case SUB -> (x, y) -> x - y;
                case MUL -> (x, y) -> x * y;
                case DIV -> (x, y) -> {
                    if (y == 0.0) {
                        throw divisionByZero();
                    }
                    return x / y;
                };
                case MOD -> throw new IllegalStateException("FLOAT64 %");
            });
            default -> row -> null;
        };
    }

    private static Evaluator longArith(Evaluator l, Evaluator r, LongOp op) {
        return row -> {
            Object a = l.eval(row);
            if (a == null) {
                return null;
            }
            Object b = r.eval(row);
            if (b == null) {
                return null;
            }
            return op.apply((Long) a, (Long) b);
        };
    }

    /** Wide DECIMAL arithmetic: exact BigInteger result, checked against the result precision. */
    private static Evaluator wideArith(Evaluator l, Evaluator r, DataType type, BinaryOperator<Object> exact) {
        return row -> {
            Object a = l.eval(row);
            if (a == null) {
                return null;
            }
            Object b = r.eval(row);
            if (b == null) {
                return null;
            }
            return Decimals.value((BigInteger) exact.apply(a, b), type);
        };
    }

    private static Evaluator doubleArith(Evaluator l, Evaluator r, DoubleOp op) {
        return row -> {
            Object a = l.eval(row);
            if (a == null) {
                return null;
            }
            Object b = r.eval(row);
            if (b == null) {
                return null;
            }
            double v = op.apply((Double) a, (Double) b);
            if (Double.isInfinite(v) || Double.isNaN(v)) {
                throw overflow();
            }
            return v;
        };
    }

    // ---------------------------------------------------------------- comparison

    private interface Comparer {
        int compare(Object a, Object b);
    }

    /** Comparator for operands of the given (comparable) types. */
    private static Comparer comparer(DataType lt, DataType rt) {
        if (HashKeys.mixedExact(lt, rt)) {
            int s1 = lt.exactScale();
            int s2 = rt.exactScale();
            return (a, b) -> Decimals.compare(a, s1, b, s2);
        }
        return (a, b) -> Values.compare(a, b, lt);
    }

    private Evaluator comparison(BoundExpr.Comparison c) {
        Evaluator l = compile(c.left());
        Evaluator r = compile(c.right());
        DataType lt = c.left().type();
        DataType rt = c.right().type();
        if (lt.isNull() || rt.isNull()) {
            return row -> null;
        }
        Comparer cmp = comparer(lt, rt);
        return switch (c.op()) {
            case EQ -> compareWith(l, r, cmp, x -> x == 0);
            case NEQ -> compareWith(l, r, cmp, x -> x != 0);
            case LT -> compareWith(l, r, cmp, x -> x < 0);
            case LE -> compareWith(l, r, cmp, x -> x <= 0);
            case GT -> compareWith(l, r, cmp, x -> x > 0);
            case GE -> compareWith(l, r, cmp, x -> x >= 0);
        };
    }

    private interface IntPredicate {
        boolean test(int x);
    }

    private static Evaluator compareWith(Evaluator l, Evaluator r, Comparer cmp, IntPredicate p) {
        return row -> {
            Object a = l.eval(row);
            if (a == null) {
                return null;
            }
            Object b = r.eval(row);
            if (b == null) {
                return null;
            }
            return p.test(cmp.compare(a, b));
        };
    }

    // ---------------------------------------------------------------- predicates

    private Evaluator like(BoundExpr.Like l) {
        Evaluator s = compile(l.operand());
        boolean neg = l.negated();
        if (l.pattern() instanceof BoundExpr.Literal lit) {
            if (lit.value() == null) {
                return row -> null;
            }
            LikeMatcher m = new LikeMatcher((String) lit.value());
            return row -> {
                Object v = s.eval(row);
                return v == null ? null : m.matches((String) v) != neg;
            };
        }
        Evaluator p = compile(l.pattern());
        return new Evaluator() {
            private String lastPattern;
            private LikeMatcher matcher;

            @Override
            public Object eval(Object[] row) {
                Object v = s.eval(row);
                if (v == null) {
                    return null;
                }
                Object pv = p.eval(row);
                if (pv == null) {
                    return null;
                }
                if (!pv.equals(lastPattern)) {
                    lastPattern = (String) pv;
                    matcher = new LikeMatcher(lastPattern);
                }
                return matcher.matches((String) v) != neg;
            }
        };
    }

    private Evaluator inList(BoundExpr.InList in) {
        Evaluator x = compile(in.operand());
        boolean neg = in.negated();
        Set<Object> constants = constantSet(in);
        if (constants != null) {
            boolean hasNull = constants.remove(null);
            DataType t = in.operand().type();
            return row -> {
                Object v = x.eval(row);
                if (v == null) {
                    return null;
                }
                if (constants.contains(HashKeys.normalize(v, t))) {
                    return !neg;
                }
                return hasNull ? null : neg;
            };
        }
        Object[] cell = new Object[1];
        Evaluator[] cmps = withPlaceholder(cell, in.comparisons());
        return row -> {
            cell[0] = x.eval(row);
            boolean sawNull = false;
            for (Evaluator c : cmps) {
                Object r = c.eval(row);
                if (Boolean.TRUE.equals(r)) {
                    return !neg;
                }
                sawNull |= r == null;
            }
            return sawNull ? null : neg;
        };
    }

    /**
     * Hash set of the list's values if every item is a literal of the operand's own type (no
     * coercion involved), else null. Contains null if the list contains NULL.
     */
    private static Set<Object> constantSet(BoundExpr.InList in) {
        DataType t = in.operand().type();
        if (t.isNull()) {
            return null;
        }
        Set<Object> out = new HashSet<>();
        for (BoundExpr c : in.comparisons()) {
            if (!(c instanceof BoundExpr.Comparison cmp && cmp.left() instanceof BoundExpr.Placeholder
                    && cmp.right() instanceof BoundExpr.Literal lit)) {
                return null;
            }
            if (lit.value() == null) {
                out.add(null);
                continue;
            }
            if (lit.type().kind() != t.kind() || lit.type().scale() != t.scale()) {
                return null;
            }
            out.add(HashKeys.normalize(lit.value(), t));
        }
        return out;
    }

    private Evaluator between(BoundExpr.Between b) {
        Evaluator x = compile(b.operand());
        Object[] cell = new Object[1];
        Evaluator[] bounds = withPlaceholder(cell, List.of(b.lower(), b.upper()));
        boolean neg = b.negated();
        return row -> {
            cell[0] = x.eval(row);
            Object r = and(bounds[0].eval(row), bounds[1], row);
            return neg ? not(r) : r;
        };
    }

    private Evaluator caseExpr(BoundExpr.Case c) {
        Evaluator[] results = compileAll(c.results());
        Evaluator otherwise = c.elseResult() == null ? row -> null : compile(c.elseResult());
        if (c.operand() == null) {
            Evaluator[] conds = compileAll(c.conditions());
            return row -> {
                for (int i = 0; i < conds.length; i++) {
                    if (Boolean.TRUE.equals(conds[i].eval(row))) {
                        return results[i].eval(row);
                    }
                }
                return otherwise.eval(row);
            };
        }
        Evaluator x = compile(c.operand());
        Object[] cell = new Object[1];
        Evaluator[] conds = withPlaceholder(cell, c.conditions());
        return row -> {
            cell[0] = x.eval(row);
            for (int i = 0; i < conds.length; i++) {
                if (Boolean.TRUE.equals(conds[i].eval(row))) {
                    return results[i].eval(row);
                }
            }
            return otherwise.eval(row);
        };
    }

    private Evaluator nullIf(BoundExpr.NullIf n) {
        Evaluator a = compile(n.operand());
        Object[] cell = new Object[1];
        Evaluator eq = withPlaceholder(cell, List.of(n.equality()))[0];
        return row -> {
            Object v = a.eval(row);
            cell[0] = v;
            return Boolean.TRUE.equals(eq.eval(row)) ? null : v;
        };
    }

    private Evaluator inSubquery(BoundExpr.InSubquery in) {
        Evaluator x = compile(in.operand());
        Function<Object[], ValueSet> values = valueSet(in);
        DataType t = in.operand().type();
        boolean neg = in.negated();
        return row -> {
            Object v = x.eval(row);
            ValueSet set = values.apply(row);
            if (set.isEmpty()) {
                return neg;
            }
            if (v == null) {
                return null;
            }
            if (set.contains(HashKeys.normalize(v, t))) {
                return !neg;
            }
            return set.hasNull() ? null : neg;
        };
    }

    /** The value set of an IN subquery for the current row (outer references read from it). */
    private Function<Object[], ValueSet> valueSet(BoundExpr.InSubquery in) {
        Object[] cell = new Object[1];
        Evaluator valueCast = withPlaceholder(cell, List.of(in.valueCast()))[0];
        DataType vt = in.valueCast().type();
        SubqueryRunner runner = new SubqueryRunner(in, in.subquery(), subqueryBuilder, ctx);
        return row -> runner.valueSet(row, value -> {
            cell[0] = value;
            Object c = valueCast.eval(row);
            return c == null ? null : HashKeys.normalize(c, vt);
        });
    }

    /**
     * The result of an uncorrelated subquery expression ({@code ScalarSubquery}: its value,
     * {@code Exists}: a Boolean, {@code InSubquery}: a {@link ValueSet}), evaluated on the first
     * call and shared with every other compiled copy of the expression (see
     * {@link ExecContext#subqueryResult}).
     */
    public Supplier<Object> uncorrelatedSubquery(BoundExpr e) {
        Object[] noRow = new Object[0];
        return switch (e) {
            case BoundExpr.ScalarSubquery s when !s.subquery().correlated() -> {
                SubqueryRunner runner = new SubqueryRunner(s, s.subquery(), subqueryBuilder, ctx);
                yield () -> runner.scalar(noRow);
            }
            case BoundExpr.Exists x when !x.subquery().correlated() -> {
                SubqueryRunner runner = new SubqueryRunner(x, x.subquery(), subqueryBuilder, ctx);
                yield () -> runner.exists(noRow);
            }
            case BoundExpr.InSubquery i when !i.subquery().correlated() -> {
                Function<Object[], ValueSet> values = valueSet(i);
                yield () -> values.apply(noRow);
            }
            default -> throw new IllegalArgumentException("not an uncorrelated subquery: " + e);
        };
    }

    /**
     * Evaluates every uncorrelated subquery in {@code e} now (on this thread), so that parallel
     * workers find their results. A data error is not raised here but kept for the rows that
     * evaluate the subquery.
     */
    public void precomputeSubqueries(BoundExpr e) {
        List<BoundExpr> found = new java.util.ArrayList<>();
        polyquery.plan.BoundExprs.any(e, x -> {
            polyquery.plan.Subquery sq = polyquery.plan.BoundExprs.subqueryOf(x);
            if (sq != null && !sq.correlated()) {
                found.add(x);
            }
            return false;
        });
        for (BoundExpr x : found) {
            if (ctx.hasSubqueryResult(x)) {
                continue;
            }
            try {
                uncorrelatedSubquery(x).get();
            } catch (PolyQueryException ex) {
                if (!ExecContext.isDataError(ex)) {
                    throw ex;
                }
            }
        }
    }

    private Evaluator[] compileAll(List<BoundExpr> exprs) {
        Evaluator[] out = new Evaluator[exprs.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = compile(exprs.get(i));
        }
        return out;
    }

    // ---------------------------------------------------------------- functions

    private Evaluator function(BoundExpr.Function f) {
        return ScalarFunctions.compile(f, compileAll(f.args()), ctx);
    }
}
