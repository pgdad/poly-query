package polyquery.exec;

import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.types.Casts;
import polyquery.types.DataType;
import polyquery.types.Decimals;
import polyquery.types.TypeKind;
import polyquery.types.Values;

/** Compiles {@link BoundExpr} trees into closures (types.md §4–§6 runtime semantics). */
public final class ExpressionCompiler {
    private final ExecContext ctx;

    public ExpressionCompiler(ExecContext ctx) {
        this.ctx = ctx;
    }

    private static PolyQueryException overflow() {
        return new PolyQueryException(ErrorCode.NUMERIC_OVERFLOW, "numeric overflow");
    }

    private static PolyQueryException divisionByZero() {
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
            case BoundExpr.Literal l -> {
                Object v = l.value();
                yield row -> v;
            }
            case BoundExpr.Cast c -> cast(c);
            case BoundExpr.Negate n -> negate(n);
            case BoundExpr.Not n -> {
                Evaluator in = compile(n.input());
                yield row -> {
                    Object v = in.eval(row);
                    return v == null ? null : !(Boolean) v;
                };
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
        };
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
                return v == null ? null : -(Long) v;
            };
            case FLOAT64 -> row -> {
                Object v = in.eval(row);
                return v == null ? null : -(Double) v;
            };
            default -> row -> null;
        };
    }

    private static Evaluator and(Evaluator l, Evaluator r) {
        return row -> {
            Object a = l.eval(row);
            if (Boolean.FALSE.equals(a)) {
                return Boolean.FALSE;
            }
            Object b = r.eval(row);
            if (Boolean.FALSE.equals(b)) {
                return Boolean.FALSE;
            }
            return a == null || b == null ? null : Boolean.TRUE;
        };
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

    private Evaluator comparison(BoundExpr.Comparison c) {
        Evaluator l = compile(c.left());
        Evaluator r = compile(c.right());
        DataType lt = c.left().type();
        DataType rt = c.right().type();
        if (lt.isNull() || rt.isNull()) {
            return row -> null;
        }
        Comparer cmp;
        if (lt.kind() == TypeKind.DECIMAL && rt.kind() == TypeKind.DECIMAL && lt.scale() != rt.scale()) {
            int s1 = lt.scale();
            int s2 = rt.scale();
            cmp = (a, b) -> Decimals.compare((Long) a, s1, (Long) b, s2);
        } else {
            cmp = (a, b) -> Values.compare(a, b, lt);
        }
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

    // ---------------------------------------------------------------- functions

    private Evaluator function(BoundExpr.Function f) {
        List<BoundExpr> args = f.args();
        if (f.name().equals("PQ_SLEEP")) {
            Evaluator arg = compile(args.get(0));
            return row -> {
                Object v = arg.eval(row);
                if (v == null) {
                    return null;
                }
                long ms = (Long) v;
                if (ms < 0) {
                    throw new PolyQueryException(ErrorCode.INVALID_ARGUMENT, "PQ_SLEEP requires a non-negative argument");
                }
                sleep(ms);
                return ms;
            };
        }
        throw new PolyQueryException(ErrorCode.UNSUPPORTED, "function " + f.name() + " is not supported");
    }

    /** Sleeps in small slices so that timeouts/cancellation are observed within a few ms. */
    private void sleep(long ms) {
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
