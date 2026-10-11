package polyquery.training;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.UncheckedIOException;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Random;
import java.util.stream.Stream;
import polyquery.Main;
import polyquery.json.JsonWriter;

/**
 * Training run for the JVM's ahead-of-time cache, executed by {@code make build} with
 * {@code -XX:AOTCacheOutput}: it generates synthetic tables, then drives the real entry point
 * ({@link Main#run} in {@code session} mode, requests on stdin, responses on stdout — exactly the
 * path of {@code bin/polyquery session}) through loading them from CSV with explicit schemas,
 * creating indexes and running a generic mix of queries (filters, index lookups, arithmetic,
 * grouping, joins, DISTINCT, top-N, full sorts, subqueries, CTEs, CASE, NULL handling, string
 * and date functions, UNION ALL) several times. The cache then holds the engine's classes
 * already loaded and linked plus the method profiles of its hot paths, so a fresh engine process
 * starts faster and compiles them early: first executions of queries are several times faster.
 * Neither the data nor the queries are those of any benchmark.
 */
public final class AotTraining {
    private static final int FACT_ROWS = 300_000;
    private static final int DIM_ROWS = 5_000;
    private static final int REPEAT = 12;

    private static final String FACT_SCHEMA = "[{\"name\":\"id\",\"type\":\"INT64\"},{\"name\":\"k1\",\"type\":\"INT64\"},"
            + "{\"name\":\"k2\",\"type\":\"INT64\"},{\"name\":\"d\",\"type\":\"DECIMAL(12,2)\"},"
            + "{\"name\":\"e\",\"type\":\"DECIMAL(10,2)\"},{\"name\":\"f\",\"type\":\"FLOAT64\"},"
            + "{\"name\":\"g\",\"type\":\"FLOAT64\"},{\"name\":\"s\",\"type\":\"STRING\"},"
            + "{\"name\":\"s2\",\"type\":\"STRING\"},{\"name\":\"ns\",\"type\":\"STRING\"},"
            + "{\"name\":\"day\",\"type\":\"DATE\"},{\"name\":\"ts\",\"type\":\"TIMESTAMP\"},"
            + "{\"name\":\"b\",\"type\":\"BOOLEAN\"},{\"name\":\"n\",\"type\":\"INT64\"},"
            + "{\"name\":\"u\",\"type\":\"INT64\"}]";
    private static final String DIM_SCHEMA = "[{\"name\":\"k2\",\"type\":\"INT64\"},{\"name\":\"name\",\"type\":\"STRING\"},"
            + "{\"name\":\"grp\",\"type\":\"STRING\"},{\"name\":\"w\",\"type\":\"DECIMAL(6,2)\"}]";

    private static final List<String> STATEMENTS = List.of(
            "CREATE INDEX fact_k2 ON fact (k2) USING HASH",
            "CREATE INDEX fact_ts ON fact (ts) USING BTREE");

