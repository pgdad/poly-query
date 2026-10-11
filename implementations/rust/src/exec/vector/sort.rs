//! Sorting of materialized batches: computes the permutation that orders
//! the rows by the sort keys, with exactly the row engine's order (stable:
//! ties keep input order; NULL placement per key).
//!
//! * A single numeric/temporal/boolean/dictionary key is encoded as an
//!   order-preserving `u64` and sorted as `(key, row)` pairs with an LSD
//!   radix sort (8-bit digits, constant digits skipped) — stable by
//!   construction and branch-free.
//! * A single string key sorts `(8-byte big-endian prefix, row)` pairs,
//!   comparing full strings only when prefixes tie.
//! * Other key lists use a comparator over typed key columns.
//!
//! Large inputs are cut into chunks sorted on separate threads and merged.
//! Top-N uses selection (`select_nth_unstable`) with the row number as
//! final tie-breaker, i.e. the prefix of the stable order.

use std::cmp::Ordering;
use std::sync::Arc;

use super::batch::{Batch, Data, Vector};
use super::eval::eval;
use crate::error::Result;
use crate::exec::ExecContext;
use crate::exec::parallel::PARALLEL_STACK_BYTES;
use crate::planner::logical::SortKey;
use crate::types::Value;

/// Minimum rows per parallel sort chunk.
const PARALLEL_SORT_MIN: usize = 64 * 1024;

/// Comparison form of one sort key over a materialized batch.
enum SortCol {
    /// Order-preserving unsigned encoding (ascending).
    U64(Vec<u64>),
    Str(Vec<Arc<str>>),
    Values(Vec<Value>),
}

struct SortColumn {
    col: SortCol,
    nulls: Option<Vec<bool>>,
    descending: bool,
    nulls_first: bool,
}

#[inline]
fn enc_i64(x: i64) -> u64 {
    (x as u64) ^ (1 << 63)
}

#[inline]
fn enc_f64(f: f64) -> u64 {
    // -0.0 sorts equal to 0.0 (types.md §7).
    let bits = (if f == 0.0 { 0.0 } else { f }).to_bits();
    if bits >> 63 == 1 {
        !bits
    } else {
        bits | (1 << 63)
    }
}

impl SortColumn {
    fn new(v: Vector, key: &SortKey) -> SortColumn {
        let nulls = match &v.data {
            Data::Values(_) => None,
            _ => v
                .validity()
                .map(|valid| valid.into_iter().map(|ok| !ok).collect()),
        };
        let col = match v.data {
            Data::Int(x) | Data::Timestamp(x) | Data::Decimal(x, _) => {
                SortCol::U64(x.into_iter().map(enc_i64).collect())
            }
            Data::Date(x) => SortCol::U64(x.into_iter().map(|d| enc_i64(d as i64)).collect()),
            Data::Bool(x) => SortCol::U64(x.into_iter().map(u64::from).collect()),
            Data::Float(x) => SortCol::U64(x.into_iter().map(enc_f64).collect()),
            Data::Str(x) => SortCol::Str(x),
            Data::Dict(codes, dict) => {
                // Rank dictionary entries once; equal strings share a rank.
                let mut order: Vec<u32> = (0..dict.len() as u32).collect();
                order
                    .sort_by(|&a, &b| dict[a as usize].as_bytes().cmp(dict[b as usize].as_bytes()));
                let mut rank = vec![0u64; dict.len()];
                let mut r = 0;
                for (k, &e) in order.iter().enumerate() {
                    if k > 0 && dict[e as usize] != dict[order[k - 1] as usize] {
                        r += 1;
                    }
                    rank[e as usize] = r;
                }
                SortCol::U64(codes.into_iter().map(|c| rank[c as usize]).collect())
            }
            Data::Null => SortCol::U64(vec![0; v.len()]),
            Data::Values(x) => SortCol::Values(x),
        };
        SortColumn {
            col,
            nulls,
            descending: key.descending,
            nulls_first: key.nulls_first,
        }
    }

