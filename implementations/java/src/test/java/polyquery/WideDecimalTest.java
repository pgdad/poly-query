package polyquery;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Stream;
import polyquery.common.ErrorCode;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.engine.LoadRequest;
import polyquery.engine.OpenRequest;
import polyquery.engine.QueryOptions;
import polyquery.engine.SaveRequest;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Layout;
import polyquery.storage.pqcf.SaveEncoding;
import polyquery.types.Casts;
import polyquery.types.DataType;
import polyquery.types.Decimals;
import polyquery.types.TextParsers;

/** CR-2: DECIMAL precision 38 — wide values, W = 18/38 typing, exact comparisons, PQCF v2, option matrix. */
final class WideDecimalTest {
    private static final DataType D38_0 = DataType.decimal(38, 0);
    private static final DataType D38_10 = DataType.decimal(38, 10);

    private WideDecimalTest() {
    }

    private static BigInteger big(String s) {
        return new BigInteger(s);
    }

    static void testTypeDomain() {
        Assert.check(DataType.decimal(19, 0).isWideDecimal(), "precision 19 is wide");
        Assert.check(!DataType.decimal(18, 2).isWideDecimal(), "precision 18 is narrow");
        Assert.eq("DECIMAL(38,38)", DataType.parse("numeric(38, 38)").toString());
        Assert.eq("DECIMAL(18,0)", DataType.parse("DECIMAL").toString());
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> DataType.parse("DECIMAL(39,0)"));
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> DataType.parse("DECIMAL(30,31)"));
    }

    static void testWideArithmetic() {
        BigInteger max = big("99999999999999999999999999999999999999");
        Assert.eq(max, Decimals.value(Decimals.addExact(max.subtract(BigInteger.ONE), 0, 1L, 0, 0), D38_0));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> Decimals.value(Decimals.addExact(max, 0, 1L, 0, 0), D38_0));
        // mixed representations and scales: 1.5 (narrow, scale 1) + 2.25 (wide, scale 2)
        Assert.eq(big("375"), Decimals.addExact(15L, 1, big("225"), 2, 2));
        Assert.eq(big("-75"), Decimals.subtractExact(15L, 1, big("225"), 2, 2));
        // a product needs more than 38 digits before the check
        BigInteger p = Decimals.multiplyExact(big("100000000000000000000"), big("10000000000000000000"));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> Decimals.value(p, D38_0));
        Assert.eq(Long.class, Decimals.value(big("123"), DataType.decimal(18, 2)).getClass());
        Assert.eq(BigInteger.class, Decimals.value(big("123"), DataType.decimal(19, 2)).getClass());
        Assert.eq(big("13"), Decimals.rescale(big("125"), 2, 1));
        Assert.eq(big("-13"), Decimals.rescale(big("-125"), 2, 1));
        Assert.eq(big("-12345"), Decimals.truncateToInteger(big("-1234599"), 2));
    }

    static void testExactComparison() {
        Assert.check(Decimals.compare(Long.MAX_VALUE, 0, 15L, 1) > 0, "9223372036854775807 > 1.5");
        Assert.eq(0, Decimals.compare(big("1234567890123456789000"), 2, big("12345678901234567890"), 0));
        Assert.eq(0, Decimals.compare(big("1000000000000000000000000000000000000"), 37, 1L, 1));
        Assert.check(Decimals.compare(-1L, 0, big("-99999999999999999999"), 0) > 0, "-1 > -10^20+1");
    }

    static void testTextAndConversions() {
        Assert.eq("-0.0000000001", Decimals.toString(big("-1"), 10));
        Assert.eq("12345678901234567890.1234567890", Decimals.toString(big("123456789012345678901234567890"), 10));
        Assert.eq("-99999999999999999999.99", Decimals.toString((Object) big("-9999999999999999999999"), 2));
        Assert.eq(1.2345678901234568e28, Decimals.toDouble(big("12345678901234567890123456789"), 0));
        Assert.eq(big("100000000000000005551115123126"), Decimals.fromDouble(0.1, 30));
        Assert.eq(big("12345678901234567890123456789123456789"),
                TextParsers.parseDecimal("12345678901234567890123456789.123456789", 38, 9, false));
        Assert.eq(12500L, TextParsers.parseDecimal("12.5", 10, 3, false));
        Assert.eq(big("-12500"), TextParsers.parseDecimal("-12.5", 25, 3, false));
        Assert.eq(big("3"), TextParsers.parseDecimal("0.25", 20, 1, true));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW,
                () -> Casts.cast("1234567890123456789012345678901234567890", DataType.STRING, D38_0));
    }

    static void testCasts() {
        Assert.eq(big("92233720368547758070000000000"), Casts.cast(Long.MAX_VALUE, DataType.INT64, D38_10));
        Assert.eq(-12345L, Casts.cast(big("-1234599"), DataType.decimal(30, 2), DataType.INT64));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW,
                () -> Casts.cast(big("9223372036854775808"), DataType.decimal(20, 0), DataType.INT64));
        // narrow ↔ wide in both directions, rounding half away from zero
        Assert.eq(big("13"), Casts.cast(125L, DataType.decimal(5, 2), DataType.decimal(30, 1)));
        Assert.eq(-13L, Casts.cast(big("-125"), DataType.decimal(30, 2), DataType.decimal(10, 1)));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW,
                () -> Casts.cast(big("10000000000"), DataType.decimal(20, 0), DataType.decimal(10, 0)));
        Assert.eq("-1.50", Casts.cast(big("-150"), DataType.decimal(20, 2), DataType.STRING));
        Assert.eq(-1.5, Casts.cast(big("-150"), DataType.decimal(20, 2), DataType.FLOAT64));
        Assert.eq(big("100000000000000005551115123126"), Casts.cast(0.1, DataType.FLOAT64, DataType.decimal(38, 30)));
    }

    static void testResultTypes() {
        Engine e = EngineTest.engine();
        Assert.eq("[n:DECIMAL(18,2), w:DECIMAL(38,2)]",
                EngineTest.types(e, "SELECT 1.5 + 2.25 AS n, CAST(1.5 AS DECIMAL(19,1)) + 2.25 AS w"));
        Assert.eq("[v:DECIMAL(21,1), f:FLOAT64]",
                EngineTest.types(e, "SELECT 12345678901234567890.5 AS v, 123456789012345678901234567890123456789.0 AS f"));
        Assert.eq("[m:DECIMAL(38,3), i:DECIMAL(38,0)]",
                EngineTest.types(e, "SELECT CAST(2.5 AS DECIMAL(20,1)) * 1.25 AS m, 1 + CAST(1 AS DECIMAL(20,0)) AS i"));
        Assert.eq("[s:DECIMAL(38,2), r:DECIMAL(38,1), f:DECIMAL(38,0), a:DECIMAL(25,2), mx:DECIMAL(25,2)]",
                EngineTest.types(e, "SELECT SUM(x) AS s, ROUND(x, 1) AS r, FLOOR(x) AS f, ABS(x) AS a, MAX(x) AS mx "
                        + "FROM (SELECT CAST(age AS DECIMAL(25,2)) AS x FROM people) d GROUP BY x"));
        Assert.eq("[c:DECIMAL(38,2), u:DECIMAL(38,1)]",
                EngineTest.types(e, "SELECT COALESCE(NULL, CAST(1 AS DECIMAL(20,2)), 1.5) AS c, "
                        + "CASE WHEN id > 1 THEN 1.5 ELSE CAST(2 AS DECIMAL(30,0)) END AS u FROM people"));
        Assert.eq("[v:DECIMAL(38,1)]",
                EngineTest.types(e, "SELECT 1.5 AS v UNION ALL SELECT CAST(7 AS DECIMAL(20,0))"));
        Assert.fails(ErrorCode.TYPE_ERROR, () -> e.query(
                "SELECT CAST(1 AS DECIMAL(38,20)) * CAST(1 AS DECIMAL(38,19))", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.TYPE_ERROR, () -> e.query("SELECT CAST(7 AS DECIMAL(30,0)) % 2", QueryOptions.DEFAULT));
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> e.query("SELECT CAST(1 AS DECIMAL(39,0))", QueryOptions.DEFAULT));
        Assert.eq("[[\"152415787532388356514250977776253630\"]]", EngineTest.rows(e,
                "SELECT CAST('12345678901234567890' AS DECIMAL(20,0)) * CAST('12345678901234567' AS DECIMAL(20,0))"));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> e.query(
                "SELECT SUM(x) FROM (SELECT CAST('99999999999999999999999999999999999999' AS DECIMAL(38,0)) AS x "
                        + "FROM people) d", QueryOptions.DEFAULT));
    }

    static void testComparisonsAreExact() {
        Engine e = EngineTest.engine();
        Assert.eq("[[true,true,true,true,false]]", EngineTest.rows(e,
                "SELECT 9223372036854775807 > 1.5, CAST('12345678901234567890.00' AS DECIMAL(22,2)) = "
                        + "12345678901234567890.0, CAST('0.1' AS DECIMAL(38,37)) = 0.1, "
                        + "-9223372036854775807 < 0.000000000000000001, 9223372036854775807 = 9223372036854775806.5"));
        // INT64 column against a narrow DECIMAL scale that cannot hold it (no overflow), and IN / BETWEEN
        e.load(new LoadRequest("big", "csv", null, "k,d\n9223372036854775807,1.50\n-5,-5.00\n3,2.99\n", null, true,
                ',', false));
        Assert.eq("[[-5],[3]]", EngineTest.rows(e, "SELECT k FROM big WHERE k < 99999999999.99 ORDER BY k"));
        Assert.eq("[[-5]]", EngineTest.rows(e, "SELECT k FROM big WHERE k = CAST(d AS DECIMAL(10,2))"));
        Assert.eq("[[-5],[3]]", EngineTest.rows(e, "SELECT k FROM big WHERE k IN (3.0, -5, 7.5) ORDER BY k"));
        Assert.eq("[[9223372036854775807]]", EngineTest.rows(e,
                "SELECT k FROM big WHERE k BETWEEN 4.5 AND 100000000000000000000000000000.00"));
    }

    private static Path tempDir() {
        try {
            return Files.createTempDirectory("pqwide");
        } catch (IOException ex) {
            throw new AssertionError(ex);
        }
    }

    private static void delete(Path dir) {
        try (Stream<Path> files = Files.walk(dir)) {
            files.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
        } catch (IOException ex) {
            throw new AssertionError(ex);
        }
    }

    private static final String WIDE_CSV = "id,amt,big,small\n"
            + "1,12345678901234567890.1234567890,999999999999999999999999999999,1.25\n"
            + "2,-0.0000000001,123456789012345678901234567890,2.50\n"
            + "3,9999999999999999999999999999.9999999999,1,-3.75\n"
            + "4,,,\n"
            + "5,12345678901234567890.1234567890,-500000000000000000000000000000,99999999.99\n"
            + "6,-9999999999999999999999999999.9999999999,7,0.01\n";

    private static final List<ColumnSchema> WIDE_SCHEMA = List.of(new ColumnSchema("id", DataType.INT64),
            new ColumnSchema("amt", D38_10), new ColumnSchema("big", DataType.decimal(30, 0)),
            new ColumnSchema("small", DataType.decimal(10, 2)));

    static void testPqcfVersionFollowsWriterRule() throws IOException {
        Path dir = tempDir();
        try {
            Engine e = new Engine(new EngineConfig(dir, false, 1L << 30, 1L << 30, 1_000_000, 1_000_000, 1));
            e.load(new LoadRequest("w", "csv", null, WIDE_CSV, WIDE_SCHEMA, true, ',', false));
            e.load(new LoadRequest("n", "csv", null, "id,small\n1,1.25\n", List.of(WIDE_SCHEMA.get(0),
                    WIDE_SCHEMA.get(3)), true, ',', false));
            String all = "SELECT * FROM %s ORDER BY id";
            String expected = EngineTest.rows(e, all.formatted("w"));
            int n = 0;
            for (SaveEncoding enc : SaveEncoding.values()) {
                for (int groupSize : new int[] {1, 4, 100}) {
                    String file = "w_" + enc + groupSize + ".pqcf";
                    e.save(new SaveRequest("w", file, groupSize, enc));
                    byte[] bytes = Files.readAllBytes(dir.resolve(file));
                    Assert.eq(2, (int) bytes[4]);
                    for (boolean mmap : new boolean[] {false, true}) {
                        String name = "r" + n++;
                        e.open(new OpenRequest(name, file, mmap, false, mmap ? Layout.COLUMN : Layout.ROW));
                        Assert.eq(expected, EngineTest.rows(e, all.formatted(name)));
                    }
                }
            }
            e.save(new SaveRequest("n", "n.pqcf", 10, SaveEncoding.AUTO));
            Assert.eq(1, (int) Files.readAllBytes(dir.resolve("n.pqcf"))[4]);
            // header says v1 while the metadata says v2 (and declares wide columns)
            byte[] v2 = Files.readAllBytes(dir.resolve("w_PLAIN100.pqcf"));
            v2[4] = 1;
            Files.write(dir.resolve("bad.pqcf"), v2);
            Assert.fails(ErrorCode.STORAGE_CORRUPT, () -> e.open(new OpenRequest("bad", "bad.pqcf", false, false,
                    Layout.COLUMN)));
            v2[4] = 3;
            Files.write(dir.resolve("bad.pqcf"), v2);
            Assert.fails(ErrorCode.STORAGE_VERSION_UNSUPPORTED, () -> e.open(new OpenRequest("bad", "bad.pqcf", false,
                    false, Layout.COLUMN)));
        } finally {
            delete(dir);
        }
    }

    static void testIndexesOnWideColumns() {
        Engine e = EngineTest.engine();
        e.load(new LoadRequest("w", "csv", null, WIDE_CSV, WIDE_SCHEMA, true, ',', false));
        String[] queries = {
            "SELECT id FROM w WHERE amt = 12345678901234567890.123456789 ORDER BY id",
            "SELECT id FROM w WHERE amt BETWEEN -1 AND 0.5 ORDER BY id",
            "SELECT id FROM w WHERE big IN (1, 7, 123456789012345678901234567890.) ORDER BY id",
            "SELECT id FROM w WHERE big > 9223372036854775807 ORDER BY id",
            "SELECT id FROM w WHERE small = 1.250 OR small < -3 ORDER BY id",
        };
        String[] before = new String[queries.length];
        for (int i = 0; i < queries.length; i++) {
            before[i] = EngineTest.rows(e, queries[i]);
        }
        Assert.eq("[[1],[5]]", before[0]);
        Assert.eq("[[2]]", before[1]);
        Assert.eq("[[2],[3],[6]]", before[2]);
        Assert.eq("[[1],[2]]", before[3]);
        Assert.eq("[[1],[3]]", before[4]);
        EngineTest.rows(e, "CREATE INDEX w_amt ON w (amt)");
        EngineTest.rows(e, "CREATE INDEX w_big ON w (big) USING HASH");
        EngineTest.rows(e, "CREATE INDEX w_small ON w (small)");
        for (int i = 0; i < queries.length; i++) {
            Assert.eq(before[i], EngineTest.rows(e, queries[i]));
        }
    }

    /** A 600-row table of wide values for the option matrix (NULLs, duplicates, extreme values). */
    static Engine matrixEngine(polyquery.ffi.NativeKernels kernels) {
        Engine e = Phase5Test.engine(kernels);
        StringBuilder csv = new StringBuilder("id,g,i,n,w,v\n");
        for (int k = 1; k <= 600; k++) {
            String w = k % 10 == 0 ? "" : (k % 3 == 0 ? "-" : "") + (k % 29) + "234567890123456789" + "." + (k % 7)
                    + "000000001";
            String v = k % 13 == 0 ? "" : k % 17 == 0 ? "99999999999999999999999.99" : (k % 41) + ".5";
            csv.append(k).append(',').append(k % 6).append(',').append(k % 11 == 0 ? "" : String.valueOf(k % 50 - 9))
                    .append(',').append(k % 9 == 0 ? "" : (k % 23) + ".50").append(',').append(w).append(',')
                    .append(v).append('\n');
        }
        e.load(new LoadRequest("wt", "csv", null, csv.toString(), List.of(new ColumnSchema("id", DataType.INT64),
                new ColumnSchema("g", DataType.INT64), new ColumnSchema("i", DataType.INT64),
                new ColumnSchema("n", DataType.decimal(8, 2)), new ColumnSchema("w", D38_10),
                new ColumnSchema("v", DataType.decimal(25, 2))), true, ',', false));
        return e;
    }

    static final String[] MATRIX_QUERIES = {
        "SELECT id, w + n, w * 2, v - i, -w, ABS(v), ROUND(w, 2), FLOOR(v), CEIL(w) FROM wt WHERE id % 7 = 0",
        "SELECT g, COUNT(w), SUM(w), MIN(w), MAX(v), AVG(w), COUNT(DISTINCT v), SUM(DISTINCT v) FROM wt GROUP BY g",
        "SELECT SUM(w), SUM(v), MIN(v), MAX(w), AVG(v), SUM(CAST(n AS DECIMAL(38,2))) FROM wt",
        "SELECT v, COUNT(*) FROM wt GROUP BY v",
        "SELECT DISTINCT v, g FROM wt",
        "SELECT id, w FROM wt ORDER BY w DESC NULLS FIRST, id LIMIT 25 OFFSET 3",
        "SELECT id, v FROM wt ORDER BY v, id",
        "SELECT id FROM wt WHERE w > 1000 AND v < 30 OR n = v OR i = v",
        "SELECT id FROM wt WHERE v IN (1.5, 2.5, 99999999999999999999999.99, NULL) AND w BETWEEN -1e3 AND 1e30",
        "SELECT a.id, b.id FROM wt a JOIN wt b ON a.v = b.n AND a.id < b.id WHERE a.id < 200",
        "SELECT a.id, b.id FROM wt a JOIN wt b ON a.w = b.w AND a.id <> b.id WHERE a.g = 1",
        "SELECT a.id, COUNT(b.id) FROM wt a LEFT JOIN wt b ON a.i = b.v GROUP BY a.id",
        "SELECT a.id, b.id FROM wt a JOIN wt b ON a.i = b.n WHERE a.id < 60 AND b.id < 60",
        "SELECT id, CASE WHEN g = 1 THEN w WHEN g = 2 THEN n ELSE v END, COALESCE(v, n, i), NULLIF(v, 1.5) FROM wt",
        "SELECT id FROM wt WHERE v IN (SELECT n FROM wt WHERE g = 2) AND id < 300",
        "SELECT id, (SELECT MAX(b.w) FROM wt b WHERE b.v = a.v) FROM wt a WHERE id < 50",
        "SELECT v FROM wt WHERE id < 20 UNION ALL SELECT i FROM wt WHERE id < 20 UNION ALL SELECT n FROM wt",
        "SELECT id, w * v FROM wt WHERE id < 40",
        "SELECT id, CAST(v AS INT64), CAST(w AS FLOAT64), CAST(w AS STRING), CAST(v AS DECIMAL(10,1)) FROM wt "
                + "WHERE v < 1000",
        "SELECT id, CAST(w AS INT64) FROM wt",
        "SELECT g, SUM(w * 100000000) FROM wt GROUP BY g",
        "SELECT x, COUNT(*) FROM (SELECT CAST(i AS DECIMAL(20,0)) + n AS x FROM wt) d GROUP BY x",
    };

    static void testOptionMatrixAgrees() {
        Phase5Test.checkAllCombinations(matrixEngine(null), MATRIX_QUERIES, false);
        System.setProperty("polyquery.batchSize", "5");
        System.setProperty("polyquery.morselRows", "37");
        System.setProperty("polyquery.parallelBuildRows", "8");
        try {
            Phase5Test.checkAllCombinations(matrixEngine(null), MATRIX_QUERIES, false);
        } finally {
            System.clearProperty("polyquery.batchSize");
            System.clearProperty("polyquery.morselRows");
            System.clearProperty("polyquery.parallelBuildRows");
        }
    }

    /** Native kernels never see wide columns; results agree with and without {@code native}. */
    static void testNativeAgrees() {
        polyquery.ffi.NativeKernels k = NativeKernelsTest.kernels();
        if (k != null) {
            Phase5Test.checkAllCombinations(matrixEngine(k), MATRIX_QUERIES, true);
        }
    }
}
