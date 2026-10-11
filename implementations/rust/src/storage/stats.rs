//! Table statistics (indexes-and-planning.md §3): row count and, per column,
//! null count, min, max and an approximate distinct count.

use std::cmp::Ordering;
use std::hash::{Hash, Hasher};

use super::column::{Column, ColumnData};
use crate::exec::hash::{FastHasher, FastSet};
use crate::types::{DataType, Value, float};

#[derive(Debug, Clone, PartialEq)]
pub struct ColumnStats {
    pub null_count: usize,
    /// Distinct non-null values (exact up to [`EXACT_LIMIT`], then a
    /// HyperLogLog estimate with ~1% standard error).
    pub distinct_count: usize,
    pub min: Option<Value>,
    pub max: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TableStats {
    pub row_count: usize,
    pub columns: Vec<ColumnStats>,
}

/// Distinct values counted exactly before switching to HyperLogLog.
const EXACT_LIMIT: usize = 1 << 16;
/// HyperLogLog register index bits.
const HLL_BITS: u32 = 14;

/// Distinct counter over 64-bit value hashes.
enum DistinctCounter {
    Exact(FastSet<u64>),
    Sketch(Vec<u8>),
}

impl DistinctCounter {
    fn new() -> Self {
        DistinctCounter::Exact(FastSet::default())
    }

    fn add(&mut self, hash: u64) {
        match self {
            DistinctCounter::Exact(set) => {
                set.insert(hash);
                if set.len() > EXACT_LIMIT {
                    let mut regs = vec![0u8; 1 << HLL_BITS];
                    for &h in set.iter() {
                        hll_add(&mut regs, h);
                    }
                    *self = DistinctCounter::Sketch(regs);
                }
            }
            DistinctCounter::Sketch(regs) => hll_add(regs, hash),
        }
    }

