//! PQCF reading: header/footer/metadata validation at open (pqcf-v1.md §1,
//! §2, §4) and checked decoding of column chunks (§3). Every violation is
//! `STORAGE_CORRUPT` (or `STORAGE_VERSION_UNSUPPORTED` for newer versions,
//! reserved flags and unknown encodings); a reader never trusts a length or
//! count before checking it against the bytes actually present.

use std::collections::HashSet;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::sync::OnceLock;

use super::mmap::Mmap;
use super::{
    Encoding, FOOTER_LEN, FORMAT_VERSION, HEADER_LEN, IndexMeta, MAGIC, corrupt, crc::crc32,
    date_range, timestamp_range, unsupported_version,
};
use crate::error::{Error, ErrorCode, Result};
use crate::json::{self, Json};
use crate::storage::column::{Bitmap, Column, ColumnData};
use crate::storage::{Field, IndexKind, RowGroup, Table, Zone};
use crate::types::{DataType, Value, datetime, decimal, float};

/// Bytes of an opened file.
#[derive(Debug)]
enum Source {
    Heap(Vec<u8>),
    Mapped(Mmap),
}

impl Source {
    fn bytes(&self) -> &[u8] {
        match self {
            Source::Heap(v) => v,
            Source::Mapped(m) => m.as_slice(),
        }
    }
}

/// Location and properties of one column chunk.
#[derive(Debug, Clone)]
struct ChunkMeta {
    offset: usize,
    length: usize,
    crc32: u32,
    encoding: Encoding,
    null_count: usize,
}

/// Storage of a PQCF-backed table: the file bytes plus a decode-once cache
/// per column chunk. Chunk checksums and contents are verified when a chunk
/// is first decoded; failures are cached and reported as STORAGE_CORRUPT.
#[derive(Debug)]
pub struct FileData {
    source: Option<Source>,
    ncols: usize,
    chunks: Vec<ChunkMeta>,
    cache: Vec<OnceLock<Result<Column>>>,
}

impl FileData {
    pub(crate) fn chunk(&self, rg: usize, col: usize, ty: DataType, n: usize) -> Result<&Column> {
        let i = rg * self.ncols + col;
        let decoded = self.cache[i].get_or_init(|| match &self.source {
            Some(src) => decode_chunk(src.bytes(), &self.chunks[i], ty, n),
            None => Err(Error::internal("chunk source released before decoding")),
        });
        decoded.as_ref().map_err(Clone::clone)
    }

    /// Drops the file bytes once every chunk is decoded.
    pub(crate) fn release_source(&mut self) {
        if self.cache.iter().all(|c| c.get().is_some()) {
            self.source = None;
        }
    }
}

/// An opened PQCF file: the table and the index definitions of its metadata.
#[derive(Debug)]
pub struct OpenedFile {
    pub table: Table,
    pub indexes: Vec<IndexMeta>,
}

fn io_error(display: &str, e: std::io::Error) -> Error {
    match e.kind() {
        std::io::ErrorKind::NotFound => Error::not_found(format!("file '{display}' not found")),
        std::io::ErrorKind::PermissionDenied => Error::new(
            ErrorCode::AccessDenied,
            format!("permission denied for '{display}'"),
        ),
        _ => Error::new(ErrorCode::IoError, format!("cannot read '{display}': {e}")),
    }
}

/// Opens and validates a PQCF file as table `name`. With `mmap` the file is
/// memory-mapped and chunks are decoded lazily; otherwise it is read and
/// every chunk is verified and decoded now.
pub fn open(
    path: &Path,
    display: &str,
    name: &str,
    mmap: bool,
    max_rows: usize,
) -> Result<OpenedFile> {
    let mut file = File::open(path).map_err(|e| io_error(display, e))?;
    let meta = file.metadata().map_err(|e| io_error(display, e))?;
    if meta.is_dir() {
        return Err(Error::new(
            ErrorCode::IoError,
            format!("'{display}' is a directory"),
        ));
    }
    let len = usize::try_from(meta.len())
        .map_err(|_| Error::resource_limit(format!("'{display}' is too large")))?;
    let source = if mmap && len >= HEADER_LEN + FOOTER_LEN {
        Source::Mapped(Mmap::map(&file, len).map_err(|e| io_error(display, e))?)
    } else {
        let mut buf = Vec::new();
        file.read_to_end(&mut buf)
            .map_err(|e| io_error(display, e))?;
        Source::Heap(buf)
    };
    let parsed = parse_layout(source.bytes(), max_rows)?;
    let ncols = parsed.fields.len();
    let cache = (0..parsed.chunks.len()).map(|_| OnceLock::new()).collect();
    let data = FileData {
        source: Some(source),
        ncols,
        chunks: parsed.chunks,
        cache,
    };
    let mut table = Table::from_file(name, parsed.fields, parsed.groups, data);
    if !mmap {
        table.load_all()?;
        table.release_file_source();
    }
    Ok(OpenedFile {
        table,
        indexes: parsed.indexes,
    })
}

