//! Application errors and their exit statuses (spec/apps/pqledger.md §10).

use std::fmt;

/// What went wrong, which determines the exit status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    /// Command-line error (exit 1).
    Usage,
    /// Configuration, rules or budget file error (exit 2).
    Config,
    /// A bank file that cannot be imported (exit 4).
    ImportData,
    /// The engine rejected the SQL of `query` (exit 5).
    Query,
    /// No ledger, ledger already exists, unknown transaction id (exit 6).
    LedgerState,
    /// I/O and unexpected engine errors (exit 7).
    Other,
}

impl ErrorKind {
    pub fn exit_code(self) -> u8 {
        match self {
            ErrorKind::Usage => 1,
            ErrorKind::Config => 2,
            ErrorKind::ImportData => 4,
            ErrorKind::Query => 5,
            ErrorKind::LedgerState => 6,
            ErrorKind::Other => 7,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppError {
    pub kind: ErrorKind,
    pub message: String,
}

impl AppError {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        AppError {
            kind,
            message: message.into(),
        }
    }

    pub fn usage(message: impl Into<String>) -> Self {
        AppError::new(ErrorKind::Usage, message)
    }

    pub fn config(message: impl Into<String>) -> Self {
        AppError::new(ErrorKind::Config, message)
    }

    pub fn import(message: impl Into<String>) -> Self {
        AppError::new(ErrorKind::ImportData, message)
    }

    pub fn ledger(message: impl Into<String>) -> Self {
        AppError::new(ErrorKind::LedgerState, message)
    }

    pub fn other(message: impl Into<String>) -> Self {
        AppError::new(ErrorKind::Other, message)
    }
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for AppError {}

/// Unexpected engine errors (anything but the SQL of `query`) are exit 7.
impl From<polyquery::api::Error> for AppError {
    fn from(e: polyquery::api::Error) -> Self {
        AppError::other(format!("engine error: {e}"))
    }
}

pub type Result<T> = std::result::Result<T, AppError>;
