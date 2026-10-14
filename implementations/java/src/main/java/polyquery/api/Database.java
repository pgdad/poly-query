package polyquery.api;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.function.Supplier;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.engine.LoadRequest;
import polyquery.engine.OpenRequest;
import polyquery.engine.SaveRequest;
import polyquery.exec.ExecMode;
import polyquery.exec.QueryResult;
import polyquery.index.Index;
import polyquery.physical.PhysicalPlanner.JoinStrategy;
import polyquery.storage.ColumnSchema;
import polyquery.storage.ColumnVector;
import polyquery.storage.Layout;
import polyquery.storage.Layouts;
import polyquery.storage.Table;
import polyquery.storage.pqcf.PqcfWriter;
import polyquery.storage.pqcf.SaveEncoding;
import polyquery.types.DataType;

/**
 * An in-process PolyQuery engine instance: an in-memory catalog of tables, a data directory for
 * files, and the SQL engine. It offers the protocol's operations ({@code spec/protocol/protocol.md}
 * §5) as methods; nothing starts a process or opens a network connection.
 *
 * <pre>{@code
 * try (Database db = Database.create(DatabaseConfig.of(Path.of("data")))) {
 *     db.loadFile("t", "t.csv", LoadOptions.csv());
 *     Result r = db.query("SELECT COUNT(*) AS n FROM t");
 *     long n = r.getLong(0, 0);
 * }
 * }</pre>
 *
 * <p><b>Errors.</b> Engine errors are thrown as {@link DatabaseException} carrying the
 * specification's {@link ErrorCode}; the instance stays usable after any error. Invalid Java
 * arguments (e.g. {@code null}) throw {@link NullPointerException} or
 * {@link IllegalArgumentException}; using a closed instance throws {@link IllegalStateException}.
 *
 * <p><b>Thread safety.</b> An instance is thread-safe: any number of threads may call any
 * methods concurrently. Each query reads one consistent snapshot of the catalog (tables are
 * immutable; loading, opening, replacing or dropping a table publishes a new catalog version
 * atomically), exactly as concurrent requests of the {@code serve} mode.
 *
 * <p><b>Stack depth.</b> Statements are parsed and planned on the calling thread; a statement
 * nested too deeply for that thread's stack fails with {@code RESOURCE_LIMIT}. Threads with
 * large stacks (e.g. {@code new Thread(null, task, "db", 512L << 20)}) accept deeper nesting.
 */
public final class Database implements AutoCloseable {
    private final DatabaseConfig config;
    private final Engine engine;
    private volatile boolean closed;

    private Database(DatabaseConfig config, Engine engine) {
        this.config = config;
        this.engine = engine;
    }

    /**
     * Creates an instance with an empty catalog.
     *
     * @throws DatabaseException NOT_FOUND if the data directory does not exist
     */
    public static Database create(DatabaseConfig config) {
        Path dataDir = config.dataDir().toAbsolutePath().normalize();
        if (!Files.isDirectory(dataDir)) {
            throw new DatabaseException(ErrorCode.NOT_FOUND, "data directory does not exist: " + dataDir);
        }
        long requested = config.maxQueryMemoryMb() > (Long.MAX_VALUE >> 20) ? Long.MAX_VALUE
                : config.maxQueryMemoryMb() << 20;
        long memoryBytes = Math.min(requested, (long) (Runtime.getRuntime().maxMemory() * 0.7));
        EngineConfig engineConfig = new EngineConfig(dataDir, config.testFunctions(), memoryBytes,
                config.maxIngestBytes(), config.maxTableRows(), config.maxJoinRows(), config.threads());
        return new Database(config, new Engine(engineConfig));
    }

    /** Creates an instance with the default configuration for {@code dataDir}. */
    public static Database create(Path dataDir) {
        return create(DatabaseConfig.of(dataDir));
    }

    public DatabaseConfig config() {
        return config;
    }

    // ---------------------------------------------------------------- load

