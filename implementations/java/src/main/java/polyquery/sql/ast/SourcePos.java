package polyquery.sql.ast;

import polyquery.sql.lexer.Token;

/** 1-based position of a syntax element in the SQL text. */
public record SourcePos(int line, int column) {
    public static SourcePos of(Token t) {
        return new SourcePos(t.line(), t.column());
    }
}
