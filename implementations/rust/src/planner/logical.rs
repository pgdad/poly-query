//! Logical query plans.

use std::sync::Arc;

use super::expr::{AggregateCall, Expr};
use crate::json::Json;
use crate::storage::{Field, Table};

#[derive(Debug, Clone, PartialEq)]
pub struct SortKey {
    pub expr: Expr,
    pub descending: bool,
    pub nulls_first: bool,
}

#[derive(Debug, Clone)]
pub enum LogicalPlan {
    /// A single row with no columns (`SELECT` without `FROM`).
    SingleRow,
    /// Full scan of a table, producing the listed columns in order.
    Scan { table: Arc<Table>, columns: Vec<usize>, schema: Vec<Field> },
    Filter { input: Box<LogicalPlan>, predicate: Expr },
    Project { input: Box<LogicalPlan>, exprs: Vec<Expr>, schema: Vec<Field> },
    /// Output: group keys followed by aggregate values.
    Aggregate { input: Box<LogicalPlan>, group_by: Vec<Expr>, aggregates: Vec<AggregateCall>, schema: Vec<Field> },
    Sort { input: Box<LogicalPlan>, keys: Vec<SortKey> },
    Limit { input: Box<LogicalPlan>, offset: u64, limit: Option<u64> },
}

impl LogicalPlan {
    pub fn schema(&self) -> &[Field] {
        match self {
            LogicalPlan::SingleRow => &[],
            LogicalPlan::Scan { schema, .. }
            | LogicalPlan::Project { schema, .. }
            | LogicalPlan::Aggregate { schema, .. } => schema,
            LogicalPlan::Filter { input, .. } | LogicalPlan::Sort { input, .. } | LogicalPlan::Limit { input, .. } => {
                input.schema()
            }
        }
    }

    /// Plan as a JSON tree (indexes-and-planning.md §4 node format).
    pub fn to_json(&self) -> Json {
        let names = |fields: &[Field]| Json::Array(fields.iter().map(|f| Json::str(&f.name)).collect());
        let node = |op: &str, mut props: Vec<(&str, Json)>, children: Vec<&LogicalPlan>| {
            let mut fields = vec![("op", Json::str(op))];
            fields.append(&mut props);
            fields.push(("children", Json::Array(children.into_iter().map(|c| c.to_json()).collect())));
            Json::object(fields)
        };
        match self {
            LogicalPlan::SingleRow => node("Values", vec![("rows", Json::int(1))], vec![]),
            LogicalPlan::Scan { table, schema, .. } => {
                node("TableScan", vec![("table", Json::str(&table.name)), ("columns", names(schema))], vec![])
            }
            LogicalPlan::Filter { input, predicate } => {
                node("Filter", vec![("predicate", Json::String(predicate.display()))], vec![input])
            }
            LogicalPlan::Project { input, schema, .. } => node("Project", vec![("columns", names(schema))], vec![input]),
            LogicalPlan::Aggregate { input, group_by, aggregates, .. } => node(
                "Aggregate",
                vec![
                    ("group_by", Json::Array(group_by.iter().map(|e| Json::String(e.display())).collect())),
                    ("aggregates", Json::Array(aggregates.iter().map(|a| Json::String(a.display())).collect())),
                ],
                vec![input],
            ),
            LogicalPlan::Sort { input, keys } => node(
                "Sort",
                vec![(
                    "keys",
                    Json::Array(
                        keys.iter()
                            .map(|k| Json::String(format!("{} {}", k.expr.display(), if k.descending { "DESC" } else { "ASC" })))
                            .collect(),
                    ),
                )],
                vec![input],
            ),
            LogicalPlan::Limit { input, offset, limit } => node(
                "Limit",
                vec![("offset", Json::uint(*offset)), ("limit", limit.map(Json::uint).unwrap_or(Json::Null))],
                vec![input],
            ),
        }
    }
}
