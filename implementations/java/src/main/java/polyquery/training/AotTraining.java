package polyquery.training;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.Random;
import java.util.stream.Stream;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.json.JsonWriter;
import polyquery.protocol.Logger;
import polyquery.protocol.RequestHandler;

/**
 * Training run for the JVM's ahead-of-time cache, executed by {@code make build} with
 * {@code -XX:AOTCacheOutput}: it generates synthetic tables, loads them from CSV and runs a
 * generic mix of queries (filters, grouping, joins, DISTINCT, top-N, sorting, subqueries, CASE,
 * string and date functions, UNION ALL) through the session protocol several times. The cache
 * then holds the engine's classes already loaded and linked plus the method profiles of its hot
 * paths, so a fresh engine process compiles them early: first executions of queries are several
 * times faster. Neither the data nor the queries are those of any benchmark.
 */
public final class AotTraining {
    private static final int FACT_ROWS = 300_000;
    private static final int DIM_ROWS = 5_000;
    private static final int REPEAT = 12;

    private static final List<String> QUERIES = List.of(
            "SELECT COUNT(*), SUM(d), AVG(f), MIN(ts), MAX(day) FROM fact WHERE s = 'v3' AND d > 10",
            "SELECT k1, COUNT(*), SUM(d), AVG(f), MIN(s), MAX(d) FROM fact GROUP BY k1 ORDER BY k1",
            "SELECT k2, COUNT(*) AS n, SUM(d) AS total FROM fact GROUP BY k2 ORDER BY total DESC, k2 LIMIT 10",
            "SELECT g.grp, COUNT(*), SUM(x.d) FROM fact x JOIN dim g ON g.k2 = x.k2 GROUP BY g.grp",
            "SELECT x.id, g.name FROM fact x LEFT JOIN dim g ON g.k2 = x.k2 AND g.w > 5 WHERE x.k1 < 3",
            "SELECT g.grp, COUNT(x.id), SUM(x.n) FROM dim g LEFT JOIN fact x ON x.k2 = g.k2 GROUP BY g.grp",
            "SELECT h.name, COUNT(*) FROM fact x JOIN dim g ON g.k2 = x.k2 JOIN dim h ON h.k2 = g.k2 + 1 "
                    + "WHERE g.grp = 'g2' GROUP BY h.name",
            "SELECT id, d FROM fact WHERE b ORDER BY d DESC, id LIMIT 25",
            "SELECT id, s2 FROM fact ORDER BY s2, id LIMIT 50",
            "SELECT id, f FROM fact WHERE k1 = 1 ORDER BY f",
            "SELECT DATE_TRUNC('month', ts) AS m, YEAR(day), COUNT(*), SUM(d) FROM fact GROUP BY 1, 2 ORDER BY 1, 2",
            "SELECT HOUR(ts), AVG(f), MIN(d), MAX(f) FROM fact WHERE b GROUP BY HOUR(ts)",
            "SELECT s, COUNT(DISTINCT k2), COUNT(DISTINCT s2), SUM(DISTINCT k1), AVG(DISTINCT d) FROM fact GROUP BY s",
            "SELECT COUNT(DISTINCT k2), COUNT(DISTINCT day) FROM fact",
            "SELECT COUNT(*) FROM (SELECT DISTINCT k1, s FROM fact) t",
            "SELECT DISTINCT k2 FROM fact WHERE k1 = 4",
            "SELECT COUNT(*) FROM fact WHERE s2 LIKE '%7' AND s IN ('v1', 'v2')",
            "SELECT k1 % 7, CASE WHEN n IS NULL THEN 'none' WHEN n > 10 THEN 'big' ELSE 'small' END, COUNT(*), "
                    + "SUM(n), COUNT(n) FROM fact GROUP BY 1, 2",
            "SELECT s, SUM(CASE WHEN b THEN d ELSE 0 END), SUM(CASE WHEN n > 5 THEN 1 ELSE 0 END) FROM fact GROUP BY s",
            "SELECT COUNT(*), SUM(d) FROM fact WHERE k2 IN (SELECT k2 FROM dim WHERE grp = 'g1')",
            "SELECT COUNT(*) FROM fact WHERE d > (SELECT AVG(d) FROM fact)",
            "SELECT COUNT(*) FROM dim g WHERE EXISTS (SELECT 1 FROM fact x WHERE x.k2 = g.k2 AND x.k1 = 3)",
            "WITH t AS (SELECT k2, SUM(d) AS total FROM fact GROUP BY k2) "
                    + "SELECT g.grp, COUNT(*), AVG(t.total) FROM t JOIN dim g ON g.k2 = t.k2 GROUP BY g.grp",
            "SELECT id, d * 2 + f, UPPER(s), COALESCE(n, 0), SUBSTR(s2, 1, 3), ROUND(f, 1), LENGTH(s2) "
                    + "FROM fact WHERE k1 = 3",
            "SELECT k1, SUM(d) FROM fact GROUP BY k1 HAVING COUNT(*) > 10 ORDER BY 2 DESC LIMIT 5",
            "SELECT COUNT(*), SUM(d) FROM fact WHERE ts >= CAST('2024-03-01 00:00:00' AS TIMESTAMP) "
                    + "AND ts < CAST('2024-04-01 00:00:00' AS TIMESTAMP) AND id % 3 = 0",
            "SELECT COUNT(*) FROM fact WHERE id BETWEEN 1000 AND 200000 AND k1 <> 5 AND n IS NOT NULL",
            "SELECT id, k1 FROM fact WHERE k1 < 2 UNION ALL SELECT k2, 1 FROM dim",
            "SELECT SUM(id), MIN(k1), MAX(k2), COUNT(*), MIN(ts), MAX(ts) FROM fact",
            "SELECT k1, COUNT(*) FROM fact WHERE n IS NULL OR f < 0.5 GROUP BY k1");

