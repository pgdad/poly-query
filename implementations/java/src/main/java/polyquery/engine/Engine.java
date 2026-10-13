package polyquery.engine;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.AccessDeniedException;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Function;
import polyquery.common.Checkpoint;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.exec.ExecMode;
import polyquery.exec.Executor;
import polyquery.exec.QueryControl;
import polyquery.exec.QueryResult;
import polyquery.exec.ResultSink;
import polyquery.exec.vector.VectorExecutor;
import polyquery.index.Index;
import polyquery.index.IndexKind;
import polyquery.ingest.CsvIngest;
import polyquery.ingest.IngestOptions;
import polyquery.ingest.JsonIngest;
import polyquery.json.JsonWriter;
import polyquery.physical.PhysicalPlan;
import polyquery.physical.PhysicalQuery;
import polyquery.physical.PlanExplainer;
import polyquery.plan.LogicalPlan;
import polyquery.sql.analyzer.Analyzer;
import polyquery.sql.analyzer.FunctionRegistry;
import polyquery.sql.ast.Query;
import polyquery.sql.ast.Statement;
import polyquery.sql.parser.Parser;
import polyquery.storage.Catalog;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Layout;
import polyquery.storage.Layouts;
import polyquery.storage.Table;
import polyquery.storage.TableData;
import polyquery.storage.pqcf.PqcfReader;
import polyquery.storage.pqcf.PqcfWriter;
import polyquery.types.DataType;

/**
 * The engine core shared by all front-ends: catalog operations, ingestion and the SQL
 * pipeline (lex → parse → analyze → logical plan → physical plan → execute).
 */
public final class Engine {
    private final EngineConfig config;
    private final Catalog catalog = new Catalog();
    private final PathResolver paths;
    private final FunctionRegistry functions;

    public Engine(EngineConfig config) {
        this.config = config;
        this.paths = new PathResolver(config.dataDir());
        this.functions = new FunctionRegistry(config.testFunctions());
    }

    public EngineConfig config() {
        return config;
    }

    public Catalog catalog() {
        return catalog;
    }

    // ---------------------------------------------------------------- ingestion

