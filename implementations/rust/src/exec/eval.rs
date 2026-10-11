//! Row-at-a-time evaluation of bound expressions.

use std::cmp::Ordering;

use super::context::ExecContext;
use super::{functions, subquery};
use crate::error::{Error, ErrorCode, Result};
use crate::planner::expr::{ArithKind, Expr, KeyDomain};
use crate::sql::ast::BinaryOp;
use crate::types::cast::cast_value;
use crate::types::value::promote_int;
use crate::types::{Value, datetime, decimal, float};

/// Evaluates an expression that references no columns.
pub fn eval_constant(e: &Expr) -> Result<Value> {
    eval(e, &[], &ExecContext::default())
}

fn bool_value(b: Option<bool>) -> Value {
    b.map_or(Value::Null, Value::Bool)
}

fn truth(v: &Value) -> Option<bool> {
    match v {
        Value::Bool(b) => Some(*b),
        _ => None,
    }
}

/// Three-valued negation.
fn not3(b: Option<bool>) -> Option<bool> {
    b.map(|b| !b)
}

/// Three-valued comparison of two values (None if either is NULL).
pub fn compare3(op: BinaryOp, l: &Value, r: &Value) -> Result<Option<bool>> {
    if l.is_null() || r.is_null() {
        return Ok(None);
    }
    Ok(Some(compare_op(op, l.compare(r)?)))
}

/// Normalizes a non-null value for hashing in comparison domain `domain`, so
/// that values equal under SQL comparison hash and compare equal.
pub fn normalize_key(v: Value, domain: KeyDomain) -> Value {
    match (domain, &v) {
        (KeyDomain::Decimal, Value::Int(i)) => Value::Decimal(*i, 0),
        (KeyDomain::Float, Value::Int(_) | Value::Decimal(..)) => {
            Value::Float(float::normalize(v.to_f64().unwrap_or(0.0)))
        }
        (KeyDomain::Timestamp, Value::Date(d)) => Value::Timestamp(datetime::date_to_timestamp(*d)),
        _ => v,
    }
}

/// `%` / `_` pattern matching over code points (semantics.md §11).
pub fn like_match(s: &str, pattern: &str) -> bool {
    let s: Vec<char> = s.chars().collect();
    let p: Vec<char> = pattern.chars().collect();
    let (mut i, mut j) = (0usize, 0usize);
    // Position of the last '%' in the pattern and the text index it matched up to.
    let mut star: Option<(usize, usize)> = None;
    while i < s.len() {
        if j < p.len() && (p[j] == '_' || (p[j] != '%' && p[j] == s[i])) {
            i += 1;
            j += 1;
        } else if j < p.len() && p[j] == '%' {
            star = Some((j, i));
            j += 1;
        } else if let Some((sj, si)) = star {
            j = sj + 1;
            i = si + 1;
            star = Some((sj, si + 1));
        } else {
            return false;
        }
    }
    p[j..].iter().all(|&c| c == '%')
}

