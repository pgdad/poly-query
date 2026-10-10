//! Semantic analysis: name resolution, typing and validation of the AST,
//! producing a logical plan (semantics.md, types.md).

use std::sync::Arc;

use super::expr::{AggFunc, AggregateCall, ArithKind, Expr, ScalarFunc};
use super::logical::{LogicalPlan, SortKey};
use crate::catalog::Catalog;
use crate::error::{Error, Result};
use crate::exec::eval::eval_constant;
use crate::sql::ast::{self, BinaryOp, ExprKind, FromItem, Ident, Literal, SelectItem, UnaryOp};
use crate::sql::lexer::Pos;
use crate::storage::{Field, Table};
use crate::types::cast::cast_allowed;
use crate::types::{DataType, MAX_DECIMAL_PRECISION, Value, datetime};

/// Inputs to semantic analysis besides the AST.
pub struct BindContext<'a> {
    pub catalog: &'a Catalog,
    /// Whether test-only functions (`PQ_SLEEP`) are enabled.
    pub test_functions: bool,
}

/// Scalar functions of functions.md that this engine does not implement yet.
const UNSUPPORTED_FUNCTIONS: &[&str] = &[
    "ABS", "ROUND", "FLOOR", "CEIL", "CEILING", "SQRT", "POWER", "MOD", "LENGTH", "UPPER", "LOWER", "SUBSTR",
    "SUBSTRING", "TRIM", "LTRIM", "RTRIM", "REPLACE", "CONCAT", "COALESCE", "NULLIF", "YEAR", "MONTH", "DAY", "HOUR",
    "MINUTE", "SECOND", "DATE_TRUNC", "DATE_DIFF",
];

/// A named relation visible in a FROM clause.
#[derive(Debug, Clone)]
struct RangeVar {
    name: String,
    fields: Vec<Field>,
    /// Index of the relation's first column in the input row.
    offset: usize,
}

#[derive(Debug, Clone, Default)]
struct Scope {
    vars: Vec<RangeVar>,
}

impl Scope {
    fn resolve(&self, qualifier: Option<&Ident>, name: &Ident) -> Result<(usize, &Field)> {
        if let Some(q) = qualifier {
            let var = self
                .vars
                .iter()
                .find(|v| q.matches(&v.name))
                .ok_or_else(|| q.pos.error(Error::semantic(format!("unknown table or alias '{}'", q.value))))?;
            let (i, f) = var
                .fields
                .iter()
                .enumerate()
                .find(|(_, f)| name.matches(&f.name))
                .ok_or_else(|| name.pos.error(Error::semantic(format!("unknown column '{}.{}'", q.value, name.value))))?;
            return Ok((var.offset + i, f));
        }
        let mut found = None;
        for var in &self.vars {
            for (i, f) in var.fields.iter().enumerate() {
                if name.matches(&f.name) {
                    if found.is_some() {
                        return Err(name.pos.error(Error::semantic(format!("ambiguous column '{}'", name.value))));
                    }
                    found = Some((var.offset + i, f));
                }
            }
        }
        found.ok_or_else(|| name.pos.error(Error::semantic(format!("unknown column '{}'", name.value))))
    }
}

/// How aggregate calls are treated while binding an expression.
enum AggMode<'m> {
    /// Aggregates are not allowed (WHERE, LIMIT, non-aggregated SELECT).
    Forbidden(&'static str),
    /// Aggregated query, outside any aggregate: aggregate calls are collected
    /// and replaced by references to the aggregate output; input columns are
    /// not accessible.
    Collect(&'m mut Vec<AggregateCall>),
    /// Inside an aggregate's argument: nested aggregates are not allowed.
    Inside,
}

/// Plans a query AST.
pub fn plan_query(q: &ast::Query, ctx: &BindContext<'_>) -> Result<LogicalPlan> {
    Binder { ctx }.query(q)
}

struct Binder<'a> {
    ctx: &'a BindContext<'a>,
}

