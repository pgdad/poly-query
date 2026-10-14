//! Errors of the embedding API.

use std::fmt;

pub use crate::error::ErrorCode;

/// An engine error: one of the specification's error codes
/// (`spec/errors/errors.md`) and a human-readable message.
///
/// `Display` writes `CODE: message`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    code: ErrorCode,
    message: String,
}

impl Error {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Error {
            code,
            message: message.into(),
        }
    }

    /// The error code, e.g. [`ErrorCode::ParseError`].
    pub fn code(&self) -> ErrorCode {
        self.code
    }

    /// The code as the specification spells it, e.g. `PARSE_ERROR`.
    pub fn code_str(&self) -> &'static str {
        self.code.as_str()
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

impl From<crate::error::Error> for Error {
    fn from(e: crate::error::Error) -> Self {
        Error::new(e.code, e.message)
    }
}

/// Result type of the embedding API.
pub type Result<T> = std::result::Result<T, Error>;
