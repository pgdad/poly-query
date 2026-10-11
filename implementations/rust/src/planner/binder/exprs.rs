//! Expression binding: resolves names, checks and assigns types, collects
//! aggregates and binds subqueries (semantics.md §8, §11–§13, types.md).

use std::sync::Arc;

use super::scope::{Correlation, ExprScope};
use super::{AggMode, Binder};
use crate::error::{Error, Result};
use crate::planner::expr::{Expr, KeyDomain, SubqueryPlan};
use crate::planner::optimizer;
use crate::planner::typing::{
    arithmetic_type, check_boolean, check_comparable, coerce, common_type, is_boolean,
};
use crate::sql::ast::{self, BinaryOp, ExprKind, Literal, UnaryOp};
use crate::sql::lexer::Pos;
use crate::types::cast::cast_allowed;
use crate::types::{DataType, MAX_DECIMAL_PRECISION, Value, datetime};

/// AST children of an expression (not descending into subqueries).
pub(super) fn ast_children(e: &ast::Expr) -> Vec<&ast::Expr> {
    match &e.kind {
        ExprKind::Literal(_)
        | ExprKind::Column { .. }
        | ExprKind::Exists(_)
        | ExprKind::Subquery(_) => vec![],
        ExprKind::Unary { expr, .. }
        | ExprKind::IsNull { expr, .. }
        | ExprKind::Cast { expr, .. }
        | ExprKind::InSubquery { expr, .. } => vec![expr],
        ExprKind::Binary { left, right, .. } => vec![left, right],
        ExprKind::Between {
            expr, low, high, ..
        } => vec![expr, low, high],
        ExprKind::InList { expr, list, .. } => {
            std::iter::once(&**expr).chain(list.iter()).collect()
        }
        ExprKind::Like { expr, pattern, .. } => vec![expr, pattern],
        ExprKind::Function { args, .. } => args.iter().collect(),
        ExprKind::Case {
            operand,
            whens,
            else_expr,
        } => {
            let mut v: Vec<&ast::Expr> = Vec::new();
            if let Some(o) = operand {
                v.push(o);
            }
            for (w, t) in whens {
                v.push(w);
                v.push(t);
            }
            if let Some(e) = else_expr {
                v.push(e);
            }
            v
        }
    }
}

/// Parses an unsigned numeric literal (optionally negated) per types.md §3.
pub fn number_literal(text: &str, negate: bool) -> Result<(Value, DataType)> {
    let overflow = || {
        Error::overflow(format!(
            "numeric literal {}{text} is out of range",
            if negate { "-" } else { "" }
        ))
    };
    let float = || -> Result<(Value, DataType)> {
        let f: f64 = text
            .parse()
            .map_err(|_| Error::parse(format!("invalid number '{text}'")))?;
        if !f.is_finite() {
            return Err(overflow());
        }
        let f = if negate { -f } else { f };
        Ok((
            Value::Float(crate::types::float::normalize(f)),
            DataType::Float64,
        ))
    };
    if text.contains(['e', 'E']) {
        return float();
    }
    if let Some((int, frac)) = text.split_once('.') {
        let int = int.trim_start_matches('0');
        let scale = frac.len();
        let precision = (int.len() + scale).max(1);
        if precision > MAX_DECIMAL_PRECISION as usize {
            return float();
        }
        let digits = format!("{int}{frac}");
        let unscaled: i64 = if digits.is_empty() {
            0
        } else {
            digits.parse().map_err(|_| overflow())?
        };
        let unscaled = if negate { -unscaled } else { unscaled };
        return Ok((
            Value::Decimal(unscaled, scale as u8),
            DataType::decimal(precision as u8, scale as u8),
        ));
    }
    let digits = text.trim_start_matches('0');
    if digits.len() > 20 {
        return Err(overflow());
    }
    let v: i128 = if digits.is_empty() {
        0
    } else {
        digits.parse().map_err(|_| overflow())?
    };
    let v = if negate { -v } else { v };
    let v = i64::try_from(v).map_err(|_| overflow())?;
    Ok((Value::Int(v), DataType::Int64))
}

fn literal(lit: &Literal, pos: Pos) -> Result<Expr> {
    let (value, ty) = match lit {
        Literal::Number(text) => number_literal(text, false).map_err(|e| pos.error(e))?,
        Literal::String(s) => (Value::str(s), DataType::String),
        Literal::Bool(b) => (Value::Bool(*b), DataType::Boolean),
        Literal::Null => (Value::Null, DataType::Null),
        Literal::Date(s) => {
            let d = datetime::parse_date(s).ok_or_else(|| {
                pos.error(Error::conversion(format!("invalid DATE literal '{s}'")))
            })?;
            (Value::Date(d), DataType::Date)
        }
        Literal::Timestamp(s) => {
            let t = datetime::parse_timestamp(s).ok_or_else(|| {
                pos.error(Error::conversion(format!(
                    "invalid TIMESTAMP literal '{s}'"
                )))
            })?;
            (Value::Timestamp(t), DataType::Timestamp)
        }
    };
    Ok(Expr::Literal { value, ty })
}

