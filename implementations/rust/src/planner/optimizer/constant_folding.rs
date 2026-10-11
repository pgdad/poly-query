//! Rule `constant_folding`: folds literal-only expressions to literals and
//! simplifies boolean structure (filters and join conditions that become
//! `TRUE` disappear). Both preserve results and errors:
//!
//! * a constant subexpression is replaced by its value only if evaluating
//!   it succeeds (`1/0` stays, and fails at run time only if evaluated);
//! * boolean simplifications only drop an operand the row engine would not
//!   evaluate either (`FALSE AND x`) or one that cannot fail.

use super::Rule;
use crate::exec::eval::eval_constant;
use crate::planner::expr::{Expr, ScalarFunc};
use crate::planner::logical::LogicalPlan;
use crate::sql::ast::BinaryOp;
use crate::types::Value;

pub struct ConstantFolding;

impl Rule for ConstantFolding {
    fn name(&self) -> &'static str {
        "constant_folding"
    }

    fn apply(&self, plan: LogicalPlan) -> LogicalPlan {
        simplify_plan(plan)
    }
}

/// Folds and simplifies every expression of `plan` (not descending into
/// subquery plans).
fn simplify_plan(plan: LogicalPlan) -> LogicalPlan {
    let b = |p: Box<LogicalPlan>| Box::new(simplify_plan(*p));
    match plan {
        LogicalPlan::SingleRow | LogicalPlan::Scan { .. } => plan,
        LogicalPlan::Filter { input, predicate } => {
            let predicate = simplify(predicate);
            if is_true(&predicate) {
                return simplify_plan(*input);
            }
            LogicalPlan::Filter {
                input: b(input),
                predicate,
            }
        }
        LogicalPlan::Project {
            input,
            exprs,
            schema,
        } => LogicalPlan::Project {
            input: b(input),
            exprs: exprs.into_iter().map(simplify).collect(),
            schema,
        },
        LogicalPlan::Aggregate {
            input,
            group_by,
            mut aggregates,
            schema,
        } => {
            for a in &mut aggregates {
                a.arg = a.arg.take().map(simplify);
            }
            LogicalPlan::Aggregate {
                input: b(input),
                group_by: group_by.into_iter().map(simplify).collect(),
                aggregates,
                schema,
            }
        }
        LogicalPlan::Join {
            left,
            right,
            join_type,
            on,
            schema,
        } => LogicalPlan::Join {
            left: b(left),
            right: b(right),
            join_type,
            on: on.map(simplify).filter(|on| !is_true(on)),
            schema,
        },
        LogicalPlan::Distinct { input } => LogicalPlan::Distinct { input: b(input) },
        LogicalPlan::Sort { input, mut keys } => {
            for k in &mut keys {
                k.expr = simplify(std::mem::replace(&mut k.expr, placeholder()));
            }
            LogicalPlan::Sort {
                input: b(input),
                keys,
            }
        }
        LogicalPlan::Limit {
            input,
            offset,
            limit,
        } => LogicalPlan::Limit {
            input: b(input),
            offset,
            limit,
        },
        LogicalPlan::UnionAll { inputs, schema } => LogicalPlan::UnionAll {
            inputs: inputs.into_iter().map(simplify_plan).collect(),
            schema,
        },
    }
}

fn placeholder() -> Expr {
    Expr::Literal {
        value: Value::Null,
        ty: crate::types::DataType::Null,
    }
}

fn is_true(e: &Expr) -> bool {
    matches!(
        e,
        Expr::Literal {
            value: Value::Bool(true),
            ..
        }
    )
}

fn is_false(e: &Expr) -> bool {
    matches!(
        e,
        Expr::Literal {
            value: Value::Bool(false),
            ..
        }
    )
}

fn bool_literal(b: bool) -> Expr {
    Expr::Literal {
        value: Value::Bool(b),
        ty: crate::types::DataType::Boolean,
    }
}

/// Logical negation of a comparison operator (3VL-safe: NULL stays NULL).
fn negate(op: BinaryOp) -> Option<BinaryOp> {
    Some(match op {
        BinaryOp::Eq => BinaryOp::NotEq,
        BinaryOp::NotEq => BinaryOp::Eq,
        BinaryOp::Lt => BinaryOp::GtEq,
        BinaryOp::LtEq => BinaryOp::Gt,
        BinaryOp::Gt => BinaryOp::LtEq,
        BinaryOp::GtEq => BinaryOp::Lt,
        _ => return None,
    })
}

/// Can this node be evaluated at planning time once its children are
/// literals?
fn foldable(e: &Expr) -> bool {
    !matches!(
        e,
        Expr::Literal { .. }
            | Expr::Column { .. }
            | Expr::Param { .. }
            | Expr::AggRef { .. }
            | Expr::ScalarSubquery { .. }
            | Expr::Exists { .. }
            | Expr::InSubquery { .. }
            | Expr::Function {
                func: ScalarFunc::PqSleep,
                ..
            }
    ) && e
        .children()
        .iter()
        .all(|c| matches!(c, Expr::Literal { .. }))
}

