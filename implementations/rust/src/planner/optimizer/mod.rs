//! Rule-based logical optimizer (indexes-and-planning.md §3).
//!
//! The optimizer rewrites a [`LogicalPlan`] into an equivalent one by
//! applying a sequence of independent, separately named [`Rule`]s. Rules
//! only see the logical plan: they never choose access paths, join
//! algorithms or the execution model (that is physical planning,
//! [`crate::planner::physical`]). All rules preserve results and errors.
//!
//! | Rule | Module |
//! |---|---|
//! | `constant_folding` | [`constant_folding`] |
//! | `predicate_pushdown` | [`predicate_pushdown`] |
//! | `join_reorder` | [`join_reorder`] |
//! | `column_pruning` | [`column_pruning`] |
//!
//! With the query option `optimize: false` no rule is applied.

pub mod column_pruning;
pub mod constant_folding;
pub mod join_reorder;
pub mod predicate_pushdown;

use std::collections::HashMap;
use std::sync::Arc;

use super::expr::SubqueryPlan;
use super::logical::LogicalPlan;
pub use column_pruning::ColumnPruning;
pub use constant_folding::ConstantFolding;
pub use join_reorder::JoinReorder;
pub use predicate_pushdown::PredicatePushdown;

/// A logical rewrite rule.
pub trait Rule {
    /// Stable rule name (for diagnostics and tests).
    fn name(&self) -> &'static str;

    /// Rewrites one query level. Subquery plans inside expressions are
    /// optimized separately by the [`Optimizer`].
    fn apply(&self, plan: LogicalPlan) -> LogicalPlan;
}

/// The rules applied with `optimize: true`, in order: folding first so that
/// pushdown and reordering see simplified predicates, pruning last so that
/// it also removes the columns that only pushed-down filters needed above
/// their new position.
pub const DEFAULT_RULES: &[&dyn Rule] = &[
    &ConstantFolding,
    &PredicatePushdown,
    &JoinReorder,
    &ColumnPruning,
];

/// Applies a sequence of rules to a plan and to all its subquery plans.
pub struct Optimizer<'r> {
    rules: &'r [&'r dyn Rule],
}

impl Optimizer<'static> {
    /// The optimizer for the query option `optimize`: every default rule,
    /// or none at all.
    pub fn for_query(optimize: bool) -> Self {
        Optimizer::new(if optimize { DEFAULT_RULES } else { &[] })
    }
}

impl<'r> Optimizer<'r> {
    pub fn new(rules: &'r [&'r dyn Rule]) -> Self {
        Optimizer { rules }
    }

    /// Names of the rules, in application order.
    pub fn rule_names(&self) -> Vec<&'static str> {
        self.rules.iter().map(|r| r.name()).collect()
    }

    /// Optimizes the plans of the subqueries in `plan`'s expressions (each
    /// subquery once, however often it is referenced), then `plan` itself.
    pub fn optimize(&self, plan: LogicalPlan) -> LogicalPlan {
        self.optimize_level(plan, &mut HashMap::new())
    }

    fn optimize_level(
        &self,
        mut plan: LogicalPlan,
        done: &mut HashMap<usize, Arc<SubqueryPlan>>,
    ) -> LogicalPlan {
        if self.rules.is_empty() {
            return plan;
        }
        plan.visit_exprs_mut(&mut |e| {
            e.visit_subqueries_mut(&mut |sub| {
                if let Some(optimized) = done.get(&sub.id) {
                    *sub = optimized.clone();
                    return;
                }
                let optimized = Arc::new(SubqueryPlan {
                    id: sub.id,
                    plan: self.optimize_level(sub.plan.clone(), done),
                });
                done.insert(sub.id, optimized.clone());
                *sub = optimized;
            })
        });
        self.rules.iter().fold(plan, |plan, rule| rule.apply(plan))
    }
}

/// Plan builders shared by the rule tests.
#[cfg(test)]
pub(crate) mod test_util {
    use std::sync::Arc;

    use crate::planner::expr::Expr;
    use crate::planner::logical::{JoinType, LogicalPlan};
    use crate::sql::ast::BinaryOp;
    use crate::storage::{Field, Table};
    use crate::types::{DataType, Value};

    /// A table `name` with INT64 columns `cols` and `rows` rows
    /// (column `c` of row `r` holds `r % (c + 1) * 10 + r`).
    pub fn table(name: &str, cols: &[&str], rows: i64) -> Arc<Table> {
        let fields = cols
            .iter()
            .map(|c| Field::new(c.to_string(), DataType::Int64))
            .collect();
        let data = (0..rows)
            .map(|r| {
                (0..cols.len() as i64)
                    .map(|c| Value::Int(r % (c + 1) * 10 + r))
                    .collect()
            })
            .collect();
        Arc::new(Table::from_rows(name, fields, data))
    }

