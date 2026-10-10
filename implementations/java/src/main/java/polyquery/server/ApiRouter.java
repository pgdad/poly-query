package polyquery.server;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Version;
import polyquery.exec.QueryControl;
import polyquery.json.JsonException;
import polyquery.json.JsonParser;
import polyquery.json.JsonWriter;
import polyquery.protocol.QueryRequest;
import polyquery.protocol.RequestHandler;
import polyquery.protocol.Response;

/**
 * Maps HTTP requests onto protocol operations (protocol.md §7) and writes the responses. Queries
 * run on a worker pool while the connection thread watches for a client disconnect, which
 * cancels the query.
 */
final class ApiRouter {
    static final String QUERY_ID_HEADER = "X-PolyQuery-Query-Id";
    private static final String JSON = "application/json";
    private static final int QUERY_POLL_MS = 5;

    private final RequestHandler handler;
    private final QueryManager manager;
    private final Metrics metrics;
    private final ExecutorService queryPool;
    private final HttpServer server;

    ApiRouter(RequestHandler handler, QueryManager manager, Metrics metrics, ExecutorService queryPool,
              HttpServer server) {
        this.handler = handler;
        this.manager = manager;
        this.metrics = metrics;
        this.queryPool = queryPool;
        this.server = server;
    }

    /** Handles one request; returns whether the connection may be kept open. */
    boolean handle(HttpConnection conn, HttpRequest req) throws IOException {
        metrics.httpRequest();
        boolean keep = req.keepAlive() && !server.isShuttingDown();
        List<String> p = req.path();
        int n = p.size();
        if (n == 1 && p.get(0).equals("health")) {
            if (!allow(conn, req, keep, "GET")) {
                return keep;
            }
            boolean down = server.isShuttingDown();
            sendJson(conn, down ? 503 : 200, down ? "{\"status\":\"shutting_down\"}" : "{\"status\":\"ok\"}",
                    Map.of(), keep);
            return keep;
        }
        if (n == 1 && p.get(0).equals("metrics")) {
            if (allow(conn, req, keep, "GET")) {
                String text = metrics.render(manager.running(), manager.queued(),
                        handler.engine().catalog().size());
                conn.writeResponse(200, "text/plain; version=0.0.4; charset=utf-8",
                        text.getBytes(StandardCharsets.UTF_8), Map.of(), keep);
            }
            return keep;
        }
        if (n < 2 || !p.get(0).equals("v1")) {
            return notFound(conn, req, keep);
        }
        String resource = p.get(1);
        switch (resource) {
            case "version", "capabilities" -> {
                if (n == 2 && allow(conn, req, keep, "GET")) {
                    Map<String, Object> m = new LinkedHashMap<>();
                    m.put("ok", true);
                    m.putAll(resource.equals("version") ? Version.versionFields() : Version.capabilityFields());
                    sendJson(conn, 200, JsonWriter.write(m), Map.of(), keep);
                    return keep;
                }
            }
            case "query" -> {
                if (n == 2 && allow(conn, req, keep, "POST")) {
                    Map<String, Object> body = jsonBody(conn, req, keep);
                    if (body != null) {
                        body.put("op", "query");
                        return runQuery(conn, body, keep);
                    }
                    return keep;
                }
                if (n == 3 && p.get(2).equals("stream") && allow(conn, req, keep, "POST")) {
                    Map<String, Object> body = jsonBody(conn, req, keep);
                    return body == null ? keep : stream(conn, body, keep);
                }
            }
            case "explain" -> {
                if (n == 2 && allow(conn, req, keep, "POST")) {
                    Map<String, Object> body = jsonBody(conn, req, keep);
                    if (body != null) {
                        body.put("op", "explain");
                        respond(conn, handler.handle(body, null), 200, keep);
                    }
                    return keep;
                }
            }
            case "request" -> {
                if (n == 2 && allow(conn, req, keep, "POST")) {
                    Object body = parseJson(conn, req, keep);
                    if (body == JsonFailure.INSTANCE) {
                        return keep;
                    }
                    if (body instanceof Map<?, ?> m && "query".equals(m.get("op"))) {
                        return runQuery(conn, body, keep);
                    }
                    respond(conn, handler.handle(body, null), 200, keep);
                    return keep;
                }
            }
            case "tables" -> {
                return tables(conn, req, keep);
            }
            case "queries" -> {
                if (n == 2 && allow(conn, req, keep, "GET")) {
                    Map<String, Object> m = new LinkedHashMap<>();
                    m.put("ok", true);
                    m.put("queries", manager.list());
                    sendJson(conn, 200, JsonWriter.write(m), Map.of(), keep);
                    return keep;
                }
                if (n == 3 && allow(conn, req, keep, "DELETE")) {
                    if (manager.cancel(p.get(2), "cancelled by request")) {
                        sendJson(conn, 200, "{\"ok\":true,\"cancelled\":true}", Map.of(), keep);
                    } else {
                        sendError(conn, PolyQueryException.of(ErrorCode.NOT_FOUND,
                                "no queued or running query with id '%s'", p.get(2)), keep);
                    }
                    return keep;
                }
            }
            default -> {
                return notFound(conn, req, keep);
            }
        }
        if (isKnownPath(p)) {
            return keep; // a 405 response has been sent by allow()
        }
        return notFound(conn, req, keep);
    }

