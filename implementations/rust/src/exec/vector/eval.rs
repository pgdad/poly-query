//! Vectorized expression evaluation over batches.
//!
//! Hot operators — comparisons, arithmetic, boolean logic, `IS NULL`,
//! `BETWEEN`, constant `IN` lists and `LIKE` — run as typed kernels over
//! whole column vectors: one dispatch per batch, then a tight loop the
//! compiler can auto-vectorize (SIMD). Comparisons against a dictionary
//! encoded column are evaluated once per dictionary entry. Every other
//! expression is evaluated element-wise with the row evaluator on a
//! "template" whose children are the already-vectorized child results, so
//! the semantics are exactly those of row mode. `AND`, `OR` and `CASE`
//! evaluate their lazily-evaluated operands only on the rows that need them,
//! like row mode does.

use std::borrow::Cow;
use std::sync::Arc;

use super::batch::{Batch, Data, Vector, selection};
use crate::error::{Error, Result};
use crate::exec::ExecContext;
use crate::exec::eval::{Chain, arithmetic, compare3, eval as eval_row, like_match};
use crate::exec::functions;
use crate::exec::hash::FastSet;
use crate::exec::subquery;
use crate::planner::expr::{ArithKind, Expr, ScalarFunc};
use crate::sql::ast::BinaryOp;
use crate::types::value::promote_int;
use crate::types::{DataType, Value, datetime, decimal, float};

/// Evaluates `e` over every row of `b`.
pub fn eval(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    Ok(eval_cow(e, b, ctx)?.into_owned())
}

/// Rows of `b` for which predicate `e` is TRUE.
pub fn eval_mask(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vec<bool>> {
    let v = eval_cow(e, b, ctx)?;
    Ok(true_mask(&v))
}

/// True where the boolean vector is TRUE (NULL and FALSE are not).
pub fn true_mask(v: &Vector) -> Vec<bool> {
    match &v.data {
        Data::Bool(vals) => match &v.valid {
            None => vals.clone(),
            Some(valid) => vals.iter().zip(valid).map(|(&x, &ok)| x && ok).collect(),
        },
        Data::Values(vals) => vals
            .iter()
            .map(|x| matches!(x, Value::Bool(true)))
            .collect(),
        _ => vec![false; v.len()],
    }
}

pub fn eval_cow<'a>(e: &Expr, b: &'a Batch, ctx: &ExecContext) -> Result<Cow<'a, Vector>> {
    match e {
        Expr::Column { index, .. } => Ok(Cow::Borrowed(&b.columns[*index])),
        _ => Ok(Cow::Owned(eval_owned(e, b, ctx)?)),
    }
}

/// A kernel operand: a vector or a single (broadcast) value.
enum Operand<'a> {
    Scalar(Value),
    Vector(Cow<'a, Vector>),
}

impl Operand<'_> {
    fn value(&self, i: usize) -> Value {
        match self {
            Operand::Scalar(v) => v.clone(),
            Operand::Vector(v) => v.value(i),
        }
    }

    fn valid(&self) -> Option<&[bool]> {
        match self {
            Operand::Scalar(_) => None,
            Operand::Vector(v) => v.valid.as_deref(),
        }
    }

    fn kind(&self) -> Kind {
        match self {
            Operand::Scalar(v) => Kind::of_value(v),
            Operand::Vector(v) => Kind::of_vector(v),
        }
    }
}

fn operand<'a>(e: &Expr, b: &'a Batch, ctx: &ExecContext) -> Result<Operand<'a>> {
    Ok(match e {
        Expr::Literal { value, .. } => Operand::Scalar(value.clone()),
        Expr::Param { index, .. } => Operand::Scalar(ctx.param(*index)?),
        _ => Operand::Vector(eval_cow(e, b, ctx)?),
    })
}

/// Runtime representation class of an operand.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Null,
    Bool,
    Int,
    Float,
    Dec(u8),
    Str,
    Date,
    Ts,
    Generic,
}

impl Kind {
    fn of_value(v: &Value) -> Kind {
        match v {
            Value::Null => Kind::Null,
            Value::Bool(_) => Kind::Bool,
            Value::Int(_) => Kind::Int,
            Value::Float(_) => Kind::Float,
            // Typed decimal kernels take values of at most 18 digits.
            Value::Decimal(u, s) if decimal::fits18(*u) => Kind::Dec(*s),
            Value::Decimal(..) => Kind::Generic,
            Value::Str(_) => Kind::Str,
            Value::Date(_) => Kind::Date,
            Value::Timestamp(_) => Kind::Ts,
        }
    }

    fn of_vector(v: &Vector) -> Kind {
        match &v.data {
            Data::Null => Kind::Null,
            Data::Bool(_) => Kind::Bool,
            Data::Int(_) => Kind::Int,
            Data::Float(_) => Kind::Float,
            Data::Decimal(_, s) => Kind::Dec(*s),
            Data::Str(_) | Data::Dict(..) => Kind::Str,
            Data::Date(_) => Kind::Date,
            Data::Timestamp(_) => Kind::Ts,
            Data::Values(_) => Kind::Generic,
        }
    }

    fn is_numeric(self) -> bool {
        matches!(self, Kind::Int | Kind::Float | Kind::Dec(_))
    }
}

/// Combined validity of two operands (None = all valid).
fn and_valid(a: Option<&[bool]>, b: Option<&[bool]>) -> Option<Vec<bool>> {
    match (a, b) {
        (None, None) => None,
        (Some(x), None) | (None, Some(x)) => Some(x.to_vec()),
        (Some(x), Some(y)) => Some(x.iter().zip(y).map(|(&p, &q)| p && q).collect()),
    }
}

fn bool_vector(values: Vec<bool>, valid: Option<Vec<bool>>) -> Vector {
    Vector::new(Data::Bool(values), valid)
}

