#!/usr/bin/env python3
"""PolyQuery deterministic dataset generator.

All randomness comes from xoshiro256** seeded through SplitMix64, and all value
derivation uses integer arithmetic only (no libm), so output is byte-identical
on every platform and Python version >= 3.10.

Rows are generated in fixed-size chunks; chunk k of table T uses the seed
splitmix(seed ^ hash(T) ^ k), so output does not depend on the number of worker
processes.

Usage:
  pqgen.py generate --scale 1m [--families all] [--out datasets/generated] [--jobs N] [--format csv|jsonl]
  pqgen.py manifest --scale 1m            # print/write manifest with sha256 checksums
  pqgen.py verify --scale 10k             # regenerate into a temp dir and compare to committed manifest
  pqgen.py list
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import hashlib
import json
import os
import shutil
import sys
import tempfile
from bisect import bisect_right
from pathlib import Path

GENERATOR_VERSION = "1.0.0"
DEFAULT_SEED = 20261010
MASK = (1 << 64) - 1
CHUNK_ROWS = 250_000
ROOT = Path(__file__).resolve().parents[2]

# Main fact-table row counts per scale factor.
SCALES = {
    "fixture": 2_000,
    "10k": 10_000,
    "100k": 100_000,
    "1m": 1_000_000,
    "10m": 10_000_000,
    "100m": 100_000_000,
}


# ------------------------------------------------------------------ PRNG

def splitmix64(x: int) -> tuple[int, int]:
    x = (x + 0x9E3779B97F4A7C15) & MASK
    z = x
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
    return x, z ^ (z >> 31)


def rotl(x: int, k: int) -> int:
    return ((x << k) | (x >> (64 - k))) & MASK


class Rng:
    """xoshiro256** (Blackman & Vigna)."""

    __slots__ = ("s0", "s1", "s2", "s3")

    def __init__(self, seed: int):
        st = seed & MASK
        st, a = splitmix64(st)
        st, b = splitmix64(st)
        st, c = splitmix64(st)
        st, d = splitmix64(st)
        self.s0, self.s1, self.s2, self.s3 = a, b, c, d

    def next(self) -> int:
        s0, s1, s2, s3 = self.s0, self.s1, self.s2, self.s3
        result = (rotl((s1 * 5) & MASK, 7) * 9) & MASK
        t = (s1 << 17) & MASK
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = rotl(s3, 45)
        self.s0, self.s1, self.s2, self.s3 = s0, s1, s2, s3
        return result

    def below(self, n: int) -> int:
        """Uniform integer in [0, n) (Lemire's multiply-shift; tiny bias acceptable, deterministic)."""
        return (self.next() * n) >> 64

    def chance(self, per_million: int) -> bool:
        return self.below(1_000_000) < per_million


def fnv1a(s: str) -> int:
    h = 0xCBF29CE484222325
    for b in s.encode():
        h = ((h ^ b) * 0x100000001B3) & MASK
    return h


def chunk_rng(seed: int, table: str, chunk: int) -> Rng:
    return Rng(seed ^ fnv1a(table) ^ ((chunk + 1) * 0xD1B54A32D192ED03 & MASK))


class Zipf:
    """Zipf(s=1) over 1..n using an integer CDF (deterministic)."""

    def __init__(self, n: int):
        acc, cdf = 0, []
        for k in range(1, n + 1):
            acc += 10**12 // k
            cdf.append(acc)
        self.cdf, self.total = cdf, acc

    def sample(self, rng: Rng) -> int:
        return bisect_right(self.cdf, rng.below(self.total)) + 1


# ------------------------------------------------------------------ helpers

FIRST = ["Aino", "Eino", "Liam", "Olivia", "Noah", "Emma", "Mia", "Leo", "Ella", "Oscar", "Sofia", "Elias",
         "Ava", "Lucas", "Isla", "Hugo", "Nora", "Theo", "Aada", "Veeti", "Saga", "Onni", "Iris", "Max",
         "Zoe", "Arttu", "Helmi", "Kai", "Lilja", "Otto", "Venla", "Jasper"]
LAST = ["Virtanen", "Korhonen", "Nieminen", "Smith", "Johnson", "Garcia", "Muller", "Rossi", "Silva",
        "Kim", "Nguyen", "Lee", "Brown", "Martin", "Lehtonen", "Laine", "Heikkinen", "Koskinen",
        "Jarvinen", "Lindqvist", "Novak", "Kowalski", "Haddad", "Tanaka", "Okafor", "Petrov"]
COUNTRIES = ["US", "FI", "DE", "GB", "FR", "SE", "JP", "BR", "IN", "CA", "AU", "NL", "ES", "IT", "NO",
             "DK", "PL", "MX", "KR", "ZA", "EE", "IE", "CH", "AT", "BE", "PT", "NZ", "SG", "AR", "CL"]
CITIES = ["Springfield", "Riverside", "Fairview", "Kingston", "Franklin", "Clinton", "Greenville",
          "Bristol", "Salem", "Madison", "Georgetown", "Ashland", "Oxford", "Arlington", "Jackson",
          "Burlington", "Manchester", "Milton", "Newport", "Auburn"]
SEGMENTS = ["consumer", "small_business", "enterprise", "public_sector"]
CURRENCIES = ["EUR", "USD", "GBP", "SEK", "JPY"]
CATEGORIES = ["groceries", "electronics", "travel", "restaurants", "fuel", "clothing", "health",
              "entertainment", "utilities", "insurance", "education", "home", "garden", "sports",
              "books", "toys", "beauty", "pets", "automotive", "services"]
TX_STATUS = ["approved", "declined", "pending", "refunded"]
ORDER_STATUS = ["placed", "paid", "shipped", "delivered", "returned", "cancelled"]
BRANDS = ["Acme", "Globex", "Initech", "Umbrella", "Hooli", "Vandelay", "Stark", "Wayne", "Tyrell",
          "Wonka", "Cyberdyne", "Soylent"]
SENSOR_STATUS = ["ok", "ok", "ok", "ok", "ok", "ok", "warn", "error"]
WORDS = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
         "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"]