/// Validated file structure.
struct Layout {
    fields: Vec<Field>,
    groups: Vec<RowGroup>,
    /// Row-major: group `g`, column `c` at `g * ncols + c`.
    chunks: Vec<ChunkMeta>,
    indexes: Vec<IndexMeta>,
}

fn u16_at(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

/// A non-negative JSON integer.
fn uint(v: Option<&Json>, what: &str) -> Result<u64> {
    match v {
        Some(Json::Number(text)) => text
            .parse::<u64>()
            .ok()
            .or_else(|| v.and_then(Json::as_i64).and_then(|i| u64::try_from(i).ok()))
            .ok_or_else(|| corrupt(format!("{what} must be a non-negative integer"))),
        Some(_) => Err(corrupt(format!("{what} must be a non-negative integer"))),
        None => Err(corrupt(format!("missing {what}"))),
    }
}

fn usize_of(v: Option<&Json>, what: &str) -> Result<usize> {
    usize::try_from(uint(v, what)?).map_err(|_| corrupt(format!("{what} is out of range")))
}

fn string<'a>(v: Option<&'a Json>, what: &str) -> Result<&'a str> {
    match v {
        Some(Json::String(s)) => Ok(s),
        Some(_) => Err(corrupt(format!("{what} must be a string"))),
        None => Err(corrupt(format!("missing {what}"))),
    }
}

fn array<'a>(v: Option<&'a Json>, what: &str) -> Result<&'a [Json]> {
    match v {
        Some(Json::Array(items)) => Ok(items),
        Some(_) => Err(corrupt(format!("{what} must be an array"))),
        None => Err(corrupt(format!("missing {what}"))),
    }
}

