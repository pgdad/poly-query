"""Minimal PQCF v1 reader/writer for the pqledger tests (spec/storage/pqcf-v1.md).

Covers the column types a ledger uses (INT64, STRING, DATE, DECIMAL(p<=18,s)) and the PLAIN,
DICT and RLE encodings. Values: int, str, datetime.date, decimal.Decimal; None is NULL.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import struct
import zlib
from decimal import Decimal
from pathlib import Path
from typing import Any

MAGIC = b"PQCF"
EPOCH = dt.date(1970, 1, 1)


class PqcfError(Exception):
    pass


def _scale(typ: str) -> int | None:
    m = re.fullmatch(r"DECIMAL\((\d+),(\d+)\)", typ)
    return int(m.group(2)) if m else None


def _crc(b: bytes) -> int:
    return zlib.crc32(b) & 0xFFFFFFFF


def _bits(flags: list[bool]) -> bytes:
    out = bytearray((len(flags) + 7) // 8)
    for i, f in enumerate(flags):
        if f:
            out[i >> 3] |= 1 << (i & 7)
    return bytes(out)


def _phys(v: Any, typ: str) -> Any:
    s = _scale(typ)
    if s is not None:
        return int(Decimal(v).scaleb(s))
    if typ == "DATE":
        return (v - EPOCH).days
    if typ == "STRING":
        return v.encode("utf-8")
    return int(v)


def write(path: Path, table: str, columns: list[tuple[str, str]], rows: list[list[Any]],
          encoding: str = "plain", row_group_size: int = 65536) -> None:
    """encoding: 'plain', or 'compact' (DICT for strings, RLE for the other types)."""
    body = bytearray(MAGIC + struct.pack("<HH", 1, 0))
    groups = []
    for g0 in range(0, len(rows), row_group_size):
        grows = rows[g0:g0 + row_group_size]
        chunks = []
        for c, (_, typ) in enumerate(columns):
            vals = [r[c] for r in grows]
            n, nulls = len(vals), sum(v is None for v in vals)
            out = bytearray(_bits([v is not None for v in vals]) if nulls else b"")
            phys = [None if v is None else _phys(v, typ) for v in vals]
            enc = "PLAIN"
            if encoding == "compact":
                enc = "DICT" if typ == "STRING" else "RLE"
            if enc == "PLAIN" and typ == "STRING":
                offs, data = [0], bytearray()
                for p in phys:
                    data += p or b""
                    offs.append(len(data))
                out += struct.pack(f"<{n + 1}I", *offs) + data
            elif enc == "PLAIN":
                fmt = "<i" if typ == "DATE" else "<q"
                out += b"".join(struct.pack(fmt, p or 0) for p in phys)
            elif enc == "DICT":
                d: dict[bytes, int] = {}
                for p in phys:
                    if p is not None:
                        d.setdefault(p, len(d))
                offs, data = [0], bytearray()
                for e in d:
                    data += e
                    offs.append(len(data))
                out += struct.pack("<I", len(d)) + struct.pack(f"<{len(d) + 1}I", *offs) + data
                out += struct.pack(f"<{n}I", *[0 if p is None else d[p] for p in phys])
            else:
                runs: list[list[int]] = []
                for p in phys:
                    v = p or 0
                    if runs and runs[-1][0] == v:
                        runs[-1][1] += 1
                    else:
                        runs.append([v, 1])
                out += struct.pack("<I", len(runs)) + b"".join(struct.pack("<qI", v, k) for v, k in runs)
            while len(body) % 8:
                body.append(0)
            chunks.append({"offset": len(body), "length": len(out), "crc32": _crc(bytes(out)),
                           "encoding": enc, "null_count": nulls})
            body += out
        groups.append({"row_count": len(grows), "chunks": chunks})
    meta = {"format_version": 1, "writer": "pqledger tests", "table": table, "row_count": len(rows),
            "columns": [{"name": n, "type": t} for n, t in columns], "indexes": [], "row_groups": groups}
    mb = json.dumps(meta, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    body += mb + struct.pack("<II", len(mb), _crc(mb)) + MAGIC
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(bytes(body))
    tmp.replace(path)


def read(path: Path) -> tuple[list[tuple[str, str]], list[list[Any]]]:
    data = path.read_bytes()
    if len(data) < 20 or data[:4] != MAGIC or data[-4:] != MAGIC:
        raise PqcfError(f"{path.name}: not a PQCF file")
    ver = struct.unpack_from("<H", data, 4)[0]
    if ver != 1:
        raise PqcfError(f"{path.name}: format version {ver}")
    mlen, mcrc = struct.unpack_from("<II", data, len(data) - 12)
    mstart = len(data) - 12 - mlen
    mb = data[mstart:len(data) - 12]
    if _crc(mb) != mcrc:
        raise PqcfError(f"{path.name}: metadata checksum")
    meta = json.loads(mb.decode("utf-8"))
    cols = [(c["name"], c["type"]) for c in meta["columns"]]
    rows: list[list[Any]] = []
    for g in meta["row_groups"]:
        n = g["row_count"]
        colvals = []
        for ch, (_, typ) in zip(g["chunks"], cols):
            blob = data[ch["offset"]:ch["offset"] + ch["length"]]
            if _crc(blob) != ch["crc32"]:
                raise PqcfError(f"{path.name}: chunk checksum")
            colvals.append(_decode(blob, n, typ, ch))
        rows.extend([cv[i] for cv in colvals] for i in range(n))
    if len(rows) != meta["row_count"]:
        raise PqcfError(f"{path.name}: row count")
    return cols, rows


def _decode(blob: bytes, n: int, typ: str, ch: dict) -> list[Any]:
    pos, valid = 0, [True] * n
    if ch.get("null_count"):
        nb = (n + 7) // 8
        valid = [bool(blob[i >> 3] >> (i & 7) & 1) for i in range(n)]
        pos = nb
    enc = ch["encoding"]
    if enc == "PLAIN" and typ == "STRING":
        offs = struct.unpack_from(f"<{n + 1}I", blob, pos)
        d0 = pos + 4 * (n + 1)
        vals: list[Any] = [blob[d0 + offs[i]:d0 + offs[i + 1]].decode("utf-8") for i in range(n)]
    elif enc == "PLAIN":
        fmt = "<i" if typ == "DATE" else "<q"
        w = struct.calcsize(fmt)
        vals = [struct.unpack_from(fmt, blob, pos + w * i)[0] for i in range(n)]
    elif enc == "DICT":
        k = struct.unpack_from("<I", blob, pos)[0]
        offs = struct.unpack_from(f"<{k + 1}I", blob, pos + 4)
        d0 = pos + 4 + 4 * (k + 1)
        entries = [blob[d0 + offs[i]:d0 + offs[i + 1]].decode("utf-8") for i in range(k)]
        codes = struct.unpack_from(f"<{n}I", blob, d0 + offs[k])
        vals = [entries[c] if valid[i] else None for i, c in enumerate(codes)]
    elif enc == "RLE":
        r = struct.unpack_from("<I", blob, pos)[0]
        vals = []
        for j in range(r):
            v, c = struct.unpack_from("<qI", blob, pos + 4 + 12 * j)
            vals.extend([v] * c)
    else:
        raise PqcfError(f"unsupported encoding {enc}")
    out: list[Any] = []
    s = _scale(typ)
    for i in range(n):
        p = vals[i]
        if not valid[i]:
            out.append(None)
        elif s is not None:
            out.append(Decimal(p).scaleb(-s))
        elif typ == "DATE":
            out.append(EPOCH + dt.timedelta(days=p))
        else:
            out.append(p)
    return out
