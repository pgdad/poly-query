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
//! Large comparator-sorted inputs are cut into chunks sorted on separate
//! threads and merged.
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
    /// Dictionary-encoded strings compared as strings (sorted runs, whose
    /// keys are compared with other batches' keys).
    Dict(Vec<u32>, Arc<[Arc<str>]>),
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
        SortColumn::with_dict_ranks(v, key, true)
    }

    /// With `ranks`, dictionary codes are replaced by the ranks of their
    /// strings (only comparable within this vector).
    fn with_dict_ranks(v: Vector, key: &SortKey, ranks: bool) -> SortColumn {
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
            Data::Dict(codes, dict) if !ranks => SortCol::Dict(codes, dict),
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
            SortCol::Dict(c, d) => d[c[a] as usize].as_bytes().cmp(d[c[b] as usize].as_bytes()),
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
    order(b, keys, top, true, ctx)
}

/// The rows at the first `n` positions of the stable order, in row order
/// (top-N compaction: selecting the set does not need sorting it).
pub fn top_rows(b: &Batch, keys: &[SortKey], n: usize, ctx: &ExecContext) -> Result<Vec<u32>> {
    let mut rows = order(b, keys, Some(n), false, ctx)?;
    rows.sort_unstable();
    Ok(rows)
}

/// The first `top` (default: all) rows of the stable order; sorted by
/// that order if `sorted`, else in unspecified order.
fn order(
    b: &Batch,
    keys: &[SortKey],
    top: Option<usize>,
    sorted: bool,
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
        ctx.execution.threads
    };
    let out = if let [single] = cols.as_slice()
        && !matches!(single.col, SortCol::Values(_))
    {
        sort_single(single, n, top, threads)
    } else if cols.iter().all(|c| !matches!(c.col, SortCol::Values(_))) {
        let keys = NormKeys::new(cols, n, false);
        match keys.pack() {
            Some(Packed::U64(items)) => sort_packed64(items, top, sorted),
            Some(Packed::U128(items)) => sort_packed128(items, top, sorted, threads),
            None => {
                let idx: Vec<u32> = (0..n as u32).collect();
                let cmp = |x: &u32, y: &u32| keys.compare(*x, *y).then(x.cmp(y));
                select_or_sort(idx, top, sorted, threads, &cmp)
            }
        }
    } else {
        let idx: Vec<u32> = (0..n as u32).collect();
        let cmp = |x: &u32, y: &u32| compare_rows(&cols, *x as usize, *y as usize).then(x.cmp(y));
        select_or_sort(idx, top, sorted, threads, &cmp)
    };
    ctx.check_interrupt()?;
    Ok(out)
}

/// Sorts `items` by `cmp` (a total order), or selects its first `top`
/// items (sorted if `sorted`).
fn select_or_sort<T: Copy + Send + Sync>(
    mut items: Vec<T>,
    top: Option<usize>,
    sorted: bool,
    threads: usize,
    cmp: &(dyn Fn(&T, &T) -> Ordering + Sync),
) -> Vec<T> {
    match top {
        Some(t) if t < items.len() => {
            items.select_nth_unstable_by(t - 1, cmp);
            items.truncate(t);
            if sorted {
                items.sort_unstable_by(cmp);
            }
            items
        }
        _ if !sorted => items,
        _ => parallel_sort(
            items,
            threads,
            &|mut v: Vec<T>| {
                v.sort_unstable_by(cmp);
                v
            },
            cmp,
        ),
    }
}

/// Multi-key sort keys normalized to rows of `u64` words that compare
/// lexicographically in sort order (row-major, so a comparison touches one
/// cache line): per key an optional NULL-placement word and the value
/// word(s), bit-inverted for DESC: the order-preserving encoding of
/// fixed-width values; for strings the big-endian 8-byte prefix and
/// `min(length, 9)`, which decide the order unless both strings are longer
/// than 8 bytes and the prefixes tie (then the strings are compared).
struct NormKeys {
    width: usize,
    words: Vec<u64>,
    strings: Vec<StrKey>,
}

