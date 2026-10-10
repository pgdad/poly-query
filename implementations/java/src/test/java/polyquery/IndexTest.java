package polyquery;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.engine.LoadRequest;
import polyquery.engine.QueryOptions;
import polyquery.index.Index;
import polyquery.index.IndexKind;
import polyquery.index.KeyPredicate;
import polyquery.json.JsonWriter;
import polyquery.storage.ColumnVector;
import polyquery.storage.ColumnarData;
import polyquery.types.DataType;

/** Index structures, key predicates, index DDL and index selection. */
final class IndexTest {
    private IndexTest() {
    }

    private static Index build(IndexKind kind, Long... values) {
        ColumnVector.Builder b = ColumnVector.builder(DataType.INT64, values.length);
        for (Long v : values) {
            b.append(v);
        }
        return Index.build("i", new ColumnarData(new ColumnVector[] {b.build()}, values.length), 0, DataType.INT64,
                kind);
    }

    private static String ids(int[] rows) {
        return java.util.Arrays.toString(rows);
    }

    static void testLookups() {
        Index btree = build(IndexKind.BTREE, 5L, null, 3L, 5L, 9L, 1L);
        Index hash = build(IndexKind.HASH, 5L, null, 3L, 5L, 9L, 1L);
        KeyPredicate eq = new KeyPredicate.Points(List.of(5L));
        Assert.eq("[0, 3]", ids(btree.structure().lookup(eq)));
        Assert.eq("[0, 3]", ids(hash.structure().lookup(eq)));
        KeyPredicate in = KeyPredicate.Points.of(List.of(9L, 1L, 9L));
        Assert.eq("[4, 5]", ids(hash.structure().lookup(in)));
        Assert.eq("[4, 5]", ids(btree.structure().lookup(in)));
        Assert.eq("[0, 2, 3]", ids(btree.structure().lookup(new KeyPredicate.Range(3L, true, 5L, true))));
        Assert.eq("[0, 3]", ids(btree.structure().lookup(new KeyPredicate.Range(3L, false, 9L, false))));
        Assert.eq("[0, 2, 3, 4, 5]", ids(btree.structure().lookup(new KeyPredicate.Range(null, false, null, false))));
        Assert.check(!hash.structure().supports(new KeyPredicate.Range(1L, true, null, false)), "hash: no ranges");
        Assert.eq(4, btree.structure().distinctKeys());
    }

    static void testKeyPredicateAlgebra() {
        KeyPredicate a = new KeyPredicate.Range(1L, true, 10L, false);
        KeyPredicate b = new KeyPredicate.Range(5L, false, null, false);
        Assert.eq(new KeyPredicate.Range(5L, false, 10L, false), a.and(b));
        Assert.eq(new KeyPredicate.Empty(), a.and(new KeyPredicate.Range(10L, true, null, false)));
        Assert.eq(new KeyPredicate.Points(List.of(7L)), a.and(KeyPredicate.Points.of(List.of(7L, 12L))));
        Assert.check(a.overlaps(9L, 20L), "overlap");
        Assert.check(!a.overlaps(10L, 20L), "upper bound is exclusive");
        Assert.check(!new KeyPredicate.Points(List.of(4L)).overlaps(5L, 9L), "point outside");
    }

    private static Engine engine() {
        Engine e = new Engine(new EngineConfig(Path.of(".").toAbsolutePath(), false, 1L << 30, 1L << 30,
                1_000_000, 1_000_000, 1));
        StringBuilder csv = new StringBuilder("id,grp,amount,day\n");
        for (int i = 1; i <= 1000; i++) {
            csv.append(i).append(',').append(i % 4).append(',').append(i).append(".25,2024-01-")
                    .append(String.format("%02d", 1 + i % 28)).append('\n');
        }
        e.load(new LoadRequest("t", "csv", null, csv.toString(), null, true, ',', false));
        return e;
    }

