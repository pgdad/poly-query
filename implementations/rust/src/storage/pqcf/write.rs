//! PQCF writing (pqcf-v1.md §2, §3, §5): per-chunk encoding selection
//! (PLAIN / DICT / RLE), chunk statistics, and the crash-safe save protocol
//! (temporary file in the target directory, fsync, atomic rename, directory
//! fsync).

use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

use super::{Encoding, FORMAT_VERSION, IndexMeta, MAGIC, crc::crc32};
use crate::error::{Error, ErrorCode, Result};
use crate::json::Json;
use crate::storage::Table;
use crate::storage::column::{Column, ColumnData};
use crate::types::{DataType, Value};

/// Default rows per row group.
pub const DEFAULT_ROW_GROUP_SIZE: usize = 65_536;

/// Longest STRING min/max statistic written to the metadata.
const MAX_STRING_STAT_BYTES: usize = 1024;

/// The `encoding` save option.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EncodingChoice {
    /// Per chunk: RLE when runs < n/4, DICT when distinct < n/2, else PLAIN.
    #[default]
    Auto,
    Plain,
    /// DICT for STRING chunks, PLAIN otherwise.
    Dict,
    /// RLE for BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP chunks, PLAIN otherwise.
    Rle,
}

impl EncodingChoice {
    pub fn parse(s: &str) -> Option<EncodingChoice> {
        match s.to_ascii_lowercase().as_str() {
            "auto" => Some(EncodingChoice::Auto),
            "plain" => Some(EncodingChoice::Plain),
            "dict" => Some(EncodingChoice::Dict),
            "rle" => Some(EncodingChoice::Rle),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SaveOptions {
    pub row_group_size: usize,
    pub encoding: EncodingChoice,
}

impl Default for SaveOptions {
    fn default() -> Self {
        SaveOptions {
            row_group_size: DEFAULT_ROW_GROUP_SIZE,
            encoding: EncodingChoice::Auto,
        }
    }
}

/// An encoded column chunk.
struct Chunk {
    encoding: Encoding,
    null_count: usize,
    min: Option<Value>,
    max: Option<Value>,
}

fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn put_i64(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(&v.to_le_bytes());
}

/// Writes STRING PLAIN offsets and bytes for `strs`.
fn put_strings<'a>(out: &mut Vec<u8>, strs: impl Iterator<Item = &'a str> + Clone) {
    let mut off: u32 = 0;
    put_u32(out, 0);
    for s in strs.clone() {
        off += s.len() as u32;
        put_u32(out, off);
    }
    for s in strs {
        out.extend_from_slice(s.as_bytes());
    }
}

/// Number of runs of the integer representation over `[start, start+n)`;
/// NULL slots extend the current run.
fn count_runs(col: &Column, start: usize, n: usize) -> usize {
    let mut runs = 0;
    let mut last: Option<i64> = None;
    for i in start..start + n {
        if col.is_null(i) {
            if last.is_none() {
                last = Some(0);
                runs += 1;
            }
            continue;
        }
        let v = col.int_repr(i).unwrap_or(0);
        if last != Some(v) {
            last = Some(v);
            runs += 1;
        }
    }
    runs
}

fn write_rle(col: &Column, start: usize, n: usize, out: &mut Vec<u8>) {
    let mut runs: Vec<(i64, u32)> = Vec::new();
    for i in start..start + n {
        let v = if col.is_null(i) {
            runs.last().map_or(0, |r| r.0)
        } else {
            col.int_repr(i).unwrap_or(0)
        };
        match runs.last_mut() {
            Some(r) if r.0 == v => r.1 += 1,
            _ => runs.push((v, 1)),
        }
    }
    put_u32(out, runs.len() as u32);
    for (v, len) in runs {
        put_i64(out, v);
        put_u32(out, len);
    }
}

/// Encodes rows `[start, start+n)` of `col` into `out`.
fn encode_chunk(
    col: &Column,
    start: usize,
    n: usize,
    choice: EncodingChoice,
    out: &mut Vec<u8>,
) -> Chunk {
    let null_count = (start..start + n).filter(|&i| col.is_null(i)).count();
    if null_count > 0 {
        col.validity.write_lsb_bytes(start, n, out);
    }
    let mut min: Option<Value> = None;
    let mut max: Option<Value> = None;
    for i in start..start + n {
        let v = col.value(i);
        if v.is_null() {
            continue;
        }
        if min.as_ref().is_none_or(|m| v.sort_cmp(m) == Ordering::Less) {
            min = Some(v.clone());
        }
        if max
            .as_ref()
            .is_none_or(|m| v.sort_cmp(m) == Ordering::Greater)
        {
            max = Some(v);
        }
    }
    let ty = col.data_type;
    let encoding = match ty {
        DataType::String => {
            let use_dict = match choice {
                EncodingChoice::Dict => true,
                EncodingChoice::Auto => {
                    let mut distinct = std::collections::HashSet::new();
                    for i in start..start + n {
                        if let Some(s) = col.str_at(i) {
                            distinct.insert(s);
                        }
                    }
                    distinct.len() * 2 < n
                }
                _ => false,
            };
            if use_dict {
                Encoding::Dict
            } else {
                Encoding::Plain
            }
        }
        DataType::Float64 => Encoding::Plain,
        _ => match choice {
            EncodingChoice::Rle => Encoding::Rle,
            EncodingChoice::Auto if count_runs(col, start, n) * 4 < n => Encoding::Rle,
            _ => Encoding::Plain,
        },
    };
    let rows = start..start + n;
    match (encoding, &col.data) {
        (Encoding::Rle, _) => write_rle(col, start, n, out),
        (Encoding::Dict, _) => {
            let mut lookup: HashMap<&str, u32> = HashMap::new();
            let mut dict: Vec<&str> = Vec::new();
            let mut codes = Vec::with_capacity(n);
            for i in rows {
                codes.push(match col.str_at(i) {
                    None => 0,
                    Some(s) => *lookup.entry(s).or_insert_with(|| {
                        dict.push(s);
                        (dict.len() - 1) as u32
                    }),
                });
            }
            put_u32(out, dict.len() as u32);
            put_strings(out, dict.iter().copied());
            for c in codes {
                put_u32(out, c);
            }
        }
        (_, ColumnData::Boolean(v)) => {
            let base = out.len();
            out.resize(base + n.div_ceil(8), 0);
            for (k, i) in rows.enumerate() {
                if !col.is_null(i) && v[i] {
                    out[base + k / 8] |= 1 << (k % 8);
                }
            }
        }
        (_, ColumnData::Float64(v)) => {
            for i in rows {
                let f = if col.is_null(i) { 0.0 } else { v[i] };
                out.extend_from_slice(&f.to_le_bytes());
            }
        }
        (_, ColumnData::Date(v)) => {
            for i in rows {
                let d = if col.is_null(i) { 0 } else { v[i] };
                out.extend_from_slice(&d.to_le_bytes());
            }
        }
        (_, ColumnData::Int64(v) | ColumnData::Decimal(v) | ColumnData::Timestamp(v)) => {
            for i in rows {
                put_i64(out, if col.is_null(i) { 0 } else { v[i] });
            }
        }
        (_, ColumnData::String(_) | ColumnData::Dict { .. }) => {
            let strs = rows.map(|i| col.str_at(i).unwrap_or(""));
            put_strings(out, strs);
        }
    }
    if ty == DataType::String {
        let long =
            |v: &Option<Value>| matches!(v, Some(Value::Str(s)) if s.len() > MAX_STRING_STAT_BYTES);
        if long(&min) || long(&max) {
            min = None;
            max = None;
        }
    }
    Chunk {
        encoding,
        null_count,
        min,
        max,
    }
}

fn stat_json(v: &Option<Value>, ty: DataType) -> Json {
    match v {
        None => Json::Null,
        Some(v) => {
            let mut s = String::new();
            v.write_json(ty, &mut s);
            Json::Raw(s)
        }
    }
}

fn write_error(display: &str, e: std::io::Error) -> Error {
    Error::new(ErrorCode::IoError, format!("cannot write '{display}': {e}"))
}

/// Serializes `table` (with index definitions `indexes`) as PQCF v1 to
/// `out`, returning the number of bytes written.
fn write_file(
    table: &Table,
    columns: &[Cow<'_, Column>],
    indexes: &[IndexMeta],
    opts: &SaveOptions,
    out: &mut impl Write,
) -> std::io::Result<u64> {
    let mut pos: u64 = 0;
    let mut header = Vec::with_capacity(8);
    header.extend_from_slice(MAGIC);
    header.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    header.extend_from_slice(&0u16.to_le_bytes());
    out.write_all(&header)?;
    pos += header.len() as u64;

    let group_size = opts.row_group_size.max(1);
    let mut groups = Vec::new();
    let mut buf = Vec::new();
    let mut start = 0;
    while start < table.row_count {
        let n = group_size.min(table.row_count - start);
        let mut chunks = Vec::with_capacity(columns.len());
        for col in columns {
            buf.clear();
            let chunk = encode_chunk(col, start, n, opts.encoding, &mut buf);
            // Chunks start 8-byte aligned.
            let pad = (8 - pos % 8) % 8;
            out.write_all(&[0u8; 8][..pad as usize])?;
            pos += pad;
            out.write_all(&buf)?;
            let mut fields = vec![
                ("offset", Json::uint(pos)),
                ("length", Json::uint(buf.len() as u64)),
                ("crc32", Json::uint(crc32(&buf) as u64)),
                ("encoding", Json::str(chunk.encoding.name())),
                ("null_count", Json::uint(chunk.null_count as u64)),
            ];
            if chunk.min.is_some() {
                fields.push(("min", stat_json(&chunk.min, col.data_type)));
                fields.push(("max", stat_json(&chunk.max, col.data_type)));
            }
            pos += buf.len() as u64;
            chunks.push(Json::object(fields));
        }
        groups.push(Json::object(vec![
            ("row_count", Json::uint(n as u64)),
            ("chunks", Json::Array(chunks)),
        ]));
        start += n;
    }

    let meta = Json::object(vec![
        ("format_version", Json::uint(FORMAT_VERSION as u64)),
        (
            "writer",
            Json::String(format!("polyquery-rust {}", env!("CARGO_PKG_VERSION"))),
        ),
        ("table", Json::str(&table.name)),
        ("row_count", Json::uint(table.row_count as u64)),
        (
            "columns",
            Json::Array(
                table
                    .fields
                    .iter()
                    .map(|f| {
                        Json::object(vec![
                            ("name", Json::str(&f.name)),
                            ("type", Json::String(f.data_type.name())),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "indexes",
            Json::Array(
                indexes
                    .iter()
                    .map(|ix| {
                        Json::object(vec![
                            ("name", Json::str(&ix.name)),
                            ("column", Json::str(&ix.column)),
                            ("kind", Json::str(ix.kind.name())),
                        ])
                    })
                    .collect(),
            ),
        ),
        ("row_groups", Json::Array(groups)),
    ])
    .to_string_compact();
    let meta = meta.as_bytes();
    out.write_all(meta)?;
    let mut footer = Vec::with_capacity(12);
    put_u32(&mut footer, meta.len() as u32);
    put_u32(&mut footer, crc32(meta));
    footer.extend_from_slice(MAGIC);
    out.write_all(&footer)?;
    Ok(pos + meta.len() as u64 + footer.len() as u64)
}

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Removes temporary files left behind by crashed saves of `file_name` in
/// `dir` (other processes' temporaries only).
fn remove_stale_temps(dir: &Path, file_name: &str) {
    let prefix = format!(".{file_name}.tmp-");
    let own = format!("{prefix}{}-", std::process::id());
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.starts_with(&prefix) && !name.starts_with(&own) {
            let _ = fs::remove_file(entry.path());
        }
    }
}

/// Saves `table` atomically to `path` (pqcf-v1.md §5); returns the file size.
pub fn save(
    table: &Table,
    indexes: &[IndexMeta],
    path: &Path,
    display: &str,
    opts: &SaveOptions,
) -> Result<u64> {
    let columns = (0..table.fields.len())
        .map(|c| table.column(c))
        .collect::<Result<Vec<_>>>()?;
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| Error::new(ErrorCode::IoError, format!("invalid target '{display}'")))?
        .to_string();
    let dir: PathBuf = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => PathBuf::from("."),
    };
    if !dir.is_dir() {
        return Err(Error::new(
            ErrorCode::IoError,
            format!("directory of '{display}' does not exist"),
        ));
    }
    remove_stale_temps(&dir, &file_name);
    let temp = dir.join(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        TEMP_COUNTER.fetch_add(1, AtomicOrdering::Relaxed)
    ));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|e| write_error(display, e))?;
    let result = (|| -> std::io::Result<u64> {
        let mut w = BufWriter::with_capacity(1 << 20, file);
        let bytes = write_file(table, &columns, indexes, opts, &mut w)?;
        let file = w.into_inner().map_err(|e| e.into_error())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)?;
        // Persist the rename; not every platform can fsync a directory.
        if let Ok(d) = File::open(&dir) {
            let _ = d.sync_all();
        }
        Ok(bytes)
    })();
    result.map_err(|e| {
        let _ = fs::remove_file(&temp);
        write_error(display, e)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::pqcf::read;
    use crate::storage::{ColumnBuilder, Field, IndexKind};

    fn sample() -> Table {
        let mut ids = ColumnBuilder::new(DataType::Int64);
        let mut tags = ColumnBuilder::new(DataType::String);
        let mut flags = ColumnBuilder::new(DataType::Boolean);
        let mut amounts = ColumnBuilder::new(DataType::decimal(6, 2));
        let mut days = ColumnBuilder::new(DataType::Date);
        let mut ratio = ColumnBuilder::new(DataType::Float64);
        for i in 0..1000i64 {
            ids.push(Value::Int(i));
            if i % 7 == 0 {
                tags.push_null();
                flags.push_null();
                amounts.push_null();
                days.push_null();
                ratio.push_null();
            } else {
                tags.push(Value::str(["a", "bb", "ünï"][(i % 3) as usize]));
                flags.push(Value::Bool(i % 50 < 25));
                amounts.push(Value::Decimal(i * 3 - 1500, 2));
                days.push(Value::Date((i / 100) as i32));
                ratio.push(Value::Float(i as f64 / 8.0));
            }
        }
        Table::new(
            "sample",
            vec![
                Field::new("id", DataType::Int64),
                Field::new("tag", DataType::String),
                Field::new("flag", DataType::Boolean),
                Field::new("amount", DataType::decimal(6, 2)),
                Field::new("day", DataType::Date),
                Field::new("ratio", DataType::Float64),
            ],
            vec![
                ids.finish(),
                tags.finish(),
                flags.finish(),
                amounts.finish(),
                days.finish(),
                ratio.finish(),
            ],
            1000,
        )
    }

    fn all_rows(t: &Table) -> Vec<Vec<Value>> {
        let cols: Vec<usize> = (0..t.fields.len()).collect();
        let mut out = Vec::new();
        for rg in 0..t.row_groups().len() {
            t.read_group(rg, &cols, 0, t.row_groups()[rg].len, &mut out)
                .unwrap();
        }
        out
    }

    #[test]
    fn round_trip_every_encoding() {
        let dir = std::env::temp_dir().join(format!("pq-write-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let t = sample();
        let expected = all_rows(&t);
        let ix = vec![IndexMeta {
            name: "i".into(),
            column: "id".into(),
            kind: IndexKind::Hash,
        }];
        for (k, enc) in [
            EncodingChoice::Auto,
            EncodingChoice::Plain,
            EncodingChoice::Dict,
            EncodingChoice::Rle,
        ]
        .into_iter()
        .enumerate()
        {
            let path = dir.join(format!("t{k}.pqcf"));
            let opts = SaveOptions {
                row_group_size: 300,
                encoding: enc,
            };
            let bytes = save(&t, &ix, &path, "t.pqcf", &opts).unwrap();
            assert_eq!(bytes, fs::metadata(&path).unwrap().len());
            for mmap in [false, true] {
                let opened = read::open(&path, "t.pqcf", "u", mmap, usize::MAX).unwrap();
                assert_eq!(opened.indexes, ix);
                assert_eq!(opened.table.row_groups().len(), 4);
                assert_eq!(all_rows(&opened.table), expected, "{enc:?} mmap={mmap}");
            }
        }
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn corruption_is_detected() {
        let dir = std::env::temp_dir().join(format!("pq-corrupt-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.pqcf");
        save(&sample(), &[], &path, "t.pqcf", &SaveOptions::default()).unwrap();
        let good = fs::read(&path).unwrap();
        let code = |bytes: &[u8]| {
            fs::write(&path, bytes).unwrap();
            read::open(&path, "t", "t", false, usize::MAX)
                .err()
                .map(|e| e.code)
        };
        assert_eq!(code(&good), None);
        let mut flipped = good.clone();
        flipped[20] ^= 0x10;
        assert_eq!(code(&flipped), Some(ErrorCode::StorageCorrupt));
        assert_eq!(
            code(&good[..good.len() / 2]),
            Some(ErrorCode::StorageCorrupt)
        );
        assert_eq!(code(&[]), Some(ErrorCode::StorageCorrupt));
        let mut v2 = good.clone();
        v2[4] = 2;
        assert_eq!(code(&v2), Some(ErrorCode::StorageVersionUnsupported));
        fs::remove_dir_all(&dir).unwrap();
    }
}
