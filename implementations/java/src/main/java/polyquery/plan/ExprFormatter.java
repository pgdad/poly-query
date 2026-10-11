package polyquery.plan;

import java.util.ArrayList;
import java.util.List;
import polyquery.storage.ColumnSchema;
import polyquery.types.TypeKind;
import polyquery.types.Values;

/** Renders bound expressions, aggregate calls and sort keys as SQL-like text (EXPLAIN output, diagnostics). */
public final class ExprFormatter {
    private ExprFormatter() {
    }

    public static String format(BoundExpr e) {
        return switch (e) {
            case BoundExpr.ColumnRef c -> c.name();
            case BoundExpr.OuterRef o -> "outer." + o.name();
            case BoundExpr.Placeholder p -> "?";
            case BoundExpr.Literal l -> literal(l);
            case BoundExpr.Cast c -> c.implicit() ? format(c.input()) : "CAST(" + format(c.input()) + " AS " + c.type() + ")";
            case BoundExpr.Negate n -> "-" + format(n.input());
            case BoundExpr.Not n -> "NOT " + format(n.input());
            case BoundExpr.Arithmetic a -> "(" + format(a.left()) + " " + arith(a.op()) + " " + format(a.right()) + ")";
            case BoundExpr.Comparison c -> "(" + format(c.left()) + " " + compare(c.op()) + " " + format(c.right()) + ")";
            case BoundExpr.And a -> "(" + format(a.left()) + " AND " + format(a.right()) + ")";
            case BoundExpr.Or o -> "(" + format(o.left()) + " OR " + format(o.right()) + ")";
            case BoundExpr.IsNull n -> "(" + format(n.input()) + (n.negated() ? " IS NOT NULL)" : " IS NULL)");
            case BoundExpr.Concat c -> "(" + format(c.left()) + " || " + format(c.right()) + ")";
            case BoundExpr.Like l -> "(" + format(l.operand()) + (l.negated() ? " NOT LIKE " : " LIKE ")
                    + format(l.pattern()) + ")";
            case BoundExpr.InList i -> {
                List<String> items = new ArrayList<>();
                for (BoundExpr c : i.comparisons()) {
                    items.add(c instanceof BoundExpr.Comparison cmp ? format(cmp.right()) : format(c));
                }
                yield "(" + format(i.operand()) + (i.negated() ? " NOT IN (" : " IN (") + String.join(", ", items) + "))";
            }
            case BoundExpr.Between b -> "(" + format(b.operand()) + (b.negated() ? " NOT BETWEEN " : " BETWEEN ")
                    + rhs(b.lower()) + " AND " + rhs(b.upper()) + ")";
            case BoundExpr.Case c -> {
                StringBuilder sb = new StringBuilder("CASE");
                if (c.operand() != null) {
                    sb.append(' ').append(format(c.operand()));
                }
                for (int i = 0; i < c.conditions().size(); i++) {
                    BoundExpr cond = c.conditions().get(i);
                    sb.append(" WHEN ").append(c.operand() != null ? rhs(cond) : format(cond))
                            .append(" THEN ").append(format(c.results().get(i)));
                }
                if (c.elseResult() != null) {
                    sb.append(" ELSE ").append(format(c.elseResult()));
                }
                yield sb.append(" END").toString();
            }
            case BoundExpr.NullIf n -> "NULLIF(" + format(n.operand()) + ", " + rhs(n.equality()) + ")";
            case BoundExpr.Function f -> {
                List<String> args = new ArrayList<>();
                for (BoundExpr a : f.args()) {
                    args.add(format(a));
                }
                yield f.name() + "(" + String.join(", ", args) + ")";
            }
            case BoundExpr.AggregateRef a -> "$" + a.index();
            case BoundExpr.ScalarSubquery s -> "(subquery)";
            case BoundExpr.Exists x -> "EXISTS(subquery)";
            case BoundExpr.InSubquery i -> "(" + format(i.operand()) + (i.negated() ? " NOT IN " : " IN ") + "(subquery))";
        };
    }

    public static String aggregate(AggregateCall c) {
        String name = c.function() == AggregateCall.AggregateFunction.COUNT_STAR ? "COUNT" : c.function().name();
        if (c.argument() == null) {
            return name + "(*)";
        }
        return name + "(" + (c.distinct() ? "DISTINCT " : "") + format(c.argument()) + ")";
    }

    /** A sort key over rows of {@code schema}, e.g. {@code total DESC NULLS LAST}. */
    public static String sortKey(SortKey k, List<ColumnSchema> schema) {
        return schema.get(k.column()).name() + (k.descending() ? " DESC" : " ASC")
                + (k.nullsFirst() ? " NULLS FIRST" : " NULLS LAST");
    }

    /** Right-hand side of a comparison against a placeholder. */
    private static String rhs(BoundExpr e) {
        return e instanceof BoundExpr.Comparison c ? format(c.right()) : format(e);
    }

    private static String literal(BoundExpr.Literal l) {
        if (l.value() == null) {
            return "NULL";
        }
        String text = Values.toText(l.value(), l.type());
        return switch (l.type().kind()) {
            case STRING -> "'" + text.replace("'", "''") + "'";
            case DATE, TIMESTAMP -> l.type().kind() + " '" + text + "'";
            default -> l.type().kind() == TypeKind.BOOLEAN ? text.toUpperCase(java.util.Locale.ROOT) : text;
        };
    }

    private static String arith(BoundExpr.ArithOp op) {
        return switch (op) {
            case ADD -> "+";
            case SUB -> "-";
            case MUL -> "*";
            case DIV -> "/";
            case MOD -> "%";
        };
    }

    private static String compare(BoundExpr.CompareOp op) {
        return switch (op) {
            case EQ -> "=";
            case NEQ -> "<>";
            case LT -> "<";
            case LE -> "<=";
            case GT -> ">";
            case GE -> ">=";
        };
    }
}
