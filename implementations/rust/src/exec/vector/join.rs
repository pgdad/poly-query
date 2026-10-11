//! Vectorized joins.
//!
//! All three algorithms reduce to the same output step: for each *outer*
//! row (in emission order) a list of candidate *inner* rows. [`emit`] turns
//! candidate pairs into output batches by gathering both sides, applies the
//! residual predicate, and pads unmatched outer rows of LEFT joins with
//! NULLs — in the same row order as the row-mode operators.
//!
//! * hash join: the build side is materialized into one batch and indexed
//!   by a [`KeyTable`] with CSR row lists (cache-friendly, no per-key
//!   allocation); probe batches stream. The table is immutable and shared
//!   (`Arc`) by parallel probe workers.
//! * merge join: both inputs are materialized, sorted by key (typed
//!   comparisons on the concatenated key columns), and merged.
//! * nested-loop join: the right input is materialized; every left row is
//!   paired with all right rows and the predicate filters the pairs.

use std::sync::Arc;

use super::batch::{BATCH_SIZE, Batch, NO_ROW, Vector};
use super::eval::{eval, eval_mask};
use super::keys::{DictCache, KeyTable};
use super::ops::{BatchOperator, BoxedBatchOp};
use crate::error::Result;
use crate::exec::ExecContext;
use crate::exec::eval::normalize_key;
use crate::planner::expr::{Expr, KeyDomain};
use crate::planner::logical::SortKey;

/// Output shape of a join.
#[derive(Debug, Clone)]
pub struct JoinSpec {
    /// Pad outer rows without a (residual-passing) match with NULLs.
    pub left_join: bool,
    /// The outer side provides the left output columns.
    pub outer_is_left: bool,
    pub residual: Option<Expr>,
    pub outer_width: usize,
    pub inner_width: usize,
}

/// Candidate inner rows of one outer row.
pub enum Cand<'a> {
    Rows(&'a [u32]),
    All(usize),
}

impl Cand<'_> {
    fn len(&self) -> usize {
        match self {
            Cand::Rows(r) => r.len(),
            Cand::All(n) => *n,
        }
    }

    fn get(&self, i: usize) -> u32 {
        match self {
            Cand::Rows(r) => r[i],
            Cand::All(_) => i as u32,
        }
    }
}

/// Progress through the outer rows of one outer batch.
#[derive(Debug, Default)]
pub struct Cursor {
    /// Position in the outer emission order.
    pos: usize,
    /// Next candidate of the current outer row.
    cand: usize,
    /// Whether the current outer row has produced a match.
    matched: bool,
}

impl Cursor {
    pub fn done(&self, order_len: usize) -> bool {
        self.pos >= order_len
    }
}

fn assemble(spec: &JoinSpec, outer: &Batch, inner: &Batch, o: &[u32], i: &[u32]) -> Batch {
    let oc = outer.columns.iter().map(|c| c.gather(o));
    let ic = inner.columns.iter().map(|c| c.gather_opt(i));
    let columns = if spec.outer_is_left {
        oc.chain(ic).collect()
    } else {
        ic.chain(oc).collect()
    };
    Batch::new(columns, o.len())
}

