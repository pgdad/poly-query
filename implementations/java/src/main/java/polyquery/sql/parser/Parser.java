package polyquery.sql.parser;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.sql.ast.Expr;
import polyquery.sql.ast.Expr.BinaryOp;
import polyquery.sql.ast.Expr.UnaryOp;
import polyquery.sql.ast.Query;
import polyquery.sql.ast.SourcePos;
import polyquery.sql.ast.Statement;
import polyquery.sql.lexer.Lexer;
import polyquery.sql.lexer.Token;
import polyquery.sql.lexer.TokenType;

/** Recursive-descent parser for the full PolyQuery SQL v1 grammar (grammar.md §2). */
public final class Parser {
    private static final int MAX_DEPTH = 1000;

    private final List<Token> tokens;
    private int pos;
    private int depth;

    private Parser(List<Token> tokens) {
        this.tokens = tokens;
    }

    /** Parses exactly one statement (optionally followed by a single ';'). */
    public static Statement parse(String sql) {
        Parser p = new Parser(Lexer.tokenize(sql));
        Statement s = p.statement();
        p.accept(TokenType.SEMICOLON);
        if (!p.peek().is(TokenType.EOF)) {
            Token t = p.peek();
            if (t.isKeyword("UNION")) {
                throw p.unsupported(t, "UNION");
            }
            throw p.error(t, "unexpected " + t.describe() + " after end of statement");
        }
        return s;
    }

    // ---------------------------------------------------------------- token helpers

    private Token peek() {
        return tokens.get(pos);
    }

    private Token peek(int ahead) {
        return tokens.get(Math.min(pos + ahead, tokens.size() - 1));
    }

    private Token next() {
        Token t = tokens.get(pos);
        if (t.type() != TokenType.EOF) {
            pos++;
        }
        return t;
    }

    private boolean accept(TokenType type) {
        if (peek().is(type)) {
            next();
            return true;
        }
        return false;
    }

    private boolean acceptKeyword(String kw) {
        if (peek().isKeyword(kw)) {
            next();
            return true;
        }
        return false;
    }

    private Token expect(TokenType type) {
        Token t = peek();
        if (!t.is(type)) {
            throw error(t, "expected '" + type.symbol() + "' but found " + t.describe());
        }
        return next();
    }

    private Token expectKeyword(String kw) {
        Token t = peek();
        if (!t.isKeyword(kw)) {
            throw error(t, "expected " + kw + " but found " + t.describe());
        }
        return next();
    }

    private boolean isIdent(Token t) {
        return t.is(TokenType.IDENT) || t.is(TokenType.QUOTED_IDENT);
    }

    private String identifier(String what) {
        Token t = peek();
        if (!isIdent(t)) {
            throw error(t, "expected " + what + " but found " + t.describe());
        }
        next();
        return t.text();
    }

    /**
     * The alias after an explicit {@code AS}: an identifier, or one of the keywords that are
     * reserved only for future syntax ({@code FULL}, {@code RIGHT}), which cannot mean anything
     * else in this position (e.g. {@code SELECT … AS full}).
     */
    private String aliasAfterAs(String what) {
        Token t = peek();
        if (t.isKeyword("FULL") || t.isKeyword("RIGHT")) {
            next();
            return t.raw();
        }
        return identifier(what);
    }

    private PolyQueryException error(Token t, String msg) {
        return PolyQueryException.parse(msg, t.line(), t.column());
    }

    private PolyQueryException unsupported(Token t, String feature) {
        PolyQueryException e = new PolyQueryException(ErrorCode.UNSUPPORTED, feature + " is not supported");
        e.withDetail("line", (long) t.line()).withDetail("column", (long) t.column());
        return e;
    }

    private void enter() {
        if (++depth > MAX_DEPTH) {
            throw error(peek(), "statement is nested too deeply");
        }
    }

    // ---------------------------------------------------------------- statements