impl Binder<'_> {
    pub(super) fn expr(
        &self,
        e: &ast::Expr,
        sc: &ExprScope<'_>,
        mode: &mut AggMode<'_>,
    ) -> Result<Expr> {
        self.expr_inner(e, sc, mode).map_err(|err| e.pos.error(err))
    }

    fn expr_inner(
        &self,
        e: &ast::Expr,
        sc: &ExprScope<'_>,
        mode: &mut AggMode<'_>,
    ) -> Result<Expr> {
        Ok(match &e.kind {
            ExprKind::Literal(lit) => literal(lit, e.pos)?,
            ExprKind::Column { qualifier, name } => sc.resolve(qualifier.as_ref(), name)?.0,
            ExprKind::Unary {
                op: UnaryOp::Neg,
                expr,
            } if matches!(expr.kind, ExprKind::Literal(Literal::Number(_))) => {
                let ExprKind::Literal(Literal::Number(text)) = &expr.kind else {
                    unreachable!()
                };
                let (value, ty) = number_literal(text, true)?;
                Expr::Literal { value, ty }
            }
            ExprKind::Unary { op, expr } => {
                let inner = self.expr(expr, sc, mode)?;
                let ty = inner.data_type();
                match op {
                    UnaryOp::Not => {
                        check_boolean(ty, "NOT operand")?;
                        Expr::Not(Box::new(inner))
                    }
                    UnaryOp::Neg | UnaryOp::Plus => {
                        if !ty.is_numeric() && ty != DataType::Null {
                            return Err(Error::type_error(format!(
                                "unary minus/plus requires a numeric operand, got {ty}"
                            )));
                        }
                        if *op == UnaryOp::Plus {
                            inner
                        } else {
                            Expr::Negate {
                                expr: Box::new(inner),
                                ty,
                            }
                        }
                    }
                }
            }
            ExprKind::Binary { op, left, right } => {
                let l = self.expr(left, sc, mode)?;
                let r = self.expr(right, sc, mode)?;
                binary(*op, l, r)?
            }
            ExprKind::IsNull { expr, negated } => Expr::IsNull {
                expr: Box::new(self.expr(expr, sc, mode)?),
                negated: *negated,
            },
            ExprKind::Cast { expr, type_name } => {
                let inner = self.expr(expr, sc, mode)?;
                let mut params = Vec::new();
                for p in &type_name.params {
                    params.push(p.parse::<u64>().map_err(|_| {
                        type_name
                            .pos
                            .error(Error::semantic(format!("invalid type parameter '{p}'")))
                    })?);
                }
                let to = DataType::from_name(&type_name.name, &params)
                    .map_err(|err| type_name.pos.error(err))?;
                if !cast_allowed(inner.data_type(), to) {
                    return Err(Error::type_error(format!(
                        "cannot cast {} to {to}",
                        inner.data_type()
                    )));
                }
                Expr::Cast {
                    expr: Box::new(inner),
                    to,
                }
            }
            ExprKind::Function {
                name,
                args,
                distinct,
                star,
            } => self.function(name, args, *distinct, *star, sc, mode)?,
            ExprKind::Between {
                expr,
                low,
                high,
                negated,
            } => {
                let x = self.expr(expr, sc, mode)?;
                let lo = self.expr(low, sc, mode)?;
                let hi = self.expr(high, sc, mode)?;
                check_comparable(x.data_type(), lo.data_type())?;
                check_comparable(x.data_type(), hi.data_type())?;
                Expr::Between {
                    expr: Box::new(x),
                    low: Box::new(lo),
                    high: Box::new(hi),
                    negated: *negated,
                }
            }
            ExprKind::InList {
                expr,
                list,
                negated,
            } => {
                let x = self.expr(expr, sc, mode)?;
                let mut items = Vec::with_capacity(list.len());
                for item in list {
                    let b = self.expr(item, sc, mode)?;
                    check_comparable(x.data_type(), b.data_type())
                        .map_err(|err| item.pos.error(err))?;
                    items.push(b);
                }
                Expr::InList {
                    expr: Box::new(x),
                    list: items,
                    negated: *negated,
                }
            }
            ExprKind::Like {
                expr,
                pattern,
                negated,
            } => {
                let x = self.expr(expr, sc, mode)?;
                let p = self.expr(pattern, sc, mode)?;
                for t in [x.data_type(), p.data_type()] {
                    if t != DataType::String && t != DataType::Null {
                        return Err(Error::type_error(format!(
                            "LIKE requires STRING operands, got {t}"
                        )));
                    }
                }
                Expr::Like {
                    expr: Box::new(x),
                    pattern: Box::new(p),
                    negated: *negated,
                }
            }
            ExprKind::Case {
                operand,
                whens,
                else_expr,
            } => self.case(operand.as_deref(), whens, else_expr.as_deref(), sc, mode)?,
            ExprKind::Exists(q) => {
                let (sub, params) = self.subquery(q, sc)?;
                Expr::Exists { sub, params }
            }
            ExprKind::Subquery(q) => {
                let (sub, params) = self.subquery(q, sc)?;
                let ty = single_column(&sub)?;
                Expr::ScalarSubquery { sub, params, ty }
            }
            ExprKind::InSubquery {
                expr,
                query,
                negated,
            } => {
                let x = self.expr(expr, sc, mode)?;
                let (sub, params) = self.subquery(query, sc)?;
                let ty = single_column(&sub)?;
                check_comparable(x.data_type(), ty)?;
                Expr::InSubquery {
                    domain: KeyDomain::of(x.data_type(), ty),
                    expr: Box::new(x),
                    sub,
                    params,
                    negated: *negated,
                }
            }
        })
    }

    fn case(
        &self,
        operand: Option<&ast::Expr>,
        whens: &[(ast::Expr, ast::Expr)],
        else_expr: Option<&ast::Expr>,
        sc: &ExprScope<'_>,
        mode: &mut AggMode<'_>,
    ) -> Result<Expr> {
        let operand = match operand {
            Some(o) => Some(self.expr(o, sc, mode)?),
            None => None,
        };
        let mut conds = Vec::with_capacity(whens.len());
        let mut results = Vec::with_capacity(whens.len() + 1);
        for (w, t) in whens {
            let c = self.expr(w, sc, mode)?;
            match &operand {
                Some(o) => check_comparable(o.data_type(), c.data_type()),
                None => check_boolean(c.data_type(), "CASE WHEN condition"),
            }
            .map_err(|err| w.pos.error(err))?;
            conds.push(c);
            results.push(self.expr(t, sc, mode)?);
        }
        let has_else = else_expr.is_some();
        if let Some(e) = else_expr {
            results.push(self.expr(e, sc, mode)?);
        }
        let types: Vec<DataType> = results.iter().map(|r| r.data_type()).collect();
        let ty = common_type(&types)?;
        let mut results: Vec<Expr> = results.into_iter().map(|r| coerce(r, ty)).collect();
        let else_expr = if has_else {
            results.pop().map(Box::new)
        } else {
            None
        };
        Ok(Expr::Case {
            operand: operand.map(Box::new),
            whens: conds.into_iter().zip(results).collect(),
            else_expr,
            ty,
        })
    }

    /// Binds a subquery appearing in an expression evaluated in `sc`.
    fn subquery(
        &self,
        q: &ast::Query,
        sc: &ExprScope<'_>,
    ) -> Result<(Arc<SubqueryPlan>, Vec<Expr>)> {
        let corr = Correlation::new(sc);
        let plan = self.query(q, Some(&corr), sc.env)?;
        let plan = optimizer::optimize(plan, self.ctx.optimize);
        let sub = SubqueryPlan {
            id: self.next_subquery_id(),
            plan,
        };
        Ok((Arc::new(sub), corr.params.into_inner()))
    }
}

