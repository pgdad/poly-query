//! Semantic analysis: name resolution, typing and validation of the AST,
//! producing a logical plan (semantics.md, types.md).
//!
//! * [`scope`]     — range variables, CTE environments, correlation
//! * [`exprs`]     — expression binding and typing
//! * [`functions`] — scalar and aggregate function signatures
//!
//! This module binds whole queries: WITH, FROM (joins, derived tables),
//! WHERE, GROUP BY / HAVING (with the grouping rule of semantics.md §5),
//! the SELECT list, DISTINCT, ORDER BY and LIMIT/OFFSET.

mod exprs;
mod functions;
mod scope;

use std::cell::Cell;

use super::expr::{AggregateCall, Expr};
use super::logical::{JoinType, LogicalPlan, SortKey};
use crate::catalog::Catalog;
use crate::error::{Error, Result};
use crate::exec::eval::eval_constant;
use crate::sql::ast::{self, ExprKind, FromItem, JoinKind, Literal, SelectItem};
use crate::storage::Field;
use crate::types::{DataType, Value};
use scope::{Correlation, CteDef, CteEnv, ExprScope, Scope, corr_key};

pub use exprs::number_literal;

/// Inputs to semantic analysis besides the AST.
pub struct BindContext<'a> {
    pub catalog: &'a Catalog,
    /// Whether test-only functions (`PQ_SLEEP`) are enabled.
    pub test_functions: bool,
    /// Whether logical rewrites are enabled (query option `optimize`).
    pub optimize: bool,
}

/// Binds a query AST into a (not yet optimized) logical plan. Subquery plans
/// embedded in expressions are optimized as they are bound.
pub fn plan_query(q: &ast::Query, ctx: &BindContext<'_>) -> Result<LogicalPlan> {
    let binder = Binder {
        ctx,
        next_subquery: Cell::new(0),
    };
    binder.query(q, None, &CteEnv::default())
}

/// How aggregate calls are treated while binding an expression.
pub(super) enum AggMode<'m> {
    /// Aggregates are not allowed (WHERE, ON, GROUP BY, LIMIT, non-aggregated SELECT).
    Forbidden(&'static str),
    /// Aggregated query outside any aggregate: aggregate calls are collected
    /// and replaced by `Expr::AggRef` placeholders.
    Collect(&'m mut Vec<AggregateCall>),
    /// Inside an aggregate's argument: nested aggregates are not allowed.
    Inside,
}

pub(super) struct Binder<'a> {
    ctx: &'a BindContext<'a>,
    next_subquery: Cell<usize>,
}

/// One output column of a SELECT list.
struct Output {
    expr: Expr,
    name: String,
    /// Named by an explicit `AS alias` (eligible for GROUP BY alias lookup).
    aliased: bool,
}

/// True if the AST expression contains an aggregate call outside subqueries.
fn contains_aggregate(e: &ast::Expr) -> bool {
    if let ExprKind::Function { name, .. } = &e.kind
        && functions::is_aggregate(&name.value)
    {
        return true;
    }
    exprs::ast_children(e).into_iter().any(contains_aggregate)
}

fn has_agg_ref(e: &Expr) -> bool {
    e.any(&|x| matches!(x, Expr::AggRef { .. }))
}

/// Applies the grouping rule (semantics.md §5): subexpressions equal to a
/// GROUP BY expression become references to the group key, aggregate
/// placeholders become references to the aggregate output, and any other
/// input column reference is an error.
fn rewrite_grouped(e: &mut Expr, groups: &[Expr]) -> Result<()> {
    if let Some(i) = groups.iter().position(|g| g == e) {
        *e = Expr::Column {
            index: i,
            ty: e.data_type(),
        };
        return Ok(());
    }
    match e {
        Expr::AggRef { index, ty } => {
            *e = Expr::Column {
                index: groups.len() + *index,
                ty: *ty,
            };
            Ok(())
        }
        Expr::Column { .. } => Err(Error::semantic(
            "column must appear in GROUP BY or be used in an aggregate function",
        )),
        _ => e
            .children_mut()
            .into_iter()
            .try_for_each(|c| rewrite_grouped(c, groups)),
    }
}