    private static String plan(Engine e, String sql, QueryOptions opts) {
        Map<String, Object> p = e.explain(sql, opts);
        return JsonWriter.write(p);
    }

    static void testDdl() {
        Engine e = engine();
        EngineTest.rows(e, "CREATE INDEX t_id ON t (id) USING HASH");
        EngineTest.rows(e, "CREATE INDEX IF NOT EXISTS T_ID ON t (grp)");
        Assert.fails(ErrorCode.ALREADY_EXISTS, () -> EngineTest.rows(e, "CREATE INDEX t_id ON t (grp)"));
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> EngineTest.rows(e, "CREATE INDEX x ON t (nope)"));
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> EngineTest.rows(e, "CREATE INDEX x ON nope (id)"));
        EngineTest.rows(e, "DROP INDEX t_ID");
        Assert.fails(ErrorCode.NOT_FOUND, () -> EngineTest.rows(e, "DROP INDEX t_id"));
        EngineTest.rows(e, "DROP INDEX IF EXISTS t_id");
    }

    static void testIndexSelection() {
        Engine e = engine();
        EngineTest.rows(e, "CREATE INDEX t_id ON t (id)");
        EngineTest.rows(e, "CREATE INDEX t_grp ON t (grp) USING HASH");
        EngineTest.rows(e, "CREATE INDEX t_amount ON t (amount)");
        QueryOptions on = QueryOptions.DEFAULT;
        Assert.check(plan(e, "SELECT * FROM t WHERE id = 7", on).contains("\"index\":\"t_id\""), "point lookup");
        Assert.check(plan(e, "SELECT * FROM t WHERE id BETWEEN 10 AND 30", on).contains("IndexScan"), "narrow range");
        Assert.check(!plan(e, "SELECT * FROM t WHERE id > 10", on).contains("IndexScan"), "wide range");
        Assert.check(!plan(e, "SELECT * FROM t WHERE grp = 1", on).contains("IndexScan"), "1/distinct = 25%");
        Assert.check(plan(e, "SELECT * FROM t WHERE amount < 5.5", on).contains("t_amount"), "decimal range");
        QueryOptions off = new QueryOptions(-1, 0, false, true, polyquery.physical.PhysicalPlanner.JoinStrategy.AUTO,
                false);
        Assert.check(!plan(e, "SELECT * FROM t WHERE id = 7", off).contains("IndexScan"), "use_indexes=false");
        Assert.eq("[[2],[3],[4]]", EngineTest.rows(e, "SELECT id FROM t WHERE amount BETWEEN 1.5 AND 4.25 ORDER BY id"));
        Assert.eq("[[1]]", EngineTest.rows(e, "SELECT id FROM t WHERE amount = 1.250"));
        Assert.eq("[]", EngineTest.rows(e, "SELECT id FROM t WHERE amount = 1.251"));
        Assert.eq("[[5],[6]]", EngineTest.rows(e, "SELECT id FROM t WHERE id IN (6, 5, NULL, 5) ORDER BY id"));
    }

    static void testColumnPruningAndBuildSide() {
        Engine e = engine();
        String p = plan(e, "SELECT a.id FROM t a JOIN (SELECT id, grp FROM t WHERE id < 5) b ON a.id = b.id",
                QueryOptions.DEFAULT);
        Assert.check(p.contains("\"columns\":[\"id\"]"), "scans read only id: " + p);
        Assert.check(p.contains("\"build_side\":\"right\""), "smaller (filtered) right input is the build side");
        p = plan(e, "SELECT a.id FROM (SELECT id FROM t WHERE id < 5) a JOIN t b ON a.id = b.id", QueryOptions.DEFAULT);
        Assert.check(p.contains("\"build_side\":\"left\""), "smaller left input is the build side: " + p);
        Assert.eq("[[1],[2],[3],[4]]", EngineTest.rows(e,
                "SELECT b.id FROM (SELECT id FROM t WHERE id < 5) a JOIN t b ON a.id = b.id ORDER BY 1"));
    }
}
