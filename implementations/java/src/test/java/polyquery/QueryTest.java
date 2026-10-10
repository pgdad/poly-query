package polyquery;

import static polyquery.EngineTest.rows;
import static polyquery.EngineTest.types;

import java.util.List;
import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.engine.Engine;
import polyquery.engine.LoadRequest;
import polyquery.engine.QueryOptions;
import polyquery.json.JsonWriter;
import polyquery.physical.PhysicalPlanner.JoinStrategy;

/** Phase 2 SQL: grouping, joins, functions, subqueries, CTEs and EXPLAIN, end to end. */
final class QueryTest {
    private QueryTest() {
    }

    private static Engine engine() {
        Engine e = EngineTest.engine();
        e.load(new LoadRequest("orders", "csv", null,
                "oid,pid,amount\n10,1,5.50\n11,1,4.50\n12,3,1.00\n13,,2.00\n14,9,3.00\n", null, true, ',', false));
        return e;
    }

    private static void fails(Engine e, ErrorCode code, String sql) {
        Assert.fails(code, () -> e.query(sql, QueryOptions.DEFAULT));
    }

    static void testGroupBy() {
        Engine e = engine();
        Assert.eq("[[1,2,10.0],[3,1,1.0],[9,1,3.0],[null,1,2.0]]",
                rows(e, "SELECT pid, COUNT(*), SUM(amount) FROM orders GROUP BY pid ORDER BY pid NULLS LAST"));
        Assert.eq("[[1]]", rows(e, "SELECT pid FROM orders GROUP BY 1 HAVING COUNT(*) > 1"));
        Assert.eq("[[3]]", rows(e, "SELECT COUNT(DISTINCT pid) FROM orders"));
        Assert.eq("[[2],[3],[4],[5]]", rows(e, "SELECT id + 1 AS k FROM people GROUP BY k ORDER BY k"));
        Assert.eq("[[null],[1],[3],[9]]", rows(e, "SELECT DISTINCT pid FROM orders ORDER BY pid"));
        fails(e, ErrorCode.SEMANTIC_ERROR, "SELECT oid FROM orders GROUP BY pid");
        fails(e, ErrorCode.SEMANTIC_ERROR, "SELECT SUM(COUNT(oid)) FROM orders");
        fails(e, ErrorCode.SEMANTIC_ERROR, "SELECT DISTINCT pid FROM orders ORDER BY oid");
    }

    static void testJoins() {
        Engine e = engine();
        Assert.eq("[[10,\"Ann\"],[11,\"Ann\"],[12,\"Cid\"]]",
                rows(e, "SELECT o.oid, p.name FROM orders o JOIN people p ON o.pid = p.id ORDER BY o.oid"));
        Assert.eq("[[10,\"Ann\"],[11,\"Ann\"],[12,\"Cid\"],[13,null],[14,null]]",
                rows(e, "SELECT o.oid, p.name FROM orders o LEFT JOIN people p ON o.pid = p.id ORDER BY o.oid"));
        Assert.eq("[[20]]", rows(e, "SELECT COUNT(*) FROM orders, people"));
        // A comma join with an equality in WHERE becomes a hash join; nested loop must agree.
        String sql = "SELECT o.oid FROM orders o, people p WHERE o.pid = p.id AND p.age > 30 ORDER BY 1";
        Assert.eq("[[10],[11]]", rows(e, sql));
        QueryOptions nl = new QueryOptions(-1, 0, false, true, JoinStrategy.NESTED_LOOP);
        Assert.eq(2L, e.query(sql, nl).rowCount());
        QueryOptions noOpt = new QueryOptions(-1, 0, false, false, JoinStrategy.AUTO);
        Assert.eq(2L, e.query(sql, noOpt).rowCount());
        fails(e, ErrorCode.SEMANTIC_ERROR, "SELECT id FROM people a JOIN people b ON a.id = b.id");
        fails(e, ErrorCode.SEMANTIC_ERROR, "SELECT * FROM people JOIN people ON TRUE");
    }

    static void testFunctionsAndPredicates() {
        Engine e = engine();
        Assert.eq("[[\"ABC Ünï\",\"x-y\",\"bc\",3,\"2.35\",true,false,null]]",
                rows(e, "SELECT UPPER('abc Ünï'), CONCAT('x', NULL, '-y'), SUBSTR('abc', 2), LENGTH('héé'),"
                        + " ROUND(2.345, 2), 'abc' LIKE 'a%', 5 BETWEEN 6 AND 7, 2 IN (1, NULL)"));
        Assert.eq("[[\"lo\",2,\"2024-02-01 00:00:00\"]]", rows(e, "SELECT CASE WHEN 1 > 2 THEN 'hi' ELSE 'lo' END,"
                + " COALESCE(NULL, 2), DATE_TRUNC('month', DATE '2024-02-29')"));
        Assert.eq("[c:DECIMAL(18,1)]", types(e, "SELECT COALESCE(1, 2.5) AS c"));
        fails(e, ErrorCode.TYPE_ERROR, "SELECT CASE WHEN TRUE THEN 1 ELSE 'x' END");
        fails(e, ErrorCode.SEMANTIC_ERROR, "SELECT ROUND(1.5, id) FROM people");
        fails(e, ErrorCode.INVALID_ARGUMENT, "SELECT SQRT(-1)");
    }

    static void testSubqueriesAndCtes() {
        Engine e = engine();
        Assert.eq("[[\"Dee\"]]", rows(e, "SELECT name FROM people WHERE age = (SELECT MAX(age) FROM people)"));
        Assert.eq("[[1],[3]]", rows(e, "SELECT id FROM people WHERE id IN (SELECT pid FROM orders) ORDER BY id"));
        Assert.eq("[]", rows(e, "SELECT id FROM people WHERE id NOT IN (SELECT pid FROM orders)"));
        Assert.eq("[[2]]", rows(e, "WITH t AS (SELECT pid FROM orders WHERE pid = 1) SELECT COUNT(*) FROM t"));
        Assert.eq("[[\"Ann\",2],[\"bob\",0]]", rows(e, "SELECT p.name, (SELECT COUNT(*) FROM orders o"
                + " WHERE o.pid = p.id) FROM people p WHERE p.id <= 2 ORDER BY p.id"));
        Assert.eq("[[1],[3]]", rows(e, "SELECT id FROM people p WHERE EXISTS (SELECT 1 FROM orders o"
                + " WHERE o.pid = p.id) ORDER BY id"));
        fails(e, ErrorCode.SUBQUERY_CARDINALITY, "SELECT (SELECT id FROM people)");
        fails(e, ErrorCode.SEMANTIC_ERROR, "WITH a AS (SELECT * FROM a) SELECT * FROM a");
    }

    static void testExplain() {
        Engine e = engine();
        Map<String, Object> plan = e.explain("SELECT p.name FROM people p JOIN orders o ON o.pid = p.id"
                + " WHERE o.amount > 1", QueryOptions.DEFAULT);
        String json = JsonWriter.write(plan);
        Assert.check(json.contains("\"op\":\"HashJoin\""), "hash join chosen: " + json);
        Assert.check(json.contains("\"join_type\":\"INNER\""), "join type: " + json);
        Assert.check(json.contains("\"op\":\"TableScan\",\"table\":\"orders\""), "scan: " + json);
        Assert.eq(List.of("plan"), e.query("EXPLAIN SELECT 1", QueryOptions.DEFAULT).columns().stream()
                .map(c -> c.name()).toList());
    }
}
