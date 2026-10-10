package polyquery.protocol;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.engine.LoadRequest;
import polyquery.engine.QueryOptions;
import polyquery.engine.Version;
import polyquery.exec.QueryResult;
import polyquery.json.JsonException;
import polyquery.json.JsonNumber;
import polyquery.json.JsonParser;
import polyquery.json.JsonWriter;
import polyquery.physical.PhysicalPlanner.JoinStrategy;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;
import polyquery.types.DataType;

/** Executes protocol requests (protocol.md §4–§5) and renders single-line JSON responses. */
public final class RequestHandler {
    private final Engine engine;
    private final Logger log;

    public RequestHandler(Engine engine, Logger log) {
        this.engine = engine;
        this.log = log;
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
        if (!(parsed instanceof Map<?, ?> raw)) {
            return error(null, new PolyQueryException(ErrorCode.INVALID_REQUEST, "request must be a JSON object"));
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> req = (Map<String, Object>) raw;
        Object id = req.get("id");
        long start = System.nanoTime();
        try {
            return dispatch(req, id, start);
        } catch (PolyQueryException e) {
            log.debug("request failed: " + e.code() + ": " + e.getMessage());
            return error(id, e);
        } catch (StackOverflowError e) {
            return error(id, new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "statement too deeply nested"));
        } catch (OutOfMemoryError e) {
            return error(id, new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "out of memory"));
        } catch (RuntimeException e) {
            log.error("internal error: " + e);
            return error(id, new PolyQueryException(ErrorCode.INTERNAL_ERROR, "internal error: " + e.getClass().getSimpleName()));
        }
    }

    private String dispatch(Map<String, Object> req, Object id, long start) {
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
            case "query" -> query(id, req, start);
            case "sleep" -> sleep(id, req);
            case "explain" -> {
                String sql = requireString(req, "sql");
                QueryOptions opts = parseQueryOptions(optionalObject(req, "options"));
                yield ok(id, Map.of("plan", engine.explain(sql, opts)));
            }
            case "save", "open", "stats" ->
                    throw PolyQueryException.of(ErrorCode.UNSUPPORTED, "operation '%s' is not supported", opName);
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

    private static Long optionalNonNegativeLong(Map<String, Object> m, String field) {
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

    private static boolean optionalBoolean(Map<String, Object> m, String field, boolean dflt) {
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
    private static Map<String, Object> optionalObject(Map<String, Object> m, String field) {
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
        m.put("indexes", List.of());
        return ok(id, m);
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
        Table t = engine.load(new LoadRequest(table, format, (String) path, (String) data, schema, header,
                delimiter, replace));
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

    private String query(Object id, Map<String, Object> req, long start) {
        String sql = requireString(req, "sql");
        QueryOptions opts = parseQueryOptions(optionalObject(req, "options"));
        QueryResult r = engine.query(sql, opts);
        StringBuilder sb = new StringBuilder(256);
        sb.append("{\"id\":");
        JsonWriter.write(sb, id);
        sb.append(",\"ok\":true,\"columns\":");
        ResultWriter.writeColumns(sb, r.columns());
        if (r.rows() != null) {
            sb.append(",\"rows\":");
            ResultWriter.writeRows(sb, r.columns(), r.rows());
        }
        sb.append(",\"row_count\":").append(r.rowCount());
        sb.append(",\"stats\":{\"elapsed_us\":").append((System.nanoTime() - start) / 1000).append("}}");
        return sb.toString();
    }

    private static QueryOptions parseQueryOptions(Map<String, Object> o) {
        Long maxRows = optionalNonNegativeLong(o, "max_rows");
        Long timeout = optionalNonNegativeLong(o, "timeout_ms");
        boolean countOnly = false;
        Object result = o.get("result");
        if (result != null) {
            if (!(result instanceof String rs)) {
                throw RequestException.invalid("'result' must be a string");
            }
            switch (rs) {
                case "rows" -> countOnly = false;
                case "count" -> countOnly = true;
                default -> throw PolyQueryException.of(ErrorCode.UNSUPPORTED, "result mode '%s' is not supported", rs);
            }
        }
        Object mode = o.get("mode");
        if (mode != null) {
            if (!(mode instanceof String ms)) {
                throw RequestException.invalid("'mode' must be a string");
            }
            if (!ms.equals("auto") && !ms.equals("row")) {
                throw PolyQueryException.of(ErrorCode.UNSUPPORTED, "execution mode '%s' is not supported", ms);
            }
        }
        JoinStrategy joinStrategy = JoinStrategy.AUTO;
        Object join = o.get("join");
        if (join != null) {
            if (!(join instanceof String js)) {
                throw RequestException.invalid("'join' must be a string");
            }
            joinStrategy = switch (js) {
                case "auto", "merge" -> JoinStrategy.AUTO;
                case "hash" -> JoinStrategy.HASH;
                case "nested_loop" -> JoinStrategy.NESTED_LOOP;
                default -> throw PolyQueryException.of(ErrorCode.UNSUPPORTED, "join algorithm '%s' is not supported", js);
            };
        }
        Long threads = optionalNonNegativeLong(o, "threads");
        if (threads != null && threads < 1) {
            throw RequestException.invalid("'threads' must be >= 1");
        }
        boolean optimize = optionalBoolean(o, "optimize", true);
        optionalBoolean(o, "use_indexes", true);
        optionalBoolean(o, "native", false);
        Object queryId = o.get("query_id");
        if (queryId != null && !(queryId instanceof String)) {
            throw RequestException.invalid("'query_id' must be a string");
        }
        return new QueryOptions(maxRows == null ? -1 : maxRows, timeout == null ? 0 : timeout, countOnly, optimize,
                joinStrategy);
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
