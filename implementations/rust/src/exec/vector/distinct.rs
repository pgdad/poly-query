//! Vectorized accumulator for DISTINCT aggregates (`COUNT(DISTINCT x)`,
//! `SUM(DISTINCT x)`, …) over one value representation.
//!
//! All groups share one hash set of `(group, encoded value)` pairs, where
//! the encoding is a `u64` that is equal exactly when the values are equal:
//! the raw `i64` of INT64/DATE/TIMESTAMP/narrow DECIMAL vectors (one scale
//! per vector), the normalized bits of FLOAT64 (`-0.0` = `0.0`), 0/1 for
//! BOOLEAN and an interned id for strings (dictionary codes are mapped to
//! ids once per dictionary entry). This replaces one `HashSet<Value>` per
//! group (allocation and generic hashing per value). Inputs of another
//! representation make the caller fall back to row-mode states
//! ([`DistinctAcc::states`]).

use std::sync::Arc;

use super::batch::{Data, Vector};
use crate::error::Result;
use crate::exec::aggregate::AggState;
use crate::exec::hash::{FastMap, FastSet};
use crate::planner::expr::{AggFunc, AggregateCall};
use crate::types::{Value, float};

const NONE: u32 = u32::MAX;

/// Representation of the encoded values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Int,
    Date,
    Ts,
    Dec(u8),
    Float,
    Bool,
    Str,
}

impl Kind {
    fn of(data: &Data) -> Option<Kind> {
        Some(match data {
            Data::Int(_) => Kind::Int,
            Data::Date(_) => Kind::Date,
            Data::Timestamp(_) => Kind::Ts,
            Data::Decimal(_, s) => Kind::Dec(*s),
            Data::Float(_) => Kind::Float,
            Data::Bool(_) => Kind::Bool,
            Data::Str(_) | Data::Dict(..) => Kind::Str,
            Data::Null | Data::Values(_) => return None,
        })
    }
}

/// Interned strings (ids are indexes into `strings`).
#[derive(Debug, Default)]
struct Interner {
    ids: FastMap<Arc<str>, u32>,
    strings: Vec<Arc<str>>,
    /// Dictionary of the last dictionary-encoded input and the id of each
    /// of its codes (`NONE` if not interned yet).
    dict: Option<Arc<[Arc<str>]>>,
    codes: Vec<u32>,
}

impl Interner {
    /// Id of `s`; the second value is the number of bytes newly retained.
    fn intern(&mut self, s: &Arc<str>) -> (u32, usize) {
        if let Some(&id) = self.ids.get(s) {
            return (id, 0);
        }
        let id = self.strings.len() as u32;
        self.strings.push(s.clone());
        self.ids.insert(s.clone(), id);
        (id, s.len() + 48)
    }

    fn dict_entry(&mut self, dict: &Arc<[Arc<str>]>, code: u32) -> (u32, usize) {
        if !self.dict.as_ref().is_some_and(|d| Arc::ptr_eq(d, dict)) {
            self.dict = Some(dict.clone());
            self.codes.clear();
            self.codes.resize(dict.len(), NONE);
        }
        let c = code as usize;
        if self.codes[c] != NONE {
            return (self.codes[c], 0);
        }
        let (id, retained) = self.intern(&dict[c]);
        self.codes[c] = id;
        (id, retained)
    }
}

/// Distinct `(group, value)` pairs of one DISTINCT aggregate.
#[derive(Debug, Default)]
pub struct DistinctAcc {
    pairs: FastSet<(u32, u64)>,
    /// Representation of the values (None until the first non-NULL input).
    kind: Option<Kind>,
    strings: Interner,
}

/// Approximate bytes retained per distinct pair.
const PAIR_BYTES: usize = 24;

impl DistinctAcc {
    /// Whether values of this representation can be added.
    pub fn accepts(&self, data: &Data) -> bool {
        match (Kind::of(data), self.kind) {
            (None, _) => matches!(data, Data::Null),
            (Some(_), None) => true,
            (Some(k), Some(mine)) => k == mine,
        }
    }