    private static final List<String> QUERIES = List.of(
            "SELECT COUNT(*), SUM(d), AVG(f), MIN(ts), MAX(day) FROM fact WHERE s = 'v3' AND d > 10",
            "SELECT COUNT(*), MAX(e), SUM(d) FROM fact WHERE s <> 'v7' AND k1 > 2",
            "SELECT COUNT(*), AVG(d) FROM fact WHERE k2 = 1234",
            "SELECT k1, COUNT(*) FROM fact WHERE ts >= TIMESTAMP '2024-05-03 00:00:00' "
                    + "AND ts < TIMESTAMP '2024-05-20 12:00:00' GROUP BY k1",
            "SELECT MAX(d * 3 - e), SUM(e + d), MIN(d - e), AVG(k2), SUM(k1 * 2 + 1) FROM fact",
            "SELECT k1, COUNT(*), SUM(d), AVG(f), MIN(s), MAX(d) FROM fact GROUP BY k1 ORDER BY k1",
            "SELECT k2, COUNT(*) AS n, SUM(d) AS total FROM fact GROUP BY k2 ORDER BY total DESC, k2 LIMIT 10",
            "SELECT u % 1000 AS r, COUNT(*) AS c FROM fact GROUP BY u % 1000 ORDER BY c DESC, r LIMIT 7",
            "SELECT k1 % 6 AS m, s, COUNT(*), SUM(e) FROM fact GROUP BY k1 % 6, s ORDER BY s, m LIMIT 40",
            "SELECT g.grp, COUNT(*), SUM(x.d) FROM fact x JOIN dim g ON g.k2 = x.k2 GROUP BY g.grp",
            "SELECT x.id, g.name FROM fact x LEFT JOIN dim g ON g.k2 = x.k2 AND g.w > 5 WHERE x.k1 < 3",
            "SELECT g.grp, COUNT(x.id), SUM(x.n) FROM dim g LEFT JOIN fact x ON x.k2 = g.k2 GROUP BY g.grp",
            "SELECT COUNT(*) FROM dim g LEFT JOIN fact x ON x.k2 = g.k2 AND x.k1 = 7 WHERE x.id IS NULL",
            "SELECT h.name, COUNT(*) FROM fact x JOIN dim g ON g.k2 = x.k2 JOIN dim h ON h.k2 = g.k2 + 1 "
                    + "WHERE g.grp = 'g2' GROUP BY h.name",
            "SELECT g.grp, h.grp, SUM(x.e * x.k1) FROM fact x JOIN dim g ON g.k2 = x.k2 "
                    + "JOIN dim h ON h.k2 = x.k1 * 2 WHERE x.b GROUP BY g.grp, h.grp ORDER BY 3 DESC",
            "SELECT id, d FROM fact WHERE b ORDER BY d DESC, id LIMIT 25",
            "SELECT id, s2 FROM fact ORDER BY s2, id LIMIT 50",
            "SELECT id, u FROM fact ORDER BY u DESC LIMIT 30",
            "SELECT id, f FROM fact WHERE k1 = 1 ORDER BY f",
            "SELECT s2, id FROM fact WHERE k1 < 25 ORDER BY s2 DESC, id",
            "SELECT k1, g, id FROM fact WHERE k2 < 6000 ORDER BY k1 DESC, g, id",
            "SELECT DATE_TRUNC('month', ts) AS m, YEAR(day), COUNT(*), SUM(d) FROM fact GROUP BY 1, 2 ORDER BY 1, 2",
            "SELECT k1, DATE_TRUNC('day', ts) AS t, MIN(f), MAX(g) FROM fact WHERE k1 < 4 "
                    + "GROUP BY k1, DATE_TRUNC('day', ts) ORDER BY t, k1 LIMIT 60",
            "SELECT HOUR(ts), AVG(f), MIN(d), MAX(f) FROM fact WHERE b GROUP BY HOUR(ts)",
            "SELECT s, COUNT(DISTINCT k2), COUNT(DISTINCT s2), SUM(DISTINCT k1), AVG(DISTINCT d) FROM fact GROUP BY s",
            "SELECT COUNT(DISTINCT k2), COUNT(DISTINCT day), COUNT(DISTINCT u % 5000) FROM fact",
            "SELECT COUNT(*) FROM (SELECT DISTINCT k1, s FROM fact) t",
            "SELECT DISTINCT k2 FROM fact WHERE k1 = 4",
            "SELECT COUNT(*) FROM fact WHERE s2 LIKE '%7' AND s IN ('v1', 'v2')",
            "SELECT s, MAX(LENGTH(s2)), SUM(CASE WHEN s2 LIKE 'w1%' THEN 1 ELSE 0 END) FROM fact "
                    + "WHERE LOWER(s) <> 'v4' GROUP BY s",
            "SELECT k1 % 7, CASE WHEN n IS NULL THEN 'none' WHEN n > 10 THEN 'big' ELSE 'small' END, COUNT(*), "
                    + "SUM(n), COUNT(n) FROM fact GROUP BY 1, 2",
            "SELECT s, SUM(CASE WHEN b THEN d ELSE 0 END), SUM(CASE WHEN n > 5 THEN 1 ELSE 0 END) FROM fact GROUP BY s",
            "SELECT COUNT(g), SUM(n), COUNT(ns), MIN(g), COUNT(*) FROM fact WHERE ns IS NOT NULL OR b = false",
            "SELECT n % 9, COUNT(*), SUM(g), COUNT(ns) FROM fact GROUP BY n % 9 ORDER BY 1",
            "SELECT COUNT(*), SUM(d) FROM fact WHERE k2 IN (SELECT k2 FROM dim WHERE grp = 'g1')",
            "SELECT COUNT(*) FROM fact WHERE d > (SELECT AVG(d) FROM fact)",
            "SELECT COUNT(*) FROM dim g WHERE EXISTS (SELECT 1 FROM fact x WHERE x.k2 = g.k2 AND x.k1 = 3)",
            "WITH t AS (SELECT k2, SUM(d) AS total FROM fact GROUP BY k2) "
                    + "SELECT g.grp, COUNT(*), AVG(t.total) FROM t JOIN dim g ON g.k2 = t.k2 GROUP BY g.grp",
            "WITH c AS (SELECT k1, k2, COUNT(*) AS cnt FROM fact GROUP BY k1, k2) "
                    + "SELECT k1, COUNT(*) FROM c WHERE cnt >= (SELECT MAX(cnt) FROM c) - 3 GROUP BY k1",
            "SELECT id, d * 2 + f, UPPER(s), COALESCE(n, 0), SUBSTR(s2, 1, 3), ROUND(f, 1), LENGTH(s2) "
                    + "FROM fact WHERE k1 = 3",
            "SELECT k1, SUM(d) FROM fact GROUP BY k1 HAVING COUNT(*) > 10 ORDER BY 2 DESC LIMIT 5",
            "SELECT COUNT(*), SUM(d) FROM fact WHERE ts >= CAST('2024-03-01 00:00:00' AS TIMESTAMP) "
                    + "AND ts < CAST('2024-04-01 00:00:00' AS TIMESTAMP) AND id % 3 = 0",
            "SELECT COUNT(*) FROM fact WHERE id BETWEEN 1000 AND 200000 AND k1 <> 5 AND n IS NOT NULL",
            "SELECT id, k1 FROM fact WHERE k1 < 2 UNION ALL SELECT k2, 1 FROM dim",
            "SELECT SUM(id), MIN(k1), MAX(k2), COUNT(*), MIN(ts), MAX(ts) FROM fact",
            "SELECT k1, COUNT(*) FROM fact WHERE n IS NULL OR f < 0.5 GROUP BY k1");

