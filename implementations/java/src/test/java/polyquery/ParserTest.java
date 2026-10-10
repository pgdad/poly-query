package polyquery;

import polyquery.common.ErrorCode;
import polyquery.sql.ast.Expr;
import polyquery.sql.ast.Query;
import polyquery.sql.ast.Statement;
import polyquery.sql.parser.Parser;

final class ParserTest {
    private ParserTest() {
    }

    private static Expr firstItem(String sql) {
        Statement.QueryStatement s = (Statement.QueryStatement) Parser.parse(sql);
        return ((Query.ExprItem) s.query().select().items().get(0)).expr();
    }

    static void testPrecedence() {
        Expr e = firstItem("SELECT 1 + 2 * 3");
        Expr.Binary add = (Expr.Binary) e;
        Assert.eq(Expr.BinaryOp.ADD, add.op());
        Assert.eq(Expr.BinaryOp.MUL, ((Expr.Binary) add.right()).op());

        Expr n = firstItem("SELECT NOT a = b AND c");
        Expr.Binary and = (Expr.Binary) n;
        Assert.eq(Expr.BinaryOp.AND, and.op());
        Assert.check(and.left() instanceof Expr.Unary u && u.operand() instanceof Expr.Binary, "NOT (a = b)");
    }

    static void testNegativeLiteralFolding() {
        Expr e = firstItem("SELECT -9223372036854775808");
        Assert.eq("-9223372036854775808", ((Expr.NumberLiteral) e).text());
        Expr m = firstItem("SELECT -2 * 3");
        Assert.check(((Expr.Binary) m).left() instanceof Expr.NumberLiteral, "(-2) * 3");
    }

    static void testClauses() {
        Statement.QueryStatement s = (Statement.QueryStatement) Parser.parse(
                "SELECT p.*, x AS y FROM people p WHERE a IS NOT NULL ORDER BY 1 DESC NULLS FIRST OFFSET 2 LIMIT 3;");
        Query q = s.query();
        Assert.eq(2, q.select().items().size());
        Assert.check(q.select().from() instanceof Query.TableRef t && t.alias().equals("p"), "alias");
        Assert.eq(true, q.orderBy().get(0).descending());
        Assert.eq(Boolean.TRUE, q.orderBy().get(0).nullsFirst());
        Assert.check(q.limit() != null && q.offset() != null, "limit/offset");
    }

    static void testFullGrammarParses() {
        Parser.parse("WITH c AS (SELECT 1 AS x) SELECT DISTINCT x FROM c JOIN t ON c.x = t.x "
                + "LEFT JOIN u ON TRUE CROSS JOIN v WHERE x BETWEEN 1 AND 2 AND y IN (1, 2) "
                + "AND z NOT LIKE 'a%' AND EXISTS (SELECT 1) GROUP BY x HAVING COUNT(*) > 1");
        Parser.parse("SELECT CASE WHEN a THEN 1 ELSE 2 END, CAST(a AS DECIMAL(10,2)), (SELECT 1)");
        Parser.parse("CREATE INDEX IF NOT EXISTS i ON t (c) USING HASH");
        Parser.parse("DROP INDEX IF EXISTS i");
        Parser.parse("EXPLAIN SELECT 1");
    }

    static void testSyntaxErrors() {
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Parser.parse("SELECT 1 = 1 = 1"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Parser.parse("SELECT a < b IS NULL"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Parser.parse("SELECT 1; SELECT 2"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Parser.parse("SELECT COUNT(*, a) FROM t"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Parser.parse("SELEC 1"));
        Assert.fails(ErrorCode.PARSE_ERROR, () -> Parser.parse("SELECT FROM t"));
        Assert.fails(ErrorCode.UNSUPPORTED, () -> Parser.parse("SELECT 1 UNION SELECT 2"));
        Assert.fails(ErrorCode.UNSUPPORTED, () -> Parser.parse("SELECT 1 FROM a RIGHT JOIN b ON TRUE"));
    }
}
