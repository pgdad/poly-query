//! JSON array and JSON Lines ingestion (ingestion.md §2).

use std::collections::HashMap;

use super::{Format, IngestOptions, at_record, check_row_limit, convert_text};
use crate::error::{Error, Result};
use crate::json::{self, Json};
use crate::storage::{ColumnBuilder, Field, Table};
use crate::types::cast::parse_int_text;
use crate::types::{DataType, Value, datetime, float};

/// A scalar JSON value of one record.
#[derive(Debug, Clone, PartialEq)]
enum Scalar {
    Null,
    Bool(bool),
    Number(String),
    String(String),
}

/// Columns being collected: names in first-appearance order plus values.
struct Columns {
    names: Vec<String>,
    index: HashMap<String, usize>,
    values: Vec<Vec<Scalar>>,
    /// Whether columns may be added (no explicit schema).
    open: bool,
    rows: usize,
}

impl Columns {
    fn add_record(&mut self, obj: Vec<(String, Json)>, record: usize) -> Result<()> {
        let mut seen = vec![false; self.names.len()];
        for (key, value) in obj {
            let lower = key.to_ascii_lowercase();
            let idx = match self.index.get(&lower) {
                Some(&i) => i,
                None if self.open => {
                    if key.is_empty() {
                        return Err(Error::ingest(format!("record {record}: empty column name")));
                    }
                    let i = self.names.len();
                    self.names.push(key.clone());
                    self.index.insert(lower, i);
                    self.values.push(vec![Scalar::Null; self.rows]);
                    seen.push(false);
                    i
                }
                None => {
                    return Err(Error::ingest(format!("record {record}: key '{key}' is not in the schema")));
                }
            };
            if seen[idx] {
                return Err(Error::ingest(format!("record {record}: duplicate key '{key}'")));
            }
            seen[idx] = true;
            let scalar = match value {
                Json::Null => Scalar::Null,
                Json::Bool(b) => Scalar::Bool(b),
                Json::Number(n) => Scalar::Number(n),
                Json::String(s) => Scalar::String(s),
                Json::Array(_) | Json::Object(_) | Json::Raw(_) => {
                    return Err(Error::ingest(format!("record {record}: nested value for key '{key}'")));
                }
            };
            self.values[idx].push(scalar);
        }
        for (i, s) in seen.iter().enumerate() {
            if !s {
                self.values[i].push(Scalar::Null);
            }
        }
        self.rows += 1;
        Ok(())
    }
}

fn record_object(v: Json, record: usize) -> Result<Vec<(String, Json)>> {
    match v {
        Json::Object(fields) => Ok(fields),
        _ => Err(Error::ingest(format!("record {record} is not a JSON object"))),
    }
}

/// Loads JSON (array of objects) or JSON Lines text into a table.
pub fn load(name: &str, format: Format, text: &str, opts: &IngestOptions) -> Result<Table> {
    let mut cols = Columns { names: Vec::new(), index: HashMap::new(), values: Vec::new(), open: true, rows: 0 };
    if let Some(schema) = &opts.schema {
        for f in schema {
            cols.index.insert(f.name.to_ascii_lowercase(), cols.names.len());
            cols.names.push(f.name.clone());
            cols.values.push(Vec::new());
        }
        cols.open = false;
    }
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    match format {
        Format::Json => {
            let doc = json::parse(text).map_err(|e| Error::ingest(format!("invalid JSON: {e}")))?;
            let Json::Array(items) = doc else {
                return Err(Error::ingest("JSON input must be an array of objects"));
            };
            check_row_limit(items.len(), opts.max_rows)?;
            for (i, item) in items.into_iter().enumerate() {
                cols.add_record(record_object(item, i + 1)?, i + 1)?;
            }
        }
        _ => {
            for (lineno, line) in text.split('\n').enumerate() {
                let line = line.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\r');
                if line.is_empty() {
                    continue;
                }
                let v = json::parse(line)
                    .map_err(|e| Error::ingest(format!("line {}: invalid JSON: {e}", lineno + 1)))?;
                let record = cols.rows + 1;
                cols.add_record(record_object(v, record)?, record)?;
                check_row_limit(cols.rows, opts.max_rows)?;
            }
        }
    }

    let declared: Option<Vec<DataType>> = opts.schema.as_ref().map(|s| s.iter().map(|f| f.data_type).collect());
    let mut fields = Vec::with_capacity(cols.names.len());
    let mut columns = Vec::with_capacity(cols.names.len());
    for (c, values) in cols.values.into_iter().enumerate() {
        let name = &cols.names[c];
        let (ty, explicit) = match &declared {
            Some(types) => (types[c], true),
            None => (infer(&values).map_err(|e| at_record(e, 0, name))?, false),
        };
        let mut builder = ColumnBuilder::new(ty);
        for (r, v) in values.into_iter().enumerate() {
            let value = convert(v, ty, explicit).map_err(|e| at_record(e, r + 1, name))?;
            builder.push(value);
        }
        fields.push(Field::new(name.clone(), ty.result_type()));
        columns.push(builder.finish());
    }
    Ok(Table::new(name, fields, columns, cols.rows))
}

fn is_integer_literal(n: &str) -> bool {
    !n.contains(['.', 'e', 'E']) && parse_int_text(n).is_ok()
}

