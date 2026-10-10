package polyquery.server;

/**
 * Options of {@code serve} (protocol.md §2).
 *
 * @param port            0 = pick a free port
 * @param workers         maximum number of concurrently executing queries
 * @param queueDepth      maximum number of queries waiting for a worker
 * @param queryTimeoutMs  default query timeout, 0 = none
 * @param shutdownGraceMs how long running and queued queries may continue after SIGTERM
 * @param maxRequestBytes maximum request body size
 */
public record ServerConfig(String host, int port, int workers, int queueDepth, long queryTimeoutMs,
                           long shutdownGraceMs, long maxRequestBytes) {
    public static final int DEFAULT_QUEUE_DEPTH = 64;
    public static final long DEFAULT_SHUTDOWN_GRACE_MS = 10_000;
    public static final long DEFAULT_MAX_REQUEST_BYTES = 1L << 30;
}
