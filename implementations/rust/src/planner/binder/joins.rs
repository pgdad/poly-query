//! Binding of join chains (`a JOIN b ON … JOIN c ON …`, `a, b, c`).
//!
//! The parser builds a chain as a left-deep tree. It is bound iteratively,
//! left to right (the same order, scopes and errors as a recursive
//! binding). Each maximal run of INNER/CROSS joins becomes a left-deep join
//! tree, as written, unless it is long: then it becomes a balanced tree
//! (same leaves, same output column order), each ON conjunct attached to
//! the lowest join covering the tables it references. A left-deep tree
//! repeats the columns of all tables below every join in its schema, which
//! is quadratic in the number of tables (CR-6: statements of 25,000
//! operands may join thousands of tables); a balanced tree needs
//! `n·log n`.

use std::collections::HashMap;

use super::scope::{Correlation, CteEnv, ExprScope, Scope};
use super::{AggMode, Binder};
use crate::error::Result;
use crate::planner::expr::Expr;
use crate::planner::logical::{JoinType, LogicalPlan};
use crate::sql::ast::{FromItem, JoinKind};

/// Runs of more than this many inner-joined inputs are built balanced.
pub const BALANCED_JOIN_MIN_INPUTS: usize = 64;

/// One input of a run of inner joins and the join that added it.
struct Input {
    plan: LogicalPlan,
    /// First column in the run's layout.
    offset: usize,
    /// Join type and bound condition (in the run's layout) of the join
    /// that added this input (None for the first input).
    join: Option<(JoinType, Option<Expr>)>,
}

/// A maximal run of INNER/CROSS joins being bound.
#[derive(Default)]
struct Run {
    inputs: Vec<Input>,
    width: usize,
}

impl Run {
    fn push(&mut self, plan: LogicalPlan, join: Option<(JoinType, Option<Expr>)>) {
        let width = plan.width();
        self.inputs.push(Input {
            plan,
            offset: self.width,
            join,
        });
        self.width += width;
    }

    /// The run's join tree.
    fn finish(self, binder: &Binder<'_>) -> Result<LogicalPlan> {
        if self.inputs.len() > BALANCED_JOIN_MIN_INPUTS {
            return balanced(self.inputs, binder);
        }
        let mut inputs = self.inputs.into_iter();
        let mut acc = inputs.next().map_or(LogicalPlan::SingleRow, |i| i.plan);
        for input in inputs {
            let (join_type, on) = input.join.unwrap_or((JoinType::Cross, None));
            acc = join(binder, acc, input.plan, join_type, on)?;
        }
        Ok(acc)
    }
}

/// A join node, accounted in the statement's plan size (its schema repeats
/// the columns of both inputs).
fn join(
    binder: &Binder<'_>,
    left: LogicalPlan,
    right: LogicalPlan,
    join_type: JoinType,
    on: Option<Expr>,
) -> Result<LogicalPlan> {
    binder.grow_plan(1 + left.width() + right.width())?;
    Ok(LogicalPlan::join(left, right, join_type, on))
}

/// Balanced join tree over `inputs` (in order). Every conjunct of the ON
/// conditions is attached to the lowest join whose inputs contain all the
/// inputs it references (a conjunct without columns stays with the join
/// that introduced it).
fn balanced(inputs: Vec<Input>, binder: &Binder<'_>) -> Result<LogicalPlan> {
    let offsets: Vec<usize> = inputs.iter().map(|i| i.offset).collect();
    let input_of = |col: usize| offsets.partition_point(|&o| o <= col) - 1;
    let n = inputs.len();
    // Conjuncts by the (lo, hi) input range of the join they belong to.
    let mut attached: HashMap<(usize, usize), Vec<Expr>> = HashMap::new();
    let mut plans = Vec::with_capacity(n);
    for (k, input) in inputs.into_iter().enumerate() {
        if let Some((_, Some(on))) = input.join {
            let mut conjuncts = Vec::new();
            on.into_conjuncts(&mut conjuncts);
            for c in conjuncts {
                let cols = c.columns();
                let (first, last) = match (cols.first(), cols.last()) {
                    (Some(&a), Some(&b)) => (input_of(a), input_of(b)),
                    _ => (k, k),
                };
                attached
                    .entry(covering_join(first, last, n))
                    .or_default()
                    .push(c);
            }
        }
        plans.push(Some(input.plan));
    }
    build(&mut plans, &offsets, 0, n, &mut attached, binder)
}