/// Type of the only column of a scalar / IN subquery.
fn single_column(sub: &SubqueryPlan) -> Result<DataType> {
    match sub.plan.schema() {
        [f] => Ok(f.data_type),
        s => Err(Error::semantic(format!(
            "subquery must return exactly one column, got {}",
            s.len()
        ))),
    }
}

/// Types a binary operator application.
fn binary(op: BinaryOp, l: Expr, r: Expr) -> Result<Expr> {
    let (lt, rt) = (l.data_type(), r.data_type());
    Ok(match op {
        BinaryOp::And | BinaryOp::Or => {
            if !is_boolean(lt) || !is_boolean(rt) {
                return Err(Error::type_error(format!(
                    "{} requires BOOLEAN operands, got {lt} and {rt}",
                    op.symbol()
                )));
            }
            if op == BinaryOp::And {
                Expr::And(Box::new(l), Box::new(r))
            } else {
                Expr::Or(Box::new(l), Box::new(r))
            }
        }
        BinaryOp::Concat => {
            let ok = |t: DataType| t == DataType::String || t == DataType::Null;
            if !ok(lt) || !ok(rt) {
                return Err(Error::type_error(format!(
                    "|| requires STRING operands, got {lt} and {rt}"
                )));
            }
            Expr::Concat(Box::new(l), Box::new(r))
        }
        op if op.is_comparison() => {
            check_comparable(lt, rt)?;
            Expr::Compare {
                op,
                left: Box::new(l),
                right: Box::new(r),
            }
        }
        op => {
            let (ty, kind) = arithmetic_type(op, lt, rt)?;
            Expr::Arith {
                op,
                kind,
                left: Box::new(l),
                right: Box::new(r),
                ty,
            }
        }
    })
}
