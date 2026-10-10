package polyquery.server;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;
import java.util.function.ToLongFunction;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.QueryOptions;
import polyquery.exec.QueryControl;
import polyquery.protocol.Logger;
import polyquery.protocol.QueryRunner;

/**
 * Runs queries for the HTTP server: registers them under their query id (for listing and
 * cancellation), applies the server default timeout, admission control, metrics and
 * completion logs.
 */
final class QueryManager implements QueryRunner {
    enum State { QUEUED, RUNNING }

    /** A registered (queued or running) query. */
    static final class Ticket {
        final String id;
        final QueryControl control;
        final long startNanos = System.nanoTime();
        volatile State state = State.QUEUED;

        Ticket(String id, QueryControl control) {
            this.id = id;
            this.control = control;
        }
    }

    private final Map<String, Ticket> active = new ConcurrentHashMap<>();
    private final Admission admission;
    private final Metrics metrics;
    private final Logger log;
    private final long defaultTimeoutMs;

    QueryManager(ServerConfig config, Metrics metrics, Logger log) {
        this.admission = new Admission(config.workers(), config.queueDepth());
        this.metrics = metrics;
        this.log = log;
        this.defaultTimeoutMs = config.queryTimeoutMs();
    }

    @Override
    public String newQueryId() {
        return UUID.randomUUID().toString();
    }

    @Override
    public <T> T run(String queryId, QueryOptions opts, QueryControl control, Function<QueryControl, T> execution,
                     ToLongFunction<T> rowCount) {
        control.setTimeout(opts.timeoutMs() > 0 ? opts.timeoutMs() : defaultTimeoutMs);
        Ticket ticket = new Ticket(queryId, control);
        ErrorCode error = null;
        long rows = 0;
        boolean registered = false;
        try {
            if (active.putIfAbsent(queryId, ticket) != null) {
                throw PolyQueryException.of(ErrorCode.ALREADY_EXISTS, "query id '%s' is already in use", queryId);
            }
            registered = true;
            admission.acquire(control);
            try {
                ticket.state = State.RUNNING;
                T result = execution.apply(control);
                rows = rowCount.applyAsLong(result);
                return result;
            } finally {
                admission.release();
            }
        } catch (PolyQueryException e) {
            error = e.code();
            throw e;
        } catch (StackOverflowError | OutOfMemoryError e) {
            error = ErrorCode.RESOURCE_LIMIT;
            throw e;
        } catch (RuntimeException | Error e) {
            error = ErrorCode.INTERNAL_ERROR;
            throw e;
        } finally {
            if (registered) {
                active.remove(queryId, ticket);
            }
            finished(ticket, error, rows);
        }
    }

    private void finished(Ticket ticket, ErrorCode error, long rows) {
        long nanos = System.nanoTime() - ticket.startNanos;
        metrics.queryFinished(error, nanos);
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("query_id", ticket.id);
        fields.put("status", error == null ? "ok" : "error");
        if (error != null) {
            fields.put("error_code", error.name());
        }
        fields.put("duration_ms", nanos / 1_000_000L);
        fields.put("rows", rows);
        log.log(error == null || error.httpStatus() < 500 ? Logger.Level.INFO : Logger.Level.WARN,
                "query finished", fields);
    }

    /** Requests cancellation of a queued or running query; false if no such query is active. */
    boolean cancel(String queryId, String reason) {
        Ticket t = active.get(queryId);
        if (t == null) {
            return false;
        }
        t.control.cancel(reason);
        admission.wakeUp();
        return true;
    }

    void cancelAll(String reason) {
        for (Ticket t : active.values()) {
            t.control.cancel(reason);
        }
        admission.wakeUp();
    }

    /** Stops admitting new queries (graceful shutdown). */
    void close() {
        admission.close();
    }

    int activeCount() {
        return active.size();
    }

    int running() {
        return admission.running();
    }

    int queued() {
        return admission.queued();
    }

    /** The active queries, oldest first, as {@code /v1/queries} entries. */
    List<Object> list() {
        List<Ticket> tickets = new ArrayList<>(active.values());
        tickets.sort((a, b) -> Long.compare(a.startNanos, b.startNanos));
        long now = System.nanoTime();
        List<Object> out = new ArrayList<>();
        for (Ticket t : tickets) {
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("query_id", t.id);
            e.put("state", t.state == State.QUEUED ? "queued" : "running");
            e.put("elapsed_ms", (now - t.startNanos) / 1_000_000L);
            out.add(e);
        }
        return out;
    }
}