fn parse_layout(bytes: &[u8], max_rows: usize) -> Result<Layout> {
    let size = bytes.len();
    if size < HEADER_LEN {
        return Err(corrupt("file is too small to be a PQCF file"));
    }
    if &bytes[..4] != MAGIC {
        return Err(corrupt("bad header magic"));
    }
    let version = u16_at(bytes, 4);
    if version == 0 {
        return Err(corrupt("format version 0 is invalid"));
    }
    if version > FORMAT_VERSION {
        return Err(unsupported_version(format!(
            "PQCF format version {version} is not supported"
        )));
    }
    if u16_at(bytes, 6) != 0 {
        return Err(unsupported_version("PQCF header flags are not supported"));
    }
    if size < HEADER_LEN + FOOTER_LEN {
        return Err(corrupt("file is truncated"));
    }
    if &bytes[size - 4..] != MAGIC {
        return Err(corrupt("bad trailer magic"));
    }
    let m = u32_at(bytes, size - 12) as usize;
    let crc = u32_at(bytes, size - 8);
    let meta_start = (size - FOOTER_LEN)
        .checked_sub(m)
        .filter(|&s| s >= HEADER_LEN)
        .ok_or_else(|| corrupt("metadata length out of range"))?;
    let meta_bytes = &bytes[meta_start..size - FOOTER_LEN];
    if crc32(meta_bytes) != crc {
        return Err(corrupt("metadata checksum mismatch"));
    }
    let text = std::str::from_utf8(meta_bytes).map_err(|_| corrupt("metadata is not UTF-8"))?;
    let meta = json::parse(text).map_err(|e| corrupt(format!("metadata is not JSON: {e}")))?;
    if !meta.is_object() {
        return Err(corrupt("metadata is not a JSON object"));
    }
    let fv = uint(meta.get("format_version"), "format_version")?;
    if fv != version as u64 {
        return Err(corrupt("metadata format_version does not match the header"));
    }
    string(meta.get("table"), "table")?;

    // Columns.
    let mut fields = Vec::new();
    let mut names = HashSet::new();
    for c in array(meta.get("columns"), "columns")? {
        let name = string(c.get("name"), "column name")?;
        if name.is_empty() || !names.insert(name.to_ascii_lowercase()) {
            return Err(corrupt(format!(
                "invalid or duplicate column name '{name}'"
            )));
        }
        let ty_text = string(c.get("type"), "column type")?;
        let ty = DataType::parse(ty_text)
            .map_err(|_| corrupt(format!("invalid column type '{ty_text}'")))?;
        fields.push(Field::new(name, ty));
    }
    let ncols = fields.len();

    // Row groups and chunks.
    let row_count = uint(meta.get("row_count"), "row_count")?;
    if row_count > max_rows as u64 {
        return Err(Error::resource_limit(format!(
            "file has {row_count} rows, more than the table row limit"
        )));
    }
    let mut groups = Vec::new();
    let mut chunks = Vec::new();
    let mut total: u64 = 0;
    for g in array(meta.get("row_groups"), "row_groups")? {
        let n = usize_of(g.get("row_count"), "row group row_count")?;
        total = total.saturating_add(n as u64);
        if total > row_count {
            return Err(corrupt("row group row counts exceed row_count"));
        }
        let cs = array(g.get("chunks"), "chunks")?;
        if cs.len() != ncols {
            return Err(corrupt("row group does not have one chunk per column"));
        }
        let mut zones = Vec::with_capacity(ncols);
        for (c, field) in cs.iter().zip(&fields) {
            let chunk = parse_chunk(c, n, meta_start, field.data_type)?;
            zones.push(Zone {
                null_count: Some(chunk.null_count),
                min: c.get("min").and_then(|v| stat_value(v, field.data_type)),
                max: c.get("max").and_then(|v| stat_value(v, field.data_type)),
            });
            chunks.push(chunk);
        }
        groups.push(RowGroup {
            start: total as usize - n,
            len: n,
            zones,
        });
    }
    if total != row_count {
        return Err(corrupt(
            "row_count does not equal the sum of row group counts",
        ));
    }

    // Indexes.
    let mut indexes = Vec::new();
    let mut index_names = HashSet::new();
    let index_items = match meta.get("indexes") {
        None | Some(Json::Null) => &[][..],
        v => array(v, "indexes")?,
    };
    for ix in index_items {
        let name = string(ix.get("name"), "index name")?;
        let column = string(ix.get("column"), "index column")?;
        let kind_text = string(ix.get("kind"), "index kind")?;
        let kind = IndexKind::parse(kind_text)
            .ok_or_else(|| corrupt(format!("unknown index kind '{kind_text}'")))?;
        if name.is_empty() || !index_names.insert(name.to_ascii_lowercase()) {
            return Err(corrupt(format!("invalid or duplicate index name '{name}'")));
        }
        if !names.contains(&column.to_ascii_lowercase()) {
            return Err(corrupt(format!(
                "index '{name}' references unknown column '{column}'"
            )));
        }
        indexes.push(IndexMeta {
            name: name.to_string(),
            column: column.to_string(),
            kind,
        });
    }
    Ok(Layout {
        fields,
        groups,
        chunks,
        indexes,
    })
}

fn parse_chunk(c: &Json, n: usize, meta_start: usize, ty: DataType) -> Result<ChunkMeta> {
    if !c.is_object() {
        return Err(corrupt("chunk must be an object"));
    }
    let offset = usize_of(c.get("offset"), "chunk offset")?;
    let length = usize_of(c.get("length"), "chunk length")?;
    let crc = uint(c.get("crc32"), "chunk crc32")?;
    let crc32 = u32::try_from(crc).map_err(|_| corrupt("chunk crc32 out of range"))?;
    let enc_text = string(c.get("encoding"), "chunk encoding")?;
    let encoding = Encoding::parse(enc_text)
        .ok_or_else(|| unsupported_version(format!("unknown encoding '{enc_text}'")))?;
    let null_count = usize_of(c.get("null_count"), "chunk null_count")?;
    if offset < HEADER_LEN
        || offset
            .checked_add(length)
            .is_none_or(|end| end > meta_start)
    {
        return Err(corrupt("chunk byte range out of bounds"));
    }
    if null_count > n {
        return Err(corrupt("chunk null_count exceeds the row group row count"));
    }
    let applicable = match encoding {
        Encoding::Plain => true,
        Encoding::Dict => ty == DataType::String,
        Encoding::Rle => !matches!(ty, DataType::String | DataType::Float64),
    };
    if !applicable {
        return Err(corrupt(format!(
            "encoding {enc_text} is not valid for type {ty}"
        )));
    }
    Ok(ChunkMeta {
        offset,
        length,
        crc32,
        encoding,
        null_count,
    })
}