/// A string key of [`NormKeys`].
struct StrKey {
    /// Index of the prefix word (the length word follows it).
    word: usize,
    src: StrSource,
    descending: bool,
}

enum StrSource {
    Plain(Vec<Arc<str>>),
    Dict(Vec<u32>, Arc<[Arc<str>]>),
}

impl StrSource {
    #[inline]
    fn get(&self, i: usize) -> &[u8] {
        match self {
            StrSource::Plain(v) => v[i].as_bytes(),
            StrSource::Dict(c, d) => d[c[i] as usize].as_bytes(),
        }
    }
}

/// Normalized keys packed into one integer per row (key bits above the
/// row number), so plain integer order is the stable sort order.
enum Packed {
    U64(Vec<(u64, u32)>),
    U128(Vec<u128>),
}

#[inline]
fn str_prefix(b: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    let k = b.len().min(8);
    buf[..k].copy_from_slice(&b[..k]);
    u64::from_be_bytes(buf)
}

/// Value of the length word of strings that need a full comparison.
const LONG: u64 = 9;

impl NormKeys {
    /// `cols` must not contain generic (`Values`) keys. With `uniform`,
    /// every key has a NULL word, so keys of different batches have the
    /// same layout and compare with each other.
    fn new(cols: Vec<SortColumn>, n: usize, uniform: bool) -> NormKeys {
        let has_null_word = |c: &SortColumn| uniform || c.nulls.is_some();
        let width: usize = cols
            .iter()
            .map(|c| {
                let value_words = match c.col {
                    SortCol::Str(_) | SortCol::Dict(..) => 2,
                    _ => 1,
                };
                value_words + usize::from(has_null_word(c))
            })
            .sum();
        let mut words = vec![0u64; n * width];
        let mut strings = Vec::new();
        let mut w = 0;
        for c in cols {
            if has_null_word(&c) {
                // NULLs first: NULL = 0 < non-NULL = 1; NULLs last: reversed.
                let (null, non_null) = if c.nulls_first { (0, 1) } else { (1, 0) };
                for i in 0..n {
                    let is_null = c.nulls.as_ref().is_some_and(|x| x[i]);
                    words[i * width + w] = if is_null { null } else { non_null };
                }
                w += 1;
            }
            let flip = if c.descending { u64::MAX } else { 0 };
            let nulls = c.nulls;
            let is_null = |i: usize| nulls.as_ref().is_some_and(|x| x[i]);
            let src = match c.col {
                SortCol::U64(v) => {
                    for (i, &x) in v.iter().enumerate() {
                        words[i * width + w] = if is_null(i) { 0 } else { x ^ flip };
                    }
                    w += 1;
                    continue;
                }
                SortCol::Str(v) => StrSource::Plain(v),
                SortCol::Dict(codes, dict) => StrSource::Dict(codes, dict),
                SortCol::Values(_) => unreachable!("generic keys use the comparator path"),
            };
            for i in 0..n {
                if !is_null(i) {
                    let s = src.get(i);
                    words[i * width + w] = str_prefix(s) ^ flip;
                    words[i * width + w + 1] = (s.len() as u64).min(LONG) ^ flip;
                }
            }
            strings.push(StrKey {
                word: w,
                src,
                descending: c.descending,
            });
            w += 2;
        }
        NormKeys {
            width,
            words,
            strings,
        }
    }

    #[inline]
    fn row(&self, i: u32) -> &[u64] {
        let from = i as usize * self.width;
        &self.words[from..from + self.width]
    }

    #[inline]
    fn compare(&self, a: u32, b: u32) -> Ordering {
        compare_norm(self, a, a, self, b, b)
    }

    /// The word rows reordered by `perm` (word row `k` = row `perm[k]`),
    /// so that a merge reads them sequentially.
    fn permute_words(&mut self, perm: &[u32]) {
        let mut words = Vec::with_capacity(perm.len() * self.width);
        for &i in perm {
            words.extend_from_slice(self.row(i));
        }
        self.words = words;
    }

