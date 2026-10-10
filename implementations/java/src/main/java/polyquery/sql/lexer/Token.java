package polyquery.sql.lexer;

/**
 * A lexical token. {@code text} is the identifier/keyword (keywords upper-cased), the
 * unescaped string or identifier content, or the numeric literal text.
 */
public record Token(TokenType type, String text, int line, int column) {
    public boolean isKeyword(String kw) {
        return type == TokenType.KEYWORD && text.equals(kw);
    }

    public boolean is(TokenType t) {
        return type == t;
    }

    public String describe() {
        return switch (type) {
            case EOF -> "end of input";
            case STRING -> "string literal";
            case NUMBER, IDENT, KEYWORD -> "'" + text + "'";
            case QUOTED_IDENT -> "\"" + text + "\"";
            default -> "'" + type.symbol() + "'";
        };
    }
}