    #[inline]
    fn null_order(&self, a_null: bool, b_null: bool) -> Option<Ordering> {
        match (a_null, b_null) {
            (true, true) => Some(Ordering::Equal),
            (true, false) => Some(if self.nulls_first {
                Ordering::Less
            } else {
                Ordering::Greater
            }),
            (false, true) => Some(if self.nulls_first {
                Ordering::Greater
            } else {
                Ordering::Less
            }),
            (false, false) => None,
        }
    }

    #[inline]
    fn compare(&self, a: usize, b: usize) -> Ordering {
        if let Some(nulls) = &self.nulls
            && let Some(o) = self.null_order(nulls[a], nulls[b])
        {
            return o;
        }
        let o = match &self.col {
            SortCol::U64(v) => v[a].cmp(&v[b]),
            SortCol::Str(v) => v[a].as_bytes().cmp(v[b].as_bytes()),
            SortCol::Values(v) => {
                if let Some(o) = self.null_order(v[a].is_null(), v[b].is_null()) {
                    return o;
                }
                v[a].sort_cmp(&v[b])
            }
        };
        if self.descending { o.reverse() } else { o }
    }

    fn is_null(&self, i: usize) -> bool {
        match &self.col {
            SortCol::Values(v) => v[i].is_null(),
            _ => self.nulls.as_ref().is_some_and(|n| n[i]),
        }
    }
}

fn compare_rows(cols: &[SortColumn], a: usize, b: usize) -> Ordering {
    for c in cols {
        let o = c.compare(a, b);
        if o != Ordering::Equal {
            return o;
        }
    }
    Ordering::Equal
}

/// Compares rows of key vectors with one direction / NULL placement
/// (merge-join keys).
pub struct KeyComparator {
    cols: Vec<SortColumn>,
}

impl KeyComparator {
    pub fn new(vectors: Vec<Vector>, key: &SortKey) -> KeyComparator {
        KeyComparator {
            cols: vectors
                .into_iter()
                .map(|v| SortColumn::new(v, key))
                .collect(),
        }
    }

    pub fn compare(&self, a: usize, b: usize) -> Ordering {
        compare_rows(&self.cols, a, b)
    }
}

/// Stable LSD radix sort of `(key, row)` pairs by key.
fn radix_sort(mut items: Vec<(u64, u32)>) -> Vec<(u64, u32)> {
    let n = items.len();
    let mut hist = vec![[0usize; 256]; 8];
    for &(k, _) in &items {
        for (d, h) in hist.iter_mut().enumerate() {
            h[((k >> (8 * d)) & 0xff) as usize] += 1;
        }
    }
    let mut buf = vec![(0u64, 0u32); n];
    for (d, h) in hist.iter().enumerate() {
        if h.contains(&n) {
            continue; // every key has the same digit
        }
        let mut offs = [0usize; 256];
        let mut sum = 0;
        for (o, &c) in offs.iter_mut().zip(h.iter()) {
            *o = sum;
            sum += c;
        }
        for &it in &items {
            let b = ((it.0 >> (8 * d)) & 0xff) as usize;
            buf[offs[b]] = it;
            offs[b] += 1;
        }
        std::mem::swap(&mut items, &mut buf);
    }
    items
}

/// Merges sorted runs (each sorted by `cmp`, which must be a total order).
fn merge_runs<T: Copy>(runs: Vec<Vec<T>>, cmp: &(dyn Fn(&T, &T) -> Ordering + Sync)) -> Vec<T> {
    let mut runs = runs;
    while runs.len() > 1 {
        let mut next = Vec::with_capacity(runs.len().div_ceil(2));
        let mut it = runs.into_iter();
        while let Some(a) = it.next() {
            match it.next() {
                None => next.push(a),
                Some(b) => {
                    let mut out = Vec::with_capacity(a.len() + b.len());
                    let (mut i, mut j) = (0, 0);
                    while i < a.len() && j < b.len() {
                        if cmp(&b[j], &a[i]) == Ordering::Less {
                            out.push(b[j]);
                            j += 1;
                        } else {
                            out.push(a[i]);
                            i += 1;
                        }
                    }
                    out.extend_from_slice(&a[i..]);
                    out.extend_from_slice(&b[j..]);
                    next.push(out);
                }
            }
        }
        runs = next;
    }
    runs.pop().unwrap_or_default()
}

