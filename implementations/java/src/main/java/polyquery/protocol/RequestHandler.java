package polyquery.protocol;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.engine.LoadRequest;
import polyquery.engine.OpenRequest;
import polyquery.engine.SaveRequest;
import polyquery.engine.Version;
import polyquery.exec.QueryControl;
import polyquery.exec.QueryResult;
import polyquery.index.Index;
import polyquery.json.JsonException;
import polyquery.json.JsonNumber;
import polyquery.json.JsonParser;
import polyquery.json.JsonWriter;
import polyquery.storage.ColumnSchema;
import polyquery.storage.ColumnStats;
import polyquery.storage.Layout;
import polyquery.storage.Layouts;
import polyquery.storage.Table;
import polyquery.storage.pqcf.PqcfWriter;
import polyquery.storage.pqcf.SaveEncoding;
import polyquery.types.DataType;

/** Executes protocol requests (protocol.md §4–§5) and renders single-line JSON responses. */
public final class RequestHandler {
    private final Engine engine;
    private final Logger log;
    private final QueryRunner runner;

    /** Per-request state that must survive failures (for the HTTP query id header). */
    private static final class Exchange {
        private final QueryControl control;
        private String queryId;

        Exchange(QueryControl control) {
            this.control = control;
        }
    }

    public RequestHandler(Engine engine, Logger log) {
        this(engine, log, QueryRunner.DIRECT);
    }

    public RequestHandler(Engine engine, Logger log, QueryRunner runner) {
        this.engine = engine;
        this.log = log;
        this.runner = runner;
    }

    public Engine engine() {
        return engine;
    }

    public QueryRunner runner() {
        return runner;
    }

    /** Handles one raw request line. Never throws. */
    public String handleLine(String line) {
        Object parsed;
        try {
            parsed = JsonParser.parse(line);
        } catch (JsonException e) {
            return error(null, new PolyQueryException(ErrorCode.INVALID_REQUEST, "malformed JSON: " + e.getMessage()));
        } catch (StackOverflowError e) {
            return error(null, new PolyQueryException(ErrorCode.INVALID_REQUEST, "request nested too deeply"));
        }
        return handle(parsed);
    }

    /** Handles one parsed request value. Never throws. */
    public String handle(Object parsed) {
        return handle(parsed, new QueryControl()).json();
    }

