package polyquery.api;

import java.nio.file.Path;
import java.util.Objects;

/**
 * Configuration of a {@link Database} instance: the settings of the {@code polyquery} command
 * line ({@code spec/protocol/protocol.md} §2). Build one with {@link #builder(Path)}:
 *
 * <pre>{@code
 * DatabaseConfig config = DatabaseConfig.builder(Path.of("data"))
 *         .maxQueryMemoryMb(512)
 *         .threads(4)
 *         .build();
 * }</pre>
 *
 * @param dataDir          the data directory (as {@code --data-dir}); every file path given to
 *                         the instance is resolved inside it, paths leaving it are rejected
 *                         with {@code ACCESS_DENIED}
 * @param maxQueryMemoryMb per-query memory limit in MiB (as {@code --max-query-memory-mb})
 * @param threads          default worker threads per query (as {@code --threads})
 * @param maxIngestBytes   largest input of one load (as {@code --max-ingest-bytes})
 * @param maxTableRows     largest table (as {@code --max-table-rows})
 * @param maxJoinRows      largest join result (as {@code --max-join-rows})
 * @param testFunctions    enable the test-only functions (as {@code --enable-test-functions})
 */
public record DatabaseConfig(Path dataDir, long maxQueryMemoryMb, int threads, long maxIngestBytes,
                             long maxTableRows, long maxJoinRows, boolean testFunctions) {
    /** Default per-query memory limit in MiB. */
    public static final long DEFAULT_QUERY_MEMORY_MB = 4096;
    /** Default largest input of one load. */
    public static final long DEFAULT_INGEST_BYTES = 4L << 30;
    /** Default largest table. */
    public static final long DEFAULT_TABLE_ROWS = 200_000_000L;
    /** Default largest join result. */
    public static final long DEFAULT_JOIN_ROWS = 100_000_000L;

    public DatabaseConfig {
        Objects.requireNonNull(dataDir, "dataDir");
        if (maxQueryMemoryMb < 1) {
            throw new IllegalArgumentException("maxQueryMemoryMb must be >= 1");
        }
        if (threads < 1) {
            throw new IllegalArgumentException("threads must be >= 1");
        }
        if (maxIngestBytes < 0 || maxTableRows < 0 || maxJoinRows < 0) {
            throw new IllegalArgumentException("limits must be >= 0");
        }
    }

    /** A builder with the engine's defaults (threads: the number of available processors). */
    public static Builder builder(Path dataDir) {
        return new Builder(dataDir);
    }

    /** The default configuration for {@code dataDir}. */
    public static DatabaseConfig of(Path dataDir) {
        return builder(dataDir).build();
    }

    /** Builder of {@link DatabaseConfig}; every setter is optional. */
    public static final class Builder {
        private final Path dataDir;
        private long maxQueryMemoryMb = DEFAULT_QUERY_MEMORY_MB;
        private int threads = Runtime.getRuntime().availableProcessors();
        private long maxIngestBytes = DEFAULT_INGEST_BYTES;
        private long maxTableRows = DEFAULT_TABLE_ROWS;
        private long maxJoinRows = DEFAULT_JOIN_ROWS;
        private boolean testFunctions;

        private Builder(Path dataDir) {
            this.dataDir = Objects.requireNonNull(dataDir, "dataDir");
        }

        public Builder maxQueryMemoryMb(long mb) {
            this.maxQueryMemoryMb = mb;
            return this;
        }

        public Builder threads(int n) {
            this.threads = n;
            return this;
        }

        public Builder maxIngestBytes(long bytes) {
            this.maxIngestBytes = bytes;
            return this;
        }

        public Builder maxTableRows(long rows) {
            this.maxTableRows = rows;
            return this;
        }

        public Builder maxJoinRows(long rows) {
            this.maxJoinRows = rows;
            return this;
        }

        public Builder testFunctions(boolean enabled) {
            this.testFunctions = enabled;
            return this;
        }

        /** @throws IllegalArgumentException for an out-of-range setting */
        public DatabaseConfig build() {
            return new DatabaseConfig(dataDir, maxQueryMemoryMb, threads, maxIngestBytes, maxTableRows, maxJoinRows,
                    testFunctions);
        }
    }
}