/// Sorts `items` with `sort` on up to `threads` threads (chunks, then merge).
fn parallel_sort<T: Copy + Send + Sync>(
    items: Vec<T>,
    threads: usize,
    sort: &(dyn Fn(Vec<T>) -> Vec<T> + Sync),
    cmp: &(dyn Fn(&T, &T) -> Ordering + Sync),
) -> Vec<T> {
    let chunks = threads.min(items.len() / PARALLEL_SORT_MIN).max(1);
    if chunks <= 1 {
        return sort(items);
    }
    let size = items.len().div_ceil(chunks);
    let parts: Vec<Vec<T>> = items.chunks(size).map(<[T]>::to_vec).collect();
    // A failure to start or a panic in a sort thread is propagated as a
    // panic; the query layer turns it into a row-mode re-execution.
    let runs: Vec<Vec<T>> = std::thread::scope(|scope| {
        let handles: Vec<_> = parts
            .into_iter()
            .map(|p| {
                std::thread::Builder::new()
                    .stack_size(PARALLEL_STACK_BYTES)
                    .spawn_scoped(scope, move || sort(p))
                    .unwrap_or_else(|e| panic!("cannot start sort thread: {e}"))
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap_or_else(|e| std::panic::resume_unwind(e)))
            .collect()
    });
    merge_runs(runs, cmp)
}

/// The permutation that sorts `b` by `keys` (stable). With `top`, only the
/// first `top` positions of the stable order.
pub fn sort_permutation(
    b: &Batch,
    keys: &[SortKey],
    top: Option<usize>,
    ctx: &ExecContext,
) -> Result<Vec<u32>> {
    let mut cols = Vec::with_capacity(keys.len());
    for k in keys {
        cols.push(SortColumn::new(eval(&k.expr, b, ctx)?, k));
    }
    let n = b.len;
    if top == Some(0) {
        return Ok(Vec::new());
    }
    let threads = if ctx.in_subquery() {
        1
    } else {
        ctx.exec.threads
    };
    let out = if let [single] = cols.as_slice()
        && !matches!(single.col, SortCol::Values(_))
    {
        sort_single(single, n, top, threads)
    } else {
        let mut idx: Vec<u32> = (0..n as u32).collect();
        let cmp = |x: &u32, y: &u32| compare_rows(&cols, *x as usize, *y as usize).then(x.cmp(y));
        match top {
            Some(t) if t < n => {
                idx.select_nth_unstable_by(t - 1, cmp);
                idx.truncate(t);
                idx.sort_unstable_by(cmp);
                idx
            }
            _ => parallel_sort(
                idx,
                threads,
                &|mut v: Vec<u32>| {
                    v.sort_unstable_by(cmp);
                    v
                },
                &cmp,
            ),
        }
    };
    ctx.check_interrupt()?;
    Ok(out)
}

/// One key: NULLs are placed as a block (stable), the rest sorted by
/// encoded key (or string prefix) and row number.
fn sort_single(col: &SortColumn, n: usize, top: Option<usize>, threads: usize) -> Vec<u32> {
    let nulls: Vec<u32> = (0..n as u32).filter(|&i| col.is_null(i as usize)).collect();
    let rows = (0..n as u32).filter(|&i| !col.is_null(i as usize));
    let mut sorted: Vec<u32> = match &col.col {
        SortCol::U64(v) => {
            let flip = if col.descending { u64::MAX } else { 0 };
            let pairs: Vec<(u64, u32)> = rows.map(|i| (v[i as usize] ^ flip, i)).collect();
            let pairs = match top {
                Some(t) if t < pairs.len() => {
                    let mut p = pairs;
                    p.select_nth_unstable(t - 1);
                    p.truncate(t);
                    p.sort_unstable();
                    p
                }
                _ if pairs.len() < 1024 => {
                    let mut p = pairs;
                    p.sort_unstable();
                    p
                }
                _ => parallel_sort(pairs, threads, &radix_sort, &|a: &(u64, u32), b| a.cmp(b)),
            };
            pairs.into_iter().map(|(_, i)| i).collect()
        }
        SortCol::Str(v) => {
            let prefix = |s: &str| {
                let mut buf = [0u8; 8];
                let b = s.as_bytes();
                let k = b.len().min(8);
                buf[..k].copy_from_slice(&b[..k]);
                u64::from_be_bytes(buf)
            };
            let pairs: Vec<(u64, u32)> = rows.map(|i| (prefix(&v[i as usize]), i)).collect();
            let desc = col.descending;
            let cmp = |a: &(u64, u32), b: &(u64, u32)| {
                let o =
                    a.0.cmp(&b.0)
                        .then_with(|| v[a.1 as usize].as_bytes().cmp(v[b.1 as usize].as_bytes()));
                (if desc { o.reverse() } else { o }).then(a.1.cmp(&b.1))
            };
            let pairs = match top {
                Some(t) if t < pairs.len() => {
                    let mut p = pairs;
                    p.select_nth_unstable_by(t - 1, cmp);
                    p.truncate(t);
                    p.sort_unstable_by(cmp);
                    p
                }
                _ => parallel_sort(
                    pairs,
                    threads,
                    &|mut p: Vec<(u64, u32)>| {
                        p.sort_unstable_by(cmp);
                        p
                    },
                    &cmp,
                ),
            };
            pairs.into_iter().map(|(_, i)| i).collect()
        }
        SortCol::Values(_) => unreachable!("generic keys use the comparator path"),
    };
    let mut out = if col.nulls_first {
        let mut out = nulls;
        out.append(&mut sorted);
        out
    } else {
        sorted.extend(nulls);
        sorted
    };
    if let Some(t) = top {
        out.truncate(t);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planner::expr::Expr;
    use crate::types::DataType;

    fn key(desc: bool, nulls_first: bool) -> SortKey {
        SortKey {
            expr: Expr::Column {
                index: 0,
                ty: DataType::Int64,
            },
            descending: desc,
            nulls_first,
        }
    }

    #[test]
    fn radix_is_stable_and_ordered() {
        let items: Vec<(u64, u32)> = (0..5000u32)
            .map(|i| (((i * 7919) % 97) as u64, i))
            .collect();
        let sorted = radix_sort(items.clone());
        let mut expect = items;
        expect.sort();
        assert_eq!(sorted, expect);
        assert!(enc_f64(-1.5) < enc_f64(-0.0) && enc_f64(-0.0) == enc_f64(0.0));
        assert!(enc_f64(0.0) < enc_f64(2.0) && enc_i64(-3) < enc_i64(2));
    }

    #[test]
    fn single_key_orders_match_comparator() {
        let values: Vec<Value> = (0..3000)
            .map(|i| {
                if i % 11 == 0 {
                    Value::Null
                } else {
                    Value::Int((i * 37) % 101 - 50)
                }
            })
            .collect();
        let b = Batch::new(vec![Vector::from_values(values.clone())], values.len());
        let ctx = ExecContext::default();
        for (desc, nf) in [(false, true), (true, false), (false, false), (true, true)] {
            let k = key(desc, nf);
            for top in [None, Some(10)] {
                let got = sort_permutation(&b, std::slice::from_ref(&k), top, &ctx).unwrap();
                let mut expect: Vec<u32> = (0..values.len() as u32).collect();
                expect.sort_by(|&x, &y| {
                    crate::exec::operators::compare_keys(
                        &values[x as usize],
                        &values[y as usize],
                        &k,
                    )
                });
                if let Some(t) = top {
                    expect.truncate(t);
                }
                assert_eq!(got, expect, "desc={desc} nulls_first={nf} top={top:?}");
            }
        }
    }
}
