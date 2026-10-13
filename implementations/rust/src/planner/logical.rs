//! Logical query plans: the relational algebra produced by semantic analysis
//! and rewritten by the optimizer. A logical plan says *what* is computed,
//! never *how*: access paths, join algorithms and the execution model are
//! chosen later by physical planning ([`super::physical`]).
//!
//! Subqueries are expressions ([`Expr::ScalarSubquery`], [`Expr::Exists`],
//! [`Expr::InSubquery`]) owning their own logical plan; CTEs are inlined by
//! the binder at every reference. `Display` prints a plan tree (with its
//! subquery plans) for debugging and tests.

use std::collections::HashSet;
use std::fmt;
use std::sync::Arc;

use super::expr::{AggregateCall, Expr, SubqueryPlan};
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
    /// Concatenation of the rows of all inputs (`UNION ALL`, duplicates
    /// kept). Every input produces exactly `schema`'s columns, already
    /// converted to the output types.
    UnionAll {
        inputs: Vec<LogicalPlan>,
        schema: Vec<Field>,
    },
}

impl LogicalPlan {
    pub fn schema(&self) -> &[Field] {
        match self {
            LogicalPlan::SingleRow => &[],
            LogicalPlan::Scan { schema, .. }
            | LogicalPlan::Project { schema, .. }
            | LogicalPlan::Aggregate { schema, .. }
            | LogicalPlan::Join { schema, .. }
            | LogicalPlan::UnionAll { schema, .. } => schema,
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

    /// Size of the plan tree in units of plan nodes, stored output columns
    /// and expression nodes (subquery plans are shared, not counted): a
    /// measure of the memory a copy of the plan takes.
    pub fn size(&self) -> usize {
        let mut units = 0;
        let mut stack = vec![self];
        while let Some(p) = stack.pop() {
            units += 1;
            match p {
                LogicalPlan::SingleRow => {}
                LogicalPlan::Scan { schema, .. } => units += schema.len(),
                LogicalPlan::Project { input, schema, .. }
                | LogicalPlan::Aggregate { input, schema, .. } => {
                    units += schema.len();
                    stack.push(input);
                }
                LogicalPlan::Join {
                    left,
                    right,
                    schema,
                    ..
                } => {
                    units += schema.len();
                    stack.push(left);
                    stack.push(right);
                }
                LogicalPlan::Filter { input, .. }
                | LogicalPlan::Distinct { input }
                | LogicalPlan::Sort { input, .. }
                | LogicalPlan::Limit { input, .. } => stack.push(input),
                LogicalPlan::UnionAll { inputs, schema } => {
                    units += schema.len();
                    stack.extend(inputs);
                }
            }
        }
        let nodes = std::cell::Cell::new(0usize);
        self.visit_exprs(&mut |e| {
            e.any(&|_| {
                nodes.set(nodes.get() + 1);
                false
            });
        });
        units + nodes.get()
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
            LogicalPlan::UnionAll { inputs, .. } => {
                for input in inputs {
                    input.visit_exprs(f);
                }
            }
        }
    }

    /// Calls `f` for every expression of this plan tree, mutably (not
    /// descending into subquery plans).
    pub fn visit_exprs_mut(&mut self, f: &mut dyn FnMut(&mut Expr)) {
        match self {
            LogicalPlan::SingleRow | LogicalPlan::Scan { .. } => {}
            LogicalPlan::Filter { input, predicate } => {
                f(predicate);
                input.visit_exprs_mut(f);
            }
            LogicalPlan::Project { input, exprs, .. } => {
                exprs.iter_mut().for_each(&mut *f);
                input.visit_exprs_mut(f);
            }
            LogicalPlan::Aggregate {
                input,
                group_by,
                aggregates,
                ..
            } => {
                group_by.iter_mut().for_each(&mut *f);
                for a in aggregates {
                    if let Some(arg) = &mut a.arg {
                        f(arg);
                    }
                }
                input.visit_exprs_mut(f);
            }
            LogicalPlan::Join {
                left, right, on, ..
            } => {
                if let Some(on) = on {
                    f(on);
                }
                left.visit_exprs_mut(f);
                right.visit_exprs_mut(f);
            }
            LogicalPlan::Distinct { input } | LogicalPlan::Limit { input, .. } => {
                input.visit_exprs_mut(f)
            }
            LogicalPlan::Sort { input, keys } => {
                for k in keys {
                    f(&mut k.expr);
                }
                input.visit_exprs_mut(f);
            }
            LogicalPlan::UnionAll { inputs, .. } => {
                for input in inputs {
                    input.visit_exprs_mut(f);
                }
            }
        }
    }

    /// Calls `f` for every subquery referenced by this plan's expressions
    /// (not descending into the subquery plans themselves); `correlated`
    /// tells whether the reference passes outer values as parameters.
    pub fn visit_subqueries(&self, f: &mut dyn FnMut(&Arc<SubqueryPlan>, bool)) {
        self.visit_exprs(&mut |e| e.visit_subqueries(&mut *f));
    }

    fn fmt_tree(&self, f: &mut fmt::Formatter<'_>, depth: usize) -> fmt::Result {
        let list = |items: &mut dyn Iterator<Item = String>| items.collect::<Vec<_>>().join(", ");
        let names = |schema: &[Field]| list(&mut schema.iter().map(|c| c.name.clone()));
        write!(f, "{:indent$}", "", indent = depth * 2)?;
        match self {
            LogicalPlan::SingleRow => writeln!(f, "SingleRow")?,
            LogicalPlan::Scan { table, schema, .. } => {
                writeln!(f, "Scan {} [{}]", table.name, names(schema))?
            }
            LogicalPlan::Filter { predicate, .. } => writeln!(f, "Filter {predicate}")?,
            LogicalPlan::Project { exprs, schema, .. } => writeln!(
                f,
                "Project [{}]",
                list(
                    &mut schema
                        .iter()
                        .zip(exprs)
                        .map(|(c, e)| format!("{} := {e}", c.name))
                )
            )?,
            LogicalPlan::Aggregate {
                group_by,
                aggregates,
                ..
            } => writeln!(
                f,
                "Aggregate group_by=[{}] aggregates=[{}]",
                list(&mut group_by.iter().map(Expr::to_string)),
                list(&mut aggregates.iter().map(AggregateCall::to_string))
            )?,
            LogicalPlan::Join { join_type, on, .. } => match on {
                Some(on) => writeln!(f, "Join {} ON {on}", join_type.name())?,
                None => writeln!(f, "Join {}", join_type.name())?,
            },
            LogicalPlan::Distinct { .. } => writeln!(f, "Distinct")?,
            LogicalPlan::Sort { keys, .. } => writeln!(
                f,
                "Sort [{}]",
                list(&mut keys.iter().map(|k| format!(
                    "{} {} NULLS {}",
                    k.expr,
                    if k.descending { "DESC" } else { "ASC" },
                    if k.nulls_first { "FIRST" } else { "LAST" }
                )))
            )?,
            LogicalPlan::Limit { offset, limit, .. } => match limit {
                Some(limit) => writeln!(f, "Limit offset={offset} limit={limit}")?,
                None => writeln!(f, "Limit offset={offset}")?,
            },
            LogicalPlan::UnionAll { schema, .. } => writeln!(f, "UnionAll [{}]", names(schema))?,
        }
        match self {
            LogicalPlan::SingleRow | LogicalPlan::Scan { .. } => Ok(()),
            LogicalPlan::Filter { input, .. }
            | LogicalPlan::Project { input, .. }
            | LogicalPlan::Aggregate { input, .. }
            | LogicalPlan::Distinct { input }
            | LogicalPlan::Sort { input, .. }
            | LogicalPlan::Limit { input, .. } => input.fmt_tree(f, depth + 1),
            LogicalPlan::Join { left, right, .. } => {
                left.fmt_tree(f, depth + 1)?;
                right.fmt_tree(f, depth + 1)
            }
            LogicalPlan::UnionAll { inputs, .. } => inputs
                .iter()
                .try_for_each(|input| input.fmt_tree(f, depth + 1)),
        }
    }
}

/// Indented operator tree, one node per line (`#i` is input column `i`),
/// followed by the plans of the subqueries it references.
impl fmt::Display for LogicalPlan {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.fmt_tree(f, 0)?;
        let mut shown = HashSet::new();
        let mut pending = Vec::new();
        self.visit_subqueries(&mut |sub, _| pending.push(sub.clone()));
        let mut next = 0;
        while let Some(sub) = pending.get(next).cloned() {
            next += 1;
            if shown.insert(sub.id) {
                writeln!(f, "$subquery{}:", sub.id)?;
                sub.plan.fmt_tree(f, 1)?;
                sub.plan
                    .visit_subqueries(&mut |sub, _| pending.push(sub.clone()));
            }
        }
        Ok(())
    }
}
