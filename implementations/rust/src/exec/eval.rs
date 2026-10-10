//! Row-at-a-time evaluation of bound expressions.

use std::cmp::Ordering;
use std::time::Duration;

use super::context::ExecContext;
use crate::error::{Error, Result};
use crate::planner::expr::{ArithKind, Expr, ScalarFunc};
use crate::sql::ast::BinaryOp;
use crate::types::cast::cast_value;
use crate::types::value::promote_int;
use crate::types::{Value, decimal, float};

/// Evaluates an expression that references no columns.
pub fn eval_constant(e: &Expr) -> Result<Value> {
    eval(e, &[], &ExecContext::default())
}

/// Evaluates `e` against one input row.
pub fn eval(e: &Expr, row: &[Value], ctx: &ExecContext) -> Result<Value> {
    Ok(match e {
        Expr::Literal { value, .. } => value.clone(),
        Expr::Column { index, .. } => row[*index].clone(),
        Expr::Negate { expr, .. } => match eval(expr, row, ctx)? {
            Value::Null => Value::Null,
            Value::Int(i) => Value::Int(i.checked_neg().ok_or_else(|| Error::overflow("integer overflow in negation"))?),
            Value::Float(f) => Value::Float(float::normalize(-f)),
            Value::Decimal(u, s) => Value::Decimal(-u, s),
            v => return Err(Error::internal(format!("cannot negate {v:?}"))),
        },
        Expr::Not(inner) => match eval(inner, row, ctx)? {
            Value::Bool(b) => Value::Bool(!b),
            _ => Value::Null,
        },
        Expr::And(l, r) => {
            let lv = eval(l, row, ctx)?;
            if let Value::Bool(false) = lv {
                return Ok(Value::Bool(false));
            }
            match (lv, eval(r, row, ctx)?) {
                (_, Value::Bool(false)) => Value::Bool(false),
                (Value::Bool(true), Value::Bool(true)) => Value::Bool(true),
                _ => Value::Null,
            }
        }
        Expr::Or(l, r) => {
            let lv = eval(l, row, ctx)?;
            if let Value::Bool(true) = lv {
                return Ok(Value::Bool(true));
            }
            match (lv, eval(r, row, ctx)?) {
                (_, Value::Bool(true)) => Value::Bool(true),
                (Value::Bool(false), Value::Bool(false)) => Value::Bool(false),
                _ => Value::Null,
            }
        }
        Expr::Arith { op, kind, left, right, .. } => {
            let l = eval(left, row, ctx)?;
            let r = eval(right, row, ctx)?;
            if l.is_null() || r.is_null() {
                return Ok(Value::Null);
            }
            arithmetic(*op, *kind, &l, &r)?
        }
        Expr::Compare { op, left, right } => {
            let l = eval(left, row, ctx)?;
            let r = eval(right, row, ctx)?;
            if l.is_null() || r.is_null() {
                return Ok(Value::Null);
            }
            Value::Bool(compare_op(*op, l.compare(&r)?))
        }
        Expr::Concat(l, r) => match (eval(l, row, ctx)?, eval(r, row, ctx)?) {
            (Value::Str(a), Value::Str(b)) => {
                let mut s = String::with_capacity(a.len() + b.len());
                s.push_str(&a);
                s.push_str(&b);
                Value::str(&s)
            }
            _ => Value::Null,
        },
        Expr::IsNull { expr, negated } => Value::Bool(eval(expr, row, ctx)?.is_null() != *negated),
        Expr::Cast { expr, to } => cast_value(&eval(expr, row, ctx)?, *to)?,
        Expr::Function { func, args, .. } => {
            let mut vals = Vec::with_capacity(args.len());
            for a in args {
                vals.push(eval(a, row, ctx)?);
            }
            call_scalar(*func, &vals, ctx)?
        }
    })
}

/// Truth value of a predicate (NULL counts as not true).
pub fn eval_predicate(e: &Expr, row: &[Value], ctx: &ExecContext) -> Result<bool> {
    Ok(matches!(eval(e, row, ctx)?, Value::Bool(true)))
}

pub fn compare_op(op: BinaryOp, ord: Ordering) -> bool {
    match op {
        BinaryOp::Eq => ord == Ordering::Equal,
        BinaryOp::NotEq => ord != Ordering::Equal,
        BinaryOp::Lt => ord == Ordering::Less,
        BinaryOp::LtEq => ord != Ordering::Greater,
        BinaryOp::Gt => ord == Ordering::Greater,
        BinaryOp::GtEq => ord != Ordering::Less,
        _ => false,
    }
}

/// Decimal operand as (unscaled, scale); INT64 is promoted to DECIMAL(18,0).
fn as_decimal(v: &Value) -> Result<(i128, u8)> {
    match v {
        Value::Decimal(u, s) => Ok((*u as i128, *s)),
        Value::Int(i) => Ok((promote_int(*i, 0)?, 0)),
        _ => Err(Error::internal(format!("expected a decimal operand, got {v:?}"))),
    }
}

