//! Runtime values and their ordering, equality and serialization.

use std::cmp::Ordering;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

use super::{DataType, datetime, decimal, float};
use crate::error::{Error, Result};

/// A single SQL value. DECIMAL carries its unscaled value and scale.
#[derive(Debug, Clone)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Decimal(i64, u8),
    Str(Arc<str>),
    /// Days since 1970-01-01.
    Date(i32),
    /// Microseconds since 1970-01-01 00:00:00.
    Timestamp(i64),
}

impl Value {
    pub fn str(s: &str) -> Value {
        Value::Str(Arc::from(s))
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// Numeric value as f64 (INT64, DECIMAL, FLOAT64).
    pub fn to_f64(&self) -> Option<f64> {
        match self {
            Value::Int(i) => Some(*i as f64),
            Value::Float(f) => Some(*f),
            Value::Decimal(u, s) => Some(decimal::to_f64(*u, *s)),
            _ => None,
        }
    }

    /// Compares two non-null values of comparable types (types.md §5).
    /// Numeric values compare by exact mathematical value (INT64 vs DECIMAL
    /// uses i128, so no promotion overflow can occur).
    pub fn compare(&self, other: &Value) -> Result<Ordering> {
        use Value::*;
        Ok(match (self, other) {
            (Bool(a), Bool(b)) => a.cmp(b),
            (Int(a), Int(b)) => a.cmp(b),
            (Float(a), Float(b)) => cmp_f64(*a, *b),
            (Decimal(a, sa), Decimal(b, sb)) => decimal::compare(*a, *sa, *b, *sb),
            (Int(a), Decimal(b, s)) => (*a as i128 * decimal::pow10(*s as u32)).cmp(&(*b as i128)),
            (Decimal(a, s), Int(b)) => (*a as i128).cmp(&(*b as i128 * decimal::pow10(*s as u32))),
            (Int(_) | Decimal(..), Float(b)) => cmp_f64(self.to_f64().unwrap_or(0.0), *b),
            (Float(a), Int(_) | Decimal(..)) => cmp_f64(*a, other.to_f64().unwrap_or(0.0)),
            (Str(a), Str(b)) => a.as_bytes().cmp(b.as_bytes()),
            (Date(a), Date(b)) => a.cmp(b),
            (Timestamp(a), Timestamp(b)) => a.cmp(b),
            (Date(a), Timestamp(b)) => datetime::date_to_timestamp(*a).cmp(b),
            (Timestamp(a), Date(b)) => a.cmp(&datetime::date_to_timestamp(*b)),
            _ => {
                return Err(Error::internal(format!(
                    "cannot compare {self:?} with {other:?}"
                )));
            }
        })
    }

    /// Total order used for sorting values of one column type: NULL first,
    /// then the §5 ordering. Never fails (falls back to exact comparison).
    pub fn sort_cmp(&self, other: &Value) -> Ordering {
        match (self, other) {
            (Value::Null, Value::Null) => Ordering::Equal,
            (Value::Null, _) => Ordering::Less,
            (_, Value::Null) => Ordering::Greater,
            (Value::Int(a), Value::Decimal(b, s)) => {
                (*a as i128 * decimal::pow10(*s as u32)).cmp(&(*b as i128))
            }
            (Value::Decimal(a, s), Value::Int(b)) => {
                (*a as i128).cmp(&(*b as i128 * decimal::pow10(*s as u32)))
            }
            _ => self.compare(other).unwrap_or(Ordering::Equal),
        }
    }

    /// Text form used by CAST(... AS STRING).
    pub fn to_text(&self) -> String {
        match self {
            Value::Null => String::new(),
            Value::Bool(b) => if *b { "true" } else { "false" }.to_string(),
            Value::Int(i) => i.to_string(),
            Value::Float(f) => float::format_f64(*f),
            Value::Decimal(u, s) => decimal::format(*u, *s),
            Value::Str(s) => s.to_string(),
            Value::Date(d) => datetime::format_date(*d),
            Value::Timestamp(t) => datetime::format_timestamp(*t),
        }
    }

    /// Serializes per types.md §9. `ty` is the column type (used to render
    /// DECIMAL with the declared scale).
    pub fn write_json(&self, ty: DataType, out: &mut String) {
        match self {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Int(i) => decimal::write_i64(out, *i),
            Value::Float(f) => out.push_str(&float::format_f64(*f)),
            Value::Decimal(u, s) => {
                out.push('"');
                match ty {
                    DataType::Decimal { scale, .. } if scale != *s => {
                        let v = decimal::rescale(*u as i128, *s, scale).unwrap_or(*u as i128);
                        decimal::write(out, v as i64, scale);
                    }
                    _ => decimal::write(out, *u, *s),
                }
                out.push('"');
            }
            Value::Str(s) => crate::json::write_escaped(out, s),
            Value::Date(d) => {
                out.push('"');
                datetime::write_date(out, *d);
                out.push('"');
            }
            Value::Timestamp(t) => {
                out.push('"');
                datetime::write_timestamp(out, *t);
                out.push('"');
            }
        }
    }

    /// Approximate in-memory footprint in bytes (for memory accounting).
    pub fn approx_size(&self) -> usize {
        match self {
            Value::Str(s) => 24 + s.len(),
            _ => 24,
        }
    }
}

/// Promotes an INT64 to the unscaled value of DECIMAL(18, scale).
pub fn promote_int(v: i64, scale: u8) -> Result<i128> {
    let scaled = v as i128 * decimal::pow10(scale as u32);
    if decimal::fits18(scaled) {
        Ok(scaled)
    } else {
        Err(Error::overflow(format!(
            "{v} does not fit DECIMAL(18,{scale})"
        )))
    }
}

fn cmp_f64(a: f64, b: f64) -> Ordering {
    a.partial_cmp(&b).unwrap_or(Ordering::Equal)
}

/// Equality with "not distinct" semantics for grouping/DISTINCT: NULLs are
/// equal to each other, DECIMALs compare by value, `0.0 = -0.0`.
impl PartialEq for Value {
    fn eq(&self, other: &Value) -> bool {
        match (self, other) {
            (Value::Null, Value::Null) => true,
            (Value::Null, _) | (_, Value::Null) => false,
            _ => self
                .compare(other)
                .map(|o| o == Ordering::Equal)
                .unwrap_or(false),
        }
    }
}

impl Eq for Value {}

impl Hash for Value {
    fn hash<H: Hasher>(&self, state: &mut H) {
        match self {
            Value::Null => 0u8.hash(state),
            Value::Bool(b) => b.hash(state),
            Value::Int(i) => i.hash(state),
            Value::Float(f) => float::normalize(*f).to_bits().hash(state),
            Value::Decimal(u, s) => {
                // Hash the value with trailing fractional zeros removed so that
                // 1.50 and 1.5 hash identically.
                let (mut u, mut s) = (*u, *s);
                while s > 0 && u % 10 == 0 {
                    u /= 10;
                    s -= 1;
                }
                u.hash(state);
                s.hash(state);
            }
            Value::Str(s) => s.hash(state),
            Value::Date(d) => d.hash(state),
            Value::Timestamp(t) => t.hash(state),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mixed_numeric_comparison() {
        assert_eq!(
            Value::Int(1).compare(&Value::Decimal(10, 1)).unwrap(),
            Ordering::Equal
        );
        assert_eq!(
            Value::Int(1).compare(&Value::Float(1.5)).unwrap(),
            Ordering::Less
        );
        assert_eq!(
            Value::Decimal(15, 1)
                .compare(&Value::Decimal(150, 2))
                .unwrap(),
            Ordering::Equal
        );
        assert_eq!(
            Value::Int(i64::MAX).compare(&Value::Decimal(1, 1)).unwrap(),
            Ordering::Greater
        );
        assert_eq!(
            Value::Int(1).compare(&Value::Decimal(1, 18)).unwrap(),
            Ordering::Greater
        );
    }

    #[test]
    fn sort_order_nulls_first() {
        assert_eq!(Value::Null.sort_cmp(&Value::Int(-5)), Ordering::Less);
        assert_eq!(Value::str("B").sort_cmp(&Value::str("a")), Ordering::Less);
    }

    #[test]
    fn decimal_hash_by_value() {
        use std::collections::hash_map::DefaultHasher;
        let h = |v: &Value| {
            let mut s = DefaultHasher::new();
            v.hash(&mut s);
            s.finish()
        };
        assert_eq!(h(&Value::Decimal(150, 2)), h(&Value::Decimal(15, 1)));
        assert_eq!(Value::Decimal(150, 2), Value::Decimal(15, 1));
    }

    #[test]
    fn json_rendering() {
        let mut s = String::new();
        Value::Decimal(-50, 2).write_json(DataType::decimal(3, 2), &mut s);
        assert_eq!(s, "\"-0.50\"");
        s.clear();
        Value::Timestamp(0).write_json(DataType::Timestamp, &mut s);
        assert_eq!(s, "\"1970-01-01 00:00:00\"");
    }
}
