#!/usr/bin/env python3
"""Reference reader/writer/validator for PQCF v1 (spec/storage/pqcf-v1.md) and v2
(spec/changes/decimal38.md: 128-bit wide decimals).

Used to (a) produce golden and deliberately-corrupted fixture files and (b)
independently validate files written by engines in the interop suite. Not an
engine; never given to implementation agents.

  pqcf.py validate FILE...          # structural + checksum validation, prints summary
  pqcf.py dump FILE                 # prints metadata and rows as JSON lines
  pqcf.py golden OUTDIR             # regenerate golden + corrupt fixtures
"""
from __future__ import annotations

import datetime as dt
import json
import re
import struct
import sys
import zlib
from decimal import Decimal
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pqref  # noqa: E402

MAGIC = b"PQCF"
FIXED = {"INT64": "<q", "FLOAT64": "<d", "TIMESTAMP": "<q", "DATE": "<i"}


def is_wide(typ: str) -> bool:
    return typ.startswith("DECIMAL") and pqref.dec_params(typ)[0] > 18


def i128(v: int) -> bytes:
    return v.to_bytes(16, "little", signed=True)


class Corrupt(Exception):
    def __init__(self, code: str, msg: str):
        super().__init__(msg)
        self.code = code


def crc32(b: bytes) -> int:
    return zlib.crc32(b) & 0xFFFFFFFF


# ------------------------------------------------------------------ value <-> physical

def to_phys(v: Any, typ: str) -> int | float | bytes | bool:
    if typ == "BOOLEAN":
        return bool(v)
    if typ == "INT64":
        return int(v)
    if typ == "FLOAT64":
        return float(v)
    if typ.startswith("DECIMAL"):
        _, s = pqref.dec_params(typ)
        return int((v if isinstance(v, Decimal) else Decimal(str(v))).scaleb(s))
    if typ == "DATE":
        return pqref.days(v)
    if typ == "TIMESTAMP":
        return pqref.micros(v)
    return v.encode("utf-8")


def from_phys(p: Any, typ: str) -> Any:
    if typ.startswith("DECIMAL"):
        _, s = pqref.dec_params(typ)
        return Decimal(p).scaleb(-s)
    if typ == "DATE":
        return dt.date(1970, 1, 1) + dt.timedelta(days=p)
    if typ == "TIMESTAMP":
        return dt.datetime(1970, 1, 1) + dt.timedelta(microseconds=p)
    if typ == "STRING":
        return p
    return p