    private static boolean isKnownPath(List<String> p) {
        return switch (p.size()) {
            case 2 -> List.of("version", "capabilities", "query", "explain", "request", "queries").contains(p.get(1));
            case 3 -> (p.get(1).equals("query") && p.get(2).equals("stream")) || p.get(1).equals("queries");
            default -> false;
        };
    }

    private boolean tables(HttpConnection conn, HttpRequest req, boolean keep) throws IOException {
        List<String> p = req.path();
        int n = p.size();
        if (n == 2) {
            if (allow(conn, req, keep, "GET")) {
                respond(conn, handler.handle(Map.of("op", "tables"), null), 200, keep);
            }
            return keep;
        }
        String table = p.get(2);
        if (n == 3) {
            if (!allow(conn, req, keep, "PUT", "DELETE")) {
                return keep;
            }
            if (req.method().equals("DELETE")) {
                respond(conn, handler.handle(Map.of("op", "drop", "table", table), null), 200, keep);
            } else {
                load(conn, req, table, keep);
            }
            return keep;
        }
        if (n == 4 && (p.get(3).equals("schema") || p.get(3).equals("stats"))) {
            if (allow(conn, req, keep, "GET")) {
                respond(conn, handler.handle(Map.of("op", p.get(3), "table", table), null), 200, keep);
            }
            return keep;
        }
        return notFound(conn, req, keep);
    }

