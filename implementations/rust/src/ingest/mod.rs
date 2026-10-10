//! Data ingestion: CSV, JSON array and JSON Lines (spec/data-types/ingestion.md).

pub mod csv;
pub mod json;

use std::collections::HashSet;

use crate::error::{Error, ErrorCode, Result};
use crate::storage::{Field, Table};
use crate::types::cast::{NumTextError, parse_bool_text, parse_int_text};
use crate::types::{DataType, Value, datetime, decimal, float};

/// Maximum length of a single field.
pub const MAX_FIELD_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Csv,
    Json,
    JsonLines,
}

impl Format {
    pub fn parse(s: &str) -> Option<Format> {
        match s {
            "csv" => Some(Format::Csv),
            "json" => Some(Format::Json),
            "jsonl" => Some(Format::JsonLines),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct IngestOptions {
    /// CSV: first record is the header.
    pub header: bool,
    /// CSV field delimiter (ASCII).
    pub delimiter: u8,
    /// Explicit schema, if given.
    pub schema: Option<Vec<Field>>,
    /// Maximum number of rows (`--max-table-rows`).
    pub max_rows: usize,
}

impl Default for IngestOptions {
    fn default() -> Self {
        IngestOptions {
            header: true,
            delimiter: b',',
            schema: None,
            max_rows: usize::MAX,
        }
    }
}

/// Parses `text` in `format` into a new table named `name`.
pub fn ingest(name: &str, format: Format, text: &str, opts: &IngestOptions) -> Result<Table> {
    if let Some(schema) = &opts.schema {
        validate_names(schema.iter().map(|f| f.name.as_str()))?;
    }
    match format {
        Format::Csv => csv::load(name, text, opts),
        Format::Json | Format::JsonLines => json::load(name, format, text, opts),
    }
}

/// Column names must be non-empty and unique (case-insensitively).
pub fn validate_names<'a>(names: impl Iterator<Item = &'a str>) -> Result<()> {
    let mut seen = HashSet::new();
    for n in names {
        if n.is_empty() {
            return Err(Error::ingest("empty column name"));
        }
        if !seen.insert(n.to_ascii_lowercase()) {
            return Err(Error::ingest(format!("duplicate column name '{n}'")));
        }
    }
    Ok(())
}

pub fn check_row_limit(rows: usize, max: usize) -> Result<()> {
    if rows > max {
        Err(Error::resource_limit(format!(
            "input exceeds the maximum of {max} rows"
        )))
    } else {
        Ok(())
    }
}

/// Converts field text to `ty` with explicit-schema rules (ingestion.md §1.2).
/// `text` is already trimmed for non-STRING types. Errors are CONVERSION_ERROR.
pub fn convert_text(text: &str, ty: DataType) -> Result<Value> {
    let bad = || Error::conversion(format!("cannot convert '{}' to {ty}", truncate(text)));
    Ok(match ty {
        DataType::String | DataType::Null => Value::str(text),
        DataType::Boolean => Value::Bool(parse_bool_text(text).ok_or_else(bad)?),
        DataType::Int64 => Value::Int(parse_int_text(text).map_err(|e| match e {
            NumTextError::Syntax | NumTextError::Range => bad(),
        })?),
        DataType::Float64 => Value::Float(float::parse_float(text).map_err(|_| bad())?),
        DataType::Decimal { precision, scale } => {
            let t = decimal::parse_text(text).ok_or_else(bad)?;
            match decimal::text_to_unscaled(&t, precision, scale, true) {
                decimal::TextToDecimal::Ok(u) => Value::Decimal(u, scale),
                _ => return Err(bad()),
            }
        }
        DataType::Date => Value::Date(datetime::parse_date(text).ok_or_else(bad)?),
        DataType::Timestamp => {
            Value::Timestamp(datetime::parse_date_or_timestamp(text).ok_or_else(bad)?)
        }
    })
}

fn truncate(s: &str) -> String {
    if s.chars().count() > 40 {
        format!("{}…", s.chars().take(40).collect::<String>())
    } else {
        s.to_string()
    }
}

/// Adds record/column context to a conversion error.
pub fn at_record(err: Error, record: usize, column: &str) -> Error {
    if err.code == ErrorCode::ConversionError || err.code == ErrorCode::IngestError {
        let msg = format!("record {record}, column '{column}': {}", err.message);
        Error::new(err.code, msg)
            .with_detail("record", crate::json::Json::uint(record as u64))
            .with_detail("column_name", crate::json::Json::str(column))
    } else {
        err
    }
}

/// Incremental type inference over text values (ingestion.md §1.1).
#[derive(Debug, Clone, Copy)]
pub struct TextInference {
    boolean: bool,
    int: bool,
    float: bool,
    date: bool,
    timestamp: bool,
    seen: bool,
}

impl Default for TextInference {
    fn default() -> Self {
        TextInference {
            boolean: true,
            int: true,
            float: true,
            date: true,
            timestamp: true,
            seen: false,
        }
    }
}

impl TextInference {
    /// Observes one considered value (already trimmed).
    pub fn observe(&mut self, t: &str) {
        self.seen = true;
        if self.boolean && parse_bool_text(t).is_none() {
            self.boolean = false;
        }
        if self.int && parse_int_text(t).is_err() {
            self.int = false;
        }
        if self.float && float::parse_float(t).is_err() {
            self.float = false;
        }
        let is_date = (self.date || self.timestamp) && datetime::parse_date(t).is_some();
        if self.date && !is_date {
            self.date = false;
        }
        if self.timestamp && !is_date && datetime::parse_timestamp(t).is_none() {
            self.timestamp = false;
        }
    }

    pub fn result(&self) -> DataType {
        if !self.seen {
            DataType::String
        } else if self.boolean {
            DataType::Boolean
        } else if self.int {
            DataType::Int64
        } else if self.float {
            DataType::Float64
        } else if self.date {
            DataType::Date
        } else if self.timestamp {
            DataType::Timestamp
        } else {
            DataType::String
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inference_order() {
        let infer = |vals: &[&str]| {
            let mut t = TextInference::default();
            for v in vals {
                t.observe(v);
            }
            t.result()
        };
        assert_eq!(infer(&["true", "FALSE"]), DataType::Boolean);
        assert_eq!(infer(&["1", "-2"]), DataType::Int64);
        assert_eq!(infer(&["1", "2.5"]), DataType::Float64);
        assert_eq!(infer(&["9223372036854775808"]), DataType::Float64);
        assert_eq!(infer(&["2024-01-01"]), DataType::Date);
        assert_eq!(
            infer(&["2024-01-01", "2024-01-01 10:00:00"]),
            DataType::Timestamp
        );
        assert_eq!(infer(&["2023-02-29"]), DataType::String);
        assert_eq!(infer(&[]), DataType::String);
        assert_eq!(infer(&["NaN"]), DataType::String);
    }

    #[test]
    fn explicit_conversion() {
        assert_eq!(
            convert_text("10.005", DataType::decimal(10, 2))
                .unwrap_err()
                .code,
            ErrorCode::ConversionError
        );
        assert_eq!(
            convert_text("0.5", DataType::decimal(4, 2)).unwrap(),
            Value::Decimal(50, 2)
        );
        assert_eq!(
            convert_text("2024-01-01", DataType::Timestamp).unwrap(),
            Value::Timestamp(19723 * 86_400_000_000)
        );
        assert!(convert_text("1e999", DataType::Float64).is_err());
    }
}
