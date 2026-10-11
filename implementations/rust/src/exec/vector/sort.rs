//! Sorting of materialized batches: computes the permutation that orders
//! the rows by the sort keys, with exactly the row engine's order (stable:
//! ties keep input order; NULL placement per key).
//!
//! * Full sorts **normalize** the keys: every key becomes an unsigned code
//!   per row whose natural order is the requested order (direction and NULL
//!   placement folded in; numbers by an order-preserving bit encoding,
//!   strings and dictionary codes by their dense rank), with the minimal
//!   bit width. The codes of all keys are packed into one `u64` or `u128`
//!   per row, and `(packed key, row)` pairs are sorted: an MSD partition on
//!   the top varying bits on several threads, then the partitions in
//!   parallel (LSD radix sort or `sort_unstable`). Ties are broken by the
//!   row number, which gives the stable order.
//! * Keys needing more than 128 bits use a comparator over the codes;
//!   generic (`Values`) key vectors a comparator over the values. Large
//!   comparator-sorted inputs are cut into chunks sorted on separate
//!   threads and merged.
//! * Top-N uses selection (`select_nth_unstable`) with the row number as
//!   final tie-breaker, i.e. the prefix of the stable order.

use std::borrow::Cow;
use std::cmp::Ordering;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering::Relaxed;

use super::batch::{Batch, Data, Vector};
use super::eval::eval_cow;
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
    let mut vectors = Vec::with_capacity(keys.len());
    for k in keys {
        vectors.push(eval_cow(&k.expr, b, ctx)?);
    }
    let n = b.len;
    if top == Some(0) {
        return Ok(Vec::new());
    }
    let threads = if ctx.serial_only() {
        1
    } else {
        ctx.execution.threads
    };
    let generic = vectors.iter().any(|v| matches!(v.data, Data::Values(_)));
    let out = match top {
        Some(t) if t < n => {
            let cols = sort_columns(vectors, keys);
            top_permutation(&cols, n, t)
        }
        _ if generic => {
            let cols = sort_columns(vectors, keys);
            let cmp =
                |x: &u32, y: &u32| compare_rows(&cols, *x as usize, *y as usize).then(x.cmp(y));
            comparator_sort(n, threads, &cmp)
        }
        _ => {
            let codes: Vec<KeyCodes> = vectors
                .iter()
                .zip(keys)
                .flat_map(|(v, k)| key_codes(v, k, threads))
                .filter(|c| c.bits > 0)
                .collect();
            normalized_sort(&codes, n, threads)
        }
    };
    ctx.check_interrupt()?;
    Ok(out)
}

fn sort_columns(vectors: Vec<Cow<Vector>>, keys: &[SortKey]) -> Vec<SortColumn> {
    vectors
        .into_iter()
        .zip(keys)
        .map(|(v, k)| SortColumn::new(v.into_owned(), k))
        .collect()
}
/// Sorts the row numbers `0..n` by `cmp` (a total order) on up to `threads`
/// threads.
fn comparator_sort(
    n: usize,
    threads: usize,
    cmp: &(dyn Fn(&u32, &u32) -> Ordering + Sync),
) -> Vec<u32> {
    parallel_sort(
        (0..n as u32).collect(),
        threads,
        &|mut v: Vec<u32>| {
            v.sort_unstable_by(cmp);
            v
        },
        cmp,
    )
}

/// The first `t` (< `n`) positions of the stable order.
fn top_permutation(cols: &[SortColumn], n: usize, t: usize) -> Vec<u32> {
    if let [single] = cols
        && !matches!(single.col, SortCol::Values(_))
    {
        return top_single(single, n, t);
    }
    let mut idx: Vec<u32> = (0..n as u32).collect();
    let cmp = |x: &u32, y: &u32| compare_rows(cols, *x as usize, *y as usize).then(x.cmp(y));
    idx.select_nth_unstable_by(t - 1, cmp);
    idx.truncate(t);
    idx.sort_unstable_by(cmp);
    idx
}

