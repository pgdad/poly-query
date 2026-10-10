package polyquery.server;

import java.io.OutputStream;
import java.io.PrintStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest.BodyPublishers;
import java.net.http.HttpResponse;
import java.net.http.HttpResponse.BodyHandlers;
import java.nio.file.Path;
import java.time.Duration;
import java.util.concurrent.CompletableFuture;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.exec.QueryControl;
import polyquery.protocol.Logger;

/** Unit tests of the HTTP server layer: admission control, query control, metrics, endpoints. */
public final class ServerTest {
    private ServerTest() {
    }

    private static void check(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError(msg);
        }
    }

    private static ErrorCode failure(Runnable r) {
        try {
            r.run();
        } catch (PolyQueryException e) {
            return e.code();
        }
        return null;
    }

    public static void testQueryControl() {
        QueryControl c = QueryControl.withTimeout(0);
        c.check();
        check(c.remainingNanos() == Long.MAX_VALUE, "no deadline");
        c.cancel("test");
        check(failure(c::check) == ErrorCode.CANCELLED, "cancelled");
        QueryControl t = QueryControl.withTimeout(1);
        sleep(5);
        check(failure(t::check) == ErrorCode.TIMEOUT, "timed out");
    }

    public static void testAdmissionLimitsAndQueue() throws Exception {
        Admission a = new Admission(1, 1);
        a.acquire(new QueryControl());
        check(a.running() == 1, "one running");
        QueryControl queued = new QueryControl();
        CompletableFuture<Void> waiter = CompletableFuture.runAsync(() -> a.acquire(queued));
        sleep(50);
        check(a.queued() == 1 && !waiter.isDone(), "second query waits");
        check(failure(() -> a.acquire(new QueryControl())) == ErrorCode.OVERLOADED, "third rejected");
        a.release();
        waiter.get();
        check(a.running() == 1 && a.queued() == 0, "queued query admitted");
        QueryControl timed = QueryControl.withTimeout(30);
        check(failure(() -> a.acquire(timed)) == ErrorCode.TIMEOUT, "queued time counts toward the timeout");
        check(a.queued() == 0, "timed-out query left the queue");
        a.close();
        a.release();
        check(failure(() -> a.acquire(new QueryControl())) == ErrorCode.SHUTTING_DOWN, "closed");
    }

    public static void testMetricsRender() {
        Metrics m = new Metrics();
        m.queryFinished(null, 1_000_000);
        m.queryFinished(ErrorCode.OVERLOADED, 0);
        m.queryFinished(ErrorCode.TIMEOUT, 0);
        String text = m.render(2, 1, 3);
        for (String line : new String[] {"polyquery_queries_total{status=\"ok\"} 1",
                "polyquery_queries_total{status=\"error\"} 2", "polyquery_queries_in_flight 2",
                "polyquery_queries_queued 1", "polyquery_queries_rejected_total 1",
                "polyquery_queries_timeout_total 1", "polyquery_queries_cancelled_total 0",
                "polyquery_query_duration_seconds_count 3", "polyquery_tables 3"}) {
            check(text.contains(line + "\n"), "metrics lack " + line);
        }
    }

    public static void testEndpoints() throws Exception {
        EngineConfig cfg = new EngineConfig(Path.of(".").toAbsolutePath(), true, 1L << 30, 1L << 30, 1_000_000,
                1_000_000, 1);
        Logger log = new Logger(Logger.Level.OFF, new PrintStream(OutputStream.nullOutputStream()));
        HttpServer server = new HttpServer(new ServerConfig("127.0.0.1", 0, 2, 4, 0, 1000, 1 << 20),
                new Engine(cfg), log, 1 << 20);
        int port = server.start();
        HttpClient client = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build();
        try {
            HttpResponse<String> r = send(client, port, "PUT", "/v1/tables/t?format=csv", "a,b\n1,x\n2,y\n");
            check(r.statusCode() == 201 && r.body().contains("\"row_count\":2"), "load: " + r.body());
            r = send(client, port, "POST", "/v1/query", "{\"sql\":\"SELECT a FROM t ORDER BY a\",\"options\":"
                    + "{\"query_id\":\"x1\"}}");
            check(r.statusCode() == 200 && r.body().contains("\"rows\":[[1],[2]]"), "query: " + r.body());
            check("x1".equals(r.headers().firstValue("X-PolyQuery-Query-Id").orElse(null)), "query id header");
            r = send(client, port, "POST", "/v1/query", "{\"sql\":\"SELECT nope FROM t\"}");
            check(r.statusCode() == 400 && r.body().contains("SEMANTIC_ERROR"), "semantic error: " + r.body());
            r = send(client, port, "POST", "/v1/query/stream", "{\"sql\":\"SELECT b FROM t ORDER BY a\"}");
            check(r.statusCode() == 200 && r.body().startsWith("{\"type\":\"header\"")
                    && r.body().contains("{\"type\":\"rows\",\"rows\":[[\"x\"]")
                    && r.body().endsWith("{\"type\":\"end\",\"row_count\":2}\n"), "stream: " + r.body());
            r = send(client, port, "GET", "/v1/nope", null);
            check(r.statusCode() == 404 && r.body().contains("NOT_FOUND"), "unknown path");
            r = send(client, port, "DELETE", "/v1/query", null);
            check(r.statusCode() == 405, "wrong method");
            r = send(client, port, "DELETE", "/v1/queries/none", null);
            check(r.statusCode() == 404, "cancel unknown query");
            r = send(client, port, "POST", "/v1/request", "{\"op\":\"query\",\"sql\":\"SELECT PQ_SLEEP(500)\","
                    + "\"options\":{\"timeout_ms\":20}}");
            check(r.statusCode() == 504 && r.body().contains("TIMEOUT"), "timeout: " + r.body());
            r = send(client, port, "GET", "/metrics", null);
            check(r.statusCode() == 200 && r.body().contains("polyquery_queries_timeout_total 1"), "metrics");
            server.shutdown();
            r = send(client, port, "GET", "/health", null);
            check(false, "server still accepting connections after shutdown");
        } catch (java.io.IOException expected) {
            // connection refused after shutdown
        } finally {
            server.shutdown();
        }
    }

    private static HttpResponse<String> send(HttpClient client, int port, String method, String path, String body)
            throws Exception {
        var builder = java.net.http.HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + path))
                .timeout(Duration.ofSeconds(10))
                .method(method, body == null ? BodyPublishers.noBody() : BodyPublishers.ofString(body));
        return client.send(builder.build(), BodyHandlers.ofString());
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
