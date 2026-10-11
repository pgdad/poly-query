//! Native kernel integration (`native.kernels`, native-kernels.md).
//!
//! `--native-kernels PATH` loads `libpqkernels` once at startup through the
//! dynamic loader ([`ffi`]); [`Kernels`] holds the resolved entry points and
//! exposes safe, slice-based wrappers that check every length the C ABI
//! relies on. Queries run with `native: true` get a `&'static Kernels` in
//! their execution options; operators use it where a kernel applies and
//! fall back to their own code otherwise (and always when no library is
//! loaded). Kernel status flags are honoured exactly: an integer sum that
//! reports overflow is recomputed exactly by the engine.
//!
//! The module also has the bitmap helpers shared by the native code paths
//! (engine vectors keep validity as `bool` arrays, the ABI uses LSB-first
//! bitmaps).

pub mod ffi;

use std::path::Path;
use std::sync::OnceLock;

use ffi::{Library, PQK_ABI_VERSION, PQK_EINVAL, PQK_OK, PQK_OVERFLOW};

/// Comparison operators of the kernels (`PQK_EQ` … `PQK_BETWEEN`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpOp {
    Eq = 0,
    Ne = 1,
    Lt = 2,
    Le = 3,
    Gt = 4,
    Ge = 5,
    /// `a <= x <= b`.
    Between = 6,
}

impl CmpOp {
    /// The operator with its operands swapped (`a < x` ⇔ `x > a`).
    pub fn flipped(self) -> CmpOp {
        match self {
            CmpOp::Lt => CmpOp::Gt,
            CmpOp::Le => CmpOp::Ge,
            CmpOp::Gt => CmpOp::Lt,
            CmpOp::Ge => CmpOp::Le,
            other => other,
        }
    }

    /// Reference semantics of the predicate (tests, scalar fallbacks).
    pub fn eval(self, x: i64, a: i64, b: i64) -> bool {
        match self {
            CmpOp::Eq => x == a,
            CmpOp::Ne => x != a,
            CmpOp::Lt => x < a,
            CmpOp::Le => x <= a,
            CmpOp::Gt => x > a,
            CmpOp::Ge => x >= a,
            CmpOp::Between => a <= x && x <= b,
        }
    }
}

/// Result of a grouped integer sum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupSum {
    /// Every group sum is exact.
    Exact,
    /// Some addition wrapped: the sums were updated with wrapping
    /// arithmetic and must be recomputed exactly by the caller.
    Wrapped,
}

/// The resolved entry points of a loaded `libpqkernels`.
pub struct Kernels {
    variant: String,
    available: String,
    filter_i64: ffi::FilterI64Fn,
    filter_i64_bitmap: ffi::FilterI64BitmapFn,
    sum_i64: ffi::SumI64Fn,
    minmax_i64: ffi::MinMaxI64Fn,
    minmax_f64: ffi::MinMaxF64Fn,
    count_i64: ffi::CountI64Fn,
    bitmap_and: ffi::BitmapBinFn,
    bitmap_or: ffi::BitmapBinFn,
    bitmap_andnot: ffi::BitmapBinFn,
    bitmap_popcount: ffi::PopcountFn,
    hash_i64: ffi::HashI64Fn,
    compare_i64: ffi::CompareI64Fn,
    group_sum_i64: ffi::GroupSumI64Fn,
    gather_i64: ffi::GatherI64Fn,
    _lib: Library,
}

impl std::fmt::Debug for Kernels {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Kernels")
            .field("variant", &self.variant)
            .finish_non_exhaustive()
    }
}

/// Number of bytes of a bitmap of `n` bits.
#[inline]
pub fn bitmap_bytes(n: usize) -> usize {
    n.div_ceil(8)
}

fn check_validity(validity: Option<&[u8]>, n: usize) -> *const u8 {
    match validity {
        Some(v) => {
            assert!(v.len() >= bitmap_bytes(n), "validity bitmap too short");
            v.as_ptr()
        }
        None => std::ptr::null(),
    }
}

