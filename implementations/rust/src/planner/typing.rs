//! Static typing rules: numeric promotion, comparability, common types
//! (types.md §2–§5, semantics.md §13).

use super::expr::{ArithKind, Expr};
use crate::error::{Error, Result};
use crate::sql::ast::BinaryOp;
use crate::types::{DataType, MAX_DECIMAL_PRECISION};

fn decimal_scale(t: DataType) -> u8 {
    match t {
        DataType::Decimal { scale, .. } => scale,
        _ => 0,
    }
}

/// Result type and evaluation domain of an arithmetic operator (types.md §4).
pub fn arithmetic_type(op: BinaryOp, l: DataType, r: DataType) -> Result<(DataType, ArithKind)> {
    let (l, r) = match (l, r) {
        (DataType::Null, DataType::Null) => return Ok((DataType::Null, ArithKind::Int)),
        (DataType::Null, t) | (t, DataType::Null) => (t, t),
        other => other,
    };
    if !l.is_numeric() || !r.is_numeric() {
        return Err(Error::type_error(format!(
            "operator {} requires numeric operands, got {l} and {r}",
            op.symbol()
        )));
    }
    let any_float = l == DataType::Float64 || r == DataType::Float64;
    let both_int = l == DataType::Int64 && r == DataType::Int64;
    Ok(match op {
        BinaryOp::Mod => {
            if both_int {
                (DataType::Int64, ArithKind::Int)
            } else {
                return Err(Error::type_error("operator % requires INT64 operands"));
            }
        }
        _ if both_int => (DataType::Int64, ArithKind::Int),
        _ if any_float => (DataType::Float64, ArithKind::Float),
        BinaryOp::Div => (DataType::Float64, ArithKind::Float),
        BinaryOp::Mul => {
            let s = decimal_scale(l) + decimal_scale(r);
            if s > MAX_DECIMAL_PRECISION {
                return Err(Error::type_error(format!(
                    "DECIMAL product scale {s} exceeds 18"
                )));
            }
            (DataType::decimal(18, s), ArithKind::Decimal)
        }
        _ => (
            DataType::decimal(18, decimal_scale(l).max(decimal_scale(r))),
            ArithKind::Decimal,
        ),
    })
}

/// Whether two types may be compared (types.md §2, §5).
pub fn comparable(l: DataType, r: DataType) -> bool {
    l == DataType::Null
        || r == DataType::Null
        || (l.is_numeric() && r.is_numeric())
        || (l.is_temporal() && r.is_temporal())
        || l == r
}

/// Fails with TYPE_ERROR unless `l` and `r` are comparable.
pub fn check_comparable(l: DataType, r: DataType) -> Result<()> {
    if comparable(l, r) {
        Ok(())
    } else {
        Err(Error::type_error(format!("cannot compare {l} with {r}")))
    }
}

pub fn is_boolean(t: DataType) -> bool {
    t == DataType::Boolean || t == DataType::Null
}

/// Fails with TYPE_ERROR unless `t` is BOOLEAN (or the null type).
pub fn check_boolean(t: DataType, what: &str) -> Result<()> {
    if is_boolean(t) {
        Ok(())
    } else {
        Err(Error::type_error(format!(
            "{what} must be BOOLEAN, got {t}"
        )))
    }
}

/// Common type of CASE branches / COALESCE arguments (semantics.md §13):
/// numeric promotion, otherwise all non-NULL types must be equal.
pub fn common_type(types: &[DataType]) -> Result<DataType> {
    let mut result = DataType::Null;
    for &t in types {
        result = match (result, t) {
            (DataType::Null, t) | (t, DataType::Null) => t,
            (a, b) if a == b => a,
            (a, b) if a.is_numeric() && b.is_numeric() => {
                if a == DataType::Float64 || b == DataType::Float64 {
                    DataType::Float64
                } else {
                    DataType::decimal(18, decimal_scale(a).max(decimal_scale(b)))
                }
            }
            (a, b) => {
                return Err(Error::type_error(format!(
                    "incompatible types {a} and {b} (no common type)"
                )));
            }
        };
    }
    Ok(result)
}

/// Converts `e` to type `to` if its static type differs (and is not NULL).
pub fn coerce(e: Expr, to: DataType) -> Expr {
    let t = e.data_type();
    if t == to || t == DataType::Null {
        e
    } else {
        Expr::Cast {
            expr: Box::new(e),
            to,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arithmetic_typing() {
        let d = |p, s| DataType::decimal(p, s);
        let t = |op, l, r| arithmetic_type(op, l, r).unwrap().0;
        assert_eq!(t(BinaryOp::Mul, d(3, 2), d(2, 1)), d(18, 3));
        assert_eq!(t(BinaryOp::Mul, d(2, 1), DataType::Int64), d(18, 1));
        assert_eq!(
            t(BinaryOp::Div, d(4, 2), DataType::Int64),
            DataType::Float64
        );
        assert!(arithmetic_type(BinaryOp::Mod, d(2, 1), DataType::Int64).is_err());
        assert_eq!(
            t(BinaryOp::Div, DataType::Null, DataType::Int64),
            DataType::Int64
        );
        assert!(arithmetic_type(BinaryOp::Add, DataType::Date, DataType::Int64).is_err());
    }

    #[test]
    fn common_types() {
        let d = |p, s| DataType::decimal(p, s);
        assert_eq!(common_type(&[DataType::Int64, d(2, 1)]).unwrap(), d(18, 1));
        assert_eq!(
            common_type(&[DataType::Null, DataType::Int64, DataType::Float64]).unwrap(),
            DataType::Float64
        );
        assert_eq!(common_type(&[d(4, 2), d(4, 2)]).unwrap(), d(4, 2));
        assert_eq!(common_type(&[DataType::Null]).unwrap(), DataType::Null);
        assert!(common_type(&[DataType::Int64, DataType::String]).is_err());
        assert!(common_type(&[DataType::Date, DataType::Timestamp]).is_err());
    }
}
