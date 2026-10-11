//! Vectorized subquery predicates (semi-join probes):
//!
//! * uncorrelated `x [NOT] IN (subquery)`: the subquery's values are
//!   collected once per query into a [`KeySet`] and every batch probes it;
//! * correlated `EXISTS (subquery)` whose subquery is only an existence
//!   check of a `ParamLookup` (`inner_key = <outer value>` over a
//!   parameter-independent input, no residual): the input's keys are
//!   collected once per query and every row probes them with its parameter
//!   values, instead of executing the subquery per distinct outer row.
//!
//! Key sets are shared by all threads of the query (built by the first
//! thread that needs them). Keys are normalized for their comparison domain
//! exactly as by the row engine (`normalize_key`), and single INT64 keys use
//! a typed set. Results equal the row-at-a-time evaluation (semantics.md §8).

use super::batch::{Batch, Data, Vector};
use super::build::build;
use super::eval::eval;
use crate::error::Result;
use crate::exec::ExecContext;
use crate::exec::eval::normalize_key;
use crate::exec::hash::FastSet;
use crate::planner::expr::{Expr, KeyDomain, SubqueryPlan};
use crate::planner::physical::{JoinKey, PhysicalPlan};
use crate::types::Value;

/// Distinct non-NULL key tuples of a subquery or lookup input.
#[derive(Debug, Default)]
pub struct KeySet {
    /// Single INT64 keys, while every key is one (then `values` is empty).
    ints: Option<FastSet<i64>>,
    values: FastSet<Vec<Value>>,
    /// A NULL value was seen (IN subqueries).
    has_null: bool,
    /// No rows at all.
    empty: bool,
}

impl KeySet {
    fn new() -> KeySet {
        KeySet {
            ints: Some(FastSet::default()),
            values: FastSet::default(),
            has_null: false,
            empty: true,
        }
    }

    /// Adds a normalized, non-NULL key. Returns whether it is new.
    fn insert(&mut self, key: Vec<Value>) -> bool {
        if let Some(ints) = &mut self.ints {
            if let [Value::Int(x)] = key.as_slice() {
                return ints.insert(*x);
            }
            // Another representation: from now on, generic keys only.
            self.values = ints.drain().map(|x| vec![Value::Int(x)]).collect();
            self.ints = None;
        }
        self.values.insert(key)
    }

    fn insert_int(&mut self, x: i64) -> bool {
        match &mut self.ints {
            Some(ints) => ints.insert(x),
            None => self.values.insert(vec![Value::Int(x)]),
        }
    }

    fn contains(&self, key: &[Value]) -> bool {
        match (&self.ints, key) {
            (Some(ints), [Value::Int(x)]) => ints.contains(x),
            (Some(_), _) => false,
            (None, _) => self.values.contains(key),
        }
    }

    fn contains_int(&self, x: i64) -> bool {
        match &self.ints {
            Some(ints) => ints.contains(&x),
            None => self.values.contains(&[Value::Int(x)][..]),
        }
    }

    /// Adds the keys `keys` (expressions with their domains) of every row
    /// of `plan`'s output; rows with a NULL key component are skipped (and
    /// noted in `has_null`).
    fn collect(
        plan: PhysicalPlan,
        keys: &[(&Expr, KeyDomain)],
        ctx: &ExecContext,
    ) -> Result<KeySet> {
        let mut set = KeySet::new();
        let mut op = build(plan, ctx);
        while let Some(b) = op.next_batch(ctx)? {
            if b.len == 0 {
                continue;
            }
            set.empty = false;
            let vectors = keys
                .iter()
                .map(|(e, _)| eval(e, &b, ctx))
                .collect::<Result<Vec<_>>>()?;
            let before = set.len();
            match (vectors.as_slice(), keys) {
                ([v], [(_, KeyDomain::Exact)]) if let Data::Int(x) = &v.data => {
                    for (i, &x) in x.iter().enumerate() {
                        if v.valid.as_ref().is_none_or(|ok| ok[i]) {
                            set.insert_int(x);
                        } else {
                            set.has_null = true;
                        }
                    }
                }
                _ => {
                    for i in 0..b.len {
                        match key_at(&vectors, keys.iter().map(|k| k.1), i) {
                            Some(key) => {
                                set.insert(key);
                            }
                            None => set.has_null = true,
                        }
                    }
                }
            }
            ctx.reserve((set.len() - before) * 32)?;
        }
        Ok(set)
    }

    fn len(&self) -> usize {
        self.ints.as_ref().map_or(0, FastSet::len) + self.values.len()
    }
}

/// The normalized key of row `i` (None if a component is NULL).
fn key_at(
    vectors: &[Vector],
    domains: impl Iterator<Item = KeyDomain>,
    i: usize,
) -> Option<Vec<Value>> {
    let mut key = Vec::with_capacity(vectors.len());
    for (v, domain) in vectors.iter().zip(domains) {
        let x = v.value(i);
        if x.is_null() {
            return None;
        }
        key.push(normalize_key(x, domain));
    }
    Some(key)
}

