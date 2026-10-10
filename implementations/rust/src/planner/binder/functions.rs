//! Function signatures and result types (functions.md).

use super::scope::ExprScope;
use super::{AggMode, Binder};
use crate::error::{Error, Result};
use crate::exec::eval::eval_constant;
use crate::planner::expr::{AggFunc, AggregateCall, Expr, ScalarFunc, TruncUnit};
use crate::planner::typing::{check_comparable, coerce, common_type};
use crate::sql::ast::{self, Ident};
use crate::types::{DataType, Value};

pub(super) fn is_aggregate(name: &str) -> bool {
    AggFunc::lookup(name).is_some()
}

/// Accepted argument counts of a scalar function (None = unknown function).
fn arity(name: &str, test_functions: bool) -> Option<(usize, usize)> {
    Some(match name {
        "ABS" | "FLOOR" | "CEIL" | "CEILING" | "SQRT" | "LENGTH" | "UPPER" | "LOWER" | "TRIM"
        | "LTRIM" | "RTRIM" | "YEAR" | "MONTH" | "DAY" | "HOUR" | "MINUTE" | "SECOND" => (1, 1),
        "ROUND" => (1, 2),
        "POWER" | "MOD" | "NULLIF" | "DATE_TRUNC" => (2, 2),
        "SUBSTR" | "SUBSTRING" => (2, 3),
        "REPLACE" | "DATE_DIFF" => (3, 3),
        "CONCAT" | "COALESCE" => (1, usize::MAX),
        "PQ_SLEEP" if test_functions => (1, 1),
        _ => return None,
    })
}

/// Checks that `t` is accepted by `pred` (the null type is always accepted).
fn expect(t: DataType, pred: fn(DataType) -> bool, func: &str, what: &str) -> Result<()> {
    if t == DataType::Null || pred(t) {
        Ok(())
    } else {
        Err(Error::type_error(format!(
            "{func} requires {what}, got {t}"
        )))
    }
}

fn is_string(t: DataType) -> bool {
    t == DataType::String
}

fn is_int(t: DataType) -> bool {
    t == DataType::Int64
}

fn is_numeric(t: DataType) -> bool {
    t.is_numeric()
}

fn is_temporal(t: DataType) -> bool {
    t.is_temporal()
}

fn is_timestamp(t: DataType) -> bool {
    t == DataType::Timestamp
}

/// Evaluates a constant argument (`ROUND`'s digits, date units).
fn constant_arg(e: &Expr, func: &str) -> Result<Value> {
    if !e.is_constant() {
        return Err(Error::semantic(format!(
            "{func}: argument must be a constant expression"
        )));
    }
    eval_constant(e)
}

/// The unit argument of DATE_TRUNC / DATE_DIFF (None if NULL).
fn unit_arg(e: &Expr, func: &str) -> Result<Option<String>> {
    expect(e.data_type(), is_string, func, "a STRING unit")?;
    match constant_arg(e, func)? {
        Value::Str(s) => Ok(Some(s.to_string())),
        _ => Ok(None),
    }
}

