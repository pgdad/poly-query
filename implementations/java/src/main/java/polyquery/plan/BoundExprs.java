package polyquery.plan;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import java.util.function.Predicate;

/** Generic traversal and rewriting helpers for {@link BoundExpr} trees. Subquery plans are opaque. */
public final class BoundExprs {
    private BoundExprs() {
    }

    /** Direct child expressions, in a fixed order understood by {@link #withChildren}. */
    public static List<BoundExpr> children(BoundExpr e) {
        return switch (e) {
            case BoundExpr.ColumnRef c -> List.of();
            case BoundExpr.OuterRef o -> List.of();
            case BoundExpr.Placeholder p -> List.of();
            case BoundExpr.Literal l -> List.of();
            case BoundExpr.AggregateRef a -> List.of();
            case BoundExpr.ScalarSubquery s -> List.of();
            case BoundExpr.Exists x -> List.of();
            case BoundExpr.Cast c -> List.of(c.input());
            case BoundExpr.Negate n -> List.of(n.input());
            case BoundExpr.Not n -> List.of(n.input());
            case BoundExpr.IsNull n -> List.of(n.input());
            case BoundExpr.Arithmetic a -> List.of(a.left(), a.right());
            case BoundExpr.Comparison c -> List.of(c.left(), c.right());
            case BoundExpr.And a -> List.of(a.left(), a.right());
            case BoundExpr.Or o -> List.of(o.left(), o.right());
            case BoundExpr.Concat c -> List.of(c.left(), c.right());
            case BoundExpr.Like l -> List.of(l.operand(), l.pattern());
            case BoundExpr.InList i -> {
                List<BoundExpr> out = new ArrayList<>();
                out.add(i.operand());
                out.addAll(i.comparisons());
                yield out;
            }
            case BoundExpr.Between b -> List.of(b.operand(), b.lower(), b.upper());
            case BoundExpr.Case c -> {
                List<BoundExpr> out = new ArrayList<>();
                if (c.operand() != null) {
                    out.add(c.operand());
                }
                out.addAll(c.conditions());
                out.addAll(c.results());
                if (c.elseResult() != null) {
                    out.add(c.elseResult());
                }
                yield out;
            }
            case BoundExpr.NullIf n -> List.of(n.operand(), n.equality());
            case BoundExpr.Function f -> f.args();
            case BoundExpr.InSubquery i -> List.of(i.operand());
        };
    }

    /** Copy of {@code e} with its children replaced (same order as {@link #children}). */
    public static BoundExpr withChildren(BoundExpr e, List<BoundExpr> ch) {
        return switch (e) {
            case BoundExpr.ColumnRef c -> e;
            case BoundExpr.OuterRef o -> e;
            case BoundExpr.Placeholder p -> e;
            case BoundExpr.Literal l -> e;
            case BoundExpr.AggregateRef a -> e;
            case BoundExpr.ScalarSubquery s -> e;
            case BoundExpr.Exists x -> e;
            case BoundExpr.Cast c -> new BoundExpr.Cast(ch.get(0), c.type(), c.implicit());
            case BoundExpr.Negate n -> new BoundExpr.Negate(ch.get(0), n.type());
            case BoundExpr.Not n -> new BoundExpr.Not(ch.get(0));
            case BoundExpr.IsNull n -> new BoundExpr.IsNull(ch.get(0), n.negated());
            case BoundExpr.Arithmetic a -> new BoundExpr.Arithmetic(a.op(), ch.get(0), ch.get(1), a.type());
            case BoundExpr.Comparison c -> new BoundExpr.Comparison(c.op(), ch.get(0), ch.get(1));
            case BoundExpr.And a -> new BoundExpr.And(ch.get(0), ch.get(1));
            case BoundExpr.Or o -> new BoundExpr.Or(ch.get(0), ch.get(1));
            case BoundExpr.Concat c -> new BoundExpr.Concat(ch.get(0), ch.get(1));
            case BoundExpr.Like l -> new BoundExpr.Like(ch.get(0), ch.get(1), l.negated());
            case BoundExpr.InList i -> new BoundExpr.InList(ch.get(0), List.copyOf(ch.subList(1, ch.size())),
                    i.negated());
            case BoundExpr.Between b -> new BoundExpr.Between(ch.get(0), ch.get(1), ch.get(2), b.negated());
            case BoundExpr.Case c -> {
                int k = 0;
                BoundExpr operand = c.operand() != null ? ch.get(k++) : null;
                int n = c.conditions().size();
                List<BoundExpr> conds = List.copyOf(ch.subList(k, k + n));
                List<BoundExpr> results = List.copyOf(ch.subList(k + n, k + 2 * n));
                k += 2 * n;
                BoundExpr elseResult = c.elseResult() != null ? ch.get(k) : null;
                yield new BoundExpr.Case(operand, conds, results, elseResult, c.type());
            }
            case BoundExpr.NullIf n -> new BoundExpr.NullIf(ch.get(0), ch.get(1));
            case BoundExpr.Function f -> new BoundExpr.Function(f.name(), List.copyOf(ch), f.type());
            case BoundExpr.InSubquery i -> new BoundExpr.InSubquery(ch.get(0), i.subquery(), i.valueCast(),
                    i.negated());
        };
    }