/// Top-N by one key: NULLs are placed as a block (stable), the rest
/// selected by encoded key (or string prefix) and row number.
fn top_single(col: &SortColumn, n: usize, t: usize) -> Vec<u32> {
    let nulls: Vec<u32> = (0..n as u32).filter(|&i| col.is_null(i as usize)).collect();
    if col.nulls_first && nulls.len() >= t {
        return nulls[..t].to_vec();
    }
    let rows = (0..n as u32).filter(|&i| !col.is_null(i as usize));
    let mut sorted: Vec<u32> = match &col.col {
        SortCol::U64(v) => {
            let flip = if col.descending { u64::MAX } else { 0 };
            let mut p: Vec<(u64, u32)> = rows.map(|i| (v[i as usize] ^ flip, i)).collect();
            if t < p.len() {
                p.select_nth_unstable(t - 1);
                p.truncate(t);
            }
            p.sort_unstable();
            p.into_iter().map(|(_, i)| i).collect()
        }
        SortCol::Str(v) => {
            let desc = col.descending;
            let cmp = |a: &(u64, u32), b: &(u64, u32)| {
                let o =
                    a.0.cmp(&b.0)
                        .then_with(|| v[a.1 as usize].as_bytes().cmp(v[b.1 as usize].as_bytes()));
                (if desc { o.reverse() } else { o }).then(a.1.cmp(&b.1))
            };
            let mut p: Vec<(u64, u32)> = rows.map(|i| (str_prefix(&v[i as usize]), i)).collect();
            if t < p.len() {
                p.select_nth_unstable_by(t - 1, cmp);
                p.truncate(t);
            }
            p.sort_unstable_by(cmp);
            p.into_iter().map(|(_, i)| i).collect()
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
    out.truncate(t);
    out
}

/// The first 8 bytes of a string as a big-endian integer (zero padded):
/// ordering prefixes orders strings up to ties.
#[inline]
fn str_prefix(s: &str) -> u64 {
    let mut buf = [0u8; 8];
    let b = s.as_bytes();
    let k = b.len().min(8);
    buf[..k].copy_from_slice(&b[..k]);
    u64::from_be_bytes(buf)
}

// ---------------------------------------------------------------------------
// Normalized keys

/// One component of a normalized sort key: a code per row whose ascending
/// order is the requested order, using `bits` bits (0: constant, ignored).
struct KeyCodes {
    codes: Vec<u64>,
    bits: u32,
}

/// The normalized components of one sort key over a typed vector: a NULL
/// flag (if there are NULLs) followed by the value code.
fn key_codes(v: &Vector, key: &SortKey, threads: usize) -> Vec<KeyCodes> {
    let n = v.len();
    let valid: Option<&[bool]> = v.valid.as_deref();
    let mut enc: Vec<u64> = match &v.data {
        Data::Int(x) | Data::Timestamp(x) | Data::Decimal(x, _) => {
            x.iter().map(|&x| enc_i64(x)).collect()
        }
        Data::Date(x) => x.iter().map(|&d| enc_i64(d as i64)).collect(),
        Data::Bool(x) => x.iter().map(|&b| u64::from(b)).collect(),
        Data::Float(x) => x.iter().map(|&f| enc_f64(f)).collect(),
        Data::Str(x) => string_ranks(x, threads),
        Data::Dict(codes, dict) => {
            let rank = if dict.len() > 4096 {
                string_ranks(dict, threads)
            } else {
                dict_ranks(dict)
            };
            codes.iter().map(|&c| rank[c as usize]).collect()
        }
        Data::Null => return Vec::new(),
        Data::Values(_) => unreachable!("generic keys use the comparator path"),
    };
    let mut out = Vec::with_capacity(2);
    let null_count = valid.map_or(0, |v| v.iter().filter(|&&ok| !ok).count());
    if null_count == n {
        return out;
    }
    if let Some(valid) = valid
        && null_count > 0
    {
        // NULLs first: NULL rows get flag 0; NULLs last: flag 1.
        let codes = valid
            .iter()
            .map(|&ok| u64::from(ok == key.nulls_first))
            .collect();
        out.push(KeyCodes { codes, bits: 1 });
        // NULL rows take the first non-NULL value: no effect on min/max.
        let first = enc[valid.iter().position(|&ok| ok).unwrap_or(0)];
        for (e, &ok) in enc.iter_mut().zip(valid) {
            if !ok {
                *e = first;
            }
        }
    }
    let (lo, hi) = enc
        .iter()
        .fold((u64::MAX, 0u64), |(lo, hi), &e| (lo.min(e), hi.max(e)));
    let bits = 64 - (hi - lo).leading_zeros();
    if bits > 0 {
        if key.descending {
            enc.iter_mut().for_each(|e| *e = hi - *e);
        } else {
            enc.iter_mut().for_each(|e| *e -= lo);
        }
        out.push(KeyCodes { codes: enc, bits });
    }
    out
}

/// Dense ranks of dictionary entries in byte order (equal strings share a
/// rank).
fn dict_ranks(dict: &[Arc<str>]) -> Vec<u64> {
    let mut order: Vec<u32> = (0..dict.len() as u32).collect();
    order.sort_by(|&a, &b| dict[a as usize].as_bytes().cmp(dict[b as usize].as_bytes()));
    let mut rank = vec![0u64; dict.len()];
    let mut r = 0;
    for (k, &e) in order.iter().enumerate() {
        if k > 0 && dict[e as usize] != dict[order[k - 1] as usize] {
            r += 1;
        }
        rank[e as usize] = r;
    }
    rank
}

/// Order-preserving codes of strings (equal strings share a code): the
/// position of the string's first occurrence in byte order. `(prefix, row)`
/// pairs are sorted, then runs of equal prefixes are ordered by the full
/// strings; both steps run on up to `threads` threads.
fn string_ranks(v: &[Arc<str>], threads: usize) -> Vec<u64> {
    let n = v.len();
    let threads = if n < 2 * PARALLEL_SORT_MIN {
        1
    } else {
        threads.min(n / PARALLEL_SORT_MIN).max(1)
    };
    let size = n.div_ceil(threads).max(1);
    let (pairs, diff) = pairs_by(n, threads, |i| str_prefix(&v[i]));
    let mut pairs = sort_pairs(pairs, diff, threads);
    // Segments of the sorted pairs, cut where prefixes change.
    let mut segments = Vec::with_capacity(threads);
    let mut rest: &mut [(u64, u32)] = &mut pairs;
    let mut start = 0;
    while !rest.is_empty() {
        let mut cut = size.min(rest.len());
        while cut < rest.len() && rest[cut].0 == rest[cut - 1].0 {
            cut += 1;
        }
        let (seg, tail) = rest.split_at_mut(cut);
        segments.push((start, seg));
        start += cut;
        rest = tail;
    }
    let ranks: Vec<AtomicU64> = (0..n).map(|_| AtomicU64::new(0)).collect();
    let ranks_ref = &ranks;
    run_threads(
        segments
            .into_iter()
            .map(|(base, seg)| move || rank_segment(v, base, seg, ranks_ref))
            .collect(),
    );
    ranks.into_iter().map(AtomicU64::into_inner).collect()
}

/// Assigns the codes of one segment of sorted `(prefix, row)` pairs
/// starting at position `base`.
fn rank_segment(v: &[Arc<str>], base: usize, seg: &mut [(u64, u32)], ranks: &[AtomicU64]) {
    let set = |row: u32, code: usize| ranks[row as usize].store(code as u64, Relaxed);
    let mut i = 0;
    while i < seg.len() {
        let prefix = seg[i].0;
        let mut end = i + 1;
        while end < seg.len() && seg[end].0 == prefix {
            end += 1;
        }
        if end == i + 1 {
            set(seg[i].1, base + i);
            i = end;
            continue;
        }
        let run = &mut seg[i..end];
        // Equal prefixes and equal lengths of at most 8 bytes mean equal
        // strings; otherwise order the run by the full strings.
        let len0 = v[run[0].1 as usize].len();
        if len0 <= 8 && run.iter().all(|p| v[p.1 as usize].len() == len0) {
            for p in run.iter() {
                set(p.1, base + i);
            }
        } else {
            run.sort_unstable_by(|a, b| {
                v[a.1 as usize]
                    .as_bytes()
                    .cmp(v[b.1 as usize].as_bytes())
                    .then(a.1.cmp(&b.1))
            });
            let mut first = 0;
            for k in 0..run.len() {
                if k > 0 && v[run[k].1 as usize] != v[run[k - 1].1 as usize] {
                    first = k;
                }
                set(run[k].1, base + i + first);
            }
        }
        i = end;
    }
}

/// An unsigned integer holding the concatenated codes of a row's keys.
trait PackedKey: Copy + Ord + Send + Sync + Default {
    const BITS: u32;
    /// `self` shifted left by `bits` with `code` in the low bits.
    fn push(self, bits: u32, code: u64) -> Self;
    /// The 8-bit digit starting at bit `shift`.
    fn digit(self, shift: u32) -> usize;
    fn xor(self, other: Self) -> Self;
    fn or(self, other: Self) -> Self;
    fn leading_zeros(self) -> u32;
}

impl PackedKey for u64 {
    const BITS: u32 = 64;
    #[inline]
    fn push(self, bits: u32, code: u64) -> u64 {
        self.checked_shl(bits).unwrap_or(0) | code
    }
    #[inline]
    fn digit(self, shift: u32) -> usize {
        ((self >> shift) & 0xff) as usize
    }
    fn xor(self, other: u64) -> u64 {
        self ^ other
    }
    fn or(self, other: u64) -> u64 {
        self | other
    }
    fn leading_zeros(self) -> u32 {
        u64::leading_zeros(self)
    }
}

impl PackedKey for u128 {
    const BITS: u32 = 128;
    #[inline]
    fn push(self, bits: u32, code: u64) -> u128 {
        self.checked_shl(bits).unwrap_or(0) | code as u128
    }
    #[inline]
    fn digit(self, shift: u32) -> usize {
        ((self >> shift) & 0xff) as usize
    }
    fn xor(self, other: u128) -> u128 {
        self ^ other
    }
    fn or(self, other: u128) -> u128 {
        self | other
    }
    fn leading_zeros(self) -> u32 {
        u128::leading_zeros(self)
    }
}

/// Sorts rows `0..n` by the concatenated codes (first component most
/// significant), ties by row number.
fn normalized_sort(codes: &[KeyCodes], n: usize, threads: usize) -> Vec<u32> {
    let bits: u32 = codes.iter().map(|c| c.bits).sum();
    if bits == 0 {
        (0..n as u32).collect()
    } else if bits <= 64 {
        let (pairs, diff) = pairs_by(n, threads, |i| pack::<u64>(codes, i));
        sorted_rows(sort_pairs(pairs, diff, threads))
    } else if bits <= 128 {
        let (pairs, diff) = pairs_by(n, threads, |i| pack::<u128>(codes, i));
        sorted_rows(sort_pairs(pairs, diff, threads))
    } else {
        let cmp = |x: &u32, y: &u32| {
            let (a, b) = (*x as usize, *y as usize);
            codes
                .iter()
                .map(|c| c.codes[a].cmp(&c.codes[b]))
                .find(|o| o.is_ne())
                .unwrap_or(Ordering::Equal)
                .then(x.cmp(y))
        };
        comparator_sort(n, threads, &cmp)
    }
}

/// The packed key of row `i`.
#[inline]
fn pack<K: PackedKey>(codes: &[KeyCodes], i: usize) -> K {
    codes
        .iter()
        .fold(K::default(), |k, c| k.push(c.bits, c.codes[i]))
}

/// The pairs `(key(i), i)` for rows `0..n`, computed on up to `threads`
/// threads, and the bits in which the keys differ (OR of `key ^ key(0)`).
fn pairs_by<K: PackedKey>(
    n: usize,
    threads: usize,
    key: impl Fn(usize) -> K + Sync,
) -> (Vec<(K, u32)>, K) {
    let mut pairs = vec![(K::default(), 0u32); n];
    if n == 0 {
        return (pairs, K::default());
    }
    let first = key(0);
    let threads = threads.min(n / PARALLEL_SORT_MIN).max(1);
    let size = n.div_ceil(threads);
    let key = &key;
    let diffs = run_threads(
        pairs
            .chunks_mut(size)
            .enumerate()
            .map(|(c, chunk)| {
                move || {
                    let mut diff = K::default();
                    for (j, p) in chunk.iter_mut().enumerate() {
                        let i = c * size + j;
                        let k = key(i);
                        diff = diff.or(k.xor(first));
                        *p = (k, i as u32);
                    }
                    diff
                }
            })
            .collect(),
    );
    let diff = diffs.into_iter().fold(K::default(), K::or);
    (pairs, diff)
}

fn sorted_rows<K>(pairs: Vec<(K, u32)>) -> Vec<u32> {
    pairs.into_iter().map(|(_, i)| i).collect()
}

/// A chunk of pairs partitioned by digit, with the 257 partition offsets.
type Partitioned<K> = (Vec<(K, u32)>, Vec<usize>);

/// A digit and the output slice of its partition.
type Partition<'a, K> = (usize, &'a mut [(K, u32)]);

/// Sorts `(key, row)` pairs (rows unique, pairs in ascending row order) by
/// key and row; `diff` has the bits in which keys differ. Large inputs are
/// partitioned by their top varying bits and the partitions sorted in
/// parallel.
fn sort_pairs<K: PackedKey>(pairs: Vec<(K, u32)>, diff: K, threads: usize) -> Vec<(K, u32)> {
    let n = pairs.len();
    if threads <= 1 || n < 2 * PARALLEL_SORT_MIN {
        return sort_partition(pairs);
    }
    if diff == K::default() {
        return pairs; // one key: row order
    }
    let top = K::BITS - 1 - diff.leading_zeros();
    let shift = top.saturating_sub(7);
    let threads = threads.min(n / PARALLEL_SORT_MIN).max(1);
    let size = n.div_ceil(threads);
    // Phase 1: every thread partitions its chunk by digit (stable).
    let locals: Vec<Partitioned<K>> = run_threads(
        pairs
            .chunks(size)
            .map(|chunk| {
                move || {
                    let mut hist = vec![0usize; 257];
                    for p in chunk {
                        hist[p.0.digit(shift) + 1] += 1;
                    }
                    for d in 1..257 {
                        hist[d] += hist[d - 1];
                    }
                    let starts = hist.clone();
                    let mut out = vec![(K::default(), 0u32); chunk.len()];
                    for &p in chunk {
                        let d = p.0.digit(shift);
                        out[hist[d]] = p;
                        hist[d] += 1;
                    }
                    (out, starts)
                }
            })
            .collect(),
    );
    drop(pairs);
    // Phase 2: partition `d` is the concatenation of every chunk's part
    // `d`; partitions are assigned to threads (largest first, to the least
    // loaded thread) and sorted there.
    let sizes: Vec<usize> = (0..256)
        .map(|d| locals.iter().map(|(_, s)| s[d + 1] - s[d]).sum())
        .collect();
    let mut out = vec![(K::default(), 0u32); n];
    let mut parts: Vec<Partition<K>> = Vec::with_capacity(256);
    let mut rest: &mut [(K, u32)] = &mut out;
    for (d, &len) in sizes.iter().enumerate() {
        let (part, tail) = rest.split_at_mut(len);
        rest = tail;
        if len > 0 {
            parts.push((d, part));
        }
    }
    parts.sort_by_key(|(_, p)| std::cmp::Reverse(p.len()));
    let mut work: Vec<(usize, Vec<Partition<K>>)> = (0..threads).map(|_| (0, Vec::new())).collect();
    for part in parts {
        let w = work
            .iter_mut()
            .min_by_key(|(load, _)| *load)
            .expect("at least one thread");
        w.0 += part.1.len();
        w.1.push(part);
    }
    let locals = &locals;
    run_threads(
        work.into_iter()
            .map(|(_, parts)| {
                move || {
                    for (d, part) in parts {
                        let mut pos = 0;
                        for (local, starts) in locals {
                            let seg = &local[starts[d]..starts[d + 1]];
                            part[pos..pos + seg.len()].copy_from_slice(seg);
                            pos += seg.len();
                        }
                        let sorted = sort_partition(part.to_vec());
                        part.copy_from_slice(&sorted);
                    }
                }
            })
            .collect(),
    );
    out
}

/// Runs the closures on scoped threads and returns their results in order.
/// A failure to start or a panic in a thread is propagated as a panic; the
/// query layer turns it into a row-mode re-execution.
fn run_threads<R: Send, F: FnOnce() -> R + Send>(mut jobs: Vec<F>) -> Vec<R> {
    if jobs.len() == 1 {
        return jobs.pop().map(|job| job()).into_iter().collect();
    }
    std::thread::scope(|scope| {
        let handles: Vec<_> = jobs
            .into_iter()
            .map(|job| {
                std::thread::Builder::new()
                    .stack_size(PARALLEL_STACK_BYTES)
                    .spawn_scoped(scope, job)
                    .unwrap_or_else(|e| panic!("cannot start sort thread: {e}"))
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap_or_else(|e| std::panic::resume_unwind(e)))
            .collect()
    })
}

/// Sorts `(key, row)` pairs that are in ascending row order by key and row
/// on the current thread.
fn sort_partition<K: PackedKey>(mut pairs: Vec<(K, u32)>) -> Vec<(K, u32)> {
    if pairs.len() < 4096 {
        pairs.sort_unstable();
        pairs
    } else {
        radix_sort(pairs)
    }
}

/// Stable LSD radix sort of `(key, row)` pairs by key (8-bit digits,
/// digits that are equal in every key are skipped).
fn radix_sort<K: PackedKey>(mut items: Vec<(K, u32)>) -> Vec<(K, u32)> {
    let n = items.len();
    let digits = (K::BITS / 8) as usize;
    let mut hist = vec![[0usize; 256]; digits];
    for &(k, _) in &items {
        for (d, h) in hist.iter_mut().enumerate() {
            h[k.digit(8 * d as u32)] += 1;
        }
    }
    let mut buf = vec![(K::default(), 0u32); n];
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
            let b = it.0.digit(8 * d as u32);
            buf[offs[b]] = it;
            offs[b] += 1;
        }
        std::mem::swap(&mut items, &mut buf);
    }
    items
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

    /// Deterministic pseudo-random values (xorshift).
    fn rand_seq(seed: u64) -> impl FnMut() -> u64 {
        let mut x = seed;
        move || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        }
    }

    fn column(ty: DataType, index: usize, desc: bool, nulls_first: bool) -> SortKey {
        SortKey {
            expr: Expr::Column { index, ty },
            descending: desc,
            nulls_first,
        }
    }

    /// Full sorts (normalized keys, serial and parallel) and top-N agree
    /// with the row engine's comparator, for strings with shared prefixes
    /// and NUL bytes, floats with -0.0, and NULLs.
    #[test]
    fn normalized_sort_matches_comparator() {
        let mut rnd = rand_seq(0x9e37_79b9_7f4a_7c15);
        let n = 140_000;
        let words = [
            "",
            "a",
            "a\0",
            "ab",
            "abcdefgh",
            "abcdefghi",
            "abcdefgh\0",
            "b",
            "zz",
        ];
        let mut strs = Vec::new();
        let mut ints = Vec::new();
        let mut floats = Vec::new();
        for _ in 0..n {
            let r = rnd();
            strs.push(match r % 13 {
                0 => Value::Null,
                k if k < 9 => Value::str(words[k as usize]),
                _ => Value::str(&format!("abcdefgh{}", r % 1000)),
            });
            ints.push(if r.is_multiple_of(17) {
                Value::Null
            } else {
                Value::Int((r >> 8) as i64 % 50 - 25)
            });
            floats.push(Value::Float(match (r >> 20) % 5 {
                0 => -0.0,
                1 => 0.0,
                2 => f64::MIN,
                _ => ((r >> 24) % 1000) as f64 / 7.0 - 70.0,
            }));
        }
        let cols = [strs, ints, floats];
        let b = Batch::new(
            cols.iter()
                .map(|c| Vector::from_values(c.clone()))
                .collect(),
            n,
        );
        let types = [DataType::String, DataType::Int64, DataType::Float64];
        let mut ctx = ExecContext::default();
        for (round, order) in [[0usize, 1, 2], [1, 0, 2], [2, 0, 1], [1, 2, 0]]
            .iter()
            .enumerate()
        {
            let keys: Vec<SortKey> = order
                .iter()
                .enumerate()
                .map(|(j, &c)| column(types[c], c, (round + j) % 2 == 1, (round + j) % 3 == 0))
                .collect();
            let mut expect: Vec<u32> = (0..n as u32).collect();
            expect.sort_by(|&x, &y| {
                keys.iter()
                    .zip(order)
                    .map(|(k, &c)| {
                        crate::exec::operators::compare_keys(
                            &cols[c][x as usize],
                            &cols[c][y as usize],
                            k,
                        )
                    })
                    .find(|o| o.is_ne())
                    .unwrap_or(Ordering::Equal)
            });
            for threads in [1, 8] {
                ctx.execution.threads = threads;
                for top in [None, Some(1000)] {
                    let got = sort_permutation(&b, &keys, top, &ctx).unwrap();
                    let want = &expect[..top.unwrap_or(n)];
                    assert!(got == want, "round {round} threads {threads} top {top:?}");
                }
            }
        }
    }

    #[test]
    fn string_ranks_are_ordered() {
        let v: Vec<Arc<str>> = ["b", "a\0", "a", "abcdefghij", "abcdefghi", "a", ""]
            .iter()
            .map(|s| Arc::from(*s))
            .collect();
        assert_eq!(string_ranks(&v, 1), vec![6, 3, 1, 5, 4, 1, 0]);
    }
}