    pub fn scan(table: &Arc<Table>) -> LogicalPlan {
        LogicalPlan::Scan {
            table: table.clone(),
            columns: (0..table.fields.len()).collect(),
            schema: table.fields.clone(),
        }
    }

    pub fn col(index: usize) -> Expr {
        Expr::Column {
            index,
            ty: DataType::Int64,
        }
    }

    pub fn int(i: i64) -> Expr {
        Expr::Literal {
            value: Value::Int(i),
            ty: DataType::Int64,
        }
    }

    pub fn cmp(op: BinaryOp, l: Expr, r: Expr) -> Expr {
        Expr::Compare {
            op,
            left: Box::new(l),
            right: Box::new(r),
        }
    }

    pub fn and(l: Expr, r: Expr) -> Expr {
        Expr::And(Box::new(l), Box::new(r))
    }

    pub fn filter(input: LogicalPlan, predicate: Expr) -> LogicalPlan {
        LogicalPlan::filter(input, Some(predicate))
    }

    pub fn join(l: LogicalPlan, r: LogicalPlan, ty: JoinType, on: Option<Expr>) -> LogicalPlan {
        LogicalPlan::join(l, r, ty, on)
    }

    /// Projection of input columns `cols` (keeping their names).
    pub fn project(input: LogicalPlan, cols: &[usize]) -> LogicalPlan {
        let schema = cols.iter().map(|&i| input.schema()[i].clone()).collect();
        LogicalPlan::Project {
            exprs: cols.iter().map(|&i| col(i)).collect(),
            input: Box::new(input),
            schema,
        }
    }

    /// The plan printed without trailing whitespace, for comparisons.
    pub fn show(plan: &LogicalPlan) -> String {
        plan.to_string().trim_end().to_string()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::test_util::*;
    use super::*;
    use crate::planner::expr::{Expr, SubqueryPlan};
    use crate::planner::logical::LogicalPlan;
    use crate::sql::ast::BinaryOp;
    use crate::types::DataType;

    /// `SELECT a FROM t WHERE a > (SELECT b FROM u WHERE 1 = 1 AND b > 3)`.
    fn plan_with_subquery() -> LogicalPlan {
        let t = table("t", &["a", "b"], 4);
        let u = table("u", &["b", "c"], 4);
        let sub_plan = project(
            filter(
                scan(&u),
                and(
                    cmp(BinaryOp::Eq, int(1), int(1)),
                    cmp(BinaryOp::Gt, col(0), int(3)),
                ),
            ),
            &[0],
        );
        let sub = Expr::ScalarSubquery {
            sub: Arc::new(SubqueryPlan {
                id: 0,
                plan: sub_plan,
            }),
            params: Vec::new(),
            ty: DataType::Int64,
        };
        project(filter(scan(&t), cmp(BinaryOp::Gt, col(0), sub)), &[0])
    }

    #[test]
    fn default_rules_are_named_and_ordered() {
        assert_eq!(
            Optimizer::for_query(true).rule_names(),
            [
                "constant_folding",
                "predicate_pushdown",
                "join_reorder",
                "column_pruning"
            ]
        );
    }

    #[test]
    fn optimize_false_applies_no_rule() {
        let plan = plan_with_subquery();
        let before = show(&plan);
        assert!(Optimizer::for_query(false).rule_names().is_empty());
        assert_eq!(show(&Optimizer::for_query(false).optimize(plan)), before);
    }

    #[test]
    fn subquery_plans_are_optimized_too() {
        let optimized = Optimizer::for_query(true).optimize(plan_with_subquery());
        assert_eq!(
            show(&optimized),
            "Project [a := #0]\n\
             \x20 Filter (#0 > $subquery0)\n\
             \x20   Scan t [a]\n\
             $subquery0:\n\
             \x20 Project [b := #0]\n\
             \x20   Filter (#0 > 3)\n\
             \x20     Scan u [b]"
        );
    }

    #[test]
    fn a_single_rule_can_be_applied_alone() {
        let optimizer = Optimizer::new(&[&ColumnPruning]);
        let optimized = optimizer.optimize(plan_with_subquery());
        // The tautology is still there: only pruning ran.
        assert!(show(&optimized).contains("Filter ((1 = 1) AND (#0 > 3))"));
        assert!(show(&optimized).contains("Scan t [a]"));
    }
}