fn eval_owned(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    crate::stack::check()?;
    let n = b.len;
    match e {
        Expr::Literal { value, .. } => Ok(Vector::broadcast(value, n)),
        Expr::Column { index, .. } => Ok(b.columns[*index].clone()),
        Expr::Param { index, .. } => Ok(Vector::broadcast(&ctx.param(*index)?, n)),
        Expr::AggRef { .. } => Err(Error::internal("unresolved aggregate reference")),
        Expr::Not(inner) => {
            let v = eval_cow(inner, b, ctx)?;
            let (t, f) = truth(&v);
            Ok(from_truth(f, t))
        }
        Expr::And(l, r) | Expr::Or(l, r) => {
            if Chain::Logic.is_long(l) {
                return logic_chain(e, b, ctx);
            }
            let lv = eval_cow(l, b, ctx)?;
            and_or(matches!(e, Expr::And(..)), &lv, r, b, ctx)
        }
        Expr::IsNull { expr, negated } => {
            let v = eval_cow(expr, b, ctx)?;
            let values = match v.validity() {
                None => vec![*negated; n],
                Some(valid) => valid.into_iter().map(|ok| ok == *negated).collect(),
            };
            Ok(bool_vector(values, None))
        }
        Expr::Compare { op, left, right } => {
            let l = operand(left, b, ctx)?;
            let r = operand(right, b, ctx)?;
            compare(*op, &l, &r, n)
        }
        Expr::Between {
            expr,
            low,
            high,
            negated,
        } => {
            let x = operand(expr, b, ctx)?;
            let lo = operand(low, b, ctx)?;
            let hi = operand(high, b, ctx)?;
            let ge = compare(BinaryOp::GtEq, &x, &lo, n)?;
            let le = compare(BinaryOp::LtEq, &x, &hi, n)?;
            let (gt, gf) = truth(&ge);
            let (lt, lf) = truth(&le);
            let t: Vec<bool> = gt.iter().zip(&lt).map(|(&a, &b)| a && b).collect();
            let f: Vec<bool> = gf.iter().zip(&lf).map(|(&a, &b)| a || b).collect();
            Ok(if *negated {
                from_truth(f, t)
            } else {
                from_truth(t, f)
            })
        }
        Expr::Arith { left, .. } if Chain::Arith.is_long(left) => arith_chain(e, b, ctx),
        Expr::Arith {
            op,
            kind,
            left,
            right,
            ..
        } => {
            let l = operand(left, b, ctx)?;
            let r = operand(right, b, ctx)?;
            arith(*op, *kind, &l, &r, n)
        }
        Expr::InList {
            expr,
            list,
            negated,
        } => match in_list_const(expr, list, *negated, b, ctx)? {
            Some(v) => Ok(v),
            None => elementwise(e, b, ctx),
        },
        Expr::Like {
            expr,
            pattern,
            negated,
        } => like(e, expr, pattern, *negated, b, ctx),
        Expr::Case {
            operand: subject,
            whens,
            else_expr,
            ..
        } => case(subject.as_deref(), whens, else_expr.as_deref(), b, ctx),
        Expr::Cast { expr, to } => {
            let v = eval_cow(expr, b, ctx)?;
            match cast_vector(&v, *to) {
                Some(r) => r,
                None => elementwise(e, b, ctx),
            }
        }
        Expr::Function { func, args, .. } if args.len() == 1 => {
            let v = eval_cow(&args[0], b, ctx)?;
            match function_vector(*func, &v) {
                Some(r) => r,
                None => elementwise_with(e, vec![Operand::Vector(v)], b, ctx),
            }
        }
        Expr::Negate { expr, .. } => {
            let v = eval_cow(expr, b, ctx)?;
            match negate_vector(&v) {
                Some(r) => r,
                None => elementwise_with(e, vec![Operand::Vector(v)], b, ctx),
            }
        }
        Expr::Concat(l, _) if Chain::Concat.is_long(l) => concat_chain(e, b, ctx),
        Expr::Function { .. } | Expr::Concat(..) => elementwise(e, b, ctx),
        // Uncorrelated subqueries run once (memoized); their result is
        // broadcast, or probed per row for IN.
        Expr::ScalarSubquery { sub, params, .. } if params.is_empty() => Ok(Vector::broadcast(
            &subquery::scalar(sub, &[], &[], ctx)?,
            b.len,
        )),
        Expr::Exists { sub, params } if params.is_empty() => Ok(Vector::broadcast(
            &Value::Bool(subquery::exists(sub, &[], &[], ctx)?),
            b.len,
        )),
        Expr::InSubquery {
            expr,
            sub,
            params,
            negated,
            domain,
        } if params.is_empty() => {
            let x = eval_cow(expr, b, ctx)?;
            let set = subquery::uncorrelated_set(sub, *domain, ctx)?;
            let mut out = Vec::with_capacity(b.len);
            for i in 0..b.len {
                let r = subquery::set_contains(&set, &x.value(i), *domain)?;
                let r = if *negated { r.map(|t| !t) } else { r };
                out.push(r.map_or(Value::Null, Value::Bool));
            }
            Ok(Vector::from_values(out))
        }
        Expr::ScalarSubquery { .. } | Expr::Exists { .. } | Expr::InSubquery { .. } => {
            rowwise(e, b, ctx)
        }
    }
}

// ------------------------------------------------------------ boolean logic

/// (definitely TRUE, definitely FALSE) flags of a boolean vector.
fn truth(v: &Vector) -> (Vec<bool>, Vec<bool>) {
    let n = v.len();
    match &v.data {
        Data::Bool(vals) => match &v.valid {
            None => (vals.clone(), vals.iter().map(|&x| !x).collect()),
            Some(valid) => (
                vals.iter().zip(valid).map(|(&x, &ok)| ok && x).collect(),
                vals.iter().zip(valid).map(|(&x, &ok)| ok && !x).collect(),
            ),
        },
        Data::Values(vals) => (
            vals.iter()
                .map(|x| matches!(x, Value::Bool(true)))
                .collect(),
            vals.iter()
                .map(|x| matches!(x, Value::Bool(false)))
                .collect(),
        ),
        _ => (vec![false; n], vec![false; n]),
    }
}

/// Boolean vector from TRUE/FALSE flags (neither = NULL).
fn from_truth(t: Vec<bool>, f: Vec<bool>) -> Vector {
    let all_known = t.iter().zip(&f).all(|(&a, &b)| a || b);
    let valid = (!all_known).then(|| t.iter().zip(&f).map(|(&a, &b)| a || b).collect());
    bool_vector(t, valid)
}

/// Three-valued AND (`is_and`) / OR of the evaluated left operand `lv` and
/// `r`. The right operand is evaluated only on the rows the left operand
/// does not decide (unless it cannot fail).
fn and_or(is_and: bool, lv: &Vector, r: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    let n = b.len;
    let (lt, lf) = truth(lv);
    // Rows decided by the left operand alone.
    let decided = if is_and { &lf } else { &lt };
    let undecided: Vec<bool> = decided.iter().map(|&d| !d).collect();
    let need = undecided.iter().filter(|&&u| u).count();
    let (rt, rf) = if need == 0 {
        (vec![false; n], vec![false; n])
    } else if need == n || r.is_infallible() {
        truth(&*eval_cow(r, b, ctx)?)
    } else {
        let idx = selection(&undecided);
        let sub = b.gather(&idx);
        let (st, sf) = truth(&eval(r, &sub, ctx)?);
        let (mut rt, mut rf) = (vec![false; n], vec![false; n]);
        for (k, &i) in idx.iter().enumerate() {
            rt[i as usize] = st[k];
            rf[i as usize] = sf[k];
        }
        (rt, rf)
    };
    let (t, f) = if is_and {
        (
            lt.iter().zip(&rt).map(|(&a, &b)| a && b).collect(),
            lf.iter().zip(&rf).map(|(&a, &b)| a || b).collect(),
        )
    } else {
        (
            lt.iter().zip(&rt).map(|(&a, &b)| a || b).collect(),
            lf.iter().zip(&rf).map(|(&a, &b)| a && b).collect(),
        )
    };
    Ok(from_truth(t, f))
}

// ------------------------------------------------------------ long chains

// Long left-deep operator chains are evaluated link by link (see
// `exec::eval::Chain`), with the same semantics as the recursive evaluation.

fn logic_chain(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    let (links, first) = Chain::Logic.links(e);
    let mut acc = eval(first, b, ctx)?;
    for link in links {
        let (Expr::And(_, r) | Expr::Or(_, r)) = link else {
            unreachable!("logic chain link");
        };
        acc = and_or(matches!(link, Expr::And(..)), &acc, r, b, ctx)?;
    }
    Ok(acc)
}