    /// Adds the non-NULL values of `v` (which must be accepted) for rows
    /// mapped to groups `gids` (None: group 0). Returns retained bytes.
    pub fn update(&mut self, gids: Option<&[u32]>, v: &Vector, n: usize) -> usize {
        let Some(kind) = Kind::of(&v.data) else {
            return 0;
        };
        self.kind = Some(kind);
        let valid = v.valid.as_deref();
        let before = self.pairs.len();
        let mut retained = 0;
        let add = |pairs: &mut FastSet<(u32, u64)>, i: usize, x: u64| {
            if valid.is_none_or(|ok| ok[i]) {
                pairs.insert((gids.map_or(0, |g| g[i]), x));
            }
        };
        match &v.data {
            Data::Int(x) | Data::Timestamp(x) | Data::Decimal(x, _) => {
                for (i, &x) in x[..n].iter().enumerate() {
                    add(&mut self.pairs, i, x as u64);
                }
            }
            Data::Date(x) => {
                for (i, &x) in x[..n].iter().enumerate() {
                    add(&mut self.pairs, i, x as i64 as u64);
                }
            }
            Data::Float(x) => {
                for (i, &x) in x[..n].iter().enumerate() {
                    add(&mut self.pairs, i, float::normalize(x).to_bits());
                }
            }
            Data::Bool(x) => {
                for (i, &x) in x[..n].iter().enumerate() {
                    add(&mut self.pairs, i, x as u64);
                }
            }
            Data::Str(x) => {
                for (i, s) in x[..n].iter().enumerate() {
                    if valid.is_none_or(|ok| ok[i]) {
                        let (id, r) = self.strings.intern(s);
                        retained += r;
                        add(&mut self.pairs, i, id as u64);
                    }
                }
            }
            Data::Dict(codes, dict) => {
                for (i, &c) in codes[..n].iter().enumerate() {
                    if valid.is_none_or(|ok| ok[i]) {
                        let (id, r) = self.strings.dict_entry(dict, c);
                        retained += r;
                        add(&mut self.pairs, i, id as u64);
                    }
                }
            }
            Data::Null | Data::Values(_) => {}
        }
        retained + (self.pairs.len() - before) * PAIR_BYTES
    }

    /// Whether `other`'s pairs can be merged into this accumulator.
    pub fn can_merge(&self, other: &DistinctAcc) -> bool {
        self.kind.is_none() || other.kind.is_none() || self.kind == other.kind
    }

    /// Adds the pairs of `other`'s groups `groups[i]` as groups `map[i]`.
    /// Returns retained bytes.
    pub fn merge(&mut self, other: &DistinctAcc, groups: &[u32], map: &[u32]) -> usize {
        if self.kind.is_none() {
            self.kind = other.kind;
        }
        let Some(&last) = groups.iter().max() else {
            return 0;
        };
        let mut target = vec![NONE; last as usize + 1];
        for (&g, &t) in groups.iter().zip(map) {
            target[g as usize] = t;
        }
        let strings = self.kind == Some(Kind::Str);
        let mut remap = vec![
            NONE;
            if strings {
                other.strings.strings.len()
            } else {
                0
            }
        ];
        let before = self.pairs.len();
        let mut retained = 0;
        for &(g, x) in &other.pairs {
            let Some(&t) = target.get(g as usize).filter(|&&t| t != NONE) else {
                continue;
            };
            let x = if strings {
                let r = &mut remap[x as usize];
                if *r == NONE {
                    let (id, bytes) = self.strings.intern(&other.strings.strings[x as usize]);
                    retained += bytes;
                    *r = id;
                }
                *r as u64
            } else {
                x
            };
            self.pairs.insert((t, x));
        }
        retained + (self.pairs.len() - before) * PAIR_BYTES
    }

    fn value(&self, x: u64) -> Value {
        match self.kind {
            Some(Kind::Int) => Value::Int(x as i64),
            Some(Kind::Date) => Value::Date(x as i64 as i32),
            Some(Kind::Ts) => Value::Timestamp(x as i64),
            Some(Kind::Dec(s)) => Value::Decimal(x as i64 as i128, s),
            Some(Kind::Float) => Value::Float(f64::from_bits(x)),
            Some(Kind::Bool) => Value::Bool(x != 0),
            Some(Kind::Str) => Value::Str(self.strings.strings[x as usize].clone()),
            None => Value::Null,
        }
    }

