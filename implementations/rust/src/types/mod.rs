//! Data types, values and conversions (spec/data-types/types.md).

pub mod cast;
pub mod datetime;
pub mod decimal;
pub mod float;
pub mod value;

use std::fmt;

pub use value::Value;

use crate::error::{Error, Result};

/// Maximum DECIMAL precision.
pub const MAX_DECIMAL_PRECISION: u8 = 18;

/// A logical SQL type. `Null` is the type of the bare `NULL` literal; it is
/// coercible to every type and reported as `STRING` in result metadata.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DataType {
    Null,
    Boolean,
    Int64,
    Float64,
    Decimal { precision: u8, scale: u8 },
    String,
    Date,
    Timestamp,
}

impl DataType {
    pub fn decimal(precision: u8, scale: u8) -> DataType {
        DataType::Decimal { precision, scale }
    }

    pub fn is_numeric(self) -> bool {
        matches!(
            self,
            DataType::Int64 | DataType::Float64 | DataType::Decimal { .. }
        )
    }

    pub fn is_temporal(self) -> bool {
        matches!(self, DataType::Date | DataType::Timestamp)
    }

    /// The type reported in result metadata (the null type is reported as STRING).
    pub fn result_type(self) -> DataType {
        if self == DataType::Null {
            DataType::String
        } else {
            self
        }
    }

    /// Canonical type name (`DECIMAL(18,2)`, `INT64`, ...).
    pub fn name(self) -> String {
        self.to_string()
    }

    /// Resolves a SQL/schema type name with optional numeric parameters,
    /// applying the aliases of types.md §1. Errors are SEMANTIC_ERROR.
    pub fn from_name(name: &str, params: &[u64]) -> Result<DataType> {
        let upper = name.to_ascii_uppercase();
        let simple = |t: DataType| {
            if params.is_empty() {
                Ok(t)
            } else {
                Err(Error::semantic(format!(
                    "type {upper} does not take parameters"
                )))
            }
        };
        match upper.as_str() {
            "BOOLEAN" | "BOOL" => simple(DataType::Boolean),
            "INT64" | "INT" | "INTEGER" | "BIGINT" => simple(DataType::Int64),
            "FLOAT64" | "DOUBLE" | "FLOAT" | "REAL" => simple(DataType::Float64),
            "STRING" | "VARCHAR" | "TEXT" => simple(DataType::String),
            "DATE" => simple(DataType::Date),
            "TIMESTAMP" => simple(DataType::Timestamp),
            "DECIMAL" | "NUMERIC" => {
                let (p, s) = match params {
                    [] => (18, 0),
                    [p] => (*p, 0),
                    [p, s] => (*p, *s),
                    _ => return Err(Error::semantic("DECIMAL takes at most two parameters")),
                };
                if p < 1 || p > MAX_DECIMAL_PRECISION as u64 || s > p {
                    return Err(Error::semantic(format!(
                        "invalid DECIMAL parameters ({p},{s})"
                    )));
                }
                Ok(DataType::decimal(p as u8, s as u8))
            }
            _ => Err(Error::semantic(format!("unknown type '{name}'"))),
        }
    }

    /// Parses a textual type such as `"DECIMAL(10, 2)"` or `"bigint"` (used by
    /// explicit schemas). Errors are SEMANTIC_ERROR.
    pub fn parse(text: &str) -> Result<DataType> {
        let text = text.trim();
        let (name, params) = match text.find('(') {
            None => (text, Vec::new()),
            Some(open) => {
                let rest = text[open + 1..].trim_end();
                let inner = rest
                    .strip_suffix(')')
                    .ok_or_else(|| Error::semantic(format!("invalid type '{text}'")))?;
                let mut params = Vec::new();
                for part in inner.split(',') {
                    let part = part.trim();
                    if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
                        return Err(Error::semantic(format!("invalid type '{text}'")));
                    }
                    params.push(
                        part.parse::<u64>()
                            .map_err(|_| Error::semantic(format!("invalid type '{text}'")))?,
                    );
                }
                (text[..open].trim(), params)
            }
        };
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            return Err(Error::semantic(format!("invalid type '{text}'")));
        }
        DataType::from_name(name, &params)
    }
}

impl fmt::Display for DataType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DataType::Null | DataType::String => f.write_str("STRING"),
            DataType::Boolean => f.write_str("BOOLEAN"),
            DataType::Int64 => f.write_str("INT64"),
            DataType::Float64 => f.write_str("FLOAT64"),
            DataType::Decimal { precision, scale } => write!(f, "DECIMAL({precision},{scale})"),
            DataType::Date => f.write_str("DATE"),
            DataType::Timestamp => f.write_str("TIMESTAMP"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases() {
        assert_eq!(DataType::parse("bigint").unwrap(), DataType::Int64);
        assert_eq!(
            DataType::parse("NUMERIC(4,2)").unwrap(),
            DataType::decimal(4, 2)
        );
        assert_eq!(
            DataType::parse("decimal").unwrap(),
            DataType::decimal(18, 0)
        );
        assert_eq!(
            DataType::parse("DECIMAL(7)").unwrap(),
            DataType::decimal(7, 0)
        );
        assert_eq!(
            DataType::parse("Decimal( 10 , 2 )").unwrap().to_string(),
            "DECIMAL(10,2)"
        );
        assert!(DataType::parse("DECIMAL(19,2)").is_err());
        assert!(DataType::parse("DECIMAL(2,3)").is_err());
        assert!(DataType::parse("WIDGET").is_err());
        assert_eq!(DataType::Null.to_string(), "STRING");
    }
}