fn arith_chain(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    let (links, first) = Chain::Arith.links(e);
    let mut acc = operand(first, b, ctx)?;
    for link in links {
        let Expr::Arith {
            op, kind, right, ..
        } = link
        else {
            unreachable!("arithmetic chain link");
        };
        let r = operand(right, b, ctx)?;
        acc = Operand::Vector(Cow::Owned(arith(*op, *kind, &acc, &r, b.len)?));
    }
    Ok(match acc {
        Operand::Vector(v) => v.into_owned(),
        Operand::Scalar(v) => Vector::broadcast(&v, b.len),
    })
}

/// `||` chain: every row's result is appended into one buffer.
fn concat_chain(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    let (links, first) = Chain::Concat.links(e);
    let mut out: Vec<Option<String>> = vec![Some(String::new()); b.len];
    let mut append = |o: Operand| {
        for (i, slot) in out.iter_mut().enumerate() {
            if let Some(buf) = slot {
                match o.value(i) {
                    Value::Str(s) => buf.push_str(&s),
                    _ => *slot = None,
                }
            }
        }
    };
    append(operand(first, b, ctx)?);
    for link in links {
        let Expr::Concat(_, r) = link else {
            unreachable!("concat chain link");
        };
        append(operand(r, b, ctx)?);
    }
    Ok(Vector::from_values(
        out.into_iter()
            .map(|s| s.map_or(Value::Null, |s| Value::str(&s)))
            .collect(),
    ))
}

// ------------------------------------------------------------ comparison

/// A typed kernel input: a slice or a broadcast scalar.
enum Lane<'a, T: Clone> {
    Slice(Cow<'a, [T]>),
    Scalar(T),
}

impl<T: Copy> Lane<'_, T> {
    fn slice(&self) -> Option<&[T]> {
        match self {
            Lane::Slice(s) => Some(s),
            Lane::Scalar(_) => None,
        }
    }

    fn scalar(&self) -> T {
        match self {
            Lane::Scalar(s) => *s,
            Lane::Slice(s) => s[0],
        }
    }
}

/// Applies a binary predicate element-wise. Each call site passes its own
/// closure, so the loop is monomorphized and branch-free.
#[inline]
fn zip_map<T: Copy, R: Copy, F: Fn(T, T) -> R>(l: &Lane<T>, r: &Lane<T>, n: usize, f: F) -> Vec<R> {
    match (l.slice(), r.slice()) {
        (Some(a), Some(b)) => a.iter().zip(b).map(|(&x, &y)| f(x, y)).collect(),
        (Some(a), None) => {
            let s = r.scalar();
            a.iter().map(|&x| f(x, s)).collect()
        }
        (None, Some(b)) => {
            let s = l.scalar();
            b.iter().map(|&y| f(s, y)).collect()
        }
        (None, None) => vec![f(l.scalar(), r.scalar()); n],
    }
}

fn cmp_kernel<T: Copy + PartialOrd>(op: BinaryOp, l: &Lane<T>, r: &Lane<T>, n: usize) -> Vec<bool> {
    match op {
        BinaryOp::Eq => zip_map(l, r, n, |a, b| a == b),
        BinaryOp::NotEq => zip_map(l, r, n, |a, b| a != b),
        BinaryOp::Lt => zip_map(l, r, n, |a, b| a < b),
        BinaryOp::LtEq => zip_map(l, r, n, |a, b| a <= b),
        BinaryOp::Gt => zip_map(l, r, n, |a, b| a > b),
        BinaryOp::GtEq => zip_map(l, r, n, |a, b| a >= b),
        _ => vec![false; n],
    }
}

fn i64_lane<'a>(o: &'a Operand) -> Option<Lane<'a, i64>> {
    Some(match o {
        Operand::Scalar(Value::Int(i) | Value::Timestamp(i)) => Lane::Scalar(*i),
        Operand::Scalar(Value::Decimal(u, _)) => Lane::Scalar(i64::try_from(*u).ok()?),
        Operand::Scalar(Value::Date(d)) => Lane::Scalar(*d as i64),
        Operand::Scalar(Value::Bool(b)) => Lane::Scalar(*b as i64),
        Operand::Vector(v) => match &v.data {
            Data::Int(x) | Data::Timestamp(x) | Data::Decimal(x, _) => {
                Lane::Slice(Cow::Borrowed(x))
            }
            Data::Date(x) => Lane::Slice(Cow::Owned(x.iter().map(|&d| d as i64).collect())),
            Data::Bool(x) => Lane::Slice(Cow::Owned(x.iter().map(|&b| b as i64).collect())),
            _ => return None,
        },
        _ => return None,
    })
}

/// Timestamp view of a DATE or TIMESTAMP operand.
fn ts_lane<'a>(o: &'a Operand) -> Option<Lane<'a, i64>> {
    Some(match o {
        Operand::Scalar(Value::Timestamp(t)) => Lane::Scalar(*t),
        Operand::Scalar(Value::Date(d)) => Lane::Scalar(datetime::date_to_timestamp(*d)),
        Operand::Vector(v) => match &v.data {
            Data::Timestamp(x) => Lane::Slice(Cow::Borrowed(x)),
            Data::Date(x) => Lane::Slice(Cow::Owned(
                x.iter().map(|&d| datetime::date_to_timestamp(d)).collect(),
            )),
            _ => return None,
        },
        _ => return None,
    })
}

/// Unscaled i128 view of an INT64/DECIMAL operand at `scale` (≤ 18, so
/// that 64-bit values rescaled to it fit i128; None otherwise).
fn i128_lane<'a>(o: &'a Operand, scale: u8) -> Option<Lane<'a, i128>> {
    if scale > decimal::NARROW_PRECISION {
        return None;
    }
    let up = |v: i128, s: u8| v.checked_mul(decimal::pow10((scale - s) as u32));
    Some(match o {
        Operand::Scalar(Value::Int(i)) => Lane::Scalar(up(*i as i128, 0)?),
        Operand::Scalar(Value::Decimal(u, s)) => Lane::Scalar(up(*u, *s)?),
        Operand::Vector(v) => match &v.data {
            Data::Int(x) => Lane::Slice(Cow::Owned(
                x.iter()
                    .map(|&i| i as i128 * decimal::pow10(scale as u32))
                    .collect(),
            )),
            Data::Decimal(x, s) => Lane::Slice(Cow::Owned(
                x.iter()
                    .map(|&u| u as i128 * decimal::pow10((scale - s) as u32))
                    .collect(),
            )),
            _ => return None,
        },
        _ => return None,
    })
}

fn f64_lane<'a>(o: &'a Operand) -> Option<Lane<'a, f64>> {
    Some(match o {
        Operand::Scalar(Value::Float(f)) => Lane::Scalar(*f),
        Operand::Scalar(Value::Int(i)) => Lane::Scalar(*i as f64),
        Operand::Scalar(Value::Decimal(u, s)) => Lane::Scalar(decimal::to_f64(*u, *s)),
        Operand::Vector(v) => match &v.data {
            Data::Float(x) => Lane::Slice(Cow::Borrowed(x)),
            Data::Int(x) => Lane::Slice(Cow::Owned(x.iter().map(|&i| i as f64).collect())),
            Data::Decimal(x, s) => Lane::Slice(Cow::Owned(
                x.iter().map(|&u| decimal::to_f64(u as i128, *s)).collect(),
            )),
            _ => return None,
        },
        _ => return None,
    })
}