    private Statement statement() {
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        if (t.isKeyword("EXPLAIN")) {
            next();
            return new Statement.Explain(pos, query());
        }
        if (t.isKeyword("CREATE")) {
            next();
            expectKeyword("INDEX");
            boolean ifNotExists = false;
            if (acceptKeyword("IF")) {
                expectKeyword("NOT");
                expectKeyword("EXISTS");
                ifNotExists = true;
            }
            String name = identifier("index name");
            expectKeyword("ON");
            String table = identifier("table name");
            expect(TokenType.LPAREN);
            String column = identifier("column name");
            expect(TokenType.RPAREN);
            String kind = "BTREE";
            if (acceptKeyword("USING")) {
                Token k = peek();
                if (k.is(TokenType.IDENT) && (k.text().equalsIgnoreCase("HASH") || k.text().equalsIgnoreCase("BTREE"))) {
                    next();
                    kind = k.text().toUpperCase(Locale.ROOT);
                } else {
                    throw error(k, "expected HASH or BTREE but found " + k.describe());
                }
            }
            return new Statement.CreateIndex(pos, name, ifNotExists, table, column, kind);
        }
        if (t.isKeyword("DROP")) {
            next();
            expectKeyword("INDEX");
            boolean ifExists = false;
            if (acceptKeyword("IF")) {
                expectKeyword("EXISTS");
                ifExists = true;
            }
            return new Statement.DropIndex(pos, identifier("index name"), ifExists);
        }
        if (t.isKeyword("SELECT") || t.isKeyword("WITH")) {
            return new Statement.QueryStatement(pos, query());
        }
        throw error(t, "expected a statement but found " + t.describe());
    }

    // ---------------------------------------------------------------- queries

    private Query query() {
        enter();
        Token start = peek();
        List<Query.Cte> with = List.of();
        if (acceptKeyword("WITH")) {
            with = new ArrayList<>();
            do {
                Token ct = peek();
                String name = identifier("CTE name");
                List<String> cols = null;
                if (accept(TokenType.LPAREN)) {
                    cols = new ArrayList<>();
                    do {
                        cols.add(identifier("column name"));
                    } while (accept(TokenType.COMMA));
                    expect(TokenType.RPAREN);
                }
                expectKeyword("AS");
                expect(TokenType.LPAREN);
                Query q = query();
                expect(TokenType.RPAREN);
                with.add(new Query.Cte(SourcePos.of(ct), name, cols, q));
            } while (accept(TokenType.COMMA));
        }
        List<Query.Select> branches = new ArrayList<>();
        branches.add(selectCore());
        while (peek().isKeyword("UNION")) {
            Token union = next();
            if (!acceptKeyword("ALL")) {
                throw unsupported(union, "UNION without ALL");
            }
            branches.add(selectCore());
        }
        List<Query.OrderItem> orderBy = List.of();
        if (peek().isKeyword("ORDER")) {
            next();
            expectKeyword("BY");
            orderBy = new ArrayList<>();
            do {
                Token it = peek();
                Expr e = expr();
                boolean desc = false;
                if (acceptKeyword("DESC")) {
                    desc = true;
                } else {
                    acceptKeyword("ASC");
                }
                Boolean nullsFirst = null;
                if (acceptKeyword("NULLS")) {
                    if (acceptKeyword("FIRST")) {
                        nullsFirst = true;
                    } else {
                        expectKeyword("LAST");
                        nullsFirst = false;
                    }
                }
                orderBy.add(new Query.OrderItem(SourcePos.of(it), e, desc, nullsFirst));
            } while (accept(TokenType.COMMA));
        }
        Expr limit = null;
        Expr offset = null;
        if (acceptKeyword("LIMIT")) {
            limit = expr();
            if (acceptKeyword("OFFSET")) {
                offset = expr();
            }
        } else if (acceptKeyword("OFFSET")) {
            offset = expr();
            if (acceptKeyword("LIMIT")) {
                limit = expr();
            }
        }
        if (peek().isKeyword("UNION") && peek(1).isKeyword("ALL")) {
            // ORDER BY / LIMIT can only follow the last branch of a compound query.
            throw error(peek(), "ORDER BY and LIMIT are only allowed after the last branch of UNION ALL");
        }
        depth--;
        return new Query(SourcePos.of(start), with, List.copyOf(branches), orderBy, limit, offset);
    }