/// Produces the next output batch of joining the outer rows `order` (their
/// positions in `outer`) with their candidates. Returns None once every
/// outer row has been processed.
pub fn emit<'a>(
    spec: &JoinSpec,
    cursor: &mut Cursor,
    outer: &Batch,
    inner: &Batch,
    order: &dyn Fn(usize) -> u32,
    order_len: usize,
    candidates: &dyn Fn(usize) -> Cand<'a>,
    ctx: &ExecContext,
) -> Result<Option<Batch>> {
    // (outer row, end of its pairs in this chunk, row complete)
    let mut segments: Vec<(u32, usize, bool)> = Vec::new();
    loop {
        if cursor.pos >= order_len {
            return Ok(None);
        }
        ctx.check_interrupt()?;
        segments.clear();
        let mut o_idx: Vec<u32> = Vec::new();
        let mut i_idx: Vec<u32> = Vec::new();
        while cursor.pos < order_len && o_idx.len() < BATCH_SIZE {
            let o = order(cursor.pos);
            let c = candidates(cursor.pos);
            let total = c.len();
            let take = (total - cursor.cand).min(BATCH_SIZE - o_idx.len());
            for k in cursor.cand..cursor.cand + take {
                o_idx.push(o);
                i_idx.push(c.get(k));
            }
            cursor.cand += take;
            let complete = cursor.cand >= total;
            segments.push((o, o_idx.len(), complete));
            if !complete {
                break;
            }
            cursor.pos += 1;
            cursor.cand = 0;
        }
        let mask = match &spec.residual {
            Some(r) if !o_idx.is_empty() => {
                let cand = assemble(spec, outer, inner, &o_idx, &i_idx);
                let mask = eval_mask(r, &cand, ctx)?;
                if !spec.left_join {
                    let out = cand.filter(&mask);
                    if out.len == 0 {
                        continue;
                    }
                    ctx.count_join_rows(out.len as u64)?;
                    return Ok(Some(out));
                }
                Some(mask)
            }
            _ => None,
        };
        let (fo, fi) = if spec.left_join {
            // Interleave surviving pairs with NULL-padded unmatched rows.
            let mut fo = Vec::with_capacity(o_idx.len());
            let mut fi = Vec::with_capacity(o_idx.len());
            let mut start = 0;
            for &(o, end, complete) in &segments {
                for k in start..end {
                    if mask.as_ref().is_none_or(|m| m[k]) {
                        fo.push(o);
                        fi.push(i_idx[k]);
                        cursor.matched = true;
                    }
                }
                start = end;
                if complete {
                    if !cursor.matched {
                        fo.push(o);
                        fi.push(NO_ROW);
                    }
                    cursor.matched = false;
                }
            }
            (fo, fi)
        } else {
            (o_idx, i_idx)
        };
        if fo.is_empty() {
            continue;
        }
        ctx.count_join_rows(fo.len() as u64)?;
        return Ok(Some(assemble(spec, outer, inner, &fo, &fi)));
    }
}

/// Key vector normalized to a comparison domain (so that hashing agrees
/// with SQL equality across types).
fn normalized(v: Vector, domain: KeyDomain) -> Vector {
    if domain == KeyDomain::Exact {
        return v;
    }
    let values = (0..v.len())
        .map(|i| {
            let x = v.value(i);
            if x.is_null() { x } else { normalize_key(x, domain) }
        })
        .collect();
    Vector::from_values(values)
}

/// Evaluates (normalized) key vectors.
fn key_vectors(keys: &[(Expr, KeyDomain)], b: &Batch, ctx: &ExecContext) -> Result<Vec<Vector>> {
    let mut out = Vec::with_capacity(keys.len());
    for (e, d) in keys {
        out.push(normalized(eval(e, b, ctx)?, *d));
    }
    Ok(out)
}

/// Materializes an input into one batch.
pub fn materialize(input: &mut dyn BatchOperator, width: usize, ctx: &ExecContext) -> Result<Batch> {
    let mut parts = Vec::new();
    while let Some(b) = input.next_batch(ctx)? {
        ctx.reserve(b.approx_size())?;
        parts.push(b);
    }
    if parts.is_empty() {
        return Ok(Batch::new((0..width).map(|_| Vector::null(0)).collect(), 0));
    }
    Ok(Batch::concat(&parts, width))
}

/// The build side of a hash join: rows plus a key index with CSR row lists.
#[derive(Debug)]
pub struct HashTable {
    pub rows: Batch,
    keys: KeyTable,
    /// Rows of key id `k`: `list[offsets[k]..offsets[k + 1]]`, in input order.
    offsets: Vec<u32>,
    list: Vec<u32>,
}

impl HashTable {
    pub fn build(
        rows: Batch,
        keys: &[(Expr, KeyDomain)],
        ctx: &ExecContext,
    ) -> Result<HashTable> {
        let kv = key_vectors(keys, &rows, ctx)?;
        let n = rows.len;
        let mut table = KeyTable::new(keys.len());
        let mut ids = Vec::new();
        table.assign(&kv, n, &mut ids);
        // Rows with a NULL key never match.
        for v in &kv {
            if let Some(valid) = v.validity() {
                for (id, ok) in ids.iter_mut().zip(valid) {
                    if !ok {
                        *id = NO_ROW;
                    }
                }
            }
        }
        let k = table.len();
        let mut offsets = vec![0u32; k + 1];
        for &id in &ids {
            if id != NO_ROW {
                offsets[id as usize + 1] += 1;
            }
        }
        for i in 0..k {
            offsets[i + 1] += offsets[i];
        }
        let mut fill = offsets.clone();
        let mut list = vec![0u32; offsets[k] as usize];
        for (row, &id) in ids.iter().enumerate() {
            if id != NO_ROW {
                list[fill[id as usize] as usize] = row as u32;
                fill[id as usize] += 1;
            }
        }
        ctx.reserve(table.approx_size() + list.len() * 4 + offsets.len() * 4)?;
        Ok(HashTable {
            rows,
            keys: table,
            offsets,
            list,
        })
    }