    /** {@code PUT /v1/tables/{name}?format=…[&replace=…][&header=…][&delimiter=…]} with the raw data as body. */
    private void load(HttpConnection conn, HttpRequest req, String table, boolean keep) throws IOException {
        Map<String, Object> load = new LinkedHashMap<>();
        load.put("op", "load");
        load.put("table", table);
        load.put("format", req.query().getOrDefault("format", "csv"));
        Map<String, Object> options = new LinkedHashMap<>();
        try {
            load.put("replace", booleanParam(req, "replace", false));
            options.put("header", booleanParam(req, "header", true));
        } catch (PolyQueryException e) {
            sendError(conn, e, keep);
            return;
        }
        String delimiter = req.query().get("delimiter");
        if (delimiter != null) {
            options.put("delimiter", delimiter);
        }
        load.put("options", options);
        try {
            load.put("data", StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(req.body())).toString());
        } catch (CharacterCodingException e) {
            sendError(conn, new PolyQueryException(ErrorCode.INGEST_ERROR, "input is not valid UTF-8"), keep);
            return;
        }
        respond(conn, handler.handle(load, null), 201, keep);
    }

    private static boolean booleanParam(HttpRequest req, String name, boolean dflt) {
        String v = req.query().get(name);
        if (v == null) {
            return dflt;
        }
        return switch (v.toLowerCase(Locale.ROOT)) {
            case "true", "1", "yes", "" -> true;
            case "false", "0", "no" -> false;
            default -> throw PolyQueryException.of(ErrorCode.INVALID_REQUEST, "'%s' must be true or false", name);
        };
    }

    // ---------------------------------------------------------------- queries

    /** Runs a {@code query} request on the worker pool, cancelling it if the client disconnects. */
    private boolean runQuery(HttpConnection conn, Object request, boolean keep) throws IOException {
        QueryControl control = new QueryControl();
        Future<Response> f = queryPool.submit(() -> handler.handle(request, control));
        Response r;
        try {
            r = awaitWatching(conn, f, control);
        } catch (ExecutionException e) {
            r = null;
        }
        if (r == null) {
            return false;
        }
        Map<String, String> headers = r.queryId() == null ? Map.of() : Map.of(QUERY_ID_HEADER, r.queryId());
        conn.writeResponse(r.ok() ? 200 : r.error().httpStatus(), JSON, bytes(r.json()), headers, keep);
        return keep;
    }

    /** Waits for {@code f}; on a client disconnect cancels the query and returns null. */
    private static <T> T awaitWatching(HttpConnection conn, Future<T> f, QueryControl control)
            throws ExecutionException {
        while (true) {
            try {
                return f.get(QUERY_POLL_MS, TimeUnit.MILLISECONDS);
            } catch (TimeoutException e) {
                if (conn.peerClosed(1)) {
                    control.cancel("client disconnected");
                    try {
                        f.get(5, TimeUnit.SECONDS);
                    } catch (InterruptedException | TimeoutException | ExecutionException ignored) {
                        // the query has been cancelled; nobody is waiting for its result
                    }
                    return null;
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                control.cancel("server interrupted");
                return null;
            }
        }
    }

    private boolean stream(HttpConnection conn, Map<String, Object> body, boolean keep) throws IOException {
        QueryRequest q;
        try {
            q = QueryRequest.parse(body);
        } catch (PolyQueryException e) {
            sendError(conn, e, keep);
            return keep;
        }
        String queryId = q.queryId() != null ? q.queryId() : manager.newQueryId();
        return new QueryStream(q, queryId).serve(conn, handler.engine(), manager, queryPool, keep);
    }

    // ---------------------------------------------------------------- helpers

    /** Marker for a request body that could not be parsed (the error response has been sent). */
    private enum JsonFailure { INSTANCE }

    private static Object parseJson(HttpConnection conn, HttpRequest req, boolean keep) throws IOException {
        try {
            String text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(req.body())).toString();
            return JsonParser.parse(text);
        } catch (CharacterCodingException e) {
            sendError(conn, new PolyQueryException(ErrorCode.INVALID_REQUEST, "request body is not valid UTF-8"), keep);
        } catch (JsonException e) {
            sendError(conn, new PolyQueryException(ErrorCode.INVALID_REQUEST, "malformed JSON: " + e.getMessage()),
                    keep);
        } catch (StackOverflowError e) {
            sendError(conn, new PolyQueryException(ErrorCode.INVALID_REQUEST, "request nested too deeply"), keep);
        }
        return JsonFailure.INSTANCE;
    }

    /** The body as a JSON object (a mutable copy), or null after sending a 400 response. */
    private static Map<String, Object> jsonBody(HttpConnection conn, HttpRequest req, boolean keep)
            throws IOException {
        Object v = parseJson(conn, req, keep);
        if (v == JsonFailure.INSTANCE) {
            return null;
        }
        if (!(v instanceof Map<?, ?> m)) {
            sendError(conn, new PolyQueryException(ErrorCode.INVALID_REQUEST, "request body must be a JSON object"),
                    keep);
            return null;
        }
        Map<String, Object> copy = new LinkedHashMap<>();
        for (Map.Entry<?, ?> e : m.entrySet()) {
            copy.put((String) e.getKey(), e.getValue());
        }
        return copy;
    }

    /** Sends 405 unless the method is one of {@code methods}. */
    private static boolean allow(HttpConnection conn, HttpRequest req, boolean keep, String... methods)
            throws IOException {
        for (String m : methods) {
            if (m.equals(req.method())) {
                return true;
            }
        }
        PolyQueryException e = PolyQueryException.of(ErrorCode.INVALID_REQUEST, "method %s not allowed for %s",
                req.method(), req.target());
        conn.writeResponse(405, JSON, bytes(RequestHandler.error(null, e)),
                Map.of("Allow", String.join(", ", methods)), keep);
        return false;
    }

    private static boolean notFound(HttpConnection conn, HttpRequest req, boolean keep) throws IOException {
        sendError(conn, PolyQueryException.of(ErrorCode.NOT_FOUND, "no such endpoint: %s %s", req.method(),
                req.target()), keep);
        return keep;
    }

    private static void respond(HttpConnection conn, Response r, int successStatus, boolean keep) throws IOException {
        conn.writeResponse(r.ok() ? successStatus : r.error().httpStatus(), JSON, bytes(r.json()), Map.of(), keep);
    }

    static void sendError(HttpConnection conn, PolyQueryException e, boolean keep) throws IOException {
        sendJson(conn, e.code().httpStatus(), RequestHandler.error(null, e), Map.of(), keep);
    }

    static void sendJson(HttpConnection conn, int status, String json, Map<String, String> headers, boolean keep)
            throws IOException {
        conn.writeResponse(status, JSON, bytes(json), headers, keep);
    }

    private static byte[] bytes(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }
}