    /**
     * Loads a file of the data directory into table {@code table} (the protocol's {@code load}
     * with {@code path}).
     *
     * @param path a path relative to the data directory
     * @return the new table's schema
     * @throws DatabaseException e.g. NOT_FOUND (no such file), ACCESS_DENIED (path outside the
     *                           data directory), INGEST_ERROR, ALREADY_EXISTS (without replace)
     */
    public TableSchema loadFile(String table, String path, LoadOptions options) {
        return load(table, path, null, options);
    }

    /**
     * Loads in-memory text into table {@code table} (the protocol's {@code load} with
     * {@code data}).
     */
    public TableSchema loadText(String table, String text, LoadOptions options) {
        return load(table, null, text, options);
    }

    private TableSchema load(String table, String path, String data, LoadOptions options) {
        requireTableName(table);
        if (path == null && data == null) {
            throw new NullPointerException("path/text");
        }
        char delimiter = options.delimiter();
        if (delimiter > 127 || delimiter == '"' || delimiter == '\n' || delimiter == '\r') {
            throw new IllegalArgumentException("delimiter must be one ASCII character other than '\"', CR and LF");
        }
        if (options.format() == LoadOptions.Format.CSV && !options.header() && options.schema() == null) {
            throw new IllegalArgumentException("a CSV load without header requires an explicit schema");
        }
        List<ColumnSchema> schema = options.schema() == null ? null : engineSchema(options.schema());
        return call(() -> describe(engine.load(new LoadRequest(table, options.format().name().toLowerCase(Locale.ROOT),
                path, data, schema, options.header(), delimiter, options.replace()))));
    }

    // ---------------------------------------------------------------- query

    /** Executes one SQL statement with {@link QueryOptions#DEFAULT}. */
    public Result query(String sql) {
        return query(sql, QueryOptions.DEFAULT);
    }

    /**
     * Executes one SQL statement (a query, {@code EXPLAIN}, {@code CREATE INDEX} or
     * {@code DROP INDEX}) and returns its complete result.
     *
     * @throws DatabaseException PARSE_ERROR, SEMANTIC_ERROR, TYPE_ERROR, a runtime error
     *                           (NUMERIC_OVERFLOW, DIVISION_BY_ZERO, …), TIMEOUT or RESOURCE_LIMIT
     */
    public Result query(String sql, QueryOptions options) {
        requireNonNull(sql, "sql");
        return call(() -> {
            QueryResult r = engine.query(sql, engineOptions(options));
            List<Column> columns = new ArrayList<>(r.columns().size());
            DataType[] types = new DataType[r.columns().size()];
            for (int i = 0; i < types.length; i++) {
                ColumnSchema c = r.columns().get(i);
                columns.add(new Column(c.name(), ValueMapping.toApi(c.type())));
                types[i] = c.type();
            }
            return new Result(columns, types, r.rows());
        });
    }

    private static polyquery.engine.QueryOptions engineOptions(QueryOptions o) {
        return new polyquery.engine.QueryOptions(o.maxRows(), o.timeoutMs(), false, true, JoinStrategy.AUTO, true,
                ExecMode.VECTORIZED, o.threads());
    }

    // ---------------------------------------------------------------- creating tables from Java

    /**
     * Creates table {@code table} from rows of Java values (an extension beyond the protocol).
     * Each row has one value per column, of the class listed on {@link ColumnType.Kind} for the
     * column's type ({@code Integer}, {@code Short} and {@code Byte} are also accepted for
     * INT64; {@code Float} for FLOAT64; {@code Long}, {@code Integer} and {@code BigInteger}
     * for DECIMAL, where values are rounded half away from zero to the column's scale), or
     * {@code null}.
     *
     * @throws IllegalArgumentException for an empty or duplicate column name or a row of the
     *                                  wrong length
     * @throws DatabaseException        TYPE_ERROR (value of the wrong class), NUMERIC_OVERFLOW,
     *                                  INVALID_ARGUMENT (value out of range), RESOURCE_LIMIT,
     *                                  ALREADY_EXISTS (without replace)
     */
    public TableSchema createTable(String table, List<Column> columns, List<? extends List<?>> rows,
                                   boolean replace) {
        requireTableName(table);
        List<ColumnSchema> schema = engineSchema(columns);
        checkColumnNames(schema);
        for (List<?> row : rows) {
            if (row.size() != schema.size()) {
                throw new IllegalArgumentException("row has " + row.size() + " values, expected " + schema.size());
            }
        }
        return call(() -> {
            checkTableRows(rows.size());
            ColumnVector[] vectors = new ColumnVector[schema.size()];
            for (int c = 0; c < vectors.length; c++) {
                ColumnSchema col = schema.get(c);
                ColumnVector.Builder b = ColumnVector.builder(col.type(), rows.size());
                for (List<?> row : rows) {
                    b.append(ValueMapping.toEngine(row.get(c), col.type(), col.name()));
                }
                vectors[c] = b.build();
            }
            return publish(new Table(table, schema, vectors, rows.size()), replace);
        });
    }

