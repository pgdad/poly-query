//! Engine configuration from command-line options (protocol.md §2).

use std::path::PathBuf;

use crate::log::LogLevel;

#[derive(Debug, Clone)]
pub struct Config {
    /// Root for all request file paths.
    pub data_dir: PathBuf,
    /// Enables `PQ_SLEEP` and the `sleep` op.
    pub test_functions: bool,
    pub max_query_memory_mb: u64,
    pub max_ingest_bytes: u64,
    pub max_table_rows: u64,
    pub max_join_rows: u64,
    pub threads: usize,
    pub log_level: LogLevel,
    pub native_kernels: Option<PathBuf>,
    /// Default query timeout when a query sets none (`--query-timeout-ms`,
    /// 0 = none).
    pub query_timeout_ms: u64,
}

/// Upper bound of the default `--threads` (the CPU count otherwise).
pub const DEFAULT_MAX_THREADS: usize = 16;

impl Default for Config {
    fn default() -> Self {
        Config {
            data_dir: PathBuf::from("."),
            test_functions: false,
            max_query_memory_mb: 4096,
            max_ingest_bytes: 4 * 1024 * 1024 * 1024,
            max_table_rows: 500_000_000,
            max_join_rows: 100_000_000,
            // More workers per query rarely pay off (thread start-up and
            // merging of partial results grow with the count) and would
            // oversubscribe the CPUs under concurrent queries.
            threads: std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(1)
                .min(DEFAULT_MAX_THREADS),
            log_level: LogLevel::Info,
            native_kernels: None,
            query_timeout_ms: 0,
        }
    }
}

/// Options only meaningful for `serve` (accepted in every mode; ignored
/// outside `serve`).
#[derive(Debug, Clone)]
pub struct ServeConfig {
    pub host: String,
    pub port: Option<u16>,
    pub workers: Option<usize>,
    pub queue_depth: usize,
    pub shutdown_grace_ms: u64,
    pub max_request_bytes: u64,
}

impl Default for ServeConfig {
    fn default() -> Self {
        ServeConfig {
            host: "127.0.0.1".to_string(),
            port: None,
            workers: None,
            queue_depth: 64,
            shutdown_grace_ms: 10_000,
            max_request_bytes: 1 << 30,
        }
    }
}
