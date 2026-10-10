//! CRC-32 (ISO-HDLC / zlib / IEEE 802.3): reflected polynomial 0xEDB88320,
//! initial value and final XOR 0xFFFFFFFF (pqcf-v1.md §1).

const POLY: u32 = 0xEDB8_8320;

/// Slicing-by-8 lookup tables, built at compile time.
static TABLES: [[u32; 256]; 8] = build_tables();

const fn build_tables() -> [[u32; 256]; 8] {
    let mut t = [[0u32; 256]; 8];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 { POLY ^ (c >> 1) } else { c >> 1 };
            k += 1;
        }
        t[0][i] = c;
        i += 1;
    }
    let mut j = 1;
    while j < 8 {
        let mut i = 0;
        while i < 256 {
            let prev = t[j - 1][i];
            t[j][i] = (prev >> 8) ^ t[0][(prev & 0xFF) as usize];
            i += 1;
        }
        j += 1;
    }
    t
}

/// Incremental CRC-32 state.
#[derive(Debug, Clone, Copy)]
pub struct Crc32(u32);

impl Default for Crc32 {
    fn default() -> Self {
        Crc32(0xFFFF_FFFF)
    }
}

impl Crc32 {
    pub fn update(&mut self, data: &[u8]) {
        let mut c = self.0;
        let mut chunks = data.chunks_exact(8);
        for b in &mut chunks {
            let lo = c ^ u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
            c = TABLES[7][(lo & 0xFF) as usize]
                ^ TABLES[6][((lo >> 8) & 0xFF) as usize]
                ^ TABLES[5][((lo >> 16) & 0xFF) as usize]
                ^ TABLES[4][(lo >> 24) as usize]
                ^ TABLES[3][b[4] as usize]
                ^ TABLES[2][b[5] as usize]
                ^ TABLES[1][b[6] as usize]
                ^ TABLES[0][b[7] as usize];
        }
        for &b in chunks.remainder() {
            c = (c >> 8) ^ TABLES[0][((c ^ b as u32) & 0xFF) as usize];
        }
        self.0 = c;
    }

    pub fn finish(self) -> u32 {
        self.0 ^ 0xFFFF_FFFF
    }
}

/// CRC-32 of `data`.
pub fn crc32(data: &[u8]) -> u32 {
    let mut c = Crc32::default();
    c.update(data);
    c.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_value() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b""), 0);
        let data: Vec<u8> = (0..1000u32).map(|i| (i * 7 % 251) as u8).collect();
        let mut inc = Crc32::default();
        inc.update(&data[..13]);
        inc.update(&data[13..]);
        assert_eq!(inc.finish(), crc32(&data));
        // Byte-at-a-time reference.
        let mut c = 0xFFFF_FFFFu32;
        for &b in &data {
            c ^= b as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { POLY ^ (c >> 1) } else { c >> 1 };
            }
        }
        assert_eq!(c ^ 0xFFFF_FFFF, crc32(&data));
    }
}
