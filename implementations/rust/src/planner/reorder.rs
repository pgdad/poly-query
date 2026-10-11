//! Join reordering for chains of inner joins (query option `optimize`).
//!
//! A maximal tree of INNER/CROSS joins is flattened into its inputs
//! ("leaves", which may be LEFT joins, derived tables, …) and the conjuncts
//! of all its join conditions. The inputs are then joined greedily, left
//! deep: first the connected pair with the smallest estimated result, then
//! repeatedly the input that keeps the estimated intermediate result
//! smallest (never a cross product while a connected input remains).
//! Join sizes are estimated as `|A|·|B| / max(ndv(a), ndv(b))` for an
//! equality `a = b`, with distinct counts from the column statistics.
//! Each conjunct is attached to the first join where all its columns are
//! available; a projection restores the original column order.

use std::collections::HashSet;

use super::expr::Expr;
use super::logical::{JoinType, LogicalPlan};
use super::physical::estimate_rows;
use crate::sql::ast::BinaryOp;
use crate::storage::Field;

/// Reorders every inner-join chain of `plan` (bottom-up).
pub fn reorder_joins(plan: LogicalPlan) -> LogicalPlan {
    let b = |p: Box<LogicalPlan>| Box::new(reorder_joins(*p));
    match plan {
        LogicalPlan::Join {
            join_type: JoinType::Inner | JoinType::Cross,
            ..
        } => reorder_chain(plan),
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
            on,
            schema,
        },
        LogicalPlan::SingleRow | LogicalPlan::Scan { .. } => plan,
        LogicalPlan::Filter { input, predicate } => LogicalPlan::Filter {
            input: b(input),
            predicate,
        },
        LogicalPlan::Project {
            input,
            exprs,
            schema,
        } => LogicalPlan::Project {
            input: b(input),
            exprs,
            schema,
        },
        LogicalPlan::Aggregate {
            input,
            group_by,
            aggregates,
            schema,
        } => LogicalPlan::Aggregate {
            input: b(input),
            group_by,
            aggregates,
            schema,
        },
        LogicalPlan::Distinct { input } => LogicalPlan::Distinct { input: b(input) },
        LogicalPlan::Sort { input, keys } => LogicalPlan::Sort {
            input: b(input),
            keys,
        },
        LogicalPlan::Limit {
            input,
            offset,
            limit,
        } => LogicalPlan::Limit {
            input: b(input),
            offset,
            limit,
        },
    }
}

struct Leaf {
    /// First column in the original (flattened) layout.
    offset: usize,
    width: usize,
    plan: LogicalPlan,
    rows: f64,
}

/// Collects the leaves and (globally indexed) conjuncts of an inner-join tree.
fn flatten(plan: LogicalPlan, offset: usize, leaves: &mut Vec<Leaf>, conjuncts: &mut Vec<Expr>) {
    match plan {
        LogicalPlan::Join {
            left,
            right,
            join_type: JoinType::Inner | JoinType::Cross,
            on,
            ..
        } => {
            let lw = left.width();
            flatten(*left, offset, leaves, conjuncts);
            flatten(*right, offset + lw, leaves, conjuncts);
            if let Some(on) = on {
                let mut cs = Vec::new();
                on.into_conjuncts(&mut cs);
                for mut c in cs {
                    c.remap_columns(&|i| i + offset);
                    conjuncts.push(c);
                }
            }
        }
        other => {
            let plan = reorder_joins(other);
            let width = plan.width();
            let rows = estimate_rows(&plan).max(1.0);
            leaves.push(Leaf {
                offset,
                width,
                plan,
                rows,
            });
        }
    }
}

/// Distinct values of output column `col` of `plan`, if traceable to a
/// table column with statistics.
fn column_ndv(plan: &LogicalPlan, col: usize) -> Option<f64> {
    match plan {
        LogicalPlan::Scan { table, columns, .. } => table
            .column_stats(columns[col])
            .ok()
            .map(|s| s.distinct_count.max(1) as f64),
        LogicalPlan::Filter { input, .. }
        | LogicalPlan::Sort { input, .. }
        | LogicalPlan::Limit { input, .. }
        | LogicalPlan::Distinct { input } => column_ndv(input, col),
        LogicalPlan::Project { input, exprs, .. } => match &exprs[col] {
            Expr::Column { index, .. } => column_ndv(input, *index),
            _ => None,
        },
        LogicalPlan::Join { left, right, .. } => {
            let lw = left.width();
            if col < lw {
                column_ndv(left, col)
            } else {
                column_ndv(right, col - lw)
            }
        }
        _ => None,
    }
}

/// An equality conjunct `a = b` between two leaves.
struct EquiEdge {
    a: usize,
    b: usize,
    ndv_a: f64,
    ndv_b: f64,
}

/// Leaves referenced by a conjunct.
fn leaves_of(c: &Expr, leaves: &[Leaf]) -> HashSet<usize> {
    c.columns()
        .into_iter()
        .filter_map(|g| {
            leaves
                .iter()
                .position(|l| g >= l.offset && g < l.offset + l.width)
        })
        .collect()
}

fn equi_edge(c: &Expr, leaves: &[Leaf]) -> Option<EquiEdge> {
    let Expr::Compare {
        op: BinaryOp::Eq,
        left,
        right,
    } = c
    else {
        return None;
    };
    let side = |e: &Expr| -> Option<(usize, f64)> {
        let set = leaves_of(e, leaves);
        if set.len() != 1 {
            return None;
        }
        let leaf = *set.iter().next()?;
        let l = &leaves[leaf];
        let ndv = match e {
            Expr::Column { index, .. } => column_ndv(&l.plan, index - l.offset),
            _ => None,
        };
        Some((leaf, ndv.unwrap_or(l.rows).min(l.rows).max(1.0)))
    };
    let (a, ndv_a) = side(left)?;
    let (b, ndv_b) = side(right)?;
    (a != b).then_some(EquiEdge { a, b, ndv_a, ndv_b })
}

