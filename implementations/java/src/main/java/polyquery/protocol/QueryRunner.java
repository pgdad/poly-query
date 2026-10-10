package polyquery.protocol;

import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;
import java.util.function.ToLongFunction;
import polyquery.engine.QueryOptions;
import polyquery.exec.QueryControl;

/**
 * Policy for running queries. The session/exec front-ends run them directly; the HTTP server
 * adds a query registry, admission control (worker limit, bounded queue), server-wide default
 * timeout, metrics and completion logs.
 */
public interface QueryRunner {
    /**
     * Runs {@code execution} under {@code control} (whose deadline the runner sets) and returns
     * its result; failures propagate as exceptions.
     *
     * @param queryId  client-assigned or generated id
     * @param rowCount extracts the row count of a result (for logs and metrics)
     */
    <T> T run(String queryId, QueryOptions opts, QueryControl control, Function<QueryControl, T> execution,
              ToLongFunction<T> rowCount);

    /** A fresh id for a query that has none. */
    String newQueryId();

    /** Runs queries in the calling thread, honouring only {@code options.timeout_ms}. */
    QueryRunner DIRECT = new QueryRunner() {
        private final AtomicLong ids = new AtomicLong();

        @Override
        public <T> T run(String queryId, QueryOptions opts, QueryControl control,
                         Function<QueryControl, T> execution, ToLongFunction<T> rowCount) {
            control.setTimeout(opts.timeoutMs());
            return execution.apply(control);
        }

        @Override
        public String newQueryId() {
            return "q" + ids.incrementAndGet();
        }
    };
}
