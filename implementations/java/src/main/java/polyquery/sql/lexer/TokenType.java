package polyquery.sql.lexer;

/** Lexical token categories. */
public enum TokenType {
    IDENT,
    QUOTED_IDENT,
    KEYWORD,
    NUMBER,
    STRING,
    PLUS("+"),
    MINUS("-"),
    STAR("*"),
    SLASH("/"),
    PERCENT("%"),
    CONCAT("||"),
    EQ("="),
    NEQ("<>"),
    LT("<"),
    LE("<="),
    GT(">"),
    GE(">="),
    LPAREN("("),
    RPAREN(")"),
    COMMA(","),
    DOT("."),
    SEMICOLON(";"),
    EOF;

    private final String symbol;

    TokenType() {
        this(null);
    }

    TokenType(String symbol) {
        this.symbol = symbol;
    }

    public String symbol() {
        return symbol;
    }
}
