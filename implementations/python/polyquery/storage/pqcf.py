"""PQCF v1 and v2, the persistent columnar file format
(spec/storage/pqcf-v1.md; v2: spec/changes/decimal38.md §7).

PQCF v2 differs from v1 only in its version numbers and in allowing wide
DECIMAL columns (precision > 18), whose values are 128-bit two's-complement
little-endian integers (PLAIN: 16 bytes per value, RLE: 20-byte runs). A
table with a wide DECIMAL column is written as v2, every other table as v1.

Writing (:func:`save_table`) streams the chunks of one row group after the
other into a temporary file in the target directory, appends the JSON
metadata and footer, fsyncs, renames it over the target and fsyncs the
directory (§5).

Reading (:func:`read_file`) validates header, footer, metadata checksum and
structure up front. Chunks are decoded (checksum and value validity verified)
either eagerly at ``open`` or — for memory-mapped files — lazily on first use,
in which case the failing query reports ``STORAGE_CORRUPT``.
"""

from __future__ import annotations

import array
import itertools
import json
import math
import mmap
import os
import secrets
import struct
import sys
import zlib
from dataclasses import dataclass
from typing import Any, BinaryIO, Callable, Iterator

from .. import ENGINE_VERSION, errors
from ..datatypes import DataType, InvalidTypeError, TypeKind, parse_type
from ..names import fold
from ..values import (
    MAX_DATE,
    MICROS_PER_DAY,
    MIN_DATE,
    POW10,
    format_date,
    format_decimal,
    format_timestamp,
    parse_date,
    parse_decimal_text,
    parse_timestamp,
)
from .table import COLUMN, ROW, ChunkBounds, Column, ColumnTable, RowGroup, Table, relayout
from .vectors import (
    TYPECODES,
    ColumnVector,
    DictVector,
    PlainVector,
    bits_to_flags,
    count_set_bits,
    dictionary_encode,
    flags_to_bits,
    null_positions,
    should_dictionary_encode,
    validity_of,
)

MAGIC = b"PQCF"
FORMAT_VERSION_1 = 1
FORMAT_VERSION_2 = 2  # wide DECIMAL columns
MAX_FORMAT_VERSION = FORMAT_VERSION_2
HEADER_SIZE = 8
FOOTER_SIZE = 12
WRITER = "polyquery-python"
DEFAULT_ROW_GROUP_SIZE = 65536

PLAIN, DICT, RLE = "PLAIN", "DICT", "RLE"
ENCODINGS = (PLAIN, DICT, RLE)
FORCED_ENCODINGS = ("auto", "plain", "dict", "rle")
RLE_KINDS = frozenset(
    {TypeKind.BOOLEAN, TypeKind.INT64, TypeKind.DECIMAL, TypeKind.DATE, TypeKind.TIMESTAMP}
)
INDEX_KINDS = ("HASH", "BTREE")

MIN_TIMESTAMP = MIN_DATE * MICROS_PER_DAY
MAX_TIMESTAMP = (MAX_DATE + 1) * MICROS_PER_DAY - 1

_BIG_ENDIAN = sys.byteorder != "little"
_RUN = struct.Struct("<qI")
_U32 = struct.Struct("<I")
I128_BYTES = 16
_WIDE_RUN_BYTES = I128_BYTES + 4


def _corrupt(message: str) -> errors.PolyQueryError:
    return errors.storage_corrupt(message)


# ====================================================================== writing


@dataclass
class SaveOptions:
    row_group_size: int = DEFAULT_ROW_GROUP_SIZE
    encoding: str = "auto"  # auto | plain | dict | rle


def save_table(
    path: str, table: Table, indexes: list[dict[str, str]], options: SaveOptions
) -> int:
    """Writes ``table`` atomically as a PQCF file; returns the file size."""
    return write_atomic(path, lambda f: _write_table(f, table, indexes, options))


