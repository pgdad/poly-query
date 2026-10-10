package polyquery.server;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.exec.QueryControl;
import polyquery.exec.ResultSink;
import polyquery.json.JsonWriter;
import polyquery.protocol.QueryRequest;
import polyquery.protocol.RequestHandler;
import polyquery.protocol.ResultWriter;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;

/**
 * {@code POST /v1/query/stream} (protocol.md §7.2). The query runs on a worker thread that
 * serializes rows into NDJSON batches; the connection thread writes them as HTTP chunks. At most
 * {@link #MAX_PENDING_BATCHES} batches may be pending, so a client that stops reading blocks
 * query execution (backpressure). The header line is deferred until the first batch (or the
 * end), so errors raised before any row is produced get a normal error response.
 */
final class QueryStream {
    static final int MAX_PENDING_BATCHES = 16;
    private static final int BATCH_ROWS = 4096;
    private static final int BATCH_BYTES = 1 << 20;
    private static final long BATCH_MAX_DELAY_NANOS = 50_000_000L;
    private static final int POLL_MS = 5;

    /** Messages from the producing worker to the connection thread. */
    private sealed interface Event {
    }

    private record Columns(List<ColumnSchema> columns) implements Event {
    }

    private record Rows(byte[] line) implements Event {
    }

    private record End(long rowCount) implements Event {
    }

    private record Failed(PolyQueryException error) implements Event {
    }

    private final LinkedBlockingQueue<Event> events = new LinkedBlockingQueue<>();
    private final Semaphore credits = new Semaphore(MAX_PENDING_BATCHES);
    private final QueryControl control = new QueryControl();
    private final QueryRequest request;
    private final String queryId;

    QueryStream(QueryRequest request, String queryId) {
        this.request = request;
        this.queryId = queryId;
    }

    /** Runs the query on {@code pool} and streams its result; returns whether to keep the connection. */
    boolean serve(HttpConnection conn, Engine engine, QueryManager manager, ExecutorService pool, boolean keepAlive)
            throws IOException {
        Future<?> producer = pool.submit(() -> produce(engine, manager));
        boolean headerSent = false;
        List<ColumnSchema> columns = List.of();
        try {
            while (true) {
                Event ev = events.poll(POLL_MS, TimeUnit.MILLISECONDS);
                if (ev == null) {
                    if (conn.peerClosed(1)) {
                        abandon(producer, "client disconnected");
                        return false;
                    }
                    continue;
                }
                switch (ev) {
                    case Columns c -> columns = c.columns();
                    case Rows r -> {
                        if (!headerSent) {
                            sendHeader(conn, columns, keepAlive);
                            headerSent = true;
                        }
                        conn.writeChunk(r.line());
                        credits.release();
                    }
                    case End e -> {
                        if (!headerSent) {
                            sendHeader(conn, columns, keepAlive);
                        }
                        conn.writeChunk(line("{\"type\":\"end\",\"row_count\":" + e.rowCount() + "}"));
                        conn.endChunks();
                        return keepAlive;
                    }
                    case Failed f -> {
                        if (!headerSent) {
                            ApiRouter.sendJson(conn, f.error().code().httpStatus(),
                                    RequestHandler.error(null, f.error()), queryIdHeader(), keepAlive);
                            return keepAlive;
                        }
                        StringBuilder sb = new StringBuilder("{\"type\":\"error\",\"error\":");
                        Map<String, Object> err = new LinkedHashMap<>();
                        err.put("code", f.error().code().name());
                        err.put("message", f.error().getMessage());
                        if (!f.error().details().isEmpty()) {
                            err.put("details", f.error().details());
                        }
                        JsonWriter.write(sb, err);
                        conn.writeChunk(line(sb.append('}').toString()));
                        conn.endChunks();
                        return keepAlive;
                    }
                }
            }
        } catch (IOException e) {
            abandon(producer, "client disconnected");
            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            abandon(producer, "server interrupted");
            return false;
        }
    }

    private Map<String, String> queryIdHeader() {
        return Map.of(ApiRouter.QUERY_ID_HEADER, queryId);
    }

    private void sendHeader(HttpConnection conn, List<ColumnSchema> columns, boolean keepAlive) throws IOException {
        conn.startChunked(200, "application/x-ndjson", queryIdHeader(), keepAlive);
        StringBuilder sb = new StringBuilder("{\"type\":\"header\",\"query_id\":");
        JsonWriter.writeString(sb, queryId);
        sb.append(",\"columns\":");
        ResultWriter.writeColumns(sb, columns);
        conn.writeChunk(line(sb.append('}').toString()));
    }

    private static byte[] line(String json) {
        return (json + "\n").getBytes(StandardCharsets.UTF_8);
    }

    /** Cancels the query and waits for the producer to stop. */
    private void abandon(Future<?> producer, String reason) {
        control.cancel(reason);
        credits.release(MAX_PENDING_BATCHES);
        try {
            producer.get(5, TimeUnit.SECONDS);
        } catch (Exception e) {
            // the producer reports its own failure through the (now unread) event queue
        }
    }

    // ---------------------------------------------------------------- producer (worker thread)

    private void produce(Engine engine, QueryManager manager) {
        BatchSink sink = new BatchSink();
        try {
            long n = manager.run(queryId, request.options(), control, ctl -> {
                long count = engine.stream(request.sql(), request.options(), ctl, sink);
                sink.flush();
                return count;
            }, c -> c);
            events.add(new End(n));
        } catch (PolyQueryException e) {
            events.add(new Failed(e));
        } catch (StackOverflowError e) {
            events.add(new Failed(new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "statement too deeply nested")));
        } catch (OutOfMemoryError e) {
            events.add(new Failed(new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "out of memory")));
        } catch (RuntimeException e) {
            events.add(new Failed(new PolyQueryException(ErrorCode.INTERNAL_ERROR,
                    "internal error: " + e.getClass().getSimpleName())));
        }
    }

    /** Serializes rows into {@code {"type":"rows",…}} lines of bounded size. */
    private final class BatchSink implements ResultSink {
        private DataType[] types = new DataType[0];
        private final StringBuilder batch = new StringBuilder();
        private int rows;
        private long batchStart;

        @Override
        public void columns(List<ColumnSchema> columns) {
            types = new DataType[columns.size()];
            for (int i = 0; i < types.length; i++) {
                types[i] = columns.get(i).type();
            }
            events.add(new Columns(columns));
        }

        @Override
        public void row(Object[] row) {
            if (request.options().countOnly()) {
                return;
            }
            if (rows == 0) {
                batch.setLength(0);
                batch.append("{\"type\":\"rows\",\"rows\":[");
                batchStart = System.nanoTime();
            } else {
                batch.append(',');
            }
            batch.append('[');
            for (int c = 0; c < types.length; c++) {
                if (c > 0) {
                    batch.append(',');
                }
                ResultWriter.writeValue(batch, row[c], types[c]);
            }
            batch.append(']');
            rows++;
            if (rows >= BATCH_ROWS || batch.length() >= BATCH_BYTES
                    || System.nanoTime() - batchStart >= BATCH_MAX_DELAY_NANOS) {
                flush();
            }
        }

        /** Hands the current batch to the connection thread, waiting for a free slot (backpressure). */
        void flush() {
            if (rows == 0) {
                return;
            }
            try {
                while (!credits.tryAcquire(POLL_MS, TimeUnit.MILLISECONDS)) {
                    control.check();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new PolyQueryException(ErrorCode.CANCELLED, "query was interrupted");
            }
            control.check();
            events.add(new Rows(line(batch.append("]}").toString())));
            rows = 0;
        }
    }
}