    fn count(&self) -> usize {
        match self {
            DistinctCounter::Exact(set) => set.len(),
            DistinctCounter::Sketch(regs) => hll_estimate(regs),
        }
    }
}

fn hll_add(regs: &mut [u8], hash: u64) {
    let idx = (hash >> (64 - HLL_BITS)) as usize;
    let rest = (hash << HLL_BITS) | (1 << (HLL_BITS - 1));
    let rank = rest.leading_zeros() as u8 + 1;
    if regs[idx] < rank {
        regs[idx] = rank;
    }
}

fn hll_estimate(regs: &[u8]) -> usize {
    let m = regs.len() as f64;
    let alpha = 0.7213 / (1.0 + 1.079 / m);
    let sum: f64 = regs.iter().map(|&r| 2f64.powi(-(r as i32))).sum();
    let raw = alpha * m * m / sum;
    let zeros = regs.iter().filter(|&&r| r == 0).count();
    let est = if raw <= 2.5 * m && zeros > 0 {
        m * (m / zeros as f64).ln()
    } else {
        raw
    };
    est.round() as usize
}

/// SplitMix64 finalizer: spreads every input bit over the whole word (the
/// HyperLogLog ranks use the high bits).
fn mix(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

fn hash_of(v: &Value) -> u64 {
    let mut h = FastHasher::default();
    v.hash(&mut h);
    mix(h.finish())
}

fn hash_str(s: &str) -> u64 {
    let mut h = FastHasher::default();
    s.hash(&mut h);
    mix(h.finish())
}

/// Distinct count, min and max of the non-null slots of a fixed-width
/// column read as `i64` (values of one representation compare as `i64`).
fn int_stats(col: &Column, at: impl Fn(usize) -> i64) -> (usize, Option<(i64, i64)>) {
    let mut counter = DistinctCounter::new();
    let mut range: Option<(i64, i64)> = None;
    for i in 0..col.len() {
        if col.is_null(i) {
            continue;
        }
        let x = at(i);
        counter.add(mix(x as u64));
        range = Some(match range {
            None => (x, x),
            Some((lo, hi)) => (lo.min(x), hi.max(x)),
        });
    }
    (counter.count(), range)
}

/// Computes the statistics of one column.
pub fn column_stats(col: &Column) -> ColumnStats {
    let n = col.len();
    let null_count = col.null_count();
    let mut min: Option<Value> = None;
    let mut max: Option<Value> = None;
    let mut update = |v: Value| {
        if min.as_ref().is_none_or(|m| v.sort_cmp(m) == Ordering::Less) {
            min = Some(v.clone());
        }
        if max
            .as_ref()
            .is_none_or(|m| v.sort_cmp(m) == Ordering::Greater)
        {
            max = Some(v);
        }
    };
    let distinct_count = match &col.data {
        ColumnData::Dict { codes, dict } => {
            let mut used = vec![false; dict.len()];
            for (i, &c) in codes.iter().enumerate() {
                if !col.is_null(i) {
                    used[c as usize] = true;
                }
            }
            let mut count = 0;
            for (s, _) in dict.iter().zip(&used).filter(|(_, u)| **u) {
                count += 1;
                update(Value::Str(s.clone()));
            }
            count
        }
        ColumnData::String(values) => {
            let mut counter = DistinctCounter::new();
            let mut lo: Option<&str> = None;
            let mut hi: Option<&str> = None;
            for (i, s) in values.iter().enumerate() {
                if col.is_null(i) {
                    continue;
                }
                counter.add(hash_str(s));
                if lo.is_none_or(|m| s.as_bytes() < m.as_bytes()) {
                    lo = Some(s);
                }
                if hi.is_none_or(|m| s.as_bytes() > m.as_bytes()) {
                    hi = Some(s);
                }
            }
            min = lo.map(Value::str);
            max = hi.map(Value::str);
            counter.count()
        }
        ColumnData::Int64(v) | ColumnData::Timestamp(v) | ColumnData::Decimal(v) => {
            let (count, range) = int_stats(col, |i| v[i]);
            let scale = match col.data_type {
                DataType::Decimal { scale, .. } => scale,
                _ => 0,
            };
            let make = |x: i64| match &col.data {
                ColumnData::Int64(_) => Value::Int(x),
                ColumnData::Timestamp(_) => Value::Timestamp(x),
                _ => Value::Decimal(x as i128, scale),
            };
            if let Some((lo, hi)) = range {
                min = Some(make(lo));
                max = Some(make(hi));
            }
            count
        }
        ColumnData::Date(v) => {
            let (count, range) = int_stats(col, |i| v[i] as i64);
            if let Some((lo, hi)) = range {
                min = Some(Value::Date(lo as i32));
                max = Some(Value::Date(hi as i32));
            }
            count
        }
        ColumnData::Float64(v) => {
            let mut counter = DistinctCounter::new();
            for (i, &x) in v.iter().enumerate() {
                if !col.is_null(i) {
                    counter.add(mix(float::normalize(x).to_bits()));
                    update(Value::Float(x));
                }
            }
            counter.count()
        }
        _ => {
            let mut counter = DistinctCounter::new();
            for i in 0..n {
                let v = col.value(i);
                if v.is_null() {
                    continue;
                }
                counter.add(hash_of(&v));
                update(v);
            }
            counter.count()
        }
    };
    ColumnStats {
        null_count,
        distinct_count,
        min,
        max,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::ColumnBuilder;
    use crate::types::DataType;

    #[test]
    fn basic_stats() {
        let mut b = ColumnBuilder::new(DataType::Int64);
        for v in [3, 1, 3, 7] {
            b.push(Value::Int(v));
        }
        b.push_null();
        let s = column_stats(&b.finish());
        assert_eq!(s.null_count, 1);
        assert_eq!(s.distinct_count, 3);
        assert_eq!(s.min, Some(Value::Int(1)));
        assert_eq!(s.max, Some(Value::Int(7)));
    }

    #[test]
    fn approximate_distinct_is_close() {
        let mut b = ColumnBuilder::new(DataType::Int64);
        let n = 200_000;
        for v in 0..n {
            b.push(Value::Int(v));
        }
        let s = column_stats(&b.finish());
        let err = (s.distinct_count as f64 - n as f64).abs() / n as f64;
        assert!(err < 0.05, "estimate {}", s.distinct_count);
    }

    #[test]
    fn all_null() {
        let mut b = ColumnBuilder::new(DataType::String);
        b.push_null();
        let s = column_stats(&b.finish());
        assert_eq!((s.null_count, s.distinct_count), (1, 0));
        assert_eq!(s.min, None);
    }
}