EPOCH = dt.datetime(1970, 1, 1)
T0 = int((dt.datetime(2023, 1, 1) - EPOCH).total_seconds())  # 2023-01-01
TWO_YEARS = 2 * 365 * 86400


def fmt_ts(sec: int, micros: int = 0) -> str:
    t = EPOCH + dt.timedelta(seconds=sec, microseconds=micros)
    s = f"{t.year:04d}-{t.month:02d}-{t.day:02d} {t.hour:02d}:{t.minute:02d}:{t.second:02d}"
    return s + (f".{t.microsecond:06d}" if t.microsecond else "")


def fmt_date(days: int) -> str:
    d = dt.date(1970, 1, 1) + dt.timedelta(days=days)
    return f"{d.year:04d}-{d.month:02d}-{d.day:02d}"


def fmt_cents(c: int, scale: int = 2) -> str:
    sign = "-" if c < 0 else ""
    c = abs(c)
    q, r = divmod(c, 10**scale)
    return f"{sign}{q}.{r:0{scale}d}" if scale else f"{sign}{q}"


def fmt_fixed(v: int, scale: int) -> str:
    """Integer v / 10^scale as text (used for FLOAT64 columns; exact decimal text)."""
    return fmt_cents(v, scale)


def amount_cents(rng: Rng) -> int:
    """Heavy-tailed positive amount in cents (integer-only, roughly log-uniform)."""
    band = rng.below(100)
    if band < 60:
        return 100 + rng.below(9_900)            # 1.00 .. 99.99
    if band < 90:
        return 10_000 + rng.below(90_000)        # 100 .. 999.99
    if band < 99:
        return 100_000 + rng.below(900_000)      # 1k .. 9999.99
    return 1_000_000 + rng.below(99_000_000)     # 10k .. 999999.99


def csv_field(v) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    s = str(v)
    if s == "" or any(c in s for c in ',"\n\r') or s != s.strip():
        return '"' + s.replace('"', '""') + '"'
    return s