/// Applies a binary arithmetic operator to two non-null values.
pub fn arithmetic(op: BinaryOp, kind: ArithKind, l: &Value, r: &Value) -> Result<Value> {
    let overflow = || Error::overflow(format!("numeric overflow in operator {}", op.symbol()));
    match kind {
        ArithKind::Int => {
            let (Value::Int(a), Value::Int(b)) = (l, r) else {
                return Err(Error::internal("expected INT64 operands"));
            };
            let (a, b) = (*a, *b);
            Ok(Value::Int(match op {
                BinaryOp::Add => a.checked_add(b).ok_or_else(overflow)?,
                BinaryOp::Sub => a.checked_sub(b).ok_or_else(overflow)?,
                BinaryOp::Mul => a.checked_mul(b).ok_or_else(overflow)?,
                BinaryOp::Div => {
                    if b == 0 {
                        return Err(Error::division_by_zero());
                    }
                    a.checked_div(b).ok_or_else(overflow)?
                }
                BinaryOp::Mod => {
                    if b == 0 {
                        return Err(Error::division_by_zero());
                    }
                    a.checked_rem(b).unwrap_or(0)
                }
                _ => return Err(Error::internal("invalid arithmetic operator")),
            }))
        }
        ArithKind::Decimal => {
            let (a, sa) = as_decimal(l)?;
            let (b, sb) = as_decimal(r)?;
            let (v, s) = match op {
                BinaryOp::Add | BinaryOp::Sub => {
                    let s = sa.max(sb);
                    let a = a * decimal::pow10((s - sa) as u32);
                    let b = b * decimal::pow10((s - sb) as u32);
                    (if op == BinaryOp::Add { a + b } else { a - b }, s)
                }
                BinaryOp::Mul => (a * b, sa + sb),
                _ => return Err(Error::internal("invalid decimal operator")),
            };
            if !decimal::fits18(v) {
                return Err(overflow());
            }
            Ok(Value::Decimal(v as i64, s))
        }
        ArithKind::Float => {
            let a = l.to_f64().ok_or_else(|| Error::internal("expected numeric operand"))?;
            let b = r.to_f64().ok_or_else(|| Error::internal("expected numeric operand"))?;
            let v = match op {
                BinaryOp::Add => a + b,
                BinaryOp::Sub => a - b,
                BinaryOp::Mul => a * b,
                BinaryOp::Div => {
                    if b == 0.0 {
                        return Err(Error::division_by_zero());
                    }
                    a / b
                }
                _ => return Err(Error::internal("invalid float operator")),
            };
            if !v.is_finite() {
                return Err(overflow());
            }
            Ok(Value::Float(float::normalize(v)))
        }
    }
}

fn call_scalar(func: ScalarFunc, args: &[Value], ctx: &ExecContext) -> Result<Value> {
    match func {
        ScalarFunc::PqSleep => match &args[0] {
            Value::Null => Ok(Value::Null),
            Value::Int(ms) => {
                if !ctx.test_functions {
                    return Err(Error::semantic("PQ_SLEEP requires --enable-test-functions"));
                }
                if *ms < 0 {
                    return Err(Error::invalid_argument("PQ_SLEEP duration must not be negative"));
                }
                ctx.sleep(Duration::from_millis(*ms as u64))?;
                Ok(Value::Int(*ms))
            }
            v => Err(Error::internal(format!("PQ_SLEEP argument {v:?}"))),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    #[test]
    fn integer_semantics() {
        let a = |op, x, y| arithmetic(op, ArithKind::Int, &Value::Int(x), &Value::Int(y));
        assert_eq!(a(BinaryOp::Div, -7, 2).unwrap(), Value::Int(-3));
        assert_eq!(a(BinaryOp::Mod, -7, 3).unwrap(), Value::Int(-1));
        assert_eq!(a(BinaryOp::Mod, 7, -3).unwrap(), Value::Int(1));
        assert_eq!(a(BinaryOp::Mod, i64::MIN, -1).unwrap(), Value::Int(0));
        assert_eq!(a(BinaryOp::Div, i64::MIN, -1).unwrap_err().code, ErrorCode::NumericOverflow);
        assert_eq!(a(BinaryOp::Div, 1, 0).unwrap_err().code, ErrorCode::DivisionByZero);
    }

    #[test]
    fn decimal_semantics() {
        let d = |op, l: Value, r: Value| arithmetic(op, ArithKind::Decimal, &l, &r).unwrap();
        assert_eq!(d(BinaryOp::Add, Value::Decimal(125, 2), Value::Decimal(25, 1)), Value::Decimal(375, 2));
        assert_eq!(d(BinaryOp::Mul, Value::Decimal(125, 2), Value::Decimal(25, 1)), Value::Decimal(3125, 3));
        assert_eq!(d(BinaryOp::Sub, Value::Int(2), Value::Decimal(75, 2)), Value::Decimal(125, 2));
        let e = arithmetic(BinaryOp::Add, ArithKind::Decimal, &Value::Decimal(999_999_999_999_999_999, 1), &Value::Decimal(1, 1));
        assert_eq!(e.unwrap_err().code, ErrorCode::NumericOverflow);
    }

    #[test]
    fn float_semantics() {
        let f = |op, x: f64, y: f64| arithmetic(op, ArithKind::Float, &Value::Float(x), &Value::Float(y));
        assert_eq!(f(BinaryOp::Div, 0.0, 0.0).unwrap_err().code, ErrorCode::DivisionByZero);
        assert_eq!(f(BinaryOp::Mul, 1e308, 10.0).unwrap_err().code, ErrorCode::NumericOverflow);
    }
}
