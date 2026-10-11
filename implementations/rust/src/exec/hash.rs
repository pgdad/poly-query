//! A fast, non-cryptographic hasher for execution-time hash tables (join
//! tables, group interners, DISTINCT sets). Keys are engine-internal values,
//! so HashDoS resistance (std's SipHash) is not needed; a multiply-rotate
//! hash is several times faster for the integer keys that dominate.

use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasherDefault, Hasher};

const SEED: u64 = 0xf135_7aea_2e62_a9c5;

#[derive(Debug, Default, Clone, Copy)]
pub struct FastHasher {
    hash: u64,
}

impl FastHasher {
    #[inline]
    fn add(&mut self, x: u64) {
        self.hash = self.hash.wrapping_add(x).wrapping_mul(SEED);
    }
}

impl Hasher for FastHasher {
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        let mut chunks = bytes.chunks_exact(8);
        for c in &mut chunks {
            self.add(u64::from_le_bytes([
                c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7],
            ]));
        }
        let rest = chunks.remainder();
        if !rest.is_empty() {
            let mut buf = [0u8; 8];
            buf[..rest.len()].copy_from_slice(rest);
            self.add(u64::from_le_bytes(buf) ^ ((rest.len() as u64) << 59));
        }
    }

    #[inline]
    fn write_u8(&mut self, i: u8) {
        self.add(i as u64);
    }

    #[inline]
    fn write_u32(&mut self, i: u32) {
        self.add(i as u64);
    }

    #[inline]
    fn write_u64(&mut self, i: u64) {
        self.add(i);
    }

    #[inline]
    fn write_i64(&mut self, i: i64) {
        self.add(i as u64);
    }

    #[inline]
    fn write_usize(&mut self, i: usize) {
        self.add(i as u64);
    }

    #[inline]
    fn finish(&self) -> u64 {
        // Moves the well-mixed high bits down to where hash tables index.
        self.hash.rotate_left(26)
    }
}

pub type FastBuild = BuildHasherDefault<FastHasher>;
pub type FastMap<K, V> = HashMap<K, V, FastBuild>;
pub type FastSet<K> = HashSet<K, FastBuild>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_work() {
        let mut m: FastMap<i64, u32> = FastMap::default();
        for i in 0..10_000 {
            m.insert(i * 7, i as u32);
        }
        assert_eq!(m.get(&700), Some(&100));
        let mut s: FastSet<String> = FastSet::default();
        s.insert("abc".into());
        s.insert("abcdefghij".into());
        assert!(s.contains("abcdefghij"));
        assert!(!s.contains("abcdefghi"));
    }
}
