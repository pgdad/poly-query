//! Sorting of materialized batches: computes the permutation that orders
//! the rows by the sort keys, with exactly the row engine's order (stable:
//! ties keep input order; NULL placement per key).
//!
//! * Full sorts **normalize** the keys: every key becomes an unsigned code
//!   per row whose natural order is the requested order (direction and NULL
//!   placement folded in; numbers by an order-preserving bit encoding,
//!   dictionary codes by their dense rank, the first string key by the 8
//!   bytes after the prefix all its strings share, later string keys by
//!   their rank), with the minimal bit width. The top 64 bits of each
//!   row's concatenated codes and the row number are sorted as
//!   `(u64, u32)` pairs: an MSD partition on the top varying bits on
//!   several threads, then the partitions in parallel (LSD radix sort or
//!   `sort_unstable`). Ties are broken by the row number, which gives the
//!   stable order. Where that key is inexact (string prefixes, codes
//!   longer than 64 bits), runs of equal keys are then ordered by comparing
//!   the full codes and strings.
//! * Generic (`Values`) key vectors use a comparator over the values;
//!   large inputs are cut into chunks sorted on separate threads and
//!   merged.
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
use crate::exec::pool;
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
    // A panic in a sort job is propagated; the query layer turns it into
    // a row-mode re-execution.
    let runs: Vec<Vec<T>> = pool::scoped(parts.into_iter().map(|p| move || sort(p)).collect());
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
            // The first string key is coded by prefix (with ties), later
            // ones by rank.
            let mut codes: Vec<KeyCodes> = Vec::new();
            for (v, k) in vectors.iter().zip(keys) {
                let allow_ties = codes.iter().all(|c| c.ties.is_none());
                codes.extend(
                    key_codes(v, k, threads, allow_ties)
                        .into_iter()
                        .filter(|c| c.bits > 0 || c.ties.is_some()),
                );
            }
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
            let mut p: Vec<(u64, u32)> = rows
                .map(|i| (str_prefix(v[i as usize].as_bytes()), i))
                .collect();
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
fn str_prefix(b: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    let k = b.len().min(8);
    buf[..k].copy_from_slice(&b[..k]);
    u64::from_be_bytes(buf)
}

// ---------------------------------------------------------------------------
// Normalized keys

/// One component of a normalized sort key: a code per row whose ascending
/// order is the requested order, using `bits` bits (0: constant, ignored
/// unless it has `ties`).
struct KeyCodes<'a> {
    codes: Vec<u64>,
    bits: u32,
    /// Set for string prefix codes: rows with equal codes may still differ
    /// and are ordered by these strings.
    ties: Option<Ties<'a>>,
}

impl KeyCodes<'_> {
    fn exact(codes: Vec<u64>, bits: u32) -> Self {
        KeyCodes {
            codes,
            bits,
            ties: None,
        }
    }
}

/// The strings of a key coded by prefix.
struct Ties<'a> {
    strings: Strings<'a>,
    valid: Option<&'a [bool]>,
    descending: bool,
}

/// Plain or dictionary-encoded strings of a vector.
#[derive(Clone, Copy)]
enum Strings<'a> {
    Plain(&'a [Arc<str>]),
    Dict(&'a [u32], &'a [Arc<str>]),
}

impl<'a> Strings<'a> {
    #[inline]
    fn get(self, row: usize) -> &'a [u8] {
        match self {
            Strings::Plain(v) => v[row].as_bytes(),
            Strings::Dict(codes, dict) => dict[codes[row] as usize].as_bytes(),
        }
    }
}

impl Ties<'_> {
    /// Compares rows `a` and `b` whose codes are equal.
    fn compare(&self, a: usize, b: usize) -> Ordering {
        if self.valid.is_some_and(|v| !v[a]) {
            return Ordering::Equal;
        }
        let o = self.strings.get(a).cmp(self.strings.get(b));
        if self.descending { o.reverse() } else { o }
    }
}