    /**
     * Top-down rewrite: {@code fn} returns a replacement for a node, or null to keep the node and
     * rewrite its children.
     */
    public static BoundExpr rewrite(BoundExpr e, Function<BoundExpr, BoundExpr> fn) {
        BoundExpr r = fn.apply(e);
        if (r != null) {
            return r;
        }
        List<BoundExpr> ch = children(e);
        if (ch.isEmpty()) {
            return e;
        }
        List<BoundExpr> out = new ArrayList<>(ch.size());
        boolean changed = false;
        for (BoundExpr c : ch) {
            BoundExpr nc = rewrite(c, fn);
            changed |= nc != c;
            out.add(nc);
        }
        return changed ? withChildren(e, out) : e;
    }

    /** True if some node (pre-order, not entering subquery plans) satisfies {@code p}. */
    public static boolean any(BoundExpr e, Predicate<BoundExpr> p) {
        if (p.test(e)) {
            return true;
        }
        for (BoundExpr c : children(e)) {
            if (any(c, p)) {
                return true;
            }
        }
        return false;
    }

    public static boolean containsColumnRef(BoundExpr e) {
        return any(e, x -> x instanceof BoundExpr.ColumnRef);
    }

    public static boolean containsSubquery(BoundExpr e) {
        return any(e, x -> x instanceof BoundExpr.ScalarSubquery || x instanceof BoundExpr.Exists
                || x instanceof BoundExpr.InSubquery);
    }

    /** True if a subquery inside {@code e} is correlated. */
    public static boolean containsCorrelatedSubquery(BoundExpr e) {
        return any(e, x -> switch (x) {
            case BoundExpr.ScalarSubquery s -> s.subquery().correlated();
            case BoundExpr.Exists s -> s.subquery().correlated();
            case BoundExpr.InSubquery s -> s.subquery().correlated();
            default -> false;
        });
    }

    /** True if a subquery inside {@code e} depends on the current row of correlation frame {@code frame}. */
    public static boolean dependsOnFrame(BoundExpr e, int frame) {
        return any(e, x -> switch (x) {
            case BoundExpr.ScalarSubquery s -> refersTo(s.subquery(), frame);
            case BoundExpr.Exists s -> refersTo(s.subquery(), frame);
            case BoundExpr.InSubquery s -> refersTo(s.subquery(), frame);
            default -> false;
        });
    }

    private static boolean refersTo(Subquery s, int frame) {
        return s.refersTo(frame);
    }

    /** The subquery of a subquery expression node, else null. */
    public static Subquery subqueryOf(BoundExpr e) {
        return switch (e) {
            case BoundExpr.ScalarSubquery s -> s.subquery();
            case BoundExpr.Exists s -> s.subquery();
            case BoundExpr.InSubquery s -> s.subquery();
            default -> null;
        };
    }

    /** Copy of a subquery expression node with its subquery replaced. */
    public static BoundExpr withSubquery(BoundExpr e, Subquery sq) {
        return switch (e) {
            case BoundExpr.ScalarSubquery s -> new BoundExpr.ScalarSubquery(sq, s.type());
            case BoundExpr.Exists s -> new BoundExpr.Exists(sq);
            case BoundExpr.InSubquery s -> new BoundExpr.InSubquery(s.operand(), sq, s.valueCast(), s.negated());
            default -> throw new IllegalArgumentException("not a subquery expression");
        };
    }

    /** True if the expression has no row inputs (columns, aggregates, subqueries, functions with effects). */
    public static boolean isConstant(BoundExpr e) {
        return !any(e, x -> x instanceof BoundExpr.ColumnRef || x instanceof BoundExpr.OuterRef
                || x instanceof BoundExpr.AggregateRef || x instanceof BoundExpr.ScalarSubquery
                || x instanceof BoundExpr.Exists || x instanceof BoundExpr.InSubquery
                || (x instanceof BoundExpr.Function f && f.name().equals("PQ_SLEEP")));
    }

    /** Smallest and largest input column index referenced ({@code [MAX, -1]} if none). */
    public static int[] columnRange(BoundExpr e) {
        int[] range = {Integer.MAX_VALUE, -1};
        collectRange(e, range);
        return range;
    }

    private static void collectRange(BoundExpr e, int[] range) {
        if (e instanceof BoundExpr.ColumnRef c) {
            range[0] = Math.min(range[0], c.index());
            range[1] = Math.max(range[1], c.index());
            return;
        }
        for (BoundExpr c : children(e)) {
            collectRange(c, range);
        }
    }

    /** Adds {@code delta} to every input column index. */
    public static BoundExpr shiftColumns(BoundExpr e, int delta) {
        if (delta == 0) {
            return e;
        }
        return rewrite(e, x -> x instanceof BoundExpr.ColumnRef c
                ? new BoundExpr.ColumnRef(c.index() + delta, c.type(), c.name()) : null);
    }

    /** Splits a predicate into its top-level AND conjuncts. */
    public static List<BoundExpr> conjuncts(BoundExpr e) {
        List<BoundExpr> out = new ArrayList<>();
        addConjuncts(e, out);
        return out;
    }

    private static void addConjuncts(BoundExpr e, List<BoundExpr> out) {
        if (e instanceof BoundExpr.And a) {
            addConjuncts(a.left(), out);
            addConjuncts(a.right(), out);
        } else {
            out.add(e);
        }
    }

    /** AND of the given predicates, or null if empty. */
    public static BoundExpr and(List<BoundExpr> preds) {
        BoundExpr out = null;
        for (BoundExpr p : preds) {
            out = out == null ? p : new BoundExpr.And(out, p);
        }
        return out;
    }
}