    /**
     * Handles one parsed request value; a {@code query} request runs under {@code control}, so
     * the caller can cancel it. Never throws.
     */
    public Response handle(Object parsed, QueryControl control) {
        if (!(parsed instanceof Map<?, ?> raw)) {
            return failure(null, null,
                    new PolyQueryException(ErrorCode.INVALID_REQUEST, "request must be a JSON object"));
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> req = (Map<String, Object>) raw;
        Object id = req.get("id");
        long start = System.nanoTime();
        Exchange exchange = new Exchange(control);
        try {
            return new Response(dispatch(req, id, start, exchange), null, exchange.queryId);
        } catch (PolyQueryException e) {
            log.debug("request failed: " + e.code() + ": " + e.getMessage());
            return failure(id, exchange.queryId, e);
        } catch (StackOverflowError e) {
            return failure(id, exchange.queryId,
                    new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "statement too deeply nested"));
        } catch (OutOfMemoryError e) {
            return failure(id, exchange.queryId, new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "out of memory"));
        } catch (RuntimeException e) {
            log.error("internal error: " + e);
            return failure(id, exchange.queryId, new PolyQueryException(ErrorCode.INTERNAL_ERROR,
                    "internal error: " + e.getClass().getSimpleName()));
        }
    }

    private static Response failure(Object id, String queryId, PolyQueryException e) {
        return new Response(error(id, e), e.code(), queryId);
    }

    private String dispatch(Map<String, Object> req, Object id, long start, Exchange exchange) {
        Object op = req.get("op");
        if (!(op instanceof String opName)) {
            throw RequestException.invalid("missing or invalid 'op'");
        }
        return switch (opName) {
            case "version" -> ok(id, Version.versionFields());
            case "capabilities" -> ok(id, Version.capabilityFields());
            case "tables" -> tables(id);
            case "schema" -> schema(id, req);
            case "drop" -> {
                engine.catalog().drop(requireString(req, "table"));
                yield ok(id, Map.of());
            }
            case "reset" -> {
                engine.catalog().reset();
                yield ok(id, Map.of());
            }
            case "load" -> load(id, req);
            case "query" -> query(id, req, start, exchange);
            case "sleep" -> sleep(id, req);
            case "explain" -> {
                QueryRequest q = QueryRequest.parse(req);
                yield ok(id, Map.of("plan", engine.explain(q.sql(), q.options())));
            }
            case "save" -> save(id, req);
            case "open" -> open(id, req);
            case "stats" -> stats(id, req);
            default -> throw RequestException.invalid("unknown op '%s'", opName);
        };
    }

    // ---------------------------------------------------------------- field helpers

    static String requireString(Map<String, Object> req, String field) {
        Object v = req.get(field);
        if (!(v instanceof String s)) {
            throw RequestException.invalid("missing or invalid '%s'", field);
        }
        return s;
    }

    static Long optionalNonNegativeLong(Map<String, Object> m, String field) {
        if (!m.containsKey(field) || m.get(field) == null) {
            return null;
        }
        Object v = m.get(field);
        if (v instanceof JsonNumber n && n.isIntegerLiteral()) {
            try {
                long x = Long.parseLong(n.text());
                if (x >= 0) {
                    return x;
                }
            } catch (NumberFormatException e) {
                return Long.MAX_VALUE;
            }
        }
        throw RequestException.invalid("'%s' must be a non-negative integer", field);
    }

    static boolean optionalBoolean(Map<String, Object> m, String field, boolean dflt) {
        Object v = m.get(field);
        if (v == null) {
            return dflt;
        }
        if (v instanceof Boolean b) {
            return b;
        }
        throw RequestException.invalid("'%s' must be a boolean", field);
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> optionalObject(Map<String, Object> m, String field) {
        Object v = m.get(field);
        if (v == null) {
            return Map.of();
        }
        if (v instanceof Map<?, ?> o) {
            return (Map<String, Object>) o;
        }
        throw RequestException.invalid("'%s' must be an object", field);
    }

    // ---------------------------------------------------------------- operations

    private String tables(Object id) {
        List<Object> list = new ArrayList<>();
        for (Table t : engine.catalog().list()) {
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("name", t.name());
            e.put("row_count", (long) t.rowCount());
            list.add(e);
        }
        return ok(id, Map.of("tables", list));
    }

    private String schema(Object id, Map<String, Object> req) {
        Table t = engine.catalog().require(requireString(req, "table"));
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("table", t.name());
        m.put("row_count", (long) t.rowCount());
        m.put("columns", columnsJson(t.columns()));
        m.put("indexes", indexesJson(t));
        m.put("layout", t.layout().jsonName());
        return ok(id, m);
    }

    private static List<Object> indexesJson(Table t) {
        List<Object> out = new ArrayList<>();
        for (Index i : t.indexes()) {
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("name", i.name());
            e.put("column", t.columns().get(i.column()).name());
            e.put("kind", i.kind().name());
            out.add(e);
        }
        return out;
    }

    private String stats(Object id, Map<String, Object> req) {
        Table t = engine.catalog().require(requireString(req, "table"));
        List<Object> cols = new ArrayList<>();
        for (int i = 0; i < t.columnCount(); i++) {
            ColumnSchema c = t.columns().get(i);
            ColumnStats s = t.stats().column(i);
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("name", c.name());
            e.put("type", c.type().toString());
            e.put("null_count", s.nullCount());
            e.put("distinct_count", s.distinctCount());
            e.put("min", ResultWriter.jsonValue(s.min(), c.type()));
            e.put("max", ResultWriter.jsonValue(s.max(), c.type()));
            cols.add(e);
        }
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("table", t.name());
        m.put("row_count", (long) t.rowCount());
        m.put("columns", cols);
        return ok(id, m);
    }

    private static String requireTableName(Map<String, Object> req) {
        String table = requireString(req, "table");
        if (table.isEmpty()) {
            throw RequestException.invalid("'table' must not be empty");
        }
        return table;
    }

    private String open(Object id, Map<String, Object> req) {
        String table = requireTableName(req);
        String path = requireString(req, "path");
        Map<String, Object> options = optionalObject(req, "options");
        boolean mmap = optionalBoolean(options, "mmap", false);
        Layout layout = parseLayout(options);
        boolean replace = optionalBoolean(req, "replace", false);
        Table t = engine.open(new OpenRequest(table, path, mmap, replace, layout));
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("table", t.name());
        m.put("row_count", (long) t.rowCount());
        m.put("columns", columnsJson(t.columns()));
        m.put("indexes", indexesJson(t));
        return ok(id, m);
    }

    private String save(Object id, Map<String, Object> req) {
        String table = requireString(req, "table");
        String path = requireString(req, "path");
        Map<String, Object> options = optionalObject(req, "options");
        Long groupSize = optionalNonNegativeLong(options, "row_group_size");
        if (groupSize != null && (groupSize < 1 || groupSize > Integer.MAX_VALUE)) {
            throw RequestException.invalid("'row_group_size' must be between 1 and %d", Integer.MAX_VALUE);
        }
        SaveEncoding encoding = SaveEncoding.AUTO;
        Object enc = options.get("encoding");
        if (enc != null) {
            if (!(enc instanceof String es) || (encoding = SaveEncoding.fromName(es)) == null) {
                throw RequestException.invalid("'encoding' must be one of auto, plain, dict, rle");
            }
        }
        long bytes = engine.save(new SaveRequest(table, path,
                groupSize == null ? PqcfWriter.DEFAULT_ROW_GROUP_SIZE : groupSize.intValue(), encoding));
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("path", path);
        m.put("bytes", bytes);
        return ok(id, m);
    }

    /** The {@code layout} option of load/open (default: column). */
    private static Layout parseLayout(Map<String, Object> options) {
        Object v = options.get("layout");
        if (v == null) {
            return Layout.COLUMN;
        }
        Layout layout = v instanceof String s ? Layout.fromName(s) : null;
        if (layout == null) {
            throw RequestException.invalid("'layout' must be \"row\" or \"column\"");
        }
        return layout;
    }

    private static List<Object> columnsJson(List<ColumnSchema> cols) {
        List<Object> out = new ArrayList<>();
        for (ColumnSchema c : cols) {
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("name", c.name());
            e.put("type", c.type().toString());
            out.add(e);
        }
        return out;
    }

    private String load(Object id, Map<String, Object> req) {
        String table = requireString(req, "table");
        if (table.isEmpty()) {
            throw RequestException.invalid("'table' must not be empty");
        }
        String format = requireString(req, "format");
        if (!format.equals("csv") && !format.equals("json") && !format.equals("jsonl")) {
            throw RequestException.invalid("unknown format '%s'", format);
        }
        Object path = req.get("path");
        Object data = req.get("data");
        if ((path == null) == (data == null)) {
            throw RequestException.invalid("exactly one of 'path' or 'data' is required");
        }
        if ((path != null && !(path instanceof String)) || (data != null && !(data instanceof String))) {
            throw RequestException.invalid("'path'/'data' must be strings");
        }
        List<ColumnSchema> schema = parseSchema(req.get("schema"));
        Map<String, Object> options = optionalObject(req, "options");
        boolean header = optionalBoolean(options, "header", true);
        char delimiter = ',';
        Object d = options.get("delimiter");
        if (d != null) {
            if (!(d instanceof String ds) || ds.length() != 1 || ds.charAt(0) > 127
                    || ds.charAt(0) == '"' || ds.charAt(0) == '\n' || ds.charAt(0) == '\r') {
                throw RequestException.invalid("'delimiter' must be a single ASCII character");
            }
            delimiter = ds.charAt(0);
        }
        if (!header && schema == null && format.equals("csv")) {
            throw RequestException.invalid("header=false requires an explicit schema");
        }
        boolean replace = optionalBoolean(req, "replace", false);
        Layout layout = parseLayout(options);
        Object dict = options.get("dictionary");
        if (dict != null && !(dict instanceof Boolean)) {
            throw RequestException.invalid("'dictionary' must be a boolean");
        }
        Layouts.Dictionary dictionary = dict == null ? Layouts.Dictionary.AUTO
                : (Boolean) dict ? Layouts.Dictionary.ALWAYS : Layouts.Dictionary.NEVER;
        Table t = engine.load(new LoadRequest(table, format, (String) path, (String) data, schema, header,
                delimiter, replace, layout, dictionary));
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("table", t.name());
        m.put("row_count", (long) t.rowCount());
        m.put("columns", columnsJson(t.columns()));
        return ok(id, m);
    }

    private static List<ColumnSchema> parseSchema(Object v) {
        if (v == null) {
            return null;
        }
        if (!(v instanceof List<?> list)) {
            throw RequestException.invalid("'schema' must be an array");
        }
        List<ColumnSchema> out = new ArrayList<>();
        for (Object o : list) {
            if (!(o instanceof Map<?, ?> col) || !(col.get("name") instanceof String name)
                    || !(col.get("type") instanceof String type)) {
                throw RequestException.invalid("schema entries must be {\"name\":…,\"type\":…}");
            }
            DataType dt;
            try {
                dt = DataType.parse(type);
            } catch (IllegalArgumentException | PolyQueryException e) {
                throw RequestException.invalid("invalid type '%s' in schema", type);
            }
            out.add(new ColumnSchema(name, dt));
        }
        return out;
    }

    private String query(Object id, Map<String, Object> req, long start, Exchange exchange) {
        QueryRequest q = QueryRequest.parse(req);
        String queryId = q.queryId() != null ? q.queryId() : runner.newQueryId();
        exchange.queryId = queryId;
        QueryResult r = runner.run(queryId, q.options(), exchange.control,
                control -> engine.query(q.sql(), q.options(), control), QueryResult::rowCount);
        StringBuilder sb = new StringBuilder(256);
        sb.append("{\"id\":");
        JsonWriter.write(sb, id);
        sb.append(",\"ok\":true,\"query_id\":");
        JsonWriter.writeString(sb, queryId);
        sb.append(",\"columns\":");
        ResultWriter.writeColumns(sb, r.columns());
        if (r.rows() != null) {
            sb.append(",\"rows\":");
            ResultWriter.writeRows(sb, r.columns(), r.rows());
        }
        sb.append(",\"row_count\":").append(r.rowCount());
        sb.append(",\"stats\":{\"elapsed_us\":").append((System.nanoTime() - start) / 1000).append("}}");
        return sb.toString();
    }

    private String sleep(Object id, Map<String, Object> req) {
        if (!engine.config().testFunctions()) {
            throw RequestException.invalid("unknown op 'sleep' (test functions are disabled)");
        }
        Long ms = optionalNonNegativeLong(req, "ms");
        if (ms == null) {
            throw RequestException.invalid("missing 'ms'");
        }
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return ok(id, Map.of());
    }

    // ---------------------------------------------------------------- rendering

    private static String ok(Object id, Map<String, Object> fields) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", id);
        m.put("ok", true);
        m.putAll(fields);
        return JsonWriter.write(m);
    }

    public static String error(Object id, PolyQueryException e) {
        Map<String, Object> err = new LinkedHashMap<>();
        err.put("code", e.code().name());
        err.put("message", e.getMessage() == null ? e.code().name() : e.getMessage());
        if (!e.details().isEmpty()) {
            err.put("details", e.details());
        }
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", id);
        m.put("ok", false);
        m.put("error", err);
        return JsonWriter.write(m);
    }
}