    /// Packs every row's words into one integer if the words' value ranges
    /// fit (no string keys).
    fn pack(&self) -> Option<Packed> {
        if !self.strings.is_empty() {
            return None;
        }
        let n = self.words.len() / self.width.max(1);
        let mut min = vec![u64::MAX; self.width];
        let mut max = vec![0u64; self.width];
        for row in self.words.chunks_exact(self.width) {
            for (j, &x) in row.iter().enumerate() {
                min[j] = min[j].min(x);
                max[j] = max[j].max(x);
            }
        }
        let bits: Vec<u32> = (0..self.width)
            .map(|j| {
                if n == 0 {
                    0
                } else {
                    64 - (max[j] - min[j]).leading_zeros()
                }
            })
            .collect();
        let total: u32 = bits.iter().sum();
        let key = |row: &[u64]| -> u128 {
            let mut k = 0u128;
            for (j, &x) in row.iter().enumerate() {
                k = (k << bits[j]) | (x - min[j]) as u128;
            }
            k
        };
        if total <= 64 {
            Some(Packed::U64(
                self.words
                    .chunks_exact(self.width)
                    .enumerate()
                    .map(|(i, row)| (key(row) as u64, i as u32))
                    .collect(),
            ))
        } else if total <= 96 {
            Some(Packed::U128(
                self.words
                    .chunks_exact(self.width)
                    .enumerate()
                    .map(|(i, row)| (key(row) << 32) | i as u128)
                    .collect(),
            ))
        } else {
            None
        }
    }
}

fn sort_packed64(items: Vec<(u64, u32)>, top: Option<usize>, sorted: bool) -> Vec<u32> {
    let items = match top {
        Some(t) if t < items.len() => {
            let mut p = items;
            p.select_nth_unstable(t - 1);
            p.truncate(t);
            if sorted {
                p.sort_unstable();
            }
            p
        }
        _ if !sorted => items,
        _ if items.len() < 1024 => {
            let mut p = items;
            p.sort_unstable();
            p
        }
        _ => radix_sort(items),
    };
    items.into_iter().map(|(_, i)| i).collect()
}

/// Compares a row of `x` with a row of `y` (keys of the same sort keys
/// and layout), given as word row (`aw`, `bw`) and row of the string
/// sources (`a`, `b`), which differ once the words are permuted.
#[inline]
fn compare_norm(x: &NormKeys, aw: u32, a: u32, y: &NormKeys, bw: u32, b: u32) -> Ordering {
    let (ra, rb) = (x.row(aw), y.row(bw));
    let mut from = 0;
    for (sx, sy) in x.strings.iter().zip(&y.strings) {
        let end = sx.word + 2;
        let o = ra[from..end].cmp(&rb[from..end]);
        if o != Ordering::Equal {
            return o;
        }
        let flip = if sx.descending { u64::MAX } else { 0 };
        if ra[sx.word + 1] ^ flip == LONG {
            let o = sx.src.get(a as usize).cmp(sy.src.get(b as usize));
            if o != Ordering::Equal {
                return if sx.descending { o.reverse() } else { o };
            }
        }
        from = end;
    }
    ra[from..].cmp(&rb[from..])
}

/// Sorted rows with their keys normalized for comparisons with other runs
/// of the same keys (None: generic keys; such runs are merged by
/// re-sorting). Row `k` of `batch` was row `perm[k]` of the input, where
/// the keys' string sources still refer to.
pub struct SortedRun {
    batch: Batch,
    perm: Vec<u32>,
    keys: Option<NormKeys>,
}

