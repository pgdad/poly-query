package polyquery;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.engine.LoadRequest;
import polyquery.engine.QueryOptions;
import polyquery.exec.ExecMode;
import polyquery.exec.QueryResult;
import polyquery.physical.PhysicalPlanner.JoinStrategy;

/**
 * Phase 5 end to end: every query must give the same result (rows, or error code) under every
 * combination of execution mode, join algorithm, thread count and optimization — also with
 * tiny batches and morsels, which exercise batch boundaries, parallel workers and the
 * deferred (row-exact) error semantics.
 */
final class Phase5Test {
    private Phase5Test() {
    }

    private static Engine engine() {
        return engine(null);
    }

    static Engine engine(polyquery.ffi.NativeKernels kernels) {
        Engine e = EngineTest.engine(kernels);
        StringBuilder csv = new StringBuilder("id,grp,val,amt,name,flag,day\n");
        for (int i = 1; i <= 600; i++) {
            csv.append(i).append(',')
                    .append(i % 7 == 0 ? "" : String.valueOf(i % 13)).append(',')
                    .append(i % 11 == 0 ? "" : String.valueOf((i * 37) % 101 - 50)).append(',')
                    .append(i % 5).append('.').append(i % 100 < 10 ? "0" : "").append(i % 100).append(',')
                    .append(i % 9 == 0 ? "" : "n" + (i % 17)).append(',')
                    .append(i % 3 == 0).append(',')
                    .append("2024-01-").append(String.format("%02d", 1 + i % 28)).append('\n');
        }
        e.load(new LoadRequest("t", "csv", null, csv.toString(), null, true, ',', false));
        StringBuilder dim = new StringBuilder("grp,label,weight\n");
        for (int g = 0; g < 15; g++) {
            dim.append(g).append(",L").append(g % 4).append(',').append(g * 1.5).append('\n');
            if (g % 5 == 0) {
                dim.append(g).append(",dup").append(g).append(",0.5\n");
            }
        }
        e.load(new LoadRequest("d", "csv", null, dim.toString(), null, true, ',', false));
        return e;
    }