    /**
     * Creates table {@code table} holding the result of the query {@code sql} (an extension
     * beyond the protocol, like {@code CREATE TABLE … AS SELECT}). Columns of the NULL type
     * become STRING columns.
     *
     * @throws DatabaseException any error of {@link #query(String, QueryOptions)}, INVALID_REQUEST
     *                           if the result has duplicate or empty column names,
     *                           ALREADY_EXISTS (without replace)
     */
    public TableSchema createTableAs(String table, String sql, QueryOptions options, boolean replace) {
        requireTableName(table);
        requireNonNull(sql, "sql");
        return call(() -> {
            QueryResult r = engine.query(sql, engineOptions(options));
            List<ColumnSchema> schema = new ArrayList<>(r.columns().size());
            for (ColumnSchema c : r.columns()) {
                schema.add(c.type().isNull() ? new ColumnSchema(c.name(), DataType.STRING) : c);
            }
            try {
                checkColumnNames(schema);
            } catch (IllegalArgumentException e) {
                throw new DatabaseException(ErrorCode.INVALID_REQUEST, "query result: " + e.getMessage());
            }
            int n = r.rows().size();
            checkTableRows(n);
            ColumnVector[] vectors = new ColumnVector[schema.size()];
            for (int c = 0; c < vectors.length; c++) {
                ColumnVector.Builder b = ColumnVector.builder(schema.get(c).type(), n);
                for (Object[] row : r.rows()) {
                    b.append(row[c]);
                }
                vectors[c] = b.build();
            }
            return publish(new Table(table, schema, vectors, n), replace);
        });
    }

    private TableSchema publish(Table table, boolean replace) {
        Table encoded = new Table(table.name(), table.columns(),
                Layouts.convert(table.data(), table.columns(), Layout.COLUMN, Layouts.Dictionary.AUTO));
        engine.catalog().put(encoded, replace);
        return describe(encoded);
    }

    private void checkTableRows(long rows) {
        if (rows > engine.config().maxTableRows()) {
            throw new DatabaseException(ErrorCode.RESOURCE_LIMIT,
                    "table exceeds the row limit (" + engine.config().maxTableRows() + ")");
        }
    }

    private static void checkColumnNames(List<ColumnSchema> schema) {
        Set<String> seen = new HashSet<>();
        for (ColumnSchema c : schema) {
            if (c.name().isEmpty()) {
                throw new IllegalArgumentException("empty column name");
            }
            if (!seen.add(Table.key(c.name()))) {
                throw new IllegalArgumentException("duplicate column name '" + c.name() + "'");
            }
        }
    }

    // ---------------------------------------------------------------- PQCF files

    /**
     * Writes table {@code table} to the PQCF file {@code path} (relative to the data directory),
     * atomically replacing an existing file.
     *
     * @return the file size in bytes
     * @throws DatabaseException NOT_FOUND (no such table), ACCESS_DENIED, IO_ERROR
     */
    public long save(String table, String path) {
        requireNonNull(table, "table");
        requireNonNull(path, "path");
        return call(() -> engine.save(new SaveRequest(table, path, PqcfWriter.DEFAULT_ROW_GROUP_SIZE,
                SaveEncoding.AUTO)));
    }

    /** Opens a PQCF file as a new table; same as {@code open(table, path, false)}. */
    public TableSchema open(String table, String path) {
        return open(table, path, false);
    }

