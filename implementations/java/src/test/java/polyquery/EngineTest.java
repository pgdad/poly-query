package polyquery;

import java.nio.file.Path;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.engine.LoadRequest;
import polyquery.engine.QueryOptions;
import polyquery.exec.QueryResult;
import polyquery.protocol.ResultWriter;

final class EngineTest {
    private EngineTest() {
    }

    static Engine engine() {
        return engine(null);
    }

    /** The test engine, using {@code kernels} (may be null) for queries with option {@code native}. */
    static Engine engine(polyquery.ffi.NativeKernels kernels) {
        Engine e = new Engine(new EngineConfig(Path.of(".").toAbsolutePath(), true, 1L << 30, 1L << 30,
                1_000_000, 1_000_000, 1, kernels));
        e.load(new LoadRequest("people", "csv", null,
                "id,name,age,score\n1,Ann,34,1.5\n2,bob,,2.5\n3,Cid,28,\n4,Dee,45,0.5\n", null, true, ',', false));
        return e;
    }

    /** Runs a query and renders the rows as JSON text. */
    static String rows(Engine e, String sql) {
        QueryResult r = e.query(sql, QueryOptions.DEFAULT);
        StringBuilder sb = new StringBuilder();
        ResultWriter.writeRows(sb, r.columns(), r.rows());
        return sb.toString();
    }

    static String types(Engine e, String sql) {
        return e.query(sql, QueryOptions.DEFAULT).columns().stream()
                .map(c -> c.name() + ":" + c.type()).toList().toString();
    }

    static void testProjectionFilterSort() {
        Engine e = engine();
        Assert.eq("[[\"Dee\",46],[\"Ann\",35],[\"Cid\",29]]",
                rows(e, "SELECT name, age + 1 AS a FROM people WHERE age IS NOT NULL ORDER BY a DESC"));
        Assert.eq("[[2],[3]]", rows(e, "SELECT id FROM people ORDER BY id LIMIT 2 OFFSET 1"));
        Assert.eq("[[2],[3],[1],[4]]", rows(e, "SELECT id FROM people ORDER BY age NULLS FIRST, id"));
        Assert.eq("[[\"Ann\"],[\"Cid\"],[\"Dee\"],[\"bob\"]]", rows(e, "SELECT name FROM people ORDER BY name"));
        Assert.eq("[id:INT64, _col2:INT64, n:STRING]", types(e, "SELECT id, id * 2, name AS n FROM people"));
    }

    static void testAggregates() {
        Engine e = engine();
        Assert.eq("[[4,3,107,28,45,35.666666666666664,4.5]]",
                rows(e, "SELECT COUNT(*), COUNT(age), SUM(age), MIN(age), MAX(age), AVG(age), SUM(score) FROM people"));
        Assert.eq("[[0,null]]", rows(e, "SELECT COUNT(*), SUM(age) FROM people WHERE id > 10"));
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> e.query("SELECT name, COUNT(*) FROM people", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> e.query("SELECT id FROM people WHERE SUM(id) > 1", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.TYPE_ERROR, () -> e.query("SELECT SUM(name) FROM people", QueryOptions.DEFAULT));
    }

    static void testTypingAndLiterals() {
        Engine e = engine();
        Assert.eq("[_col1:DECIMAL(18,2), _col2:DECIMAL(18,3), _col3:FLOAT64, _col4:DECIMAL(3,2)]",
                types(e, "SELECT 1.25 + 2.5, 1.25 * 2.5, 10.00 / 4, -2.50"));
        Assert.eq("[[\"3.75\",\"3.125\",2.5,\"-2.50\"]]", rows(e, "SELECT 1.25 + 2.5, 1.25 * 2.5, 10.00 / 4, -2.50"));
        Assert.eq("[[-9223372036854775808]]", rows(e, "SELECT -9223372036854775808"));
        Assert.eq("[[false,null,true,null]]", rows(e, "SELECT NULL AND FALSE, NULL AND TRUE, NULL OR TRUE, NULL = NULL"));
        Assert.eq("[[\"2024-03-01 00:00:00\"]]", rows(e, "SELECT CAST(DATE '2024-03-01' AS TIMESTAMP)"));
        Assert.fails(ErrorCode.TYPE_ERROR, () -> e.query("SELECT 1 = '1'", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.TYPE_ERROR, () -> e.query("SELECT 0.000000001 * 0.0000000001", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> e.query("SELECT 9223372036854775808", QueryOptions.DEFAULT));
    }

    static void testRuntimeErrors() {
        Engine e = engine();
        Assert.fails(ErrorCode.DIVISION_BY_ZERO, () -> e.query("SELECT 1 / 0", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> e.query("SELECT 9223372036854775807 + 1", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> e.query("SELECT 1e308 * 10", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.INVALID_ARGUMENT, () -> e.query("SELECT id FROM people LIMIT -1", QueryOptions.DEFAULT));
        Assert.eq("[[null]]", rows(e, "SELECT NULL / 0"));
    }

    static void testLimitsAndTimeout() {
        Engine e = engine();
        Assert.fails(ErrorCode.RESOURCE_LIMIT, () -> e.query("SELECT id FROM people", new QueryOptions(3, 0, false)));
        Assert.eq(4L, e.query("SELECT id FROM people", new QueryOptions(4, 0, true)).rowCount());
        long t0 = System.nanoTime();
        Assert.fails(ErrorCode.TIMEOUT, () -> e.query("SELECT PQ_SLEEP(5000)", new QueryOptions(-1, 30, false)));
        Assert.check(System.nanoTime() - t0 < 1_000_000_000L, "timeout honoured promptly");
    }

    static void testUnsupportedSyntax() {
        Engine e = engine();
        for (String sql : List.of("SELECT * FROM people a RIGHT JOIN people b ON a.id = b.id",
                "SELECT id FROM people UNION SELECT id FROM people")) {
            Assert.fails(ErrorCode.UNSUPPORTED, () -> e.query(sql, QueryOptions.DEFAULT));
        }
    }
}
