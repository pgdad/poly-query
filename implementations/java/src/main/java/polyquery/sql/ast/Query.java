package polyquery.sql.ast;

import java.util.List;

/**
 * A query expression: optional WITH, one or more SELECT cores combined with {@code UNION ALL}
 * (the branches, in order), then ORDER BY and LIMIT/OFFSET applying to the whole result.
 */
public record Query(SourcePos pos, List<Cte> with, List<Select> branches, List<OrderItem> orderBy,
                    Expr limit, Expr offset) {

    /** True for a {@code UNION ALL} of two or more branches. */
    public boolean compound() {
        return branches.size() > 1;
    }

    public record Cte(SourcePos pos, String name, List<String> columnNames, Query query) {
    }

    public record Select(SourcePos pos, boolean distinct, List<SelectItem> items, FromItem from,
                         Expr where, List<Expr> groupBy, Expr having) {
    }

    public sealed interface SelectItem {
        SourcePos pos();
    }

    /** {@code *} or {@code qualifier.*}. */
    public record Star(SourcePos pos, String qualifier) implements SelectItem {
    }

    public record ExprItem(SourcePos pos, Expr expr, String alias) implements SelectItem {
    }

    public sealed interface FromItem {
        SourcePos pos();
    }

    public record TableRef(SourcePos pos, String name, String alias) implements FromItem {
    }

    public record DerivedTable(SourcePos pos, Query query, String alias) implements FromItem {
    }

    public enum JoinKind { INNER, LEFT, CROSS }

    public record Join(SourcePos pos, FromItem left, FromItem right, JoinKind kind, Expr condition)
            implements FromItem {
    }

    public record OrderItem(SourcePos pos, Expr expr, boolean descending, Boolean nullsFirst) {
    }
}