def bitmap(bits: list[bool]) -> bytes:
    out = bytearray((len(bits) + 7) // 8)
    for i, b in enumerate(bits):
        if b:
            out[i >> 3] |= 1 << (i & 7)
    return bytes(out)


def read_bit(buf: bytes, i: int) -> bool:
    return bool(buf[i >> 3] >> (i & 7) & 1)


# ------------------------------------------------------------------ writer

def encode_chunk(values: list[Any], typ: str, encoding: str) -> tuple[bytes, dict]:
    n = len(values)
    nulls = sum(1 for v in values if v is None)
    out = bytearray()
    if nulls:
        out += bitmap([v is not None for v in values])
    phys = [None if v is None else to_phys(v, typ) for v in values]
    if encoding == "PLAIN":
        if typ == "BOOLEAN":
            out += bitmap([bool(p) for p in phys])
        elif typ == "STRING":
            offs, data = [0], bytearray()
            for p in phys:
                data += p or b""
                offs.append(len(data))
            out += struct.pack(f"<{n + 1}I", *offs) + data
        elif is_wide(typ):
            out += b"".join(i128(p or 0) for p in phys)
        elif typ.startswith("DECIMAL"):
            out += struct.pack(f"<{n}q", *[p or 0 for p in phys])
        else:
            fmt = FIXED[typ]
            out += b"".join(struct.pack(fmt, p if p is not None else 0) for p in phys)
    elif encoding == "DICT":
        assert typ == "STRING"
        d: dict[bytes, int] = {}
        for p in phys:
            if p is not None and p not in d:
                d[p] = len(d)
        entries = list(d)
        offs, data = [0], bytearray()
        for e in entries:
            data += e
            offs.append(len(data))
        out += struct.pack("<I", len(entries)) + struct.pack(f"<{len(entries) + 1}I", *offs) + data
        out += struct.pack(f"<{n}I", *[0 if p is None else d[p] for p in phys])
    elif encoding == "RLE":
        runs: list[list[int]] = []
        for p in phys:
            v = 0 if p is None else int(p)
            if runs and runs[-1][0] == v:
                runs[-1][1] += 1
            else:
                runs.append([v, 1])
        if is_wide(typ):
            out += struct.pack("<I", len(runs)) + b"".join(i128(v) + struct.pack("<I", c) for v, c in runs)
        else:
            out += struct.pack("<I", len(runs)) + b"".join(struct.pack("<qI", v, c) for v, c in runs)
    else:
        raise ValueError(encoding)
    meta: dict = {"encoding": encoding, "null_count": nulls}
    nn = [v for v in values if v is not None]
    if nn and typ != "STRING":
        meta["min"] = pqref.serialize(min(nn), typ)
        meta["max"] = pqref.serialize(max(nn), typ)
    return bytes(out), meta


def choose_encoding(values: list[Any], typ: str, mode: str) -> str:
    if mode == "plain":
        return "PLAIN"
    if mode == "dict":
        return "DICT" if typ == "STRING" else "PLAIN"
    if mode == "rle":
        return "RLE" if typ in ("BOOLEAN", "INT64", "DATE", "TIMESTAMP") or typ.startswith("DECIMAL") else "PLAIN"
    # auto
    if typ == "STRING":
        return "DICT" if len(set(values)) <= max(1, len(values) // 2) else "PLAIN"
    if typ in ("BOOLEAN", "INT64", "DATE", "TIMESTAMP") or typ.startswith("DECIMAL"):
        runs = sum(1 for i, v in enumerate(values) if i == 0 or values[i - 1] != v)
        return "RLE" if runs <= len(values) // 4 else "PLAIN"
    return "PLAIN"


def write(path: Path, table: str, columns: list[tuple[str, str]], rows: list[list[Any]],
          row_group_size: int = 65536, mode: str = "auto", indexes: list | None = None,
          writer: str = "pqcf.py reference 1.0", extra_meta: dict | None = None) -> bytes:
    version = 2 if any(is_wide(t) for _, t in columns) else 1
    body = bytearray(MAGIC + struct.pack("<HH", version, 0))
    groups = []
    for g0 in range(0, len(rows), row_group_size) if rows else []:
        grows = rows[g0:g0 + row_group_size]
        chunks = []
        for c, (_, typ) in enumerate(columns):
            vals = [r[c] for r in grows]
            enc = choose_encoding(vals, typ, mode)
            data, meta = encode_chunk(vals, typ, enc)
            while len(body) % 8:
                body.append(0)
            chunks.append({"offset": len(body), "length": len(data), "crc32": crc32(data), **meta})
            body += data
        groups.append({"row_count": len(grows), "chunks": chunks})
    meta = {"format_version": version, "writer": writer, "table": table, "row_count": len(rows),
            "columns": [{"name": n, "type": t} for n, t in columns], "indexes": indexes or [],
            "row_groups": groups}
    if extra_meta:
        meta.update(extra_meta)
    mb = json.dumps(meta, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    body += mb + struct.pack("<II", len(mb), crc32(mb)) + MAGIC
    path.write_bytes(bytes(body))
    return bytes(body)


# ------------------------------------------------------------------ reader / validator

def _check(cond: bool, msg: str, code: str = "STORAGE_CORRUPT") -> None:
    if not cond:
        raise Corrupt(code, msg)


def read(data: bytes) -> tuple[dict, list[list[Any]]]:
    S = len(data)
    _check(S >= 20, "file too short")
    _check(data[:4] == MAGIC, "bad header magic")
    ver, flags = struct.unpack_from("<HH", data, 4)
    _check(ver != 0, "version 0")
    _check(ver in (1, 2), f"unsupported version {ver}", "STORAGE_VERSION_UNSUPPORTED")
    _check(flags == 0, f"unsupported flags {flags}", "STORAGE_VERSION_UNSUPPORTED")
    _check(data[-4:] == MAGIC, "bad trailing magic")
    M, mcrc = struct.unpack_from("<II", data, S - 12)
    mstart = S - 12 - M
    _check(mstart >= 8, "metadata length out of range")
    mb = data[mstart:S - 12]
    _check(crc32(mb) == mcrc, "metadata crc mismatch")
    try:
        meta = json.loads(mb.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise Corrupt("STORAGE_CORRUPT", f"metadata json: {e}") from e
    _check(isinstance(meta, dict), "metadata not an object")
    _check(meta.get("format_version") == ver, "format_version mismatch")
    cols = meta.get("columns")
    _check(isinstance(cols, list), "columns missing")
    names = set()
    types = []
    for c in cols:
        _check(isinstance(c, dict) and isinstance(c.get("name"), str) and c["name"], "bad column")
        _check(c["name"].lower() not in names, "duplicate column")
        names.add(c["name"].lower())
        try:
            types.append(pqref.canonical_type(c.get("type", ""), 38 if ver == 2 else 18))
        except pqref.IngestError as e:
            raise Corrupt("STORAGE_CORRUPT", f"bad type {c.get('type')}") from e
    for ix in meta.get("indexes") or []:
        _check(isinstance(ix, dict) and str(ix.get("column", "")).lower() in names, "index references unknown column")
    groups = meta.get("row_groups")
    _check(isinstance(groups, list), "row_groups missing")
    total = 0
    rows: list[list[Any]] = []
    for g in groups:
        n = g.get("row_count")
        _check(isinstance(n, int) and n >= 0, "bad row_count")
        chunks = g.get("chunks")
        _check(isinstance(chunks, list) and len(chunks) == len(types), "chunk count mismatch")
        colvals = []
        for ch, typ in zip(chunks, types):
            off, ln = ch.get("offset"), ch.get("length")
            _check(isinstance(off, int) and isinstance(ln, int) and off >= 8 and ln >= 0 and off + ln <= mstart,
                   "chunk out of bounds")
            blob = data[off:off + ln]
            _check(crc32(blob) == ch.get("crc32"), "chunk crc mismatch")
            colvals.append(decode_chunk(blob, n, typ, ch))
        for i in range(n):
            rows.append([cv[i] for cv in colvals])
        total += n
    _check(total == meta.get("row_count"), "row_count mismatch")
    return meta, rows


def decode_chunk(blob: bytes, n: int, typ: str, ch: dict) -> list[Any]:
    nulls = ch.get("null_count")
    _check(isinstance(nulls, int) and 0 <= nulls <= n, "bad null_count")
    pos = 0
    valid = [True] * n
    if nulls:
        nb = (n + 7) // 8
        _check(len(blob) >= nb, "truncated validity")
        vb = blob[:nb]
        valid = [read_bit(vb, i) for i in range(n)]
        _check(valid.count(False) == nulls, "null_count disagrees with bitmap")
        pos = nb
    enc = ch.get("encoding")
    vals: list[Any]
    if enc == "PLAIN":
        if typ == "BOOLEAN":
            nb = (n + 7) // 8
            _check(len(blob) - pos == nb, "bad boolean size")
            vals = [read_bit(blob[pos:], i) for i in range(n)]
        elif typ == "STRING":
            _check(len(blob) - pos >= 4 * (n + 1), "truncated offsets")
            offs = struct.unpack_from(f"<{n + 1}I", blob, pos)
            dstart = pos + 4 * (n + 1)
            _check(offs[0] == 0 and all(offs[i] <= offs[i + 1] for i in range(n)), "bad offsets")
            _check(dstart + offs[n] == len(blob), "string data size mismatch")
            vals = []
            for i in range(n):
                try:
                    vals.append(blob[dstart + offs[i]:dstart + offs[i + 1]].decode("utf-8"))
                except UnicodeDecodeError as e:
                    raise Corrupt("STORAGE_CORRUPT", "invalid utf-8") from e
        elif is_wide(typ):
            _check(len(blob) - pos == 16 * n, "fixed-width size mismatch")
            vals = [int.from_bytes(blob[pos + 16 * i:pos + 16 * i + 16], "little", signed=True) for i in range(n)]
        else:
            fmt = "<q" if typ.startswith("DECIMAL") else FIXED[typ]
            w = struct.calcsize(fmt)
            _check(len(blob) - pos == w * n, "fixed-width size mismatch")
            vals = [struct.unpack_from(fmt, blob, pos + w * i)[0] for i in range(n)]
    elif enc == "DICT":
        _check(typ == "STRING", "DICT on non-string")
        _check(len(blob) - pos >= 4, "truncated dict")
        D = struct.unpack_from("<I", blob, pos)[0]
        pos += 4
        _check(len(blob) - pos >= 4 * (D + 1), "truncated dict offsets")
        offs = struct.unpack_from(f"<{D + 1}I", blob, pos)
        pos += 4 * (D + 1)
        _check(offs[0] == 0 and all(offs[i] <= offs[i + 1] for i in range(D)), "bad dict offsets")
        dbytes = blob[pos:pos + offs[D]]
        _check(len(dbytes) == offs[D], "truncated dict data")
        pos += offs[D]
        try:
            entries = [dbytes[offs[i]:offs[i + 1]].decode("utf-8") for i in range(D)]
        except UnicodeDecodeError as e:
            raise Corrupt("STORAGE_CORRUPT", "invalid utf-8 in dict") from e
        _check(len(blob) - pos == 4 * n, "codes size mismatch")
        codes = struct.unpack_from(f"<{n}I", blob, pos)
        vals = []
        for i, c in enumerate(codes):
            if valid[i]:
                _check(c < D, "dict code out of range")
                vals.append(entries[c])
            else:
                vals.append(None)
    elif enc == "RLE":
        _check(typ in ("BOOLEAN", "INT64", "DATE", "TIMESTAMP") or typ.startswith("DECIMAL"), "RLE on unsupported type")
        _check(len(blob) - pos >= 4, "truncated rle")
        R = struct.unpack_from("<I", blob, pos)[0]
        pos += 4
        rw = 20 if is_wide(typ) else 12
        _check(len(blob) - pos == rw * R, "rle size mismatch")
        vals = []
        for r in range(R):
            if rw == 20:
                o = pos + 20 * r
                v, c = int.from_bytes(blob[o:o + 16], "little", signed=True), struct.unpack_from("<I", blob, o + 16)[0]
            else:
                v, c = struct.unpack_from("<qI", blob, pos + 12 * r)
            _check(c >= 1, "zero-length run")
            vals.extend([v] * c)
        _check(len(vals) == n, "rle length mismatch")
        if typ == "BOOLEAN":
            _check(all(v in (0, 1) for v in vals), "bad boolean rle value")
            vals = [bool(v) for v in vals]
    else:
        raise Corrupt("STORAGE_VERSION_UNSUPPORTED", f"unknown encoding {enc}")
    out = []
    for i in range(n):
        if not valid[i]:
            out.append(None)
            continue
        p = vals[i]
        if typ.startswith("DECIMAL"):
            prec, _ = pqref.dec_params(typ)
            _check(abs(p) < 10**prec, "decimal exceeds precision")
        elif typ == "DATE":
            _check(-719162 <= p <= 2932896, "date out of range")
        elif typ == "TIMESTAMP":
            _check(-62135596800000000 <= p <= 253402300799999999, "timestamp out of range")
        elif typ == "FLOAT64":
            _check(p == p and p not in (float("inf"), float("-inf")), "non-finite float")
        out.append(from_phys(p, typ))
    return out


# ------------------------------------------------------------------ golden fixtures

def _types_table():
    cols = [("id", "INT64"), ("flag", "BOOLEAN"), ("qty", "INT64"), ("price", "DECIMAL(10,2)"),
            ("ratio", "FLOAT64"), ("label", "STRING"), ("day", "DATE"), ("at", "TIMESTAMP")]
    labels = ["red", "green", "blue", None, "ünïcödé", ""]
    rows = []
    for i in range(1, 2001):
        rows.append([
            i,
            None if i % 11 == 0 else (i % 3 == 0),
            None if i % 13 == 0 else (i // 100),              # long runs -> RLE friendly
            None if i % 17 == 0 else Decimal(i * 7 % 100000).scaleb(-2) * (-1 if i % 5 == 0 else 1),
            None if i % 19 == 0 else (i % 97) / 8.0,
            labels[i % len(labels)],
            None if i % 23 == 0 else dt.date(2020, 1, 1) + dt.timedelta(days=i % 900),
            None if i % 29 == 0 else dt.datetime(2024, 1, 1) + dt.timedelta(seconds=i * 3601, microseconds=i % 1000),
        ])
    return cols, rows


def _wide_table():
    cols = [("id", "INT64"), ("amt", "DECIMAL(38,10)"), ("big", "DECIMAL(30,0)"), ("small", "DECIMAL(10,2)")]
    unit = Decimal("123456789012345678.9012345678")
    rows = []
    for i in range(1, 61):
        rows.append([
            i,
            None if i % 9 == 0 else unit * i * (-1 if i % 4 == 0 else 1),
            Decimal((i // 10) * 10**29 + 7),                    # long runs -> RLE friendly
            None if i % 7 == 0 else Decimal(i) * Decimal("1.25"),
        ])
    top = Decimal("9999999999999999999999999999.9999999999")
    rows += [[61, top, Decimal(10**30 - 1), Decimal("99999999.99")],
             [62, -top, Decimal(-(10**30 - 1)), Decimal("-99999999.99")],
             [63, Decimal(0), Decimal(0), Decimal(0)],
             [64, None, None, None]]
    return cols, rows


def golden(outdir: Path) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    cols, rows = _types_table()
    write(outdir / "types_plain.pqcf", "types", cols, rows, row_group_size=2000, mode="plain")
    write(outdir / "types_auto.pqcf", "types", cols, rows, row_group_size=300, mode="auto",
          indexes=[{"name": "types_id_idx", "column": "id", "kind": "BTREE"},
                   {"name": "types_label_idx", "column": "label", "kind": "HASH"}])
    write(outdir / "types_dict.pqcf", "types", cols, rows, row_group_size=512, mode="dict")
    write(outdir / "types_rle.pqcf", "types", cols, rows, row_group_size=1000, mode="rle")
    write(outdir / "empty.pqcf", "empty", [("a", "INT64"), ("b", "STRING")], [], mode="plain")
    write(outdir / "forward_compat.pqcf", "fc", [("a", "INT64")], [[1], [2]], mode="plain",
          extra_meta={"future_key": {"x": [1, 2]}, "writer": "polyquery-future 9.9"})
    # people fixture with explicit types
    names, types, prow = pqref.load_csv((outdir.parent / "people.csv").read_text())
    write(outdir / "people.pqcf", "people", list(zip(names, types)), prow, row_group_size=3, mode="auto")

    # ---- corrupt variants derived from a small valid file
    small = write(outdir / "_small.pqcf", "small", [("a", "INT64"), ("s", "STRING")],
                  [[1, "x"], [2, "yy"], [None, "zzz"]], mode="plain")
    (outdir / "_small.pqcf").unlink()
    meta_len = struct.unpack_from("<I", small, len(small) - 12)[0]
    mstart = len(small) - 12 - meta_len
    meta = json.loads(small[mstart:len(small) - 12])
    bad = outdir / "corrupt"
    bad.mkdir(exist_ok=True)

    def put(name: str, b: bytes) -> None:
        (bad / name).write_bytes(b)

    def remeta(m: dict) -> bytes:
        mb = json.dumps(m, separators=(",", ":")).encode()
        return small[:mstart] + mb + struct.pack("<II", len(mb), crc32(mb)) + MAGIC

    put("bad_header_magic.pqcf", b"PQCX" + small[4:])
    put("bad_trailer_magic.pqcf", small[:-4] + b"PQCX")
    put("version3.pqcf", small[:4] + struct.pack("<HH", 3, 0) + small[8:])
    put("flags.pqcf", small[:4] + struct.pack("<HH", 1, 1) + small[8:])
    put("truncated_half.pqcf", small[: len(small) // 2])
    put("truncated_tail.pqcf", small[:-1])
    put("empty_file.pqcf", b"")
    flipped = bytearray(small)
    flipped[mstart + 5] ^= 0x01
    put("meta_bitflip.pqcf", bytes(flipped))
    flipped = bytearray(small)
    flipped[meta["row_groups"][0]["chunks"][0]["offset"]] ^= 0x10
    put("chunk_bitflip.pqcf", bytes(flipped))
    m = json.loads(json.dumps(meta))
    m["row_count"] = 4
    put("row_count_mismatch.pqcf", remeta(m))
    m = json.loads(json.dumps(meta))
    m["row_groups"][0]["chunks"][1]["offset"] = len(small) + 100
    put("chunk_out_of_bounds.pqcf", remeta(m))
    m = json.loads(json.dumps(meta))
    m["row_groups"][0]["chunks"] = m["row_groups"][0]["chunks"][:1]
    put("missing_chunk.pqcf", remeta(m))
    m = json.loads(json.dumps(meta))
    m["columns"][1]["type"] = "WIDGET"
    put("bad_type.pqcf", remeta(m))
    m = json.loads(json.dumps(meta))
    m["row_groups"][0]["chunks"][0]["encoding"] = "ZSTD"
    put("unknown_encoding.pqcf", remeta(m))
    # string chunk with invalid UTF-8 but a correct CRC
    sch = meta["row_groups"][0]["chunks"][1]
    blob = bytearray(small[sch["offset"]:sch["offset"] + sch["length"]])
    blob[-1] = 0xFF
    m = json.loads(json.dumps(meta))
    m["row_groups"][0]["chunks"][1]["crc32"] = crc32(bytes(blob))
    body = bytearray(small[:mstart])
    body[sch["offset"]:sch["offset"] + sch["length"]] = blob
    mb = json.dumps(m, separators=(",", ":")).encode()
    put("invalid_utf8.pqcf", bytes(body) + mb + struct.pack("<II", len(mb), crc32(mb)) + MAGIC)
    put("not_json_meta.pqcf", small[:mstart] + b"{not json" + struct.pack("<II", 9, crc32(b"{not json")) + MAGIC)

    # ---- PQCF v2 (CR-2 wide decimals)
    wcols, wrows = _wide_table()
    write(outdir / "wide_plain.pqcf", "wide", wcols, wrows, row_group_size=40, mode="plain",
          indexes=[{"name": "wide_amt_idx", "column": "amt", "kind": "BTREE"}])
    wide_rle = write(outdir / "wide_rle.pqcf", "wide", wcols, wrows, row_group_size=25, mode="rle")
    wl = struct.unpack_from("<I", wide_rle, len(wide_rle) - 12)[0]
    wstart = len(wide_rle) - 12 - wl
    wmeta = json.loads(wide_rle[wstart:len(wide_rle) - 12])

    def rewide(m: dict, version: int) -> bytes:
        mb = json.dumps(m, separators=(",", ":")).encode()
        return MAGIC + struct.pack("<HH", version, 0) + wide_rle[8:wstart] + mb + struct.pack("<II", len(mb), crc32(mb)) + MAGIC

    m = json.loads(json.dumps(wmeta))
    m["format_version"] = 1
    put("wide_in_v1.pqcf", rewide(m, 1))
    put("wide_version_mismatch.pqcf", rewide(wmeta, 1))
    over = write(bad / "wide_overprecision.pqcf", "wide", [("id", "INT64"), ("amt", "DECIMAL(38,10)")],
                 [[1, Decimal("1.5")], [2, Decimal(10) ** 28]], mode="plain")
    del over

    # sanity: all goldens valid, all corrupt invalid
    for p in sorted(outdir.glob("*.pqcf")):
        read(p.read_bytes())
    for p in sorted(bad.glob("*.pqcf")):
        try:
            read(p.read_bytes())
        except Corrupt:
            continue
        raise SystemExit(f"corrupt fixture unexpectedly valid: {p}")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "golden":
        golden(Path(sys.argv[2]))
        return 0
    rc = 0
    for f in sys.argv[2:]:
        try:
            meta, rows = read(Path(f).read_bytes())
        except Corrupt as e:
            print(f"{f}: {e.code}: {e}")
            rc = 1
            continue
        if cmd == "validate":
            encs = sorted({c["encoding"] for g in meta["row_groups"] for c in g["chunks"]})
            print(f"{f}: OK table={meta['table']} rows={meta['row_count']} groups={len(meta['row_groups'])} encodings={encs} writer={meta.get('writer')}")
        elif cmd == "dump":
            types = [pqref.canonical_type(c["type"], 38) for c in meta["columns"]]
            print(json.dumps({k: v for k, v in meta.items() if k != "row_groups"}))
            for r in rows:
                print(json.dumps([pqref.serialize(v, t) for v, t in zip(r, types)], ensure_ascii=False))
    return rc


if __name__ == "__main__":
    _ = re
    sys.exit(main())
