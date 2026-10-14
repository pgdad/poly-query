//! Native value and type representations of the embedding API.

use std::fmt;
use std::str::FromStr;
use std::sync::Arc;

use crate::types::{self, DataType, datetime, decimal, float};

/// A column type, named as in `spec/data-types/types.md` (see
/// [`ColumnType::name`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColumnType {
    Boolean,
    Int64,
    Float64,
    /// `DECIMAL(precision, scale)`: precision 1–38, scale 0–precision.
    Decimal {
        precision: u8,
        scale: u8,
    },
    String,
    Date,
    Timestamp,
}

impl ColumnType {
    /// The canonical type name: `INT64`, `DECIMAL(18,2)`, `STRING`, …
    pub fn name(self) -> String {
        DataType::from(self).name()
    }

    /// Parses a type name, accepting the aliases of types.md §1
    /// (`INTEGER`, `NUMERIC(p,s)`, `VARCHAR`, …). Errors are
    /// `SEMANTIC_ERROR`.
    pub fn parse(name: &str) -> Result<ColumnType, super::Error> {
        Ok(ColumnType::from(DataType::parse(name)?))
    }

    /// True for the types whose values are numbers (right-aligned in
    /// tabular output): INT64, FLOAT64 and DECIMAL.
    pub fn is_numeric(self) -> bool {
        matches!(
            self,
            ColumnType::Int64 | ColumnType::Float64 | ColumnType::Decimal { .. }
        )
    }
}

impl fmt::Display for ColumnType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.name())
    }
}

impl From<DataType> for ColumnType {
    fn from(t: DataType) -> Self {
        match t.result_type() {
            DataType::Boolean => ColumnType::Boolean,
            DataType::Int64 => ColumnType::Int64,
            DataType::Float64 => ColumnType::Float64,
            DataType::Decimal { precision, scale } => ColumnType::Decimal { precision, scale },
            DataType::Date => ColumnType::Date,
            DataType::Timestamp => ColumnType::Timestamp,
            DataType::String | DataType::Null => ColumnType::String,
        }
    }
}

impl From<ColumnType> for DataType {
    fn from(t: ColumnType) -> Self {
        match t {
            ColumnType::Boolean => DataType::Boolean,
            ColumnType::Int64 => DataType::Int64,
            ColumnType::Float64 => DataType::Float64,
            ColumnType::Decimal { precision, scale } => DataType::Decimal { precision, scale },
            ColumnType::String => DataType::String,
            ColumnType::Date => DataType::Date,
            ColumnType::Timestamp => DataType::Timestamp,
        }
    }
}

/// A named, typed column of a table or result.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Column {
    pub name: String,
    pub column_type: ColumnType,
}

impl Column {
    pub fn new(name: impl Into<String>, column_type: ColumnType) -> Self {
        Column {
            name: name.into(),
            column_type,
        }
    }
}

/// An exact decimal number: `unscaled × 10^-scale` (e.g. `-12.50` is
/// unscaled `-1250`, scale `2`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Decimal {
    unscaled: i128,
    scale: u8,
}

impl Decimal {
    /// `unscaled × 10^-scale`. Scales above 38 are clamped to 38.
    pub fn new(unscaled: i128, scale: u8) -> Self {
        Decimal {
            unscaled,
            scale: scale.min(38),
        }
    }

    pub fn unscaled(self) -> i128 {
        self.unscaled
    }

    pub fn scale(self) -> u8 {
        self.scale
    }

    /// The same value at another scale, rounding half away from zero when
    /// digits are dropped; None on overflow.
    pub fn rescale(self, scale: u8) -> Option<Decimal> {
        let scale = scale.min(38);
        decimal::rescale(self.unscaled, self.scale, scale).map(|u| Decimal::new(u, scale))
    }

    /// The nearest binary64 value.
    pub fn to_f64(self) -> f64 {
        decimal::to_f64(self.unscaled, self.scale)
    }
}

/// Canonical text: exactly `scale` fractional digits, `-` for negative
/// values (`-12.50`, `0.0`, `7`).
impl fmt::Display for Decimal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&decimal::format(self.unscaled, self.scale))
    }
}

/// Parses `[+-]digits[.digits]`; the scale is the number of fractional
/// digits given (at most 38 significant digits overall).
impl FromStr for Decimal {
    type Err = super::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || {
            super::Error::new(
                super::ErrorCode::ConversionError,
                format!("invalid decimal '{s}'"),
            )
        };
        let text = decimal::parse_text(s).ok_or_else(bad)?;
        let scale = u8::try_from(text.frac_digits.len()).map_err(|_| bad())?;
        if scale > 38 {
            return Err(bad());
        }
        match decimal::text_to_unscaled(&text, 38, scale, true) {
            decimal::TextToDecimal::Ok(u) => Ok(Decimal::new(u, scale)),
            _ => Err(bad()),
        }
    }
}

/// A calendar date, stored as days since 1970-01-01 (negative before).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date(i32);

impl Date {
    pub fn from_days(days_since_epoch: i32) -> Self {
        Date(days_since_epoch)
    }

