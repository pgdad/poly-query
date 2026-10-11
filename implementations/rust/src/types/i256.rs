//! A minimal signed 256-bit integer for exact DECIMAL intermediates.
//!
//! Wide decimals (precision 19–38) hold their unscaled values in `i128`
//! (10^38 < 2^127). Products of two such values, rescaled comparisons and
//! long-running sums need more room; `I256` covers them exactly (|x| < 2^255
//! holds e.g. 10^76). Only the operations the engine needs are provided.

use std::cmp::Ordering;

/// Two's-complement 256-bit integer, little-endian 64-bit limbs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct I256([u64; 4]);

impl I256 {
    pub const ZERO: I256 = I256([0; 4]);

    pub fn from_i128(v: i128) -> I256 {
        let lo = v as u128;
        let ext = if v < 0 { u64::MAX } else { 0 };
        I256([lo as u64, (lo >> 64) as u64, ext, ext])
    }

    pub fn is_negative(self) -> bool {
        (self.0[3] as i64) < 0
    }

    pub fn is_zero(self) -> bool {
        self.0 == [0; 4]
    }

    /// The value as i128, if it fits.
    pub fn to_i128(self) -> Option<i128> {
        let lo = self.0[0] as u128 | (self.0[1] as u128) << 64;
        let v = lo as i128;
        let ext = if v < 0 { u64::MAX } else { 0 };
        (self.0[2] == ext && self.0[3] == ext).then_some(v)
    }

    pub fn wrapping_add(self, o: I256) -> I256 {
        let mut out = [0u64; 4];
        let mut carry = false;
        for (i, slot) in out.iter_mut().enumerate() {
            let (s1, c1) = self.0[i].overflowing_add(o.0[i]);
            let (s2, c2) = s1.overflowing_add(carry as u64);
            *slot = s2;
            carry = c1 || c2;
        }
        I256(out)
    }

    pub fn wrapping_neg(self) -> I256 {
        I256(self.0.map(|w| !w)).wrapping_add(I256::from_i128(1))
    }

    pub fn wrapping_sub(self, o: I256) -> I256 {
        self.wrapping_add(o.wrapping_neg())
    }

    /// Magnitude as unsigned limbs (|i256::MIN| does not occur in practice).
    fn magnitude(self) -> [u64; 4] {
        if self.is_negative() {
            self.wrapping_neg().0
        } else {
            self.0
        }
    }

    fn from_magnitude(mag: [u64; 4], negative: bool) -> I256 {
        let v = I256(mag);
        if negative { v.wrapping_neg() } else { v }
    }

    /// Exact product of two i128 values.
    pub fn mul_i128(a: i128, b: i128) -> I256 {
        let (x, y) = (a.unsigned_abs(), b.unsigned_abs());
        let xs = [x as u64, (x >> 64) as u64];
        let ys = [y as u64, (y >> 64) as u64];
        let mut out = [0u64; 4];
        for (i, &xi) in xs.iter().enumerate() {
            let mut carry: u128 = 0;
            for (j, &yj) in ys.iter().enumerate() {
                let t = xi as u128 * yj as u128 + out[i + j] as u128 + carry;
                out[i + j] = t as u64;
                carry = t >> 64;
            }
            out[i + 2] = carry as u64;
        }
        I256::from_magnitude(out, (a < 0) != (b < 0))
    }

    /// Divides by `d` (> 0), truncating toward zero; returns (quotient,
    /// remainder magnitude).
    pub fn div_rem_u64(self, d: u64) -> (I256, u64) {
        let neg = self.is_negative();
        let mut mag = self.magnitude();
        let mut rem: u128 = 0;
        for w in mag.iter_mut().rev() {
            let cur = rem << 64 | *w as u128;
            *w = (cur / d as u128) as u64;
            rem = cur % d as u128;
        }
        (I256::from_magnitude(mag, neg), rem as u64)
    }

