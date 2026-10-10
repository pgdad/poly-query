# PQCF v1 — PolyQuery Columnar File Format

PQCF is a single-file, immutable, columnar table format. Every engine MUST be
able to read any valid PQCF v1 file written by any other engine, and MUST
reject invalid files with `STORAGE_CORRUPT` (never crash, hang, or return
wrong data).

All integers are **little-endian**. Offsets are absolute byte offsets from the
start of the file.

## 1. File layout

```
+----------------------+  offset 0
| Header (8 bytes)     |  "PQCF" | u16 format_version = 1 | u16 flags = 0
+----------------------+  offset 8
| Column chunks …      |  byte ranges referenced from metadata (any order,
|                      |  optional zero padding between/after chunks)
+----------------------+
| Metadata (JSON)      |  UTF-8 JSON object, length M
+----------------------+
| u32 M                |  metadata length in bytes
| u32 metadata_crc32   |  CRC-32 of the M metadata bytes
| "PQCF"               |  trailing magic
+----------------------+  end of file (size S)
```

* Magic is the 4 ASCII bytes `P Q C F` (0x50 0x51 0x43 0x46).
* Metadata starts at `S − 12 − M`, which MUST be ≥ 8.
* `format_version` 0 ⇒ `STORAGE_CORRUPT`; > 1 ⇒ `STORAGE_VERSION_UNSUPPORTED`.
  `flags` ≠ 0 ⇒ `STORAGE_VERSION_UNSUPPORTED` (reserved for future use).
* Writers SHOULD start each chunk at an 8-byte aligned offset. Readers MUST
  NOT assume alignment.

### Checksums

CRC-32 as in ISO-HDLC / zlib / IEEE 802.3: reflected polynomial `0xEDB88320`,
initial value `0xFFFFFFFF`, final XOR `0xFFFFFFFF`. Check value: CRC-32 of the
ASCII bytes `123456789` is `0xCBF43926`.

## 2. Metadata

```json
{
  "format_version": 1,
  "writer": "polyquery-go 0.3.0",
  "table": "transactions",
  "row_count": 100000,
  "columns": [
    {"name": "id", "type": "INT64"},
    {"name": "amount", "type": "DECIMAL(12,2)"},
    {"name": "memo", "type": "STRING"}
  ],
  "indexes": [{"name": "tx_id_idx", "column": "id", "kind": "BTREE"}],
  "row_groups": [
    {
      "row_count": 65536,
      "chunks": [
        {"offset": 8, "length": 524288, "crc32": 2914061453,
         "encoding": "PLAIN", "null_count": 0, "min": 1, "max": 65536},
        {"offset": 524296, "length": 600000, "crc32": 1234, "encoding": "PLAIN",
         "null_count": 12, "min": "-120.50", "max": "9999.99"},
        {"offset": 1124296, "length": 4000, "crc32": 77, "encoding": "DICT",
         "null_count": 0}
      ]
    }
  ]
}
```

Required keys: `format_version` (must equal header version), `table`,
`row_count`, `columns`, `row_groups`. Optional: `writer`, `indexes` (default
`[]`), per-chunk `min`/`max` (absent or `null` = unknown). Readers MUST ignore
unknown keys at any level.

Consistency rules (violations ⇒ `STORAGE_CORRUPT`):

* column names non-empty and unique (case-insensitive); types valid per types.md;
* `row_count` = Σ row group `row_count`; each row group has exactly one chunk
  per column, in column order; a row group's `row_count` ≥ 0 (zero-row tables
  have `row_groups: []` or groups with 0 rows);
* `8 ≤ offset` and `offset + length ≤ S − 12 − M` for every chunk;
* `0 ≤ null_count ≤ row_count` of the group;
* index entries reference existing columns.

`min`/`max` statistics, if present, are exact bounds of the non-null values in
the chunk, serialized as in types.md §9 (DECIMAL as string, DATE/TIMESTAMP as
strings, FLOAT64/INT64 as numbers, STRING as string, BOOLEAN as bool). Writers
SHOULD write them for all types except STRING (optional). Readers MAY use them
for row-group skipping (predicate pushdown); readers MUST NOT trust them for
anything that affects results other than skipping, and a reader that uses them
assumes they are correct (incorrect stats are a writer bug, not detectable corruption).

## 3. Column chunk layout

A chunk holds the values of one column for the `n` rows of one row group:

```
[validity bitmap]   present iff null_count > 0: ceil(n/8) bytes
[values]            depends on encoding and type
```