    /// A valid calendar date with year 1–9999, else None.
    pub fn from_ymd(year: i32, month: u32, day: u32) -> Option<Self> {
        if !(1..=9999).contains(&year)
            || !(1..=12).contains(&month)
            || day == 0
            || day > datetime::days_in_month(year as i64, month)
        {
            return None;
        }
        Some(Date(
            datetime::days_from_civil(year as i64, month, day) as i32
        ))
    }

    pub fn days_since_epoch(self) -> i32 {
        self.0
    }

    /// (year, month 1–12, day 1–31).
    pub fn ymd(self) -> (i32, u32, u32) {
        let (y, m, d) = datetime::civil_from_days(self.0 as i64);
        (y as i32, m, d)
    }
}

/// `YYYY-MM-DD`.
impl fmt::Display for Date {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&datetime::format_date(self.0))
    }
}

/// Parses exactly `YYYY-MM-DD`.
impl FromStr for Date {
    type Err = super::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        datetime::parse_date(s).map(Date).ok_or_else(|| {
            super::Error::new(
                super::ErrorCode::ConversionError,
                format!("invalid date '{s}'"),
            )
        })
    }
}

/// A timestamp without time zone, stored as microseconds since
/// 1970-01-01 00:00:00.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Timestamp(i64);

impl Timestamp {
    pub fn from_micros(micros_since_epoch: i64) -> Self {
        Timestamp(micros_since_epoch)
    }

    pub fn micros_since_epoch(self) -> i64 {
        self.0
    }

    /// The date part.
    pub fn date(self) -> Date {
        Date(datetime::timestamp_to_date(self.0))
    }
}

/// `YYYY-MM-DD HH:MM:SS`, with `.ffffff` when the microseconds are not 0.
impl fmt::Display for Timestamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&datetime::format_timestamp(self.0))
    }
}

/// Parses `YYYY-MM-DD[ T]HH:MM:SS[.f{1,6}]`.
impl FromStr for Timestamp {
    type Err = super::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        datetime::parse_timestamp(s).map(Timestamp).ok_or_else(|| {
            super::Error::new(
                super::ErrorCode::ConversionError,
                format!("invalid timestamp '{s}'"),
            )
        })
    }
}

/// A value in a result row or a table built from native values.
///
/// | SQL type | variant |
/// |---|---|
/// | NULL (any type) | `Null` |
/// | BOOLEAN | `Boolean(bool)` |
/// | INT64 | `Int64(i64)` |
/// | FLOAT64 | `Float64(f64)` |
/// | DECIMAL(p,s) | `Decimal(Decimal)` (scale = the column's `s`) |
/// | STRING | `String(String)` |
/// | DATE | `Date(Date)` |
/// | TIMESTAMP | `Timestamp(Timestamp)` |
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Boolean(bool),
    Int64(i64),
    Float64(f64),
    Decimal(Decimal),
    String(String),
    Date(Date),
    Timestamp(Timestamp),
}