    private AotTraining() {
    }

    public static void main(String[] args) throws IOException {
        Path dir = Files.createTempDirectory("polyquery-aot");
        try {
            writeFact(dir.resolve("fact.csv"));
            writeDim(dir.resolve("dim.csv"));
            EngineConfig config = new EngineConfig(dir, false, EngineConfig.DEFAULT_QUERY_MEMORY_MB << 20,
                    EngineConfig.DEFAULT_INGEST_BYTES, EngineConfig.DEFAULT_TABLE_ROWS, EngineConfig.DEFAULT_JOIN_ROWS,
                    Runtime.getRuntime().availableProcessors());
            RequestHandler handler = new RequestHandler(new Engine(config), new Logger(Logger.Level.OFF, System.err));
            run(handler, "{\"op\":\"load\",\"table\":\"fact\",\"format\":\"csv\",\"path\":\"fact.csv\"}");
            run(handler, "{\"op\":\"load\",\"table\":\"dim\",\"format\":\"csv\",\"path\":\"dim.csv\"}");
            run(handler, "{\"op\":\"stats\",\"table\":\"fact\"}");
            for (int r = 0; r < REPEAT; r++) {
                for (String sql : QUERIES) {
                    run(handler, "{\"op\":\"query\",\"sql\":" + JsonWriter.write(sql) + "}");
                }
            }
        } finally {
            try (Stream<Path> files = Files.walk(dir)) {
                files.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
    }

    private static void run(RequestHandler handler, String request) {
        String response = handler.handleLine(request);
        if (!response.contains("\"ok\":true")) {
            throw new IllegalStateException("training request failed: " + request + " -> " + response);
        }
    }

    private static void writeFact(Path file) throws IOException {
        Random r = new Random(42);
        try (Writer w = Files.newBufferedWriter(file, StandardCharsets.UTF_8)) {
            w.write("id,k1,k2,d,f,s,s2,day,ts,b,n\n");
            StringBuilder sb = new StringBuilder(128);
            for (int i = 1; i <= FACT_ROWS; i++) {
                sb.setLength(0);
                int day = 1 + r.nextInt(28);
                int month = 1 + r.nextInt(12);
                sb.append(i).append(',')
                        .append(r.nextInt(50)).append(',')
                        .append(r.nextInt(DIM_ROWS * 2)).append(',')
                        .append(r.nextInt(100_000) / 100).append('.').append(10 + r.nextInt(90)).append(',')
                        .append(r.nextDouble()).append(',')
                        .append('v').append(r.nextInt(20)).append(',')
                        .append("w").append(r.nextInt(FACT_ROWS / 3)).append(',')
                        .append(String.format("2023-%02d-%02d", month, day)).append(',')
                        .append(String.format("2024-%02d-%02d %02d:%02d:%02d", month, day, r.nextInt(24),
                                r.nextInt(60), r.nextInt(60))).append(',')
                        .append(r.nextBoolean()).append(',');
                if (r.nextInt(3) != 0) {
                    sb.append(r.nextInt(1000));
                }
                sb.append('\n');
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