/// Sorts `b` by `keys` (the first `top` rows with `top`) into a run.
pub fn sorted_run(
    b: Batch,
    keys: &[SortKey],
    top: Option<usize>,
    ctx: &ExecContext,
) -> Result<SortedRun> {
    let mut cols = Vec::with_capacity(keys.len());
    for k in keys {
        cols.push(SortColumn::with_dict_ranks(
            eval(&k.expr, &b, ctx)?,
            k,
            false,
        ));
    }
    if cols.iter().any(|c| matches!(c.col, SortCol::Values(_))) {
        let perm = sort_permutation(&b, keys, top, ctx)?;
        return Ok(SortedRun {
            batch: b.gather(&perm),
            perm,
            keys: None,
        });
    }
    let mut norm = NormKeys::new(cols, b.len, true);
    let threads = if ctx.in_subquery() {
        1
    } else {
        ctx.execution.threads
    };
    let perm = match norm.pack() {
        Some(Packed::U64(items)) => sort_packed64(items, top, true),
        Some(Packed::U128(items)) => sort_packed128(items, top, true, threads),
        None => {
            let idx: Vec<u32> = (0..b.len as u32).collect();
            let cmp = |x: &u32, y: &u32| norm.compare(*x, *y).then(x.cmp(y));
            select_or_sort(idx, top, true, threads, &cmp)
        }
    };
    norm.permute_words(&perm);
    ctx.check_interrupt()?;
    Ok(SortedRun {
        batch: b.gather(&perm),
        perm,
        keys: Some(norm),
    })
}

/// The first `n` rows of the sorted union of `runs` (runs of `keys`, with
/// `width` columns). `keys` must be a total order (no ties between rows).
pub fn merge_top(
    runs: Vec<SortedRun>,
    keys: &[SortKey],
    n: usize,
    width: usize,
    ctx: &ExecContext,
) -> Result<Batch> {
    let runs: Vec<SortedRun> = runs.into_iter().filter(|r| !r.perm.is_empty()).collect();
    if runs.iter().any(|r| r.keys.is_none()) {
        let batches: Vec<Batch> = runs.into_iter().map(|r| r.batch).collect();
        if batches.is_empty() {
            return Ok(Batch::new(Vec::new(), 0));
        }
        let all = Batch::concat(&batches, width);
        let perm = sort_permutation(&all, keys, Some(n), ctx)?;
        return Ok(all.gather(&perm));
    }
    let norm: Vec<&NormKeys> = runs.iter().filter_map(|r| r.keys.as_ref()).collect();
    let perms: Vec<&[u32]> = runs.iter().map(|r| r.perm.as_slice()).collect();
    // Position in each run's order (= word row of its permuted keys); a
    // binary min-heap of run indices ordered by the rows at those positions.
    let mut pos = vec![0usize; runs.len()];
    let less = |pos: &[usize], x: usize, y: usize| {
        let (px, py) = (pos[x], pos[y]);
        compare_norm(
            norm[x],
            px as u32,
            perms[x][px],
            norm[y],
            py as u32,
            perms[y][py],
        ) == Ordering::Less
    };
    let sift_down = |heap: &mut [usize], pos: &[usize], mut i: usize| {
        loop {
            let (l, r) = (2 * i + 1, 2 * i + 2);
            let mut m = i;
            if l < heap.len() && less(pos, heap[l], heap[m]) {
                m = l;
            }
            if r < heap.len() && less(pos, heap[r], heap[m]) {
                m = r;
            }
            if m == i {
                return;
            }
            heap.swap(i, m);
            i = m;
        }
    };
    let mut heap: Vec<usize> = (0..runs.len()).collect();
    for i in (0..heap.len() / 2).rev() {
        sift_down(&mut heap, &pos, i);
    }
    let mut order: Vec<(u32, u32)> = Vec::with_capacity(n.min(1 << 20));
    while order.len() < n && !heap.is_empty() {
        let r = heap[0];
        order.push((r as u32, pos[r] as u32));
        pos[r] += 1;
        if pos[r] == perms[r].len() {
            let last = heap.len() - 1;
            heap.swap(0, last);
            heap.pop();
        }
        sift_down(&mut heap, &pos, 0);
    }
    ctx.check_interrupt()?;
    let batches: Vec<&Batch> = runs.iter().map(|r| &r.batch).collect();
    Ok(Batch::gather_parts(&batches, &order, width))
}