/// Folds constants and simplifies boolean structure, bottom-up.
pub fn simplify(mut e: Expr) -> Expr {
    for c in e.children_mut() {
        *c = simplify(std::mem::replace(c, placeholder()));
    }
    let e = match e {
        Expr::And(l, r) => {
            if is_true(&l) {
                return *r;
            }
            if is_true(&r) {
                return *l;
            }
            // FALSE AND x: the row engine does not evaluate x either.
            if is_false(&l) || (is_false(&r) && l.is_infallible()) {
                return bool_literal(false);
            }
            Expr::And(l, r)
        }
        Expr::Or(l, r) => {
            if is_false(&l) {
                return *r;
            }
            if is_false(&r) {
                return *l;
            }
            if is_true(&l) || (is_true(&r) && l.is_infallible()) {
                return bool_literal(true);
            }
            Expr::Or(l, r)
        }
        Expr::Not(inner) => match *inner {
            Expr::Not(x) => *x,
            Expr::Compare { op, left, right } if negate(op).is_some() => Expr::Compare {
                op: negate(op).unwrap_or(op),
                left,
                right,
            },
            other => Expr::Not(Box::new(other)),
        },
        other => other,
    };
    if foldable(&e)
        && let Ok(value) = eval_constant(&e)
    {
        return Expr::Literal {
            ty: e.data_type(),
            value,
        };
    }
    e
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planner::expr::ArithKind;
    use crate::types::DataType;

    fn int(i: i64) -> Box<Expr> {
        Box::new(Expr::Literal {
            value: Value::Int(i),
            ty: DataType::Int64,
        })
    }

    fn col() -> Box<Expr> {
        Box::new(Expr::Column {
            index: 0,
            ty: DataType::Int64,
        })
    }

    #[test]
    fn folds_constants_but_not_errors() {
        let e = Expr::Arith {
            op: BinaryOp::Add,
            kind: ArithKind::Int,
            left: int(1),
            right: int(2),
            ty: DataType::Int64,
        };
        assert!(matches!(
            simplify(e),
            Expr::Literal {
                value: Value::Int(3),
                ..
            }
        ));
        let div = Expr::Arith {
            op: BinaryOp::Div,
            kind: ArithKind::Int,
            left: int(1),
            right: int(0),
            ty: DataType::Int64,
        };
        assert!(matches!(simplify(div), Expr::Arith { .. }));
    }

    #[test]
    fn simplifies_boolean_structure() {
        let cmp = Expr::Compare {
            op: BinaryOp::Lt,
            left: col(),
            right: int(5),
        };
        let always = Expr::Compare {
            op: BinaryOp::Eq,
            left: int(1),
            right: int(1),
        };
        let e = Expr::And(Box::new(always), Box::new(cmp.clone()));
        assert_eq!(simplify(e), cmp);
        let e = Expr::Not(Box::new(cmp));
        assert!(matches!(
            simplify(e),
            Expr::Compare {
                op: BinaryOp::GtEq,
                ..
            }
        ));
    }

    #[test]
    fn removes_filters_and_join_conditions_that_fold_to_true() {
        use crate::planner::logical::JoinType;
        use crate::planner::optimizer::test_util::{self, apply_checked, scan, show, table};
        let t = table("t", &["a"], 5);
        let u = table("u", &["b"], 3);
        let always = || test_util::cmp(BinaryOp::Lt, *int(1), *int(2));
        let joined = test_util::join(scan(&t), scan(&u), JoinType::Inner, Some(always()));
        let plan = apply_checked(&ConstantFolding, test_util::filter(joined, always()));
        assert_eq!(show(&plan), "Join INNER\n  Scan t [a]\n  Scan u [b]");
    }

    #[test]
    fn folds_projections_and_keeps_failing_constants() {
        use crate::planner::optimizer::test_util::{project, scan, show, table};
        let t = table("t", &["a"], 2);
        let mut plan = project(scan(&t), &[0, 0]);
        if let LogicalPlan::Project { exprs, .. } = &mut plan {
            let arith = |op, right| Expr::Arith {
                op,
                kind: ArithKind::Int,
                left: int(6),
                right,
                ty: DataType::Int64,
            };
            exprs[0] = arith(BinaryOp::Mul, int(7));
            exprs[1] = arith(BinaryOp::Div, int(0));
        }
        assert_eq!(
            show(&ConstantFolding.apply(plan)),
            "Project [a := 42, a := (6 / 0)]\n  Scan t [a]"
        );
    }
}
