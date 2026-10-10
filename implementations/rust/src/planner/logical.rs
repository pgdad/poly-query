//! Logical query plans: the relational algebra produced by semantic analysis
//! and rewritten by the optimizer.

use std::sync::Arc;

use super::expr::{AggregateCall, Expr};
use crate::storage::{Field, Table};

#[derive(Debug, Clone, PartialEq)]
pub struct SortKey {
    pub expr: Expr,
    pub descending: bool,
    pub nulls_first: bool,
}

/// Join types of the logical plan (semantics.md §7).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinType {
    Inner,
    Left,
    Cross,
}

impl JoinType {
    pub fn name(self) -> &'static str {
        match self {
            JoinType::Inner => "INNER",
            JoinType::Left => "LEFT",
            JoinType::Cross => "CROSS",
        }
    }
}

#[derive(Debug, Clone)]
pub enum LogicalPlan {
    /// A single row with no columns (`SELECT` without `FROM`).
    SingleRow,
    /// Scan of a table, producing the listed columns in order.
    Scan {
        table: Arc<Table>,
        columns: Vec<usize>,
        schema: Vec<Field>,
    },
    Filter {
        input: Box<LogicalPlan>,
        predicate: Expr,
    },
    Project {
        input: Box<LogicalPlan>,
        exprs: Vec<Expr>,
        schema: Vec<Field>,
    },
    /// Output: group keys followed by aggregate values. Without group keys
    /// there is exactly one output row.
    Aggregate {
        input: Box<LogicalPlan>,
        group_by: Vec<Expr>,
        aggregates: Vec<AggregateCall>,
        schema: Vec<Field>,
    },
    /// Output: left columns followed by right columns. `on` is evaluated over
    /// that combined row.
    Join {
        left: Box<LogicalPlan>,
        right: Box<LogicalPlan>,
        join_type: JoinType,
        on: Option<Expr>,
        schema: Vec<Field>,
    },
    /// Removes duplicate rows (NULLs equal).
    Distinct { input: Box<LogicalPlan> },
    Sort {
        input: Box<LogicalPlan>,
        keys: Vec<SortKey>,
    },
    Limit {
        input: Box<LogicalPlan>,
        offset: u64,
        limit: Option<u64>,
    },
}

impl LogicalPlan {
    pub fn schema(&self) -> &[Field] {
        match self {
            LogicalPlan::SingleRow => &[],
            LogicalPlan::Scan { schema, .. }
            | LogicalPlan::Project { schema, .. }
            | LogicalPlan::Aggregate { schema, .. }
            | LogicalPlan::Join { schema, .. } => schema,
            LogicalPlan::Filter { input, .. }
            | LogicalPlan::Distinct { input }
            | LogicalPlan::Sort { input, .. }
            | LogicalPlan::Limit { input, .. } => input.schema(),
        }
    }

    pub fn width(&self) -> usize {
        self.schema().len()
    }

    /// Builds a join node, deriving its schema.
    pub fn join(
        left: LogicalPlan,
        right: LogicalPlan,
        join_type: JoinType,
        on: Option<Expr>,
    ) -> LogicalPlan {
        let schema = left
            .schema()
            .iter()
            .chain(right.schema())
            .cloned()
            .collect();
        LogicalPlan::Join {
            left: Box::new(left),
            right: Box::new(right),
            join_type,
            on,
            schema,
        }
    }

    pub fn filter(input: LogicalPlan, predicate: Option<Expr>) -> LogicalPlan {
        match predicate {
            Some(predicate) => LogicalPlan::Filter {
                input: Box::new(input),
                predicate,
            },
            None => input,
        }
    }

    /// Calls `f` for every expression of this plan tree (not descending into
    /// subquery plans).
    pub fn visit_exprs(&self, f: &mut dyn FnMut(&Expr)) {
        match self {
            LogicalPlan::SingleRow | LogicalPlan::Scan { .. } => {}
            LogicalPlan::Filter { input, predicate } => {
                f(predicate);
                input.visit_exprs(f);
            }
            LogicalPlan::Project { input, exprs, .. } => {
                exprs.iter().for_each(&mut *f);
                input.visit_exprs(f);
            }
            LogicalPlan::Aggregate {
                input,
                group_by,
                aggregates,
                ..
            } => {
                group_by.iter().for_each(&mut *f);
                for a in aggregates {
                    if let Some(arg) = &a.arg {
                        f(arg);
                    }
                }
                input.visit_exprs(f);
            }
            LogicalPlan::Join {
                left, right, on, ..
            } => {
                if let Some(on) = on {
                    f(on);
                }
                left.visit_exprs(f);
                right.visit_exprs(f);
            }
            LogicalPlan::Distinct { input } | LogicalPlan::Limit { input, .. } => {
                input.visit_exprs(f)
            }
            LogicalPlan::Sort { input, keys } => {
                for k in keys {
                    f(&k.expr);
                }
                input.visit_exprs(f);
            }
        }
    }
}
