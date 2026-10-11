//! Evaluation of subqueries inside expressions (semantics.md §8).
//!
//! A subquery is executed with its correlation parameters (values from the
//! enclosing row) pushed onto the context; results are memoized per
//! parameter tuple, so an uncorrelated subquery runs at most once per query.

use std::collections::HashSet;
use std::rc::Rc;

use super::context::ExecContext;
use super::eval::{eval, normalize_key};
use super::operators::{build, build_row};
use crate::error::{Error, ErrorCode, Result};
use crate::planner::expr::{Expr, KeyDomain, SubqueryPlan};
use crate::planner::physical;
use crate::types::Value;

/// The materialized outcome of one subquery execution.
#[derive(Debug)]
pub enum SubqueryResult {
    Scalar(Value),
    Exists(bool),
    /// Distinct non-NULL values (normalized for `domain`) of an IN subquery.
    Set {
        values: HashSet<Value>,
        has_null: bool,
        empty: bool,
    },
}

#[derive(Clone, Copy)]
enum Want {
    Scalar,
    Exists,
    Set(KeyDomain),
}

fn run(
    sub: &SubqueryPlan,
    params: &[Expr],
    row: &[Value],
    ctx: &ExecContext,
    want: Want,
) -> Result<Rc<SubqueryResult>> {
    let mut values = Vec::with_capacity(params.len());
    for p in params {
        values.push(eval(p, row, ctx)?);
    }
    let key = (sub.id, values);
    if let Some(r) = ctx.cached_result(&key) {
        return Ok(r);
    }
    let plan = match ctx.cached_plan(sub.id) {
        Some(p) => p,
        None => {
            let p = Rc::new(physical::lower(&sub.plan, ctx.physical));
            ctx.cache_plan(sub.id, p.clone());
            p
        }
    };
    let result = ctx.with_params(key.1.clone().into(), || {
        // Correlated subqueries run once per distinct parameter tuple on
        // small inputs: the row engine's lower setup cost wins there.
        let mut op = if params.is_empty() {
            build((*plan).clone(), ctx)
        } else {
            build_row((*plan).clone())
        };
        Ok(match want {
            Want::Scalar => match op.next(ctx)? {
                None => SubqueryResult::Scalar(Value::Null),
                Some(mut first) => {
                    if op.next(ctx)?.is_some() {
                        return Err(Error::new(
                            ErrorCode::SubqueryCardinality,
                            "scalar subquery returned more than one row",
                        ));
                    }
                    SubqueryResult::Scalar(first.swap_remove(0))
                }
            },
            Want::Exists => SubqueryResult::Exists(op.next(ctx)?.is_some()),
            Want::Set(domain) => {
                let mut values = HashSet::new();
                let mut has_null = false;
                let mut empty = true;
                while let Some(mut r) = op.next(ctx)? {
                    empty = false;
                    let v = r.swap_remove(0);
                    if v.is_null() {
                        has_null = true;
                    } else {
                        let v = normalize_key(v, domain);
                        ctx.reserve(v.approx_size() + 16)?;
                        values.insert(v);
                    }
                }
                SubqueryResult::Set {
                    values,
                    has_null,
                    empty,
                }
            }
        })
    })?;
    let result = Rc::new(result);
    ctx.cache_result(key, result.clone());
    Ok(result)
}

/// Value of a scalar subquery (NULL for zero rows).
pub fn scalar(
    sub: &SubqueryPlan,
    params: &[Expr],
    row: &[Value],
    ctx: &ExecContext,
) -> Result<Value> {
    match &*run(sub, params, row, ctx, Want::Scalar)? {
        SubqueryResult::Scalar(v) => Ok(v.clone()),
        _ => Err(Error::internal("subquery result kind mismatch")),
    }
}

/// `EXISTS (subquery)`.
pub fn exists(
    sub: &SubqueryPlan,
    params: &[Expr],
    row: &[Value],
    ctx: &ExecContext,
) -> Result<bool> {
    match &*run(sub, params, row, ctx, Want::Exists)? {
        SubqueryResult::Exists(b) => Ok(*b),
        _ => Err(Error::internal("subquery result kind mismatch")),
    }
}

/// `x IN (subquery)` with SQL three-valued semantics (None = NULL).
pub fn in_subquery(
    x: &Value,
    sub: &SubqueryPlan,
    params: &[Expr],
    domain: KeyDomain,
    row: &[Value],
    ctx: &ExecContext,
) -> Result<Option<bool>> {
    match &*run(sub, params, row, ctx, Want::Set(domain))? {
        SubqueryResult::Set {
            values,
            has_null,
            empty,
        } => Ok(if *empty {
            Some(false)
        } else if x.is_null() {
            None
        } else if values.contains(&normalize_key(x.clone(), domain)) {
            Some(true)
        } else if *has_null {
            None
        } else {
            Some(false)
        }),
        _ => Err(Error::internal("subquery result kind mismatch")),
    }
}