/// Resolves a symbol as a function pointer of type `F`.
///
/// # Safety
/// `F` must be the exact `extern "C"` function pointer type of the symbol.
unsafe fn resolve<F: Copy>(lib: &Library, name: &str) -> Result<F, String> {
    let p = lib.symbol(name)?;
    debug_assert_eq!(std::mem::size_of::<F>(), std::mem::size_of_val(&p));
    // SAFETY: guaranteed by the caller (types mirror pq_kernels.h).
    Ok(unsafe { std::mem::transmute_copy::<*mut std::ffi::c_void, F>(&p) })
}

impl Kernels {
    /// Loads the library at `path`, checks its ABI version and runs the
    /// CPU-feature dispatch (`pqk_init`, honouring `PQ_KERNELS_VARIANT`).
    pub fn load(path: &Path) -> Result<Kernels, String> {
        let lib = Library::open(path)?;
        // SAFETY: every type below mirrors the declaration in pq_kernels.h.
        unsafe {
            let abi: ffi::AbiVersionFn = resolve(&lib, "pqk_abi_version")?;
            let v = abi();
            if v != PQK_ABI_VERSION {
                return Err(format!(
                    "unsupported kernel ABI version {v} (expected {PQK_ABI_VERSION})"
                ));
            }
            let init: ffi::InitFn = resolve(&lib, "pqk_init")?;
            if init() != PQK_OK {
                return Err("pqk_init failed".to_string());
            }
            let variant: ffi::VariantFn = resolve(&lib, "pqk_variant")?;
            let available: ffi::VariantFn = resolve(&lib, "pqk_available_variants")?;
            Ok(Kernels {
                variant: ffi::static_str(variant()),
                available: ffi::static_str(available()),
                filter_i64: resolve(&lib, "pqk_filter_i64")?,
                filter_i64_bitmap: resolve(&lib, "pqk_filter_i64_bitmap")?,
                sum_i64: resolve(&lib, "pqk_sum_i64")?,
                minmax_i64: resolve(&lib, "pqk_minmax_i64")?,
                minmax_f64: resolve(&lib, "pqk_minmax_f64")?,
                count_i64: resolve(&lib, "pqk_count_i64")?,
                bitmap_and: resolve(&lib, "pqk_bitmap_and")?,
                bitmap_or: resolve(&lib, "pqk_bitmap_or")?,
                bitmap_andnot: resolve(&lib, "pqk_bitmap_andnot")?,
                bitmap_popcount: resolve(&lib, "pqk_bitmap_popcount")?,
                hash_i64: resolve(&lib, "pqk_hash_i64")?,
                compare_i64: resolve(&lib, "pqk_compare_i64")?,
                group_sum_i64: resolve(&lib, "pqk_group_sum_i64")?,
                gather_i64: resolve(&lib, "pqk_gather_i64")?,
                _lib: lib,
            })
        }
    }

    /// Name of the active variant (`reference`, `scalar`, `avx2`, …).
    pub fn variant(&self) -> &str {
        &self.variant
    }

    /// Variants usable on this CPU.
    pub fn available_variants(&self) -> &str {
        &self.available
    }

    /// Appends to `out` the indices of the valid rows satisfying
    /// `op(data[i], a, b)`; returns how many were appended.
    pub fn filter_i64(
        &self,
        data: &[i64],
        validity: Option<&[u8]>,
        op: CmpOp,
        a: i64,
        b: i64,
        out: &mut Vec<u32>,
    ) -> usize {
        let n = data.len();
        assert!(n < u32::MAX as usize);
        let v = check_validity(validity, n);
        let base = out.len();
        out.reserve(n);
        // SAFETY: `data` has n elements, the bitmap ceil(n/8) bytes, and
        // `out` capacity for n more indices; written entries are counted.
        unsafe {
            let k = (self.filter_i64)(
                data.as_ptr(),
                v,
                n,
                op as i32,
                a,
                b,
                out.as_mut_ptr().add(base),
            );
            assert!(k <= n, "invalid kernel operator");
            out.set_len(base + k);
            k
        }
    }

