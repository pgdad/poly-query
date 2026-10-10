package polyquery;

import java.io.IOException;
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
import polyquery.engine.SaveRequest;
import polyquery.storage.ColumnVector;
import polyquery.storage.Layout;
import polyquery.storage.Layouts;
import polyquery.storage.Table;
import polyquery.storage.pqcf.SaveEncoding;

/** PQCF round trips and corruption detection, layouts, dictionary encoding, statistics. */
final class StorageTest {
    private static final String CSV = "id,name,price,day,at,ok,ratio\n"
            + "1,red,1.50,2024-01-01,2024-01-01 10:00:00,true,0.5\n"
            + "2,,2.25,,2024-01-02 11:30:00.123456,false,\n"
            + "3,red,,2024-01-03,,true,-1.25\n"
            + "4,Ünï,4.00,2024-01-04,2024-01-04 00:00:00,,2.0\n"
            + "5,red,5.75,0001-01-01,9999-12-31 23:59:59.999999,false,3.5\n";
    private static final String ALL = "SELECT * FROM %s ORDER BY id";

    private StorageTest() {
    }

    private static Path tempDir() {
        try {
            return Files.createTempDirectory("pqtest");
        } catch (IOException e) {
            throw new AssertionError(e);
        }
    }

    private static void delete(Path dir) {
        try (Stream<Path> files = Files.walk(dir)) {
            files.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
        } catch (IOException e) {
            throw new AssertionError(e);
        }
    }

    private static Engine engine(Path dir, Layout layout, Layouts.Dictionary dict) {
        Engine e = new Engine(new EngineConfig(dir, false, 1L << 30, 1L << 30, 1_000_000, 1_000_000, 1));
        e.load(new LoadRequest("t", "csv", null, CSV, null, true, ',', false, layout, dict));
        return e;
    }

    static void testRoundTripEveryEncodingAndGroupSize() throws IOException {
        Path dir = tempDir();
        try {
            Engine e = engine(dir, Layout.COLUMN, Layouts.Dictionary.AUTO);
            String expected = EngineTest.rows(e, ALL.formatted("t"));
            int n = 0;
            for (SaveEncoding enc : SaveEncoding.values()) {
                for (int groupSize : new int[] {1, 2, 5, 100}) {
                    String file = "t_" + enc + "_" + groupSize + ".pqcf";
                    long bytes = e.save(new SaveRequest("t", file, groupSize, enc));
                    Assert.eq(Files.size(dir.resolve(file)), bytes);
                    for (boolean mmap : new boolean[] {false, true}) {
                        String name = "r" + n++;
                        e.open(new OpenRequest(name, file, mmap, false, mmap ? Layout.COLUMN : Layout.ROW));
                        Assert.eq(expected, EngineTest.rows(e, ALL.formatted(name)));
                    }
                }
            }
        } finally {
            delete(dir);
        }
    }

    static void testCorruptFilesAreRejected() throws IOException {
        Path dir = tempDir();
        try {
            Engine e = engine(dir, Layout.COLUMN, Layouts.Dictionary.AUTO);
            e.save(new SaveRequest("t", "good.pqcf", 2, SaveEncoding.AUTO));
            byte[] good = Files.readAllBytes(dir.resolve("good.pqcf"));
            for (int pos = 0; pos < good.length; pos++) {
                byte[] bad = good.clone();
                bad[pos] ^= 0x10;
                Files.write(dir.resolve("bad.pqcf"), bad);
                ErrorCode expected = pos >= 4 && pos < 8 ? ErrorCode.STORAGE_VERSION_UNSUPPORTED : ErrorCode.STORAGE_CORRUPT;
                Assert.fails(expected, () -> e.open(new OpenRequest("bad", "bad.pqcf", false, false, Layout.COLUMN)));
            }
            Files.write(dir.resolve("short.pqcf"), java.util.Arrays.copyOf(good, good.length - 1));
            Assert.fails(ErrorCode.STORAGE_CORRUPT,
                    () -> e.open(new OpenRequest("bad", "short.pqcf", true, false, Layout.COLUMN)));
            Assert.check(e.catalog().find("bad") == null, "failed opens must not create tables");
            Assert.fails(ErrorCode.NOT_FOUND, () -> e.open(new OpenRequest("x", "missing.pqcf", false, false,
                    Layout.COLUMN)));
            Assert.fails(ErrorCode.IO_ERROR, () -> e.save(new SaveRequest("t", "nodir/x.pqcf", 10, SaveEncoding.AUTO)));
            Assert.fails(ErrorCode.ACCESS_DENIED, () -> e.save(new SaveRequest("t", "../x.pqcf", 10,
                    SaveEncoding.AUTO)));
        } finally {
            delete(dir);
        }
    }

    static void testLayoutsGiveIdenticalResults() {
        Path dir = tempDir();
        try {
            String sql = "SELECT name, COUNT(*), SUM(price), MIN(day), MAX(at) FROM t GROUP BY name ORDER BY name";
            String col = EngineTest.rows(engine(dir, Layout.COLUMN, Layouts.Dictionary.NEVER), sql);
            Assert.eq(col, EngineTest.rows(engine(dir, Layout.ROW, Layouts.Dictionary.AUTO), sql));
            Assert.eq(col, EngineTest.rows(engine(dir, Layout.COLUMN, Layouts.Dictionary.ALWAYS), sql));
            Table t = engine(dir, Layout.COLUMN, Layouts.Dictionary.ALWAYS).catalog().require("t");
            Assert.check(t.data().chunk(0, 1) instanceof ColumnVector.DictStringVector, "dictionary expected");
            Assert.eq(Layout.ROW, engine(dir, Layout.ROW, Layouts.Dictionary.AUTO).catalog().require("t").layout());
        } finally {
            delete(dir);
        }
    }

    static void testStatistics() {
        Path dir = tempDir();
        try {
            Table t = engine(dir, Layout.COLUMN, Layouts.Dictionary.AUTO).catalog().require("t");
            var name = t.stats().column(1);
            Assert.eq(1L, name.nullCount());
            Assert.eq(2L, name.distinctCount());
            Assert.eq("red", name.min());
            Assert.eq("Ünï", name.max());
            var price = t.stats().column(2);
            Assert.eq(1.5, price.min());
            Assert.eq(5.75, price.max());
            Assert.eq(4L, price.distinctCount());
        } finally {
            delete(dir);
        }
    }

    static void testIndexesSurviveSaveAndOpen() {
        Path dir = tempDir();
        try {
            Engine e = engine(dir, Layout.COLUMN, Layouts.Dictionary.AUTO);
            EngineTest.rows(e, "CREATE INDEX t_id ON t (id) USING HASH");
            e.save(new SaveRequest("t", "t.pqcf", 2, SaveEncoding.AUTO));
            Assert.fails(ErrorCode.ALREADY_EXISTS, () -> e.open(new OpenRequest("u", "t.pqcf", false, false,
                    Layout.COLUMN)));
            e.open(new OpenRequest("t", "t.pqcf", true, true, Layout.COLUMN));
            Assert.eq(List.of("t_id"), e.catalog().require("t").indexes().stream().map(i -> i.name()).toList());
            Assert.eq("[[3]]", EngineTest.rows(e, "SELECT id FROM t WHERE id = 3"));
        } finally {
            delete(dir);
        }
    }
}
