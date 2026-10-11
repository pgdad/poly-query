//! Hash table from `i64` keys to dense `u32` ids whose hashes are supplied
//! by the caller — computed a batch at a time by the native `pqk_hash_i64`
//! kernel (`fmix64(key ^ seed)`), or by [`crate::native::fmix64`] for single
//! keys, which yields the same values.
//!
//! The table itself is std's `HashMap` (a SwissTable) keyed by
//! `(key, hash)` with a pass-through hasher, so the precomputed hash is
//! used as is. (Hand-written linear-probing and group-probed tables fed
//! with the same hashes measured 1.5–2× slower.)

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hash, Hasher};

use crate::native::{Kernels, fmix64};

/// Seed of the key hashes.
pub const HASH_SEED: u64 = 0x9e37_79b9_7f4a_7c15;

/// A key with its precomputed hash.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Hashed {
    key: i64,
    hash: u64,
}

impl Hash for Hashed {
    fn hash<H: Hasher>(&self, state: &mut H) {
        state.write_u64(self.hash);
    }
}

/// Hasher returning the precomputed hash written by [`Hashed`].
#[derive(Debug, Default, Clone, Copy)]
struct PassThrough(u64);

impl Hasher for PassThrough {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        // Only `write_u64` is used by `Hashed`; fold anything else in.
        for &b in bytes {
            self.0 = self.0.rotate_left(8) ^ b as u64;
        }
    }

    fn write_u64(&mut self, x: u64) {
        self.0 = x;
    }
}

#[derive(Debug, Clone, Default)]
pub struct I64Table {
    map: HashMap<Hashed, u32, BuildHasherDefault<PassThrough>>,
}

impl I64Table {
    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    /// Id of `key` (whose hash is `hash`), None if absent.
    #[inline]
    pub fn get(&self, key: i64, hash: u64) -> Option<u32> {
        debug_assert_eq!(hash, fmix64(key, HASH_SEED));
        self.map.get(&Hashed { key, hash }).copied()
    }

    /// Id of `key`, inserting it with id `next` if absent.
    #[inline]
    pub fn get_or_insert(&mut self, key: i64, hash: u64, next: u32) -> u32 {
        debug_assert_eq!(hash, fmix64(key, HASH_SEED));
        *self.map.entry(Hashed { key, hash }).or_insert(next)
    }
}

/// Hashes a batch of keys with the kernel (into `out`).
pub fn hash_keys(k: &Kernels, keys: &[i64], out: &mut Vec<u64>) {
    k.hash_i64(keys, HASH_SEED, out);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_get_and_grow() {
        let mut t = I64Table::default();
        for i in 0..10_000i64 {
            let k = i * 7919 - 50_000;
            assert_eq!(t.get_or_insert(k, fmix64(k, HASH_SEED), i as u32), i as u32);
        }
        assert_eq!(t.len(), 10_000);
        for i in 0..10_000i64 {
            let k = i * 7919 - 50_000;
            assert_eq!(t.get(k, fmix64(k, HASH_SEED)), Some(i as u32));
            assert_eq!(t.get_or_insert(k, fmix64(k, HASH_SEED), 99_999), i as u32);
        }
        assert_eq!(t.get(1, fmix64(1, HASH_SEED)), None);
    }

    #[test]
    fn kernel_hashes_match_scalar_hashes() {
        let Some(k) = crate::native::tests::test_kernels() else {
            return;
        };
        let keys: Vec<i64> = (-500..500).map(|i| i * 1_000_003).collect();
        let mut h = Vec::new();
        hash_keys(k, &keys, &mut h);
        let mut t = I64Table::default();
        for (i, (&x, &hx)) in keys.iter().zip(&h).enumerate() {
            t.get_or_insert(x, hx, i as u32);
        }
        for (i, &x) in keys.iter().enumerate() {
            assert_eq!(t.get(x, fmix64(x, HASH_SEED)), Some(i as u32));
        }
    }
}
