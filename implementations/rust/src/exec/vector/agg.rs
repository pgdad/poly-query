//! Vectorized hash aggregation: group ids from a [`KeyTable`], then one
//! struct-of-arrays accumulator per aggregate updated by tight per-batch
//! loops (with dedicated loops for the single-group case). Partial
//! aggregators of parallel workers are merged with [`Aggregator::merge`].
//! Final values follow [`AggState::finish`] exactly (typed accumulators
//! are finished column-wise with the same arithmetic and overflow checks).

use std::sync::Arc;

use super::batch::{Batch, Data, Vector};
use super::keys::KeyTable;
use crate::error::{Error, Result};
use crate::exec::ExecContext;
use crate::exec::aggregate::{AggState, Partial};
use crate::planner::expr::{AggFunc, AggregateCall};
use crate::types::{DataType, Value, decimal};

/// Accumulator for one aggregate over all groups.
#[derive(Debug)]
enum Acc {
    CountStar(Vec<i64>),
    Count(Vec<i64>),
    SumInt {
        sum: Vec<i128>,
        n: Vec<i64>,
    },
    /// Unscaled sums at `scale` (the argument type's scale).
    SumDec {
        sum: Vec<i128>,
        n: Vec<i64>,
        scale: u8,
    },
    SumFloat {
        sum: Vec<f64>,
        n: Vec<i64>,
    },
    /// MIN/MAX over fixed-width values of one representation (`kind` is
    /// the representation of the first values seen).
    ExtremeI64 {
        max: bool,
        best: Vec<i64>,
        has: Vec<bool>,
        kind: Option<I64Kind>,
    },
    /// MIN/MAX over strings: `best[g]` indexes `strings` (`NONE` = no
    /// value yet). Strings of dictionary-encoded inputs are taken once per
    /// dictionary entry, so groups share them (no per-group reference
    /// counting).
    ExtremeStr {
        max: bool,
        best: Vec<u32>,
        strings: StrTable,
    },
    /// MIN/MAX over FLOAT64.
    ExtremeF64 {
        max: bool,
        best: Vec<f64>,
        has: Vec<bool>,
    },
    /// Any other aggregate (DISTINCT, MIN/MAX of other types): row-mode states.
    States(Vec<AggState>),
}

const NONE: u32 = u32::MAX;

/// Strings referenced by a string MIN/MAX accumulator.
#[derive(Debug, Default)]
struct StrTable {
    strings: Vec<Arc<str>>,
    /// Dictionary of the last dictionary-encoded input and the index of
    /// each of its codes in `strings` (`NONE` if not taken yet).
    dict: Option<Arc<[Arc<str>]>>,
    codes: Vec<u32>,
}

impl StrTable {
    fn push(&mut self, s: &Arc<str>) -> u32 {
        self.strings.push(s.clone());
        (self.strings.len() - 1) as u32
    }

    fn get(&self, i: u32) -> &str {
        &self.strings[i as usize]
    }