/// `x [NOT] IN (subquery)` over `b` for an uncorrelated subquery.
pub fn in_subquery(
    x: &Expr,
    sub: &SubqueryPlan,
    negated: bool,
    domain: KeyDomain,
    b: &Batch,
    ctx: &ExecContext,
) -> Result<Vector> {
    let set = ctx.shared_key_set((0, sub.id), || {
        let plan = ctx.subquery_plan(sub.id)?.plan.clone();
        let first = Expr::Column {
            index: 0,
            ty: plan.schema()[0].data_type,
        };
        KeySet::collect(plan, &[(&first, domain)], ctx)
    })?;
    let x = eval(x, b, ctx)?;
    let n = b.len;
    let mut values = vec![false; n];
    let mut valid = vec![true; n];
    // Three-valued result of `x IN set` for a non-NULL x found or not.
    let mut set_result = |i: usize, found: bool| {
        if found {
            values[i] = !negated;
        } else if set.has_null {
            valid[i] = false;
        } else {
            values[i] = negated;
        }
    };
    if set.empty {
        return Ok(Vector::new(Data::Bool(vec![negated; n]), None));
    }
    match (&x.data, domain) {
        (Data::Int(xs), KeyDomain::Exact) => {
            for (i, &v) in xs.iter().enumerate() {
                if x.valid.as_ref().is_none_or(|ok| ok[i]) {
                    set_result(i, set.contains_int(v));
                }
            }
        }
        _ => {
            for i in 0..n {
                let v = x.value(i);
                if !v.is_null() {
                    set_result(i, set.contains(&[normalize_key(v, domain)]));
                }
            }
        }
    }
    if let Some(xv) = &x.valid {
        for (ok, &x_ok) in valid.iter_mut().zip(xv) {
            *ok &= x_ok;
        }
    } else if let Data::Values(_) | Data::Null = x.data {
        for (i, ok) in valid.iter_mut().enumerate() {
            *ok &= !x.is_null(i);
        }
    }
    let all_valid = valid.iter().all(|&v| v);
    Ok(Vector::new(
        Data::Bool(values),
        (!all_valid).then_some(valid),
    ))
}

/// The `ParamLookup` of a subquery plan that is only an existence check of
/// it: Project (of columns/literals only, which cannot fail) and LIMIT
/// without OFFSET over a ParamLookup without residual predicate.
fn lookup_of(plan: &PhysicalPlan) -> Option<(usize, &PhysicalPlan, &[JoinKey])> {
    match plan {
        PhysicalPlan::Project { input, exprs, .. }
            if exprs
                .iter()
                .all(|e| matches!(e, Expr::Column { .. } | Expr::Literal { .. })) =>
        {
            lookup_of(input)
        }
        PhysicalPlan::Limit {
            input,
            offset: 0,
            limit,
        } if *limit != Some(0) => lookup_of(input),
        PhysicalPlan::ParamLookup {
            id,
            input,
            keys,
            residual: None,
        } => Some((*id, input, keys)),
        _ => None,
    }
}

/// `EXISTS (subquery)` over `b` for a correlated existence check of a
/// `ParamLookup` (None: another kind of subquery).
pub fn exists(
    sub: &SubqueryPlan,
    params: &[Expr],
    b: &Batch,
    ctx: &ExecContext,
) -> Result<Option<Vector>> {
    let plan = &ctx.subquery_plan(sub.id)?.plan;
    let Some((id, input, keys)) = lookup_of(plan) else {
        return Ok(None);
    };
    // Each probe key must be a parameter: (parameter index, domain).
    let mut probes = Vec::with_capacity(keys.len());
    for k in keys {
        match k.right {
            Expr::Param { index, .. } if index < params.len() => probes.push((index, k.domain)),
            _ => return Ok(None),
        }
    }
    let set = ctx.shared_key_set((1, id), || {
        let inner: Vec<(&Expr, KeyDomain)> = keys.iter().map(|k| (&k.left, k.domain)).collect();
        KeySet::collect(input.clone(), &inner, ctx)
    })?;
    let vectors = probes
        .iter()
        .map(|&(p, _)| eval(&params[p], b, ctx))
        .collect::<Result<Vec<_>>>()?;
    let out: Vec<bool> = match (vectors.as_slice(), probes.as_slice()) {
        ([v], [(_, KeyDomain::Exact)]) if let Data::Int(xs) = &v.data => xs
            .iter()
            .enumerate()
            .map(|(i, &x)| v.valid.as_ref().is_none_or(|ok| ok[i]) && set.contains_int(x))
            .collect(),
        _ => (0..b.len)
            .map(|i| {
                key_at(&vectors, probes.iter().map(|p| p.1), i).is_some_and(|k| set.contains(&k))
            })
            .collect(),
    };
    Ok(Some(Vector::new(Data::Bool(out), None)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_set_switches_from_ints_to_generic_keys() {
        let mut s = KeySet::new();
        assert!(s.insert(vec![Value::Int(3)]));
        assert!(!s.insert_int(3));
        assert!(s.contains_int(3) && !s.contains_int(4));
        assert!(s.insert(vec![Value::Decimal(15, 1)]));
        assert!(s.contains_int(3));
        assert!(s.contains(&[Value::Decimal(15, 1)]));
        assert!(s.contains(&[Value::Int(3)]));
        assert_eq!(s.len(), 2);
    }
}