def write_atomic(path: str, write: Callable[[BinaryIO], None]) -> int:
    """Writes a file via a temporary file + fsync + rename + directory fsync.
    A symbolic link as target is followed (the link's target is replaced)."""
    if os.path.islink(path):
        path = os.path.realpath(path)
    if os.path.isdir(path):
        raise errors.io_error("the target path is a directory")
    directory = os.path.dirname(path) or "."
    base = os.path.basename(path)
    if not base:
        raise errors.io_error("path names a directory")
    _remove_stale_temporaries(directory, base)
    tmp = os.path.join(directory, f".{base}.tmp-{os.getpid()}-{secrets.token_hex(6)}")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileNotFoundError:
        raise errors.io_error("the target directory does not exist") from None
    except PermissionError:
        raise errors.access_denied("permission denied") from None
    except OSError as e:
        raise errors.io_error(f"cannot create file: {e.strerror}") from None
    try:
        with os.fdopen(fd, "wb") as f:
            write(f)
            f.flush()
            os.fsync(f.fileno())
            size = f.tell()
        os.replace(tmp, path)
    except BaseException as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        if isinstance(e, OSError):
            raise errors.io_error(f"cannot write file: {e.strerror}") from None
        raise
    _fsync_directory(directory)
    return size


def _remove_stale_temporaries(directory: str, base: str) -> None:
    """Removes temporary files of earlier saves to the same target whose
    writing process no longer exists (left behind by a crash)."""
    prefix = f".{base}.tmp-"
    try:
        names = [n for n in os.listdir(directory) if n.startswith(prefix)]
    except OSError:
        return
    for name in names:
        pid_text = name[len(prefix) :].partition("-")[0]
        if not pid_text.isdigit() or _process_alive(int(pid_text)):
            continue
        try:
            os.unlink(os.path.join(directory, name))
        except OSError:
            pass


def _process_alive(pid: int) -> bool:
    if pid == os.getpid():
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OSError):
        return True
    return True


def _fsync_directory(directory: str) -> None:
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass  # not supported for directories on every platform
    finally:
        os.close(fd)


def format_version_for(columns: list[Column]) -> int:
    """The writer rule: v2 exactly when the table has a wide DECIMAL column."""
    return FORMAT_VERSION_2 if any(c.type.is_wide for c in columns) else FORMAT_VERSION_1