/// Walks AST children (not descending into subqueries).
fn ast_children(e: &ast::Expr) -> Vec<&ast::Expr> {
    match &e.kind {
        ExprKind::Literal(_) | ExprKind::Column { .. } | ExprKind::Exists(_) | ExprKind::Subquery(_) => vec![],
        ExprKind::Unary { expr, .. } | ExprKind::IsNull { expr, .. } | ExprKind::Cast { expr, .. } => vec![expr],
        ExprKind::InSubquery { expr, .. } => vec![expr],
        ExprKind::Binary { left, right, .. } => vec![left, right],
        ExprKind::Between { expr, low, high, .. } => vec![expr, low, high],
        ExprKind::InList { expr, list, .. } => std::iter::once(&**expr).chain(list.iter()).collect(),
        ExprKind::Like { expr, pattern, .. } => vec![expr, pattern],
        ExprKind::Function { args, .. } => args.iter().collect(),
        ExprKind::Case { operand, whens, else_expr } => {
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

fn contains_aggregate(e: &ast::Expr) -> bool {
    if let ExprKind::Function { name, .. } = &e.kind {
        if AggFunc::lookup(&name.value).is_some() {
            return true;
        }
    }
    ast_children(e).into_iter().any(contains_aggregate)
}

/// Parses an unsigned numeric literal (optionally negated) per types.md §3.
pub fn number_literal(text: &str, negate: bool) -> Result<(Value, DataType)> {
    let overflow = || Error::overflow(format!("numeric literal {}{text} is out of range", if negate { "-" } else { "" }));
    let float = || -> Result<(Value, DataType)> {
        let f: f64 = text.parse().map_err(|_| Error::parse(format!("invalid number '{text}'")))?;
        if !f.is_finite() {
            return Err(overflow());
        }
        let f = if negate { -f } else { f };
        Ok((Value::Float(crate::types::float::normalize(f)), DataType::Float64))
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
        let unscaled: i64 = if digits.is_empty() { 0 } else { digits.parse().map_err(|_| overflow())? };
        let unscaled = if negate { -unscaled } else { unscaled };
        return Ok((Value::Decimal(unscaled, scale as u8), DataType::decimal(precision as u8, scale as u8)));
    }
    let digits = text.trim_start_matches('0');
    if digits.len() > 20 {
        return Err(overflow());
    }
    let v: i128 = if digits.is_empty() { 0 } else { digits.parse().map_err(|_| overflow())? };
    let v = if negate { -v } else { v };
    let v = i64::try_from(v).map_err(|_| overflow())?;
    Ok((Value::Int(v), DataType::Int64))
}

/// Result type and evaluation domain of an arithmetic operator (types.md §4).
fn arithmetic_type(op: BinaryOp, l: DataType, r: DataType, pos: Pos) -> Result<(DataType, ArithKind)> {
    let (l, r) = match (l, r) {
        (DataType::Null, DataType::Null) => return Ok((DataType::Null, ArithKind::Int)),
        (DataType::Null, t) | (t, DataType::Null) => (t, t),
        other => other,
    };
    if !l.is_numeric() || !r.is_numeric() {
        return Err(pos.error(Error::type_error(format!("operator {} requires numeric operands, got {l} and {r}", op.symbol()))));
    }
    let scale = |t: DataType| match t {
        DataType::Decimal { scale, .. } => scale,
        _ => 0,
    };
    let any_float = l == DataType::Float64 || r == DataType::Float64;
    let both_int = l == DataType::Int64 && r == DataType::Int64;
    Ok(match op {
        BinaryOp::Mod => {
            if both_int {
                (DataType::Int64, ArithKind::Int)
            } else {
                return Err(pos.error(Error::type_error("operator % requires INT64 operands")));
            }
        }
        _ if both_int => (DataType::Int64, ArithKind::Int),
        _ if any_float => (DataType::Float64, ArithKind::Float),
        BinaryOp::Div => (DataType::Float64, ArithKind::Float),
        BinaryOp::Mul => {
            let s = scale(l) + scale(r);
            if s > MAX_DECIMAL_PRECISION {
                return Err(pos.error(Error::type_error(format!("DECIMAL product scale {s} exceeds 18"))));
            }
            (DataType::decimal(18, s), ArithKind::Decimal)
        }
        _ => (DataType::decimal(18, scale(l).max(scale(r))), ArithKind::Decimal),
    })
}

/// Whether two types may be compared (types.md §2, §5).
fn comparable(l: DataType, r: DataType) -> bool {
    l == DataType::Null
        || r == DataType::Null
        || (l.is_numeric() && r.is_numeric())
        || (l.is_temporal() && r.is_temporal())
        || l == r
}

fn is_boolean(t: DataType) -> bool {
    t == DataType::Boolean || t == DataType::Null
}

impl Binder<'_> {
    fn query(&self, q: &ast::Query) -> Result<LogicalPlan> {
        if !q.with.is_empty() {
            return Err(q.pos.error(Error::unsupported("WITH is not supported")));
        }
        let core = &q.body;
        if core.distinct {
            return Err(q.pos.error(Error::unsupported("SELECT DISTINCT is not supported")));
        }
        if !core.group_by.is_empty() || core.having.is_some() {
            return Err(q.pos.error(Error::unsupported("GROUP BY / HAVING is not supported")));
        }

        // FROM
        let (mut plan, scope, base_table) = match &core.from {
            None => (LogicalPlan::SingleRow, Scope::default(), None),
            Some(FromItem::Table { name, alias }) => {
                let table = self
                    .ctx
                    .catalog
                    .get(&name.value)
                    .ok_or_else(|| name.pos.error(Error::semantic(format!("unknown table '{}'", name.value))))?;
                let var_name = alias.as_ref().unwrap_or(name).value.clone();
                let scope = Scope { vars: vec![RangeVar { name: var_name, fields: table.fields.clone(), offset: 0 }] };
                (LogicalPlan::SingleRow, scope, Some(table))
            }
            Some(FromItem::Join { pos, .. }) => return Err(pos.error(Error::unsupported("joins are not supported"))),
            Some(FromItem::Derived { alias, .. }) => {
                return Err(alias.pos.error(Error::unsupported("derived tables are not supported")));
            }
        };

        // WHERE
        let predicate = match &core.where_clause {
            Some(w) => {
                let p = self.expr(w, &scope, &mut AggMode::Forbidden("WHERE"))?;
                if !is_boolean(p.data_type()) {
                    return Err(w.pos.error(Error::type_error(format!("WHERE condition must be BOOLEAN, got {}", p.data_type()))));
                }
                Some(p)
            }
            None => None,
        };

        let aggregated = core.items.iter().any(|i| matches!(i, SelectItem::Expr { expr, .. } if contains_aggregate(expr)))
            || q.order_by.iter().any(|o| contains_aggregate(&o.expr));
        let mut aggregates: Vec<AggregateCall> = Vec::new();

        // SELECT list: (expression, output name)
        let mut outputs: Vec<(Expr, String)> = Vec::new();
        for item in &core.items {
            match item {
                SelectItem::Wildcard(pos) => {
                    if scope.vars.is_empty() {
                        return Err(pos.error(Error::semantic("SELECT * requires a FROM clause")));
                    }
                    if aggregated {
                        return Err(pos.error(Error::semantic("* is not allowed in an aggregated query")));
                    }
                    for var in &scope.vars {
                        for (i, f) in var.fields.iter().enumerate() {
                            outputs.push((Expr::Column { index: var.offset + i, ty: f.data_type }, f.name.clone()));
                        }
                    }
                }
                SelectItem::QualifiedWildcard(q) => {
                    let var = scope
                        .vars
                        .iter()
                        .find(|v| q.matches(&v.name))
                        .ok_or_else(|| q.pos.error(Error::semantic(format!("unknown table or alias '{}'", q.value))))?;
                    if aggregated {
                        return Err(q.pos.error(Error::semantic("* is not allowed in an aggregated query")));
                    }
                    for (i, f) in var.fields.iter().enumerate() {
                        outputs.push((Expr::Column { index: var.offset + i, ty: f.data_type }, f.name.clone()));
                    }
                }
                SelectItem::Expr { expr, alias } => {
                    let bound = if aggregated {
                        self.expr(expr, &scope, &mut AggMode::Collect(&mut aggregates))?
                    } else {
                        self.expr(expr, &scope, &mut AggMode::Forbidden("this context"))?
                    };
                    let name = match (alias, &expr.kind) {
                        (Some(a), _) => a.value.clone(),
                        (None, ExprKind::Column { qualifier, name }) => {
                            scope.resolve(qualifier.as_ref(), name)?.1.name.clone()
                        }
                        (None, _) => format!("_col{}", outputs.len() + 1),
                    };
                    outputs.push((bound, name));
                }
            }
        }
        let visible = outputs.len();

        // ORDER BY: keys refer to output columns; other expressions become
        // hidden output columns appended after the visible ones.
        let mut hidden: Vec<Expr> = Vec::new();
        let mut sort_keys: Vec<SortKey> = Vec::new();
        for item in &q.order_by {
            let column = self.order_target(&item.expr, &outputs)?;
            let index = match column {
                Some(i) => i,
                None => {
                    let bound = if aggregated {
                        self.expr(&item.expr, &scope, &mut AggMode::Collect(&mut aggregates))?
                    } else {
                        self.expr(&item.expr, &scope, &mut AggMode::Forbidden("ORDER BY"))?
                    };
                    hidden.push(bound);
                    visible + hidden.len() - 1
                }
            };
            let ty = if index < visible { outputs[index].0.data_type() } else { hidden[index - visible].data_type() };
            sort_keys.push(SortKey {
                expr: Expr::Column { index, ty },
                descending: item.descending,
                nulls_first: item.nulls_first.unwrap_or(!item.descending),
            });
        }

        // LIMIT / OFFSET: constant INT64 expressions.
        let limit = q.limit.as_ref().map(|e| self.limit_value(e, "LIMIT")).transpose()?.flatten();
        let offset = q.offset.as_ref().map(|e| self.limit_value(e, "OFFSET")).transpose()?.flatten().unwrap_or(0);

        // Column pruning: the scan only produces columns the query references.
        let mut predicate = predicate;
        let mut project_exprs: Vec<Expr> = outputs.iter().map(|(e, _)| e.clone()).chain(hidden).collect();
        if let Some(table) = base_table {
            let mut used = Vec::new();
            if let Some(p) = &predicate {
                p.collect_columns(&mut used);
            }
            if aggregated {
                for a in &aggregates {
                    if let Some(arg) = &a.arg {
                        arg.collect_columns(&mut used);
                    }
                }
            } else {
                for e in &project_exprs {
                    e.collect_columns(&mut used);
                }
            }
            used.sort_unstable();
            used.dedup();
            let map = |old: usize| used.binary_search(&old).unwrap_or(0);
            if let Some(p) = &mut predicate {
                p.remap_columns(&map);
            }
            if aggregated {
                for a in &mut aggregates {
                    if let Some(arg) = &mut a.arg {
                        arg.remap_columns(&map);
                    }
                }
            } else {
                for e in &mut project_exprs {
                    e.remap_columns(&map);
                }
            }
            plan = scan(table, used);
        }
        if let Some(p) = predicate {
            plan = LogicalPlan::Filter { input: Box::new(plan), predicate: p };
        }
        if aggregated {
            let schema = aggregates.iter().map(|a| Field::new(a.display(), a.ty)).collect();
            plan = LogicalPlan::Aggregate { input: Box::new(plan), group_by: Vec::new(), aggregates, schema };
        }
        let hidden_count = project_exprs.len() - visible;
        let mut schema: Vec<Field> =
            outputs.iter().map(|(e, name)| Field::new(name.clone(), e.data_type().result_type())).collect();
        for (i, e) in project_exprs[visible..].iter().enumerate() {
            schema.push(Field::new(format!("_sort{}", i + 1), e.data_type().result_type()));
        }
        plan = LogicalPlan::Project { input: Box::new(plan), exprs: project_exprs, schema };
        if !sort_keys.is_empty() {
            plan = LogicalPlan::Sort { input: Box::new(plan), keys: sort_keys };
        }
        if limit.is_some() || offset > 0 {
            plan = LogicalPlan::Limit { input: Box::new(plan), offset, limit };
        }
        if hidden_count > 0 {
            let schema: Vec<Field> = plan.schema()[..visible].to_vec();
            let exprs = schema.iter().enumerate().map(|(i, f)| Expr::Column { index: i, ty: f.data_type }).collect();
            plan = LogicalPlan::Project { input: Box::new(plan), exprs, schema };
        }
        Ok(plan)
    }

    /// Resolves an ORDER BY item to an output column, if it is an ordinal or
    /// an unqualified name of an output column (semantics.md §6).
    fn order_target(&self, e: &ast::Expr, outputs: &[(Expr, String)]) -> Result<Option<usize>> {
        match &e.kind {
            ExprKind::Literal(Literal::Number(text)) if text.bytes().all(|b| b.is_ascii_digit()) => {
                let k: usize = text.parse().unwrap_or(0);
                if k == 0 || k > outputs.len() {
                    return Err(e.pos.error(Error::semantic(format!("ORDER BY position {text} is out of range"))));
                }
                Ok(Some(k - 1))
            }
            ExprKind::Column { qualifier: None, name } => {
                let matches: Vec<usize> =
                    outputs.iter().enumerate().filter(|(_, (_, n))| name.matches(n)).map(|(i, _)| i).collect();
                match matches.as_slice() {
                    [] => Ok(None),
                    [i] => Ok(Some(*i)),
                    [first, rest @ ..] => {
                        if rest.iter().all(|i| outputs[*i].0 == outputs[*first].0) {
                            Ok(Some(*first))
                        } else {
                            Err(name.pos.error(Error::semantic(format!("ORDER BY '{}' is ambiguous", name.value))))
                        }
                    }
                }
            }
            _ => Ok(None),
        }
    }

    /// Evaluates a LIMIT/OFFSET expression (None for NULL).
    fn limit_value(&self, e: &ast::Expr, clause: &'static str) -> Result<Option<u64>> {
        let bound = self.expr(e, &Scope::default(), &mut AggMode::Forbidden(clause))?;
        match bound.data_type() {
            DataType::Int64 | DataType::Null => {}
            t => return Err(e.pos.error(Error::type_error(format!("{clause} must be INT64, got {t}")))),
        }
        match eval_constant(&bound)? {
            Value::Null => Ok(None),
            Value::Int(v) if v >= 0 => Ok(Some(v as u64)),
            Value::Int(v) => Err(e.pos.error(Error::invalid_argument(format!("{clause} must not be negative, got {v}")))),
            v => Err(Error::internal(format!("unexpected {clause} value {v:?}"))),
        }
    }

    fn expr(&self, e: &ast::Expr, scope: &Scope, mode: &mut AggMode<'_>) -> Result<Expr> {
        let pos = e.pos;
        Ok(match &e.kind {
            ExprKind::Literal(lit) => self.literal(lit, pos)?,
            ExprKind::Column { qualifier, name } => {
                let (index, field) = scope.resolve(qualifier.as_ref(), name)?;
                if let AggMode::Collect(_) = mode {
                    return Err(name.pos.error(Error::semantic(format!(
                        "column '{}' must appear in GROUP BY or be used in an aggregate function",
                        name.value
                    ))));
                }
                Expr::Column { index, ty: field.data_type }
            }
            ExprKind::Unary { op: UnaryOp::Neg, expr } if matches!(expr.kind, ExprKind::Literal(Literal::Number(_))) => {
                let ExprKind::Literal(Literal::Number(text)) = &expr.kind else { unreachable!() };
                let (value, ty) = number_literal(text, true).map_err(|err| pos.error(err))?;
                Expr::Literal { value, ty }
            }
            ExprKind::Unary { op, expr } => {
                let inner = self.expr(expr, scope, mode)?;
                let ty = inner.data_type();
                match op {
                    UnaryOp::Not => {
                        if !is_boolean(ty) {
                            return Err(pos.error(Error::type_error(format!("NOT requires BOOLEAN, got {ty}"))));
                        }
                        Expr::Not(Box::new(inner))
                    }
                    UnaryOp::Neg | UnaryOp::Plus => {
                        if !ty.is_numeric() && ty != DataType::Null {
                            return Err(pos.error(Error::type_error(format!("unary minus/plus requires a numeric operand, got {ty}"))));
                        }
                        if *op == UnaryOp::Plus { inner } else { Expr::Negate { expr: Box::new(inner), ty } }
                    }
                }
            }
            ExprKind::Binary { op, left, right } => {
                let l = self.expr(left, scope, mode)?;
                let r = self.expr(right, scope, mode)?;
                let (lt, rt) = (l.data_type(), r.data_type());
                match op {
                    BinaryOp::And | BinaryOp::Or => {
                        if !is_boolean(lt) || !is_boolean(rt) {
                            return Err(pos.error(Error::type_error(format!(
                                "{} requires BOOLEAN operands, got {lt} and {rt}",
                                op.symbol()
                            ))));
                        }
                        if *op == BinaryOp::And {
                            Expr::And(Box::new(l), Box::new(r))
                        } else {
                            Expr::Or(Box::new(l), Box::new(r))
                        }
                    }
                    BinaryOp::Concat => {
                        let ok = |t: DataType| t == DataType::String || t == DataType::Null;
                        if !ok(lt) || !ok(rt) {
                            return Err(pos.error(Error::type_error(format!("|| requires STRING operands, got {lt} and {rt}"))));
                        }
                        Expr::Concat(Box::new(l), Box::new(r))
                    }
                    op if op.is_comparison() => {
                        if !comparable(lt, rt) {
                            return Err(pos.error(Error::type_error(format!("cannot compare {lt} with {rt}"))));
                        }
                        Expr::Compare { op: *op, left: Box::new(l), right: Box::new(r) }
                    }
                    op => {
                        let (ty, kind) = arithmetic_type(*op, lt, rt, pos)?;
                        Expr::Arith { op: *op, kind, left: Box::new(l), right: Box::new(r), ty }
                    }
                }
            }
            ExprKind::IsNull { expr, negated } => {
                Expr::IsNull { expr: Box::new(self.expr(expr, scope, mode)?), negated: *negated }
            }
            ExprKind::Cast { expr, type_name } => {
                let inner = self.expr(expr, scope, mode)?;
                let mut params = Vec::new();
                for p in &type_name.params {
                    params.push(p.parse::<u64>().map_err(|_| {
                        type_name.pos.error(Error::semantic(format!("invalid type parameter '{p}'")))
                    })?);
                }
                let to = DataType::from_name(&type_name.name, &params).map_err(|err| type_name.pos.error(err))?;
                if !cast_allowed(inner.data_type(), to) {
                    return Err(pos.error(Error::type_error(format!("cannot cast {} to {to}", inner.data_type()))));
                }
                Expr::Cast { expr: Box::new(inner), to }
            }
            ExprKind::Function { name, args, distinct, star } => {
                if let Some(func) = AggFunc::lookup(&name.value) {
                    return self.aggregate(func, name, args, *distinct, *star, scope, mode);
                }
                self.scalar_function(name, args, *distinct, *star, scope, mode)?
            }
            ExprKind::Between { .. } => return Err(pos.error(Error::unsupported("BETWEEN is not supported"))),
            ExprKind::InList { .. } => return Err(pos.error(Error::unsupported("IN lists are not supported"))),
            ExprKind::Like { .. } => return Err(pos.error(Error::unsupported("LIKE is not supported"))),
            ExprKind::Case { .. } => return Err(pos.error(Error::unsupported("CASE is not supported"))),
            ExprKind::InSubquery { .. } | ExprKind::Exists(_) | ExprKind::Subquery(_) => {
                return Err(pos.error(Error::unsupported("subqueries are not supported")));
            }
        })
    }

    fn literal(&self, lit: &Literal, pos: Pos) -> Result<Expr> {
        let (value, ty) = match lit {
            Literal::Number(text) => number_literal(text, false).map_err(|e| pos.error(e))?,
            Literal::String(s) => (Value::str(s), DataType::String),
            Literal::Bool(b) => (Value::Bool(*b), DataType::Boolean),
            Literal::Null => (Value::Null, DataType::Null),
            Literal::Date(s) => {
                let d = datetime::parse_date(s)
                    .ok_or_else(|| pos.error(Error::conversion(format!("invalid DATE literal '{s}'"))))?;
                (Value::Date(d), DataType::Date)
            }
            Literal::Timestamp(s) => {
                let t = datetime::parse_timestamp(s)
                    .ok_or_else(|| pos.error(Error::conversion(format!("invalid TIMESTAMP literal '{s}'"))))?;
                (Value::Timestamp(t), DataType::Timestamp)
            }
        };
        Ok(Expr::Literal { value, ty })
    }

    #[allow(clippy::too_many_arguments)]
    fn aggregate(
        &self,
        func: AggFunc,
        name: &Ident,
        args: &[ast::Expr],
        distinct: bool,
        star: bool,
        scope: &Scope,
        mode: &mut AggMode<'_>,
    ) -> Result<Expr> {
        let pos = name.pos;
        let aggs = match mode {
            AggMode::Forbidden(clause) => {
                return Err(pos.error(Error::semantic(format!("aggregate function {} is not allowed in {clause}", func.name()))));
            }
            AggMode::Inside => {
                return Err(pos.error(Error::semantic("aggregate function calls cannot be nested")));
            }
            AggMode::Collect(aggs) => aggs,
        };
        let (func, arg) = if star {
            if func != AggFunc::Count {
                return Err(pos.error(Error::semantic(format!("{}(*) is not allowed", func.name()))));
            }
            (AggFunc::CountStar, None)
        } else {
            if args.len() != 1 {
                return Err(pos.error(Error::semantic(format!("{} takes exactly one argument", func.name()))));
            }
            let arg = self.expr(&args[0], scope, &mut AggMode::Inside)?;
            (func, Some(arg))
        };
        let arg_ty = arg.as_ref().map(|a| a.data_type()).unwrap_or(DataType::Null);
        let ty = match func {
            AggFunc::CountStar | AggFunc::Count => DataType::Int64,
            AggFunc::Sum => match arg_ty {
                DataType::Int64 | DataType::Null => DataType::Int64,
                DataType::Decimal { scale, .. } => DataType::decimal(18, scale),
                DataType::Float64 => DataType::Float64,
                t => return Err(pos.error(Error::type_error(format!("SUM requires a numeric argument, got {t}")))),
            },
            AggFunc::Avg => {
                if !arg_ty.is_numeric() && arg_ty != DataType::Null {
                    return Err(pos.error(Error::type_error(format!("AVG requires a numeric argument, got {arg_ty}"))));
                }
                DataType::Float64
            }
            AggFunc::Min | AggFunc::Max => arg_ty,
        };
        let call = AggregateCall { func, arg, distinct, ty };
        let index = match aggs.iter().position(|a| *a == call) {
            Some(i) => i,
            None => {
                aggs.push(call);
                aggs.len() - 1
            }
        };
        Ok(Expr::Column { index, ty })
    }

    #[allow(clippy::too_many_arguments)]
    fn scalar_function(
        &self,
        name: &Ident,
        args: &[ast::Expr],
        distinct: bool,
        star: bool,
        scope: &Scope,
        mode: &mut AggMode<'_>,
    ) -> Result<Expr> {
        let pos = name.pos;
        let upper = name.value.to_ascii_uppercase();
        let func = match upper.as_str() {
            "PQ_SLEEP" if self.ctx.test_functions => ScalarFunc::PqSleep,
            n if UNSUPPORTED_FUNCTIONS.contains(&n) => {
                return Err(pos.error(Error::unsupported(format!("function {upper} is not supported"))));
            }
            _ => return Err(pos.error(Error::semantic(format!("unknown function '{}'", name.value)))),
        };
        if star || distinct {
            return Err(pos.error(Error::semantic(format!("{upper} does not accept * or DISTINCT"))));
        }
        let mut bound = Vec::with_capacity(args.len());
        for a in args {
            bound.push(self.expr(a, scope, mode)?);
        }
        let ty = match func {
            ScalarFunc::PqSleep => {
                if bound.len() != 1 {
                    return Err(pos.error(Error::semantic("PQ_SLEEP takes exactly one argument")));
                }
                let t = bound[0].data_type();
                if t != DataType::Int64 && t != DataType::Null {
                    return Err(pos.error(Error::type_error(format!("PQ_SLEEP requires INT64, got {t}"))));
                }
                DataType::Int64
            }
        };
        Ok(Expr::Function { func, args: bound, ty })
    }
}

fn scan(table: Arc<Table>, columns: Vec<usize>) -> LogicalPlan {
    let schema = columns.iter().map(|&c| table.fields[c].clone()).collect();
    LogicalPlan::Scan { table, columns, schema }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_typing() {
        let t = |s: &str| number_literal(s, false).unwrap().1.to_string();
        assert_eq!(t("1.50"), "DECIMAL(3,2)");
        assert_eq!(t("0.05"), "DECIMAL(2,2)");
        assert_eq!(t(".5"), "DECIMAL(1,1)");
        assert_eq!(t("00012.5"), "DECIMAL(3,1)");
        assert_eq!(t("3."), "DECIMAL(1,0)");
        assert_eq!(t("1e3"), "FLOAT64");
        assert_eq!(t("1234567890.1234567890"), "FLOAT64");
        assert!(number_literal("9223372036854775808", false).is_err());
        assert_eq!(number_literal("9223372036854775808", true).unwrap().0, Value::Int(i64::MIN));
        assert_eq!(number_literal("2.50", true).unwrap().0, Value::Decimal(-250, 2));
    }

    #[test]
    fn arithmetic_typing() {
        let p = Pos::default();
        let d = |p, s| DataType::decimal(p, s);
        assert_eq!(arithmetic_type(BinaryOp::Mul, d(3, 2), d(2, 1), p).unwrap().0, d(18, 3));
        assert_eq!(arithmetic_type(BinaryOp::Mul, d(2, 1), DataType::Int64, p).unwrap().0, d(18, 1));
        assert_eq!(arithmetic_type(BinaryOp::Div, d(4, 2), DataType::Int64, p).unwrap().0, DataType::Float64);
        assert!(arithmetic_type(BinaryOp::Mod, d(2, 1), DataType::Int64, p).is_err());
        assert_eq!(arithmetic_type(BinaryOp::Div, DataType::Null, DataType::Int64, p).unwrap().0, DataType::Int64);
        assert!(arithmetic_type(BinaryOp::Add, DataType::Date, DataType::Int64, p).is_err());
    }
}