fn sort_packed128(items: Vec<u128>, top: Option<usize>, sorted: bool, threads: usize) -> Vec<u32> {
    let cmp = |a: &u128, b: &u128| a.cmp(b);
    select_or_sort(items, top, sorted, threads, &cmp)
        .into_iter()
        .map(|x| x as u32)
        .collect()
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
                // Radix sorting is memory-bound and linear: one pass beats
                // sorting chunks in parallel and merging them.
                _ => radix_sort(pairs),
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
        SortCol::Dict(..) | SortCol::Values(_) => {
            unreachable!("generic keys use the comparator path")
        }
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

    /// Multi-key orders (normalized words, packed and string keys) and
    /// merged runs equal the generic comparator's stable order.
    #[test]
    fn multi_key_orders_and_merged_runs_match_comparator() {
        let n = 3000usize;
        let strs = [
            "",
            "a",
            "ab",
            "abcdefgh",
            "abcdefghi",
            "abcdefghj",
            "b\0",
            "b",
            "zz",
        ];
        let rows: Vec<Vec<Value>> = (0..n)
            .map(|i| {
                let s = if i % 13 == 0 {
                    Value::Null
                } else {
                    Value::str(strs[(i * 7) % strs.len()])
                };
                let x = if i % 17 == 0 {
                    Value::Null
                } else {
                    Value::Int(((i * 31) % 23) as i64 - 11)
                };
                vec![s, x, Value::Int(i as i64 % 5)]
            })
            .collect();
        let column = |c: usize| Vector::from_values(rows.iter().map(|r| r[c].clone()).collect());
        let b = Batch::new(vec![column(0), column(1), column(2)], n);
        let ctx = ExecContext::default();
        let key = |index: usize, ty: DataType, descending: bool, nulls_first: bool| SortKey {
            expr: Expr::Column { index, ty },
            descending,
            nulls_first,
        };
        let key_sets = [
            vec![
                key(0, DataType::String, false, true),
                key(1, DataType::Int64, true, false),
            ],
            vec![
                key(1, DataType::Int64, false, false),
                key(2, DataType::Int64, true, true),
            ],
            vec![
                key(2, DataType::Int64, true, false),
                key(0, DataType::String, true, true),
            ],
        ];
        for keys in &key_sets {
            let mut expect: Vec<u32> = (0..n as u32).collect();
            expect.sort_by(|&x, &y| {
                for k in keys {
                    let Expr::Column { index, .. } = k.expr else {
                        unreachable!()
                    };
                    let o = crate::exec::operators::compare_keys(
                        &rows[x as usize][index],
                        &rows[y as usize][index],
                        k,
                    );
                    if o != Ordering::Equal {
                        return o;
                    }
                }
                Ordering::Equal
            });
            for top in [None, Some(1), Some(100)] {
                let got = sort_permutation(&b, keys, top, &ctx).unwrap();
                let want = &expect[..top.unwrap_or(n)];
                assert_eq!(got, want, "keys={keys:?} top={top:?}");
            }
            // Runs over slices, with the row number as the final key.
            let mut keys_seq = keys.clone();
            keys_seq.push(key(3, DataType::Int64, false, true));
            let with_seq = |from: usize, to: usize| {
                let mut part = b.slice(from, to);
                part.columns.push(Vector::new(
                    Data::Int((from as i64..to as i64).collect()),
                    None,
                ));
                part
            };
            let runs = [(0, 1000), (1000, 1100), (1100, n)]
                .iter()
                .map(|&(f, t)| sorted_run(with_seq(f, t), &keys_seq, Some(500), &ctx).unwrap())
                .collect();
            let merged = merge_top(runs, &keys_seq, 400, 4, &ctx).unwrap();
            let order: Vec<u32> = (0..merged.len)
                .map(|i| match merged.columns[3].value(i) {
                    Value::Int(x) => x as u32,
                    v => panic!("{v:?}"),
                })
                .collect();
            assert_eq!(order, &expect[..400], "merged keys={keys:?}");
        }
    }
}
