//! Table statistics (indexes-and-planning.md §3): row count and, per column,
//! null count, min, max and an approximate distinct count.

use std::cmp::Ordering;
use std::collections::HashSet;
use std::hash::{DefaultHasher, Hash, Hasher};

use super::column::{Column, ColumnData};
use crate::types::Value;

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
    Exact(HashSet<u64>),
    Sketch(Vec<u8>),
}

impl DistinctCounter {
    fn new() -> Self {
        DistinctCounter::Exact(HashSet::new())
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

fn hash_of(v: &Value) -> u64 {
    let mut h = DefaultHasher::new();
    v.hash(&mut h);
    h.finish()
}

fn hash_str(s: &str) -> u64 {
    let mut h = DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
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
