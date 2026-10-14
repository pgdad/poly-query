package pqledger.ledger;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import polyquery.api.Column;
import polyquery.api.ColumnType;
import polyquery.api.Database;
import polyquery.api.DatabaseConfig;
import polyquery.api.DatabaseException;
import polyquery.api.QueryOptions;
import polyquery.api.Result;
import polyquery.api.TableSchema;
import pqledger.AppException;
import pqledger.config.Config;

/**
 * The ledger (spec §4): the PQCF files {@code transactions.pqcf}, {@code batches.pqcf} and
 * {@code overrides.pqcf} in the data directory, opened as tables of an embedded
 * {@link Database} whose data directory is the ledger directory.
 */
public final class Ledger implements AutoCloseable {
    public static final String TRANSACTIONS = "transactions";
    public static final String BATCHES = "batches";
    public static final String OVERRIDES = "overrides";

    public static final List<Column> TRANSACTION_COLUMNS = List.of(
            new Column("id", ColumnType.INT64), new Column("account", ColumnType.STRING),
            new Column("date", ColumnType.DATE), new Column("description", ColumnType.STRING),
            new Column("merchant", ColumnType.STRING), new Column("amount", ColumnType.decimal(18, 2)),
            new Column("batch", ColumnType.INT64));
    public static final List<Column> BATCH_COLUMNS = List.of(
            new Column("batch", ColumnType.INT64), new Column("account", ColumnType.STRING),
            new Column("file", ColumnType.STRING), new Column("imported", ColumnType.INT64),
            new Column("duplicates", ColumnType.INT64));
    public static final List<Column> OVERRIDE_COLUMNS = List.of(
            new Column("id", ColumnType.INT64), new Column("category", ColumnType.STRING));

    private final Database db;
    private final QueryOptions options;

    private Ledger(Database db, QueryOptions options) {
        this.db = db;
        this.options = options;
    }

    /** The PQCF file of {@code table}. */
    public static String fileName(String table) {
        return table + ".pqcf";
    }

    /** True if {@code dataDir} holds a ledger ({@code transactions.pqcf} exists). */
    public static boolean exists(Path dataDir) {
        return Files.exists(dataDir.resolve(fileName(TRANSACTIONS)));
    }

    /**
     * {@code init}: creates the data directory and the three tables with zero rows.
     *
     * @throws AppException exit 6 if a ledger exists, 7 if the directory cannot be created
     */
    public static void create(Config config) throws AppException {
        if (exists(config.dataDir())) {
            throw AppException.ledgerState("a ledger already exists in " + config.dataDir());
        }
        try {
            Files.createDirectories(config.dataDir());
        } catch (IOException | SecurityException e) {
            throw AppException.other("cannot create the data directory " + config.dataDir() + ": " + e.getMessage());
        }
        try (Ledger ledger = new Ledger(Database.create(databaseConfig(config)), queryOptions(config))) {
            // transactions.pqcf last: its presence marks a complete ledger
            for (String table : List.of(OVERRIDES, BATCHES, TRANSACTIONS)) {
                ledger.db.createTable(table, columns(table), List.of(), false);
                ledger.save(table);
            }
        }
    }

    /**
     * Opens the ledger of {@code config}.
     *
     * @throws AppException exit 6 if there is no ledger, 7 if a file does not have the
     *                      ledger's columns
     */
    public static Ledger open(Config config) throws AppException {
        if (!exists(config.dataDir())) {
            throw AppException.ledgerState("no ledger in " + config.dataDir() + " (run 'pqledger init')");
        }
        Ledger ledger = new Ledger(Database.create(databaseConfig(config)), queryOptions(config));
        try {
            for (String table : List.of(TRANSACTIONS, BATCHES, OVERRIDES)) {
                ledger.openTable(table, config.dataDir());
            }
        } catch (AppException | RuntimeException e) {
            ledger.close();
            throw e;
        }
        return ledger;
    }

    private void openTable(String table, Path dataDir) throws AppException {
        TableSchema schema;
        try {
            schema = db.open(table, fileName(table));
        } catch (DatabaseException e) {
            throw AppException.other("cannot open " + dataDir.resolve(fileName(table)) + ": " + e.code()
                    + ": " + e.getMessage());
        }
        List<Column> expected = columns(table);
        boolean ok = schema.columns().size() == expected.size();
        for (int i = 0; ok && i < expected.size(); i++) {
            ok = schema.columns().get(i).name().equalsIgnoreCase(expected.get(i).name())
                    && schema.columns().get(i).type().equals(expected.get(i).type());
        }
        if (!ok) {
            throw AppException.other(fileName(table) + " does not have the columns of the ledger's " + table
                    + " table: " + schema.columns());
        }
    }

    private static List<Column> columns(String table) {
        return switch (table) {
            case TRANSACTIONS -> TRANSACTION_COLUMNS;
            case BATCHES -> BATCH_COLUMNS;
            default -> OVERRIDE_COLUMNS;
        };
    }

    private static DatabaseConfig databaseConfig(Config config) {
        DatabaseConfig.Builder b = DatabaseConfig.builder(config.dataDir());
        if (config.memoryMb() != null) {
            b.maxQueryMemoryMb(config.memoryMb());
        }
        if (config.threads() != null) {
            b.threads(config.threads());
        }
        return b.build();
    }

    private static QueryOptions queryOptions(Config config) {
        return config.threads() == null ? QueryOptions.DEFAULT : QueryOptions.DEFAULT.withThreads(config.threads());
    }

    /** The embedded engine instance holding the ledger's tables. */
    public Database database() {
        return db;
    }

    /** The query options from {@code [engine]}. */
    public QueryOptions queryOptions() {
        return options;
    }

    /** Runs one SQL statement with the configured options. */
    public Result query(String sql) {
        return db.query(sql, options);
    }

    /** Replaces the in-memory table {@code table} by the result of {@code sql}. */
    public void replaceTable(String table, String sql) {
        db.createTableAs(table, sql, options, true);
    }

    /** Writes the in-memory table {@code table} to its PQCF file (atomically). */
    public void save(String table) {
        db.save(table, fileName(table));
    }

    @Override
    public void close() {
        db.close();
    }
}
