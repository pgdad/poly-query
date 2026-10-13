package polyquery.sql.parser;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.function.Function;
import java.util.function.Supplier;
import polyquery.common.Checkpoint;
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

/**
 * Recursive-descent parser for the full PolyQuery SQL v1 grammar (grammar.md §2).
 *
 * <p>It enforces the statement size limits of {@link StatementLimits} (CR-6) while parsing:
 * <ul>
 * <li>Tokens are lexed on demand and only a small lookahead window is kept, so a long statement
 * never exists as a token list.</li>
 * <li>Nesting depth is measured as CR-6 §1 defines it: every parse method that produces an
 * expression (or query) leaves its <em>height</em> in {@link #height} — the most constructs
 * enclosing any expression inside it, counting itself, with a chain of binary operators of one
 * precedence level as one construct. Since a construct's left operand is parsed before the
 * construct is recognized, the height is computed bottom-up. To stop the recursion early,
 * {@link #depth} counts the constructs entered on the way down; it never exceeds the true depth.</li>
 * <li>Operands (literals, column references, {@code *} arguments) are counted as they are parsed.</li>
 * </ul>
 * The parser also polls the query's timeout ({@link Checkpoint}).
 */
public final class Parser {
    /** Tokens the parser may look ahead (it never looks behind). */
    private static final int LOOKAHEAD = 4;

    private final Lexer lexer;
    /** Ring buffer of the next {@link #buffered} tokens, starting at {@link #head}. */
    private final Token[] window = new Token[LOOKAHEAD];
    private int head;
    private int buffered;
    /** Constructs entered on the current parse path: a lower bound of the nesting depth below. */
    private int depth;
    /** Height of the expression, query or FROM item parsed last (see the class comment). */
    private int height;
    private int operands;

    private Parser(Lexer lexer) {
        this.lexer = lexer;
    }