/// Estimated size of joining the leaves in `set` (estimated `rows`) with
/// leaf `next`, and whether they are connected by an equality.
fn join_estimate(
    set: &[bool],
    rows: f64,
    next: usize,
    leaves: &[Leaf],
    edges: &[EquiEdge],
) -> (f64, bool) {
    let mut best: Option<f64> = None;
    for e in edges {
        let (inside, ndv_in, ndv_next) = if e.b == next && set[e.a] {
            (true, e.ndv_a, e.ndv_b)
        } else if e.a == next && set[e.b] {
            (true, e.ndv_b, e.ndv_a)
        } else {
            (false, 0.0, 0.0)
        };
        if inside {
            let est = rows * leaves[next].rows / ndv_in.min(rows).max(ndv_next).max(1.0);
            best = Some(best.map_or(est, |b: f64| b.min(est)));
        }
    }
    match best {
        Some(b) => (b.max(1.0), true),
        None => (rows * leaves[next].rows, false),
    }
}

/// Greedy join order (indices into `leaves`).
fn greedy_order(leaves: &[Leaf], edges: &[EquiEdge]) -> Vec<usize> {
    let n = leaves.len();
    // Starting pair: connected and smallest estimated result.
    let mut start: Option<(f64, usize, usize)> = None;
    for e in edges {
        let mut set = vec![false; n];
        set[e.a] = true;
        let (est, _) = join_estimate(&set, leaves[e.a].rows, e.b, leaves, edges);
        let (a, b) = if leaves[e.a].rows >= leaves[e.b].rows {
            (e.a, e.b)
        } else {
            (e.b, e.a)
        };
        if start.is_none_or(|(s, _, _)| est < s) {
            start = Some((est, a, b));
        }
    }
    let Some((mut rows, a, b)) = start else {
        return (0..n).collect();
    };
    let mut order = vec![a, b];
    let mut set = vec![false; n];
    set[a] = true;
    set[b] = true;
    while order.len() < n {
        let mut pick: Option<(bool, f64, usize)> = None;
        for next in (0..n).filter(|&i| !set[i]) {
            let (est, connected) = join_estimate(&set, rows, next, leaves, edges);
            let better = match pick {
                None => true,
                Some((pc, pe, _)) => (connected && !pc) || (connected == pc && est < pe),
            };
            if better {
                pick = Some((connected, est, next));
            }
        }
        let Some((_, est, next)) = pick else { break };
        rows = est;
        set[next] = true;
        order.push(next);
    }
    order
}

fn reorder_chain(plan: LogicalPlan) -> LogicalPlan {
    let schema: Vec<Field> = plan.schema().to_vec();
    let mut leaves = Vec::new();
    let mut conjuncts = Vec::new();
    flatten(plan, 0, &mut leaves, &mut conjuncts);
    let n = leaves.len();
    let order: Vec<usize> = if n >= 3 {
        let edges: Vec<EquiEdge> = conjuncts
            .iter()
            .filter_map(|c| equi_edge(c, &leaves))
            .collect();
        greedy_order(&leaves, &edges)
    } else {
        (0..n).collect()
    };
    // New position of every original column.
    let mut new_pos = vec![0usize; schema.len()];
    let mut offset = 0;
    for &i in &order {
        let l = &leaves[i];
        for j in 0..l.width {
            new_pos[l.offset + j] = offset + j;
        }
        offset += l.width;
    }
    let conj_leaves: Vec<HashSet<usize>> =
        conjuncts.iter().map(|c| leaves_of(c, &leaves)).collect();
    let mut pending: Vec<Option<Expr>> = conjuncts.into_iter().map(Some).collect();
    let identity = order.iter().enumerate().all(|(k, &i)| k == i);
    let mut slots: Vec<Option<LogicalPlan>> = leaves.into_iter().map(|l| Some(l.plan)).collect();
    let mut avail = vec![false; n];
    let mut cur: Option<LogicalPlan> = None;
    for &i in &order {
        avail[i] = true;
        let leaf = slots[i].take().unwrap_or(LogicalPlan::SingleRow);
        cur = Some(match cur {
            None => leaf,
            Some(acc) => {
                let mut on = Vec::new();
                for (k, slot) in pending.iter_mut().enumerate() {
                    if slot.is_some() && conj_leaves[k].iter().all(|&l| avail[l]) {
                        let mut c = slot.take().unwrap_or_else(|| unreachable!());
                        c.remap_columns(&|g| new_pos[g]);
                        on.push(c);
                    }
                }
                let on = Expr::conjunction(on);
                let jt = if on.is_some() {
                    JoinType::Inner
                } else {
                    JoinType::Cross
                };
                LogicalPlan::join(acc, leaf, jt, on)
            }
        });
    }
    let joined = cur.unwrap_or(LogicalPlan::SingleRow);
    if identity {
        return joined;
    }
    let exprs = schema
        .iter()
        .enumerate()
        .map(|(g, f)| Expr::Column {
            index: new_pos[g],
            ty: f.data_type,
        })
        .collect();
    LogicalPlan::Project {
        input: Box::new(joined),
        exprs,
        schema,
    }
}