impl Binder<'_> {
    pub(super) fn function(
        &self,
        name: &Ident,
        args: &[ast::Expr],
        distinct: bool,
        star: bool,
        sc: &ExprScope<'_>,
        mode: &mut AggMode<'_>,
    ) -> Result<Expr> {
        if let Some(func) = AggFunc::lookup(&name.value) {
            return self.aggregate(func, args, distinct, star, sc, mode);
        }
        let upper = name.value.to_ascii_uppercase();
        let (min, max) = arity(&upper, self.ctx.test_functions)
            .ok_or_else(|| Error::semantic(format!("unknown function '{}'", name.value)))?;
        if star || distinct {
            return Err(Error::semantic(format!(
                "{upper} does not accept * or DISTINCT"
            )));
        }
        if args.len() < min || args.len() > max {
            return Err(Error::semantic(format!(
                "wrong number of arguments for {upper}: {}",
                args.len()
            )));
        }
        let mut bound = Vec::with_capacity(args.len());
        for a in args {
            bound.push(self.expr(a, sc, mode)?);
        }
        scalar(&upper, bound)
    }

    fn aggregate(
        &self,
        func: AggFunc,
        args: &[ast::Expr],
        distinct: bool,
        star: bool,
        sc: &ExprScope<'_>,
        mode: &mut AggMode<'_>,
    ) -> Result<Expr> {
        let aggs = match mode {
            AggMode::Forbidden(clause) => {
                return Err(Error::semantic(format!(
                    "aggregate function {} is not allowed in {clause}",
                    func.name()
                )));
            }
            AggMode::Inside => {
                return Err(Error::semantic("aggregate function calls cannot be nested"));
            }
            AggMode::Collect(aggs) => aggs,
        };
        let (func, arg) = if star {
            if func != AggFunc::Count {
                return Err(Error::semantic(format!(
                    "{}(*) is not allowed",
                    func.name()
                )));
            }
            (AggFunc::CountStar, None)
        } else {
            if args.len() != 1 {
                return Err(Error::semantic(format!(
                    "{} takes exactly one argument",
                    func.name()
                )));
            }
            let arg = self.expr(&args[0], sc, &mut AggMode::Inside)?;
            (func, Some(arg))
        };
        let arg_ty = arg.as_ref().map_or(DataType::Null, |a| a.data_type());
        let ty = match func {
            AggFunc::CountStar | AggFunc::Count => DataType::Int64,
            AggFunc::Sum => match arg_ty {
                DataType::Int64 | DataType::Null => DataType::Int64,
                DataType::Decimal { scale, .. } => DataType::decimal(18, scale),
                DataType::Float64 => DataType::Float64,
                t => {
                    return Err(Error::type_error(format!(
                        "SUM requires a numeric argument, got {t}"
                    )));
                }
            },
            AggFunc::Avg => {
                expect(arg_ty, is_numeric, "AVG", "a numeric argument")?;
                DataType::Float64
            }
            AggFunc::Min | AggFunc::Max => arg_ty,
        };
        let call = AggregateCall {
            func,
            arg,
            distinct: distinct && func != AggFunc::CountStar,
            ty,
        };
        let index = match aggs.iter().position(|a| *a == call) {
            Some(i) => i,
            None => {
                aggs.push(call);
                aggs.len() - 1
            }
        };
        Ok(Expr::AggRef { index, ty })
    }
}