/// Positive integer literal text (`ORDER BY 2`, `GROUP BY 1`).
fn ordinal(e: &ast::Expr) -> Option<&str> {
    match &e.kind {
        ExprKind::Literal(Literal::Number(text)) if text.bytes().all(|b| b.is_ascii_digit()) => {
            Some(text)
        }
        _ => None,
    }
}

impl Binder<'_> {
    fn next_subquery_id(&self) -> usize {
        let id = self.next_subquery.get();
        self.next_subquery.set(id + 1);
        id
    }

    /// Binds `[WITH …] SELECT …`; `corr` links to the enclosing query when
    /// this is (part of) a subquery.
    fn query(
        &self,
        q: &ast::Query,
        corr: Option<&Correlation<'_>>,
        env: &CteEnv<'_>,
    ) -> Result<LogicalPlan> {
        if q.with.is_empty() {
            return self.select(q, corr, env);
        }
        let mut local = CteEnv {
            defs: Vec::new(),
            parent: Some(env),
        };
        for cte in &q.with {
            if local.defs.iter().any(|d| cte.name.matches(&d.name)) {
                return Err(cte.name.pos.error(Error::semantic(format!(
                    "duplicate CTE name '{}'",
                    cte.name.value
                ))));
            }
            // A CTE sees earlier CTEs of the same WITH, not itself.
            let plan = self.query(&cte.query, corr, &local)?;
            let mut fields = plan.schema().to_vec();
            if !cte.columns.is_empty() {
                if cte.columns.len() != fields.len() {
                    return Err(cte.name.pos.error(Error::semantic(format!(
                        "CTE '{}' has {} columns but its column list names {}",
                        cte.name.value,
                        fields.len(),
                        cte.columns.len()
                    ))));
                }
                for (f, c) in fields.iter_mut().zip(&cte.columns) {
                    f.name = c.value.clone();
                }
            }
            let mut correlated = false;
            plan.visit_exprs(&mut |e| {
                correlated |= e.any(&|x| matches!(x, Expr::Param { .. }));
            });
            local.defs.push(CteDef {
                name: cte.name.value.clone(),
                plan,
                fields,
                corr_key: corr_key(corr),
                correlated,
            });
        }
        self.select(q, corr, &local)
    }

    /// Binds a FROM item, returning its plan and range variables.
    fn bind_from(
        &self,
        item: &FromItem,
        corr: Option<&Correlation<'_>>,
        env: &CteEnv<'_>,
    ) -> Result<(LogicalPlan, Scope)> {
        match item {
            FromItem::Table { name, alias } => {
                let var = &alias.as_ref().unwrap_or(name).value;
                if let Some(def) = env.lookup(&name.value) {
                    if def.correlated && def.corr_key != corr_key(corr) {
                        return Err(name.pos.error(Error::unsupported(
                            "a correlated CTE referenced from a nested subquery is not supported",
                        )));
                    }
                    return Ok((def.plan.clone(), Scope::single(var, def.fields.clone())));
                }
                let table = self.ctx.catalog.get(&name.value).ok_or_else(|| {
                    name.pos
                        .error(Error::semantic(format!("unknown table '{}'", name.value)))
                })?;
                let fields = table.fields.clone();
                let plan = LogicalPlan::Scan {
                    columns: (0..fields.len()).collect(),
                    schema: fields.clone(),
                    indexes: self.ctx.catalog.indexes_for(&table),
                    table,
                };
                Ok((plan, Scope::single(var, fields)))
            }
            FromItem::Derived { query, alias } => {
                let plan = self.query(query, corr, env)?;
                let fields = plan.schema().to_vec();
                Ok((plan, Scope::single(&alias.value, fields)))
            }
            FromItem::Join {
                left,
                right,
                kind,
                on,
                pos,
            } => {
                let (lp, ls) = self.bind_from(left, corr, env)?;
                let (rp, rs) = self.bind_from(right, corr, env)?;
                let scope = Scope::merge(ls, rs).map_err(|e| pos.error(e))?;
                let on = match on {
                    Some(cond) => {
                        let sc = ExprScope {
                            scope: &scope,
                            corr,
                            env,
                        };
                        let bound = self.expr(cond, &sc, &mut AggMode::Forbidden("ON"))?;
                        crate::planner::typing::check_boolean(bound.data_type(), "ON condition")
                            .map_err(|e| cond.pos.error(e))?;
                        Some(bound)
                    }
                    None => None,
                };
                let join_type = match kind {
                    JoinKind::Inner => JoinType::Inner,
                    JoinKind::Left => JoinType::Left,
                    JoinKind::Cross => JoinType::Cross,
                };
                Ok((LogicalPlan::join(lp, rp, join_type, on), scope))
            }
        }
    }

    /// Binds the SELECT core plus ORDER BY / LIMIT of a query.
    fn select(
        &self,
        q: &ast::Query,
        corr: Option<&Correlation<'_>>,
        env: &CteEnv<'_>,
    ) -> Result<LogicalPlan> {
        let core = &q.body;
        let (input, scope) = match &core.from {
            None => (LogicalPlan::SingleRow, Scope::default()),
            Some(f) => self.bind_from(f, corr, env)?,
        };
        let sc = ExprScope {
            scope: &scope,
            corr,
            env,
        };

        // WHERE
        let predicate = match &core.where_clause {
            Some(w) => {
                let p = self.expr(w, &sc, &mut AggMode::Forbidden("WHERE"))?;
                crate::planner::typing::check_boolean(p.data_type(), "WHERE condition")
                    .map_err(|e| w.pos.error(e))?;
                Some(p)
            }
            None => None,
        };

        let aggregated = !core.group_by.is_empty()
            || core.having.is_some()
            || core
                .items
                .iter()
                .any(|i| matches!(i, SelectItem::Expr { expr, .. } if contains_aggregate(expr)))
            || q.order_by.iter().any(|o| contains_aggregate(&o.expr));
        let mut aggregates: Vec<AggregateCall> = Vec::new();

        // SELECT list (expressions over the input; aggregates as placeholders)
        let mut outputs: Vec<Output> = Vec::new();
        for item in &core.items {
            match item {
                SelectItem::Wildcard(pos) => {
                    if scope.vars.is_empty() {
                        return Err(pos.error(Error::semantic("SELECT * requires a FROM clause")));
                    }
                    for var in &scope.vars {
                        push_var_columns(&mut outputs, var);
                    }
                }
                SelectItem::QualifiedWildcard(qual) => {
                    let var = scope.var(qual).ok_or_else(|| {
                        qual.pos.error(Error::semantic(format!(
                            "unknown table or alias '{}'",
                            qual.value
                        )))
                    })?;
                    push_var_columns(&mut outputs, var);
                }
                SelectItem::Expr { expr, alias } => {
                    let (bound, column_name) = match &expr.kind {
                        ExprKind::Column { qualifier, name } => {
                            let (e, n) = sc.resolve(qualifier.as_ref(), name)?;
                            (e, Some(n))
                        }
                        _ => {
                            let mut mode = if aggregated {
                                AggMode::Collect(&mut aggregates)
                            } else {
                                AggMode::Forbidden("a non-aggregated SELECT list")
                            };
                            (self.expr(expr, &sc, &mut mode)?, None)
                        }
                    };
                    let name = match (alias, column_name) {
                        (Some(a), _) => a.value.clone(),
                        (None, Some(n)) => n,
                        (None, None) => format!("_col{}", outputs.len() + 1),
                    };
                    outputs.push(Output {
                        expr: bound,
                        name,
                        aliased: alias.is_some(),
                    });
                }
            }
        }
        let visible = outputs.len();

        // GROUP BY
        let mut group_by = Vec::with_capacity(core.group_by.len());
        for g in &core.group_by {
            let e = self.group_item(g, &sc, &outputs)?;
            group_by.push(e);
        }

        // HAVING
        let mut having = match &core.having {
            Some(h) => {
                let e = self.expr(h, &sc, &mut AggMode::Collect(&mut aggregates))?;
                crate::planner::typing::check_boolean(e.data_type(), "HAVING condition")
                    .map_err(|err| h.pos.error(err))?;
                Some(e)
            }
            None => None,
        };

        // ORDER BY: output columns by ordinal or name; other expressions are
        // matched against the select list or become hidden columns.
        let mut hidden: Vec<Expr> = Vec::new();
        let mut sort_keys: Vec<SortKey> = Vec::new();
        for item in &q.order_by {
            let index = match self.order_target(&item.expr, &outputs)? {
                Some(i) => i,
                None => {
                    let bound = if aggregated {
                        self.expr(&item.expr, &sc, &mut AggMode::Collect(&mut aggregates))?
                    } else {
                        self.expr(&item.expr, &sc, &mut AggMode::Forbidden("ORDER BY"))?
                    };
                    if let Some(i) = outputs.iter().position(|o| o.expr == bound) {
                        i
                    } else if core.distinct {
                        return Err(item.expr.pos.error(Error::semantic(
                            "ORDER BY expressions must appear in the select list of SELECT DISTINCT",
                        )));
                    } else if let Some(h) = hidden.iter().position(|h| *h == bound) {
                        visible + h
                    } else {
                        hidden.push(bound);
                        visible + hidden.len() - 1
                    }
                }
            };
            sort_keys.push(SortKey {
                expr: Expr::Column {
                    index,
                    ty: DataType::Null,
                },
                descending: item.descending,
                nulls_first: item.nulls_first.unwrap_or(!item.descending),
            });
        }

        // LIMIT / OFFSET
        let limit = match &q.limit {
            Some(e) => self.limit_value(e, "LIMIT", env)?,
            None => None,
        };
        let offset = match &q.offset {
            Some(e) => self.limit_value(e, "OFFSET", env)?.unwrap_or(0),
            None => 0,
        };

        // Grouping rule and aggregation.
        let mut project_exprs: Vec<Expr> = outputs
            .iter()
            .map(|o| o.expr.clone())
            .chain(hidden)
            .collect();
        let mut plan = LogicalPlan::filter(input, predicate);
        if aggregated {
            for e in project_exprs.iter_mut().chain(having.iter_mut()) {
                rewrite_grouped(e, &group_by).map_err(|err| q.pos.error(err))?;
            }
            let schema = group_by
                .iter()
                .enumerate()
                .map(|(i, g)| Field::new(format!("group{}", i + 1), g.data_type()))
                .chain(aggregates.iter().map(|a| Field::new(a.to_string(), a.ty)))
                .collect();
            plan = LogicalPlan::Aggregate {
                input: Box::new(plan),
                group_by,
                aggregates,
                schema,
            };
            plan = LogicalPlan::filter(plan, having.take());
        }

        let mut schema: Vec<Field> = outputs
            .iter()
            .map(|o| Field::new(o.name.clone(), o.expr.data_type()))
            .collect();
        for (i, e) in project_exprs[visible..].iter().enumerate() {
            schema.push(Field::new(format!("_sort{}", i + 1), e.data_type()));
        }
        for k in &mut sort_keys {
            if let Expr::Column { index, ty } = &mut k.expr {
                *ty = schema[*index].data_type;
            }
        }
        let has_hidden = schema.len() > visible;
        plan = LogicalPlan::Project {
            input: Box::new(plan),
            exprs: project_exprs,
            schema,
        };
        if core.distinct {
            plan = LogicalPlan::Distinct {
                input: Box::new(plan),
            };
        }
        if !sort_keys.is_empty() {
            plan = LogicalPlan::Sort {
                input: Box::new(plan),
                keys: sort_keys,
            };
        }
        if limit.is_some() || offset > 0 {
            plan = LogicalPlan::Limit {
                input: Box::new(plan),
                offset,
                limit,
            };
        }
        if has_hidden {
            let schema: Vec<Field> = plan.schema()[..visible].to_vec();
            let exprs = schema
                .iter()
                .enumerate()
                .map(|(i, f)| Expr::Column {
                    index: i,
                    ty: f.data_type,
                })
                .collect();
            plan = LogicalPlan::Project {
                input: Box::new(plan),
                exprs,
                schema,
            };
        }
        Ok(plan)
    }

    /// Binds one GROUP BY item (semantics.md §5): an ordinal, an input
    /// column, a SELECT alias, or an expression over input columns.
    fn group_item(&self, g: &ast::Expr, sc: &ExprScope<'_>, outputs: &[Output]) -> Result<Expr> {
        let from_output = |o: &Output| -> Result<Expr> {
            if has_agg_ref(&o.expr) {
                return Err(g.pos.error(Error::semantic(
                    "aggregate functions are not allowed in GROUP BY",
                )));
            }
            Ok(o.expr.clone())
        };
        if let Some(text) = ordinal(g) {
            let k: usize = text.parse().unwrap_or(0);
            if k == 0 || k > outputs.len() {
                return Err(g.pos.error(Error::semantic(format!(
                    "GROUP BY position {text} is out of range"
                ))));
            }
            return from_output(&outputs[k - 1]);
        }
        if let ExprKind::Column {
            qualifier: None,
            name,
        } = &g.kind
            && sc.scope.lookup(None, name)?.is_none()
        {
            let matches: Vec<&Output> = outputs
                .iter()
                .filter(|o| o.aliased && name.matches(&o.name))
                .collect();
            if let Some(first) = matches.first() {
                if matches.iter().any(|o| o.expr != first.expr) {
                    return Err(name.pos.error(Error::semantic(format!(
                        "GROUP BY '{}' is ambiguous",
                        name.value
                    ))));
                }
                return from_output(first);
            }
        }
        self.expr(g, sc, &mut AggMode::Forbidden("GROUP BY"))
    }

    /// Resolves an ORDER BY item to an output column, if it is an ordinal or
    /// an unqualified name of an output column (semantics.md §6).
    fn order_target(&self, e: &ast::Expr, outputs: &[Output]) -> Result<Option<usize>> {
        if let Some(text) = ordinal(e) {
            let k: usize = text.parse().unwrap_or(0);
            if k == 0 || k > outputs.len() {
                return Err(e.pos.error(Error::semantic(format!(
                    "ORDER BY position {text} is out of range"
                ))));
            }
            return Ok(Some(k - 1));
        }
        let ExprKind::Column {
            qualifier: None,
            name,
        } = &e.kind
        else {
            return Ok(None);
        };
        let matches: Vec<usize> = outputs
            .iter()
            .enumerate()
            .filter(|(_, o)| name.matches(&o.name))
            .map(|(i, _)| i)
            .collect();
        match matches.as_slice() {
            [] => Ok(None),
            [first, rest @ ..] => {
                if rest
                    .iter()
                    .all(|i| outputs[*i].expr == outputs[*first].expr)
                {
                    Ok(Some(*first))
                } else {
                    Err(name.pos.error(Error::semantic(format!(
                        "ORDER BY '{}' is ambiguous",
                        name.value
                    ))))
                }
            }
        }
    }

    /// Evaluates a LIMIT/OFFSET expression (None for NULL).
    fn limit_value(
        &self,
        e: &ast::Expr,
        clause: &'static str,
        env: &CteEnv<'_>,
    ) -> Result<Option<u64>> {
        let empty = Scope::default();
        let sc = ExprScope {
            scope: &empty,
            corr: None,
            env,
        };
        let bound = self.expr(e, &sc, &mut AggMode::Forbidden(clause))?;
        if !bound.is_constant() {
            return Err(e.pos.error(Error::semantic(format!(
                "{clause} must be a constant expression"
            ))));
        }
        match bound.data_type() {
            DataType::Int64 | DataType::Null => {}
            t => {
                return Err(e.pos.error(Error::type_error(format!(
                    "{clause} must be INT64, got {t}"
                ))));
            }
        }
        match eval_constant(&bound).map_err(|err| e.pos.error(err))? {
            Value::Null => Ok(None),
            Value::Int(v) if v >= 0 => Ok(Some(v as u64)),
            Value::Int(v) => Err(e.pos.error(Error::invalid_argument(format!(
                "{clause} must not be negative, got {v}"
            )))),
            v => Err(Error::internal(format!("unexpected {clause} value {v:?}"))),
        }
    }
}

fn push_var_columns(outputs: &mut Vec<Output>, var: &scope::RangeVar) {
    for (i, f) in var.fields.iter().enumerate() {
        outputs.push(Output {
            expr: Expr::Column {
                index: var.offset + i,
                ty: f.data_type,
            },
            name: f.name.clone(),
            aliased: false,
        });
    }
}
