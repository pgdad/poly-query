package polyquery;

import java.io.IOException;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.SplittableRandom;
import java.util.stream.Stream;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.json.JsonWriter;
import polyquery.protocol.Logger;
import polyquery.protocol.RequestHandler;

/**
 * The JIT training run used at build time to create the JVM's ahead-of-time cache
 * ({@code -XX:AOTCacheOutput}, see README "JIT warm-up"): it generates synthetic tables of
 * the usual analytical shapes (integer keys of low and high cardinality, DECIMAL amounts,
 * FLOAT64 measures, timestamps, dictionary and free-text strings, NULL-heavy columns), loads
 * them through the protocol and runs a broad mix of query shapes — filters, aggregation,
 * DISTINCT, joins, sorts, top-N, subqueries — each several times, through the same request
 * path as {@code session}. The JVM records the classes loaded and the method profiles, so a
 * later engine process compiles its hot paths much sooner. Nothing here affects results.
 *
 * <p>Usage: {@code java -XX:AOTCacheOutput=FILE -cp polyquery.jar polyquery.Training [ROWS]}.
 */
public final class Training {
    private static final String[] CATEGORIES = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta",
        "theta", "iota", "kappa", "lambda", "mu"};
    private static final String[] STATES = {"open", "closed", "pending", "failed"};
    private static final String[] REGIONS = {"north", "south", "east", "west", "central"};

    private Training() {
    }

    public static void main(String[] args) throws Exception {
        int rows = args.length > 0 ? Integer.parseInt(args[0]) : 300_000;
        int iterations = args.length > 1 ? Integer.parseInt(args[1]) : 8;
        Path dir = Files.createTempDirectory("polyquery-training");
        Throwable[] failure = {null};
        Thread t = new Thread(null, () -> {
            try {
                run(dir, rows, iterations);
            } catch (Throwable e) {
                failure[0] = e;
            }
        }, "polyquery-main", 1L << 30);
        t.start();
        t.join();
        try (Stream<Path> files = Files.walk(dir)) {
            for (Path p : files.sorted(Comparator.reverseOrder()).toList()) {
                Files.deleteIfExists(p);
            }
        }
        if (failure[0] != null) {
            System.err.println("training failed: " + failure[0]);
            System.exit(1);
        }
        System.exit(0);
    }

    private static void run(Path dir, int rows, int iterations) throws IOException {
        writeTables(dir, rows);
        EngineConfig config = new EngineConfig(dir, false, EngineConfig.DEFAULT_QUERY_MEMORY_MB << 20,
                EngineConfig.DEFAULT_INGEST_BYTES, EngineConfig.DEFAULT_TABLE_ROWS, EngineConfig.DEFAULT_JOIN_ROWS,
                Runtime.getRuntime().availableProcessors());
        RequestHandler handler = new RequestHandler(new Engine(config), new Logger(Logger.Level.OFF, System.err));
        send(handler, load("facts", "facts.csv", "[{\"name\":\"id\",\"type\":\"INT64\"},{\"name\":\"k1\",\"type\":\"INT64\"},"
                + "{\"name\":\"k2\",\"type\":\"INT64\"},{\"name\":\"cat\",\"type\":\"STRING\"},"
                + "{\"name\":\"label\",\"type\":\"STRING\"},{\"name\":\"amount\",\"type\":\"DECIMAL(12,2)\"},"
                + "{\"name\":\"fee\",\"type\":\"DECIMAL(10,2)\"},{\"name\":\"score\",\"type\":\"FLOAT64\"},"
                + "{\"name\":\"ts\",\"type\":\"TIMESTAMP\"},{\"name\":\"day\",\"type\":\"DATE\"},"
                + "{\"name\":\"flag\",\"type\":\"BOOLEAN\"},{\"name\":\"state\",\"type\":\"STRING\"},"
                + "{\"name\":\"opt\",\"type\":\"INT64\"},{\"name\":\"note\",\"type\":\"STRING\"},"
                + "{\"name\":\"bucket\",\"type\":\"INT64\"}]"));
        send(handler, load("dims", "dims.csv", null));
        send(handler, load("items", "items.csv", null));
        send(handler, load("small", "small.csv", null));
        send(handler, query("CREATE INDEX tr_k2 ON facts (k2) USING HASH", false, 0));
        send(handler, query("CREATE INDEX tr_ts ON facts (ts) USING BTREE", false, 0));
        List<String> queries = queries();
        for (int i = 0; i < iterations; i++) {
            for (String sql : queries) {
                send(handler, query(sql, false, 0));
                send(handler, query(sql, true, 0));
            }
        }
        for (String sql : queries) {
            send(handler, query(sql, false, 1));
        }
    }

    private static void send(RequestHandler handler, String line) {
        String response = handler.handleLine(line);
        if (!response.contains("\"ok\":true")) {
            throw new IllegalStateException("training request failed: " + line + " -> " + response);
        }
    }

    private static String load(String table, String file, String schema) {
        return "{\"op\":\"load\",\"table\":\"" + table + "\",\"path\":\"" + file + "\",\"format\":\"csv\""
                + (schema == null ? "" : ",\"schema\":" + schema) + "}";
    }

    /** A query request; {@code threads} 0 = the engine default. */
    private static String query(String sql, boolean countOnly, int threads) {
        List<String> options = new ArrayList<>();
        if (countOnly) {
            options.add("\"result\":\"count\"");
        }
        if (threads > 0) {
            options.add("\"threads\":" + threads);
        }
        return "{\"op\":\"query\",\"sql\":" + JsonWriter.write(sql) + ",\"options\":{"
                + String.join(",", options) + "}}";
    }

    /** The training queries: generic analytical shapes over the synthetic tables. */
    private static List<String> queries() {
        List<String> q = new ArrayList<>();
        // filters and reductions
        q.add("SELECT COUNT(*), SUM(amount), MAX(fee) FROM facts WHERE k2 = 42");
        q.add("SELECT COUNT(*), SUM(amount), MIN(score) FROM facts WHERE state <> 'failed' AND bucket < 600");
        q.add("SELECT COUNT(*), AVG(amount) FROM facts WHERE ts >= TIMESTAMP '2023-02-01 00:00:00' "
                + "AND ts < TIMESTAMP '2023-02-15 00:00:00'");
        q.add("SELECT SUM(amount * 3 - fee), MIN(amount), MAX(amount), AVG(bucket), SUM(score) FROM facts");
        q.add("SELECT COUNT(*), SUM(id) FROM facts WHERE id BETWEEN 1000 AND 200000 AND flag = false");
        q.add("SELECT COUNT(opt), SUM(opt), COUNT(note), COUNT(*) FROM facts WHERE note IS NOT NULL OR flag = true");
        q.add("SELECT COUNT(*) FROM facts WHERE cat IN ('alpha', 'gamma', 'mu') AND label LIKE '%a%'");
        q.add("SELECT COUNT(*), MAX(LENGTH(label)), SUM(CASE WHEN cat LIKE '%ta%' THEN 1 ELSE 0 END) FROM facts "
                + "WHERE UPPER(state) = 'OPEN'");
        q.add("SELECT COUNT(*) FROM facts WHERE day >= DATE '2023-03-01' AND score > 10.5 AND opt IS NULL");
        // aggregation
        q.add("SELECT cat, COUNT(*), SUM(amount), AVG(amount), MIN(ts), MAX(score) FROM facts GROUP BY cat ORDER BY cat");
        q.add("SELECT k1, COUNT(*) AS n, SUM(amount) AS s FROM facts GROUP BY k1 ORDER BY s DESC, k1 LIMIT 10");
        q.add("SELECT k2, COUNT(*) AS n FROM facts GROUP BY k2 ORDER BY n DESC, k2 LIMIT 20");
        q.add("SELECT bucket % 50 AS b, state, COUNT(*), SUM(fee) FROM facts GROUP BY bucket % 50, state "
                + "ORDER BY b, state LIMIT 40");
        q.add("SELECT k1 % 7, DATE_TRUNC('day', ts) AS d, AVG(score), MAX(amount) FROM facts WHERE k1 < 3000 "
                + "GROUP BY k1 % 7, DATE_TRUNC('day', ts) ORDER BY 1, d LIMIT 100");
        q.add("SELECT COUNT(DISTINCT k1), COUNT(DISTINCT k2), COUNT(DISTINCT cat) FROM facts");
        q.add("SELECT state, COUNT(DISTINCT k2), SUM(DISTINCT bucket) FROM facts GROUP BY state");
        q.add("SELECT DISTINCT cat, state FROM facts");
        q.add("SELECT flag, COUNT(*), SUM(opt), AVG(score) FROM facts GROUP BY flag HAVING COUNT(*) > 10");
        q.add("SELECT label, COUNT(*) FROM facts GROUP BY label ORDER BY 2 DESC, 1 LIMIT 5");
        // joins
        q.add("SELECT d.region, d.tier, COUNT(*), SUM(f.amount) FROM facts f JOIN dims d ON d.k1 = f.k1 "
                + "GROUP BY d.region, d.tier ORDER BY d.region, d.tier");
        q.add("SELECT s.name, COUNT(*), SUM(i.qty * i.price) FROM facts f JOIN items i ON i.fid = f.id "
                + "JOIN small s ON s.sid = i.sid WHERE f.state = 'closed' GROUP BY s.name ORDER BY s.name");
        q.add("SELECT COUNT(*) FROM dims d LEFT JOIN facts f ON f.k1 = d.k1 WHERE f.id IS NULL");
        q.add("SELECT d.tier, COUNT(i.fid), SUM(i.qty) FROM dims d LEFT JOIN items i ON i.fid = d.k1 GROUP BY d.tier");
        q.add("SELECT f.id, d.region FROM facts f JOIN dims d ON d.k1 = f.k1 WHERE f.k2 = 7 ORDER BY f.id");
        q.add("SELECT COUNT(*) FROM items i JOIN facts f ON f.id = i.fid JOIN dims d ON d.k1 = f.k1 "
                + "JOIN small s ON s.sid = i.sid WHERE d.region = 'north' AND s.name = 'n3'");
        // sorting
        q.add("SELECT id, k1 FROM facts ORDER BY k1 DESC, id LIMIT 100");
        q.add("SELECT id, label FROM facts ORDER BY label, id");
        q.add("SELECT k2, score, id FROM facts ORDER BY k2 DESC, score, id");
        q.add("SELECT id, ts FROM facts WHERE flag ORDER BY ts LIMIT 50");
        q.add("SELECT cat, amount FROM facts ORDER BY amount DESC, cat LIMIT 25 OFFSET 5");
        q.add("SELECT id, score FROM facts WHERE bucket < 300 ORDER BY score");
        // subqueries and CTEs
        q.add("WITH per AS (SELECT k1, SUM(amount) AS total FROM facts GROUP BY k1) "
                + "SELECT COUNT(*) FROM per WHERE total > (SELECT AVG(total) FROM per)");
        q.add("SELECT COUNT(*) FROM facts WHERE k1 IN (SELECT k1 FROM dims WHERE tier = 't2')");
        q.add("SELECT d.k1, (SELECT COUNT(*) FROM small s WHERE s.sid = d.k1 % 50) FROM dims d WHERE d.k1 < 200");
        q.add("SELECT x.cat, x.n FROM (SELECT cat, COUNT(*) AS n FROM facts GROUP BY cat) x WHERE x.n > 100 "
                + "ORDER BY x.n DESC");
        q.add("SELECT id, amount * 2 + fee, UPPER(cat), SUBSTR(label, 1, 3), COALESCE(opt, -1) FROM facts "
                + "WHERE bucket < 200");
        q.add("SELECT cat FROM facts WHERE k2 < 5 UNION ALL SELECT name FROM small");
        q.add("SELECT CAST(amount AS FLOAT64) / 3, CAST(k1 AS STRING) || '-' || state FROM facts WHERE id % 1000 = 0");
        q.add("EXPLAIN SELECT cat, COUNT(*) FROM facts WHERE k2 = 3 GROUP BY cat");
        return q;
    }

    /** Writes the CSV files of the synthetic tables (deterministic). */
    private static void writeTables(Path dir, int rows) throws IOException {
        SplittableRandom r = new SplittableRandom(20241011L);
        int keys = Math.max(10, rows / 12);
        try (Writer w = Files.newBufferedWriter(dir.resolve("facts.csv"), StandardCharsets.UTF_8)) {
            w.write("id,k1,k2,cat,label,amount,fee,score,ts,day,flag,state,opt,note,bucket\n");
            StringBuilder sb = new StringBuilder();
            for (int i = 1; i <= rows; i++) {
                sb.setLength(0);
                int skew = (int) Math.min(keys - 1, Math.abs((long) (r.nextGaussian() * keys / 6)));
                int month = 1 + r.nextInt(6);
                int dayOfMonth = 1 + r.nextInt(28);
                sb.append(i).append(',').append(1 + r.nextInt(keys)).append(',').append(skew).append(',')
                        .append(CATEGORIES[r.nextInt(CATEGORIES.length)]).append(',').append(word(r)).append(',')
                        .append(r.nextInt(100_000)).append('.').append(two(r.nextInt(100))).append(',')
                        .append(r.nextInt(20)).append('.').append(two(r.nextInt(100))).append(',')
                        .append(r.nextInt(-5000, 5000) / 7.0).append(',')
                        .append("2023-0").append(month).append('-').append(two(dayOfMonth)).append(' ')
                        .append(two(r.nextInt(24))).append(':').append(two(r.nextInt(60))).append(':')
                        .append(two(r.nextInt(60))).append('.').append(r.nextInt(1000)).append(',')
                        .append("2023-0").append(month).append('-').append(two(dayOfMonth)).append(',')
                        .append(r.nextInt(3) == 0).append(',').append(STATES[r.nextInt(STATES.length)]).append(',')
                        .append(r.nextBoolean() ? "" : String.valueOf(r.nextInt(1000))).append(',')
                        .append(r.nextInt(4) == 0 ? word(r) : "").append(',').append(r.nextInt(1000)).append('\n');
                w.write(sb.toString());
            }
        }
        try (Writer w = Files.newBufferedWriter(dir.resolve("dims.csv"), StandardCharsets.UTF_8)) {
            w.write("k1,region,tier,weight\n");
            for (int k = 1; k <= keys + keys / 10; k++) {
                w.write(k + "," + REGIONS[r.nextInt(REGIONS.length)] + ",t" + r.nextInt(6) + ","
                        + r.nextInt(100) + "." + two(r.nextInt(100)) + "\n");
            }
        }
        try (Writer w = Files.newBufferedWriter(dir.resolve("items.csv"), StandardCharsets.UTF_8)) {
            w.write("fid,sid,qty,price\n");
            for (int i = 0; i < rows; i++) {
                w.write((1 + r.nextInt(rows)) + "," + r.nextInt(50) + "," + (1 + r.nextInt(9)) + ","
                        + r.nextInt(500) + "." + two(r.nextInt(100)) + "\n");
            }
        }
        try (Writer w = Files.newBufferedWriter(dir.resolve("small.csv"), StandardCharsets.UTF_8)) {
            w.write("sid,name\n");
            for (int s = 0; s < 50; s++) {
                w.write(s + ",n" + (s % 10) + "\n");
            }
        }
    }

    private static String two(int v) {
        return v < 10 ? "0" + v : String.valueOf(v);
    }

    private static String word(SplittableRandom r) {
        int n = 1 + r.nextInt(10);
        char[] c = new char[n];
        for (int i = 0; i < n; i++) {
            c[i] = (char) ('a' + r.nextInt(26));
        }
        return new String(c);
    }
}
