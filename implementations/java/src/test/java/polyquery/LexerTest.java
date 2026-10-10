package polyquery;

import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.sql.lexer.Lexer;
import polyquery.sql.lexer.Token;
import polyquery.sql.lexer.TokenType;

final class LexerTest {
    private LexerTest() {
    }

    static void testTokensAndPositions() {
        List<Token> t = Lexer.tokenize("select a,\n  \"B c\" <> 'it''s' -- x\n /* y */ 1.5e3");
        Assert.eq(TokenType.KEYWORD, t.get(0).type());
        Assert.eq("SELECT", t.get(0).text());
        Assert.eq(TokenType.IDENT, t.get(1).type());
        Assert.eq(TokenType.COMMA, t.get(2).type());
        Assert.eq(TokenType.QUOTED_IDENT, t.get(3).type());
        Assert.eq("B c", t.get(3).text());
        Assert.eq(2, t.get(3).line());
        Assert.eq(3, t.get(3).column());
        Assert.eq(TokenType.NEQ, t.get(4).type());
        Assert.eq("it's", t.get(5).text());
        Assert.eq(TokenType.NUMBER, t.get(6).type());
        Assert.eq("1.5e3", t.get(6).text());
        Assert.eq(TokenType.EOF, t.get(7).type());
    }

    static void testOperators() {
        List<Token> t = Lexer.tokenize("a||b != c <= d >= e");
        Assert.eq(TokenType.CONCAT, t.get(1).type());
        Assert.eq(TokenType.NEQ, t.get(3).type());
        Assert.eq(TokenType.LE, t.get(5).type());
        Assert.eq(TokenType.GE, t.get(7).type());
    }

    static void testErrors() {
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Lexer.tokenize("'open"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Lexer.tokenize("/* open"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Lexer.tokenize("1abc"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Lexer.tokenize("a @ b"));
    }
}
