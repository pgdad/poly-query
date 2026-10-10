package polyquery.sql.ast;

import java.util.List;

/** A query expression: optional WITH, a SELECT core, ORDER BY and LIMIT/OFFSET. */
public record Query(SourcePos pos, List<Cte> with, Select select, List<OrderItem> orderBy,
                    Expr limit, Expr offset) {

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
