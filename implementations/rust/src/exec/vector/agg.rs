//! Vectorized hash aggregation: group ids from a [`KeyTable`], then one
//! struct-of-arrays accumulator per aggregate updated by tight per-batch
//! loops (with dedicated loops for the single-group case). Partial
//! aggregators of parallel workers are merged with [`Aggregator::merge`].
//! Final values go through [`AggState::finish`], so results and errors are
//! exactly those of row mode.

use super::batch::{Batch, Data, Vector};
use super::keys::KeyTable;
use crate::error::{Error, Result};
use crate::exec::aggregate::{AggState, Partial};
use crate::exec::ExecContext;
use crate::planner::expr::{AggFunc, AggregateCall};
use crate::types::{DataType, Value, decimal};

/// Accumulator for one aggregate over all groups.
#[derive(Debug)]
enum Acc {
    CountStar(Vec<i64>),
    Count(Vec<i64>),
    SumInt { sum: Vec<i128>, n: Vec<i64> },
    /// Unscaled sums at `scale` (the argument type's scale).
    SumDec { sum: Vec<i128>, n: Vec<i64>, scale: u8 },
    SumFloat { sum: Vec<f64>, n: Vec<i64> },
    /// MIN/MAX over fixed-width values of one representation (`kind` is
    /// the representation of the first values seen).
    ExtremeI64 { max: bool, best: Vec<i64>, has: Vec<bool>, kind: Option<I64Kind> },
    /// Any other aggregate (DISTINCT, MIN/MAX of other types): row-mode states.
    States(Vec<AggState>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum I64Kind {
    Int,
    Date,
    Ts,
    Dec(u8),
}

impl I64Kind {
    fn of(data: &Data) -> Option<I64Kind> {
        Some(match data {
            Data::Int(_) => I64Kind::Int,
            Data::Date(_) => I64Kind::Date,
            Data::Timestamp(_) => I64Kind::Ts,
            Data::Decimal(_, s) => I64Kind::Dec(*s),
            _ => return None,
        })
    }

    fn value(self, x: i64) -> Value {
        match self {
            I64Kind::Int => Value::Int(x),
            I64Kind::Date => Value::Date(x as i32),
            I64Kind::Ts => Value::Timestamp(x),
            I64Kind::Dec(s) => Value::Decimal(x, s),
        }
    }
}

fn arg_type(call: &AggregateCall) -> DataType {
    call.arg.as_ref().map(|a| a.data_type()).unwrap_or(DataType::Null)
}

impl Acc {
    fn new(call: &AggregateCall) -> Acc {
        if call.distinct {
            return Acc::States(Vec::new());
        }
        match call.func {
            AggFunc::CountStar => Acc::CountStar(Vec::new()),
            AggFunc::Count => Acc::Count(Vec::new()),
            AggFunc::Sum | AggFunc::Avg => match arg_type(call) {
                DataType::Float64 => Acc::SumFloat { sum: Vec::new(), n: Vec::new() },
                DataType::Decimal { scale, .. } => Acc::SumDec {
                    sum: Vec::new(),
                    n: Vec::new(),
                    scale,
                },
                _ => Acc::SumInt { sum: Vec::new(), n: Vec::new() },
            },
            AggFunc::Min | AggFunc::Max => match arg_type(call) {
                DataType::Int64 | DataType::Date | DataType::Timestamp | DataType::Decimal { .. } => {
                    Acc::ExtremeI64 {
                        max: call.func == AggFunc::Max,
                        best: Vec::new(),
                        has: Vec::new(),
                        kind: None,
                    }
                }
                _ => Acc::States(Vec::new()),
            },
        }
    }

    fn resize(&mut self, groups: usize, call: &AggregateCall) {
        match self {
            Acc::CountStar(c) | Acc::Count(c) => c.resize(groups, 0),
            Acc::SumInt { sum, n } | Acc::SumDec { sum, n, .. } => {
                sum.resize(groups, 0);
                n.resize(groups, 0);
            }
            Acc::SumFloat { sum, n } => {
                sum.resize(groups, 0.0);
                n.resize(groups, 0);
            }
            Acc::ExtremeI64 { best, has, .. } => {
                best.resize(groups, 0);
                has.resize(groups, false);
            }
            Acc::States(s) => s.resize_with(groups, || AggState::new(call)),
        }
    }

    /// Converts typed MIN/MAX state to row-mode states (mixed representations).
    fn to_states(&mut self, call: &AggregateCall) {
        if let Acc::ExtremeI64 { best, has, kind, .. } = self {
            let states = best
                .iter()
                .zip(has.iter())
                .map(|(&b, &h)| {
                    let v = if h { kind.map(|k| k.value(b)) } else { None };
                    AggState::from_partial(call, Partial::Extreme(v))
                })
                .collect();
            *self = Acc::States(states);
        }
    }

    /// Adds the values of `v` (None for COUNT(*)) for rows mapped to groups
    /// `gids` (None: every row belongs to group 0). Returns retained bytes.
    fn update(
        &mut self,
        call: &AggregateCall,
        gids: Option<&[u32]>,
        v: Option<&Vector>,
        n: usize,
    ) -> Result<usize> {
        let g = |i: usize| gids.map_or(0, |x| x[i] as usize);
        if let Acc::CountStar(c) = self {
            match gids {
                None => c[0] += n as i64,
                Some(gids) => {
                    for &gi in gids {
                        c[gi as usize] += 1;
                    }
                }
            }
            return Ok(0);
        }
        let Some(v) = v else {
            return Err(Error::internal("aggregate without argument"));
        };
        if let Data::Null = v.data {
            return Ok(0);
        }
        let valid = v.valid.as_deref();
        let ok = |i: usize| valid.is_none_or(|x| x[i]);
        if let Acc::ExtremeI64 { kind, .. } = self {
            let k = I64Kind::of(&v.data);
            if k.is_none() || (kind.is_some() && *kind != k) {
                self.to_states(call);
            } else {
                *kind = k;
            }
        }
        match (&mut *self, &v.data) {
            (Acc::Count(c), Data::Values(vals)) => {
                for (i, x) in vals.iter().enumerate() {
                    if !x.is_null() {
                        c[g(i)] += 1;
                    }
                }
            }
            (Acc::Count(c), _) => match (gids, valid) {
                (None, None) => c[0] += n as i64,
                (None, Some(valid)) => c[0] += valid.iter().filter(|&&x| x).count() as i64,
                (Some(gids), _) => {
                    for (i, &gi) in gids.iter().enumerate() {
                        if ok(i) {
                            c[gi as usize] += 1;
                        }
                    }
                }
            },
            (Acc::SumInt { sum, n: cnt }, Data::Int(vals)) => match (gids, valid) {
                (None, None) => {
                    sum[0] += vals.iter().map(|&x| x as i128).sum::<i128>();
                    cnt[0] += n as i64;
                }
                _ => {
                    for (i, &x) in vals.iter().enumerate() {
                        if ok(i) {
                            let gi = g(i);
                            sum[gi] += x as i128;
                            cnt[gi] += 1;
                        }
                    }
                }
            },
            (Acc::SumDec { sum, n: cnt, scale }, Data::Decimal(vals, s)) if *s == *scale => {
                match (gids, valid) {
                    (None, None) => {
                        sum[0] += vals.iter().map(|&x| x as i128).sum::<i128>();
                        cnt[0] += n as i64;
                    }
                    _ => {
                        for (i, &x) in vals.iter().enumerate() {
                            if ok(i) {
                                let gi = g(i);
                                sum[gi] += x as i128;
                                cnt[gi] += 1;
                            }
                        }
                    }
                }
            }
            (Acc::SumFloat { sum, n: cnt }, Data::Float(vals)) => {
                // Sequential adds keep the row-mode summation order.
                for (i, &x) in vals.iter().enumerate() {
                    if ok(i) {
                        let gi = g(i);
                        sum[gi] += x;
                        cnt[gi] += 1;
                    }
                }
            }
            (Acc::ExtremeI64 { max, best, has, .. }, data) => {
                let max = *max;
                for i in 0..n {
                    if !ok(i) {
                        continue;
                    }
                    let x = match data {
                        Data::Int(v) | Data::Timestamp(v) | Data::Decimal(v, _) => v[i],
                        Data::Date(v) => v[i] as i64,
                        _ => unreachable!(),
                    };
                    let gi = g(i);
                    if !has[gi] || (if max { x > best[gi] } else { x < best[gi] }) {
                        best[gi] = x;
                        has[gi] = true;
                    }
                }
            }
            (Acc::States(states), _) => {
                let mut retained = 0;
                for i in 0..n {
                    let x = v.value(i);
                    if !x.is_null() {
                        retained += states[g(i)].update(&x)?;
                    }
                }
                return Ok(retained);
            }
            // Representation differs from the typed accumulator: per value.
            (acc, _) => {
                for i in 0..n {
                    let x = v.value(i);
                    if !x.is_null() {
                        acc.update_value(g(i), &x)?;
                    }
                }
            }
        }
        Ok(0)
    }

    /// Adds one non-null value (same semantics as `AggState::update`).
    fn update_value(&mut self, g: usize, v: &Value) -> Result<()> {
        match self {
            Acc::CountStar(c) | Acc::Count(c) => c[g] += 1,
            Acc::SumInt { sum, n } => match v {
                Value::Int(i) => {
                    sum[g] += *i as i128;
                    n[g] += 1;
                }
                _ => return Err(Error::internal("SUM over non-integer value")),
            },
            Acc::SumDec { sum, n, scale } => {
                match v {
                    Value::Decimal(u, vs) => {
                        sum[g] += decimal::rescale(*u as i128, *vs, *scale).unwrap_or(*u as i128)
                    }
                    Value::Int(i) => sum[g] += *i as i128 * decimal::pow10(*scale as u32),
                    _ => return Err(Error::internal("SUM over non-decimal value")),
                }
                n[g] += 1;
            }
            Acc::SumFloat { sum, n } => {
                sum[g] += v.to_f64().unwrap_or(0.0);
                n[g] += 1;
            }
            Acc::ExtremeI64 { .. } | Acc::States(_) => {
                return Err(Error::internal("unexpected aggregate update"));
            }
        }
        Ok(())
    }

    /// Folds `other` (a partial accumulator of the same aggregate) into
    /// this one; `map[g]` is the group of `other`'s group `g` here.
    fn merge_from(&mut self, call: &AggregateCall, other: &mut Acc, map: &[u32]) -> Result<usize> {
        match (&mut *self, &mut *other) {
            (Acc::CountStar(a), Acc::CountStar(b)) | (Acc::Count(a), Acc::Count(b)) => {
                for (g, &t) in map.iter().enumerate() {
                    a[t as usize] += b[g];
                }
            }
            (Acc::SumInt { sum: a, n: an }, Acc::SumInt { sum: b, n: bn })
            | (Acc::SumDec { sum: a, n: an, .. }, Acc::SumDec { sum: b, n: bn, .. }) => {
                for (g, &t) in map.iter().enumerate() {
                    a[t as usize] += b[g];
                    an[t as usize] += bn[g];
                }
            }
            (Acc::SumFloat { sum: a, n: an }, Acc::SumFloat { sum: b, n: bn }) => {
                for (g, &t) in map.iter().enumerate() {
                    a[t as usize] += b[g];
                    an[t as usize] += bn[g];
                }
            }
            (
                Acc::ExtremeI64 { max, best: a, has: ah, kind: ak },
                Acc::ExtremeI64 { best: b, has: bh, kind: bk, .. },
            ) if ak.is_none() || bk.is_none() || ak == bk => {
                if ak.is_none() {
                    *ak = *bk;
                }
                for (g, &t) in map.iter().enumerate() {
                    let t = t as usize;
                    if bh[g] && (!ah[t] || (if *max { b[g] > a[t] } else { b[g] < a[t] })) {
                        a[t] = b[g];
                        ah[t] = true;
                    }
                }
            }
            _ => {
                self.to_states(call);
                other.to_states(call);
                let mut retained = 0;
                for (g, &t) in map.iter().enumerate() {
                    let theirs = other.state(call, g);
                    if let Acc::States(s) = self {
                        retained += s[t as usize].merge(theirs)?;
                    }
                }
                return Ok(retained);
            }
        }
        Ok(0)
    }

    /// The state of group `g` as a row-mode aggregate state.
    fn state(&mut self, call: &AggregateCall, g: usize) -> AggState {
        let partial = match self {
            Acc::CountStar(c) | Acc::Count(c) => Partial::Count(c[g]),
            Acc::SumInt { sum, n } => Partial::SumInt(sum[g], n[g]),
            Acc::SumDec { sum, n, .. } => Partial::SumDecimal(sum[g], n[g]),
            Acc::SumFloat { sum, n } => Partial::SumFloat(sum[g], n[g]),
            Acc::ExtremeI64 { best, has, kind, .. } => Partial::Extreme(
                has[g]
                    .then(|| kind.map(|k| k.value(best[g])))
                    .flatten(),
            ),
            Acc::States(s) => return std::mem::replace(&mut s[g], AggState::new(call)),
        };
        AggState::from_partial(call, partial)
    }
}

/// Grouped aggregation state over batches.
#[derive(Debug)]
pub struct Aggregator {
    calls: Vec<AggregateCall>,
    keys: KeyTable,
    accs: Vec<Acc>,
    gids: Vec<u32>,
    /// Groups for which accumulator slots exist.
    groups: usize,
}

impl Aggregator {
    pub fn new(key_count: usize, calls: &[AggregateCall]) -> Aggregator {
        let mut a = Aggregator {
            calls: calls.to_vec(),
            keys: KeyTable::new(key_count),
            accs: calls.iter().map(Acc::new).collect(),
            gids: Vec::new(),
            groups: 0,
        };
        if key_count == 0 {
            // A global aggregate has exactly one group, even without input.
            a.grow(1);
        }
        a
    }

    fn grow(&mut self, groups: usize) {
        if groups > self.groups {
            for (acc, call) in self.accs.iter_mut().zip(&self.calls) {
                acc.resize(groups, call);
            }
            self.groups = groups;
        }
    }

    pub fn groups(&self) -> usize {
        self.groups
    }

    /// Accumulates one batch: `keys` are the group key vectors and `args`
    /// the argument vectors (None for COUNT(*)). Returns approximate bytes
    /// newly retained.
    pub fn update(&mut self, keys: &[Vector], args: &[Option<Vector>], n: usize) -> Result<usize> {
        if n == 0 {
            return Ok(0);
        }
        let before = self.groups;
        let global = keys.is_empty();
        if !global {
            self.keys.assign(keys, n, &mut self.gids);
            self.grow(self.keys.len());
        }
        let gids = (!global).then_some(self.gids.as_slice());
        let mut retained = 0;
        for ((acc, call), arg) in self.accs.iter_mut().zip(&self.calls).zip(args) {
            retained += acc.update(call, gids, arg.as_ref(), n)?;
        }
        let per_group = 48 + 32 * (keys.len() + self.calls.len());
        Ok(retained + (self.groups - before) * per_group)
    }

    /// Folds a partial aggregator over the same keys and aggregates into
    /// this one. Returns approximate bytes newly retained.
    pub fn merge(&mut self, mut other: Aggregator) -> Result<usize> {
        let before = self.groups;
        let map: Vec<u32> = if self.keys.width() == 0 {
            vec![0; other.groups]
        } else {
            (0..other.groups as u32)
                .map(|g| self.keys.assign_values(&other.keys.key(g)))
                .collect()
        };
        self.grow(self.keys.len());
        let mut retained = 0;
        for (k, call) in self.calls.iter().enumerate() {
            retained += self.accs[k].merge_from(call, &mut other.accs[k], &map)?;
        }
        let per_group = 48 + 32 * (self.keys.width() + self.calls.len());
        Ok(retained + (self.groups - before) * per_group)
    }

    /// Output batch: group key columns followed by one column per aggregate.
    pub fn finish(mut self, ctx: &ExecContext) -> Result<Batch> {
        let groups = self.groups;
        let mut columns = self.keys.key_vectors();
        for (k, call) in self.calls.iter().enumerate() {
            let mut values = Vec::with_capacity(groups);
            for g in 0..groups {
                if g % 4096 == 4095 {
                    ctx.check_interrupt()?;
                }
                values.push(self.accs[k].state(call, g).finish()?);
            }
            columns.push(Vector::from_values(values));
        }
        Ok(Batch::new(columns, groups))
    }
}