    private Query.Select selectCore() {
        Token start = expectKeyword("SELECT");
        boolean distinct = false;
        if (acceptKeyword("DISTINCT")) {
            distinct = true;
        } else {
            acceptKeyword("ALL");
        }
        List<Query.SelectItem> items = new ArrayList<>();
        do {
            items.add(selectItem());
        } while (accept(TokenType.COMMA));
        Query.FromItem from = null;
        if (acceptKeyword("FROM")) {
            from = fromItem();
        }
        Expr where = null;
        if (acceptKeyword("WHERE")) {
            where = expr();
        }
        List<Expr> groupBy = List.of();
        if (acceptKeyword("GROUP")) {
            expectKeyword("BY");
            groupBy = new ArrayList<>();
            do {
                groupBy.add(expr());
            } while (accept(TokenType.COMMA));
        }
        Expr having = null;
        if (acceptKeyword("HAVING")) {
            having = expr();
        }
        return new Query.Select(SourcePos.of(start), distinct, items, from, where, groupBy, having);
    }

    private Query.SelectItem selectItem() {
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        if (t.is(TokenType.STAR)) {
            next();
            return new Query.Star(pos, null);
        }
        if (isIdent(t) && peek(1).is(TokenType.DOT) && peek(2).is(TokenType.STAR)) {
            next();
            next();
            next();
            return new Query.Star(pos, t.text());
        }
        Expr e = expr();
        String alias = null;
        if (acceptKeyword("AS")) {
            alias = aliasAfterAs("alias");
        } else if (isIdent(peek())) {
            alias = next().text();
        }
        return new Query.ExprItem(pos, e, alias);
    }

    private Query.FromItem fromItem() {
        Query.FromItem left = tableRef();
        while (true) {
            Token t = peek();
            SourcePos pos = SourcePos.of(t);
            if (t.is(TokenType.COMMA)) {
                next();
                left = new Query.Join(pos, left, tableRef(), Query.JoinKind.CROSS, null);
            } else if (t.isKeyword("CROSS")) {
                next();
                expectKeyword("JOIN");
                left = new Query.Join(pos, left, tableRef(), Query.JoinKind.CROSS, null);
            } else if (t.isKeyword("JOIN") || t.isKeyword("INNER")) {
                if (acceptKeyword("INNER")) {
                    expectKeyword("JOIN");
                } else {
                    next();
                }
                Query.FromItem right = tableRef();
                expectKeyword("ON");
                left = new Query.Join(pos, left, right, Query.JoinKind.INNER, expr());
            } else if (t.isKeyword("LEFT")) {
                next();
                acceptKeyword("OUTER");
                expectKeyword("JOIN");
                Query.FromItem right = tableRef();
                expectKeyword("ON");
                left = new Query.Join(pos, left, right, Query.JoinKind.LEFT, expr());
            } else if (t.isKeyword("RIGHT") || t.isKeyword("FULL")) {
                throw unsupported(t, t.text() + " JOIN");
            } else {
                return left;
            }
        }
    }

    private Query.FromItem tableRef() {
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        if (t.is(TokenType.LPAREN)) {
            enter();
            next();
            Token n = peek();
            if (n.isKeyword("SELECT") || n.isKeyword("WITH")) {
                Query q = query();
                expect(TokenType.RPAREN);
                acceptKeyword("AS");
                String alias = identifier("derived table alias");
                depth--;
                return new Query.DerivedTable(pos, q, alias);
            }
            Query.FromItem inner = fromItem();
            expect(TokenType.RPAREN);
            depth--;
            return inner;
        }
        String name = identifier("table name");
        String alias = null;
        if (acceptKeyword("AS")) {
            alias = aliasAfterAs("alias");
        } else if (isIdent(peek())) {
            alias = next().text();
        }
        return new Query.TableRef(pos, name, alias);
    }

    // ---------------------------------------------------------------- expressions

    public Expr expr() {
        enter();
        Expr e = orExpr();
        depth--;
        return e;
    }

    private Expr orExpr() {
        Expr left = andExpr();
        while (peek().isKeyword("OR")) {
            Token op = next();
            left = new Expr.Binary(SourcePos.of(op), BinaryOp.OR, left, andExpr());
        }
        return left;
    }

    private Expr andExpr() {
        Expr left = notExpr();
        while (peek().isKeyword("AND")) {
            Token op = next();
            left = new Expr.Binary(SourcePos.of(op), BinaryOp.AND, left, notExpr());
        }
        return left;
    }

    private Expr notExpr() {
        if (peek().isKeyword("NOT")) {
            Token op = next();
            enter();
            Expr operand = notExpr();
            depth--;
            return new Expr.Unary(SourcePos.of(op), UnaryOp.NOT, operand);
        }
        return predicate();
    }