    /// Index of dictionary entry `code` of `dict`.
    fn dict_entry(&mut self, dict: &Arc<[Arc<str>]>, code: u32) -> u32 {
        if !self.dict.as_ref().is_some_and(|d| Arc::ptr_eq(d, dict)) {
            self.dict = Some(dict.clone());
            self.codes.clear();
            self.codes.resize(dict.len(), NONE);
        }
        let c = code as usize;
        if self.codes[c] == NONE {
            self.strings.push(dict[c].clone());
            self.codes[c] = (self.strings.len() - 1) as u32;
        }
        self.codes[c]
    }
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
    call.arg
        .as_ref()
        .map(|a| a.data_type())
        .unwrap_or(DataType::Null)
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
                DataType::Float64 => Acc::SumFloat {
                    sum: Vec::new(),
                    n: Vec::new(),
                },
                DataType::Decimal { scale, .. } => Acc::SumDec {
                    sum: Vec::new(),
                    n: Vec::new(),
                    scale,
                },
                _ => Acc::SumInt {
                    sum: Vec::new(),
                    n: Vec::new(),
                },
            },
            AggFunc::Min | AggFunc::Max => match arg_type(call) {
                DataType::Int64
                | DataType::Date
                | DataType::Timestamp
                | DataType::Decimal { .. } => Acc::ExtremeI64 {
                    max: call.func == AggFunc::Max,
                    best: Vec::new(),
                    has: Vec::new(),
                    kind: None,
                },
                DataType::String => Acc::ExtremeStr {
                    max: call.func == AggFunc::Max,
                    best: Vec::new(),
                    strings: StrTable::default(),
                },
                DataType::Float64 => Acc::ExtremeF64 {
                    max: call.func == AggFunc::Max,
                    best: Vec::new(),
                    has: Vec::new(),
                },
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
            Acc::ExtremeStr { best, .. } => best.resize(groups, NONE),
            Acc::ExtremeF64 { best, has, .. } => {
                best.resize(groups, 0.0);
                has.resize(groups, false);
            }
            Acc::States(s) => s.resize_with(groups, || AggState::new(call)),
        }
    }

    /// Number of group slots.
    fn len(&self) -> usize {
        match self {
            Acc::CountStar(c) | Acc::Count(c) => c.len(),
            Acc::SumInt { n, .. } | Acc::SumDec { n, .. } | Acc::SumFloat { n, .. } => n.len(),
            Acc::ExtremeI64 { has, .. } | Acc::ExtremeF64 { has, .. } => has.len(),
            Acc::ExtremeStr { best, .. } => best.len(),
            Acc::States(s) => s.len(),
        }
    }

    /// Whether the typed accumulator can take values of this representation.
    fn accepts(&mut self, data: &Data) -> bool {
        match self {
            Acc::ExtremeI64 { kind, .. } => {
                let k = I64Kind::of(data);
                if k.is_none() || (kind.is_some() && *kind != k) {
                    return false;
                }
                *kind = k;
                true
            }
            Acc::ExtremeStr { .. } => matches!(data, Data::Str(_) | Data::Dict(..)),
            Acc::ExtremeF64 { .. } => matches!(data, Data::Float(_)),
            _ => true,
        }
    }

    /// Converts a typed MIN/MAX accumulator to row-mode states (for values
    /// of another representation).
    fn switch_to_states(&mut self, call: &AggregateCall) {
        if matches!(
            self,
            Acc::ExtremeI64 { .. } | Acc::ExtremeStr { .. } | Acc::ExtremeF64 { .. }
        ) {
            let states = (0..self.len()).map(|g| self.state_of(call, g)).collect();
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
        if !self.accepts(&v.data) {
            self.switch_to_states(call);
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
            (Acc::ExtremeStr { max, best, strings }, data) => {
                let max = *max;
                let better = |strings: &StrTable, cur: u32, x: &str| {
                    cur == NONE || {
                        let o = x.as_bytes().cmp(strings.get(cur).as_bytes());
                        if max { o.is_gt() } else { o.is_lt() }
                    }
                };
                match data {
                    Data::Dict(codes, dict) => {
                        for i in 0..n {
                            if ok(i) {
                                let gi = g(i);
                                let x = &dict[codes[i] as usize];
                                if better(strings, best[gi], x) {
                                    best[gi] = strings.dict_entry(dict, codes[i]);
                                }
                            }
                        }
                    }
                    Data::Str(v) => {
                        for i in 0..n {
                            if ok(i) {
                                let gi = g(i);
                                if better(strings, best[gi], &v[i]) {
                                    best[gi] = strings.push(&v[i]);
                                }
                            }
                        }
                    }
                    _ => unreachable!(),
                }
            }
            (Acc::ExtremeF64 { max, best, has }, Data::Float(vals)) => {
                let max = *max;
                for (i, &x) in vals.iter().enumerate() {
                    if !ok(i) {
                        continue;
                    }
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
            Acc::ExtremeI64 { .. }
            | Acc::ExtremeStr { .. }
            | Acc::ExtremeF64 { .. }
            | Acc::States(_) => {
                return Err(Error::internal("unexpected aggregate update"));
            }
        }
        Ok(())
    }

    /// Folds groups of `other` (a partial accumulator of the same
    /// aggregate) into this one: `other`'s group `groups[i]` goes to group
    /// `map[i]` here.
    fn merge_from(
        &mut self,
        call: &AggregateCall,
        other: &Acc,
        groups: &[u32],
        map: &[u32],
    ) -> Result<usize> {
        let pairs = || {
            groups
                .iter()
                .map(|&g| g as usize)
                .zip(map.iter().map(|&t| t as usize))
        };
        match (&mut *self, other) {
            (Acc::CountStar(a), Acc::CountStar(b)) | (Acc::Count(a), Acc::Count(b)) => {
                for (g, t) in pairs() {
                    a[t] += b[g];
                }
            }
            (Acc::SumInt { sum: a, n: an }, Acc::SumInt { sum: b, n: bn })
            | (Acc::SumDec { sum: a, n: an, .. }, Acc::SumDec { sum: b, n: bn, .. }) => {
                for (g, t) in pairs() {
                    a[t] += b[g];
                    an[t] += bn[g];
                }
            }
            (Acc::SumFloat { sum: a, n: an }, Acc::SumFloat { sum: b, n: bn }) => {
                for (g, t) in pairs() {
                    a[t] += b[g];
                    an[t] += bn[g];
                }
            }
            (
                Acc::ExtremeI64 {
                    max,
                    best: a,
                    has: ah,
                    kind: ak,
                },
                Acc::ExtremeI64 {
                    best: b,
                    has: bh,
                    kind: bk,
                    ..
                },
            ) if ak.is_none() || bk.is_none() || ak == bk => {
                if ak.is_none() {
                    *ak = *bk;
                }
                for (g, t) in pairs() {
                    if bh[g] && (!ah[t] || (if *max { b[g] > a[t] } else { b[g] < a[t] })) {
                        a[t] = b[g];
                        ah[t] = true;
                    }
                }
            }
            (
                Acc::ExtremeStr {
                    max,
                    best: a,
                    strings: sa,
                },
                Acc::ExtremeStr {
                    best: b,
                    strings: sb,
                    ..
                },
            ) => {
                // Index here of each of `other`'s strings, taken on first use.
                let mut taken = vec![NONE; sb.strings.len()];
                for (g, t) in pairs() {
                    if b[g] == NONE {
                        continue;
                    }
                    let x = sb.get(b[g]);
                    let better = a[t] == NONE || {
                        let o = x.as_bytes().cmp(sa.get(a[t]).as_bytes());
                        if *max { o.is_gt() } else { o.is_lt() }
                    };
                    if better {
                        let k = b[g] as usize;
                        if taken[k] == NONE {
                            taken[k] = sa.push(&sb.strings[k]);
                        }
                        a[t] = taken[k];
                    }
                }
            }
            (
                Acc::ExtremeF64 {
                    max,
                    best: a,
                    has: ah,
                },
                Acc::ExtremeF64 {
                    best: b, has: bh, ..
                },
            ) => {
                for (g, t) in pairs() {
                    if bh[g] && (!ah[t] || (if *max { b[g] > a[t] } else { b[g] < a[t] })) {
                        a[t] = b[g];
                        ah[t] = true;
                    }
                }
            }
            _ => {
                self.switch_to_states(call);
                let mut retained = 0;
                for (g, t) in pairs() {
                    let theirs = other.state_of(call, g);
                    if let Acc::States(s) = self {
                        retained += s[t].merge(theirs)?;
                    }
                }
                return Ok(retained);
            }
        }
        Ok(0)
    }

    /// A copy of the state of group `g` as a row-mode aggregate state.
    fn state_of(&self, call: &AggregateCall, g: usize) -> AggState {
        match self {
            Acc::States(s) => s[g].clone(),
            Acc::CountStar(c) | Acc::Count(c) => AggState::from_partial(call, Partial::Count(c[g])),
            Acc::SumInt { sum, n } => AggState::from_partial(call, Partial::SumInt(sum[g], n[g])),
            Acc::SumDec { sum, n, .. } => {
                AggState::from_partial(call, Partial::SumDecimal(sum[g], n[g]))
            }
            Acc::SumFloat { sum, n } => {
                AggState::from_partial(call, Partial::SumFloat(sum[g], n[g]))
            }
            Acc::ExtremeI64 {
                best, has, kind, ..
            } => AggState::from_partial(
                call,
                Partial::Extreme(has[g].then(|| kind.map(|k| k.value(best[g]))).flatten()),
            ),
            Acc::ExtremeStr { best, strings, .. } => AggState::from_partial(
                call,
                Partial::Extreme(
                    (best[g] != NONE)
                        .then(|| Value::Str(strings.strings[best[g] as usize].clone())),
                ),
            ),
            Acc::ExtremeF64 { best, has, .. } => AggState::from_partial(
                call,
                Partial::Extreme(has[g].then_some(Value::Float(best[g]))),
            ),
        }
    }

    /// Final values of groups `0..groups` (same results and errors as
    /// `AggState::finish`).
    fn finish(&mut self, call: &AggregateCall, groups: usize, ctx: &ExecContext) -> Result<Vector> {
        let overflow = || Error::overflow(format!("{} result is out of range", call.func.name()));
        let avg = call.func == AggFunc::Avg;
        let valid_of = |n: &[i64]| {
            let v: Vec<bool> = n[..groups].iter().map(|&c| c > 0).collect();
            (!v.iter().all(|&x| x)).then_some(v)
        };
        Ok(match self {
            Acc::CountStar(c) | Acc::Count(c) => Vector::new(Data::Int(c[..groups].to_vec()), None),
            Acc::SumInt { sum, n } if avg => Vector::new(
                Data::Float(
                    (0..groups)
                        .map(|g| {
                            if n[g] > 0 {
                                sum[g] as f64 / n[g] as f64
                            } else {
                                0.0
                            }
                        })
                        .collect(),
                ),
                valid_of(n),
            ),
            Acc::SumInt { sum, n } => {
                let mut out = Vec::with_capacity(groups);
                for g in 0..groups {
                    out.push(if n[g] > 0 {
                        i64::try_from(sum[g]).map_err(|_| overflow())?
                    } else {
                        0
                    });
                }
                Vector::new(Data::Int(out), valid_of(n))
            }
            Acc::SumDec { sum, n, scale } if avg => {
                let div = decimal::pow10(*scale as u32) as f64;
                Vector::new(
                    Data::Float(
                        (0..groups)
                            .map(|g| {
                                if n[g] > 0 {
                                    sum[g] as f64 / div / n[g] as f64
                                } else {
                                    0.0
                                }
                            })
                            .collect(),
                    ),
                    valid_of(n),
                )
            }
            Acc::SumDec { sum, n, scale } => {
                let mut out = Vec::with_capacity(groups);
                for g in 0..groups {
                    if n[g] > 0 && !decimal::fits18(sum[g]) {
                        return Err(overflow());
                    }
                    out.push(if n[g] > 0 { sum[g] as i64 } else { 0 });
                }
                Vector::new(Data::Decimal(out, *scale), valid_of(n))
            }
            Acc::SumFloat { sum, n } => {
                let mut out = Vec::with_capacity(groups);
                for g in 0..groups {
                    let v = if n[g] == 0 {
                        0.0
                    } else if avg {
                        sum[g] / n[g] as f64
                    } else {
                        sum[g]
                    };
                    if !v.is_finite() {
                        return Err(overflow());
                    }
                    out.push(v);
                }
                Vector::new(Data::Float(out), valid_of(n))
            }
            Acc::ExtremeI64 {
                best, has, kind, ..
            } => {
                let valid: Vec<bool> = has[..groups].to_vec();
                let all = valid.iter().all(|&x| x);
                let valid = (!all).then_some(valid);
                let vals = best[..groups].to_vec();
                match kind {
                    None => Vector::null(groups),
                    Some(I64Kind::Int) => Vector::new(Data::Int(vals), valid),
                    Some(I64Kind::Ts) => Vector::new(Data::Timestamp(vals), valid),
                    Some(I64Kind::Date) => Vector::new(
                        Data::Date(vals.into_iter().map(|d| d as i32).collect()),
                        valid,
                    ),
                    Some(I64Kind::Dec(s)) => Vector::new(Data::Decimal(vals, *s), valid),
                }
            }
            Acc::ExtremeStr { best, strings, .. } => {
                // Dictionary-encoded result: codes index the taken strings.
                let valid: Vec<bool> = best[..groups].iter().map(|&b| b != NONE).collect();
                let all = valid.iter().all(|&x| x);
                let codes = best[..groups]
                    .iter()
                    .map(|&b| if b == NONE { 0 } else { b })
                    .collect();
                let dict: Arc<[Arc<str>]> = std::mem::take(&mut strings.strings).into();
                if dict.is_empty() {
                    Vector::null(groups)
                } else {
                    Vector::new(Data::Dict(codes, dict), (!all).then_some(valid))
                }
            }
            Acc::ExtremeF64 { best, has, .. } => {
                let valid: Vec<bool> = has[..groups].to_vec();
                let all = valid.iter().all(|&x| x);
                Vector::new(
                    Data::Float(best[..groups].to_vec()),
                    (!all).then_some(valid),
                )
            }
            Acc::States(states) => {
                let mut values = Vec::with_capacity(groups);
                for (g, s) in states[..groups].iter().enumerate() {
                    if g % 4096 == 4095 {
                        ctx.check_interrupt()?;
                    }
                    values.push(s.finish()?);
                }
                Vector::from_values(values)
            }
        })
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
    pub fn merge(&mut self, other: Aggregator) -> Result<usize> {
        let groups: Vec<u32> = (0..other.groups as u32).collect();
        self.merge_groups(&other, &groups)
    }

    /// Folds the groups `groups` of the partial aggregator `other` into
    /// this one. Returns approximate bytes newly retained.
    pub fn merge_groups(&mut self, other: &Aggregator, groups: &[u32]) -> Result<usize> {
        let before = self.groups;
        let map: Vec<u32> = if self.keys.width() == 0 {
            vec![0; groups.len()]
        } else {
            groups
                .iter()
                .map(|&g| self.keys.assign_from(&other.keys, g))
                .collect()
        };
        self.grow(self.keys.len());
        let mut retained = 0;
        for (k, call) in self.calls.iter().enumerate() {
            retained += self.accs[k].merge_from(call, &other.accs[k], groups, &map)?;
        }
        let per_group = 48 + 32 * (self.keys.width() + self.calls.len());
        Ok(retained + (self.groups - before) * per_group)
    }

    /// Splits the groups into `parts` partitions by a hash of their key
    /// (equal keys of different partial aggregators land in the same
    /// partition, so partitions can be merged independently).
    pub fn partition_groups(&self, parts: usize) -> Vec<Vec<u32>> {
        let mut out = vec![Vec::new(); parts];
        for g in 0..self.groups as u32 {
            out[(self.keys.hash_key(g) % parts as u64) as usize].push(g);
        }
        out
    }

    pub fn key_count(&self) -> usize {
        self.keys.width()
    }

    pub fn calls(&self) -> &[AggregateCall] {
        &self.calls
    }

    /// Output batch: group key columns followed by one column per aggregate.
    pub fn finish(mut self, ctx: &ExecContext) -> Result<Batch> {
        let groups = self.groups;
        let mut columns = self.keys.key_vectors();
        for (acc, call) in self.accs.iter_mut().zip(&self.calls) {
            columns.push(acc.finish(call, groups, ctx)?);
        }
        Ok(Batch::new(columns, groups))
    }
}
