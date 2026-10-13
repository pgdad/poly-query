//! Semantic analysis: name resolution, typing and validation of the AST,
//! producing a logical plan (semantics.md, types.md).
//!
//! * [`scope`]     — range variables, CTE environments, correlation
//! * [`exprs`]     — expression binding and typing
//! * [`functions`] — scalar and aggregate function signatures
//! * [`joins`]     — join chains (balanced trees for long ones)
//!
//! This module binds whole queries: WITH, FROM (joins, derived tables),
//! WHERE, GROUP BY / HAVING (with the grouping rule of semantics.md §5),
//! the SELECT list, DISTINCT, ORDER BY and LIMIT/OFFSET, and `UNION ALL`
//! compounds (CR-1: branch column counts, common output types, ORDER BY
//! restricted to output columns).

mod exprs;
mod functions;
mod joins;
mod scope;

use std::cell::Cell;
use std::collections::HashMap;

use super::expr::{AggregateCall, Expr};
use super::logical::{LogicalPlan, SortKey};
use crate::catalog::Catalog;
use crate::error::{Error, Result};
use crate::exec::eval::eval_constant;
use crate::planner::typing::{coerce, common_type};
use crate::sql::ast::{self, ExprKind, FromItem, Literal, SelectItem};
use crate::sql::lexer::Pos;
use crate::storage::Field;
use crate::types::{DataType, Value};
use scope::{Correlation, CteDef, CteEnv, ExprScope, Scope, corr_key};

pub use exprs::number_literal;

/// Inputs to semantic analysis besides the AST.
pub struct BindContext<'a> {
    pub catalog: &'a Catalog,
    /// Whether test-only functions (`PQ_SLEEP`) are enabled.
    pub test_functions: bool,
}

/// Binds a query AST into a (not yet optimized) logical plan.
pub fn plan_query(q: &ast::Query, ctx: &BindContext<'_>) -> Result<LogicalPlan> {
    let binder = Binder {
        ctx,
        next_subquery: Cell::new(0),
        plan_units: Cell::new(0),
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
    /// Plan size (`LogicalPlan::size` units) added by expanding CTE
    /// references and building joins.
    plan_units: Cell<usize>,
}

/// One output column of a SELECT list.
struct Output {
    expr: Expr,
    name: String,
    /// Named by an explicit `AS alias` (eligible for GROUP BY alias lookup).
    aliased: bool,
}

/// The clauses that follow the SELECT core(s) of a query: `ORDER BY` and
/// `LIMIT`/`OFFSET`. Branches of a compound have none of them.
#[derive(Clone, Copy, Default)]
struct Tail<'q> {
    order_by: &'q [ast::OrderItem],
    limit: Option<&'q ast::Expr>,
    offset: Option<&'q ast::Expr>,
}