/// The input range `(lo, hi)` of the lowest join of the balanced tree over
/// `0..n` containing inputs `first..=last`.
fn covering_join(first: usize, last: usize, n: usize) -> (usize, usize) {
    let (mut lo, mut hi) = (0, n);
    loop {
        let mid = lo + (hi - lo) / 2;
        if last < mid && mid - lo >= 2 {
            hi = mid;
        } else if first >= mid && hi - mid >= 2 {
            lo = mid;
        } else {
            return (lo, hi);
        }
    }
}

fn build(
    plans: &mut [Option<LogicalPlan>],
    offsets: &[usize],
    lo: usize,
    hi: usize,
    attached: &mut HashMap<(usize, usize), Vec<Expr>>,
    binder: &Binder<'_>,
) -> Result<LogicalPlan> {
    if hi - lo == 1 {
        return Ok(plans[lo].take().unwrap_or(LogicalPlan::SingleRow));
    }
    let mid = lo + (hi - lo) / 2;
    let left = build(plans, offsets, lo, mid, attached, binder)?;
    let right = build(plans, offsets, mid, hi, attached, binder)?;
    let shift = offsets[lo];
    let mut conjuncts = attached.remove(&(lo, hi)).unwrap_or_default();
    for c in &mut conjuncts {
        c.remap_columns(&|i| i - shift);
    }
    let on = Expr::conjunction(conjuncts);
    let join_type = if on.is_some() {
        JoinType::Inner
    } else {
        JoinType::Cross
    };
    join(binder, left, right, join_type, on)
}

impl Binder<'_> {
    /// Binds a join chain (`item` is a `FromItem::Join`).
    pub(super) fn bind_join_chain(
        &self,
        item: &FromItem,
        corr: Option<&Correlation<'_>>,
        env: &CteEnv<'_>,
    ) -> Result<(LogicalPlan, Scope)> {
        // The left spine, from the first joined item on.
        let mut links = Vec::new();
        let mut base = item;
        while let FromItem::Join {
            left,
            right,
            kind,
            on,
            pos,
        } = base
        {
            links.push((&**right, *kind, on.as_ref(), *pos));
            base = left;
        }
        links.reverse();
        let (plan, mut scope) = self.bind_from(base, corr, env)?;
        let mut run = Run::default();
        run.push(plan, None);
        // A run always starts with everything joined before it, so its
        // layout is the FROM clause's layout (column numbers need no shift).
        for (right, kind, on, pos) in links {
            crate::interrupt::poll()?;
            let (rp, rs) = self.bind_from(right, corr, env)?;
            debug_assert_eq!(scope.width(), run.width);
            scope = Scope::merge(scope, rs).map_err(|e| pos.error(e))?;
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
            match kind {
                JoinKind::Left => {
                    // A LEFT join ends the run; its result starts the next.
                    let left = std::mem::take(&mut run).finish(self)?;
                    run.push(join(self, left, rp, JoinType::Left, on)?, None);
                }
                JoinKind::Inner => run.push(rp, Some((JoinType::Inner, on))),
                JoinKind::Cross => run.push(rp, Some((JoinType::Cross, on))),
            }
        }
        Ok((run.finish(self)?, scope))
    }
}

#[cfg(test)]
mod tests {
    use super::covering_join;

    #[test]
    fn covering_joins_of_a_balanced_tree() {
        // 0..8: (0,8) → (0,4) (4,8) → (0,2) (2,4) (4,6) (6,8)
        assert_eq!(covering_join(0, 1, 8), (0, 2));
        assert_eq!(covering_join(1, 2, 8), (0, 4));
        assert_eq!(covering_join(3, 4, 8), (0, 8));
        assert_eq!(covering_join(6, 6, 8), (6, 8));
        assert_eq!(covering_join(4, 7, 8), (4, 8));
        // Odd sizes: 0..5 → (0,2) (2,5) → (3,5)
        assert_eq!(covering_join(2, 2, 5), (2, 5));
        assert_eq!(covering_join(4, 4, 5), (3, 5));
    }
}
