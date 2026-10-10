//! CAST rules (types.md §8) and shared text→value parsers.

use super::{DataType, Value, datetime, decimal, float};
use crate::error::{Error, Result};

/// Whether `CAST(<from> AS <to>)` is a supported conversion (else TYPE_ERROR).
pub fn cast_allowed(from: DataType, to: DataType) -> bool {
    use DataType::*;
    if from == Null || from == to || to == String || from == String {
        return true;
    }
    matches!(
        (from, to),
        (Boolean, Int64)
            | (Int64, Boolean | Decimal { .. } | Float64)
            | (Decimal { .. }, Int64 | Decimal { .. } | Float64)
            | (Float64, Int64 | Decimal { .. })
            | (Date, Timestamp)
            | (Timestamp, Date)
    )
}

/// Error from parsing numeric text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NumTextError {
    /// Not syntactically valid.
    Syntax,
    /// Valid syntax but out of range for the target type.
    Range,
}

/// Parses `[+-]?[0-9]+` into an i64.
pub fn parse_int_text(s: &str) -> std::result::Result<i64, NumTextError> {
    let digits = s.strip_prefix(['+', '-']).unwrap_or(s);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(NumTextError::Syntax);
    }
    s.parse::<i64>().map_err(|_| NumTextError::Range)
}

/// `true`/`false`, ASCII case-insensitive.
pub fn parse_bool_text(s: &str) -> Option<bool> {
    if s.eq_ignore_ascii_case("true") {
        Some(true)
    } else if s.eq_ignore_ascii_case("false") {
        Some(false)
    } else {
        None
    }
}

fn trim(s: &str) -> &str {
    s.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\n' || c == '\r')
}

/// Converts a non-null value to type `to` with CAST semantics. The caller has
/// validated `cast_allowed`.
pub fn cast_value(v: &Value, to: DataType) -> Result<Value> {
    use DataType as T;
    if v.is_null() {
        return Ok(Value::Null);
    }
    let fail = || Error::type_error(format!("cannot cast {v:?} to {to}"));
    Ok(match to {
        T::Null => Value::Null,
        T::String => match v {
            Value::Str(_) => v.clone(),
            _ => Value::str(&v.to_text()),
        },
        T::Boolean => match v {
            Value::Bool(_) => v.clone(),
            Value::Int(i) => Value::Bool(*i != 0),
            Value::Str(s) => Value::Bool(
                parse_bool_text(trim(s))
                    .ok_or_else(|| Error::conversion(format!("cannot convert '{s}' to BOOLEAN")))?,
            ),
            _ => return Err(fail()),
        },
        T::Int64 => match v {
            Value::Int(_) => v.clone(),
            Value::Bool(b) => Value::Int(*b as i64),
            Value::Decimal(u, s) => Value::Int(u / 10i64.pow(*s as u32)),
            Value::Float(f) => Value::Int(float_to_int(*f)?),
            Value::Str(s) => Value::Int(parse_int_text(trim(s)).map_err(|e| match e {
                NumTextError::Syntax => Error::conversion(format!("cannot convert '{s}' to INT64")),
                NumTextError::Range => Error::overflow(format!("'{s}' is out of range for INT64")),
            })?),
            _ => return Err(fail()),
        },
        T::Float64 => match v {
            Value::Float(_) => v.clone(),
            Value::Int(i) => Value::Float(*i as f64),
            Value::Decimal(u, s) => Value::Float(decimal::to_f64(*u, *s)),
            Value::Str(s) => Value::Float(float::parse_float(trim(s)).map_err(|range| {
                if range {
                    Error::overflow(format!("'{s}' is out of range for FLOAT64"))
                } else {
                    Error::conversion(format!("cannot convert '{s}' to FLOAT64"))
                }
            })?),
            _ => return Err(fail()),
        },
        T::Decimal { precision, scale } => {
            let overflow = || Error::overflow(format!("value does not fit {to}"));
            match v {
                Value::Decimal(u, s) => {
                    let r = decimal::rescale(*u as i128, *s, scale).ok_or_else(overflow)?;
                    if !decimal::fits_precision(r, precision) {
                        return Err(overflow());
                    }
                    Value::Decimal(r as i64, scale)
                }
                Value::Int(i) => {
                    let r = (*i as i128)
                        .checked_mul(decimal::pow10(scale as u32))
                        .ok_or_else(overflow)?;
                    if !decimal::fits_precision(r, precision) {
                        return Err(overflow());
                    }
                    Value::Decimal(r as i64, scale)
                }
                Value::Float(f) => Value::Decimal(
                    float::f64_to_decimal(*f, precision, scale).ok_or_else(overflow)?,
                    scale,
                ),
                Value::Str(s) => {
                    let t = decimal::parse_text(trim(s)).ok_or_else(|| {
                        Error::conversion(format!("cannot convert '{s}' to {to}"))
                    })?;
                    match decimal::text_to_unscaled(&t, precision, scale, false) {
                        decimal::TextToDecimal::Ok(u) => Value::Decimal(u, scale),
                        _ => return Err(overflow()),
                    }
                }
                _ => return Err(fail()),
            }
        }
        T::Date => match v {
            Value::Date(_) => v.clone(),
            Value::Timestamp(t) => Value::Date(datetime::timestamp_to_date(*t)),
            Value::Str(s) => Value::Date(
                datetime::parse_date(trim(s))
                    .ok_or_else(|| Error::conversion(format!("cannot convert '{s}' to DATE")))?,
            ),
            _ => return Err(fail()),
        },
        T::Timestamp => match v {
            Value::Timestamp(_) => v.clone(),
            Value::Date(d) => Value::Timestamp(datetime::date_to_timestamp(*d)),
            Value::Str(s) => {
                Value::Timestamp(datetime::parse_timestamp(trim(s)).ok_or_else(|| {
                    Error::conversion(format!("cannot convert '{s}' to TIMESTAMP"))
                })?)
            }
            _ => return Err(fail()),
        },
    })
}