    fn candidates(&self, id: u32) -> &[u32] {
        if id == NO_ROW {
            return &[];
        }
        let id = id as usize;
        &self.list[self.offsets[id] as usize..self.offsets[id + 1] as usize]
    }
}

/// Hash join: builds `table` from the build input (unless given), then
/// streams the probe input.
pub struct HashJoinOp {
    pub probe: BoxedBatchOp,
    pub build_input: Option<(BoxedBatchOp, usize)>,
    pub table: Option<Arc<HashTable>>,
    pub build_keys: Vec<(Expr, KeyDomain)>,
    pub probe_keys: Vec<(Expr, KeyDomain)>,
    pub spec: JoinSpec,
    pub current: Option<(Batch, Vec<u32>)>,
    pub cursor: Cursor,
    pub caches: Vec<DictCache>,
}

impl HashJoinOp {
    pub fn new(
        probe: BoxedBatchOp,
        build: Option<(BoxedBatchOp, usize)>,
        table: Option<Arc<HashTable>>,
        build_keys: Vec<(Expr, KeyDomain)>,
        probe_keys: Vec<(Expr, KeyDomain)>,
        spec: JoinSpec,
    ) -> HashJoinOp {
        let caches = (0..probe_keys.len()).map(|_| DictCache::default()).collect();
        HashJoinOp {
            probe,
            build_input: build,
            table,
            build_keys,
            probe_keys,
            spec,
            current: None,
            cursor: Cursor::default(),
            caches,
        }
    }
}

/// Builds a hash table by materializing `input`.
pub fn build_table(
    input: &mut dyn BatchOperator,
    width: usize,
    keys: &[(Expr, KeyDomain)],
    ctx: &ExecContext,
) -> Result<HashTable> {
    let rows = materialize(input, width, ctx)?;
    HashTable::build(rows, keys, ctx)
}

impl BatchOperator for HashJoinOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<crate::exec::vector::Batch>> {
        if let Some((mut input, width)) = self.build_input.take() {
            self.table = Some(Arc::new(build_table(&mut *input, width, &self.build_keys, ctx)?));
        }
        let Some(table) = self.table.clone() else {
            return Ok(None);
        };
        loop {
            if let Some((probe, ids)) = &self.current {
                let out = emit(
                    &self.spec,
                    &mut self.cursor,
                    probe,
                    &table.rows,
                    &|p| p as u32,
                    probe.len,
                    &|p| Cand::Rows(table.candidates(ids[p])),
                    ctx,
                )?;
                if out.is_some() {
                    return Ok(out);
                }
                self.current = None;
            }
            let Some(b) = self.probe.next_batch(ctx)? else {
                return Ok(None);
            };
            let kv = key_vectors(&self.probe_keys, &b, ctx)?;
            let mut ids = Vec::new();
            table.keys.lookup(&kv, b.len, &mut ids, &mut self.caches);
            self.cursor = Cursor::default();
            self.current = Some((b, ids));
        }
    }
}

/// Nested-loop join: the right input is materialized once; each left batch
/// is paired with all right rows.
pub struct NestedLoopJoinOp {
    pub left: BoxedBatchOp,
    pub right_input: Option<(BoxedBatchOp, usize)>,
    pub right: Option<Arc<Batch>>,
    pub spec: JoinSpec,
    pub current: Option<Batch>,
    pub cursor: Cursor,
}

impl BatchOperator for NestedLoopJoinOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        if let Some((mut input, width)) = self.right_input.take() {
            self.right = Some(Arc::new(materialize(&mut *input, width, ctx)?));
        }
        let Some(right) = self.right.clone() else {
            return Ok(None);
        };
        loop {
            if let Some(left) = &self.current {
                let n = right.len;
                let out = emit(
                    &self.spec,
                    &mut self.cursor,
                    left,
                    &right,
                    &|p| p as u32,
                    left.len,
                    &|_| Cand::All(n),
                    ctx,
                )?;
                if out.is_some() {
                    return Ok(out);
                }
                self.current = None;
            }
            let Some(b) = self.left.next_batch(ctx)? else {
                return Ok(None);
            };
            self.cursor = Cursor::default();
            self.current = Some(b);
        }
    }
}

