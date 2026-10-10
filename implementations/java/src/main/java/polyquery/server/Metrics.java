package polyquery.server;

import java.util.Locale;
import java.util.concurrent.atomic.LongAdder;
import polyquery.common.ErrorCode;

/** Server counters, rendered in the Prometheus text exposition format 0.0.4 (protocol.md §7.3). */
final class Metrics {
    private final long startNanos = System.nanoTime();
    private final LongAdder ok = new LongAdder();
    private final LongAdder failed = new LongAdder();
    private final LongAdder rejected = new LongAdder();
    private final LongAdder cancelled = new LongAdder();
    private final LongAdder timedOut = new LongAdder();
    private final LongAdder durationNanos = new LongAdder();
    private final LongAdder durationCount = new LongAdder();
    private final LongAdder httpRequests = new LongAdder();

    /** Records a finished query; {@code error} is null on success. */
    void queryFinished(ErrorCode error, long nanos) {
        if (error == null) {
            ok.increment();
        } else {
            failed.increment();
            switch (error) {
                case OVERLOADED -> rejected.increment();
                case CANCELLED -> cancelled.increment();
                case TIMEOUT -> timedOut.increment();
                default -> {
                }
            }
        }
        durationNanos.add(nanos);
        durationCount.increment();
    }

    void httpRequest() {
        httpRequests.increment();
    }

    String render(int inFlight, int queued, int tables) {
        StringBuilder sb = new StringBuilder(1024);
        family(sb, "polyquery_queries_total", "counter", "Finished queries by status.");
        sb.append("polyquery_queries_total{status=\"ok\"} ").append(ok.sum()).append('\n');
        sb.append("polyquery_queries_total{status=\"error\"} ").append(failed.sum()).append('\n');
        sample(sb, "polyquery_queries_in_flight", "gauge", "Queries currently executing.", inFlight);
        sample(sb, "polyquery_queries_queued", "gauge", "Queries waiting for a worker.", queued);
        sample(sb, "polyquery_queries_rejected_total", "counter", "Queries rejected with OVERLOADED.",
                rejected.sum());
        sample(sb, "polyquery_queries_cancelled_total", "counter", "Queries that ended CANCELLED.",
                cancelled.sum());
        sample(sb, "polyquery_queries_timeout_total", "counter", "Queries that ended with TIMEOUT.",
                timedOut.sum());
        family(sb, "polyquery_query_duration_seconds", "summary", "Query duration including queueing.");
        sb.append("polyquery_query_duration_seconds_sum ").append(seconds(durationNanos.sum())).append('\n');
        sb.append("polyquery_query_duration_seconds_count ").append(durationCount.sum()).append('\n');
        sample(sb, "polyquery_tables", "gauge", "Tables in the catalog.", tables);
        family(sb, "polyquery_uptime_seconds", "gauge", "Seconds since the server started.");
        sb.append("polyquery_uptime_seconds ").append(seconds(System.nanoTime() - startNanos)).append('\n');
        sample(sb, "polyquery_http_requests_total", "counter", "HTTP requests received.", httpRequests.sum());
        return sb.toString();
    }

    private static void family(StringBuilder sb, String name, String type, String help) {
        sb.append("# HELP ").append(name).append(' ').append(help).append('\n');
        sb.append("# TYPE ").append(name).append(' ').append(type).append('\n');
    }

    private static void sample(StringBuilder sb, String name, String type, String help, long value) {
        family(sb, name, type, help);
        sb.append(name).append(' ').append(value).append('\n');
    }

    private static String seconds(long nanos) {
        return String.format(Locale.ROOT, "%.6f", nanos / 1e9);
    }
}