fn str_lane<'a>(o: &'a Operand) -> Option<Lane<'a, &'a str>> {
    Some(match o {
        Operand::Scalar(Value::Str(s)) => Lane::Scalar(&**s),
        Operand::Vector(v) => match &v.data {
            Data::Str(x) => Lane::Slice(Cow::Owned(x.iter().map(|s| &**s).collect())),
            Data::Dict(c, d) => {
                Lane::Slice(Cow::Owned(c.iter().map(|&k| &*d[k as usize]).collect()))
            }
            _ => return None,
        },
        _ => return None,
    })
}

/// `l <op> r` for comparable operands (three-valued).
fn compare(op: BinaryOp, l: &Operand, r: &Operand, n: usize) -> Result<Vector> {
    let (lk, rk) = (l.kind(), r.kind());
    if lk == Kind::Null || rk == Kind::Null {
        return Ok(Vector::null(n));
    }
    if let (Operand::Scalar(a), Operand::Scalar(b)) = (l, r) {
        return Ok(Vector::broadcast(
            &compare3(op, a, b)?.map_or(Value::Null, Value::Bool),
            n,
        ));
    }
    let valid = || and_valid(l.valid(), r.valid());
    let values = match (lk, rk) {
        (Kind::Int, Kind::Int)
        | (Kind::Date, Kind::Date)
        | (Kind::Ts, Kind::Ts)
        | (Kind::Bool, Kind::Bool) => cmp_lanes(op, i64_lane(l), i64_lane(r), n),
        (Kind::Dec(a), Kind::Dec(b)) if a == b => cmp_lanes(op, i64_lane(l), i64_lane(r), n),
        (Kind::Dec(a), Kind::Dec(b)) => {
            let s = a.max(b);
            cmp_lanes(op, i128_lane(l, s), i128_lane(r, s), n)
        }
        (Kind::Int, Kind::Dec(s)) | (Kind::Dec(s), Kind::Int) => {
            cmp_lanes(op, i128_lane(l, s), i128_lane(r, s), n)
        }
        (Kind::Date, Kind::Ts) | (Kind::Ts, Kind::Date) => cmp_lanes(op, ts_lane(l), ts_lane(r), n),
        (a, b) if a.is_numeric() && b.is_numeric() => cmp_lanes(op, f64_lane(l), f64_lane(r), n),
        (Kind::Str, Kind::Str) => compare_strings(op, l, r, n),
        _ => None,
    };
    match values {
        Some(values) => Ok(bool_vector(values, valid())),
        None => {
            // Generic value-at-a-time comparison.
            let mut out = Vec::with_capacity(n);
            for i in 0..n {
                out.push(compare3(op, &l.value(i), &r.value(i))?.map_or(Value::Null, Value::Bool));
            }
            Ok(Vector::from_values(out))
        }
    }
}

fn cmp_lanes<T: Copy + PartialOrd>(
    op: BinaryOp,
    l: Option<Lane<T>>,
    r: Option<Lane<T>>,
    n: usize,
) -> Option<Vec<bool>> {
    Some(cmp_kernel(op, &l?, &r?, n))
}

/// String comparison; a dictionary column against a constant is compared
/// once per dictionary entry.
fn compare_strings(op: BinaryOp, l: &Operand, r: &Operand, n: usize) -> Option<Vec<bool>> {
    let dict_vs_scalar = |v: &Vector, s: &str, flip: bool| -> Option<Vec<bool>> {
        let Data::Dict(codes, dict) = &v.data else {
            return None;
        };
        if dict.len() > n {
            return None;
        }
        let entries: Vec<&str> = dict.iter().map(|d| &**d).collect();
        let per_entry = if flip {
            cmp_kernel(
                op,
                &Lane::Scalar(s),
                &Lane::Slice(Cow::Owned(entries)),
                dict.len(),
            )
        } else {
            cmp_kernel(
                op,
                &Lane::Slice(Cow::Owned(entries)),
                &Lane::Scalar(s),
                dict.len(),
            )
        };
        Some(codes.iter().map(|&c| per_entry[c as usize]).collect())
    };
    match (l, r) {
        (Operand::Vector(v), Operand::Scalar(Value::Str(s))) => {
            if let Some(out) = dict_vs_scalar(v, s, false) {
                return Some(out);
            }
        }
        (Operand::Scalar(Value::Str(s)), Operand::Vector(v)) => {
            if let Some(out) = dict_vs_scalar(v, s, true) {
                return Some(out);
            }
        }
        _ => {}
    }
    cmp_lanes(op, str_lane(l), str_lane(r), n)
}

// ------------------------------------------------------------ arithmetic

fn overflow(op: BinaryOp) -> Error {
    Error::overflow(format!("numeric overflow in operator {}", op.symbol()))
}

/// True if any valid position is flagged.
fn any_valid(flags: &[bool], valid: Option<&[bool]>) -> bool {
    match valid {
        None => flags.iter().any(|&f| f),
        Some(v) => flags.iter().zip(v).any(|(&f, &ok)| f && ok),
    }
}

fn arith(op: BinaryOp, kind: ArithKind, l: &Operand, r: &Operand, n: usize) -> Result<Vector> {
    let (lk, rk) = (l.kind(), r.kind());
    if lk == Kind::Null || rk == Kind::Null {
        return Ok(Vector::null(n));
    }
    if let (Operand::Scalar(a), Operand::Scalar(b)) = (l, r) {
        return Ok(Vector::broadcast(&arithmetic(op, kind, a, b)?, n));
    }
    let valid = and_valid(l.valid(), r.valid());
    let result = match kind {
        ArithKind::Int => arith_int(op, l, r, n, valid.as_deref())?,
        ArithKind::Decimal => arith_decimal(op, l, r, n, valid.as_deref())?,
        // Wide decimals are evaluated value-at-a-time (exact 128/256-bit).
        ArithKind::WideDecimal => None,
        ArithKind::Float => arith_float(op, l, r, n, valid.as_deref())?,
    };
    match result {
        Some(data) => Ok(Vector::new(data, valid)),
        None => {
            let mut out = Vec::with_capacity(n);
            for i in 0..n {
                let (a, b) = (l.value(i), r.value(i));
                out.push(if a.is_null() || b.is_null() {
                    Value::Null
                } else {
                    arithmetic(op, kind, &a, &b)?
                });
            }
            Ok(Vector::from_values(out))
        }
    }
}