/// A chunk min/max statistic (types.md §9 serialization); unusable values
/// are treated as unknown.
fn stat_value(v: &Json, ty: DataType) -> Option<Value> {
    match (ty, v) {
        (DataType::Boolean, Json::Bool(b)) => Some(Value::Bool(*b)),
        (DataType::Int64, Json::Number(t)) => t.parse().ok().map(Value::Int),
        (DataType::Float64, Json::Number(t)) => t
            .parse::<f64>()
            .ok()
            .filter(|f| f.is_finite())
            .map(Value::Float),
        (DataType::Decimal { precision, scale }, Json::String(s)) => {
            let t = decimal::parse_text(s)?;
            match decimal::text_to_unscaled(&t, precision, scale, true) {
                decimal::TextToDecimal::Ok(u) => Some(Value::Decimal(u, scale)),
                _ => None,
            }
        }
        (DataType::String, Json::String(s)) => Some(Value::str(s)),
        (DataType::Date, Json::String(s)) => datetime::parse_date(s).map(Value::Date),
        (DataType::Timestamp, Json::String(s)) => {
            datetime::parse_timestamp(s).map(Value::Timestamp)
        }
        _ => None,
    }
}

// ------------------------------------------------------------ chunk decoding

/// Sequential reader over a chunk's bytes.
struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self
            .pos
            .checked_add(n)
            .filter(|&e| e <= self.buf.len())
            .ok_or_else(|| corrupt("column chunk is too short"))?;
        let s = &self.buf[self.pos..end];
        self.pos = end;
        Ok(s)
    }

    /// `count` items of `width` bytes each.
    fn take_n(&mut self, count: usize, width: usize) -> Result<&'a [u8]> {
        let n = count
            .checked_mul(width)
            .ok_or_else(|| corrupt("column chunk is too short"))?;
        self.take(n)
    }

    fn u32(&mut self) -> Result<u32> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
}

fn alloc<T>(n: usize) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(n)
        .map_err(|_| Error::resource_limit("not enough memory to decode a column chunk"))?;
    Ok(v)
}

fn i64s(b: &[u8]) -> impl Iterator<Item = i64> + '_ {
    b.chunks_exact(8)
        .map(|c| i64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]))
}

fn u32s(b: &[u8]) -> impl Iterator<Item = u32> + '_ {
    b.chunks_exact(4)
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
}

/// Decodes `(n+1)` string offsets followed by their bytes into strings.
/// `keep(i)` says whether slot i is non-null (null slots become "").
fn decode_strings(
    cur: &mut Cursor<'_>,
    n: usize,
    keep: &dyn Fn(usize) -> bool,
) -> Result<Vec<std::sync::Arc<str>>> {
    let offsets: Vec<u32> = u32s(cur.take_n(n.saturating_add(1), 4)?).collect();
    if offsets[0] != 0 || offsets.windows(2).any(|w| w[0] > w[1]) {
        return Err(corrupt("string offsets are not non-decreasing from 0"));
    }
    let bytes = cur.take(offsets[n] as usize)?;
    let text = std::str::from_utf8(bytes).map_err(|_| corrupt("invalid UTF-8 in string data"))?;
    let empty: std::sync::Arc<str> = std::sync::Arc::from("");
    let mut out = alloc(n)?;
    for i in 0..n {
        let (a, b) = (offsets[i] as usize, offsets[i + 1] as usize);
        if !text.is_char_boundary(a) || !text.is_char_boundary(b) {
            return Err(corrupt("invalid UTF-8 in string data"));
        }
        out.push(if keep(i) && a < b {
            std::sync::Arc::from(&text[a..b])
        } else {
            empty.clone()
        });
    }
    Ok(out)
}

/// Converts raw i64 slot values to typed column data, validating the values
/// of non-null slots.
fn typed_from_i64(raw: Vec<i64>, ty: DataType, valid: &Bitmap) -> Result<ColumnData> {
    let check = |ok: &dyn Fn(i64) -> bool, what: &str| -> Result<()> {
        for (i, &v) in raw.iter().enumerate() {
            if valid.get(i) && !ok(v) {
                return Err(corrupt(format!("invalid {what} value {v}")));
            }
        }
        Ok(())
    };
    Ok(match ty {
        DataType::Boolean => {
            check(&|v| v == 0 || v == 1, "BOOLEAN")?;
            ColumnData::Boolean(raw.into_iter().map(|v| v == 1).collect())
        }
        DataType::Int64 => ColumnData::Int64(raw),
        DataType::Decimal { precision, .. } => {
            check(
                &|v| decimal::fits_precision(v as i128, precision),
                "DECIMAL",
            )?;
            ColumnData::Decimal(raw)
        }
        DataType::Date => {
            let range = date_range();
            check(&|v| range.contains(&v), "DATE")?;
            ColumnData::Date(
                raw.into_iter()
                    .enumerate()
                    .map(|(i, v)| if valid.get(i) { v as i32 } else { 0 })
                    .collect(),
            )
        }
        DataType::Timestamp => {
            let range = timestamp_range();
            check(&|v| range.contains(&v), "TIMESTAMP")?;
            ColumnData::Timestamp(raw)
        }
        _ => return Err(Error::internal("not an integer-represented type")),
    })
}

