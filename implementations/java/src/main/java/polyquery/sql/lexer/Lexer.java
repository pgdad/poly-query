package polyquery.sql.lexer;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import polyquery.common.PolyQueryException;

/** Converts SQL text into tokens (grammar.md §1). */
public final class Lexer {
    public static final Set<String> RESERVED = Set.of(
            "ALL", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CAST", "CREATE", "CROSS", "DATE",
            "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "EXPLAIN", "FALSE", "FIRST", "FROM",
            "FULL", "GROUP", "HAVING", "IF", "IN", "INDEX", "INNER", "IS", "JOIN", "LAST", "LEFT",
            "LIKE", "LIMIT", "NOT", "NULL", "NULLS", "OFFSET", "ON", "OR", "ORDER", "OUTER", "RIGHT",
            "SELECT", "THEN", "TIMESTAMP", "TRUE", "UNION", "USING", "WHEN", "WHERE", "WITH");

    private final String src;
    private int pos;
    private int line = 1;
    private int lineStart;

    /** A lexer producing the tokens of {@code src} on demand ({@link #next}). */
    public Lexer(String src) {
        this.src = src;
    }

    /** All tokens of {@code sql}, ending with EOF. */
    public static List<Token> tokenize(String sql) {
        Lexer lexer = new Lexer(sql);
        List<Token> out = new ArrayList<>();
        Token t;
        do {
            t = lexer.next();
            out.add(t);
        } while (!t.is(TokenType.EOF));
        return out;
    }

    private int col() {
        return pos - lineStart + 1;
    }

    private PolyQueryException error(String msg, int l, int c) {
        return PolyQueryException.parse(msg, l, c);
    }

    private void newline() {
        line++;
        lineStart = pos;
    }

    private static boolean identStart(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    }

    private static boolean identPart(char c) {
        return identStart(c) || (c >= '0' && c <= '9');
    }

    private static boolean digit(char c) {
        return c >= '0' && c <= '9';
    }

    /** The next token; EOF at the end of the text (and on every later call). */
    public Token next() {
        int n = src.length();
        skipTrivia();
        if (pos >= n) {
            return new Token(TokenType.EOF, "", line, col());
        }
        int l = line;
        int c = col();
        char ch = src.charAt(pos);
        if (identStart(ch)) {
            int start = pos;
            while (pos < n && identPart(src.charAt(pos))) {
                pos++;
            }
            String word = src.substring(start, pos);
            String upper = word.toUpperCase(Locale.ROOT);
            if (RESERVED.contains(upper)) {
                return new Token(TokenType.KEYWORD, upper, l, c, word);
            }
            return new Token(TokenType.IDENT, word, l, c);
        }
        if (digit(ch) || (ch == '.' && pos + 1 < n && digit(src.charAt(pos + 1)))) {
            return number(l, c);
        }
        if (ch == '\'') {
            return new Token(TokenType.STRING, quoted('\'', l, c, "string literal"), l, c);
        }
        if (ch == '"') {
            String id = quoted('"', l, c, "quoted identifier");
            if (id.isEmpty()) {
                throw error("empty quoted identifier", l, c);
            }
            return new Token(TokenType.QUOTED_IDENT, id, l, c);
        }
        return operator(ch, l, c);
    }

    private void skipTrivia() {
        int n = src.length();
        while (pos < n) {
            char ch = src.charAt(pos);
            if (ch == '\n') {
                pos++;
                newline();
            } else if (ch == ' ' || ch == '\t' || ch == '\r') {
                pos++;
            } else if (ch == '-' && pos + 1 < n && src.charAt(pos + 1) == '-') {
                while (pos < n && src.charAt(pos) != '\n') {
                    pos++;
                }
            } else if (ch == '/' && pos + 1 < n && src.charAt(pos + 1) == '*') {
                int l = line;
                int c = col();
                pos += 2;
                while (true) {
                    if (pos >= n) {
                        throw error("unterminated block comment", l, c);
                    }
                    char d = src.charAt(pos);
                    if (d == '*' && pos + 1 < n && src.charAt(pos + 1) == '/') {
                        pos += 2;
                        break;
                    }
                    pos++;
                    if (d == '\n') {
                        newline();
                    }
                }
            } else {
                return;
            }
        }
    }

    private Token number(int l, int c) {
        int n = src.length();
        int start = pos;
        while (pos < n && digit(src.charAt(pos))) {
            pos++;
        }
        if (pos < n && src.charAt(pos) == '.') {
            pos++;
            while (pos < n && digit(src.charAt(pos))) {
                pos++;
            }
        }
        if (pos < n && (src.charAt(pos) == 'e' || src.charAt(pos) == 'E')) {
            int save = pos;
            pos++;
            if (pos < n && (src.charAt(pos) == '+' || src.charAt(pos) == '-')) {
                pos++;
            }
            if (pos < n && digit(src.charAt(pos))) {
                while (pos < n && digit(src.charAt(pos))) {
                    pos++;
                }
            } else {
                pos = save;
            }
        }
        if (pos < n && (identPart(src.charAt(pos)) || src.charAt(pos) == '.')) {
            throw error("malformed numeric literal", l, c);
        }
        return new Token(TokenType.NUMBER, src.substring(start, pos), l, c);
    }

    private String quoted(char q, int l, int c, String what) {
        int n = src.length();
        pos++;
        StringBuilder sb = new StringBuilder();
        while (true) {
            if (pos >= n) {
                throw error("unterminated " + what, l, c);
            }
            char ch = src.charAt(pos++);
            if (ch == q) {
                if (pos < n && src.charAt(pos) == q) {
                    sb.append(q);
                    pos++;
                    continue;
                }
                return sb.toString();
            }
            sb.append(ch);
            if (ch == '\n') {
                newline();
            }
        }
    }

    private Token operator(char ch, int l, int c) {
        int n = src.length();
        char next = pos + 1 < n ? src.charAt(pos + 1) : '\0';
        TokenType t;
        int len = 1;
        switch (ch) {
            case '+' -> t = TokenType.PLUS;
            case '-' -> t = TokenType.MINUS;
            case '*' -> t = TokenType.STAR;
            case '/' -> t = TokenType.SLASH;
            case '%' -> t = TokenType.PERCENT;
            case '(' -> t = TokenType.LPAREN;
            case ')' -> t = TokenType.RPAREN;
            case ',' -> t = TokenType.COMMA;
            case '.' -> t = TokenType.DOT;
            case ';' -> t = TokenType.SEMICOLON;
            case '=' -> t = TokenType.EQ;
            case '|' -> {
                if (next != '|') {
                    throw error("unexpected character '|'", l, c);
                }
                t = TokenType.CONCAT;
                len = 2;
            }
            case '!' -> {
                if (next != '=') {
                    throw error("unexpected character '!'", l, c);
                }
                t = TokenType.NEQ;
                len = 2;
            }
            case '<' -> {
                if (next == '=') {
                    t = TokenType.LE;
                    len = 2;
                } else if (next == '>') {
                    t = TokenType.NEQ;
                    len = 2;
                } else {
                    t = TokenType.LT;
                }
            }
            case '>' -> {
                if (next == '=') {
                    t = TokenType.GE;
                    len = 2;
                } else {
                    t = TokenType.GT;
                }
            }
            default -> throw error("unexpected character '" + new String(Character.toChars(src.codePointAt(pos))) + "'", l, c);
        }
        String text = src.substring(pos, pos + len);
        pos += len;
        return new Token(t, text, l, c);
    }
}