fn arith_int(
    op: BinaryOp,
    l: &Operand,
    r: &Operand,
    n: usize,
    valid: Option<&[bool]>,
) -> Result<Option<Data>> {
    if l.kind() != Kind::Int || r.kind() != Kind::Int {
        return Ok(None);
    }
    let (Some(a), Some(b)) = (i64_lane(l), i64_lane(r)) else {
        return Ok(None);
    };
    let checked = |pairs: Vec<(i64, bool)>| -> Result<Vec<i64>> {
        let flags: Vec<bool> = pairs.iter().map(|p| p.1).collect();
        if any_valid(&flags, valid) {
            return Err(overflow(op));
        }
        Ok(pairs.into_iter().map(|p| p.0).collect())
    };
    let out = match op {
        BinaryOp::Add => checked(zip_map(&a, &b, n, |x: i64, y| x.overflowing_add(y)))?,
        BinaryOp::Sub => checked(zip_map(&a, &b, n, |x: i64, y| x.overflowing_sub(y)))?,
        BinaryOp::Mul => checked(zip_map(&a, &b, n, |x: i64, y| x.overflowing_mul(y)))?,
        BinaryOp::Div | BinaryOp::Mod => {
            let zero = zip_map(&a, &b, n, |_, y: i64| y == 0);
            if any_valid(&zero, valid) {
                return Err(Error::division_by_zero());
            }
            if op == BinaryOp::Div {
                // i64::MIN / -1 overflows; NULL slots may hold a zero divisor.
                checked(zip_map(&a, &b, n, |x: i64, y| {
                    if y == 0 {
                        (0, false)
                    } else {
                        x.overflowing_div(y)
                    }
                }))?
            } else {
                zip_map(&a, &b, n, |x: i64, y| {
                    if y == 0 {
                        0
                    } else {
                        x.checked_rem(y).unwrap_or(0)
                    }
                })
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(Data::Int(out)))
}

fn arith_decimal(
    op: BinaryOp,
    l: &Operand,
    r: &Operand,
    n: usize,
    valid: Option<&[bool]>,
) -> Result<Option<Data>> {
    let scale_of = |k: Kind| match k {
        Kind::Int => Some(0u8),
        Kind::Dec(s) => Some(s),
        _ => None,
    };
    let (Some(sa), Some(sb)) = (scale_of(l.kind()), scale_of(r.kind())) else {
        return Ok(None);
    };
    // INT64 operands are promoted to DECIMAL(18,0), which may overflow
    // (narrow arithmetic only; wide arithmetic never reaches this kernel).
    for (o, k) in [(l, l.kind()), (r, r.kind())] {
        if k == Kind::Int
            && let Some(lane) = i64_lane(o)
        {
            let bad = match lane.slice() {
                Some(s) => {
                    let flags: Vec<bool> =
                        s.iter().map(|&v| promote_int(v, 18, 0).is_err()).collect();
                    any_valid(&flags, o.valid())
                }
                None => promote_int(lane.scalar(), 18, 0).is_err(),
            };
            if bad {
                return Err(Error::overflow("integer does not fit DECIMAL(18,0)"));
            }
        }
    }
    let (out, scale) = match op {
        BinaryOp::Add | BinaryOp::Sub => {
            let s = sa.max(sb);
            let (Some(a), Some(b)) = (i128_lane(l, s), i128_lane(r, s)) else {
                return Ok(None);
            };
            let v = if op == BinaryOp::Add {
                zip_map(&a, &b, n, |x: i128, y| x + y)
            } else {
                zip_map(&a, &b, n, |x: i128, y| x - y)
            };
            (v, s)
        }
        BinaryOp::Mul => {
            let (Some(a), Some(b)) = (i128_lane(l, sa), i128_lane(r, sb)) else {
                return Ok(None);
            };
            (zip_map(&a, &b, n, |x: i128, y| x * y), sa + sb)
        }
        _ => return Ok(None),
    };
    let flags: Vec<bool> = out.iter().map(|&v| !decimal::fits18(v)).collect();
    if any_valid(&flags, valid) {
        return Err(overflow(op));
    }
    Ok(Some(Data::Decimal(
        out.into_iter()
            .map(|v| if decimal::fits18(v) { v as i64 } else { 0 })
            .collect(),
        scale,
    )))
}

fn arith_float(
    op: BinaryOp,
    l: &Operand,
    r: &Operand,
    n: usize,
    valid: Option<&[bool]>,
) -> Result<Option<Data>> {
    let (Some(a), Some(b)) = (f64_lane(l), f64_lane(r)) else {
        return Ok(None);
    };
    let out = match op {
        BinaryOp::Add => zip_map(&a, &b, n, |x: f64, y| x + y),
        BinaryOp::Sub => zip_map(&a, &b, n, |x: f64, y| x - y),
        BinaryOp::Mul => zip_map(&a, &b, n, |x: f64, y| x * y),
        BinaryOp::Div => {
            let zero = zip_map(&a, &b, n, |_, y: f64| y == 0.0);
            if any_valid(&zero, valid) {
                return Err(Error::division_by_zero());
            }
            zip_map(&a, &b, n, |x: f64, y| x / y)
        }
        _ => return Ok(None),
    };
    let flags: Vec<bool> = out.iter().map(|v| !v.is_finite()).collect();
    if any_valid(&flags, valid) {
        return Err(overflow(op));
    }
    Ok(Some(Data::Float(
        out.into_iter().map(float::normalize).collect(),
    )))
}

// ------------------------------------------------------------ CAST

/// Typed kernels for the numeric and temporal casts (same results and
/// errors as `cast_value`); None for other conversions.
fn cast_vector(v: &Vector, to: DataType) -> Option<Result<Vector>> {
    let valid = v.valid.clone();
    let ok = |i: usize| valid.as_ref().is_none_or(|x| x[i]);
    let overflow = || Error::overflow(format!("value does not fit {to}"));
    let data = match (&v.data, to) {
        (Data::Int(_), DataType::Int64)
        | (Data::Float(_), DataType::Float64)
        | (Data::Date(_), DataType::Date)
        | (Data::Timestamp(_), DataType::Timestamp) => return Some(Ok(v.clone())),
        (Data::Int(x), DataType::Float64) => Data::Float(x.iter().map(|&i| i as f64).collect()),
        (Data::Decimal(x, s), DataType::Float64) => {
            Data::Float(x.iter().map(|&u| decimal::to_f64(u as i128, *s)).collect())
        }
        (Data::Decimal(x, s), DataType::Int64) if *s <= decimal::NARROW_PRECISION => {
            let d = 10i64.pow(*s as u32);
            Data::Int(x.iter().map(|&u| u / d).collect())
        }
        // Wide targets produce 128-bit values: value-at-a-time.
        (_, DataType::Decimal { precision, .. }) if precision > decimal::NARROW_PRECISION => {
            return None;
        }
        (Data::Bool(x), DataType::Int64) => Data::Int(x.iter().map(|&b| b as i64).collect()),
        (Data::Int(x), DataType::Decimal { precision, scale }) => {
            let mut out = Vec::with_capacity(x.len());
            for (i, &u) in x.iter().enumerate() {
                if !ok(i) {
                    out.push(0);
                    continue;
                }
                match (u as i128).checked_mul(decimal::pow10(scale as u32)) {
                    Some(r) if decimal::fits_precision(r, precision) => out.push(r as i64),
                    _ => return Some(Err(overflow())),
                }
            }
            Data::Decimal(out, scale)
        }
        (Data::Decimal(x, s), DataType::Decimal { precision, scale }) => {
            let mut out = Vec::with_capacity(x.len());
            for (i, &u) in x.iter().enumerate() {
                if !ok(i) {
                    out.push(0);
                    continue;
                }
                match decimal::rescale(u as i128, *s, scale) {
                    Some(r) if decimal::fits_precision(r, precision) => out.push(r as i64),
                    _ => return Some(Err(overflow())),
                }
            }
            Data::Decimal(out, scale)
        }
        (Data::Timestamp(x), DataType::Date) => {
            Data::Date(x.iter().map(|&t| datetime::timestamp_to_date(t)).collect())
        }
        (Data::Date(x), DataType::Timestamp) => {
            Data::Timestamp(x.iter().map(|&d| datetime::date_to_timestamp(d)).collect())
        }
        _ => return None,
    };
    Some(Ok(Vector::new(data, valid)))
}

// ------------------------------------------------------------ functions

/// Typed kernels for single-argument date/time functions and `ABS` (same
/// results and errors as `functions::call`); None for anything else.
fn function_vector(func: ScalarFunc, v: &Vector) -> Option<Result<Vector>> {
    let valid = v.valid.clone();
    let data = match (func, &v.data) {
        (ScalarFunc::Year | ScalarFunc::Month | ScalarFunc::Day, Data::Date(x)) => Data::Int(
            x.iter()
                .map(|&d| functions::ymd_part(func, d as i64))
                .collect(),
        ),
        (ScalarFunc::Year | ScalarFunc::Month | ScalarFunc::Day, Data::Timestamp(x)) => Data::Int(
            x.iter()
                .map(|&t| functions::ymd_part(func, t.div_euclid(datetime::MICROS_PER_DAY)))
                .collect(),
        ),
        (ScalarFunc::Hour | ScalarFunc::Minute | ScalarFunc::Second, Data::Timestamp(x)) => {
            Data::Int(x.iter().map(|&t| functions::hms_part(func, t)).collect())
        }
        (ScalarFunc::DateTrunc(unit), Data::Timestamp(x)) => {
            Data::Timestamp(x.iter().map(|&t| functions::date_trunc(unit, t)).collect())
        }
        (ScalarFunc::DateTrunc(unit), Data::Date(x)) => Data::Timestamp(
            x.iter()
                .map(|&d| functions::date_trunc(unit, datetime::date_to_timestamp(d)))
                .collect(),
        ),
        (ScalarFunc::Abs, Data::Int(x)) => {
            let ovf: Vec<bool> = x.iter().map(|&i| i == i64::MIN).collect();
            if any_valid(&ovf, valid.as_deref()) {
                return Some(Err(Error::overflow("numeric overflow in ABS")));
            }
            Data::Int(x.iter().map(|&i| i.wrapping_abs()).collect())
        }
        (ScalarFunc::Abs, Data::Float(x)) => Data::Float(x.iter().map(|f| f.abs()).collect()),
        (ScalarFunc::Abs, Data::Decimal(x, s)) => {
            Data::Decimal(x.iter().map(|u| u.abs()).collect(), *s)
        }
        _ => return None,
    };
    Some(Ok(Vector::new(data, valid)))
}

/// Unary minus over typed numeric vectors (as the row evaluator).
fn negate_vector(v: &Vector) -> Option<Result<Vector>> {
    let valid = v.valid.clone();
    let data = match &v.data {
        Data::Int(x) => {
            let ovf: Vec<bool> = x.iter().map(|&i| i == i64::MIN).collect();
            if any_valid(&ovf, valid.as_deref()) {
                return Some(Err(Error::overflow("integer overflow in negation")));
            }
            Data::Int(x.iter().map(|&i| i.wrapping_neg()).collect())
        }
        Data::Float(x) => Data::Float(x.iter().map(|&f| float::normalize(-f)).collect()),
        Data::Decimal(x, s) => Data::Decimal(x.iter().map(|&u| -u).collect(), *s),
        _ => return None,
    };
    Some(Ok(Vector::new(data, valid)))
}

// ------------------------------------------------------------ IN, LIKE

/// `x [NOT] IN (literal, …)` over an INT64 or STRING operand, with a hash
/// set of the constants. None if not applicable.
fn in_list_const(
    expr: &Expr,
    list: &[Expr],
    negated: bool,
    b: &Batch,
    ctx: &ExecContext,
) -> Result<Option<Vector>> {
    let mut consts = Vec::with_capacity(list.len());
    for item in list {
        match item {
            Expr::Literal { value, .. } => consts.push(value.clone()),
            _ => return Ok(None),
        }
    }
    let has_null = consts.iter().any(Value::is_null);
    let x = operand(expr, b, ctx)?;
    let Operand::Vector(v) = &x else {
        return Ok(None);
    };
    let n = b.len;
    let found: Vec<bool> = match &v.data {
        Data::Int(vals)
            if consts
                .iter()
                .all(|c| matches!(c, Value::Int(_) | Value::Null)) =>
        {
            let set: FastSet<i64> = consts
                .iter()
                .filter_map(|c| match c {
                    Value::Int(i) => Some(*i),
                    _ => None,
                })
                .collect();
            vals.iter().map(|x| set.contains(x)).collect()
        }
        Data::Str(_) | Data::Dict(..)
            if consts
                .iter()
                .all(|c| matches!(c, Value::Str(_) | Value::Null)) =>
        {
            let set: FastSet<&str> = consts
                .iter()
                .filter_map(|c| match c {
                    Value::Str(s) => Some(&**s),
                    _ => None,
                })
                .collect();
            match &v.data {
                Data::Dict(codes, dict) if dict.len() <= n => {
                    let per: Vec<bool> = dict.iter().map(|d| set.contains(&**d)).collect();
                    codes.iter().map(|&c| per[c as usize]).collect()
                }
                _ => (0..n)
                    .map(|i| v.str_at(i).is_some_and(|s| set.contains(s)))
                    .collect(),
            }
        }
        _ => return Ok(None),
    };
    // found ⇒ TRUE; not found ⇒ NULL if the list holds a NULL, else FALSE;
    // NULL operand ⇒ NULL (unless the list is empty, which the parser forbids).
    let valid: Vec<bool> = (0..n)
        .map(|i| !v.is_null(i) && (found[i] || !has_null))
        .collect();
    let values: Vec<bool> = found.into_iter().map(|f| f != negated).collect();
    let all_valid = valid.iter().all(|&x| x);
    Ok(Some(bool_vector(values, (!all_valid).then_some(valid))))
}

fn like(
    e: &Expr,
    expr: &Expr,
    pattern: &Expr,
    negated: bool,
    b: &Batch,
    ctx: &ExecContext,
) -> Result<Vector> {
    let p = match pattern {
        Expr::Literal { value, .. } => value.clone(),
        _ => return elementwise(e, b, ctx),
    };
    let n = b.len;
    let Value::Str(p) = p else {
        return Ok(Vector::null(n));
    };
    let v = eval_cow(expr, b, ctx)?;
    let values: Vec<bool> = match &v.data {
        Data::Dict(codes, dict) if dict.len() <= n => {
            let per: Vec<bool> = dict.iter().map(|d| like_match(d, &p) != negated).collect();
            codes.iter().map(|&c| per[c as usize]).collect()
        }
        Data::Str(_) | Data::Dict(..) | Data::Values(_) | Data::Null => (0..n)
            .map(|i| v.str_at(i).is_some_and(|s| like_match(s, &p) != negated))
            .collect(),
        _ => return elementwise(e, b, ctx),
    };
    let valid = v.validity();
    Ok(bool_vector(
        values,
        valid.filter(|x| !x.iter().all(|&ok| ok)),
    ))
}

// ------------------------------------------------------------ CASE

fn case(
    subject: Option<&Expr>,
    whens: &[(Expr, Expr)],
    else_expr: Option<&Expr>,
    b: &Batch,
    ctx: &ExecContext,
) -> Result<Vector> {
    let n = b.len;
    let mut result = vec![Value::Null; n];
    // Rows (positions in `b`) not yet decided, and the batch restricted to them.
    let mut remaining: Vec<u32> = (0..n as u32).collect();
    let mut cur: Cow<Batch> = Cow::Borrowed(b);
    let mut cur_subject = match subject {
        Some(s) => Some(eval(s, b, ctx)?),
        None => None,
    };
    let scatter = |result: &mut Vec<Value>, rows: &[u32], v: &Vector| {
        for (k, &i) in rows.iter().enumerate() {
            result[i as usize] = v.value(k);
        }
    };
    for (w, t) in whens {
        if remaining.is_empty() {
            break;
        }
        let c = eval(w, &cur, ctx)?;
        let hit = match &cur_subject {
            Some(s) => {
                let eq = compare(
                    BinaryOp::Eq,
                    &Operand::Vector(Cow::Borrowed(s)),
                    &Operand::Vector(Cow::Owned(c)),
                    cur.len,
                )?;
                true_mask(&eq)
            }
            None => true_mask(&c),
        };
        let hit_idx = selection(&hit);
        if hit_idx.is_empty() {
            continue;
        }
        let sub = cur.gather(&hit_idx);
        let tv = eval(t, &sub, ctx)?;
        let rows: Vec<u32> = hit_idx.iter().map(|&j| remaining[j as usize]).collect();
        scatter(&mut result, &rows, &tv);
        let miss: Vec<bool> = hit.iter().map(|&h| !h).collect();
        let miss_idx = selection(&miss);
        remaining = miss_idx.iter().map(|&j| remaining[j as usize]).collect();
        cur = Cow::Owned(cur.gather(&miss_idx));
        cur_subject = cur_subject.map(|s| s.gather(&miss_idx));
    }
    if let Some(e) = else_expr
        && !remaining.is_empty()
    {
        let ev = eval(e, &cur, ctx)?;
        scatter(&mut result, &remaining, &ev);
    }
    Ok(Vector::from_values(result))
}

// ------------------------------------------------------------ fallbacks

/// Evaluates `e` per row with the row evaluator, after evaluating its
/// children vectorized: the node is copied with its children replaced by
/// references to a small per-row tuple of child values.
fn elementwise(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    let children = e.children();
    let mut ops = Vec::with_capacity(children.len());
    for c in &children {
        ops.push(operand(c, b, ctx)?);
    }
    elementwise_with(e, ops, b, ctx)
}

/// [`elementwise`] with the children of `e` already evaluated (`ops`).
fn elementwise_with(e: &Expr, ops: Vec<Operand>, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    let n = b.len;
    let template = e.template();
    let mut row = vec![Value::Null; ops.len()];
    let vectors: Vec<usize> = (0..ops.len())
        .filter(|&k| matches!(ops[k], Operand::Vector(_)))
        .collect();
    if let [k] = vectors[..]
        && let Operand::Vector(v) = &ops[k]
        && let Data::Dict(codes, dict) = &v.data
        && dict.len() <= n
    {
        for (slot, o) in row.iter_mut().zip(&ops) {
            *slot = o.value(0);
        }
        return per_dictionary_code(&template, &mut row, k, v, codes, dict, ctx);
    }
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        for (slot, o) in row.iter_mut().zip(&ops) {
            *slot = o.value(i);
        }
        out.push(eval_row(&template, &row, ctx)?);
    }
    Ok(Vector::from_values(out))
}

/// Evaluates `template` (whose only non-constant input, slot `k` of `row`,
/// is the dictionary-encoded `v`) once per distinct code occurring in the
/// batch — in row order, so errors surface at the same row as row by row.
/// String results stay dictionary-encoded.
fn per_dictionary_code(
    template: &Expr,
    row: &mut [Value],
    k: usize,
    v: &Vector,
    codes: &[u32],
    dict: &Arc<[Arc<str>]>,
    ctx: &ExecContext,
) -> Result<Vector> {
    let n = v.len();
    // Result slot of each code (`dict.len()` is the NULL input), in order
    // of first occurrence.
    let null_slot = dict.len();
    let mut slot_of = vec![u32::MAX; dict.len() + 1];
    let mut results: Vec<Value> = Vec::new();
    let mut slots = Vec::with_capacity(n);
    for (i, &code) in codes.iter().enumerate() {
        let c = if v.is_null(i) {
            null_slot
        } else {
            code as usize
        };
        if slot_of[c] == u32::MAX {
            row[k] = if c == null_slot {
                Value::Null
            } else {
                Value::Str(dict[c].clone())
            };
            slot_of[c] = results.len() as u32;
            results.push(eval_row(template, row, ctx)?);
        }
        slots.push(slot_of[c]);
    }
    if results
        .iter()
        .all(|r| matches!(r, Value::Str(_) | Value::Null))
    {
        let valid: Vec<bool> = slots
            .iter()
            .map(|&s| !results[s as usize].is_null())
            .collect();
        let all = valid.iter().all(|&x| x);
        let strings: Vec<Arc<str>> = results
            .into_iter()
            .map(|r| match r {
                Value::Str(s) => s,
                _ => Arc::from(""),
            })
            .collect();
        return Ok(Vector::new(
            Data::Dict(slots, strings.into()),
            (!all).then_some(valid),
        ));
    }
    Ok(Vector::from_values(
        slots.iter().map(|&s| results[s as usize].clone()).collect(),
    ))
}

/// Evaluates `e` row by row over full rows (subquery expressions).
fn rowwise(e: &Expr, b: &Batch, ctx: &ExecContext) -> Result<Vector> {
    let cols = e.columns();
    let mut row = vec![Value::Null; b.width()];
    let mut out = Vec::with_capacity(b.len);
    for i in 0..b.len {
        for &c in &cols {
            row[c] = b.columns[c].value(i);
        }
        out.push(eval_row(e, &row, ctx)?);
    }
    Ok(Vector::from_values(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;
    use crate::types::DataType;

    fn col(i: usize, ty: DataType) -> Box<Expr> {
        Box::new(Expr::Column { index: i, ty })
    }

    fn lit(v: Value, ty: DataType) -> Box<Expr> {
        Box::new(Expr::Literal { value: v, ty })
    }

    fn batch() -> Batch {
        let a = Vector::from_values(vec![
            Value::Int(1),
            Value::Int(5),
            Value::Null,
            Value::Int(0),
        ]);
        let s = Vector::from_values(vec![
            Value::str("x"),
            Value::str("y"),
            Value::str("x"),
            Value::Null,
        ]);
        Batch::new(vec![a, s], 4)
    }

    /// Vectorized and row evaluation agree on every row.
    fn agrees(e: &Expr) {
        let b = batch();
        let ctx = ExecContext::default();
        let v = eval(e, &b, &ctx).unwrap();
        for i in 0..b.len {
            let r = eval_row(e, &b.row(i), &ctx).unwrap();
            assert_eq!(v.value(i).is_null(), r.is_null(), "{e} row {i}");
            assert_eq!(v.value(i), r, "{e} row {i}");
        }
    }

    #[test]
    fn kernels_match_row_semantics() {
        let int = DataType::Int64;
        for op in [BinaryOp::Eq, BinaryOp::Lt, BinaryOp::GtEq, BinaryOp::NotEq] {
            agrees(&Expr::Compare {
                op,
                left: col(0, int),
                right: lit(Value::Int(1), int),
            });
            agrees(&Expr::Compare {
                op,
                left: col(0, int),
                right: lit(Value::Decimal(15, 1), DataType::decimal(2, 1)),
            });
            agrees(&Expr::Compare {
                op,
                left: col(1, DataType::String),
                right: lit(Value::str("x"), DataType::String),
            });
        }
        agrees(&Expr::Arith {
            op: BinaryOp::Mul,
            kind: ArithKind::Decimal,
            left: col(0, int),
            right: lit(Value::Decimal(15, 1), DataType::decimal(2, 1)),
            ty: DataType::decimal(18, 1),
        });
        agrees(&Expr::And(
            Box::new(Expr::Compare {
                op: BinaryOp::Gt,
                left: col(0, int),
                right: lit(Value::Int(0), int),
            }),
            Box::new(Expr::IsNull {
                expr: col(1, DataType::String),
                negated: true,
            }),
        ));
        for to in [
            DataType::Float64,
            DataType::decimal(18, 3),
            DataType::decimal(3, 1),
            DataType::Int64,
            DataType::String,
        ] {
            agrees(&Expr::Cast {
                expr: col(0, int),
                to,
            });
        }
        let dec = Expr::Cast {
            expr: col(0, int),
            to: DataType::decimal(18, 2),
        };
        agrees(&Expr::Cast {
            expr: Box::new(dec.clone()),
            to: DataType::decimal(4, 1),
        });
        agrees(&Expr::Cast {
            expr: Box::new(dec),
            to: DataType::Float64,
        });
        let too_small = Expr::Cast {
            expr: col(0, int),
            to: DataType::decimal(1, 1),
        };
        let err = eval(&too_small, &batch(), &ExecContext::default()).unwrap_err();
        assert_eq!(err.code, ErrorCode::NumericOverflow);
        agrees(&Expr::InList {
            expr: col(1, DataType::String),
            list: vec![
                *lit(Value::str("y"), DataType::String),
                *lit(Value::Null, DataType::Null),
            ],
            negated: false,
        });
    }

    #[test]
    fn functions_over_dictionary_codes() {
        use crate::planner::expr::ScalarFunc;
        let dict: Arc<[Arc<str>]> = vec![Arc::from("ab"), Arc::from("Cd")].into();
        let v = Vector::new(
            Data::Dict(vec![1, 0, 1, 0], dict),
            Some(vec![true, true, false, true]),
        );
        let b = Batch::new(vec![v], 4);
        let ctx = ExecContext::default();
        let s = DataType::String;
        for e in [
            Expr::Function {
                func: ScalarFunc::Upper,
                args: vec![*col(0, s)],
                ty: s,
            },
            Expr::Function {
                func: ScalarFunc::Coalesce,
                args: vec![*col(0, s), *lit(Value::str("none"), s)],
                ty: s,
            },
            Expr::Function {
                func: ScalarFunc::Length,
                args: vec![*col(0, s)],
                ty: DataType::Int64,
            },
        ] {
            let got = eval(&e, &b, &ctx).unwrap();
            for i in 0..4 {
                assert_eq!(
                    got.value(i),
                    eval_row(&e, &b.row(i), &ctx).unwrap(),
                    "{e} row {i}"
                );
            }
        }
    }

    #[test]
    fn date_and_numeric_function_kernels() {
        use crate::planner::expr::{ScalarFunc, TruncUnit};
        let ts = Vector::from_values(vec![
            Value::Timestamp(1_720_088_412_123_456),
            Value::Null,
            Value::Timestamp(-86_400_000_001),
        ]);
        let d = Vector::from_values(vec![Value::Date(19_000), Value::Date(-1), Value::Null]);
        let f = Vector::from_values(vec![Value::Float(-1.5), Value::Float(0.0), Value::Null]);
        let b = Batch::new(vec![ts, d, f], 3);
        let ctx = ExecContext::default();
        let funcs = [
            ScalarFunc::Year,
            ScalarFunc::Month,
            ScalarFunc::Day,
            ScalarFunc::Hour,
            ScalarFunc::Minute,
            ScalarFunc::Second,
            ScalarFunc::DateTrunc(TruncUnit::Year),
            ScalarFunc::DateTrunc(TruncUnit::Month),
            ScalarFunc::DateTrunc(TruncUnit::Day),
            ScalarFunc::DateTrunc(TruncUnit::Hour),
            ScalarFunc::DateTrunc(TruncUnit::Minute),
            ScalarFunc::Abs,
        ];
        let types = [DataType::Timestamp, DataType::Date, DataType::Float64];
        for func in funcs {
            for (c, ty) in types.iter().enumerate() {
                let e = Expr::Function {
                    func,
                    args: vec![*col(c, *ty)],
                    ty: DataType::Int64,
                };
                let rows: Vec<Result<Value>> =
                    (0..3).map(|i| eval_row(&e, &b.row(i), &ctx)).collect();
                if rows.iter().any(|r| r.is_err()) {
                    continue; // argument type not accepted by the function
                }
                let got = eval(&e, &b, &ctx).unwrap();
                for (i, r) in rows.into_iter().enumerate() {
                    assert_eq!(got.value(i), r.unwrap(), "{e} row {i}");
                }
            }
        }
        let neg = Expr::Negate {
            expr: col(2, DataType::Float64),
            ty: DataType::Float64,
        };
        let got = eval(&neg, &b, &ctx).unwrap();
        for i in 0..3 {
            assert_eq!(got.value(i), eval_row(&neg, &b.row(i), &ctx).unwrap());
        }
        let min = Batch::new(vec![Vector::from_values(vec![Value::Int(i64::MIN)])], 1);
        let abs = Expr::Function {
            func: ScalarFunc::Abs,
            args: vec![*col(0, DataType::Int64)],
            ty: DataType::Int64,
        };
        assert_eq!(
            eval(&abs, &min, &ctx).unwrap_err().code,
            ErrorCode::NumericOverflow
        );
    }

    #[test]
    fn lazy_and_avoids_errors() {
        // a <> 0 AND 10 / a > 1: row 3 has a = 0.
        let int = DataType::Int64;
        let e = Expr::And(
            Box::new(Expr::Compare {
                op: BinaryOp::NotEq,
                left: col(0, int),
                right: lit(Value::Int(0), int),
            }),
            Box::new(Expr::Compare {
                op: BinaryOp::Gt,
                left: Box::new(Expr::Arith {
                    op: BinaryOp::Div,
                    kind: ArithKind::Int,
                    left: lit(Value::Int(10), int),
                    right: col(0, int),
                    ty: int,
                }),
                right: lit(Value::Int(1), int),
            }),
        );
        agrees(&e);
        let div = Expr::Arith {
            op: BinaryOp::Div,
            kind: ArithKind::Int,
            left: lit(Value::Int(10), int),
            right: col(0, int),
            ty: int,
        };
        let err = eval(&div, &batch(), &ExecContext::default()).unwrap_err();
        assert_eq!(err.code, ErrorCode::DivisionByZero);
    }
}