/// Evaluates `e` against one input row.
pub fn eval(e: &Expr, row: &[Value], ctx: &ExecContext) -> Result<Value> {
    Ok(match e {
        Expr::Literal { value, .. } => value.clone(),
        Expr::Column { index, .. } => row[*index].clone(),
        Expr::Param { index, .. } => ctx.param(*index)?,
        Expr::AggRef { .. } => return Err(Error::internal("unresolved aggregate reference")),
        Expr::Negate { expr, .. } => match eval(expr, row, ctx)? {
            Value::Null => Value::Null,
            Value::Int(i) => Value::Int(
                i.checked_neg()
                    .ok_or_else(|| Error::overflow("integer overflow in negation"))?,
            ),
            Value::Float(f) => Value::Float(float::normalize(-f)),
            Value::Decimal(u, s) => Value::Decimal(-u, s),
            v => return Err(Error::internal(format!("cannot negate {v:?}"))),
        },
        Expr::Not(inner) => bool_value(not3(truth(&eval(inner, row, ctx)?))),
        Expr::And(l, r) => {
            let lv = match eval(l, row, ctx) {
                Ok(v) => v,
                Err(e) => return decided_by(r, false, e, row, ctx),
            };
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
            let lv = match eval(l, row, ctx) {
                Ok(v) => v,
                Err(e) => return decided_by(r, true, e, row, ctx),
            };
            if let Value::Bool(true) = lv {
                return Ok(Value::Bool(true));
            }
            match (lv, eval(r, row, ctx)?) {
                (_, Value::Bool(true)) => Value::Bool(true),
                (Value::Bool(false), Value::Bool(false)) => Value::Bool(false),
                _ => Value::Null,
            }
        }
        Expr::Arith {
            op,
            kind,
            left,
            right,
            ..
        } => {
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
            bool_value(compare3(*op, &l, &r)?)
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
            functions::call(*func, vals, ctx)?
        }
        Expr::Case {
            operand,
            whens,
            else_expr,
            ..
        } => {
            let subject = match operand {
                Some(o) => Some(eval(o, row, ctx)?),
                None => None,
            };
            for (w, t) in whens {
                let c = eval(w, row, ctx)?;
                let hit = match &subject {
                    Some(s) => compare3(BinaryOp::Eq, s, &c)? == Some(true),
                    None => truth(&c) == Some(true),
                };
                if hit {
                    return eval(t, row, ctx);
                }
            }
            match else_expr {
                Some(e) => eval(e, row, ctx)?,
                None => Value::Null,
            }
        }
        Expr::Between {
            expr,
            low,
            high,
            negated,
        } => {
            let x = eval(expr, row, ctx)?;
            let ge = compare3(BinaryOp::GtEq, &x, &eval(low, row, ctx)?)?;
            let le = compare3(BinaryOp::LtEq, &x, &eval(high, row, ctx)?)?;
            let r = match (ge, le) {
                (Some(false), _) | (_, Some(false)) => Some(false),
                (Some(true), Some(true)) => Some(true),
                _ => None,
            };
            bool_value(if *negated { not3(r) } else { r })
        }
        Expr::InList {
            expr,
            list,
            negated,
        } => {
            let x = eval(expr, row, ctx)?;
            let mut r = Some(false);
            for item in list {
                match compare3(BinaryOp::Eq, &x, &eval(item, row, ctx)?)? {
                    Some(true) => {
                        r = Some(true);
                        break;
                    }
                    Some(false) => {}
                    None => r = None,
                }
            }
            bool_value(if *negated { not3(r) } else { r })
        }
        Expr::Like {
            expr,
            pattern,
            negated,
        } => match (eval(expr, row, ctx)?, eval(pattern, row, ctx)?) {
            (Value::Str(s), Value::Str(p)) => Value::Bool(like_match(&s, &p) != *negated),
            _ => Value::Null,
        },
        Expr::ScalarSubquery { sub, params, .. } => subquery::scalar(sub, params, row, ctx)?,
        Expr::Exists { sub, params } => Value::Bool(subquery::exists(sub, params, row, ctx)?),
        Expr::InSubquery {
            expr,
            sub,
            params,
            negated,
            domain,
        } => {
            let x = eval(expr, row, ctx)?;
            let r = subquery::in_subquery(&x, sub, params, *domain, row, ctx)?;
            bool_value(if *negated { not3(r) } else { r })
        }
    })
}