impl<'q> Tail<'q> {
    fn of(q: &'q ast::Query) -> Tail<'q> {
        Tail {
            order_by: &q.order_by,
            limit: q.limit.as_ref(),
            offset: q.offset.as_ref(),
        }
    }
}

/// Adds `Sort` and `Limit` nodes on top of `plan` as requested.
fn sort_and_limit(
    mut plan: LogicalPlan,
    keys: Vec<SortKey>,
    limit: Option<u64>,
    offset: u64,
) -> LogicalPlan {
    if !keys.is_empty() {
        plan = LogicalPlan::Sort {
            input: Box::new(plan),
            keys,
        };
    }
    if limit.is_some() || offset > 0 {
        plan = LogicalPlan::Limit {
            input: Box::new(plan),
            offset,
            limit,
        };
    }
    plan
}

/// Converts the output of a compound branch to the compound's column types
/// (`schema`), wrapping it in a projection of casts where a type differs.
fn conform_branch(plan: LogicalPlan, schema: &[Field]) -> LogicalPlan {
    let types_match = plan
        .schema()
        .iter()
        .zip(schema)
        .all(|(f, out)| f.data_type == out.data_type);
    if types_match {
        return plan;
    }
    let exprs = plan
        .schema()
        .iter()
        .zip(schema)
        .enumerate()
        .map(|(index, (f, out))| {
            let column = Expr::Column {
                index,
                ty: f.data_type,
            };
            match (f.data_type, out.data_type) {
                // An untyped NULL column adopts the common type.
                (DataType::Null, to) if to != DataType::Null => Expr::Cast {
                    expr: Box::new(column),
                    to,
                },
                (_, to) => coerce(column, to),
            }
        })
        .collect();
    LogicalPlan::Project {
        input: Box::new(plan),
        exprs,
        schema: schema.to_vec(),
    }
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
/// Counts the table / CTE references in the FROM clauses of `q` and of
/// every query nested in it, by ASCII-lowercased name, except references
/// to names defined by a nested `WITH` where they are visible (`shadowed`,
/// with multiplicities). For the CTEs of `q`'s own `WITH` the count bounds
/// the number of references that resolve to them.
fn count_table_refs(
    q: &ast::Query,
    counts: &mut HashMap<String, usize>,
    shadowed: &mut HashMap<String, usize>,
) -> Result<()> {
    count_refs(q, counts, shadowed, false)
}

/// [`count_table_refs`]; `nested` tells whether `q`'s own CTE names shadow
/// (they do for queries nested in the one whose CTEs are counted).
fn count_refs(
    q: &ast::Query,
    counts: &mut HashMap<String, usize>,
    shadowed: &mut HashMap<String, usize>,
    nested: bool,
) -> Result<()> {
    crate::stack::check()?;
    let mut defined = Vec::new();
    let result = count_query_refs(q, counts, shadowed, nested, &mut defined);
    for name in defined {
        if let Some(n) = shadowed.get_mut(&name) {
            *n -= 1;
            if *n == 0 {
                shadowed.remove(&name);
            }
        }
    }
    result
}

/// [`count_refs`] for one query; the CTE names it adds to `shadowed` are
/// recorded in `defined` (and removed again by the caller).
fn count_query_refs(
    q: &ast::Query,
    counts: &mut HashMap<String, usize>,
    shadowed: &mut HashMap<String, usize>,
    nested: bool,
    defined: &mut Vec<String>,
) -> Result<()> {
    for cte in &q.with {
        // A CTE's body sees the earlier CTEs of its WITH, not itself.
        count_refs(&cte.query, counts, shadowed, true)?;
        if nested {
            let name = cte.name.value.to_ascii_lowercase();
            *shadowed.entry(name.clone()).or_default() += 1;
            defined.push(name);
        }
    }
    let mut exprs: Vec<&ast::Expr> = Vec::new();
    for core in q.branches() {
        for item in &core.items {
            if let SelectItem::Expr { expr, .. } = item {
                exprs.push(expr);
            }
        }
        if let Some(from) = &core.from {
            count_from_refs(from, counts, shadowed, &mut exprs)?;
        }
        exprs.extend(&core.where_clause);
        exprs.extend(&core.group_by);
        exprs.extend(&core.having);
    }
    exprs.extend(q.order_by.iter().map(|o| &o.expr));
    exprs.extend(&q.limit);
    exprs.extend(&q.offset);
    // Expressions are walked with an explicit stack (operator chains are
    // deep); only their subqueries recurse.
    while let Some(e) = exprs.pop() {
        crate::interrupt::poll()?;
        match &e.kind {
            ExprKind::Subquery(sub) | ExprKind::Exists(sub) => {
                count_refs(sub, counts, shadowed, true)?
            }
            ExprKind::InSubquery { query, .. } => count_refs(query, counts, shadowed, true)?,
            _ => {}
        }
        exprs.extend(exprs::ast_children(e));
    }
    Ok(())
}

fn count_from_refs<'q>(
    item: &'q FromItem,
    counts: &mut HashMap<String, usize>,
    shadowed: &mut HashMap<String, usize>,
    exprs: &mut Vec<&'q ast::Expr>,
) -> Result<()> {
    // Join chains are left-deep: walk the left spine iteratively.
    let mut item = item;
    loop {
        match item {
            FromItem::Table { name, .. } => {
                let key = name.value.to_ascii_lowercase();
                if !shadowed.contains_key(&key) {
                    *counts.entry(key).or_default() += 1;
                }
                return Ok(());
            }
            FromItem::Derived { query, .. } => return count_refs(query, counts, shadowed, true),
            FromItem::Join {
                left, right, on, ..
            } => {
                count_from_refs(right, counts, shadowed, exprs)?;
                exprs.extend(on);
                item = left;
            }
        }
    }
}

fn ordinal(e: &ast::Expr) -> Option<&str> {
    match &e.kind {
        ExprKind::Literal(Literal::Number(text)) if text.bytes().all(|b| b.is_ascii_digit()) => {
            Some(text)
        }
        _ => None,
    }
}

impl Binder<'_> {
    /// Accounts `units` of plan size (see `sql::limits::MAX_PLAN_SIZE`).
    fn grow_plan(&self, units: usize) -> Result<()> {
        let total = self.plan_units.get().saturating_add(units);
        self.plan_units.set(total);
        crate::sql::limits::check_plan_size(total)
    }

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
        crate::stack::check()?;
        crate::interrupt::poll()?;
        if q.with.is_empty() {
            return self.query_body(q, corr, env);
        }
        let mut local = CteEnv::new(Some(env));
        let mut uses = HashMap::new();
        count_table_refs(q, &mut uses, &mut HashMap::new())?;
        for cte in &q.with {
            if local.defines(&cte.name.value) {
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
            // Only a CTE of a subquery can reference outer columns.
            let mut correlated = false;
            if corr.is_some() {
                plan.visit_exprs(&mut |e| {
                    correlated |= e.any(&|x| matches!(x, Expr::Param { .. }));
                });
            }
            let uses = uses
                .get(&cte.name.value.to_ascii_lowercase())
                .copied()
                .unwrap_or(0);
            local.define(CteDef::new(
                cte.name.value.clone(),
                plan,
                uses,
                fields,
                corr_key(corr),
                correlated,
            ));
        }
        self.query_body(q, corr, &local)
    }