    /** Queries whose result is requested as a count only (large outputs). */
    private static final List<String> COUNT_QUERIES = List.of(
            "SELECT id, s2 FROM fact ORDER BY s2, id",
            "SELECT k1, f, id FROM fact ORDER BY k1 DESC, f, id");

    private AotTraining() {
    }

    public static void main(String[] args) throws IOException {
        Path dir = Files.createTempDirectory("polyquery-aot");
        try {
            writeFact(dir.resolve("fact.csv"));
            writeDim(dir.resolve("dim.csv"));
            List<String> requests = new ArrayList<>();
            requests.add("{\"op\":\"version\"}");
            requests.add("{\"op\":\"load\",\"table\":\"fact\",\"format\":\"csv\",\"path\":\"fact.csv\",\"schema\":"
                    + FACT_SCHEMA + "}");
            requests.add("{\"op\":\"load\",\"table\":\"dim\",\"format\":\"csv\",\"path\":\"dim.csv\",\"schema\":"
                    + DIM_SCHEMA + "}");
            for (String sql : STATEMENTS) {
                requests.add(query(sql, ""));
            }
            requests.add("{\"op\":\"stats\",\"table\":\"fact\"}");
            for (int r = 0; r < REPEAT; r++) {
                for (String sql : QUERIES) {
                    requests.add(query(sql, ""));
                }
                for (String sql : COUNT_QUERIES) {
                    requests.add(query(sql, ",\"options\":{\"result\":\"count\"}"));
                }
            }
            session(dir, requests);
        } finally {
            try (Stream<Path> files = Files.walk(dir)) {
                files.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
    }

    private static String query(String sql, String extra) {
        return "{\"op\":\"query\",\"sql\":" + JsonWriter.write(sql) + extra + "}";
    }

    /** Runs the requests through {@code polyquery session} with stdin/stdout redirected. */
    private static void session(Path dir, List<String> requests) {
        byte[] input = (String.join("\n", requests) + "\n").getBytes(StandardCharsets.UTF_8);
        ResponseChecker checker = new ResponseChecker();
        InputStream stdin = System.in;
        PrintStream stdout = System.out;
        System.setIn(new ByteArrayInputStream(input));
        System.setOut(new PrintStream(checker, false, StandardCharsets.UTF_8));
        int exit;
        try {
            exit = Main.run(new String[] {"session", "--data-dir", dir.toString()});
        } finally {
            System.out.flush();
            System.setIn(stdin);
            System.setOut(stdout);
        }
        if (exit != 0 || checker.lines != requests.size() || checker.failed != null) {
            throw new IllegalStateException("training session failed (exit " + exit + ", " + checker.lines + "/"
                    + requests.size() + " responses): " + checker.failed);
        }
    }

    /** Counts response lines and remembers the first one that does not report success. */
    private static final class ResponseChecker extends OutputStream {
        private static final byte[] OK = "\"ok\":true".getBytes(StandardCharsets.UTF_8);
        private final byte[] head = new byte[256];
        private int len;
        int lines;
        String failed;

        @Override
        public void write(int b) {
            if (b == '\n') {
                if (failed == null && !contains(head, len, OK)) {
                    failed = new String(head, 0, len, StandardCharsets.UTF_8);
                }
                lines++;
                len = 0;
            } else if (len < head.length) {
                head[len++] = (byte) b;
            }
        }

        @Override
        public void write(byte[] b, int off, int n) {
            for (int i = off; i < off + n; i++) {
                write(b[i]);
            }
        }

        private static boolean contains(byte[] a, int n, byte[] p) {
            outer:
            for (int i = 0; i + p.length <= n; i++) {
                for (int j = 0; j < p.length; j++) {
                    if (a[i + j] != p[j]) {
                        continue outer;
                    }
                }
                return true;
            }
            return false;
        }
    }

    private static void writeFact(Path file) throws IOException {
        Random r = new Random(42);
        try (Writer w = Files.newBufferedWriter(file, StandardCharsets.UTF_8)) {
            w.write("id,k1,k2,d,e,f,g,s,s2,ns,day,ts,b,n,u\n");
            StringBuilder sb = new StringBuilder(160);
            for (int i = 1; i <= FACT_ROWS; i++) {
                sb.setLength(0);
                int day = 1 + r.nextInt(28);
                int month = 1 + r.nextInt(12);
                sb.append(i).append(',')
                        .append(r.nextInt(50)).append(',')
                        .append(r.nextInt(DIM_ROWS * 2)).append(',')
                        .append(r.nextInt(100_000) / 100).append('.').append(10 + r.nextInt(90)).append(',')
                        .append(r.nextInt(500)).append('.').append(r.nextInt(10)).append(r.nextInt(10)).append(',')
                        .append(r.nextDouble()).append(',');
                if (r.nextInt(4) != 0) {
                    sb.append(r.nextInt(2_000_000) / 100.0 - 5000);
                }
                sb.append(',')
                        .append('v').append(r.nextInt(20)).append(',')
                        .append("w").append(r.nextInt(FACT_ROWS / 3)).append(',');
                if (r.nextInt(5) < 2) {
                    sb.append('x').append(r.nextInt(300));
                }
                sb.append(',')
                        .append(String.format("2023-%02d-%02d", month, day)).append(',')
                        .append(String.format("2024-%02d-%02d %02d:%02d:%02d.%06d", month, day, r.nextInt(24),
                                r.nextInt(60), r.nextInt(60), r.nextInt(1000) * 1000)).append(',')
                        .append(r.nextBoolean()).append(',');
                if (r.nextInt(3) != 0) {
                    sb.append(r.nextInt(1000));
                }
                sb.append(',').append(r.nextLong()).append('\n');
                w.write(sb.toString());
            }
        } catch (UncheckedIOException e) {
            throw e.getCause();
        }
    }

    private static void writeDim(Path file) throws IOException {
        Random r = new Random(7);
        try (Writer w = Files.newBufferedWriter(file, StandardCharsets.UTF_8)) {
            w.write("k2,name,grp,w\n");
            for (int i = 0; i < DIM_ROWS; i++) {
                w.write(i * 2 + "," + "name" + i + ",g" + r.nextInt(8) + "," + r.nextInt(1000) / 100 + "."
                        + (10 + r.nextInt(90)) + "\n");
            }
        }
    }
}