impl Value {
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Boolean(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Value::Int64(i) => Some(*i),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Value::Float64(f) => Some(*f),
            _ => None,
        }
    }

    pub fn as_decimal(&self) -> Option<Decimal> {
        match self {
            Value::Decimal(d) => Some(*d),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_date(&self) -> Option<Date> {
        match self {
            Value::Date(d) => Some(*d),
            _ => None,
        }
    }

    pub fn as_timestamp(&self) -> Option<Timestamp> {
        match self {
            Value::Timestamp(t) => Some(*t),
            _ => None,
        }
    }

    /// Converts an engine value of a column of type `ty`; DECIMAL values
    /// get the column's scale.
    pub(crate) fn from_engine(v: types::Value, ty: DataType) -> Value {
        match v {
            types::Value::Null => Value::Null,
            types::Value::Bool(b) => Value::Boolean(b),
            types::Value::Int(i) => match ty {
                DataType::Decimal { scale, .. } => match decimal::rescale(i as i128, 0, scale) {
                    Some(u) => Value::Decimal(Decimal::new(u, scale)),
                    None => Value::Int64(i),
                },
                DataType::Float64 => Value::Float64(i as f64),
                _ => Value::Int64(i),
            },
            types::Value::Float(f) => Value::Float64(float::normalize(f)),
            types::Value::Decimal(u, s) => {
                let d = Decimal::new(u, s);
                Value::Decimal(match ty {
                    DataType::Decimal { scale, .. } if scale != s => d.rescale(scale).unwrap_or(d),
                    _ => d,
                })
            }
            types::Value::Str(s) => Value::String(s.to_string()),
            types::Value::Date(d) => Value::Date(Date(d)),
            types::Value::Timestamp(t) => Value::Timestamp(Timestamp(t)),
        }
    }

    /// Converts to an engine value for a column of type `ty`, checking that
    /// the value fits the type (`TYPE_ERROR` / `NUMERIC_OVERFLOW`).
    pub(crate) fn to_engine(&self, ty: ColumnType) -> Result<types::Value, super::Error> {
        use super::{Error, ErrorCode};
        let mismatch = || {
            Error::new(
                ErrorCode::TypeError,
                format!("value {self:?} does not match column type {ty}"),
            )
        };
        Ok(match (self, ty) {
            (Value::Null, _) => types::Value::Null,
            (Value::Boolean(b), ColumnType::Boolean) => types::Value::Bool(*b),
            (Value::Int64(i), ColumnType::Int64) => types::Value::Int(*i),
            (Value::Float64(f), ColumnType::Float64) => {
                if !f.is_finite() {
                    return Err(Error::new(
                        ErrorCode::InvalidArgument,
                        "FLOAT64 values must be finite",
                    ));
                }
                types::Value::Float(float::normalize(*f))
            }
            (Value::Decimal(d), ColumnType::Decimal { precision, scale }) => {
                let u = d
                    .rescale(scale)
                    .filter(|r| r.rescale(d.scale) == Some(*d))
                    .ok_or_else(|| {
                        Error::new(
                            ErrorCode::ConversionError,
                            format!("{d} has more fractional digits than {ty} allows"),
                        )
                    })?
                    .unscaled;
                if !decimal::fits_precision(u, precision) {
                    return Err(Error::new(
                        ErrorCode::NumericOverflow,
                        format!("{d} does not fit {ty}"),
                    ));
                }
                types::Value::Decimal(u, scale)
            }
            (Value::String(s), ColumnType::String) => types::Value::Str(Arc::from(s.as_str())),
            (Value::Date(d), ColumnType::Date) => types::Value::Date(d.0),
            (Value::Timestamp(t), ColumnType::Timestamp) => types::Value::Timestamp(t.0),
            _ => return Err(mismatch()),
        })
    }
}

/// The value's canonical text (types.md §9 without JSON quoting): DECIMAL
/// with its scale, `YYYY-MM-DD`, `true`/`false`, FLOAT64 as the shortest
/// round-trip text (`0.1`, `3.0`). NULL is written as the empty string.
impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Null => Ok(()),
            Value::Boolean(b) => write!(f, "{b}"),
            Value::Int64(i) => write!(f, "{i}"),
            Value::Float64(x) => f.write_str(&float::format_f64(*x)),
            Value::Decimal(d) => write!(f, "{d}"),
            Value::String(s) => f.write_str(s),
            Value::Date(d) => write!(f, "{d}"),
            Value::Timestamp(t) => write!(f, "{t}"),
        }
    }
}

impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Boolean(v)
    }
}

impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int64(v)
    }
}

impl From<f64> for Value {
    fn from(v: f64) -> Self {
        Value::Float64(v)
    }
}

impl From<Decimal> for Value {
    fn from(v: Decimal) -> Self {
        Value::Decimal(v)
    }
}

impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::String(v)
    }
}

impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::String(v.to_string())
    }
}

impl From<Date> for Value {
    fn from(v: Date) -> Self {
        Value::Date(v)
    }
}

impl From<Timestamp> for Value {
    fn from(v: Timestamp) -> Self {
        Value::Timestamp(v)
    }
}

impl<T: Into<Value>> From<Option<T>> for Value {
    fn from(v: Option<T>) -> Self {
        v.map_or(Value::Null, Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimal_text_round_trip() {
        let d: Decimal = "-12.50".parse().unwrap();
        assert_eq!((d.unscaled(), d.scale()), (-1250, 2));
        assert_eq!(d.to_string(), "-12.50");
        assert_eq!(Decimal::new(5, 1).to_string(), "0.5");
        assert!("1e5".parse::<Decimal>().is_err());
        assert_eq!(Decimal::new(125, 2).rescale(1), Some(Decimal::new(13, 1)));
    }

    #[test]
    fn dates() {
        let d = Date::from_ymd(2026, 2, 28).unwrap();
        assert_eq!(d.to_string(), "2026-02-28");
        assert_eq!(d.ymd(), (2026, 2, 28));
        assert_eq!(Date::from_ymd(1970, 1, 1).unwrap().days_since_epoch(), 0);
        assert!(Date::from_ymd(2026, 2, 29).is_none());
        assert_eq!("2024-02-29".parse::<Date>().unwrap().ymd(), (2024, 2, 29));
        assert_eq!(
            Timestamp::from_micros(1_500_000).to_string(),
            "1970-01-01 00:00:01.500000"
        );
    }

    #[test]
    fn engine_conversion_checks_types() {
        let ty = ColumnType::Decimal {
            precision: 18,
            scale: 2,
        };
        let v = Value::Decimal(Decimal::new(5, 1)).to_engine(ty).unwrap();
        assert_eq!(v, types::Value::Decimal(50, 2));
        assert!(Value::Decimal(Decimal::new(5, 3)).to_engine(ty).is_err());
        assert!(Value::Int64(1).to_engine(ColumnType::String).is_err());
        assert_eq!(
            Value::from_engine(types::Value::Decimal(5, 1), ty.into()),
            Value::Decimal(Decimal::new(50, 2))
        );
    }
}