    /**
     * Parses exactly one statement (optionally followed by a single ';'). Fails with
     * RESOURCE_LIMIT if the statement exceeds a limit of {@link StatementLimits}.
     */
    public static Statement parse(String sql) {
        StatementLimits.checkTextLength(sql);
        Parser p = new Parser(new Lexer(sql));
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

    /** The token {@code ahead} positions after the current one (EOF past the end). */
    private Token peek(int ahead) {
        while (buffered <= ahead) {
            if (buffered > 0) {
                Token last = window[(head + buffered - 1) % LOOKAHEAD];
                if (last.is(TokenType.EOF)) {
                    return last;
                }
            }
            Checkpoint.poll();
            window[(head + buffered) % LOOKAHEAD] = lexer.next();
            buffered++;
        }
        return window[(head + ahead) % LOOKAHEAD];
    }

    private Token peek() {
        return peek(0);
    }

    private Token next() {
        Token t = peek(0);
        if (t.type() != TokenType.EOF) {
            head = (head + 1) % LOOKAHEAD;
            buffered--;
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

    // ---------------------------------------------------------------- size limits

    /** Enters a construct: everything parsed until {@link #leave} is nested one level deeper. */
    private void enter() {
        if (++depth > StatementLimits.MAX_NESTING_DEPTH) {
            throw StatementLimits.nestingDepthExceeded();
        }
        Checkpoint.poll();
    }

    private void leave() {
        depth--;
    }

    /** The height of a construct whose parts have at most {@code inner} height. */
    private static int level(int inner) {
        if (inner + 1 > StatementLimits.MAX_NESTING_DEPTH) {
            throw StatementLimits.nestingDepthExceeded();
        }
        return inner + 1;
    }

    /** Counts one operand (literal, column reference or {@code *} argument). */
    private void operand() {
        if (++operands > StatementLimits.MAX_OPERANDS) {
            throw StatementLimits.operandCountExceeded();
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

    /** The query of a statement (not a construct: its expressions are at nesting depth 0). */
    private Query query() {
        Token start = peek();
        int h = 0;
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
                Query q = subquery();
                h = Math.max(h, height);
                expect(TokenType.RPAREN);
                with.add(new Query.Cte(SourcePos.of(ct), name, cols, q));
            } while (accept(TokenType.COMMA));
        }
        List<Query.Select> branches = new ArrayList<>();
        branches.add(selectCore());
        h = Math.max(h, height);
        while (peek().isKeyword("UNION")) {
            Token union = next();
            if (!acceptKeyword("ALL")) {
                throw unsupported(union, "UNION without ALL");
            }
            branches.add(selectCore());
            h = Math.max(h, height);
        }
        List<Query.OrderItem> orderBy = List.of();
        if (peek().isKeyword("ORDER")) {
            next();
            expectKeyword("BY");
            orderBy = new ArrayList<>();
            do {
                Token it = peek();
                Expr e = expr();
                h = Math.max(h, height);
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
            h = Math.max(h, height);
            if (acceptKeyword("OFFSET")) {
                offset = expr();
                h = Math.max(h, height);
            }
        } else if (acceptKeyword("OFFSET")) {
            offset = expr();
            h = Math.max(h, height);
            if (acceptKeyword("LIMIT")) {
                limit = expr();
                h = Math.max(h, height);
            }
        }
        if (peek().isKeyword("UNION") && peek(1).isKeyword("ALL")) {
            // ORDER BY / LIMIT can only follow the last branch of a compound query.
            throw error(peek(), "ORDER BY and LIMIT are only allowed after the last branch of UNION ALL");
        }
        height = h;
        return new Query(SourcePos.of(start), with, List.copyOf(branches), orderBy, limit, offset);
    }

    /** A subquery (scalar, EXISTS, IN, derived table or CTE): one construct around its query. */
    private Query subquery() {
        enter();
        Query q = query();
        leave();
        height = level(height);
        return q;
    }

    private Query.Select selectCore() {
        Token start = expectKeyword("SELECT");
        int h = 0;
        boolean distinct = false;
        if (acceptKeyword("DISTINCT")) {
            distinct = true;
        } else {
            acceptKeyword("ALL");
        }
        List<Query.SelectItem> items = new ArrayList<>();
        do {
            items.add(selectItem());
            h = Math.max(h, height);
        } while (accept(TokenType.COMMA));
        Query.FromItem from = null;
        if (acceptKeyword("FROM")) {
            from = fromItem();
            h = Math.max(h, height);
        }
        Expr where = null;
        if (acceptKeyword("WHERE")) {
            where = expr();
            h = Math.max(h, height);
        }
        List<Expr> groupBy = List.of();
        if (acceptKeyword("GROUP")) {
            expectKeyword("BY");
            groupBy = new ArrayList<>();
            do {
                groupBy.add(expr());
                h = Math.max(h, height);
            } while (accept(TokenType.COMMA));
        }
        Expr having = null;
        if (acceptKeyword("HAVING")) {
            having = expr();
            h = Math.max(h, height);
        }
        height = h;
        return new Query.Select(SourcePos.of(start), distinct, items, from, where, groupBy, having);
    }

    private Query.SelectItem selectItem() {
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        if (t.is(TokenType.STAR)) {
            next();
            height = 0;
            return new Query.Star(pos, null);
        }
        if (isIdent(t) && peek(1).is(TokenType.DOT) && peek(2).is(TokenType.STAR)) {
            next();
            next();
            next();
            height = 0;
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
        int h = height;
        while (true) {
            Checkpoint.poll();
            Token t = peek();
            SourcePos pos = SourcePos.of(t);
            if (t.is(TokenType.COMMA)) {
                next();
                left = new Query.Join(pos, left, tableRef(), Query.JoinKind.CROSS, null);
                h = Math.max(h, height);
            } else if (t.isKeyword("CROSS")) {
                next();
                expectKeyword("JOIN");
                left = new Query.Join(pos, left, tableRef(), Query.JoinKind.CROSS, null);
                h = Math.max(h, height);
            } else if (t.isKeyword("JOIN") || t.isKeyword("INNER")) {
                if (acceptKeyword("INNER")) {
                    expectKeyword("JOIN");
                } else {
                    next();
                }
                Query.FromItem right = tableRef();
                h = Math.max(h, height);
                expectKeyword("ON");
                left = new Query.Join(pos, left, right, Query.JoinKind.INNER, expr());
                h = Math.max(h, height);
            } else if (t.isKeyword("LEFT")) {
                next();
                acceptKeyword("OUTER");
                expectKeyword("JOIN");
                Query.FromItem right = tableRef();
                h = Math.max(h, height);
                expectKeyword("ON");
                left = new Query.Join(pos, left, right, Query.JoinKind.LEFT, expr());
                h = Math.max(h, height);
            } else if (t.isKeyword("RIGHT") || t.isKeyword("FULL")) {
                throw unsupported(t, t.text() + " JOIN");
            } else {
                height = h;
                return left;
            }
        }
    }

    private Query.FromItem tableRef() {
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        if (t.is(TokenType.LPAREN)) {
            next();
            Token n = peek();
            if (n.isKeyword("SELECT") || n.isKeyword("WITH")) {
                Query q = subquery();
                expect(TokenType.RPAREN);
                acceptKeyword("AS");
                String alias = identifier("derived table alias");
                return new Query.DerivedTable(pos, q, alias);
            }
            // a parenthesized join counts as a nesting level too
            enter();
            Query.FromItem inner = fromItem();
            leave();
            height = level(height);
            expect(TokenType.RPAREN);
            return inner;
        }
        String name = identifier("table name");
        String alias = null;
        if (acceptKeyword("AS")) {
            alias = aliasAfterAs("alias");
        } else if (isIdent(peek())) {
            alias = next().text();
        }
        height = 0;
        return new Query.TableRef(pos, name, alias);
    }

    // ---------------------------------------------------------------- expressions

    public Expr expr() {
        return orExpr();
    }

    /**
     * Finishes a chain of binary operators of one precedence level whose first operand
     * ({@code left}, of height {@code leftHeight}) is parsed: the chain is one construct.
     */
    private Expr chain(Expr left, int leftHeight, Function<Token, BinaryOp> operator,
                       Supplier<Expr> operandParser) {
        BinaryOp op = operator.apply(peek());
        if (op == null) {
            height = leftHeight;
            return left;
        }
        int h = leftHeight;
        enter();
        while (op != null) {
            Token t = next();
            Expr right = operandParser.get();
            h = Math.max(h, height);
            left = new Expr.Binary(SourcePos.of(t), op, left, right);
            Checkpoint.poll();
            op = operator.apply(peek());
        }
        leave();
        height = level(h);
        return left;
    }

    private Expr orExpr() {
        Expr left = andExpr();
        return chain(left, height, t -> t.isKeyword("OR") ? BinaryOp.OR : null, this::andExpr);
    }

    private Expr andExpr() {
        Expr left = notExpr();
        return chain(left, height, t -> t.isKeyword("AND") ? BinaryOp.AND : null, this::notExpr);
    }

    private Expr notExpr() {
        if (peek().isKeyword("NOT")) {
            Token op = next();
            enter();
            Expr operand = notExpr();
            leave();
            height = level(height);
            return new Expr.Unary(SourcePos.of(op), UnaryOp.NOT, operand);
        }
        return predicate();
    }

    private Expr predicate() {
        Expr left = concatExpr();
        int h = height;
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
            enter();
            Expr right = concatExpr();
            leave();
            height = level(Math.max(h, height));
            return new Expr.Binary(pos, cmp, left, right);
        }
        if (t.isKeyword("IS")) {
            next();
            boolean negated = acceptKeyword("NOT");
            expectKeyword("NULL");
            height = level(h);
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
            enter();
            Expr low = concatExpr();
            h = Math.max(h, height);
            expectKeyword("AND");
            Expr high = concatExpr();
            leave();
            height = level(Math.max(h, height));
            return new Expr.Between(pos, left, low, high, negated);
        }
        if (t.isKeyword("IN")) {
            next();
            expect(TokenType.LPAREN);
            enter();
            Token n = peek();
            if (n.isKeyword("SELECT") || n.isKeyword("WITH")) {
                Query q = subquery();
                leave();
                height = level(Math.max(h, height));
                expect(TokenType.RPAREN);
                return new Expr.InSubquery(pos, left, q, negated);
            }
            List<Expr> items = new ArrayList<>();
            do {
                items.add(expr());
                h = Math.max(h, height);
                Checkpoint.poll();
            } while (accept(TokenType.COMMA));
            leave();
            height = level(h);
            expect(TokenType.RPAREN);
            return new Expr.InList(pos, left, items, negated);
        }
        if (t.isKeyword("LIKE")) {
            next();
            enter();
            Expr pattern = concatExpr();
            leave();
            height = level(Math.max(h, height));
            return new Expr.Like(pos, left, pattern, negated);
        }
        height = h;
        return left;
    }

    private Expr concatExpr() {
        Expr left = additive();
        return chain(left, height, t -> t.is(TokenType.CONCAT) ? BinaryOp.CONCAT : null, this::additive);
    }

    private Expr additive() {
        Expr left = multiplicative();
        return chain(left, height, t -> switch (t.type()) {
            case PLUS -> BinaryOp.ADD;
            case MINUS -> BinaryOp.SUB;
            default -> null;
        }, this::multiplicative);
    }

    private Expr multiplicative() {
        Expr left = unary();
        return chain(left, height, t -> switch (t.type()) {
            case STAR -> BinaryOp.MUL;
            case SLASH -> BinaryOp.DIV;
            case PERCENT -> BinaryOp.MOD;
            default -> null;
        }, this::unary);
    }

    private Expr unary() {
        Token t = peek();
        if (t.is(TokenType.MINUS) || t.is(TokenType.PLUS)) {
            next();
            enter();
            Expr result;
            if (t.is(TokenType.MINUS) && peek().is(TokenType.NUMBER)) {
                // Fold the sign into the literal so that INT64_MIN is representable.
                Token num = next();
                operand();
                height = 0;
                result = new Expr.NumberLiteral(SourcePos.of(t), "-" + num.text());
            } else {
                Expr operand = unary();
                result = new Expr.Unary(SourcePos.of(t), t.is(TokenType.MINUS) ? UnaryOp.NEG : UnaryOp.PLUS,
                        operand);
            }
            leave();
            height = level(height);
            return result;
        }
        return primary();
    }

    private Expr primary() {
        Token t = peek();
        SourcePos pos = SourcePos.of(t);
        switch (t.type()) {
            case NUMBER -> {
                next();
                operand();
                height = 0;
                return new Expr.NumberLiteral(pos, t.text());
            }
            case STRING -> {
                next();
                operand();
                height = 0;
                return new Expr.StringLiteral(pos, t.text());
            }
            case LPAREN -> {
                next();
                Token n = peek();
                if (n.isKeyword("SELECT") || n.isKeyword("WITH")) {
                    Query q = subquery();
                    expect(TokenType.RPAREN);
                    return new Expr.ScalarSubquery(pos, q);
                }
                enter();
                Expr e = expr();
                leave();
                height = level(height);
                expect(TokenType.RPAREN);
                return e;
            }
            case IDENT, QUOTED_IDENT -> {
                next();
                if (peek().is(TokenType.LPAREN)) {
                    return functionCall(t);
                }
                operand();
                height = 0;
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
                operand();
                height = 0;
                return new Expr.BooleanLiteral(pos, true);
            }
            case "FALSE" -> {
                next();
                operand();
                height = 0;
                return new Expr.BooleanLiteral(pos, false);
            }
            case "NULL" -> {
                next();
                operand();
                height = 0;
                return new Expr.NullLiteral(pos);
            }
            case "DATE", "TIMESTAMP" -> {
                next();
                Token s = peek();
                if (!s.is(TokenType.STRING)) {
                    throw error(s, "expected string literal after " + t.text());
                }
                next();
                operand();
                height = 0;
                return new Expr.TypedLiteral(pos, t.text(), s.text());
            }
            case "CAST" -> {
                next();
                expect(TokenType.LPAREN);
                enter();
                Expr operand = expr();
                leave();
                height = level(height);
                expectKeyword("AS");
                Expr.TypeName type = typeName();
                expect(TokenType.RPAREN);
                return new Expr.Cast(pos, operand, type);
            }
            case "CASE" -> {
                next();
                enter();
                int h = 0;
                Expr operand = null;
                if (!peek().isKeyword("WHEN")) {
                    operand = expr();
                    h = height;
                }
                List<Expr.When> whens = new ArrayList<>();
                do {
                    expectKeyword("WHEN");
                    Expr cond = expr();
                    h = Math.max(h, height);
                    expectKeyword("THEN");
                    whens.add(new Expr.When(cond, expr()));
                    h = Math.max(h, height);
                    Checkpoint.poll();
                } while (peek().isKeyword("WHEN"));
                Expr elseExpr = null;
                if (acceptKeyword("ELSE")) {
                    elseExpr = expr();
                    h = Math.max(h, height);
                }
                expectKeyword("END");
                leave();
                height = level(h);
                return new Expr.Case(pos, operand, whens, elseExpr);
            }
            case "EXISTS" -> {
                next();
                expect(TokenType.LPAREN);
                Query q = subquery();
                expect(TokenType.RPAREN);
                return new Expr.Exists(pos, q);
            }
            default -> throw error(t, "unexpected " + t.describe());
        }
    }

    private Expr functionCall(Token name) {
        SourcePos pos = SourcePos.of(name);
        expect(TokenType.LPAREN);
        enter();
        if (accept(TokenType.STAR)) {
            operand();
            expect(TokenType.RPAREN);
            leave();
            height = level(0);
            return new Expr.FunctionCall(pos, name.text(), List.of(), false, true);
        }
        List<Expr> args = new ArrayList<>();
        int h = 0;
        boolean distinct = false;
        if (!peek().is(TokenType.RPAREN)) {
            distinct = acceptKeyword("DISTINCT");
            do {
                args.add(expr());
                h = Math.max(h, height);
                Checkpoint.poll();
            } while (accept(TokenType.COMMA));
        }
        expect(TokenType.RPAREN);
        leave();
        height = level(h);
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
