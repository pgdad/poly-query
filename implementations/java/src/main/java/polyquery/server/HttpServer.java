package polyquery.server;

import java.io.Closeable;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import polyquery.engine.Engine;
import polyquery.protocol.Logger;
import polyquery.protocol.RequestHandler;

/**
 * The {@code serve} HTTP/1.1 server (protocol.md §7, concurrency.md). One platform thread per
 * connection plus a pool of query threads (both with large stacks for deeply nested SQL);
 * admission control limits how many queries execute at once. {@link #shutdown()} implements
 * the graceful shutdown sequence of concurrency.md §5.
 */
public final class HttpServer {
    private static final int IDLE_TIMEOUT_MS = 300_000;
    private static final long CANCEL_DRAIN_MS = 3_000;

    private final ServerConfig config;
    private final Logger log;
    private final QueryManager manager;
    private final ApiRouter router;
    private final ExecutorService connectionPool;
    private final ExecutorService queryPool;
    private final Set<HttpConnection> connections = ConcurrentHashMap.newKeySet();
    private final AtomicInteger activeExchanges = new AtomicInteger();
    private ServerSocket serverSocket;
    private volatile boolean shuttingDown;

    public HttpServer(ServerConfig config, Engine engine, Logger log, long threadStackSize) {
        this.config = config;
        this.log = log;
        Metrics metrics = new Metrics();
        this.manager = new QueryManager(config, metrics, log);
        this.connectionPool = Executors.newCachedThreadPool(threads("pq-conn-", threadStackSize));
        this.queryPool = Executors.newCachedThreadPool(threads("pq-query-", threadStackSize));
        RequestHandler handler = new RequestHandler(engine, log, manager);
        this.router = new ApiRouter(handler, manager, metrics, queryPool, this);
    }

    private static ThreadFactory threads(String prefix, long stackSize) {
        AtomicInteger n = new AtomicInteger();
        return r -> {
            Thread t = new Thread(null, r, prefix + n.incrementAndGet(), stackSize);
            t.setDaemon(true);
            return t;
        };
    }

    /** Binds the listening socket and starts accepting connections; returns the actual port. */
    public int start() throws IOException {
        serverSocket = new ServerSocket();
        serverSocket.setReuseAddress(true);
        serverSocket.bind(new InetSocketAddress(config.host(), config.port()), 1024);
        Thread acceptor = new Thread(this::acceptLoop, "pq-accept");
        acceptor.setDaemon(true);
        acceptor.start();
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("host", config.host());
        fields.put("port", (long) serverSocket.getLocalPort());
        fields.put("workers", (long) config.workers());
        fields.put("queue_depth", (long) config.queueDepth());
        log.info("server listening", fields);
        return serverSocket.getLocalPort();
    }

    boolean isShuttingDown() {
        return shuttingDown;
    }

    private void acceptLoop() {
        while (!serverSocket.isClosed()) {
            try {
                Socket socket = serverSocket.accept();
                connectionPool.execute(() -> serve(socket));
            } catch (IOException e) {
                if (!serverSocket.isClosed()) {
                    log.warn("accept failed: " + e.getMessage());
                }
            }
        }
    }

    private void serve(Socket socket) {
        HttpConnection conn;
        try {
            conn = new HttpConnection(socket);
        } catch (IOException e) {
            closeQuietly(socket);
            return;
        }
        connections.add(conn);
        try {
            while (true) {
                HttpRequest req;
                try {
                    req = conn.readRequest(IDLE_TIMEOUT_MS, config.maxRequestBytes());
                } catch (HttpConnection.BadRequest e) {
                    activeExchanges.incrementAndGet();
                    try {
                        ApiRouter.sendError(conn, e.error, false);
                    } finally {
                        activeExchanges.decrementAndGet();
                    }
                    conn.closeGracefully();
                    return;
                }
                if (req == null) {
                    return;
                }
                activeExchanges.incrementAndGet();
                boolean keep;
                try {
                    keep = router.handle(conn, req);
                } finally {
                    activeExchanges.decrementAndGet();
                }
                if (!keep) {
                    return;
                }
            }
        } catch (IOException | RuntimeException e) {
            log.debug("connection closed: " + e);
        } finally {
            connections.remove(conn);
            conn.close();
        }
    }

    /**
     * Graceful shutdown: stop accepting connections and new queries, let running and queued
     * queries finish within the grace period, cancel the rest, then close all connections.
     */
    public void shutdown() {
        shuttingDown = true;
        log.info("shutdown started", Map.of("grace_ms", config.shutdownGraceMs()));
        manager.close();
        closeQuietly(serverSocket);
        boolean drained = waitUntil(() -> activeExchanges.get() == 0 && manager.activeCount() == 0,
                config.shutdownGraceMs());
        if (!drained) {
            log.warn("grace period expired; cancelling " + manager.activeCount() + " queries");
            manager.cancelAll("server shutting down");
            waitUntil(() -> activeExchanges.get() == 0, CANCEL_DRAIN_MS);
        }
        for (HttpConnection c : connections) {
            c.close();
        }
        log.info("server stopped");
    }

    private static boolean waitUntil(BooleanSupplier condition, long timeoutMs) {
        long deadline = System.nanoTime() + timeoutMs * 1_000_000L;
        while (!condition.getAsBoolean()) {
            if (System.nanoTime() - deadline >= 0) {
                return false;
            }
            try {
                Thread.sleep(5);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return condition.getAsBoolean();
            }
        }
        return true;
    }

    private static void closeQuietly(Closeable c) {
        try {
            c.close();
        } catch (IOException e) {
            // ignore
        }
    }
}