def json_value(v, typ: str):
    if v is None:
        return None
    if typ in ("INT64",):
        return int(v)
    if typ == "FLOAT64":
        return float(v) if not isinstance(v, str) else float(v)
    if typ == "BOOLEAN":
        return bool(v)
    return str(v)


# ------------------------------------------------------------------ table definitions
# Each table: name -> (rows_fn(scale_rows) -> int, schema list, row_fn(rng, row_index, ctx) -> list)

def sizes(n: int) -> dict:
    return {
        "customers": max(100, n // 10),
        "merchants": max(50, n // 100),
        "products": max(50, min(100_000, n // 50)),
        "sensors": max(10, min(10_000, n // 1000)),
        "orders": max(100, n // 4),
    }


def t_customers(rng: Rng, i: int, ctx: dict) -> list:
    cid = i + 1
    first, last = FIRST[rng.below(len(FIRST))], LAST[rng.below(len(LAST))]
    country = COUNTRIES[ctx["zipf_country"].sample(rng) - 1]
    signup = (T0 // 86400) - 3650 + rng.below(3650 + 700)
    return [
        cid,
        f"{first} {last}",
        f"{first.lower()}.{last.lower()}{cid}@example.com",
        country,
        CITIES[rng.below(len(CITIES))],
        SEGMENTS[ctx["zipf_segment"].sample(rng) - 1],
        fmt_date(signup),
        1940 + rng.below(66),
        fmt_cents(rng.below(50_000) * 100),
        rng.chance(850_000),
        None if rng.chance(400_000) else rng.below(100_000),
    ]


S_CUSTOMERS = [("customer_id", "INT64"), ("name", "STRING"), ("email", "STRING"), ("country", "STRING"),
               ("city", "STRING"), ("segment", "STRING"), ("signup_date", "DATE"), ("birth_year", "INT64"),
               ("credit_limit", "DECIMAL(12,2)"), ("is_active", "BOOLEAN"), ("loyalty_points", "INT64")]


def t_transactions(rng: Rng, i: int, ctx: dict) -> list:
    sec = T0 + rng.below(TWO_YEARS)
    amt = amount_cents(rng)
    return [
        i + 1,
        ctx["zipf_customer"].sample(rng),                    # skewed foreign key
        1 + rng.below(ctx["n_merchants"]),                   # high-cardinality uniform
        fmt_cents(amt),
        CURRENCIES[ctx["zipf_currency"].sample(rng) - 1],    # low-cardinality skewed
        CATEGORIES[ctx["zipf_category"].sample(rng) - 1],
        fmt_ts(sec, rng.below(1000) * 1000),
        TX_STATUS[rng.below(4)],
        rng.chance(1_000),                                   # 0.1% fraud
        None if rng.chance(300_000) else fmt_cents(amt // 100 + rng.below(50)),
        rng.below(1000),                                     # uniform group key (1000 groups)
    ]


S_TRANSACTIONS = [("tx_id", "INT64"), ("customer_id", "INT64"), ("merchant_id", "INT64"),
                  ("amount", "DECIMAL(12,2)"), ("currency", "STRING"), ("category", "STRING"),
                  ("ts", "TIMESTAMP"), ("status", "STRING"), ("is_fraud", "BOOLEAN"),
                  ("fee", "DECIMAL(10,2)"), ("bucket", "INT64")]


def t_sensor_readings(rng: Rng, i: int, ctx: dict) -> list:
    ns = ctx["n_sensors"]
    sensor = (i % ns) + 1
    step = i // ns
    sec = T0 + step * 60 + rng.below(5)
    temp = 1500 + rng.below(1500) + (sensor % 7) * 100       # centi-degrees
    return [
        sensor,
        fmt_ts(sec),
        fmt_fixed(temp, 2),
        None if rng.chance(50_000) else fmt_fixed(2000 + rng.below(6000), 2),
        fmt_fixed(98_000 + rng.below(5_000), 1),
        SENSOR_STATUS[rng.below(len(SENSOR_STATUS))],
    ]


S_SENSORS = [("sensor_id", "INT64"), ("ts", "TIMESTAMP"), ("temperature", "FLOAT64"),
             ("humidity", "FLOAT64"), ("pressure", "FLOAT64"), ("status", "STRING")]


def t_products(rng: Rng, i: int, ctx: dict) -> list:
    pid = i + 1
    return [
        pid,
        f"{WORDS[rng.below(len(WORDS))]}-{WORDS[rng.below(len(WORDS))]}-{pid}",
        CATEGORIES[rng.below(len(CATEGORIES))],
        BRANDS[ctx["zipf_brand"].sample(rng) - 1],
        fmt_cents(99 + rng.below(99_900)),
        fmt_fixed(10 + rng.below(50_000), 3),
        fmt_date(T0 // 86400 - rng.below(2000)),
    ]


S_PRODUCTS = [("product_id", "INT64"), ("name", "STRING"), ("category", "STRING"), ("brand", "STRING"),
              ("price", "DECIMAL(10,2)"), ("weight_kg", "FLOAT64"), ("released", "DATE")]


def t_orders(rng: Rng, i: int, ctx: dict) -> list:
    return [
        i + 1,
        ctx["zipf_customer"].sample(rng),
        fmt_date(T0 // 86400 + rng.below(730)),
        ORDER_STATUS[rng.below(len(ORDER_STATUS))],
        1 + rng.below(5),                                    # number of items (see order_items)
    ]


S_ORDERS = [("order_id", "INT64"), ("customer_id", "INT64"), ("order_date", "DATE"),
            ("status", "STRING"), ("item_count", "INT64")]


def t_order_items(rng: Rng, i: int, ctx: dict) -> list:
    # Each order gets exactly 4 lines (simplifies deterministic chunking): row i -> order i//4 + 1.
    return [
        i // 4 + 1,
        i % 4 + 1,
        ctx["zipf_product"].sample(rng),
        1 + rng.below(10),
        fmt_cents(99 + rng.below(20_000)),
        None if rng.chance(800_000) else fmt_cents(rng.below(500)),
    ]


S_ORDER_ITEMS = [("order_id", "INT64"), ("line_no", "INT64"), ("product_id", "INT64"),
                 ("quantity", "INT64"), ("unit_price", "DECIMAL(10,2)"), ("discount", "DECIMAL(10,2)")]


def t_nulls(rng: Rng, i: int, ctx: dict) -> list:
    return [
        i + 1,
        None if rng.chance(500_000) else rng.below(1000),
        None if rng.chance(900_000) else rng.below(10),
        None if rng.chance(700_000) else WORDS[rng.below(len(WORDS))],
        None if rng.chance(950_000) else fmt_fixed(rng.below(100_000), 2),
        None if rng.chance(600_000) else rng.chance(500_000),
        None if rng.chance(990_000) else fmt_date(19000 + rng.below(1000)),
    ]


S_NULLS = [("id", "INT64"), ("n50", "INT64"), ("n90", "INT64"), ("s70", "STRING"), ("f95", "FLOAT64"),
           ("b60", "BOOLEAN"), ("d99", "DATE")]

WIDE_COLS = 100


def t_wide(rng: Rng, i: int, ctx: dict) -> list:
    row = [i + 1]
    for c in range(WIDE_COLS):
        k = c % 5
        if k == 0:
            row.append(rng.below(1_000_000))
        elif k == 1:
            row.append(fmt_fixed(rng.below(1_000_000), 3))
        elif k == 2:
            row.append(WORDS[rng.below(len(WORDS))])
        elif k == 3:
            row.append(rng.chance(500_000))
        else:
            row.append(fmt_cents(rng.below(10_000_000)))
    return row


S_WIDE = [("id", "INT64")] + [(f"c{c:03d}", ["INT64", "FLOAT64", "STRING", "BOOLEAN", "DECIMAL(12,2)"][c % 5])
                              for c in range(WIDE_COLS)]


def t_sortkeys(rng: Rng, i: int, ctx: dict) -> list:
    n = ctx["rows"]
    return [
        i + 1,
        rng.below(max(1, n // 10)),                          # many duplicates
        rng.next() >> 1,                                     # nearly unique 63-bit
        "".join(chr(97 + rng.below(26)) for _ in range(1 + rng.below(12))),
        fmt_fixed(rng.below(10_000_000) - 5_000_000, 4),
    ]


S_SORTKEYS = [("id", "INT64"), ("dup_key", "INT64"), ("uniq_key", "INT64"), ("str_key", "STRING"),
              ("float_key", "FLOAT64")]

# family -> list of (table, schema, row_fn, row_count_fn)
FAMILIES = {
    "customers": [("customers", S_CUSTOMERS, t_customers, lambda n: sizes(n)["customers"])],
    "financial": [("transactions", S_TRANSACTIONS, t_transactions, lambda n: n)],
    "timeseries": [("sensor_readings", S_SENSORS, t_sensor_readings, lambda n: n)],
    "join": [("products", S_PRODUCTS, t_products, lambda n: sizes(n)["products"]),
             ("orders", S_ORDERS, t_orders, lambda n: sizes(n)["orders"]),
             ("order_items", S_ORDER_ITEMS, t_order_items, lambda n: sizes(n)["orders"] * 4)],
    "nulls": [("nulls_heavy", S_NULLS, t_nulls, lambda n: n)],
    "wide": [("wide", S_WIDE, t_wide, lambda n: max(1000, n // 10))],
    "sort": [("sort_keys", S_SORTKEYS, t_sortkeys, lambda n: n)],
}


def context(n: int) -> dict:
    sz = sizes(n)
    return {
        "rows": n,
        "n_merchants": sz["merchants"],
        "n_sensors": sz["sensors"],
        "zipf_country": Zipf(len(COUNTRIES)),
        "zipf_segment": Zipf(len(SEGMENTS)),
        "zipf_currency": Zipf(len(CURRENCIES)),
        "zipf_category": Zipf(len(CATEGORIES)),
        "zipf_brand": Zipf(len(BRANDS)),
        "zipf_customer": Zipf(sz["customers"]),
        "zipf_product": Zipf(sz["products"]),
    }


_CTX_CACHE: dict = {}


def _ctx(n: int) -> dict:
    if n not in _CTX_CACHE:
        _CTX_CACHE[n] = context(n)
    return _CTX_CACHE[n]


def gen_chunk(args: tuple) -> tuple[int, str]:
    family, table, base_rows, total, start, count, seed, out_path, fmt = args
    fn = next(t for t in FAMILIES[family] if t[0] == table)
    schema, row_fn = fn[1], fn[2]
    ctx = dict(_ctx(base_rows))
    ctx["rows"] = total
    rng = chunk_rng(seed, table, start // CHUNK_ROWS)
    with open(out_path, "w", encoding="utf-8", newline="") as fh:
        if fmt == "csv":
            for i in range(start, start + count):
                fh.write(",".join(csv_field(v) for v in row_fn(rng, i, ctx)) + "\n")
        else:
            names = [c for c, _ in schema]
            types = [t for _, t in schema]
            for i in range(start, start + count):
                row = row_fn(rng, i, ctx)
                obj = {n: json_value(v, t) for n, t, v in zip(names, types, row)}
                fh.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    return start, out_path


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def generate(scale: str, families: list[str], out: Path, jobs: int, seed: int, fmt: str, quiet: bool = False) -> dict:
    base = SCALES[scale]
    target = out / scale
    target.mkdir(parents=True, exist_ok=True)
    manifest = {"generator": "pqgen", "generator_version": GENERATOR_VERSION, "seed": seed, "scale": scale,
                "base_rows": base, "format": fmt, "tables": {}}
    for fam in families:
        for table, schema, _fn, rows_fn in FAMILIES[fam]:
            total = rows_fn(base)
            ext = "csv" if fmt == "csv" else "jsonl"
            final = target / f"{table}.{ext}"
            tmpdir = Path(tempfile.mkdtemp(prefix=f"pqgen-{table}-", dir=target))
            tasks = []
            for k, start in enumerate(range(0, total, CHUNK_ROWS)):
                cnt = min(CHUNK_ROWS, total - start)
                tasks.append((fam, table, base, total, start, cnt, seed, str(tmpdir / f"{k:06d}"), fmt))
            if jobs > 1 and len(tasks) > 1:
                with cf.ProcessPoolExecutor(max_workers=jobs) as ex:
                    parts = sorted(ex.map(gen_chunk, tasks))
            else:
                parts = sorted(gen_chunk(t) for t in tasks)
            with open(final, "wb") as w:
                if fmt == "csv":
                    w.write((",".join(c for c, _ in schema) + "\n").encode())
                for _, p in parts:
                    with open(p, "rb") as r:
                        shutil.copyfileobj(r, w, 1 << 22)
            shutil.rmtree(tmpdir)
            schema_path = target / f"{table}.schema.json"
            schema_path.write_text(json.dumps([{"name": c, "type": t} for c, t in schema]) + "\n")
            manifest["tables"][table] = {"family": fam, "file": final.name, "schema_file": schema_path.name,
                                         "rows": total, "bytes": final.stat().st_size, "sha256": sha256_file(final),
                                         "columns": [{"name": c, "type": t} for c, t in schema]}
            if not quiet:
                print(f"  {scale}/{final.name}: {total} rows, {final.stat().st_size} bytes", flush=True)
    return manifest


def manifest_path(scale: str, fmt: str) -> Path:
    return ROOT / "datasets/manifests" / f"{scale}{'' if fmt == 'csv' else '-' + fmt}.json"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("generate", "verify"):
        p = sub.add_parser(name)
        p.add_argument("--scale", required=True, choices=list(SCALES))
        p.add_argument("--families", default="all")
        p.add_argument("--out", default=str(ROOT / "datasets/generated"))
        p.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
        p.add_argument("--seed", type=int, default=DEFAULT_SEED)
        p.add_argument("--format", choices=["csv", "jsonl"], default="csv")
        p.add_argument("--write-manifest", action="store_true")
    sub.add_parser("list")
    args = ap.parse_args()

    if args.cmd == "list":
        for fam, tables in FAMILIES.items():
            for t in tables:
                print(f"{fam:12} {t[0]:18} " + ", ".join(f"{s}={t[3](n)}" for s, n in SCALES.items()))
        return 0

    fams = list(FAMILIES) if args.families == "all" else args.families.split(",")
    if args.cmd == "generate":
        m = generate(args.scale, fams, Path(args.out), args.jobs, args.seed, args.format)
        (Path(args.out) / args.scale / "manifest.json").write_text(json.dumps(m, indent=1) + "\n")
        if args.write_manifest:
            manifest_path(args.scale, args.format).write_text(json.dumps(m, indent=1, sort_keys=True) + "\n")
        return 0

    # verify: regenerate twice into temp dirs; compare with each other and with committed manifest
    committed = manifest_path(args.scale, args.format)
    with tempfile.TemporaryDirectory() as t1:
        m1 = generate(args.scale, fams, Path(t1), args.jobs, args.seed, args.format, quiet=True)
    with tempfile.TemporaryDirectory() as t2:
        m2 = generate(args.scale, fams, Path(t2), max(1, args.jobs // 2), args.seed, args.format, quiet=True)
    ok = True
    for t, info in m1["tables"].items():
        if m2["tables"][t]["sha256"] != info["sha256"]:
            print(f"NON-DETERMINISTIC: {t}")
            ok = False
    if committed.exists():
        cm = json.loads(committed.read_text())
        for t, info in m1["tables"].items():
            exp = cm["tables"].get(t, {}).get("sha256")
            if exp and exp != info["sha256"]:
                print(f"CHECKSUM MISMATCH vs committed manifest: {t}")
                ok = False
            elif exp:
                print(f"  ok {t} {info['sha256'][:16]}")
    else:
        print(f"(no committed manifest at {committed}; determinism check only)")
    print("verify:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
