//! Aggregate accumulators (functions.md §2).

use std::collections::HashSet;

use crate::error::{Error, Result};
use crate::planner::expr::{AggFunc, AggregateCall};
use crate::types::{DataType, Value, decimal};

#[derive(Debug, Clone)]
enum Acc {
    Count(i64),
    /// Exact integer sum (INT64 input).
    SumInt(i128),
    /// Exact unscaled sum at the result scale (DECIMAL input).
    SumDecimal(i128),
    SumFloat(f64),
    Min(Option<Value>),
    Max(Option<Value>),
}

/// Running state of one aggregate within one group.
#[derive(Debug, Clone)]
pub struct AggState {
    func: AggFunc,
    acc: Acc,
    /// Number of non-null inputs accumulated.
    count: i64,
    /// Scale of DECIMAL input (sum/avg).
    scale: u8,
    distinct: Option<HashSet<Value>>,
}

impl AggState {
    pub fn new(call: &AggregateCall) -> AggState {
        let input_ty = call
            .arg
            .as_ref()
            .map(|a| a.data_type())
            .unwrap_or(DataType::Null);
        let scale = match input_ty {
            DataType::Decimal { scale, .. } => scale,
            _ => 0,
        };
        let acc = match call.func {
            AggFunc::CountStar | AggFunc::Count => Acc::Count(0),
            AggFunc::Sum | AggFunc::Avg => match input_ty {
                DataType::Float64 => Acc::SumFloat(0.0),
                DataType::Decimal { .. } => Acc::SumDecimal(0),
                _ => Acc::SumInt(0),
            },
            AggFunc::Min => Acc::Min(None),
            AggFunc::Max => Acc::Max(None),
        };
        let distinct = if call.distinct {
            Some(HashSet::new())
        } else {
            None
        };
        AggState {
            func: call.func,
            acc,
            count: 0,
            scale,
            distinct,
        }
    }

    /// Adds one input value (`Value::Null` for COUNT(*) rows is fine).
    /// Returns the approximate number of bytes newly retained.
    pub fn update(&mut self, v: &Value) -> Result<usize> {
        if let Acc::Count(n) = &mut self.acc
            && self.func == AggFunc::CountStar
        {
            *n += 1;
            return Ok(0);
        }
        if v.is_null() {
            return Ok(0);
        }
        let mut retained = 0;
        if let Some(set) = &mut self.distinct {
            if !set.insert(v.clone()) {
                return Ok(0);
            }
            retained = v.approx_size() + 16;
        }
        self.count += 1;
        match &mut self.acc {
            Acc::Count(n) => *n += 1,
            Acc::SumInt(s) => match v {
                Value::Int(i) => *s += *i as i128,
                _ => return Err(Error::internal("SUM over non-integer value")),
            },
            Acc::SumDecimal(s) => match v {
                Value::Decimal(u, vs) => {
                    *s += decimal::rescale(*u as i128, *vs, self.scale).unwrap_or(*u as i128);
                }
                Value::Int(i) => *s += *i as i128 * decimal::pow10(self.scale as u32),
                _ => return Err(Error::internal("SUM over non-decimal value")),
            },
            Acc::SumFloat(s) => *s += v.to_f64().unwrap_or(0.0),
            Acc::Min(m) => {
                if m.as_ref().is_none_or(|cur| v.sort_cmp(cur).is_lt()) {
                    *m = Some(v.clone());
                }
            }
            Acc::Max(m) => {
                if m.as_ref().is_none_or(|cur| v.sort_cmp(cur).is_gt()) {
                    *m = Some(v.clone());
                }
            }
        }
        Ok(retained)
    }

    /// Final aggregate value.
    pub fn finish(&self) -> Result<Value> {
        let overflow = || Error::overflow(format!("{} result is out of range", self.func.name()));
        if let Acc::Count(n) = self.acc {
            return Ok(Value::Int(n));
        }
        if self.count == 0 {
            return Ok(Value::Null);
        }
        let n = self.count as f64;
        Ok(match (&self.acc, self.func) {
            (Acc::SumInt(s), AggFunc::Avg) => Value::Float(*s as f64 / n),
            (Acc::SumDecimal(s), AggFunc::Avg) => {
                Value::Float(*s as f64 / (decimal::pow10(self.scale as u32) as f64) / n)
            }
            (Acc::SumFloat(s), AggFunc::Avg) => {
                let v = s / n;
                if !v.is_finite() {
                    return Err(overflow());
                }
                Value::Float(v)
            }
            (Acc::SumInt(s), _) => Value::Int(i64::try_from(*s).map_err(|_| overflow())?),
            (Acc::SumDecimal(s), _) => {
                if !decimal::fits18(*s) {
                    return Err(overflow());
                }
                Value::Decimal(*s as i64, self.scale)
            }
            (Acc::SumFloat(s), _) => {
                if !s.is_finite() {
                    return Err(overflow());
                }
                Value::Float(*s)
            }
            (Acc::Min(m) | Acc::Max(m), _) => m.clone().unwrap_or(Value::Null),
            (Acc::Count(_), _) => unreachable!(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;
    use crate::planner::expr::Expr;

    fn call(func: AggFunc, ty: DataType, distinct: bool) -> AggregateCall {
        AggregateCall {
            func,
            arg: Some(Expr::Column { index: 0, ty }),
            distinct,
            ty,
        }
    }

    #[test]
    fn exact_integer_sum() {
        let mut s = AggState::new(&call(AggFunc::Sum, DataType::Int64, false));
        for v in [i64::MAX, 1, -1, i64::MIN] {
            s.update(&Value::Int(v)).unwrap();
        }
        assert_eq!(s.finish().unwrap(), Value::Int(-1));
        let mut s = AggState::new(&call(AggFunc::Sum, DataType::Int64, false));
        s.update(&Value::Int(i64::MAX)).unwrap();
        s.update(&Value::Int(1)).unwrap();
        assert_eq!(s.finish().unwrap_err().code, ErrorCode::NumericOverflow);
    }

    #[test]
    fn decimal_avg_and_distinct_count() {
        let mut s = AggState::new(&call(AggFunc::Avg, DataType::decimal(10, 2), false));
        for u in [100, 200] {
            s.update(&Value::Decimal(u, 2)).unwrap();
        }
        assert_eq!(s.finish().unwrap(), Value::Float(1.5));
        let mut c = AggState::new(&call(AggFunc::Count, DataType::decimal(10, 2), true));
        for v in [
            Value::Decimal(150, 2),
            Value::Decimal(150, 2),
            Value::Null,
            Value::Decimal(1, 2),
        ] {
            c.update(&v).unwrap();
        }
        assert_eq!(c.finish().unwrap(), Value::Int(2));
    }

    #[test]
    fn empty_input() {
        let s = AggState::new(&call(AggFunc::Max, DataType::String, false));
        assert!(s.finish().unwrap().is_null());
    }
}