    /**
     * Opens the PQCF file {@code path} (relative to the data directory) as table {@code table},
     * with the indexes recorded in the file.
     *
     * @param replace replace an existing table of that name (else ALREADY_EXISTS)
     * @throws DatabaseException NOT_FOUND, ACCESS_DENIED, STORAGE_CORRUPT,
     *                           STORAGE_VERSION_UNSUPPORTED, ALREADY_EXISTS, IO_ERROR
     */
    public TableSchema open(String table, String path, boolean replace) {
        requireTableName(table);
        requireNonNull(path, "path");
        return call(() -> describe(engine.open(new OpenRequest(table, path, false, replace, Layout.COLUMN))));
    }

    // ---------------------------------------------------------------- catalog

    /**
     * Drops table {@code table} and its indexes.
     *
     * @throws DatabaseException NOT_FOUND
     */
    public void drop(String table) {
        requireNonNull(table, "table");
        call(() -> {
            engine.catalog().drop(table);
            return null;
        });
    }

    /** All tables, sorted by name. */
    public List<TableInfo> tables() {
        return call(() -> engine.catalog().list().stream()
                .map(t -> new TableInfo(t.name(), t.rowCount()))
                .toList());
    }

    /**
     * The schema of table {@code table}.
     *
     * @throws DatabaseException NOT_FOUND
     */
    public TableSchema schema(String table) {
        requireNonNull(table, "table");
        return call(() -> describe(engine.catalog().require(table)));
    }

    // ---------------------------------------------------------------- lifecycle

    /** True after {@link #close()}. */
    public boolean isClosed() {
        return closed;
    }

    /**
     * Drops every table and releases the instance's memory. Further calls throw
     * {@link IllegalStateException}; closing twice has no effect. Operations running
     * concurrently complete on the catalog version they started with.
     */
    @Override
    public void close() {
        closed = true;
        engine.catalog().reset();
    }

    // ---------------------------------------------------------------- helpers

    private <T> T call(Supplier<T> operation) {
        if (closed) {
            throw new IllegalStateException("the database is closed");
        }
        try {
            return operation.get();
        } catch (PolyQueryException e) {
            throw translate(e);
        } catch (DatabaseException e) {
            throw e;
        } catch (StackOverflowError e) {
            throw new DatabaseException(ErrorCode.RESOURCE_LIMIT, "statement too deeply nested");
        } catch (OutOfMemoryError e) {
            throw new DatabaseException(ErrorCode.RESOURCE_LIMIT, "out of memory");
        } catch (RuntimeException e) {
            throw new DatabaseException(ErrorCode.INTERNAL_ERROR, "internal error: " + e);
        }
    }

    private static DatabaseException translate(PolyQueryException e) {
        String message = e.getMessage() == null ? e.code().name() : e.getMessage();
        return new DatabaseException(ErrorCode.valueOf(e.code().name()), message, e.details());
    }

    private static TableSchema describe(Table t) {
        List<Column> columns = new ArrayList<>(t.columnCount());
        for (ColumnSchema c : t.columns()) {
            columns.add(new Column(c.name(), ValueMapping.toApi(c.type())));
        }
        List<TableSchema.IndexInfo> indexes = new ArrayList<>();
        for (Index i : t.indexes()) {
            indexes.add(new TableSchema.IndexInfo(i.name(), t.columns().get(i.column()).name(), i.kind().name()));
        }
        return new TableSchema(t.name(), t.rowCount(), columns, indexes);
    }

    private static List<ColumnSchema> engineSchema(List<Column> columns) {
        List<ColumnSchema> out = new ArrayList<>(columns.size());
        for (Column c : columns) {
            out.add(new ColumnSchema(c.name(), ValueMapping.toEngine(c.type())));
        }
        return out;
    }

    private static void requireTableName(String table) {
        requireNonNull(table, "table");
        if (table.isEmpty()) {
            throw new IllegalArgumentException("table name must not be empty");
        }
    }

    private static void requireNonNull(Object value, String what) {
        if (value == null) {
            throw new NullPointerException(what + " must not be null");
        }
    }
}