    /// Writes the predicate result as a bitmap into `out` (resized to
    /// ceil(n/8) bytes, trailing bits zero); returns the number of set bits.
    pub fn filter_i64_bitmap(
        &self,
        data: &[i64],
        validity: Option<&[u8]>,
        op: CmpOp,
        a: i64,
        b: i64,
        out: &mut Vec<u8>,
    ) -> usize {
        let n = data.len();
        let v = check_validity(validity, n);
        out.clear();
        out.resize(bitmap_bytes(n), 0);
        // SAFETY: lengths as documented in pq_kernels.h.
        let k = unsafe {
            (self.filter_i64_bitmap)(data.as_ptr(), v, n, op as i32, a, b, out.as_mut_ptr())
        };
        assert!(k <= n, "invalid kernel operator");
        k
    }

    /// Number of valid rows satisfying the predicate.
    pub fn count_i64(
        &self,
        data: &[i64],
        validity: Option<&[u8]>,
        op: CmpOp,
        a: i64,
        b: i64,
    ) -> usize {
        let n = data.len();
        let v = check_validity(validity, n);
        // SAFETY: lengths as documented.
        let k = unsafe { (self.count_i64)(data.as_ptr(), v, n, op as i32, a, b) };
        assert!(k <= n, "invalid kernel operator");
        k
    }

    /// Exact sum of the valid values; None if it is outside the INT64 range
    /// (`PQK_OVERFLOW`).
    pub fn sum_i64(&self, data: &[i64], validity: Option<&[u8]>) -> Option<i64> {
        let v = check_validity(validity, data.len());
        let mut sum = 0i64;
        // SAFETY: lengths as documented; `sum` is a valid out pointer.
        let status = unsafe { (self.sum_i64)(data.as_ptr(), v, data.len(), &mut sum) };
        match status {
            PQK_OK => Some(sum),
            _ => None,
        }
    }

    /// (min, max) of the valid values, None if there are none.
    pub fn minmax_i64(&self, data: &[i64], validity: Option<&[u8]>) -> Option<(i64, i64)> {
        let v = check_validity(validity, data.len());
        let (mut lo, mut hi) = (0i64, 0i64);
        // SAFETY: lengths as documented; out pointers are valid.
        let k = unsafe { (self.minmax_i64)(data.as_ptr(), v, data.len(), &mut lo, &mut hi) };
        (k > 0).then_some((lo, hi))
    }

    /// (min, max) of the valid (finite) values, None if there are none.
    pub fn minmax_f64(&self, data: &[f64], validity: Option<&[u8]>) -> Option<(f64, f64)> {
        let v = check_validity(validity, data.len());
        let (mut lo, mut hi) = (0f64, 0f64);
        // SAFETY: lengths as documented; out pointers are valid.
        let k = unsafe { (self.minmax_f64)(data.as_ptr(), v, data.len(), &mut lo, &mut hi) };
        (k > 0).then_some((lo, hi))
    }

    fn bitmap_binary(&self, f: ffi::BitmapBinFn, a: &[u8], b: &[u8], out: &mut [u8]) {
        let n = out.len();
        assert!(a.len() >= n && b.len() >= n);
        // SAFETY: all three buffers hold at least n bytes.
        unsafe { f(a.as_ptr(), b.as_ptr(), out.as_mut_ptr(), n) }
    }

    /// `out = a & b` (bytewise over `out.len()` bytes).
    pub fn bitmap_and(&self, a: &[u8], b: &[u8], out: &mut [u8]) {
        self.bitmap_binary(self.bitmap_and, a, b, out);
    }

    /// `a &= b` in place.
    pub fn bitmap_and_assign(&self, a: &mut [u8], b: &[u8]) {
        let n = a.len();
        assert!(b.len() >= n);
        // SAFETY: the ABI allows `out` to alias `a`; both hold n bytes.
        unsafe { (self.bitmap_and)(a.as_ptr(), b.as_ptr(), a.as_mut_ptr(), n) }
    }

