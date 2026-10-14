package polyquery;

import static polyquery.Assert.check;
import static polyquery.Assert.eq;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.Arrays;
import java.util.List;
import polyquery.api.Column;
import polyquery.api.ColumnType;
import polyquery.api.Database;
import polyquery.api.DatabaseConfig;
import polyquery.api.DatabaseException;
import polyquery.api.ErrorCode;
import polyquery.api.LoadOptions;
import polyquery.api.QueryOptions;
import polyquery.api.Result;
import polyquery.api.TableInfo;
import polyquery.api.TableSchema;

/** The embedding API ({@code polyquery.api}, spec/apps/embedding.md §1). */
final class ApiTest {
    private ApiTest() {
    }

    private static void fails(ErrorCode code, Runnable r) {
        try {
            r.run();
        } catch (DatabaseException e) {
            if (e.code() != code) {
                throw new AssertionError("expected " + code + " but got " + e.code() + ": " + e.getMessage());
            }
            check(!e.getMessage().isEmpty(), "error message");
            return;
        }
        throw new AssertionError("expected " + code + " but succeeded");
    }

    private static Path tempDir() throws IOException {
        return Files.createTempDirectory("pq-api");
    }

    static void testTypedValues() throws Exception {
        try (Database db = Database.create(tempDir())) {
            Result r = db.query("SELECT 1 AS i, CAST('12.50' AS DECIMAL(10,2)) AS d, 0.5e0 AS f, 'x' AS s, "
                    + "TRUE AS b, DATE '2026-09-01' AS dt, TIMESTAMP '2026-09-01 10:00:00.5' AS ts, "
                    + "CAST(NULL AS INT64) AS n");
            eq(List.of("i", "d", "f", "s", "b", "dt", "ts", "n"), r.columnNames());
            eq(List.of("INT64", "DECIMAL(10,2)", "FLOAT64", "STRING", "BOOLEAN", "DATE", "TIMESTAMP", "INT64"),
                    r.columnTypes().stream().map(ColumnType::typeName).toList());
            eq(1, r.rowCount());
            eq(1L, r.getLong(0, 0));
            eq(new BigDecimal("12.50"), r.getDecimal(0, 1));
            eq(0.5, r.getDouble(0, 2));
            eq("x", r.getString(0, 3));
            eq(true, r.getBoolean(0, 4));
            eq(LocalDate.of(2026, 9, 1), r.getDate(0, 5));
            eq(LocalDateTime.of(2026, 9, 1, 10, 0, 0, 500_000_000), r.getTimestamp(0, 6));
            check(r.isNull(0, 7) && r.get(0, 7) == null, "NULL");
        }
    }

    static void testLoadSaveOpenDropAndErrors() throws Exception {
        Path dir = tempDir();
        Files.writeString(dir.resolve("t.csv"), "a;b\n1;x\n2;y\n");
        try (Database db = Database.create(DatabaseConfig.builder(dir).threads(2).build())) {
            TableSchema s = db.loadFile("t", "t.csv", LoadOptions.csv().withDelimiter(';'));
            eq(2L, s.rowCount());
            eq(new Column("a", ColumnType.INT64), s.columns().get(0));
            fails(ErrorCode.ALREADY_EXISTS, () -> db.loadText("t", "a\n1\n", LoadOptions.csv()));
            db.loadText("t", "a,b\n3,z\n", LoadOptions.csv().withReplace(true)
                    .withSchema(List.of(Column.of("a", "DECIMAL(5,1)"), Column.of("b", "STRING"))));
            eq(new BigDecimal("3.0"), db.query("SELECT a FROM t").getDecimal(0, 0));
            fails(ErrorCode.PARSE_ERROR, () -> db.query("SELEC 1"));
            fails(ErrorCode.SEMANTIC_ERROR, () -> db.query("SELECT * FROM missing"));
            fails(ErrorCode.ACCESS_DENIED, () -> db.loadFile("u", "../outside.csv", LoadOptions.csv()));
            eq(1, db.query("SELECT 1 AS x").rowCount()); // still usable after errors

            db.save("t", "t.pqcf");
            db.drop("t");
            fails(ErrorCode.NOT_FOUND, () -> db.schema("t"));
            db.open("t2", "t.pqcf");
            eq(List.of(new TableInfo("t2", 1)), db.tables());
            fails(ErrorCode.ALREADY_EXISTS, () -> db.open("t2", "t.pqcf"));
            db.open("t2", "t.pqcf", true);

            db.createTable("m", List.of(Column.of("k", "INT64"), Column.of("v", "STRING")),
                    List.of(Arrays.asList(1L, "a"), Arrays.asList(2L, null)), false);
            Result r = db.query("SELECT k, v FROM m ORDER BY k", QueryOptions.DEFAULT.withMaxRows(2));
            eq(2, r.rowCount());
            check(r.isNull(1, 1), "NULL from createTable");
            fails(ErrorCode.RESOURCE_LIMIT, () -> db.query("SELECT k FROM m", QueryOptions.DEFAULT.withMaxRows(1)));
        }
    }

    static void testCloseReleasesTheInstance() throws Exception {
        Database db = Database.create(tempDir());
        db.close();
        db.close(); // idempotent
        check(db.isClosed(), "closed");
        try {
            db.query("SELECT 1");
            throw new AssertionError("query on a closed instance");
        } catch (IllegalStateException expected) {
            // documented behaviour
        }
        fails(ErrorCode.NOT_FOUND, () -> Database.create(Path.of("/nonexistent-pq-api-dir")));
    }
}