    static final String[] QUERIES = {
        "SELECT id, val * 2 + 1, name FROM t WHERE val > 0 AND name LIKE 'n1%'",
        "SELECT grp, COUNT(*), SUM(val), MIN(name), MAX(amt), AVG(val), COUNT(DISTINCT name) FROM t GROUP BY grp",
        "SELECT COUNT(*), SUM(val), SUM(amt), MIN(day), MAX(id), COUNT(val) FROM t WHERE flag",
        "SELECT d.label, COUNT(*), SUM(t.amt) FROM t JOIN d ON d.grp = t.grp GROUP BY d.label",
        "SELECT t.id, d.label FROM t LEFT JOIN d ON d.grp = t.grp AND d.weight > 3 WHERE t.id < 100",
        "SELECT t.id, d.label FROM t JOIN d ON t.grp = d.grp AND t.val < d.weight * 10 ORDER BY 1, 2",
        "SELECT DISTINCT grp, flag FROM t",
        "SELECT id, amt FROM t ORDER BY amt DESC, id LIMIT 17 OFFSET 3",
        "SELECT name, id FROM t ORDER BY name NULLS FIRST, id DESC",
        "SELECT id FROM t ORDER BY val, id LIMIT 5",
        "SELECT id, CASE WHEN val IS NULL THEN 'none' WHEN val > 10 THEN 'big' ELSE 'small' END FROM t",
        "SELECT grp, COUNT(*) FROM t WHERE grp IN (1, 2, 3, NULL) OR val BETWEEN -5 AND 5 GROUP BY grp",
        "SELECT id FROM t WHERE id IN (SELECT grp * 10 FROM d) AND EXISTS (SELECT 1 FROM d WHERE d.grp = t.grp)",
        "SELECT id, (SELECT MAX(weight) FROM d WHERE d.grp = t.grp) FROM t WHERE id < 40",
        "SELECT id, 1000 / (grp - 3) FROM t WHERE id < 30",
        "SELECT id FROM t WHERE 100 / (grp - 5) > 0 LIMIT 3",
        "SELECT SUM(id * 4611686018427387) FROM t",
        "SELECT grp, SUM(val) FROM t GROUP BY grp HAVING SUM(val) > 0",
        "SELECT UPPER(name) || '-' || CAST(id AS STRING), COALESCE(val, -1) FROM t WHERE id % 50 = 0",
        "SELECT x, COUNT(*) FROM (SELECT grp + 1 AS x FROM t WHERE val IS NOT NULL) s GROUP BY x",
        // a join condition that may fail (SUBSTR with a column length): nothing moves across it
        "SELECT COUNT(*), SUM(t.val) FROM t JOIN d ON d.grp = t.grp AND SUBSTR(t.name, 1, t.grp) <> 'zz' "
                + "WHERE t.flag AND d.weight > 2",
        "SELECT t.id, d.label FROM t, d WHERE t.grp = d.grp AND t.id / (d.grp - 3) > 0 ORDER BY 1, 2",
        "SELECT t.id FROM t, d WHERE t.grp = d.grp AND d.weight * 1000000 > 1 AND t.val + 1 > 0 ORDER BY 1",
        // UNION ALL (CR-1): branches of different types, aggregation / joins over it, ORDER BY + LIMIT
        "SELECT id, name FROM t WHERE val > 20 UNION ALL SELECT grp, label FROM d UNION ALL SELECT 0, NULL",
        "SELECT amt AS v FROM t WHERE id < 50 UNION ALL SELECT val FROM t WHERE flag UNION ALL SELECT weight FROM d",
        "SELECT x, COUNT(*), SUM(v) FROM (SELECT grp AS x, val AS v FROM t UNION ALL SELECT grp, 1 FROM d) u GROUP BY x",
        "SELECT u.k, d.label FROM (SELECT grp AS k FROM t WHERE id < 90 UNION ALL SELECT grp FROM d) u "
                + "JOIN d ON d.grp = u.k",
        "SELECT name FROM t UNION ALL SELECT label FROM d ORDER BY 1 NULLS FIRST LIMIT 20 OFFSET 5",
        "SELECT DISTINCT grp FROM t UNION ALL SELECT DISTINCT weight FROM d",
        "SELECT id FROM t WHERE grp IN (SELECT grp FROM d WHERE weight > 10 UNION ALL SELECT 2) AND id < 200",
        "SELECT id FROM t WHERE EXISTS (SELECT 1 FROM d WHERE d.grp = t.grp UNION ALL SELECT 1 FROM d WHERE t.val > 45)",
        "SELECT id FROM t WHERE id < 5 UNION ALL SELECT 1000 / (grp - 3) FROM t",
        "SELECT id FROM t WHERE id < 5 UNION ALL SELECT 1000 / (grp - 3) FROM t LIMIT 3",
    };

    /** A result: column list and rows (sorted unless the query orders them), or an error code. */
    private record Outcome(String columns, List<Object[]> rows, ErrorCode error) {
        boolean matches(Outcome o) {
            if (error != null || o.error != null) {
                return error == o.error;
            }
            if (!columns.equals(o.columns) || rows.size() != o.rows.size()) {
                return false;
            }
            for (int i = 0; i < rows.size(); i++) {
                Object[] a = rows.get(i);
                Object[] b = o.rows.get(i);
                for (int c = 0; c < a.length; c++) {
                    if (a[c] instanceof Double x && b[c] instanceof Double y) {
                        if (Math.abs(x - y) > 1e-9 * Math.max(1, Math.max(Math.abs(x), Math.abs(y)))) {
                            return false;
                        }
                    } else if (!java.util.Objects.equals(a[c], b[c])) {
                        return false;
                    }
                }
            }
            return true;
        }

        @Override
        public String toString() {
            if (error != null) {
                return "error " + error;
            }
            return columns + " " + java.util.Arrays.deepToString(rows.toArray());
        }
    }

    private static String sortKey(Object[] row) {
        StringBuilder sb = new StringBuilder();
        for (Object v : row) {
            sb.append(v instanceof Double d ? String.format("%.6g", d) : String.valueOf(v)).append('|');
        }
        return sb.toString();
    }