    /// Row-mode states of groups `0..groups` holding the same distinct
    /// values (`call` is the DISTINCT aggregate).
    pub fn states(&self, call: &AggregateCall, groups: usize) -> Result<Vec<AggState>> {
        let mut states = vec![AggState::new(call); groups];
        for &(g, x) in &self.pairs {
            states[g as usize].update(&self.value(x))?;
        }
        Ok(states)
    }

    /// Final values of groups `0..groups`: the aggregate over each group's
    /// distinct values.
    pub fn finish(&self, call: &AggregateCall, groups: usize) -> Result<Vector> {
        if call.func == AggFunc::Count {
            let mut counts = vec![0i64; groups];
            for &(g, _) in &self.pairs {
                counts[g as usize] += 1;
            }
            return Ok(Vector::new(Data::Int(counts), None));
        }
        // The values are distinct already: aggregate them without a set.
        let plain = AggregateCall {
            distinct: false,
            ..call.clone()
        };
        let mut states = vec![AggState::new(&plain); groups];
        for &(g, x) in &self.pairs {
            states[g as usize].update(&self.value(x))?;
        }
        let values = states.iter().map(AggState::finish).collect::<Result<_>>()?;
        Ok(Vector::from_values(values))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planner::expr::Expr;
    use crate::types::DataType;

    fn call(func: AggFunc, ty: DataType) -> AggregateCall {
        AggregateCall {
            func,
            arg: Some(Expr::Column { index: 0, ty }),
            distinct: true,
            ty,
        }
    }

    #[test]
    fn counts_and_sums_distinct_values_per_group() {
        let v = Vector::new(
            Data::Int(vec![1, 2, 1, 3, 2, 9]),
            Some(vec![true, true, true, true, true, false]),
        );
        let gids = [0, 0, 0, 1, 1, 1];
        let mut a = DistinctAcc::default();
        assert!(a.accepts(&v.data));
        a.update(Some(&gids), &v, 6);
        let count = a.finish(&call(AggFunc::Count, DataType::Int64), 2).unwrap();
        assert_eq!(count.value(0), Value::Int(2));
        assert_eq!(count.value(1), Value::Int(2));
        let sum = a.finish(&call(AggFunc::Sum, DataType::Int64), 2).unwrap();
        assert_eq!(sum.value(0), Value::Int(3));
        assert_eq!(sum.value(1), Value::Int(5));
        assert!(!a.accepts(&Data::Float(vec![1.0])));
    }

    #[test]
    fn merges_strings_from_different_dictionaries() {
        let d1: Arc<[Arc<str>]> = vec![Arc::from("a"), Arc::from("b")].into();
        let d2: Arc<[Arc<str>]> = vec![Arc::from("b"), Arc::from("c")].into();
        let mut a = DistinctAcc::default();
        a.update(None, &Vector::new(Data::Dict(vec![0, 1, 1], d1), None), 3);
        let mut b = DistinctAcc::default();
        b.update(None, &Vector::new(Data::Dict(vec![0, 1], d2), None), 2);
        assert!(a.can_merge(&b));
        a.merge(&b, &[0], &[0]);
        let c = call(AggFunc::Count, DataType::String);
        assert_eq!(a.finish(&c, 1).unwrap().value(0), Value::Int(3));
        let states = a.states(&c, 1).unwrap();
        assert_eq!(states[0].finish().unwrap(), Value::Int(3));
    }

    #[test]
    fn negative_zero_equals_zero() {
        let mut a = DistinctAcc::default();
        a.update(
            None,
            &Vector::new(Data::Float(vec![0.0, -0.0, 1.5]), None),
            3,
        );
        let c = call(AggFunc::Count, DataType::Float64);
        assert_eq!(a.finish(&c, 1).unwrap().value(0), Value::Int(2));
    }
}
