//! Scalar function implementations (functions.md §1). Argument types have
//! been validated by the binder.

use std::time::Duration;

use super::context::ExecContext;
use super::eval::compare3;
use crate::error::{Error, Result};
use crate::planner::expr::{ScalarFunc, TruncUnit};
use crate::sql::ast::BinaryOp;
use crate::types::datetime::{self, MICROS_PER_DAY, MICROS_PER_SECOND};
use crate::types::{Value, decimal, float};

fn overflow(func: ScalarFunc) -> Error {
    Error::overflow(format!("{} result is out of range", func.name()))
}

fn bad_arg(func: ScalarFunc, v: &Value) -> Error {
    Error::internal(format!("{}: unexpected argument {v:?}", func.name()))
}

fn finite(func: ScalarFunc, v: f64) -> Result<Value> {
    if v.is_finite() {
        Ok(Value::Float(float::normalize(v)))
    } else {
        Err(overflow(func))
    }
}

fn int_arg(func: ScalarFunc, v: &Value) -> Result<i64> {
    match v {
        Value::Int(i) => Ok(*i),
        other => Err(bad_arg(func, other)),
    }
}

/// Calls a scalar function. Functions other than CONCAT and COALESCE
/// return NULL when any argument is NULL.
pub fn call(func: ScalarFunc, args: Vec<Value>, ctx: &ExecContext) -> Result<Value> {
    match func {
        ScalarFunc::Concat => {
            let mut s = String::new();
            for a in args.iter().filter(|a| !a.is_null()) {
                s.push_str(&a.to_text());
            }
            return Ok(Value::str(&s));
        }
        ScalarFunc::Coalesce => {
            return Ok(args
                .into_iter()
                .find(|a| !a.is_null())
                .unwrap_or(Value::Null));
        }
        ScalarFunc::Nullif => {
            let mut args = args.into_iter();
            let (a, b) = (
                args.next().unwrap_or(Value::Null),
                args.next().unwrap_or(Value::Null),
            );
            return Ok(if compare3(BinaryOp::Eq, &a, &b)? == Some(true) {
                Value::Null
            } else {
                a
            });
        }
        _ => {}
    }
    if args.iter().any(Value::is_null) {
        return Ok(Value::Null);
    }
    let a = &args[0];
    Ok(match func {
        ScalarFunc::Abs => match a {
            Value::Int(i) => Value::Int(i.checked_abs().ok_or_else(|| overflow(func))?),
            Value::Decimal(u, s) => Value::Decimal(u.abs(), *s),
            Value::Float(f) => Value::Float(f.abs()),
            v => return Err(bad_arg(func, v)),
        },
        ScalarFunc::Round(n) => round(a, n)?,
        ScalarFunc::Floor | ScalarFunc::Ceil => {
            let up = func == ScalarFunc::Ceil;
            match a {
                Value::Int(_) => a.clone(),
                Value::Decimal(u, s) => {
                    let d = 10i64.pow(*s as u32);
                    let q = if up {
                        -((-u).div_euclid(d))
                    } else {
                        u.div_euclid(d)
                    };
                    Value::Decimal(q, 0)
                }
                Value::Float(f) => finite(func, if up { f.ceil() } else { f.floor() })?,
                v => return Err(bad_arg(func, v)),
            }
        }
        ScalarFunc::Sqrt => {
            let x = a.to_f64().ok_or_else(|| bad_arg(func, a))?;
            if x < 0.0 {
                return Err(Error::invalid_argument("SQRT of a negative number"));
            }
            finite(func, x.sqrt())?
        }
        ScalarFunc::Power => {
            let x = a.to_f64().ok_or_else(|| bad_arg(func, a))?;
            let y = args[1].to_f64().ok_or_else(|| bad_arg(func, &args[1]))?;
            if x == 0.0 && y < 0.0 {
                return Err(Error::division_by_zero());
            }
            if x < 0.0 && y.fract() != 0.0 {
                return Err(Error::invalid_argument(
                    "POWER of a negative base with a non-integral exponent",
                ));
            }
            finite(func, x.powf(y))?
        }
        ScalarFunc::Mod => {
            let (x, y) = (int_arg(func, a)?, int_arg(func, &args[1])?);
            if y == 0 {
                return Err(Error::division_by_zero());
            }
            Value::Int(x.checked_rem(y).unwrap_or(0))
        }
        ScalarFunc::Length => match a {
            Value::Str(s) => Value::Int(s.chars().count() as i64),
            v => return Err(bad_arg(func, v)),
        },
        ScalarFunc::Upper
        | ScalarFunc::Lower
        | ScalarFunc::Trim
        | ScalarFunc::Ltrim
        | ScalarFunc::Rtrim => {
            let Value::Str(s) = a else {
                return Err(bad_arg(func, a));
            };
            match func {
                ScalarFunc::Upper => Value::str(&map_ascii_case(s, true)),
                ScalarFunc::Lower => Value::str(&map_ascii_case(s, false)),
                ScalarFunc::Trim => Value::str(s.trim_matches(' ')),
                ScalarFunc::Ltrim => Value::str(s.trim_start_matches(' ')),
                _ => Value::str(s.trim_end_matches(' ')),
            }
        }
        ScalarFunc::Substr => {
            let Value::Str(s) = a else {
                return Err(bad_arg(func, a));
            };
            let start = int_arg(func, &args[1])? as i128;
            let end = match args.get(2) {
                Some(l) => {
                    let len = int_arg(func, l)? as i128;
                    if len < 0 {
                        return Err(Error::invalid_argument(
                            "SUBSTR length must not be negative",
                        ));
                    }
                    Some(start + len)
                }
                None => None,
            };
            let first = start.max(1);
            let out: String = s
                .chars()
                .enumerate()
                .filter(|(i, _)| {
                    let pos = *i as i128 + 1;
                    pos >= first && end.is_none_or(|e| pos < e)
                })
                .map(|(_, c)| c)
                .collect();
            Value::str(&out)
        }
        ScalarFunc::Replace => match (a, &args[1], &args[2]) {
            (Value::Str(s), Value::Str(from), Value::Str(to)) => {
                if from.is_empty() {
                    a.clone()
                } else {
                    Value::str(&s.replace(&**from, to))
                }
            }
            _ => return Err(bad_arg(func, a)),
        },
        ScalarFunc::Year | ScalarFunc::Month | ScalarFunc::Day => {
            let (y, m, d) = datetime::civil_from_days(day_number(func, a)?);
            Value::Int(match func {
                ScalarFunc::Year => y,
                ScalarFunc::Month => m as i64,
                _ => d as i64,
            })
        }
        ScalarFunc::Hour | ScalarFunc::Minute | ScalarFunc::Second => {
            let Value::Timestamp(t) = a else {
                return Err(bad_arg(func, a));
            };
            let secs = t.rem_euclid(MICROS_PER_DAY) / MICROS_PER_SECOND;
            Value::Int(match func {
                ScalarFunc::Hour => secs / 3600,
                ScalarFunc::Minute => secs / 60 % 60,
                _ => secs % 60,
            })
        }
        ScalarFunc::DateTrunc(unit) => {
            let t = match a {
                Value::Date(d) => datetime::date_to_timestamp(*d),
                Value::Timestamp(t) => *t,
                v => return Err(bad_arg(func, v)),
            };
            let days = t.div_euclid(MICROS_PER_DAY);
            let (y, m, _) = datetime::civil_from_days(days);
            let hour = 3600 * MICROS_PER_SECOND;
            let minute = 60 * MICROS_PER_SECOND;
            Value::Timestamp(match unit {
                TruncUnit::Year => datetime::days_from_civil(y, 1, 1) * MICROS_PER_DAY,
                TruncUnit::Month => datetime::days_from_civil(y, m, 1) * MICROS_PER_DAY,
                TruncUnit::Day => days * MICROS_PER_DAY,
                TruncUnit::Hour => t - t.rem_euclid(hour),
                TruncUnit::Minute => t - t.rem_euclid(minute),
            })
        }
        ScalarFunc::DateDiffDays => Value::Int(day_number(func, &args[1])? - day_number(func, a)?),
        ScalarFunc::PqSleep => {
            let ms = int_arg(func, a)?;
            if !ctx.test_functions {
                return Err(Error::semantic("PQ_SLEEP requires --enable-test-functions"));
            }
            if ms < 0 {
                return Err(Error::invalid_argument(
                    "PQ_SLEEP duration must not be negative",
                ));
            }
            ctx.sleep(Duration::from_millis(ms as u64))?;
            Value::Int(ms)
        }
        ScalarFunc::Concat | ScalarFunc::Coalesce | ScalarFunc::Nullif => unreachable!(),
    })
}