/// Types a scalar function call whose arity has been checked.
fn scalar(name: &str, mut args: Vec<Expr>) -> Result<Expr> {
    let t: Vec<DataType> = args.iter().map(|a| a.data_type()).collect();
    let call = |func: ScalarFunc, args: Vec<Expr>, ty: DataType| Expr::Function { func, args, ty };
    Ok(match name {
        "ABS" => {
            expect(t[0], is_numeric, name, "a numeric argument")?;
            call(ScalarFunc::Abs, args, t[0])
        }
        "ROUND" => {
            expect(t[0], is_numeric, name, "a numeric argument")?;
            let digits = if args.len() == 2 {
                expect(t[1], is_int, name, "INT64 digits")?;
                match constant_arg(&args[1], name)? {
                    Value::Int(n) => Some(n),
                    _ => None,
                }
            } else {
                Some(0)
            };
            args.truncate(1);
            let ty = match t[0] {
                DataType::Decimal { scale, .. } => {
                    let n = digits.unwrap_or(0);
                    DataType::decimal(18, n.clamp(0, scale as i64) as u8)
                }
                other => other,
            };
            match digits {
                Some(n) => call(ScalarFunc::Round(n), args, ty),
                None => Expr::Literal {
                    value: Value::Null,
                    ty,
                },
            }
        }
        "FLOOR" | "CEIL" | "CEILING" => {
            expect(t[0], is_numeric, name, "a numeric argument")?;
            let ty = match t[0] {
                DataType::Decimal { .. } => DataType::decimal(18, 0),
                other => other,
            };
            let func = if name == "FLOOR" {
                ScalarFunc::Floor
            } else {
                ScalarFunc::Ceil
            };
            call(func, args, ty)
        }
        "SQRT" => {
            expect(t[0], is_numeric, name, "a numeric argument")?;
            call(ScalarFunc::Sqrt, args, DataType::Float64)
        }
        "POWER" => {
            expect(t[0], is_numeric, name, "numeric arguments")?;
            expect(t[1], is_numeric, name, "numeric arguments")?;
            call(ScalarFunc::Power, args, DataType::Float64)
        }
        "MOD" => {
            expect(t[0], is_int, name, "INT64 arguments")?;
            expect(t[1], is_int, name, "INT64 arguments")?;
            call(ScalarFunc::Mod, args, DataType::Int64)
        }
        "LENGTH" => {
            expect(t[0], is_string, name, "a STRING argument")?;
            call(ScalarFunc::Length, args, DataType::Int64)
        }
        "UPPER" | "LOWER" | "TRIM" | "LTRIM" | "RTRIM" => {
            expect(t[0], is_string, name, "a STRING argument")?;
            let func = match name {
                "UPPER" => ScalarFunc::Upper,
                "LOWER" => ScalarFunc::Lower,
                "TRIM" => ScalarFunc::Trim,
                "LTRIM" => ScalarFunc::Ltrim,
                _ => ScalarFunc::Rtrim,
            };
            call(func, args, DataType::String)
        }
        "SUBSTR" | "SUBSTRING" => {
            expect(t[0], is_string, name, "a STRING argument")?;
            for &ti in &t[1..] {
                expect(ti, is_int, name, "INT64 positions")?;
            }
            call(ScalarFunc::Substr, args, DataType::String)
        }
        "REPLACE" => {
            for &ti in &t {
                expect(ti, is_string, name, "STRING arguments")?;
            }
            call(ScalarFunc::Replace, args, DataType::String)
        }
        "CONCAT" => {
            if let Some(f) = t.iter().find(|ti| **ti == DataType::Float64) {
                return Err(Error::type_error(format!(
                    "CONCAT does not accept {f} arguments"
                )));
            }
            call(ScalarFunc::Concat, args, DataType::String)
        }
        "COALESCE" => {
            let ty = common_type(&t)?;
            let args = args.into_iter().map(|a| coerce(a, ty)).collect();
            call(ScalarFunc::Coalesce, args, ty)
        }
        "NULLIF" => {
            check_comparable(t[0], t[1])?;
            call(ScalarFunc::Nullif, args, t[0])
        }
        "YEAR" | "MONTH" | "DAY" => {
            expect(t[0], is_temporal, name, "a DATE or TIMESTAMP argument")?;
            let func = match name {
                "YEAR" => ScalarFunc::Year,
                "MONTH" => ScalarFunc::Month,
                _ => ScalarFunc::Day,
            };
            call(func, args, DataType::Int64)
        }
        "HOUR" | "MINUTE" | "SECOND" => {
            expect(t[0], is_timestamp, name, "a TIMESTAMP argument")?;
            let func = match name {
                "HOUR" => ScalarFunc::Hour,
                "MINUTE" => ScalarFunc::Minute,
                _ => ScalarFunc::Second,
            };
            call(func, args, DataType::Int64)
        }
        "DATE_TRUNC" => {
            expect(t[1], is_temporal, name, "a DATE or TIMESTAMP argument")?;
            let unit = unit_arg(&args[0], name)?;
            let arg = args.pop().expect("arity checked");
            match unit {
                None => Expr::Literal {
                    value: Value::Null,
                    ty: DataType::Timestamp,
                },
                Some(u) => {
                    let unit = TruncUnit::parse(&u).ok_or_else(|| {
                        Error::invalid_argument(format!("unknown DATE_TRUNC unit '{u}'"))
                    })?;
                    call(ScalarFunc::DateTrunc(unit), vec![arg], DataType::Timestamp)
                }
            }
        }
        "DATE_DIFF" => {
            expect(t[1], is_temporal, name, "DATE or TIMESTAMP arguments")?;
            expect(t[2], is_temporal, name, "DATE or TIMESTAMP arguments")?;
            let unit = unit_arg(&args[0], name)?;
            args.remove(0);
            match unit {
                None => Expr::Literal {
                    value: Value::Null,
                    ty: DataType::Int64,
                },
                Some(u) if u.eq_ignore_ascii_case("day") => {
                    call(ScalarFunc::DateDiffDays, args, DataType::Int64)
                }
                Some(u) => {
                    return Err(Error::invalid_argument(format!(
                        "unsupported DATE_DIFF unit '{u}'"
                    )));
                }
            }
        }
        "PQ_SLEEP" => {
            expect(t[0], is_int, name, "an INT64 argument")?;
            call(ScalarFunc::PqSleep, args, DataType::Int64)
        }
        _ => return Err(Error::semantic(format!("unknown function '{name}'"))),
    })
}