    private static Outcome run(Engine e, String sql, QueryOptions o) {
        try {
            QueryResult r = e.query(sql, o);
            List<Object[]> rows = new ArrayList<>(r.rows());
            if (!sql.contains("ORDER BY")) {
                rows.sort(java.util.Comparator.comparing(Phase5Test::sortKey));
            }
            return new Outcome(r.columns().toString(), rows, null);
        } catch (PolyQueryException ex) {
            return new Outcome(null, null, ex.code());
        }
    }

    private static void checkAllCombinations(Engine e) {
        checkAllCombinations(e, QUERIES, false);
    }

    /** Every query gives the row engine's result under every option combination (with {@code native}). */
    static void checkAllCombinations(Engine e, String[] queries, boolean useNative) {
        for (String sql : queries) {
            Outcome expected = run(e, sql, new QueryOptions(-1, 0, false, false, JoinStrategy.AUTO, true,
                    ExecMode.ROW, 1));
            for (ExecMode mode : ExecMode.values()) {
                for (JoinStrategy join : JoinStrategy.values()) {
                    for (int threads : new int[] {1, 4}) {
                        for (boolean optimize : new boolean[] {true, false}) {
                            QueryOptions o = new QueryOptions(-1, 0, false, optimize, join, true, mode, threads,
                                    useNative);
                            Outcome got = run(e, sql, o);
                            if (!got.matches(expected)) {
                                throw new AssertionError(sql + " under " + o + ":\n expected " + expected
                                        + "\n got      " + got);
                            }
                        }
                    }
                }
            }
        }
    }

    static void testOptionMatrixAgrees() {
        checkAllCombinations(engine());
    }

    static void testTinyBatchesAndMorsels() {
        System.setProperty("polyquery.batchSize", "5");
        System.setProperty("polyquery.morselRows", "37");
        System.setProperty("polyquery.parallelBuildRows", "8");
        try {
            checkAllCombinations(engine());
        } finally {
            System.clearProperty("polyquery.batchSize");
            System.clearProperty("polyquery.morselRows");
            System.clearProperty("polyquery.parallelBuildRows");
        }
    }

    static void testErrorsAreRowExact() {
        Engine e = engine();
        System.setProperty("polyquery.batchSize", "64");
        try {
            for (ExecMode mode : ExecMode.values()) {
                QueryOptions o = new QueryOptions(-1, 0, false, true, JoinStrategy.AUTO, true, mode, 4);
                // the failing row is never reached: LIMIT is satisfied first
                Assert.eq(3L, e.query("SELECT 1 / (id - 50) FROM t LIMIT 3", o).rowCount());
                Assert.fails(ErrorCode.DIVISION_BY_ZERO, () -> e.query("SELECT 1 / (id - 50) FROM t LIMIT 60", o));
                // the first failing row decides the error, as in row-at-a-time evaluation
                Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> e.query(
                        "SELECT CASE WHEN id = 30 THEN 9223372036854775807 + id ELSE 1 / (id - 40) END FROM t", o));
                Assert.fails(ErrorCode.DIVISION_BY_ZERO, () -> e.query(
                        "SELECT CASE WHEN id = 50 THEN 9223372036854775807 + id ELSE 1 / (id - 40) END FROM t", o));
            }
        } finally {
            System.clearProperty("polyquery.batchSize");
        }
    }

    static void testExplainShowsForcedJoins() {
        Engine e = engine();
        String sql = "SELECT t.id FROM t JOIN d ON d.grp = t.grp";
        Assert.check(explain(e, sql, JoinStrategy.MERGE).contains("\"MergeJoin\""), "merge join");
        Assert.check(explain(e, sql, JoinStrategy.HASH).contains("\"HashJoin\""), "hash join");
        Assert.check(explain(e, sql, JoinStrategy.NESTED_LOOP).contains("\"NestedLoopJoin\""), "nested loop");
        Assert.check(explain(e, "SELECT id FROM t ORDER BY val LIMIT 3", JoinStrategy.AUTO).contains("\"TopN\""),
                "top-N");
    }

    private static String explain(Engine e, String sql, JoinStrategy join) {
        return polyquery.json.JsonWriter.write(e.explain(sql, new QueryOptions(-1, 0, false, true, join)));
    }
}