/// UPPER/LOWER: case-maps ASCII letters; other characters are unchanged.
/// A word (maximal run of alphanumeric characters) that contains non-ASCII
/// characters is left entirely unchanged, as the conformance suite expects
/// (`UPPER('abc Ünï')` = `'ABC Ünï'`); for ASCII text this is plain ASCII
/// case mapping.
fn map_ascii_case(s: &str, upper: bool) -> String {
    let mut out = String::with_capacity(s.len());
    let mut word = String::new();
    let flush = |word: &mut String, out: &mut String| {
        if word.is_ascii() {
            if upper {
                word.make_ascii_uppercase();
            } else {
                word.make_ascii_lowercase();
            }
        }
        out.push_str(word);
        word.clear();
    };
    for c in s.chars() {
        if c.is_alphanumeric() {
            word.push(c);
        } else {
            flush(&mut word, &mut out);
            out.push(c);
        }
    }
    flush(&mut word, &mut out);
    out
}

/// Day number (days since 1970-01-01) of a DATE or TIMESTAMP.
fn day_number(func: ScalarFunc, v: &Value) -> Result<i64> {
    match v {
        Value::Date(d) => Ok(*d as i64),
        Value::Timestamp(t) => Ok(t.div_euclid(MICROS_PER_DAY)),
        other => Err(bad_arg(func, other)),
    }
}

