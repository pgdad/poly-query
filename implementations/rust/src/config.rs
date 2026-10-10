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
}

impl Default for Config {
    fn default() -> Self {
        Config {
            data_dir: PathBuf::from("."),
            test_functions: false,
            max_query_memory_mb: 4096,
            max_ingest_bytes: 4 * 1024 * 1024 * 1024,
            max_table_rows: 500_000_000,
            max_join_rows: 100_000_000,
            threads: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
            log_level: LogLevel::Info,
            native_kernels: None,
        }
    }
}

/// Options only meaningful for `serve` (accepted and validated by the CLI).
#[derive(Debug, Clone)]
pub struct ServeConfig {
    pub host: String,
    pub port: Option<u16>,
    pub workers: Option<usize>,
    pub queue_depth: usize,
    pub query_timeout_ms: u64,
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
            query_timeout_ms: 0,
            shutdown_grace_ms: 10_000,
            max_request_bytes: 1 << 30,
        }
    }
}