    private Expr predicate() {
        Expr left = concatExpr();
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        BinaryOp cmp = switch (t.type()) {
            case EQ -> BinaryOp.EQ;
            case NEQ -> BinaryOp.NEQ;
            case LT -> BinaryOp.LT;
            case LE -> BinaryOp.LE;
            case GT -> BinaryOp.GT;
            case GE -> BinaryOp.GE;
            default -> null;
        };
        if (cmp != null) {
            next();
            return new Expr.Binary(pos, cmp, left, concatExpr());
        }
        if (t.isKeyword("IS")) {
            next();
            boolean negated = acceptKeyword("NOT");
            expectKeyword("NULL");
            return new Expr.IsNull(pos, left, negated);
        }
        boolean negated = false;
        if (t.isKeyword("NOT")) {
            Token n = peek(1);
            if (n.isKeyword("BETWEEN") || n.isKeyword("IN") || n.isKeyword("LIKE")) {
                next();
                negated = true;
                t = peek();
            } else {
                return left;
            }
        }
        if (t.isKeyword("BETWEEN")) {
            next();
            Expr low = concatExpr();
            expectKeyword("AND");
            Expr high = concatExpr();
            return new Expr.Between(pos, left, low, high, negated);
        }
        if (t.isKeyword("IN")) {
            next();
            expect(TokenType.LPAREN);
            Token n = peek();
            if (n.isKeyword("SELECT") || n.isKeyword("WITH")) {
                Query q = query();
                expect(TokenType.RPAREN);
                return new Expr.InSubquery(pos, left, q, negated);
            }
            List<Expr> items = new ArrayList<>();
            do {
                items.add(expr());
            } while (accept(TokenType.COMMA));
            expect(TokenType.RPAREN);
            return new Expr.InList(pos, left, items, negated);
        }
        if (t.isKeyword("LIKE")) {
            next();
            return new Expr.Like(pos, left, concatExpr(), negated);
        }
        return left;
    }

    private Expr concatExpr() {
        Expr left = additive();
        while (peek().is(TokenType.CONCAT)) {
            Token op = next();
            left = new Expr.Binary(SourcePos.of(op), BinaryOp.CONCAT, left, additive());
        }
        return left;
    }

    private Expr additive() {
        Expr left = multiplicative();
        while (peek().is(TokenType.PLUS) || peek().is(TokenType.MINUS)) {
            Token op = next();
            BinaryOp b = op.is(TokenType.PLUS) ? BinaryOp.ADD : BinaryOp.SUB;
            left = new Expr.Binary(SourcePos.of(op), b, left, multiplicative());
        }
        return left;
    }

    private Expr multiplicative() {
        Expr left = unary();
        while (true) {
            Token op = peek();
            BinaryOp b = switch (op.type()) {
                case STAR -> BinaryOp.MUL;
                case SLASH -> BinaryOp.DIV;
                case PERCENT -> BinaryOp.MOD;
                default -> null;
            };
            if (b == null) {
                return left;
            }
            next();
            left = new Expr.Binary(SourcePos.of(op), b, left, unary());
        }
    }

    private Expr unary() {
        Token t = peek();
        if (t.is(TokenType.MINUS) || t.is(TokenType.PLUS)) {
            next();
            enter();
            try {
                if (t.is(TokenType.MINUS) && peek().is(TokenType.NUMBER)) {
                    // Fold the sign into the literal so that INT64_MIN is representable.
                    Token num = next();
                    return new Expr.NumberLiteral(SourcePos.of(t), "-" + num.text());
                }
                Expr operand = unary();
                return new Expr.Unary(SourcePos.of(t), t.is(TokenType.MINUS) ? UnaryOp.NEG : UnaryOp.PLUS, operand);
            } finally {
                depth--;
            }
        }
        return primary();
    }