/// Infers a column type from its JSON values (ingestion.md §2.1).
fn infer(values: &[Scalar]) -> Result<DataType> {
    let (mut bools, mut nums, mut strs) = (0, 0, 0);
    let (mut all_int, mut all_date, mut all_temporal) = (true, true, true);
    for v in values {
        match v {
            Scalar::Null => {}
            Scalar::Bool(_) => bools += 1,
            Scalar::Number(n) => {
                nums += 1;
                all_int &= is_integer_literal(n);
            }
            Scalar::String(s) => {
                strs += 1;
                if all_temporal {
                    let is_date = datetime::parse_date(s).is_some();
                    all_date &= is_date;
                    all_temporal = is_date || datetime::parse_timestamp(s).is_some();
                }
            }
        }
    }
    let kinds = (bools > 0) as u8 + (nums > 0) as u8 + (strs > 0) as u8;
    Ok(match kinds {
        0 => DataType::String,
        1 if bools > 0 => DataType::Boolean,
        1 if nums > 0 => {
            if all_int {
                DataType::Int64
            } else {
                DataType::Float64
            }
        }
        1 => {
            if all_date {
                DataType::Date
            } else if all_temporal {
                DataType::Timestamp
            } else {
                DataType::String
            }
        }
        _ => return Err(Error::ingest("column mixes JSON value types")),
    })
}

/// Converts one JSON scalar to the column type. With an inferred type the
/// value is known to fit the inference; with an explicit schema the rules of
/// ingestion.md §2.2 apply (failures are CONVERSION_ERROR).
fn convert(v: Scalar, ty: DataType, explicit: bool) -> Result<Value> {
    let mismatch = |what: &str| Error::conversion(format!("cannot convert JSON {what} to {ty}"));
    Ok(match v {
        Scalar::Null => Value::Null,
        Scalar::Bool(b) => match ty {
            DataType::Boolean => Value::Bool(b),
            _ => return Err(mismatch("boolean")),
        },
        Scalar::Number(n) => match ty {
            DataType::Int64 | DataType::Decimal { .. } => convert_text(&n, ty)?,
            DataType::Float64 => match float::parse_float(&n) {
                Ok(f) => Value::Float(f),
                Err(_) if explicit => return Err(mismatch("number")),
                Err(_) => return Err(Error::ingest(format!("number {n} is out of range for FLOAT64"))),
            },
            _ => return Err(mismatch("number")),
        },
        Scalar::String(s) => match ty {
            DataType::String => Value::str(&s),
            DataType::Boolean => return Err(mismatch("string")),
            DataType::Date | DataType::Timestamp if !explicit => convert_text(&s, ty)?,
            _ => convert_text(s.trim_matches(|c: char| c == ' ' || c == '\t'), ty)?,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn opts() -> IngestOptions {
        IngestOptions::default()
    }

    #[test]
    fn jsonl_union_of_keys() {
        let t = load("t", Format::JsonLines, "{\"a\": 1}\n\n{\"b\": \"x\", \"a\": 2}\n{\"c\": true}\n", &opts()).unwrap();
        assert_eq!(t.row_count, 3);
        let names: Vec<_> = t.fields.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, ["a", "b", "c"]);
        assert_eq!(t.fields[0].data_type, DataType::Int64);
        assert!(t.columns[1].value(0).is_null());
        assert_eq!(t.columns[1].value(1), Value::str("x"));
    }

    #[test]
    fn json_array_inference() {
        let t = load("t", Format::Json, r#"[{"x": 1.5, "d": "2024-01-01"}, {"x": 2, "d": "2024-01-01T10:00:00"}]"#, &opts())
            .unwrap();
        assert_eq!(t.fields[0].data_type, DataType::Float64);
        assert_eq!(t.fields[1].data_type, DataType::Timestamp);
    }

    #[test]
    fn errors() {
        let code = |f, s: &str| load("t", f, s, &opts()).unwrap_err().code;
        assert_eq!(code(Format::Json, "{\"a\": 1}"), ErrorCode::IngestError);
        assert_eq!(code(Format::Json, "[{\"a\": 1}, 2]"), ErrorCode::IngestError);
        assert_eq!(code(Format::JsonLines, "{\"a\": 1, \"a\": 2}"), ErrorCode::IngestError);
        assert_eq!(code(Format::JsonLines, "{\"a\": [1]}"), ErrorCode::IngestError);
        assert_eq!(code(Format::Json, "[{\"a\":1},{\"a\":\"x\"}]"), ErrorCode::IngestError);
        assert_eq!(code(Format::JsonLines, "{\"a\":1,"), ErrorCode::IngestError);
    }

    #[test]
    fn explicit_schema() {
        let mut o = opts();
        o.schema = Some(vec![Field::new("id", DataType::Int64), Field::new("amt", DataType::decimal(8, 3))]);
        let t = load("t", Format::Json, r#"[{"id": 1, "amt": 12.5}, {"id": 2, "amt": "-0.125"}, {"id": 3}]"#, &o)
            .unwrap();
        assert_eq!(t.columns[1].value(0), Value::Decimal(12500, 3));
        assert_eq!(t.columns[1].value(1), Value::Decimal(-125, 3));
        assert!(t.columns[1].value(2).is_null());
        let e = load("t", Format::JsonLines, "{\"id\": 1.5}", &o).unwrap_err();
        assert_eq!(e.code, ErrorCode::ConversionError);
        let e = load("t", Format::JsonLines, "{\"id\": 1, \"zzz\": 2}", &o).unwrap_err();
        assert_eq!(e.code, ErrorCode::IngestError);
    }
}