    /// Binds the body of a query (after its WITH clause): a single SELECT
    /// or a `UNION ALL` compound, with ORDER BY / LIMIT.
    fn query_body(
        &self,
        q: &ast::Query,
        corr: Option<&Correlation<'_>>,
        env: &CteEnv<'_>,
    ) -> Result<LogicalPlan> {
        if q.is_compound() {
            self.compound(q, corr, env)
        } else {
            self.select(&q.body, Tail::of(q), q.pos, corr, env)
        }
    }

    /// Binds `core UNION ALL core …` with the ORDER BY / LIMIT of the whole
    /// compound (CR-1 §2).
    fn compound(
        &self,
        q: &ast::Query,
        corr: Option<&Correlation<'_>>,
        env: &CteEnv<'_>,
    ) -> Result<LogicalPlan> {
        let branches = q
            .branches()
            .map(|core| self.select(core, Tail::default(), q.pos, corr, env))
            .collect::<Result<Vec<_>>>()?;
        let first = branches[0].schema();
        if let Some(b) = branches.iter().find(|b| b.width() != first.len()) {
            return Err(q.pos.error(Error::semantic(format!(
                "UNION ALL branches have different numbers of columns ({} and {})",
                first.len(),
                b.width()
            ))));
        }
        let schema = first
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let types: Vec<DataType> =
                    branches.iter().map(|b| b.schema()[i].data_type).collect();
                let ty = common_type(&types).map_err(|e| {
                    q.pos.error(Error::type_error(format!(
                        "UNION ALL column {} ('{}'): {}",
                        i + 1,
                        f.name,
                        e.message
                    )))
                })?;
                Ok(Field::new(f.name.clone(), ty))
            })
            .collect::<Result<Vec<Field>>>()?;
        let inputs = branches
            .into_iter()
            .map(|b| conform_branch(b, &schema))
            .collect();

        // ORDER BY: output column names (of the first branch) or positions.
        let mut keys = Vec::with_capacity(q.order_by.len());
        for item in &q.order_by {
            let index = self.compound_order_target(&item.expr, &schema)?;
            keys.push(SortKey {
                expr: Expr::Column {
                    index,
                    ty: schema[index].data_type,
                },
                descending: item.descending,
                nulls_first: item.nulls_first.unwrap_or(!item.descending),
            });
        }
        let (limit, offset) = self.limit_offset(Tail::of(q), env)?;
        let plan = LogicalPlan::UnionAll { inputs, schema };
        Ok(sort_and_limit(plan, keys, limit, offset))
    }

    /// Resolves an ORDER BY item of a compound query: a 1-based position or
    /// the unqualified name of an output column; anything else is an error.
    fn compound_order_target(&self, e: &ast::Expr, schema: &[Field]) -> Result<usize> {
        if let Some(text) = ordinal(e) {
            let k: usize = text.parse().unwrap_or(0);
            if k == 0 || k > schema.len() {
                return Err(e.pos.error(Error::semantic(format!(
                    "ORDER BY position {text} is out of range"
                ))));
            }
            return Ok(k - 1);
        }
        if let ExprKind::Column {
            qualifier: None,
            name,
        } = &e.kind
        {
            let mut matches = schema
                .iter()
                .enumerate()
                .filter(|(_, f)| name.matches(&f.name))
                .map(|(i, _)| i);
            return match (matches.next(), matches.next()) {
                (Some(i), None) => Ok(i),
                (Some(_), Some(_)) => Err(name.pos.error(Error::semantic(format!(
                    "ORDER BY '{}' is ambiguous",
                    name.value
                )))),
                (None, _) => Err(name.pos.error(Error::semantic(format!(
                    "ORDER BY '{}' is not an output column of the UNION ALL",
                    name.value
                )))),
            };
        }
        Err(e.pos.error(Error::semantic(
            "ORDER BY of a UNION ALL must name an output column or position",
        )))
    }

    /// Evaluates the LIMIT and OFFSET clauses (no limit, offset 0 if absent).
    fn limit_offset(&self, tail: Tail<'_>, env: &CteEnv<'_>) -> Result<(Option<u64>, u64)> {
        let limit = match tail.limit {
            Some(e) => self.limit_value(e, "LIMIT", env)?,
            None => None,
        };
        let offset = match tail.offset {
            Some(e) => self.limit_value(e, "OFFSET", env)?.unwrap_or(0),
            None => 0,
        };
        Ok((limit, offset))
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
                    let plan = def
                        .instantiate(|size| self.grow_plan(size))
                        .map_err(|e| name.pos.error(e))?;
                    return Ok((plan, Scope::single(var, def.fields.clone())));
                }
                let table = self.ctx.catalog.get(&name.value).ok_or_else(|| {
                    name.pos
                        .error(Error::semantic(format!("unknown table '{}'", name.value)))
                })?;
                let fields = table.fields.clone();
                let plan = LogicalPlan::Scan {
                    columns: (0..fields.len()).collect(),
                    schema: fields.clone(),
                    table,
                };
                Ok((plan, Scope::single(var, fields)))
            }
            FromItem::Derived { query, alias } => {
                let plan = self.query(query, corr, env)?;
                let fields = plan.schema().to_vec();
                Ok((plan, Scope::single(&alias.value, fields)))
            }
            FromItem::Join { .. } => self.bind_join_chain(item, corr, env),
        }
    }

    /// Binds a SELECT core plus the ORDER BY / LIMIT in `tail`; `pos` is
    /// the position of the query (for errors without a better location).
    fn select(
        &self,
        core: &ast::SelectCore,
        tail: Tail<'_>,
        pos: Pos,
        corr: Option<&Correlation<'_>>,
        env: &CteEnv<'_>,
    ) -> Result<LogicalPlan> {
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
            || tail.order_by.iter().any(|o| contains_aggregate(&o.expr));
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
        for item in tail.order_by {
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

        let (limit, offset) = self.limit_offset(tail, env)?;

        // Grouping rule and aggregation.
        let mut project_exprs: Vec<Expr> = outputs
            .iter()
            .map(|o| o.expr.clone())
            .chain(hidden)
            .collect();
        let mut plan = LogicalPlan::filter(input, predicate);
        if aggregated {
            for e in project_exprs.iter_mut().chain(having.iter_mut()) {
                rewrite_grouped(e, &group_by).map_err(|err| pos.error(err))?;
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
        plan = sort_and_limit(plan, sort_keys, limit, offset);
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
