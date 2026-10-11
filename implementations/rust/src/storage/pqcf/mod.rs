//! PQCF v1/v2 — the PolyQuery columnar file format (spec/storage/pqcf-v1.md;
//! v2 adds 128-bit wide decimal columns, spec/changes/decimal38.md §7).
//!
//! * [`crc`]   — CRC-32 used for metadata and chunk checksums
//! * [`mmap`]  — read-only memory mapping via the system C library
//! * [`read`]  — validation at open and lazy, checked chunk decoding
//! * [`write`] — encoding (PLAIN/DICT/RLE) and the atomic save protocol

pub mod crc;
pub mod mmap;
pub mod read;
pub mod write;

use crate::error::{Error, ErrorCode};
use crate::types::datetime::{MICROS_PER_DAY, days_from_civil};

/// Header and trailer magic.
pub const MAGIC: &[u8; 4] = b"PQCF";
/// The base format version, written for tables without wide decimals.
pub const FORMAT_VERSION: u16 = 1;
/// PQCF v2 (CR-2 §7): v1 plus 128-bit wide decimal columns. Written iff a
/// table has a wide decimal column; the newest version this engine reads.
pub const FORMAT_VERSION_WIDE: u16 = 2;
/// Header size: magic, u16 version, u16 flags.
pub const HEADER_LEN: usize = 8;
/// Footer size: u32 metadata length, u32 metadata CRC, magic.
pub const FOOTER_LEN: usize = 12;

/// Column chunk encodings (pqcf-v1.md §3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Encoding {
    Plain,
    Dict,
    Rle,
}

impl Encoding {
    pub fn name(self) -> &'static str {
        match self {
            Encoding::Plain => "PLAIN",
            Encoding::Dict => "DICT",
            Encoding::Rle => "RLE",
        }
    }

    pub fn parse(s: &str) -> Option<Encoding> {
        match s {
            "PLAIN" => Some(Encoding::Plain),
            "DICT" => Some(Encoding::Dict),
            "RLE" => Some(Encoding::Rle),
            _ => None,
        }
    }
}

/// An index definition stored in the file metadata.
#[derive(Debug, Clone, PartialEq)]
pub struct IndexMeta {
    pub name: String,
    /// Column name as declared in the file.
    pub column: String,
    pub kind: super::IndexKind,
}

fn corrupt(msg: impl Into<String>) -> Error {
    Error::new(ErrorCode::StorageCorrupt, msg)
}

fn unsupported_version(msg: impl Into<String>) -> Error {
    Error::new(ErrorCode::StorageVersionUnsupported, msg)
}

/// Valid DATE day numbers (0001-01-01 … 9999-12-31).
fn date_range() -> std::ops::RangeInclusive<i64> {
    days_from_civil(1, 1, 1)..=days_from_civil(9999, 12, 31)
}

/// Valid TIMESTAMP microseconds (0001-01-01 00:00:00 … 9999-12-31 23:59:59.999999).
fn timestamp_range() -> std::ops::RangeInclusive<i64> {
    days_from_civil(1, 1, 1) * MICROS_PER_DAY
        ..=(days_from_civil(9999, 12, 31) + 1) * MICROS_PER_DAY - 1
}