    /// Divides by 2^`bits`, rounding half away from zero.
    pub fn shr_round(self, bits: u32) -> I256 {
        if bits == 0 {
            return self;
        }
        let neg = self.is_negative();
        let mag = self.magnitude();
        if bits > 256 {
            return I256::ZERO;
        }
        let bit = |k: u32| -> bool { k < 256 && (mag[(k / 64) as usize] >> (k % 64)) & 1 == 1 };
        let half = bit(bits - 1);
        let mut out = [0u64; 4];
        for (i, slot) in out.iter_mut().enumerate() {
            let src = i as u32 * 64 + bits;
            let (w, b) = ((src / 64) as usize, src % 64);
            let lo = mag.get(w).copied().unwrap_or(0) >> b;
            let hi = if b == 0 {
                0
            } else {
                mag.get(w + 1).copied().unwrap_or(0) << (64 - b)
            };
            *slot = lo | hi;
        }
        let mut q = I256(out);
        if half {
            q = q.wrapping_add(I256::from_i128(1));
        }
        I256::from_magnitude(q.0, neg)
    }

    /// Multiplies by 2^`bits`; None if the result does not fit.
    pub fn checked_shl(self, bits: u32) -> Option<I256> {
        let neg = self.is_negative();
        let mag = self.magnitude();
        let mut out = [0u64; 4];
        for k in 0..256u32 {
            if (mag[(k / 64) as usize] >> (k % 64)) & 1 == 1 {
                let t = k + bits;
                if t >= 255 {
                    return None;
                }
                out[(t / 64) as usize] |= 1 << (t % 64);
            }
        }
        Some(I256::from_magnitude(out, neg))
    }

    /// Decimal text of the integer.
    pub fn to_decimal_string(self) -> String {
        const CHUNK: u64 = 10_000_000_000_000_000_000; // 10^19
        let neg = self.is_negative();
        let mut v = I256(self.magnitude());
        let mut chunks = Vec::new();
        loop {
            let (q, r) = v.div_rem_u64(CHUNK);
            chunks.push(r);
            v = q;
            if v.is_zero() {
                break;
            }
        }
        let mut s = String::new();
        if neg {
            s.push('-');
        }
        let mut iter = chunks.iter().rev();
        if let Some(first) = iter.next() {
            s.push_str(&first.to_string());
        }
        for c in iter {
            s.push_str(&format!("{c:019}"));
        }
        s
    }
}

impl Ord for I256 {
    fn cmp(&self, other: &I256) -> Ordering {
        (self.0[3] as i64)
            .cmp(&(other.0[3] as i64))
            .then(self.0[2].cmp(&other.0[2]))
            .then(self.0[1].cmp(&other.0[1]))
            .then(self.0[0].cmp(&other.0[0]))
    }
}

impl PartialOrd for I256 {
    fn partial_cmp(&self, other: &I256) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_arith() {
        for v in [0i128, 1, -1, i128::MAX, i128::MIN, 12345, -98765] {
            assert_eq!(I256::from_i128(v).to_i128(), Some(v));
        }
        let a = I256::from_i128(i128::MAX);
        let s = a.wrapping_add(a);
        assert_eq!(s.to_i128(), None);
        assert_eq!(s.wrapping_sub(a).to_i128(), Some(i128::MAX));
        assert!(I256::from_i128(-5) < I256::from_i128(3));
        assert!(s > a);
    }

    #[test]
    fn products() {
        let p = I256::mul_i128(10i128.pow(38), -(10i128.pow(38)));
        assert_eq!(p.to_decimal_string(), format!("-1{}", "0".repeat(76)));
        assert_eq!(I256::mul_i128(-7, 6).to_i128(), Some(-42));
        assert_eq!(I256::mul_i128(-7, -6).to_i128(), Some(42));
    }

    #[test]
    fn shifts() {
        assert_eq!(I256::from_i128(5).shr_round(1).to_i128(), Some(3));
        assert_eq!(I256::from_i128(-5).shr_round(1).to_i128(), Some(-3));
        assert_eq!(I256::from_i128(4).shr_round(2).to_i128(), Some(1));
        assert_eq!(I256::from_i128(1).shr_round(300).to_i128(), Some(0));
        assert_eq!(
            I256::from_i128(3).checked_shl(100).unwrap().to_i128(),
            Some(3i128 << 100)
        );
        assert!(I256::from_i128(1).checked_shl(255).is_none());
    }
}