/// The normalized components of one sort key over a typed vector: a NULL
/// flag (if there are NULLs) followed by the value code. Strings (plain or
/// with a large dictionary) are coded by prefix if `allow_ties`, else by
/// rank.
fn key_codes<'a>(
    v: &'a Vector,
    key: &SortKey,
    threads: usize,
    allow_ties: bool,
) -> Vec<KeyCodes<'a>> {
    let n = v.len();
    let valid: Option<&[bool]> = v.valid.as_deref();
    let mut ties = None;
    let mut enc: Vec<u64> = match &v.data {
        Data::Int(x) | Data::Timestamp(x) | Data::Decimal(x, _) => {
            x.iter().map(|&x| enc_i64(x)).collect()
        }
        Data::Date(x) => x.iter().map(|&d| enc_i64(d as i64)).collect(),
        Data::Bool(x) => x.iter().map(|&b| u64::from(b)).collect(),
        Data::Float(x) => x.iter().map(|&f| enc_f64(f)).collect(),
        Data::Str(x) if allow_ties => {
            ties = Some(Strings::Plain(x));
            string_prefixes(x, threads)
        }
        Data::Str(x) => string_ranks(x, threads),
        Data::Dict(codes, dict) => {
            let rank = if dict.len() <= 4096 {
                dict_ranks(dict)
            } else if allow_ties {
                ties = Some(Strings::Dict(codes, dict));
                string_prefixes(dict, threads)
            } else {
                string_ranks(dict, threads)
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
        out.push(KeyCodes::exact(codes, 1));
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
    let ties = ties.map(|strings| Ties {
        strings,
        valid,
        descending: key.descending,
    });
    if bits > 0 || ties.is_some() {
        if key.descending {
            enc.iter_mut().for_each(|e| *e = hi - *e);
        } else {
            enc.iter_mut().for_each(|e| *e -= lo);
        }
        out.push(KeyCodes {
            codes: enc,
            bits,
            ties,
        });
    }
    out
}

/// Order-preserving codes of strings up to ties: the 8 bytes following
/// the longest prefix shared by all strings (big-endian, zero padded).
/// Computed on up to `threads` threads.
fn string_prefixes(v: &[Arc<str>], threads: usize) -> Vec<u64> {
    let n = v.len();
    if n == 0 {
        return Vec::new();
    }
    let threads = if n < 2 * PARALLEL_SORT_MIN {
        1
    } else {
        threads.min(n / PARALLEL_SORT_MIN).max(1)
    };
    let size = n.div_ceil(threads);
    let first = v[0].as_bytes();
    let offset = pool::scoped(
        v.chunks(size)
            .map(|chunk| {
                move || {
                    chunk.iter().fold(first.len(), |l, s| {
                        let s = s.as_bytes();
                        let l = l.min(s.len());
                        first[..l].iter().zip(s).take_while(|(a, b)| a == b).count()
                    })
                }
            })
            .collect(),
    )
    .into_iter()
    .min()
    .unwrap_or(0);
    let mut codes = vec![0u64; n];
    pool::scoped(
        codes
            .chunks_mut(size)
            .zip(v.chunks(size))
            .map(|(out, strings)| {
                move || {
                    for (o, s) in out.iter_mut().zip(strings) {
                        *o = str_prefix(&s.as_bytes()[offset.min(s.len())..]);
                    }
                }
            })
            .collect(),
    );
    codes
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
    let (pairs, diff) = pairs_by(n, threads, |i| str_prefix(v[i].as_bytes()));
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
    pool::scoped(
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

/// A `(key, row)` pair of a sort.
type Pair = (u64, u32);

/// Sorts rows `0..n` by the components' codes (first component most
/// significant, ties by row number). The codes are concatenated and the
/// top 64 bits sorted as integers. If that key is inexact — a string coded
/// by prefix, or codes longer than 64 bits — runs of rows that are equal
/// up to the inexact part are then ordered by comparing the components
/// (rare in practice: they need equal prefixes or equal leading 64 bits).
fn normalized_sort(codes: &[KeyCodes], n: usize, threads: usize) -> Vec<u32> {
    let total: u32 = codes.iter().map(|c| c.bits).sum();
    // Bits (from the top) up to the end of the first prefix-coded string.
    let tie_end = codes
        .iter()
        .scan(0, |end, c| {
            *end += c.bits;
            Some((*end, c.ties.is_some()))
        })
        .find(|&(_, ties)| ties)
        .map(|(end, _)| end);
    if total == 0 && tie_end.is_none() {
        return (0..n as u32).collect();
    }
    let width = total.min(64);
    let (pairs, diff) = pairs_by(n, threads, |i| pack(codes, i));
    let mut pairs = sort_pairs(pairs, diff, threads);
    let exact_to = match tie_end {
        Some(end) => Some(end.min(64)),
        None => (total > 64).then_some(64),
    };
    if let Some(m) = exact_to {
        // Runs: pairs equal in the key's top `m` bits.
        let mask = u64::MAX.checked_shl(width - m).unwrap_or(0);
        let size = n.div_ceil(threads.max(1)).max(PARALLEL_SORT_MIN);
        let mut segments = Vec::new();
        let mut rest: &mut [Pair] = &mut pairs;
        while !rest.is_empty() {
            let mut cut = size.min(rest.len());
            while cut < rest.len() && rest[cut].0 & mask == rest[cut - 1].0 & mask {
                cut += 1;
            }
            let (segment, tail) = std::mem::take(&mut rest).split_at_mut(cut);
            segments.push(segment);
            rest = tail;
        }
        pool::scoped(
            segments
                .into_iter()
                .map(|segment| move || order_runs(segment, mask, codes))
                .collect(),
        );
    }
    pairs.into_iter().map(|(_, i)| i).collect()
}

/// The top 64 bits of the concatenated codes of row `i` (all of them,
/// right-aligned, if they are shorter).
#[inline]
fn pack(codes: &[KeyCodes], i: usize) -> u64 {
    let mut key = 0u64;
    let mut room = 64;
    for c in codes {
        if c.bits <= room {
            key = key.checked_shl(c.bits).unwrap_or(0) | c.codes[i];
            room -= c.bits;
        } else {
            if room > 0 {
                key = (key << room) | (c.codes[i] >> (c.bits - room));
            }
            break;
        }
    }
    key
}

/// Orders the runs of `pairs` that are equal under `mask` by comparing the
/// components (codes, then strings for prefix-coded ones), then rows.
fn order_runs(pairs: &mut [Pair], mask: u64, codes: &[KeyCodes]) {
    let cmp = |a: usize, b: usize| {
        codes
            .iter()
            .map(|c| {
                c.codes[a]
                    .cmp(&c.codes[b])
                    .then_with(|| c.ties.as_ref().map_or(Ordering::Equal, |t| t.compare(a, b)))
            })
            .find(|o| o.is_ne())
            .unwrap_or(Ordering::Equal)
            .then(a.cmp(&b))
    };
    let mut i = 0;
    while i < pairs.len() {
        let m = pairs[i].0 & mask;
        let mut j = i + 1;
        while j < pairs.len() && pairs[j].0 & mask == m {
            j += 1;
        }
        if j - i > 1 {
            pairs[i..j].sort_unstable_by(|x, y| cmp(x.1 as usize, y.1 as usize));
        }
        i = j;
    }
}

/// The pairs `(key(i), i)` for rows `0..n`, computed on up to `threads`
/// threads, and the bits in which the keys differ (OR of `key ^ key(0)`).
fn pairs_by(n: usize, threads: usize, key: impl Fn(usize) -> u64 + Sync) -> (Vec<Pair>, u64) {
    let mut pairs = vec![(0u64, 0u32); n];
    if n == 0 {
        return (pairs, 0);
    }
    let first = key(0);
    let threads = threads.min(n / PARALLEL_SORT_MIN).max(1);
    let size = n.div_ceil(threads);
    let key = &key;
    let diffs = pool::scoped(
        pairs
            .chunks_mut(size)
            .enumerate()
            .map(|(c, chunk)| {
                move || {
                    let mut diff = 0;
                    for (j, p) in chunk.iter_mut().enumerate() {
                        let i = c * size + j;
                        let k = key(i);
                        diff |= k ^ first;
                        *p = (k, i as u32);
                    }
                    diff
                }
            })
            .collect(),
    );
    (pairs, diffs.into_iter().fold(0, |a, b| a | b))
}

/// The 8-bit digit of `key` starting at bit `shift`.
#[inline]
fn digit(key: u64, shift: u32) -> usize {
    ((key >> shift) & 0xff) as usize
}

/// Sorts `(key, row)` pairs (rows unique, pairs in ascending row order) by
/// key and row; `diff` has the bits in which keys differ. Large inputs are
/// partitioned by their top varying bits (every thread scatters its chunk
/// straight into the partitions), then the partitions are sorted in place
/// in parallel.
fn sort_pairs(mut pairs: Vec<Pair>, diff: u64, threads: usize) -> Vec<Pair> {
    let n = pairs.len();
    if threads <= 1 || n < 2 * PARALLEL_SORT_MIN {
        sort_slice(&mut pairs, &mut Vec::new());
        return pairs;
    }
    if diff == 0 {
        return pairs; // one key: row order
    }
    let top = 63 - diff.leading_zeros();
    let shift = top.saturating_sub(7);
    let threads = threads.min(n / PARALLEL_SORT_MIN).max(1);
    let size = n.div_ceil(threads);
    let hists: Vec<[usize; 256]> = pool::scoped(
        pairs
            .chunks(size)
            .map(|chunk| {
                move || {
                    let mut h = [0usize; 256];
                    for p in chunk {
                        h[digit(p.0, shift)] += 1;
                    }
                    h
                }
            })
            .collect(),
    );
    // Partition `d` is the concatenation of every chunk's part `d` (in
    // chunk order, so it stays in ascending row order).
    let mut out = vec![(0u64, 0u32); n];
    let mut targets: Vec<Vec<&mut [Pair]>> =
        hists.iter().map(|_| Vec::with_capacity(256)).collect();
    let mut rest: &mut [Pair] = &mut out;
    for d in 0..256 {
        for (c, h) in hists.iter().enumerate() {
            let (part, tail) = std::mem::take(&mut rest).split_at_mut(h[d]);
            targets[c].push(part);
            rest = tail;
        }
    }
    pool::scoped(
        pairs
            .chunks(size)
            .zip(targets)
            .map(|(chunk, mut parts)| {
                move || {
                    let mut pos = [0usize; 256];
                    for &p in chunk {
                        let d = digit(p.0, shift);
                        parts[d][pos[d]] = p;
                        pos[d] += 1;
                    }
                }
            })
            .collect(),
    );
    drop(pairs);
    // Sort the partitions, assigned to threads largest first (each to the
    // least loaded thread).
    let mut parts: Vec<&mut [Pair]> = Vec::with_capacity(256);
    let mut rest: &mut [Pair] = &mut out;
    for d in 0..256 {
        let len = hists.iter().map(|h| h[d]).sum();
        let (part, tail) = std::mem::take(&mut rest).split_at_mut(len);
        rest = tail;
        if len > 1 {
            parts.push(part);
        }
    }
    parts.sort_by_key(|p| std::cmp::Reverse(p.len()));
    let mut work: Vec<(usize, Vec<&mut [Pair]>)> = (0..threads).map(|_| (0, Vec::new())).collect();
    for part in parts {
        let w = work
            .iter_mut()
            .min_by_key(|(load, _)| *load)
            .expect("at least one thread");
        w.0 += part.len();
        w.1.push(part);
    }
    pool::scoped(
        work.into_iter()
            .map(|(_, parts)| {
                move || {
                    let mut scratch = Vec::new();
                    for part in parts {
                        sort_slice(part, &mut scratch);
                    }
                }
            })
            .collect(),
    );
    out
}

/// Sorts `(key, row)` pairs that are in ascending row order by key and row
/// on the current thread: `sort_unstable` for small inputs, else a stable
/// LSD radix sort (8-bit digits; digits equal in every key are skipped)
/// using `scratch` as the second buffer.
fn sort_slice(items: &mut [Pair], scratch: &mut Vec<Pair>) {
    let n = items.len();
    if n < 4096 {
        items.sort_unstable();
        return;
    }
    // Only the digits up to the highest varying bit are histogrammed.
    let first = items[0].0;
    let diff = items.iter().fold(0, |acc, p| acc | (p.0 ^ first));
    if diff == 0 {
        return; // one key: already in row order
    }
    let digits = (64 - diff.leading_zeros()).div_ceil(8) as usize;
    let mut hist = vec![[0usize; 256]; digits];
    for &(k, _) in items.iter() {
        for (d, h) in hist.iter_mut().enumerate() {
            h[digit(k, 8 * d as u32)] += 1;
        }
    }
    scratch.clear();
    scratch.resize(n, (0, 0));
    let mut in_items = true;
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
        let (src, dst): (&[Pair], &mut [Pair]) = if in_items {
            (items, scratch)
        } else {
            (scratch, items)
        };
        for &it in src {
            let b = digit(it.0, 8 * d as u32);
            dst[offs[b]] = it;
            offs[b] += 1;
        }
        in_items = !in_items;
    }
    if !in_items {
        items.copy_from_slice(scratch);
    }
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
        let mut sorted = items.clone();
        sort_slice(&mut sorted, &mut Vec::new());
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
        let mut shared = Vec::new();
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
            // A long shared prefix, then short, NUL-extended and long tails.
            let tail = words[((r >> 30) % 9) as usize];
            shared.push(if (r >> 40).is_multiple_of(29) {
                Value::Null
            } else if (r >> 34).is_multiple_of(3) {
                Value::str(&format!("shared/prefix/{tail}{}", (r >> 44) % 50))
            } else {
                Value::str(&format!("shared/prefix/{tail}"))
            });
        }
        let cols = [strs, ints, floats, shared];
        let b = Batch::new(
            cols.iter()
                .map(|c| Vector::from_values(c.clone()))
                .collect(),
            n,
        );
        let types = [
            DataType::String,
            DataType::Int64,
            DataType::Float64,
            DataType::String,
        ];
        let mut ctx = ExecContext::default();
        for (round, order) in [
            [0usize, 1, 2],
            [1, 0, 2],
            [2, 0, 1],
            [1, 2, 0],
            [3, 1, 2],
            [3, 0, 1],
            [1, 3, 0],
            [0, 3, 2],
        ]
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
