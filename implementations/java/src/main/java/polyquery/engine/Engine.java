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
import java.util.Map;
import java.util.function.Function;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.exec.Executor;
import polyquery.exec.QueryResult;
import polyquery.ingest.CsvIngest;
import polyquery.ingest.IngestOptions;
import polyquery.ingest.JsonIngest;
import polyquery.json.JsonWriter;
import polyquery.optimizer.LogicalOptimizer;
import polyquery.physical.PhysicalPlan;
import polyquery.physical.PhysicalPlanner;
import polyquery.physical.PlanExplainer;
import polyquery.plan.LogicalPlan;
import polyquery.sql.analyzer.Analyzer;
import polyquery.sql.analyzer.FunctionRegistry;
import polyquery.sql.ast.Query;
import polyquery.sql.ast.Statement;
import polyquery.sql.parser.Parser;
import polyquery.storage.Catalog;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;
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
        Table table = switch (req.format()) {
            case "csv" -> CsvIngest.load(req.table(), text, opts);
            case "json" -> JsonIngest.loadArray(req.table(), text, opts);
            case "jsonl" -> JsonIngest.loadLines(req.table(), text, opts);
            default -> throw PolyQueryException.of(ErrorCode.INVALID_REQUEST, "unknown format '%s'", req.format());
        };
        catalog.put(table, req.replace());
        return table;
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

    /** Executes one SQL statement: lex → parse → analyze → logical plan → optimize → physical plan → execute. */
    public QueryResult query(String sql, QueryOptions opts) {
        Statement stmt = Parser.parse(sql);
        return switch (stmt) {
            case Statement.QueryStatement qs -> {
                Function<LogicalPlan, PhysicalPlan> planner = planner(opts);
                PhysicalPlan plan = planner.apply(analyze(qs.query()));
                yield Executor.run(plan, newContext(opts), !opts.countOnly(), planner);
            }
            case Statement.Explain e -> {
                String text = JsonWriter.write(explainQuery(e.query(), opts));
                if (opts.maxRows() == 0) {
                    throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "result exceeds max_rows (0)");
                }
                List<Object[]> rows = new ArrayList<>();
                rows.add(new Object[] {text});
                yield new QueryResult(List.of(new ColumnSchema("plan", DataType.STRING)),
                        opts.countOnly() ? null : rows, 1);
            }
            case Statement.CreateIndex c -> throw new PolyQueryException(ErrorCode.UNSUPPORTED, "indexes are not supported");
            case Statement.DropIndex d -> throw new PolyQueryException(ErrorCode.UNSUPPORTED, "indexes are not supported");
        };
    }

    /** The EXPLAIN plan tree of a query (or of the query of an EXPLAIN statement). */
    public Map<String, Object> explain(String sql, QueryOptions opts) {
        Statement stmt = Parser.parse(sql);
        return switch (stmt) {
            case Statement.QueryStatement qs -> explainQuery(qs.query(), opts);
            case Statement.Explain e -> explainQuery(e.query(), opts);
            case Statement.CreateIndex c -> throw new PolyQueryException(ErrorCode.UNSUPPORTED, "indexes are not supported");
            case Statement.DropIndex d -> throw new PolyQueryException(ErrorCode.UNSUPPORTED, "indexes are not supported");
        };
    }

    private Map<String, Object> explainQuery(Query query, QueryOptions opts) {
        Function<LogicalPlan, PhysicalPlan> planner = planner(opts);
        return new PlanExplainer(planner).explain(planner.apply(analyze(query)));
    }

    private LogicalPlan analyze(Query query) {
        return new Analyzer(catalog, functions).analyze(query);
    }

    /** Logical optimization (unless disabled) followed by physical planning; also used for subqueries. */
    private static Function<LogicalPlan, PhysicalPlan> planner(QueryOptions opts) {
        PhysicalPlanner physical = new PhysicalPlanner(opts.joinStrategy());
        return logical -> physical.plan(opts.optimize() ? LogicalOptimizer.optimize(logical) : logical);
    }

    private ExecContext newContext(QueryOptions opts) {
        return new ExecContext(opts.timeoutMs(), config.maxQueryMemoryBytes(), opts.maxRows(), config.maxJoinRows());
    }
}
