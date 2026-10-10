package polyquery.sql.ast;

import java.util.List;

/** Expression syntax tree (grammar.md §2). */
public sealed interface Expr {
    SourcePos pos();

    enum UnaryOp { NEG, PLUS, NOT }

    enum BinaryOp {
        OR("OR"), AND("AND"),
        EQ("="), NEQ("<>"), LT("<"), LE("<="), GT(">"), GE(">="),
        ADD("+"), SUB("-"), MUL("*"), DIV("/"), MOD("%"), CONCAT("||");

        private final String symbol;

        BinaryOp(String symbol) {
            this.symbol = symbol;
        }

        public String symbol() {
            return symbol;
        }

        public boolean isComparison() {
            return ordinal() >= EQ.ordinal() && ordinal() <= GE.ordinal();
        }

        public boolean isArithmetic() {
            return ordinal() >= ADD.ordinal() && ordinal() <= MOD.ordinal();
        }
    }

    /** Numeric literal text, possibly with a folded leading '-'. */
    record NumberLiteral(SourcePos pos, String text) implements Expr {
    }

    record StringLiteral(SourcePos pos, String value) implements Expr {
    }

    record BooleanLiteral(SourcePos pos, boolean value) implements Expr {
    }

    record NullLiteral(SourcePos pos) implements Expr {
    }

    /** {@code DATE '…'} or {@code TIMESTAMP '…'}. */
    record TypedLiteral(SourcePos pos, String typeName, String text) implements Expr {
    }

    record ColumnRef(SourcePos pos, String qualifier, String name) implements Expr {
    }

    record Unary(SourcePos pos, UnaryOp op, Expr operand) implements Expr {
    }

    record Binary(SourcePos pos, BinaryOp op, Expr left, Expr right) implements Expr {
    }

    record IsNull(SourcePos pos, Expr operand, boolean negated) implements Expr {
    }

    record Between(SourcePos pos, Expr operand, Expr low, Expr high, boolean negated) implements Expr {
    }

    record InList(SourcePos pos, Expr operand, List<Expr> items, boolean negated) implements Expr {
    }

    record InSubquery(SourcePos pos, Expr operand, Query query, boolean negated) implements Expr {
    }

    record Like(SourcePos pos, Expr operand, Expr pattern, boolean negated) implements Expr {
    }

    /** Function call; {@code star} for {@code COUNT(*)}. */
    record FunctionCall(SourcePos pos, String name, List<Expr> args, boolean distinct, boolean star)
            implements Expr {
    }

    record Cast(SourcePos pos, Expr operand, TypeName type) implements Expr {
    }

    record When(Expr condition, Expr result) {
    }

    record Case(SourcePos pos, Expr operand, List<When> whens, Expr elseExpr) implements Expr {
    }

    record Exists(SourcePos pos, Query query) implements Expr {
    }

    record ScalarSubquery(SourcePos pos, Query query) implements Expr {
    }

    /** {@code name[(p[,s])]} as written in CAST. */
    record TypeName(SourcePos pos, String name, Integer precision, Integer scale) {
    }
}