    /// `a |= b` in place.
    pub fn bitmap_or_assign(&self, a: &mut [u8], b: &[u8]) {
        let n = a.len();
        assert!(b.len() >= n);
        // SAFETY: the ABI allows `out` to alias `a`; both hold n bytes.
        unsafe { (self.bitmap_or)(a.as_ptr(), b.as_ptr(), a.as_mut_ptr(), n) }
    }

    /// `out = a & !b`.
    pub fn bitmap_andnot(&self, a: &[u8], b: &[u8], out: &mut [u8]) {
        self.bitmap_binary(self.bitmap_andnot, a, b, out);
    }

    /// Number of set bits among the first `nbits` bits.
    pub fn popcount(&self, bits: &[u8], nbits: usize) -> usize {
        assert!(bits.len() >= bitmap_bytes(nbits));
        // SAFETY: the bitmap holds ceil(nbits/8) bytes.
        unsafe { (self.bitmap_popcount)(bits.as_ptr(), nbits) }
    }

    /// `out[i] = fmix64(data[i] ^ seed)` (out is resized to `data.len()`).
    pub fn hash_i64(&self, data: &[i64], seed: u64, out: &mut Vec<u64>) {
        out.clear();
        out.reserve(data.len());
        // SAFETY: `out` has capacity for data.len() hashes, all written.
        unsafe {
            (self.hash_i64)(data.as_ptr(), data.len(), seed, out.as_mut_ptr());
            out.set_len(data.len());
        }
    }

    /// Element-wise `op(a[i], b[i])` as a bitmap in `out` (resized);
    /// returns the number of set bits. `op` must not be `Between`.
    pub fn compare_i64(&self, a: &[i64], b: &[i64], op: CmpOp, out: &mut Vec<u8>) -> usize {
        assert_eq!(a.len(), b.len());
        assert!(op != CmpOp::Between);
        let n = a.len();
        out.clear();
        out.resize(bitmap_bytes(n), 0);
        // SAFETY: both inputs hold n values, `out` ceil(n/8) bytes.
        let k =
            unsafe { (self.compare_i64)(a.as_ptr(), b.as_ptr(), n, op as i32, out.as_mut_ptr()) };
        assert!(k <= n, "invalid kernel operator");
        k
    }

    /// For valid rows: `sums[gids[i]] += values[i]` (wrapping) and
    /// `counts[gids[i]] += 1`. Every group id must be `< sums.len()`.
    pub fn group_sum_i64(
        &self,
        gids: &[u32],
        values: &[i64],
        validity: Option<&[u8]>,
        sums: &mut [i64],
        counts: &mut [i64],
    ) -> GroupSum {
        let n = values.len();
        assert_eq!(gids.len(), n);
        assert_eq!(sums.len(), counts.len());
        let v = check_validity(validity, n);
        // SAFETY: lengths checked above; the kernel validates group ids
        // (PQK_EINVAL leaves the outputs untouched).
        let status = unsafe {
            (self.group_sum_i64)(
                gids.as_ptr(),
                values.as_ptr(),
                v,
                n,
                sums.as_mut_ptr(),
                counts.as_mut_ptr(),
                sums.len(),
            )
        };
        match status {
            PQK_OK => GroupSum::Exact,
            PQK_OVERFLOW => GroupSum::Wrapped,
            PQK_EINVAL => panic!("group id out of range in native group sum"),
            other => panic!("unexpected native kernel status {other}"),
        }
    }

    /// Appends `data[idx[j]]` for every `j` to `out`.
    pub fn gather_i64(&self, data: &[i64], idx: &[u32], out: &mut Vec<i64>) {
        assert!(idx.iter().all(|&i| (i as usize) < data.len()));
        let base = out.len();
        out.reserve(idx.len());
        // SAFETY: every index is in bounds (checked); `out` has capacity.
        unsafe {
            (self.gather_i64)(
                data.as_ptr(),
                idx.as_ptr(),
                idx.len(),
                out.as_mut_ptr().add(base),
            );
            out.set_len(base + idx.len());
        }
    }
}