/// The left operand of `AND` (`decisive = false`) or `OR` (`decisive =
/// true`) failed with `err`. The operators are commutative, so the error is
/// only raised if the right operand does not decide the result on its own;
/// evaluation order (and hence plan shape, e.g. predicate pushdown) then
/// does not change whether a query fails. Interruptions and resource limits
/// are always raised.
fn decided_by(
    r: &Expr,
    decisive: bool,
    err: Error,
    row: &[Value],
    ctx: &ExecContext,
) -> Result<Value> {
    let data_error = matches!(
        err.code,
        ErrorCode::NumericOverflow
            | ErrorCode::DivisionByZero
            | ErrorCode::ConversionError
            | ErrorCode::InvalidArgument
            | ErrorCode::SubqueryCardinality
    );
    if data_error
        && let Ok(Value::Bool(b)) = eval(r, row, ctx)
        && b == decisive
    {
        return Ok(Value::Bool(decisive));
    }
    Err(err)
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
        _ => Err(Error::internal(format!(
            "expected a decimal operand, got {v:?}"
        ))),
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
            let a = l
                .to_f64()
                .ok_or_else(|| Error::internal("expected numeric operand"))?;
            let b = r
                .to_f64()
                .ok_or_else(|| Error::internal("expected numeric operand"))?;
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
        assert_eq!(
            a(BinaryOp::Div, i64::MIN, -1).unwrap_err().code,
            ErrorCode::NumericOverflow
        );
        assert_eq!(
            a(BinaryOp::Div, 1, 0).unwrap_err().code,
            ErrorCode::DivisionByZero
        );
    }

    #[test]
    fn decimal_semantics() {
        let d = |op, l: Value, r: Value| arithmetic(op, ArithKind::Decimal, &l, &r).unwrap();
        assert_eq!(
            d(BinaryOp::Add, Value::Decimal(125, 2), Value::Decimal(25, 1)),
            Value::Decimal(375, 2)
        );
        assert_eq!(
            d(BinaryOp::Mul, Value::Decimal(125, 2), Value::Decimal(25, 1)),
            Value::Decimal(3125, 3)
        );
        assert_eq!(
            d(BinaryOp::Sub, Value::Int(2), Value::Decimal(75, 2)),
            Value::Decimal(125, 2)
        );
        let e = arithmetic(
            BinaryOp::Add,
            ArithKind::Decimal,
            &Value::Decimal(999_999_999_999_999_999, 1),
            &Value::Decimal(1, 1),
        );
        assert_eq!(e.unwrap_err().code, ErrorCode::NumericOverflow);
    }

    #[test]
    fn like_patterns() {
        assert!(like_match("abc", "a%"));
        assert!(like_match("abc", "%c"));
        assert!(like_match("abc", "a_c"));
        assert!(!like_match("ac", "a_c"));
        assert!(like_match("", "%"));
        assert!(like_match("éa", "_a"));
        assert!(!like_match("abc", "b"));
        assert!(like_match("aXbXc", "%b%c"));
        assert!(like_match("mississippi", "%iss%ppi"));
        assert!(!like_match("abc", "ABC"));
    }

    #[test]
    fn key_normalization() {
        assert_eq!(
            normalize_key(Value::Int(1), KeyDomain::Decimal),
            Value::Decimal(10, 1)
        );
        assert_eq!(
            normalize_key(Value::Decimal(15, 1), KeyDomain::Float),
            Value::Float(1.5)
        );
    }

    #[test]
    fn and_or_errors_are_order_independent() {
        let ty = crate::types::DataType::Int64;
        let lit = |v: Value| Box::new(Expr::Literal { value: v, ty });
        let div0 = Box::new(Expr::Compare {
            op: BinaryOp::Gt,
            left: Box::new(Expr::Arith {
                op: BinaryOp::Div,
                kind: ArithKind::Int,
                left: lit(Value::Int(1)),
                right: lit(Value::Int(0)),
                ty,
            }),
            right: lit(Value::Int(0)),
        });
        let ctx = ExecContext::default();
        let f = Box::new(Expr::Literal {
            value: Value::Bool(false),
            ty: crate::types::DataType::Boolean,
        });
        let t = Box::new(Expr::Literal {
            value: Value::Bool(true),
            ty: crate::types::DataType::Boolean,
        });
        // The other operand decides: no error, in either order.
        assert_eq!(
            eval(&Expr::And(div0.clone(), f.clone()), &[], &ctx).unwrap(),
            Value::Bool(false)
        );
        assert_eq!(
            eval(&Expr::And(f, div0.clone()), &[], &ctx).unwrap(),
            Value::Bool(false)
        );
        assert_eq!(
            eval(&Expr::Or(div0.clone(), t.clone()), &[], &ctx).unwrap(),
            Value::Bool(true)
        );
        // Otherwise the error is raised.
        let e = eval(&Expr::And(div0, t), &[], &ctx).unwrap_err();
        assert_eq!(e.code, ErrorCode::DivisionByZero);
    }

    #[test]
    fn float_semantics() {
        let f = |op, x: f64, y: f64| {
            arithmetic(op, ArithKind::Float, &Value::Float(x), &Value::Float(y))
        };
        assert_eq!(
            f(BinaryOp::Div, 0.0, 0.0).unwrap_err().code,
            ErrorCode::DivisionByZero
        );
        assert_eq!(
            f(BinaryOp::Mul, 1e308, 10.0).unwrap_err().code,
            ErrorCode::NumericOverflow
        );
    }
}