/// Sort-merge join over materialized inputs.
pub struct MergeJoinOp {
    pub left: Option<(BoxedBatchOp, usize)>,
    pub right: Option<(BoxedBatchOp, usize)>,
    pub left_keys: Vec<(Expr, KeyDomain)>,
    pub right_keys: Vec<(Expr, KeyDomain)>,
    pub spec: JoinSpec,
    pub state: Option<MergeState>,
    pub cursor: Cursor,
}

pub struct MergeState {
    left: Batch,
    right: Batch,
    /// Left rows in emission order (NULL keys first, then by key).
    order: Vec<u32>,
    /// For each position of `order`: range in `right_sorted`.
    ranges: Vec<(u32, u32)>,
    right_sorted: Vec<u32>,
}

impl MergeJoinOp {
    fn prepare(&mut self, ctx: &ExecContext) -> Result<MergeState> {
        let (Some((mut l, lw)), Some((mut r, rw))) = (self.left.take(), self.right.take()) else {
            return Err(crate::error::Error::internal("merge join prepared twice"));
        };
        let left = materialize(&mut *l, lw, ctx)?;
        let right = materialize(&mut *r, rw, ctx)?;
        let lk = key_vectors(&self.left_keys, &left, ctx)?;
        let rk = key_vectors(&self.right_keys, &right, ctx)?;
        let (nl, nr) = (left.len, right.len);
        // Key columns of both sides concatenated: one typed comparison
        // domain for sorting each side and comparing across sides.
        let combined: Vec<Vector> = lk
            .iter()
            .zip(&rk)
            .map(|(a, b)| Vector::concat(&[a.clone(), b.clone()]))
            .collect();
        let null_key = |pos: usize| combined.iter().any(|c| c.is_null(pos));
        let asc = SortKey {
            expr: Expr::Literal {
                value: crate::types::Value::Null,
                ty: crate::types::DataType::Null,
            },
            descending: false,
            nulls_first: true,
        };
        let cmp = super::ops::KeyComparator::new(combined.clone(), &asc);
        let mut lsorted: Vec<u32> = (0..nl as u32).filter(|&i| !null_key(i as usize)).collect();
        let lnull: Vec<u32> = (0..nl as u32).filter(|&i| null_key(i as usize)).collect();
        let mut rsorted: Vec<u32> = (nl as u32..(nl + nr) as u32)
            .filter(|&i| !null_key(i as usize))
            .collect();
        lsorted.sort_by(|&a, &b| cmp.compare(a as usize, b as usize));
        rsorted.sort_by(|&a, &b| cmp.compare(a as usize, b as usize));
        ctx.check_interrupt()?;
        let mut order = lnull.clone();
        let mut ranges = vec![(0u32, 0u32); lnull.len()];
        let mut j = 0usize;
        let mut i = 0usize;
        while i < lsorted.len() {
            // Group of equal left keys.
            let mut i2 = i + 1;
            while i2 < lsorted.len()
                && cmp.compare(lsorted[i] as usize, lsorted[i2] as usize).is_eq()
            {
                i2 += 1;
            }
            while j < rsorted.len()
                && cmp.compare(rsorted[j] as usize, lsorted[i] as usize).is_lt()
            {
                j += 1;
            }
            let mut j2 = j;
            while j2 < rsorted.len()
                && cmp.compare(rsorted[j2] as usize, lsorted[i] as usize).is_eq()
            {
                j2 += 1;
            }
            for &l in &lsorted[i..i2] {
                order.push(l);
                ranges.push((j as u32, j2 as u32));
            }
            j = j2;
            i = i2;
        }
        let right_sorted = rsorted.into_iter().map(|p| p - nl as u32).collect();
        Ok(MergeState {
            left,
            right,
            order,
            ranges,
            right_sorted,
        })
    }
}

impl BatchOperator for MergeJoinOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        if self.state.is_none() {
            let s = self.prepare(ctx)?;
            self.state = Some(s);
        }
        let Some(s) = &self.state else {
            return Ok(None);
        };
        emit(
            &self.spec,
            &mut self.cursor,
            &s.left,
            &s.right,
            &|p| s.order[p],
            s.order.len(),
            &|p| {
                let (a, b) = s.ranges[p];
                Cand::Rows(&s.right_sorted[a as usize..b as usize])
            },
            ctx,
        )
    }
}
