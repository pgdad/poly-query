//! Engine-wide error model (spec/errors/errors.md).

use std::fmt;

use crate::json::Json;

/// Stable error codes from `spec/errors/error-codes.json`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    ParseError,
    SemanticError,
    TypeError,
    NumericOverflow,
    DivisionByZero,
    ConversionError,
    InvalidArgument,
    SubqueryCardinality,
    InvalidRequest,
    IngestError,
    Unsupported,
    AccessDenied,
    NotFound,
    AlreadyExists,
    Cancelled,
    ResourceLimit,
    IoError,
    StorageCorrupt,
    StorageVersionUnsupported,
    InternalError,
    Overloaded,
    ShuttingDown,
    Timeout,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::ParseError => "PARSE_ERROR",
            ErrorCode::SemanticError => "SEMANTIC_ERROR",
            ErrorCode::TypeError => "TYPE_ERROR",
            ErrorCode::NumericOverflow => "NUMERIC_OVERFLOW",
            ErrorCode::DivisionByZero => "DIVISION_BY_ZERO",
            ErrorCode::ConversionError => "CONVERSION_ERROR",
            ErrorCode::InvalidArgument => "INVALID_ARGUMENT",
            ErrorCode::SubqueryCardinality => "SUBQUERY_CARDINALITY",
            ErrorCode::InvalidRequest => "INVALID_REQUEST",
            ErrorCode::IngestError => "INGEST_ERROR",
            ErrorCode::Unsupported => "UNSUPPORTED",
            ErrorCode::AccessDenied => "ACCESS_DENIED",
            ErrorCode::NotFound => "NOT_FOUND",
            ErrorCode::AlreadyExists => "ALREADY_EXISTS",
            ErrorCode::Cancelled => "CANCELLED",
            ErrorCode::ResourceLimit => "RESOURCE_LIMIT",
            ErrorCode::IoError => "IO_ERROR",
            ErrorCode::StorageCorrupt => "STORAGE_CORRUPT",
            ErrorCode::StorageVersionUnsupported => "STORAGE_VERSION_UNSUPPORTED",
            ErrorCode::InternalError => "INTERNAL_ERROR",
            ErrorCode::Overloaded => "OVERLOADED",
            ErrorCode::ShuttingDown => "SHUTTING_DOWN",
            ErrorCode::Timeout => "TIMEOUT",
        }
    }

    /// HTTP status for this code (protocol.md §7.1).
    pub fn http_status(self) -> u16 {
        match self {
            ErrorCode::AccessDenied => 403,
            ErrorCode::NotFound => 404,
            ErrorCode::AlreadyExists | ErrorCode::Cancelled => 409,
            ErrorCode::ResourceLimit => 413,
            ErrorCode::InternalError
            | ErrorCode::IoError
            | ErrorCode::StorageCorrupt
            | ErrorCode::StorageVersionUnsupported => 500,
            ErrorCode::Overloaded | ErrorCode::ShuttingDown => 503,
            ErrorCode::Timeout => 504,
            _ => 400,
        }
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// An error reported to the client: stable code, free-form message, optional details.
#[derive(Debug, Clone, PartialEq)]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
    pub details: Vec<(String, Json)>,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Error { code, message: message.into(), details: Vec::new() }
    }

    pub fn with_detail(mut self, key: &str, value: Json) -> Self {
        self.details.push((key.to_string(), value));
        self
    }

    pub fn parse(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::ParseError, message)
    }
    pub fn semantic(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::SemanticError, message)
    }
    pub fn type_error(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::TypeError, message)
    }
    pub fn overflow(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::NumericOverflow, message)
    }
    pub fn division_by_zero() -> Self {
        Error::new(ErrorCode::DivisionByZero, "division by zero")
    }
    pub fn conversion(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::ConversionError, message)
    }
    pub fn invalid_argument(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::InvalidArgument, message)
    }
    pub fn invalid_request(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::InvalidRequest, message)
    }
    pub fn ingest(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::IngestError, message)
    }
    pub fn unsupported(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::Unsupported, message)
    }
    pub fn not_found(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::NotFound, message)
    }
    pub fn resource_limit(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::ResourceLimit, message)
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Error::new(ErrorCode::InternalError, message)
    }

    /// The error object of the protocol (`{"code","message","details"?}`).
    pub fn to_json(&self) -> Json {
        let mut fields = vec![
            ("code".to_string(), Json::str(self.code.as_str())),
            ("message".to_string(), Json::str(&self.message)),
        ];
        if !self.details.is_empty() {
            fields.push(("details".to_string(), Json::Object(self.details.clone())));
        }
        Json::Object(fields)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}