    private Expr primary() {
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        switch (t.type()) {
            case NUMBER -> {
                next();
                return new Expr.NumberLiteral(pos, t.text());
            }
            case STRING -> {
                next();
                return new Expr.StringLiteral(pos, t.text());
            }
            case LPAREN -> {
                next();
                Token n = peek();
                if (n.isKeyword("SELECT") || n.isKeyword("WITH")) {
                    Query q = query();
                    expect(TokenType.RPAREN);
                    return new Expr.ScalarSubquery(pos, q);
                }
                Expr e = expr();
                expect(TokenType.RPAREN);
                return e;
            }
            case IDENT, QUOTED_IDENT -> {
                next();
                if (peek().is(TokenType.LPAREN)) {
                    return functionCall(t);
                }
                if (peek().is(TokenType.DOT)) {
                    next();
                    String col = identifier("column name");
                    return new Expr.ColumnRef(pos, t.text(), col);
                }
                return new Expr.ColumnRef(pos, null, t.text());
            }
            case KEYWORD -> {
                return keywordPrimary(t, pos);
            }
            default -> throw error(t, "unexpected " + t.describe());
        }
    }

    private Expr keywordPrimary(Token t, SourcePos pos) {
        switch (t.text()) {
            case "TRUE" -> {
                next();
                return new Expr.BooleanLiteral(pos, true);
            }
            case "FALSE" -> {
                next();
                return new Expr.BooleanLiteral(pos, false);
            }
            case "NULL" -> {
                next();
                return new Expr.NullLiteral(pos);
            }
            case "DATE", "TIMESTAMP" -> {
                next();
                Token s = peek();
                if (!s.is(TokenType.STRING)) {
                    throw error(s, "expected string literal after " + t.text());
                }
                next();
                return new Expr.TypedLiteral(pos, t.text(), s.text());
            }
            case "CAST" -> {
                next();
                expect(TokenType.LPAREN);
                Expr operand = expr();
                expectKeyword("AS");
                Expr.TypeName type = typeName();
                expect(TokenType.RPAREN);
                return new Expr.Cast(pos, operand, type);
            }
            case "CASE" -> {
                next();
                Expr operand = null;
                if (!peek().isKeyword("WHEN")) {
                    operand = expr();
                }
                List<Expr.When> whens = new ArrayList<>();
                do {
                    expectKeyword("WHEN");
                    Expr cond = expr();
                    expectKeyword("THEN");
                    whens.add(new Expr.When(cond, expr()));
                } while (peek().isKeyword("WHEN"));
                Expr elseExpr = null;
                if (acceptKeyword("ELSE")) {
                    elseExpr = expr();
                }
                expectKeyword("END");
                return new Expr.Case(pos, operand, whens, elseExpr);
            }
            case "EXISTS" -> {
                next();
                expect(TokenType.LPAREN);
                Query q = query();
                expect(TokenType.RPAREN);
                return new Expr.Exists(pos, q);
            }
            default -> throw error(t, "unexpected " + t.describe());
        }
    }

    private Expr functionCall(Token name) {
        SourcePos pos = SourcePos.of(name);
        expect(TokenType.LPAREN);
        if (accept(TokenType.STAR)) {
            expect(TokenType.RPAREN);
            return new Expr.FunctionCall(pos, name.text(), List.of(), false, true);
        }
        List<Expr> args = new ArrayList<>();
        boolean distinct = false;
        if (!peek().is(TokenType.RPAREN)) {
            distinct = acceptKeyword("DISTINCT");
            do {
                args.add(expr());
            } while (accept(TokenType.COMMA));
        }
        expect(TokenType.RPAREN);
        return new Expr.FunctionCall(pos, name.text(), args, distinct, false);
    }

    private Expr.TypeName typeName() {
        Token t = peek();
        if (!(t.is(TokenType.IDENT) || t.is(TokenType.KEYWORD) || t.is(TokenType.QUOTED_IDENT))) {
            throw error(t, "expected type name but found " + t.describe());
        }
        next();
        Integer precision = null;
        Integer scale = null;
        if (accept(TokenType.LPAREN)) {
            precision = typeParam();
            if (accept(TokenType.COMMA)) {
                scale = typeParam();
            }
            expect(TokenType.RPAREN);
        }
        return new Expr.TypeName(SourcePos.of(t), t.text(), precision, scale);
    }

    private int typeParam() {
        Token t = peek();
        if (!t.is(TokenType.NUMBER) || !t.text().chars().allMatch(Character::isDigit)) {
            throw error(t, "expected integer type parameter but found " + t.describe());
        }
        next();
        try {
            return Integer.parseInt(t.text());
        } catch (NumberFormatException e) {
            return Integer.MAX_VALUE;
        }
    }
}