    public Table load(LoadRequest req) {
        String text;
        if (req.path() != null) {
            text = readFile(paths.resolve(req.path()));
        } else {
            if ((long) req.data().length() > config.maxIngestBytes()) {
                throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "input exceeds the ingestion size limit");
            }
            text = req.data();
        }
        IngestOptions opts = new IngestOptions(req.schema(), req.header(), req.delimiter(), config.maxTableRows());
        Table ingested = switch (req.format()) {
            case "csv" -> CsvIngest.load(req.table(), text, opts);
            case "json" -> JsonIngest.loadArray(req.table(), text, opts);
            case "jsonl" -> JsonIngest.loadLines(req.table(), text, opts);
            default -> throw PolyQueryException.of(ErrorCode.INVALID_REQUEST, "unknown format '%s'", req.format());
        };
        Table table = new Table(ingested.name(), ingested.columns(),
                Layouts.convert(ingested.data(), ingested.columns(), req.layout(), req.dictionary()));
        catalog.put(table, req.replace());
        return table;
    }

    // ---------------------------------------------------------------- PQCF storage

    /** {@code open}: loads a PQCF file as a table and recreates the indexes recorded in it. */
    public Table open(OpenRequest req) {
        Path path = paths.resolve(req.path());
        catalog.checkAvailable(req.table(), List.of(), req.replace());
        PqcfReader.OpenedFile file = PqcfReader.open(path, req.mmap(), config.maxTableRows());
        List<String> indexNames = new ArrayList<>();
        for (PqcfReader.IndexDefinition d : file.indexes()) {
            indexNames.add(d.name());
        }
        catalog.checkAvailable(req.table(), indexNames, req.replace());
        TableData data = req.layout() == Layout.ROW
                ? Layouts.convert(file.data(), file.columns(), Layout.ROW, Layouts.Dictionary.NEVER) : file.data();
        Table table = new Table(req.table(), file.columns(), data);
        List<Index> indexes = new ArrayList<>();
        for (PqcfReader.IndexDefinition d : file.indexes()) {
            indexes.add(Index.build(d.name(), data, d.column(), table.columnType(d.column()), d.kind()));
        }
        table = table.withIndexes(indexes);
        catalog.put(table, req.replace());
        return table;
    }

    /** {@code save}: writes a table as a PQCF file atomically; returns the file size. */
    public long save(SaveRequest req) {
        Path path = paths.resolve(req.path());
        Table table = catalog.require(req.table());
        return PqcfWriter.save(table, path, Version.ENGINE + " " + Version.ENGINE_VERSION, req.rowGroupSize(),
                req.encoding());
    }

    private String readFile(Path p) {
        byte[] bytes;
        try {
            if (Files.isDirectory(p)) {
                throw PolyQueryException.of(ErrorCode.IO_ERROR, "'%s' is a directory", config.dataDir().relativize(p));
            }
            if (Files.size(p) > config.maxIngestBytes()) {
                throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "input exceeds the ingestion size limit");
            }
            bytes = Files.readAllBytes(p);
        } catch (NoSuchFileException e) {
            throw PolyQueryException.of(ErrorCode.NOT_FOUND, "file not found");
        } catch (AccessDeniedException e) {
            throw PolyQueryException.of(ErrorCode.IO_ERROR, "permission denied reading file");
        } catch (IOException e) {
            throw PolyQueryException.of(ErrorCode.IO_ERROR, "cannot read file: %s", e.getMessage());
        } catch (OutOfMemoryError e) {
            throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "input too large for available memory");
        }
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            throw new PolyQueryException(ErrorCode.INGEST_ERROR, "input is not valid UTF-8");
        }
    }

    // ---------------------------------------------------------------- SQL

    /** Executes one SQL statement with the timeout of {@code opts} and collects its result. */
    public QueryResult query(String sql, QueryOptions opts) {
        return query(sql, opts, QueryControl.withTimeout(opts.timeoutMs()));
    }

    /** Executes one SQL statement under {@code control} and collects its result. */
    public QueryResult query(String sql, QueryOptions opts, QueryControl control) {
        List<Object[]> rows = opts.countOnly() ? null : new ArrayList<>();
        List<List<ColumnSchema>> columns = new ArrayList<>(1);
        long count = execute(sql, opts, control, ctx -> new ResultSink() {
            @Override
            public void columns(List<ColumnSchema> cols) {
                columns.add(cols);
            }

            @Override
            public void row(Object[] row) {
                if (rows != null) {
                    ctx.reserve(ExecContext.estimateRow(row));
                    rows.add(row);
                }
            }

            @Override
            public boolean wantsRows() {
                return rows != null;
            }
        });
        return new QueryResult(columns.getFirst(), rows, count);
    }

    /**
     * Executes one SQL statement under {@code control}, passing the result to {@code sink}
     * incrementally (rows are passed even when {@code opts.countOnly()}); returns the row count.
     */
    public long stream(String sql, QueryOptions opts, QueryControl control, ResultSink sink) {
        return execute(sql, opts, control, ctx -> sink);
    }

    /**
     * lex → parse → analyze (against a catalog snapshot) → logical plan → optimize → physical
     * plan → execute.
     */
    private long execute(String sql, QueryOptions opts, QueryControl control,
                         Function<ExecContext, ResultSink> sinkFactory) {
        // The timeout covers every stage (CR-6 §4): parsing, binding and planning poll it too.
        return Checkpoint.with(control::check, () -> {
            control.check();
            Statement stmt = Parser.parse(sql);
            control.check();
            return execute(stmt, opts, control, sinkFactory);
        });
    }

    private long execute(Statement stmt, QueryOptions opts, QueryControl control,
                         Function<ExecContext, ResultSink> sinkFactory) {
        ExecContext ctx = newContext(opts, control);
        ResultSink sink = sinkFactory.apply(ctx);
        return switch (stmt) {
            case Statement.QueryStatement qs -> {
                QueryPlanner planner = planner(opts);
                LogicalPlan logical = analyze(qs.query(), catalog.snapshot());
                control.check();
                PhysicalQuery query = planner.planQuery(logical);
                control.check();
                ctx.withNativeKernels(query.nativeKernels() ? config.nativeKernels() : null);
                // subqueries are planned when first executed, possibly by a worker thread
                Function<LogicalPlan, PhysicalPlan> subqueries =
                        plan -> Checkpoint.with(control::check, () -> planner.plan(plan));
                yield query.mode() == ExecMode.ROW ? Executor.stream(query.root(), ctx, subqueries, sink)
                        : VectorExecutor.stream(query.root(), ctx, subqueries, sink, query.threads());
            }
            case Statement.Explain e -> {
                String text = JsonWriter.write(explainQuery(e.query(), opts, catalog.snapshot()));
                sink.columns(List.of(new ColumnSchema("plan", DataType.STRING)));
                if (opts.maxRows() == 0) {
                    throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "result exceeds max_rows (0)");
                }
                sink.row(new Object[] {text});
                yield 1;
            }
            case Statement.CreateIndex c -> {
                catalog.createIndex(c.name(), c.ifNotExists(), c.table(), c.column(),
                        IndexKind.valueOf(c.kind().toUpperCase(Locale.ROOT)));
                sink.columns(List.of());
                yield 0;
            }
            case Statement.DropIndex d -> {
                catalog.dropIndex(d.name(), d.ifExists());
                sink.columns(List.of());
                yield 0;
            }
        };
    }

    /**
     * The EXPLAIN plan tree of a query (or of the query of an EXPLAIN statement), computed
     * within the timeout of {@code opts}.
     */
    public Map<String, Object> explain(String sql, QueryOptions opts) {
        QueryControl control = QueryControl.withTimeout(opts.timeoutMs());
        return Checkpoint.with(control::check, () -> {
            Statement stmt = Parser.parse(sql);
            return switch (stmt) {
                case Statement.QueryStatement qs -> explainQuery(qs.query(), opts, catalog.snapshot());
                case Statement.Explain e -> explainQuery(e.query(), opts, catalog.snapshot());
                case Statement.CreateIndex c -> throw new PolyQueryException(ErrorCode.SEMANTIC_ERROR,
                        "only queries can be explained");
                case Statement.DropIndex d -> throw new PolyQueryException(ErrorCode.SEMANTIC_ERROR,
                        "only queries can be explained");
            };
        });
    }

    /**
     * The logical plan of a query before optimization — an internal debugging and test API
     * (render it with {@link polyquery.plan.LogicalPlanPrinter}); not part of the protocol.
     */
    public LogicalPlan logicalPlan(String sql) {
        if (!(Parser.parse(sql) instanceof Statement.QueryStatement qs)) {
            throw new PolyQueryException(ErrorCode.SEMANTIC_ERROR, "not a query");
        }
        return analyze(qs.query(), catalog.snapshot());
    }

    private Map<String, Object> explainQuery(Query query, QueryOptions opts, Catalog.Snapshot snapshot) {
        QueryPlanner planner = planner(opts);
        return new PlanExplainer(planner::plan).explain(planner.plan(analyze(query, snapshot)));
    }

    /** Name resolution sees exactly the table versions of {@code snapshot} (concurrency.md §1). */
    private LogicalPlan analyze(Query query, Catalog.Snapshot snapshot) {
        return new Analyzer(snapshot, functions).analyze(query);
    }

    private QueryPlanner planner(QueryOptions opts) {
        return new QueryPlanner(opts, threads(opts), config.nativeKernels() != null);
    }

    /** Worker threads a query may use: its {@code threads} option, else the engine's {@code --threads}. */
    private int threads(QueryOptions opts) {
        return opts.threads() > 0 ? opts.threads() : Math.max(1, config.threads());
    }

    private ExecContext newContext(QueryOptions opts, QueryControl control) {
        return new ExecContext(control, config.maxQueryMemoryBytes(), opts.maxRows(), config.maxJoinRows());
    }
}
