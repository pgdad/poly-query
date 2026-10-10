package polyquery.engine;

import java.nio.file.Path;

/** Process-wide engine settings from the command line (protocol.md §2). */
public record EngineConfig(Path dataDir, boolean testFunctions, long maxQueryMemoryBytes, long maxIngestBytes,
                           long maxTableRows, long maxJoinRows, int threads) {
    public static final long DEFAULT_QUERY_MEMORY_MB = 4096;
    public static final long DEFAULT_INGEST_BYTES = 4L << 30;
    public static final long DEFAULT_TABLE_ROWS = 200_000_000L;
    public static final long DEFAULT_JOIN_ROWS = 100_000_000L;
}