Bitmaps are **LSB-first**: row `i` is bit `(i mod 8)` of byte `floor(i/8)`. In
the validity bitmap a 1 bit means *non-null*. Unused trailing bits MUST be 0
on write and MUST be ignored on read. If the validity bitmap is present, the
number of 0 bits among the first n MUST equal `null_count`.

The chunk's `crc32` is computed over its `length` bytes. The decoded size of a
chunk MUST equal `length` exactly (no trailing garbage inside a chunk).

### 3.1 Encoding `PLAIN` (all types; every writer and reader MUST support it)

| Type | Values section |
|---|---|
| BOOLEAN | ceil(n/8) bytes, LSB-first bitmap, 1 = true (null slots 0) |
| INT64 | n × i64 |
| DECIMAL(p,s) | n × i64 unscaled values (|v| < 10ᵖ) |
| FLOAT64 | n × IEEE-754 binary64 (finite) |
| DATE | n × i32 days since 1970-01-01 |
| TIMESTAMP | n × i64 microseconds since 1970-01-01 00:00:00 |
| STRING | (n+1) × u32 offsets, then the concatenated UTF-8 bytes. `offsets[0] = 0`, non-decreasing, `offsets[n]` = byte count. Value i is `bytes[offsets[i] .. offsets[i+1])`. Null slots SHOULD have zero length. |

Null slots of fixed-width types SHOULD be written as zero; readers ignore them.

### 3.2 Encoding `DICT` (STRING only)

```
u32 D                          dictionary entry count
(D+1) × u32 dict offsets       as STRING PLAIN offsets, over the dictionary bytes
dictionary UTF-8 bytes
n × u32 codes                  index into the dictionary
```
Every code of a non-null row MUST be < D; codes of null slots are ignored
(writers SHOULD write 0).

### 3.3 Encoding `RLE` (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP)

```
u32 R                          number of runs
R × { i64 value, u32 run_length }   (12 bytes per run, packed, no padding)
```
Σ run_length MUST equal n and every run_length ≥ 1. BOOLEAN values are 0/1,
DATE values are day numbers (stored widened to i64). Null slots are covered by
runs like any other slot; their values are ignored.

`DICT` and `RLE` constitute the format's *basic compression*. Writers choose
encodings per chunk (e.g. RLE when the run count is below n/4, DICT when the
distinct count is below n/2). Unknown encoding name ⇒ `STORAGE_VERSION_UNSUPPORTED`.

### 3.4 Value validity (violations ⇒ `STORAGE_CORRUPT`)

Invalid UTF-8; offsets out of range or decreasing; DECIMAL unscaled value with
more than p digits; DATE/TIMESTAMP outside the types.md range; non-finite
FLOAT64; BOOLEAN RLE value not 0/1; dictionary code ≥ D.

## 4. Validation and memory mapping

Readers MUST validate the header, footer, metadata CRC and structure at `open`.
Chunk CRCs MUST be verified before the chunk's data is used to produce any result;
this MAY happen at `open` or lazily on first access (in which case the failing
query returns `STORAGE_CORRUPT`). Either way, no result derived from a corrupt
chunk may be returned.

With `{"options":{"mmap":true}}` (capability `storage.mmap`), readers SHOULD
memory-map the file and decode lazily. The file MUST NOT be modified while
open (PQCF files are immutable; writers always create new files).

## 5. Atomic writes and crash consistency

`save` MUST be atomic with respect to crashes of the engine process and of the
operating system:

1. write the complete file to a temporary file in the **same directory**,
   named `.<target>.tmp-<unique>`;
2. flush and `fsync` the temporary file;
3. `rename` it over the target path (atomic replace);
4. `fsync` the containing directory (where supported).

**Guarantee:** at any instant (including after a crash at any point), the
target path either does not exist, holds the complete previous file, or holds
the complete new file. Temporary files left by a crash are ignored by readers
and MAY be removed by the next `save` to the same target.

Verification (harness `storage-crash` suite): the engine is killed with
SIGKILL at random points during repeated `save`s of a large table; afterwards
every target file MUST either be absent or open successfully with exactly
the expected contents. Truncated and bit-flipped files MUST yield
`STORAGE_CORRUPT`.

## 6. Versioning policy

Additive changes that old readers can safely ignore go in new metadata keys
(no version bump). Any change to chunk layouts, header, footer or semantics
requires `format_version` 2. A v2-capable reader MUST still read v1.