/// The process-wide loaded library (set once at startup).
static LOADED: OnceLock<Option<Kernels>> = OnceLock::new();

/// Loads the library given with `--native-kernels` (once per process).
/// Returns the kernels, or the reason the library could not be used (the
/// engine then runs without it).
pub fn init(path: Option<&Path>) -> Result<Option<&'static Kernels>, String> {
    let mut error = None;
    let loaded = LOADED.get_or_init(|| match path {
        None => None,
        Some(p) => match Kernels::load(p) {
            Ok(k) => Some(k),
            Err(e) => {
                error = Some(e);
                None
            }
        },
    });
    match error {
        Some(e) => Err(e),
        None => Ok(loaded.as_ref()),
    }
}

/// The loaded kernels, if any.
pub fn loaded() -> Option<&'static Kernels> {
    LOADED.get().and_then(Option::as_ref)
}

// ------------------------------------------------------------ bitmaps

/// Packs a `bool` validity array into an LSB-first bitmap.
pub fn pack_bools(flags: &[bool], out: &mut Vec<u8>) {
    out.clear();
    out.reserve(bitmap_bytes(flags.len()));
    let mut chunks = flags.chunks_exact(8);
    for c in &mut chunks {
        let mut b = 0u8;
        for (k, &f) in c.iter().enumerate() {
            b |= (f as u8) << k;
        }
        out.push(b);
    }
    let rest = chunks.remainder();
    if !rest.is_empty() {
        let mut b = 0u8;
        for (k, &f) in rest.iter().enumerate() {
            b |= (f as u8) << k;
        }
        out.push(b);
    }
}

/// Appends the positions of the set bits among the first `n` bits.
pub fn bitmap_selection(bits: &[u8], n: usize, out: &mut Vec<u32>) {
    for (byte_index, &b) in bits[..bitmap_bytes(n)].iter().enumerate() {
        let mut b = b;
        while b != 0 {
            let k = b.trailing_zeros() as usize;
            let i = byte_index * 8 + k;
            if i < n {
                out.push(i as u32);
            }
            b &= b - 1;
        }
    }
}

/// Unpacks the first `n` bits into booleans.
pub fn bitmap_bools(bits: &[u8], n: usize) -> Vec<bool> {
    (0..n).map(|i| bits[i / 8] >> (i % 8) & 1 == 1).collect()
}

