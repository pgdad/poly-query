//! Open-addressing hash table from `i64` keys to dense `u32` ids whose
//! hashes are supplied by the caller — computed a batch at a time by the
//! native `pqk_hash_i64` kernel (`fmix64(key ^ seed)`), or by
//! [`crate::native::fmix64`] for single keys, which yields the same values.
//! Linear probing over a power-of-two slot array kept at most half full.

use crate::native::{Kernels, fmix64};

/// Seed of the key hashes.
pub const HASH_SEED: u64 = 0x9e37_79b9_7f4a_7c15;

const EMPTY: u32 = u32::MAX;

#[derive(Debug, Clone)]
pub struct I64Table {
    keys: Vec<i64>,
    ids: Vec<u32>,
    mask: usize,
    len: usize,
}

impl Default for I64Table {
    fn default() -> Self {
        I64Table {
            keys: vec![0; 16],
            ids: vec![EMPTY; 16],
            mask: 15,
            len: 0,
        }
    }
}

impl I64Table {
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Id of `key` (with hash `hash`), None if absent.
    #[inline]
    pub fn get(&self, key: i64, hash: u64) -> Option<u32> {
        let mut i = hash as usize & self.mask;
        loop {
            let id = self.ids[i];
            if id == EMPTY {
                return None;
            }
            if self.keys[i] == key {
                return Some(id);
            }
            i = (i + 1) & self.mask;
        }
    }

    /// Id of `key`, inserting it with id `next` if absent.
    #[inline]
    pub fn get_or_insert(&mut self, key: i64, hash: u64, next: u32) -> u32 {
        debug_assert_ne!(next, EMPTY);
        if (self.len + 1) * 2 > self.ids.len() {
            self.grow();
        }
        let mut i = hash as usize & self.mask;
        loop {
            let id = self.ids[i];
            if id == EMPTY {
                self.keys[i] = key;
                self.ids[i] = next;
                self.len += 1;
                return next;
            }
            if self.keys[i] == key {
                return id;
            }
            i = (i + 1) & self.mask;
        }
    }

    /// Doubles the slot array and reinserts every key.
    fn grow(&mut self) {
        let size = self.ids.len() * 2;
        let old_keys = std::mem::replace(&mut self.keys, vec![0; size]);
        let old_ids = std::mem::replace(&mut self.ids, vec![EMPTY; size]);
        self.mask = size - 1;
        for (k, id) in old_keys.into_iter().zip(old_ids) {
            if id == EMPTY {
                continue;
            }
            let mut i = fmix64(k, HASH_SEED) as usize & self.mask;
            while self.ids[i] != EMPTY {
                i = (i + 1) & self.mask;
            }
            self.keys[i] = k;
            self.ids[i] = id;
        }
    }

    /// Approximate memory held.
    pub fn approx_size(&self) -> usize {
        self.ids.len() * 12
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
}