def _write_table(
    f: BinaryIO, table: Table, indexes: list[dict[str, str]], options: SaveOptions
) -> None:
    version = format_version_for(table.columns)
    f.write(MAGIC + struct.pack("<HH", version, 0))
    offset = HEADER_SIZE
    columns = [table.column_values(i) for i in range(len(table.columns))]
    groups: list[dict[str, Any]] = []
    for start in range(0, table.row_count, options.row_group_size):
        stop = min(table.row_count, start + options.row_group_size)
        chunks = []
        for column, values in zip(table.columns, columns):
            body, info = encode_chunk(column.type, values[start:stop], options.encoding)
            padding = -offset % 8
            if padding:
                f.write(bytes(padding))
                offset += padding
            f.write(body)
            chunks.append({"offset": offset, "length": len(body), "crc32": zlib.crc32(body), **info})
            offset += len(body)
        groups.append({"row_count": stop - start, "chunks": chunks})
    meta = {
        "format_version": version,
        "writer": f"{WRITER} {ENGINE_VERSION}",
        "table": table.name,
        "row_count": table.row_count,
        "columns": table.schema_json(),
        "indexes": indexes,
        "row_groups": groups,
    }
    meta_bytes = json.dumps(meta, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
    f.write(meta_bytes)
    f.write(struct.pack("<II", len(meta_bytes), zlib.crc32(meta_bytes)))
    f.write(MAGIC)


def encode_chunk(dtype: DataType, values: list[Any], forced: str) -> tuple[bytes, dict[str, Any]]:
    """Encodes one column chunk; returns its bytes and its metadata entries
    (encoding, null_count, min/max)."""
    validity, nulls = validity_of(values)
    encoding = _choose_encoding(dtype, values, forced)
    if encoding == PLAIN:
        body = _encode_plain(dtype, values)
    elif encoding == DICT:
        body = _encode_dict(values)
    else:
        body = _encode_rle(dtype, values)
    info: dict[str, Any] = {"encoding": encoding, "null_count": nulls}
    if dtype.kind is not TypeKind.STRING and nulls < len(values):
        present = [v for v in values if v is not None] if nulls else values
        info["min"] = _bound_json(dtype, min(present))
        info["max"] = _bound_json(dtype, max(present))
    return (validity + body if validity is not None else body), info


def _choose_encoding(dtype: DataType, values: list[Any], forced: str) -> str:
    kind = dtype.kind
    if forced == "plain":
        return PLAIN
    if forced == "dict":
        return DICT if kind is TypeKind.STRING else PLAIN
    if forced == "rle":
        return RLE if kind in RLE_KINDS else PLAIN
    if kind is TypeKind.STRING:
        return DICT if should_dictionary_encode(values) else PLAIN
    if kind in RLE_KINDS and len(values) >= 4 and _run_count(values) < len(values) / 4:
        return RLE
    return PLAIN


def _rle_values(dtype: DataType, values: list[Any]) -> list[int]:
    """The i64 value of every slot; NULL slots repeat the previous value so
    they extend the current run."""
    out: list[int] = []
    previous = 0
    is_bool = dtype.kind is TypeKind.BOOLEAN
    for v in values:
        if v is not None:
            previous = int(v) if is_bool else v
        out.append(previous)
    return out


def _run_count(values: list[Any]) -> int:
    runs = 0
    previous: Any = object()
    for v in values:
        if v is not None and v != previous:
            runs += 1
            previous = v
    return max(runs, 1)


def _array_bytes(typecode: str, values: Any) -> bytes:
    arr = array.array(typecode, values)
    if _BIG_ENDIAN:
        arr.byteswap()
    return arr.tobytes()


def _encode_strings(strings: list[bytes]) -> bytes:
    offsets = [0, *itertools.accumulate(map(len, strings))]
    if offsets[-1] >= 1 << 32:
        raise errors.resource_limit("string data of a chunk exceeds 4 GiB")
    return _array_bytes("I", offsets) + b"".join(strings)


def _i128_bytes(v: int) -> bytes:
    return v.to_bytes(I128_BYTES, "little", signed=True)


def _encode_plain(dtype: DataType, values: list[Any]) -> bytes:
    kind = dtype.kind
    if dtype.is_wide:
        return b"".join([_i128_bytes(0 if v is None else v) for v in values])
    if kind is TypeKind.BOOLEAN:
        return flags_to_bits(bytes([v is True for v in values]))
    if kind is TypeKind.STRING:
        return _encode_strings([b"" if v is None else v.encode() for v in values])
    return _array_bytes(TYPECODES[kind], [0 if v is None else v for v in values])


def _encode_dict(values: list[Any]) -> bytes:
    codes_of: dict[str, int] = {}
    codes = []
    for v in values:
        if v is None:
            codes.append(0)
            continue
        code = codes_of.get(v)
        if code is None:
            code = codes_of[v] = len(codes_of)
        codes.append(code)
    dictionary = [s.encode() for s in codes_of]  # insertion order = code order
    return _U32.pack(len(dictionary)) + _encode_strings(dictionary) + _array_bytes("I", codes)


def _encode_rle(dtype: DataType, values: list[Any]) -> bytes:
    runs: list[bytes] = []
    wide = dtype.is_wide
    for value, group in itertools.groupby(_rle_values(dtype, values)):
        length = sum(1 for _ in group)
        if wide:
            runs.append(_i128_bytes(value) + _U32.pack(length))
        else:
            runs.append(_RUN.pack(value, length))
    return _U32.pack(len(runs)) + b"".join(runs)


def _bound_json(dtype: DataType, v: Any) -> Any:
    kind = dtype.kind
    if kind is TypeKind.DECIMAL:
        return format_decimal(v, dtype.scale)
    if kind is TypeKind.DATE:
        return format_date(v)
    if kind is TypeKind.TIMESTAMP:
        return format_timestamp(v)
    if kind is TypeKind.FLOAT64:
        return v + 0.0
    return v


# ====================================================================== reading


@dataclass(frozen=True)
class ChunkMeta:
    offset: int
    length: int
    crc32: int
    encoding: str
    null_count: int
    min: Any
    max: Any


@dataclass
class GroupMeta:
    row_count: int
    chunks: list[ChunkMeta]


@dataclass
class PqcfFile:
    buffer: Any  # bytes or mmap.mmap
    table: str
    columns: list[Column]
    row_count: int
    indexes: list[tuple[str, int, str]]  # (name, column position, kind)
    groups: list[GroupMeta]


def read_file(path: str, *, use_mmap: bool) -> PqcfFile:
    """Opens and validates a PQCF file (structure only; chunks are checked
    when decoded)."""
    try:
        f = open(path, "rb")
    except FileNotFoundError:
        raise errors.not_found("file does not exist") from None
    except PermissionError:
        raise errors.access_denied("permission denied") from None
    except IsADirectoryError:
        raise errors.io_error("path is a directory") from None
    except OSError as e:
        raise errors.io_error(f"cannot open file: {e.strerror}") from None
    try:
        with f:
            size = os.fstat(f.fileno()).st_size
            if use_mmap and size > 0:
                buffer: Any = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            else:
                buffer = f.read()
    except OSError as e:
        raise errors.io_error(f"cannot read file: {e.strerror}") from None
    return parse_file(buffer)


def parse_file(buffer: Any) -> PqcfFile:
    size = len(buffer)
    if size < HEADER_SIZE or buffer[0:4] != MAGIC:
        raise _corrupt("not a PQCF file (bad header magic)")
    version, flags = struct.unpack("<HH", buffer[4:8])
    if version == 0:
        raise _corrupt("invalid format version 0")
    if version > MAX_FORMAT_VERSION:
        raise errors.storage_version_unsupported(f"PQCF format version {version} is not supported")
    if flags != 0:
        raise errors.storage_version_unsupported(f"unsupported PQCF header flags {flags}")
    if size < HEADER_SIZE + FOOTER_SIZE or buffer[size - 4 : size] != MAGIC:
        raise _corrupt("truncated file or bad trailing magic")
    meta_len, meta_crc = struct.unpack("<II", buffer[size - 12 : size - 4])
    meta_start = size - FOOTER_SIZE - meta_len
    if meta_start < HEADER_SIZE:
        raise _corrupt("metadata length out of range")
    meta_bytes = buffer[meta_start : size - FOOTER_SIZE]
    if zlib.crc32(meta_bytes) != meta_crc:
        raise _corrupt("metadata checksum mismatch")
    try:
        meta = json.loads(meta_bytes.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise _corrupt("metadata is not valid JSON") from None
    return _parse_metadata(meta, buffer, meta_start, version)


def _reject_constant(name: str) -> Any:
    raise ValueError(f"invalid JSON constant {name}")


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise _corrupt(message)


def _parse_metadata(meta: Any, buffer: Any, meta_start: int, version: int) -> PqcfFile:
    _require(isinstance(meta, dict), "metadata is not a JSON object")
    _require(
        _is_int(meta.get("format_version")) and meta["format_version"] == version,
        "metadata format_version does not match the header",
    )
    table = meta.get("table")
    _require(isinstance(table, str), "metadata 'table' must be a string")
    row_count = meta.get("row_count")
    _require(_is_int(row_count) and row_count >= 0, "invalid row_count")
    columns = _parse_columns(meta.get("columns"))
    if version < FORMAT_VERSION_2:
        _require(not any(c.type.is_wide for c in columns), "a PQCF v1 file cannot have wide DECIMAL columns")
    raw_groups = meta.get("row_groups")
    _require(isinstance(raw_groups, list), "'row_groups' must be an array")
    groups = [_parse_group(g, columns, meta_start) for g in raw_groups]
    _require(sum(g.row_count for g in groups) == row_count, "row_count does not match the row groups")
    indexes = _parse_indexes(meta.get("indexes", []), columns)
    return PqcfFile(buffer, table, columns, row_count, indexes, groups)


def _parse_columns(raw: Any) -> list[Column]:
    _require(isinstance(raw, list) and len(raw) > 0, "'columns' must be a non-empty array")
    columns: list[Column] = []
    seen: set[str] = set()
    for entry in raw:
        _require(isinstance(entry, dict), "column entries must be objects")
        name, type_text = entry.get("name"), entry.get("type")
        _require(isinstance(name, str) and name != "", "column names must be non-empty strings")
        _require(fold(name) not in seen, f"duplicate column name '{name}'")
        seen.add(fold(name))
        _require(isinstance(type_text, str), "column types must be strings")
        try:
            dtype = parse_type(type_text)
        except InvalidTypeError:
            raise _corrupt(f"invalid column type '{type_text}'") from None
        columns.append(Column(name, dtype))
    return columns


def _parse_group(raw: Any, columns: list[Column], meta_start: int) -> GroupMeta:
    _require(isinstance(raw, dict), "row group entries must be objects")
    rows = raw.get("row_count")
    _require(_is_int(rows) and rows >= 0, "invalid row group row_count")
    chunks = raw.get("chunks")
    _require(
        isinstance(chunks, list) and len(chunks) == len(columns),
        "a row group must have exactly one chunk per column",
    )
    return GroupMeta(rows, [_parse_chunk(c, col.type, rows, meta_start) for c, col in zip(chunks, columns)])


def _parse_chunk(raw: Any, dtype: DataType, rows: int, meta_start: int) -> ChunkMeta:
    _require(isinstance(raw, dict), "chunk entries must be objects")
    offset, length, crc = raw.get("offset"), raw.get("length"), raw.get("crc32")
    _require(_is_int(offset) and _is_int(length) and length >= 0, "invalid chunk offset/length")
    _require(HEADER_SIZE <= offset and offset + length <= meta_start, "chunk out of bounds")
    _require(_is_int(crc) and 0 <= crc < 1 << 32, "invalid chunk crc32")
    encoding = raw.get("encoding")
    _require(isinstance(encoding, str), "chunk encoding must be a string")
    if encoding not in ENCODINGS:
        raise errors.storage_version_unsupported(f"unknown chunk encoding '{encoding}'")
    if encoding == DICT:
        _require(dtype.kind is TypeKind.STRING, "DICT encoding requires a STRING column")
    if encoding == RLE:
        _require(dtype.kind in RLE_KINDS, f"RLE encoding is not valid for {dtype.name}")
    nulls = raw.get("null_count")
    _require(_is_int(nulls) and 0 <= nulls <= rows, "invalid chunk null_count")
    low, high = _parse_bound(dtype, raw.get("min")), _parse_bound(dtype, raw.get("max"))
    if low is not None and high is not None and low > high:
        low = high = None
    return ChunkMeta(offset, length, crc, encoding, nulls, low, high)


def _parse_bound(dtype: DataType, v: Any) -> Any:
    """A min/max statistic in the runtime representation; None if absent or
    not interpretable (statistics are only used for row-group skipping)."""
    kind = dtype.kind
    try:
        if kind is TypeKind.INT64 and _is_int(v):
            return v
        if kind is TypeKind.FLOAT64 and (_is_int(v) or isinstance(v, float)):
            return float(v)
        if kind is TypeKind.BOOLEAN and isinstance(v, bool):
            return v
        if kind is TypeKind.STRING and isinstance(v, str):
            return v
        if isinstance(v, str):
            if kind is TypeKind.DECIMAL:
                return parse_decimal_text(v, dtype.scale, exact=True)
            if kind is TypeKind.DATE:
                return parse_date(v)
            if kind is TypeKind.TIMESTAMP:
                return parse_timestamp(v, allow_date=False)
    except (errors.PolyQueryError, ValueError, OverflowError):
        return None
    return None


def _parse_indexes(raw: Any, columns: list[Column]) -> list[tuple[str, int, str]]:
    _require(isinstance(raw, list), "'indexes' must be an array")
    positions = {fold(c.name): i for i, c in enumerate(columns)}
    out: list[tuple[str, int, str]] = []
    names: set[str] = set()
    for entry in raw:
        _require(isinstance(entry, dict), "index entries must be objects")
        name, column, kind = entry.get("name"), entry.get("column"), entry.get("kind")
        _require(isinstance(name, str) and name != "", "index names must be non-empty strings")
        _require(fold(name) not in names, f"duplicate index name '{name}'")
        names.add(fold(name))
        _require(isinstance(column, str) and fold(column) in positions, "index references an unknown column")
        _require(isinstance(kind, str) and kind.upper() in INDEX_KINDS, "invalid index kind")
        out.append((name, positions[fold(column)], kind.upper()))
    return out


# ---------------------------------------------------------------- chunk decoding


def decode_chunk(buffer: Any, chunk: ChunkMeta, dtype: DataType, n: int) -> ColumnVector:
    """Verifies and decodes one chunk of ``n`` rows (§3, §3.4)."""
    data = buffer[chunk.offset : chunk.offset + chunk.length]
    if zlib.crc32(data) != chunk.crc32:
        raise _corrupt("chunk checksum mismatch")
    validity: bytes | None = None
    flags: bytes | None = None
    pos = 0
    if chunk.null_count > 0:
        size = (n + 7) // 8
        _require(len(data) >= size, "chunk too short for its validity bitmap")
        validity = bytearray(data[:size])
        if n % 8:
            validity[-1] &= (1 << (n % 8)) - 1  # unused trailing bits are ignored
        validity = bytes(validity)
        _require(n - count_set_bits(validity, n) == chunk.null_count, "validity bitmap does not match null_count")
        flags = bits_to_flags(validity, n)
        pos = size
    body = memoryview(data)[pos:]
    if chunk.encoding == PLAIN:
        return _decode_plain(dtype, body, n, validity, flags, chunk.null_count)
    if chunk.encoding == DICT:
        return _decode_dict(dtype, body, n, validity, flags, chunk.null_count)
    return _decode_rle(dtype, body, n, validity, flags, chunk.null_count)


def _unpack_array(typecode: str, data: Any) -> array.array:
    arr = array.array(typecode)
    arr.frombytes(data)
    if _BIG_ENDIAN:
        arr.byteswap()
    return arr


def _present(values: Any, flags: bytes | None) -> list[Any]:
    """The values of the non-NULL rows."""
    return list(values) if flags is None else list(itertools.compress(values, flags))


def _check_values(dtype: DataType, values: Any, flags: bytes | None) -> None:
    """Value validity of non-NULL rows (§3.4)."""
    kind = dtype.kind
    if kind is TypeKind.INT64 or kind is TypeKind.STRING:
        return
    present = _present(values, flags)
    if not present:
        return
    if kind is TypeKind.FLOAT64:
        _require(all(map(math.isfinite, present)), "non-finite FLOAT64 value")
        return
    low, high = min(present), max(present)
    if kind is TypeKind.DECIMAL:
        limit = POW10[dtype.precision]
        _require(-limit < low and high < limit, f"DECIMAL value exceeds precision {dtype.precision}")
    elif kind is TypeKind.DATE:
        _require(MIN_DATE <= low and high <= MAX_DATE, "DATE value out of range")
    elif kind is TypeKind.TIMESTAMP:
        _require(MIN_TIMESTAMP <= low and high <= MAX_TIMESTAMP, "TIMESTAMP value out of range")
    elif kind is TypeKind.BOOLEAN:
        _require(0 <= low and high <= 1, "BOOLEAN value is not 0/1")


def _zero_nulls(values: list[int], flags: bytes | None) -> list[int]:
    if flags is not None:
        for i in null_positions(flags):
            values[i] = 0
    return values


def _decode_plain(
    dtype: DataType, body: memoryview, n: int, validity: bytes | None, flags: bytes | None, nulls: int
) -> ColumnVector:
    kind = dtype.kind
    if kind is TypeKind.BOOLEAN:
        _require(len(body) == (n + 7) // 8, "BOOLEAN chunk has the wrong size")
        return PlainVector(dtype, bytearray(bits_to_flags(bytes(body), n)), validity, nulls)
    if kind is TypeKind.STRING:
        _require(len(body) >= 4 * (n + 1), "STRING chunk too short for its offsets")
        offsets = _unpack_array("I", body[: 4 * (n + 1)])
        strings = _decode_strings(bytes(body[4 * (n + 1) :]), offsets, flags)
        return PlainVector(dtype, strings, validity, nulls)
    if dtype.is_wide:
        _require(len(body) == I128_BYTES * n, f"{dtype.name} chunk has the wrong size")
        wide = _unpack_i128(body)
        _check_values(dtype, wide, flags)
        return PlainVector(dtype, _zero_nulls(wide, flags), validity, nulls)
    typecode = TYPECODES[kind]
    width = 4 if typecode == "i" else 8
    _require(len(body) == width * n, f"{dtype.name} chunk has the wrong size")
    values = _unpack_array(typecode, body)
    _check_values(dtype, values, flags)
    return PlainVector(dtype, values, validity, nulls)


def _unpack_i128(data: Any) -> list[int]:
    """Consecutive 128-bit two's-complement little-endian integers."""
    raw = bytes(data)
    from_bytes = int.from_bytes
    return [from_bytes(raw[i : i + I128_BYTES], "little", signed=True) for i in range(0, len(raw), I128_BYTES)]


def _decode_strings(blob: bytes, offsets: array.array, flags: bytes | None) -> list[str]:
    """Splits concatenated UTF-8 strings at ``offsets`` (n+1 entries)."""
    _require(offsets[0] == 0, "first string offset must be 0")
    _require(offsets[-1] == len(blob), "string offsets do not match the data size")
    bounds = offsets.tolist()
    pairs = list(zip(bounds, bounds[1:]))
    _require(all(a <= b for a, b in pairs), "string offsets are decreasing")
    try:
        if blob.isascii():
            text = blob.decode("ascii")
            return [text[a:b] for a, b in pairs]
        if flags is None:
            return [blob[a:b].decode("utf-8") for a, b in pairs]
        return [blob[a:b].decode("utf-8") if f else "" for (a, b), f in zip(pairs, flags)]
    except UnicodeDecodeError:
        raise _corrupt("invalid UTF-8 in string data") from None


def _decode_dict(
    dtype: DataType, body: memoryview, n: int, validity: bytes | None, flags: bytes | None, nulls: int
) -> ColumnVector:
    _require(len(body) >= 4, "DICT chunk too short")
    (count,) = _U32.unpack(body[:4])
    offsets_end = 4 + 4 * (count + 1)
    _require(len(body) >= offsets_end, "DICT chunk too short for its dictionary offsets")
    offsets = _unpack_array("I", body[4:offsets_end])
    codes_start = offsets_end + offsets[-1]
    _require(len(body) == codes_start + 4 * n, "DICT chunk has the wrong size")
    dictionary = _decode_strings(bytes(body[offsets_end:codes_start]), offsets, None)
    codes = _unpack_array("I", body[codes_start:])
    present = _present(codes, flags)
    _require(not present or max(present) < count, "dictionary code out of range")
    if not dictionary:
        dictionary = [""]  # every row is NULL; keeps the (ignored) codes valid below
    if flags is not None:
        for i in null_positions(flags):
            codes[i] = 0
    return DictVector(dtype, dictionary, codes, validity, nulls)


def _decode_rle(
    dtype: DataType, body: memoryview, n: int, validity: bytes | None, flags: bytes | None, nulls: int
) -> ColumnVector:
    _require(len(body) >= 4, "RLE chunk too short")
    (count,) = _U32.unpack(body[:4])
    wide = dtype.is_wide
    _require(len(body) == 4 + (_WIDE_RUN_BYTES if wide else _RUN.size) * count, "RLE chunk has the wrong size")
    values: list[int] = []
    total = 0
    for value, run in _wide_runs(body[4:]) if wide else _RUN.iter_unpack(body[4:]):
        _require(run >= 1, "RLE run length must be at least 1")
        total += run
        _require(total <= n, "RLE runs exceed the row count")
        values.extend(itertools.repeat(value, run))
    _require(total == n, "RLE runs do not cover the row count")
    _check_values(dtype, values, flags)
    values = _zero_nulls(values, flags)
    if dtype.kind is TypeKind.BOOLEAN:
        return PlainVector(dtype, bytearray(values), validity, nulls)
    if wide:
        return PlainVector(dtype, values, validity, nulls)
    return PlainVector(dtype, array.array(TYPECODES[dtype.kind], values), validity, nulls)


def _wide_runs(data: Any) -> Iterator[tuple[int, int]]:
    """The (i128 value, u32 run length) pairs of a wide RLE chunk."""
    raw = bytes(data)
    for i in range(0, len(raw), _WIDE_RUN_BYTES):
        value = int.from_bytes(raw[i : i + I128_BYTES], "little", signed=True)
        (run,) = _U32.unpack_from(raw, i + I128_BYTES)
        yield value, run


# ---------------------------------------------------------------- tables


def table_from_file(
    pqcf: PqcfFile,
    name: str,
    *,
    lazy: bool,
    layout: str = COLUMN,
    dictionary: bool | None = None,
) -> Table:
    """Builds a catalog table from a validated file. With ``lazy`` chunks are
    decoded on first access; otherwise all chunks are verified now."""
    groups: list[RowGroup] = []
    start = 0
    for meta in pqcf.groups:
        bounds = [ChunkBounds(c.null_count, c.min, c.max) for c in meta.chunks]
        loader = _chunk_loader(pqcf, meta, dictionary)
        vectors: list[ColumnVector | None] = [None] * len(pqcf.columns)
        if not lazy:
            vectors = [loader(i) for i in range(len(pqcf.columns))]
        groups.append(RowGroup(start, meta.row_count, vectors, bounds, loader))
        start += meta.row_count
    table: Table = ColumnTable(name, list(pqcf.columns), groups)
    if layout == ROW:
        table = relayout(table, name, ROW)
    return table


def _chunk_loader(
    pqcf: PqcfFile, meta: GroupMeta, dictionary: bool | None
) -> Callable[[int], ColumnVector]:
    def load(i: int) -> ColumnVector:
        dtype = pqcf.columns[i].type
        vector = decode_chunk(pqcf.buffer, meta.chunks[i], dtype, meta.row_count)
        if dictionary and isinstance(vector, PlainVector) and dtype.kind is TypeKind.STRING:
            vector = dictionary_encode(dtype, vector.to_list(), vector.validity, vector.null_count)
        return vector

    return load