/// The reference fmix64 hash of `pqk_hash_i64` (for single values; batch
/// hashing calls the kernel, and both must agree).
#[inline]
pub fn fmix64(x: i64, seed: u64) -> u64 {
    let mut k = (x as u64) ^ seed;
    k ^= k >> 33;
    k = k.wrapping_mul(0xff51_afd7_ed55_8ccd);
    k ^= k >> 33;
    k = k.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    k ^= k >> 33;
    k
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The library built by `make -C native-kernels`, if present.
    pub(crate) fn test_kernels() -> Option<&'static Kernels> {
        static K: OnceLock<Option<Kernels>> = OnceLock::new();
        K.get_or_init(|| {
            let path = std::env::var("PQ_TEST_NATIVE_KERNELS").map_or_else(
                |_| {
                    Path::new(env!("CARGO_MANIFEST_DIR"))
                        .join("../../native-kernels/build/x86_64/libpqkernels.so")
                },
                std::path::PathBuf::from,
            );
            Kernels::load(&path).ok()
        })
        .as_ref()
    }

    #[test]
    fn bitmap_helpers() {
        let flags = [
            true, false, true, true, false, false, false, false, true, true,
        ];
        let mut bits = Vec::new();
        pack_bools(&flags, &mut bits);
        assert_eq!(bits, vec![0b0000_1101, 0b0000_0011]);
        let mut sel = Vec::new();
        bitmap_selection(&bits, flags.len(), &mut sel);
        assert_eq!(sel, vec![0, 2, 3, 8, 9]);
        assert_eq!(bitmap_bools(&bits, flags.len()), flags);
    }

    #[test]
    fn missing_library_is_an_error() {
        assert!(Kernels::load(Path::new("/nonexistent/libpqkernels.so")).is_err());
    }

    #[test]
    fn kernels_match_reference_semantics() {
        let Some(k) = test_kernels() else {
            eprintln!("libpqkernels not built; skipping");
            return;
        };
        let data: Vec<i64> = (0..1000).map(|i| (i * 7919 % 211) - 100).collect();
        let valid: Vec<bool> = (0..1000).map(|i| i % 13 != 0).collect();
        let mut vbits = Vec::new();
        pack_bools(&valid, &mut vbits);
        for op in [
            CmpOp::Eq,
            CmpOp::Ne,
            CmpOp::Lt,
            CmpOp::Le,
            CmpOp::Gt,
            CmpOp::Ge,
            CmpOp::Between,
        ] {
            let expect: Vec<u32> = (0..data.len())
                .filter(|&i| valid[i] && op.eval(data[i], -5, 40))
                .map(|i| i as u32)
                .collect();
            let mut idx = Vec::new();
            k.filter_i64(&data, Some(&vbits), op, -5, 40, &mut idx);
            assert_eq!(idx, expect);
            let mut bits = Vec::new();
            let c = k.filter_i64_bitmap(&data, Some(&vbits), op, -5, 40, &mut bits);
            let mut sel = Vec::new();
            bitmap_selection(&bits, data.len(), &mut sel);
            assert_eq!(sel, expect);
            assert_eq!(c, expect.len());
            assert_eq!(k.count_i64(&data, Some(&vbits), op, -5, 40), expect.len());
            assert_eq!(k.popcount(&bits, data.len()), expect.len());
        }
        let exact: i64 = data
            .iter()
            .zip(&valid)
            .filter(|(_, v)| **v)
            .map(|(x, _)| *x)
            .sum();
        assert_eq!(k.sum_i64(&data, Some(&vbits)), Some(exact));
        assert_eq!(k.sum_i64(&[i64::MAX, 1], None), None);
        assert_eq!(k.sum_i64(&[i64::MAX, 1, -2], None), Some(i64::MAX - 1));
        assert_eq!(k.minmax_i64(&[3, -9, 4], None), Some((-9, 4)));
        assert_eq!(k.minmax_i64(&[3], Some(&[0])), None);
        assert_eq!(k.minmax_f64(&[0.5, -2.5, 9.0], None), Some((-2.5, 9.0)));
        let mut h = Vec::new();
        k.hash_i64(&data, 42, &mut h);
        for (x, hx) in data.iter().zip(&h) {
            assert_eq!(*hx, fmix64(*x, 42));
        }
        let mut out = Vec::new();
        k.gather_i64(&data, &[5, 1, 999], &mut out);
        assert_eq!(out, vec![data[5], data[1], data[999]]);
        let mut sums = vec![0i64; 3];
        let mut counts = vec![0i64; 3];
        let st = k.group_sum_i64(&[0, 1, 2, 1], &[5, 6, 7, 8], None, &mut sums, &mut counts);
        assert_eq!(st, GroupSum::Exact);
        assert_eq!((sums, counts), (vec![5, 14, 7], vec![1, 2, 1]));
        let mut sums = vec![i64::MAX];
        let mut counts = vec![0];
        let st = k.group_sum_i64(&[0], &[1], None, &mut sums, &mut counts);
        assert_eq!(st, GroupSum::Wrapped);
        let mut cmp = Vec::new();
        let c = k.compare_i64(&[1, 5, 3], &[2, 5, 1], CmpOp::Le, &mut cmp);
        assert_eq!((c, cmp[0]), (2, 0b011));
        let mut a = vec![0b1100u8];
        k.bitmap_and_assign(&mut a, &[0b1010]);
        assert_eq!(a, vec![0b1000]);
        k.bitmap_or_assign(&mut a, &[0b0001]);
        assert_eq!(a, vec![0b1001]);
        let mut o = vec![0u8];
        k.bitmap_andnot(&[0b1111], &[0b0101], &mut o);
        assert_eq!(o, vec![0b1010]);
    }
}