/// FLOAT64 → INT64, truncating toward zero.
pub fn float_to_int(f: f64) -> Result<i64> {
    let t = f.trunc();
    if (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&t) {
        Ok(t as i64)
    } else {
        Err(Error::overflow(format!(
            "{} is out of range for INT64",
            float::format_f64(f)
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn c(v: Value, to: DataType) -> Result<Value> {
        cast_value(&v, to)
    }

    #[test]
    fn numeric_casts() {
        assert_eq!(
            c(Value::Decimal(-375, 2), DataType::Int64).unwrap(),
            Value::Int(-3)
        );
        assert_eq!(
            c(Value::Decimal(2345, 3), DataType::decimal(5, 2)).unwrap(),
            Value::Decimal(235, 2)
        );
        assert_eq!(
            c(Value::Decimal(-2345, 3), DataType::decimal(5, 2)).unwrap(),
            Value::Decimal(-235, 2)
        );
        assert_eq!(
            c(Value::Int(1000), DataType::decimal(3, 0))
                .unwrap_err()
                .code,
            ErrorCode::NumericOverflow
        );
        assert_eq!(
            c(Value::Float(1e19), DataType::Int64).unwrap_err().code,
            ErrorCode::NumericOverflow
        );
        assert_eq!(
            c(Value::Float(7.9), DataType::Int64).unwrap(),
            Value::Int(7)
        );
    }

    #[test]
    fn string_casts() {
        assert_eq!(
            c(Value::str(" 12 "), DataType::Int64).unwrap(),
            Value::Int(12)
        );
        assert_eq!(
            c(Value::str("abc"), DataType::Int64).unwrap_err().code,
            ErrorCode::ConversionError
        );
        assert_eq!(
            c(Value::str("9223372036854775808"), DataType::Int64)
                .unwrap_err()
                .code,
            ErrorCode::NumericOverflow
        );
        assert_eq!(
            c(Value::str("1.005"), DataType::decimal(4, 2)).unwrap(),
            Value::Decimal(101, 2)
        );
        assert_eq!(
            c(Value::str("  TRUE "), DataType::Boolean).unwrap(),
            Value::Bool(true)
        );
        assert_eq!(
            c(Value::str("yes"), DataType::Boolean).unwrap_err().code,
            ErrorCode::ConversionError
        );
        assert_eq!(
            c(Value::str("2024-13-01"), DataType::Date)
                .unwrap_err()
                .code,
            ErrorCode::ConversionError
        );
        assert_eq!(
            c(Value::Decimal(-5, 2), DataType::String).unwrap(),
            Value::str("-0.05")
        );
    }

    #[test]
    fn allowed_matrix() {
        assert!(!cast_allowed(DataType::Date, DataType::Int64));
        assert!(!cast_allowed(DataType::Int64, DataType::Date));
        assert!(!cast_allowed(DataType::Boolean, DataType::Float64));
        assert!(cast_allowed(DataType::Null, DataType::Date));
    }
}