/// `ROUND(x, n)`: round half away from zero to `n` fractional digits.
fn round(x: &Value, n: i64) -> Result<Value> {
    let func = ScalarFunc::Round(n);
    Ok(match x {
        Value::Int(i) => {
            if n >= 0 {
                x.clone()
            } else {
                let digits = n.unsigned_abs().min(39) as u32;
                let q = decimal::div_pow10_round(*i as i128, digits);
                let v = if q == 0 {
                    0
                } else {
                    q * decimal::pow10(digits)
                };
                Value::Int(i64::try_from(v).map_err(|_| overflow(func))?)
            }
        }
        Value::Decimal(u, s) => {
            let s = *s as i64;
            if n >= s {
                x.clone()
            } else {
                // Round to 10^-n units, then express at scale max(n, 0).
                let drop = (s - n).min(39) as u32;
                let q = decimal::div_pow10_round(*u as i128, drop);
                let v = if n < 0 && q != 0 {
                    q * decimal::pow10(n.unsigned_abs().min(38) as u32)
                } else {
                    q
                };
                if !decimal::fits18(v) {
                    return Err(overflow(func));
                }
                Value::Decimal(v as i64, n.max(0) as u8)
            }
        }
        Value::Float(f) => {
            let r = if n >= 0 {
                let m = 10f64.powi(n.min(400) as i32);
                let scaled = f * m;
                if !scaled.is_finite() || !m.is_finite() {
                    *f
                } else {
                    scaled.round() / m
                }
            } else {
                let m = 10f64.powi(n.unsigned_abs().min(400) as i32);
                if !m.is_finite() {
                    0.0
                } else {
                    (f / m).round() * m
                }
            };
            finite(func, r)?
        }
        v => return Err(bad_arg(func, v)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn f(func: ScalarFunc, args: Vec<Value>) -> Result<Value> {
        call(func, args, &ExecContext::default())
    }

    #[test]
    fn rounding() {
        assert_eq!(
            round(&Value::Decimal(25, 1), 0).unwrap(),
            Value::Decimal(3, 0)
        );
        assert_eq!(
            round(&Value::Decimal(-25, 1), 0).unwrap(),
            Value::Decimal(-3, 0)
        );
        assert_eq!(
            round(&Value::Decimal(2345, 3), 2).unwrap(),
            Value::Decimal(235, 2)
        );
        assert_eq!(
            round(&Value::Decimal(12345678, 4), -2).unwrap(),
            Value::Decimal(1200, 0)
        );
        assert_eq!(round(&Value::Int(15), -1).unwrap(), Value::Int(20));
        assert_eq!(round(&Value::Int(-15), -1).unwrap(), Value::Int(-20));
        assert_eq!(round(&Value::Float(1.26), 1).unwrap(), Value::Float(1.3));
        assert_eq!(round(&Value::Int(7), -30).unwrap(), Value::Int(0));
        assert_eq!(
            round(&Value::Int(i64::MAX), -19).unwrap_err().code,
            ErrorCode::NumericOverflow
        );
    }

    #[test]
    fn strings() {
        let s = |v: &str| Value::str(v);
        assert_eq!(
            f(
                ScalarFunc::Substr,
                vec![s("hello"), Value::Int(0), Value::Int(2)]
            )
            .unwrap(),
            s("h")
        );
        assert_eq!(
            f(
                ScalarFunc::Substr,
                vec![s("héllo"), Value::Int(2), Value::Int(2)]
            )
            .unwrap(),
            s("él")
        );
        assert_eq!(
            f(
                ScalarFunc::Substr,
                vec![s("abc"), Value::Int(1), Value::Int(-1)]
            )
            .unwrap_err()
            .code,
            ErrorCode::InvalidArgument
        );
        assert_eq!(
            f(ScalarFunc::Replace, vec![s("aaa"), s("aa"), s("b")]).unwrap(),
            s("ba")
        );
        assert_eq!(
            f(ScalarFunc::Upper, vec![s("abc Ünï")]).unwrap(),
            s("ABC Ünï")
        );
        assert_eq!(
            f(ScalarFunc::Lower, vec![s("ABC ÜNÏ")]).unwrap(),
            s("abc ÜNÏ")
        );
        assert_eq!(
            f(ScalarFunc::Upper, vec![s("a-b_c 1x")]).unwrap(),
            s("A-B_C 1X")
        );
        assert_eq!(
            f(ScalarFunc::Concat, vec![s("a"), Value::Null, Value::Int(1)]).unwrap(),
            s("a1")
        );
    }

    #[test]
    fn dates() {
        let ts = datetime::parse_timestamp("2024-07-04 10:11:12.5").unwrap();
        let trunc = |u| f(ScalarFunc::DateTrunc(u), vec![Value::Timestamp(ts)]).unwrap();
        assert_eq!(
            trunc(TruncUnit::Hour),
            Value::Timestamp(datetime::parse_timestamp("2024-07-04 10:00:00").unwrap())
        );
        assert_eq!(
            trunc(TruncUnit::Year),
            Value::Timestamp(datetime::parse_timestamp("2024-01-01 00:00:00").unwrap())
        );
        assert_eq!(
            f(ScalarFunc::Second, vec![Value::Timestamp(ts)]).unwrap(),
            Value::Int(12)
        );
        let d = |s| Value::Date(datetime::parse_date(s).unwrap());
        assert_eq!(
            f(
                ScalarFunc::DateDiffDays,
                vec![d("2024-03-01"), d("2024-01-01")]
            )
            .unwrap(),
            Value::Int(-60)
        );
    }

    #[test]
    fn numeric_errors() {
        assert_eq!(
            f(ScalarFunc::Sqrt, vec![Value::Int(-1)]).unwrap_err().code,
            ErrorCode::InvalidArgument
        );
        assert_eq!(
            f(ScalarFunc::Power, vec![Value::Int(0), Value::Int(-1)])
                .unwrap_err()
                .code,
            ErrorCode::DivisionByZero
        );
        assert_eq!(
            f(ScalarFunc::Power, vec![Value::Int(10), Value::Int(400)])
                .unwrap_err()
                .code,
            ErrorCode::NumericOverflow
        );
        assert_eq!(
            f(ScalarFunc::Abs, vec![Value::Int(i64::MIN)])
                .unwrap_err()
                .code,
            ErrorCode::NumericOverflow
        );
        assert_eq!(
            f(ScalarFunc::Floor, vec![Value::Decimal(-27, 1)]).unwrap(),
            Value::Decimal(-3, 0)
        );
        assert_eq!(
            f(ScalarFunc::Ceil, vec![Value::Decimal(-21, 1)]).unwrap(),
            Value::Decimal(-2, 0)
        );
    }
}