/// Decodes and validates one column chunk of `n` rows.
fn decode_chunk(file: &[u8], meta: &ChunkMeta, ty: DataType, n: usize) -> Result<Column> {
    let buf = &file[meta.offset..meta.offset + meta.length];
    if crc32(buf) != meta.crc32 {
        return Err(corrupt("column chunk checksum mismatch"));
    }
    let mut cur = Cursor { buf, pos: 0 };
    let validity = if meta.null_count > 0 {
        let bm = Bitmap::from_lsb_bytes(cur.take(n.div_ceil(8))?, n);
        if n - bm.count_ones() != meta.null_count {
            return Err(corrupt("validity bitmap does not match null_count"));
        }
        bm
    } else {
        Bitmap::all_set(n)
    };
    let data = match (meta.encoding, ty) {
        (Encoding::Plain, DataType::Boolean) => {
            let bits = Bitmap::from_lsb_bytes(cur.take(n.div_ceil(8))?, n);
            ColumnData::Boolean((0..n).map(|i| bits.get(i) && validity.get(i)).collect())
        }
        (Encoding::Plain, DataType::Float64) => {
            let b = cur.take_n(n, 8)?;
            let mut v = alloc(n)?;
            for (i, x) in i64s(b).enumerate() {
                let f = f64::from_bits(x as u64);
                if validity.get(i) && !f.is_finite() {
                    return Err(corrupt("non-finite FLOAT64 value"));
                }
                v.push(if validity.get(i) {
                    float::normalize(f)
                } else {
                    0.0
                });
            }
            ColumnData::Float64(v)
        }
        (Encoding::Plain, DataType::Date) => {
            let b = cur.take_n(n, 4)?;
            let mut raw = alloc(n)?;
            raw.extend(u32s(b).map(|x| x as i32 as i64));
            typed_from_i64(raw, ty, &validity)?
        }
        (Encoding::Plain, DataType::String) => {
            ColumnData::String(decode_strings(&mut cur, n, &|i| validity.get(i))?)
        }
        (Encoding::Plain, _) => {
            let b = cur.take_n(n, 8)?;
            let mut raw = alloc(n)?;
            raw.extend(i64s(b));
            typed_from_i64(raw, ty, &validity)?
        }
        (Encoding::Dict, DataType::String) => {
            let d = cur.u32()? as usize;
            let dict = decode_strings(&mut cur, d, &|_| true)?;
            let mut codes = alloc(n)?;
            for (i, code) in u32s(cur.take_n(n, 4)?).enumerate() {
                if !validity.get(i) {
                    codes.push(0);
                } else if (code as usize) < d {
                    codes.push(code);
                } else {
                    return Err(corrupt("dictionary code out of range"));
                }
            }
            ColumnData::Dict {
                codes,
                dict: dict.into(),
            }
        }
        (Encoding::Rle, _) => {
            let r = cur.u32()? as usize;
            let runs = cur.take_n(r, 12)?;
            let mut raw = alloc(n)?;
            for run in runs.chunks_exact(12) {
                let value = i64s(&run[..8]).next().unwrap_or(0);
                let len = u32::from_le_bytes([run[8], run[9], run[10], run[11]]) as usize;
                if len == 0 || len > n - raw.len() {
                    return Err(corrupt("invalid RLE run length"));
                }
                raw.extend(std::iter::repeat_n(value, len));
            }
            if raw.len() != n {
                return Err(corrupt("RLE runs do not cover the row group"));
            }
            typed_from_i64(raw, ty, &validity)?
        }
        (enc, ty) => {
            return Err(corrupt(format!(
                "encoding {} is not valid for type {ty}",
                enc.name()
            )));
        }
    };
    if cur.pos != buf.len() {
        return Err(corrupt("column chunk has trailing bytes"));
    }
    Ok(Column {
        data_type: ty,
        data,
        validity,
    })
}
