#!/usr/bin/env python3
"""Reference implementation of pqledger (spec/apps/pqledger.md), used only to derive the
expected outputs of the application test cases. It does not use any PolyQuery engine: reports
are computed directly in Python. `query` is not supported (its cases are written by hand).
Never given to implementation agents.

  pqledger_ref.py [GLOBAL OPTIONS] COMMAND ...      (same command line as pqledger)
"""
from __future__ import annotations

import datetime as dt
import os
import re
import sys
from decimal import Decimal
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests/apps/pqledger"))
import pqcf_mini  # noqa: E402

TX_COLS = [("id", "INT64"), ("account", "STRING"), ("date", "DATE"), ("description", "STRING"),
           ("merchant", "STRING"), ("amount", "DECIMAL(18,2)"), ("batch", "INT64")]
BATCH_COLS = [("batch", "INT64"), ("account", "STRING"), ("file", "STRING"), ("imported", "INT64"),
              ("duplicates", "INT64")]
OVR_COLS = [("id", "INT64"), ("category", "STRING")]
NAME_RE = re.compile(r"[a-z0-9_-]{1,32}")
MONTH_RE = re.compile(r"([0-9]{4})-([0-9]{2})")
IMPORT_KEYS = {"delimiter": ",", "header": "true", "skip_lines": "0", "date_column": "Date",
               "date_format": "YYYY-MM-DD", "description_column": "Description", "amount_mode": "signed",
               "amount_column": "Amount", "debit_column": "Debit", "credit_column": "Credit",
               "decimal_separator": ".", "thousands_separator": "none", "currency_symbol": "",
               "invert_sign": "false"}
DATE_FORMATS = {"YYYY-MM-DD", "YYYYMMDD", "MM/DD/YYYY", "DD/MM/YYYY", "DD.MM.YYYY"}
NUMERIC = {"INT64", "FLOAT64"}


class Fail(Exception):
    def __init__(self, code: int, msg: str):
        super().__init__(msg)
        self.code = code


def usage(msg: str) -> Fail:
    return Fail(1, msg)


def cfgerr(msg: str) -> Fail:
    return Fail(2, msg)


# ------------------------------------------------------------------ small helpers

def ascii_upper(s: str) -> str:
    return "".join(chr(ord(c) - 32) if "a" <= c <= "z" else c for c in s)


def ascii_lower(s: str) -> str:
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in s)


def strip_st(s: str) -> str:
    return s.strip(" \t")


def is_numeric_type(t: str) -> bool:
    return t in NUMERIC or t.startswith("DECIMAL")


def parse_month(s: str) -> tuple[int, int]:
    m = MONTH_RE.fullmatch(s)
    if not m or not (1 <= int(m.group(2)) <= 12) or int(m.group(1)) < 1:
        raise usage(f"invalid month {s!r}")
    return int(m.group(1)), int(m.group(2))


def text_lines(raw: bytes) -> list[str]:
    t = raw.decode("utf-8")
    if t.startswith("﻿"):
        t = t[1:]
    lines = t.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [ln[:-1] if ln.endswith("\r") else ln for ln in lines]


def unquote(v: str) -> str:
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        inner, out, i = v[1:-1], [], 0
        while i < len(inner):
            if inner[i] == "\\" and i + 1 < len(inner) and inner[i + 1] in '"\\':
                out.append(inner[i + 1])
                i += 2
            else:
                out.append(inner[i])
                i += 1
        return "".join(out)
    return v


# ------------------------------------------------------------------ configuration

def find_config(opt: str | None) -> Path:
    if opt is not None:
        p = Path(opt)
    elif os.environ.get("PQLEDGER_CONFIG"):
        p = Path(os.environ["PQLEDGER_CONFIG"])
    else:
        p = Path("pqledger.conf")
    if not p.is_file():
        raise cfgerr(f"configuration file not found: {p}")
    return p.resolve()


def parse_config(path: Path) -> dict:
    try:
        lines = text_lines(path.read_bytes())
    except (OSError, UnicodeDecodeError) as e:
        raise cfgerr(f"cannot read {path}: {e}") from e
    sections: dict[str, dict[str, str]] = {}
    cur: dict[str, str] | None = None
    curname = ""
    for no, line in enumerate(lines, 1):
        s = strip_st(line)
        if not s or s[0] in "#;":
            continue
        if s[0] == "[":
            if not s.endswith("]"):
                raise cfgerr(f"{path.name}:{no}: bad section header")
            name = s[1:-1]
            ok = name in ("ledger", "import", "output", "engine") or (
                name.startswith("account ") and NAME_RE.fullmatch(name[8:]) is not None)
            if not ok:
                raise cfgerr(f"{path.name}:{no}: unknown section [{name}]")
            if name in sections:
                raise cfgerr(f"{path.name}:{no}: repeated section [{name}]")
            cur, curname = {}, name
            sections[name] = cur
            continue
        if "=" not in s:
            raise cfgerr(f"{path.name}:{no}: expected KEY = VALUE")
        if cur is None:
            raise cfgerr(f"{path.name}:{no}: assignment outside a section")
        k, v = strip_st(s.split("=", 1)[0]), unquote(strip_st(s.split("=", 1)[1]))
        allowed = {"ledger": {"data_dir", "rules_file", "budget_file"}, "output": {"format"},
                   "engine": {"threads", "memory_mb"}}.get(curname, set(IMPORT_KEYS))
        if k not in allowed:
            raise cfgerr(f"{path.name}:{no}: unknown key {k!r} in [{curname}]")
        if k in cur:
            raise cfgerr(f"{path.name}:{no}: repeated key {k!r}")
        cur[k] = v
        if not valid_value(k, v):
            raise cfgerr(f"{path.name}:{no}: invalid value for {k}: {v!r}")
    if "ledger" not in sections or "data_dir" not in sections["ledger"]:
        raise cfgerr("[ledger] data_dir is required")
    base = path.parent
    led = sections["ledger"]
    cfg = {"data_dir": base / led["data_dir"],
           "rules_file": base / led["rules_file"] if "rules_file" in led else None,
           "budget_file": base / led["budget_file"] if "budget_file" in led else None,
           "format": sections.get("output", {}).get("format", "table"),
           "import": sections.get("import", {}),
           "accounts": {n[8:]: d for n, d in sections.items() if n.startswith("account ")}}
    for name in [None, *cfg["accounts"]]:
        eff = effective_import(cfg, name)
        if eff["decimal_separator"] == eff["thousands_separator"]:
            raise cfgerr("decimal and thousands separators must differ")
    return cfg


def valid_value(k: str, v: str) -> bool:
    if k in ("data_dir", "rules_file", "budget_file"):
        return v != ""
    if k == "format":
        return v in ("table", "csv", "json")
    if k in ("threads", "memory_mb"):
        return re.fullmatch(r"[0-9]+", v) is not None and int(v) >= 1
    if k == "delimiter":
        return v == "tab" or (len(v) == 1 and ord(v) < 128 and v not in '"\r\n')
    if k in ("header", "invert_sign"):
        return v in ("true", "false")
    if k == "skip_lines":
        return re.fullmatch(r"[0-9]+", v) is not None
    if k.endswith("_column"):
        return v != "" and (not v.isdigit() or int(v) >= 1)
    if k == "date_format":
        return v in DATE_FORMATS
    if k == "amount_mode":
        return v in ("signed", "debit_credit")
    if k == "decimal_separator":
        return v in (".", ",")
    if k == "thousands_separator":
        return v in ("none", ",", ".", "space", "'")
    return True


def effective_import(cfg: dict, account: str | None) -> dict[str, str]:
    eff = dict(IMPORT_KEYS)
    eff.update(cfg["import"])
    if account is not None:
        eff.update(cfg["accounts"].get(account, {}))
    return eff


def parse_rules(path: Path | None) -> list[tuple[int, str, str, re.Pattern]]:
    if path is None:
        return []
    try:
        lines = text_lines(path.read_bytes())
    except (OSError, UnicodeDecodeError) as e:
        raise cfgerr(f"cannot read rules file: {e}") from e
    rules = []
    for no, line in enumerate(lines, 1):
        s = strip_st(line)
        if not s or s[0] in "#;":
            continue
        if "=" not in s:
            raise cfgerr(f"{path.name}:{no}: expected CATEGORY = PATTERN")
        cat, pats = strip_st(s.split("=", 1)[0]), s.split("=", 1)[1]
        if not NAME_RE.fullmatch(cat) or cat == "uncategorized":
            raise cfgerr(f"{path.name}:{no}: invalid category {cat!r}")
        for p in pats.split(","):
            p = strip_st(p)
            if not p or "%" in p or "_" in p:
                raise cfgerr(f"{path.name}:{no}: invalid pattern {p!r}")
            up = ascii_upper(p)
            rx = re.compile("".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in up), re.S)
            rules.append((len(rules) + 1, cat, up, rx))
    return rules


def parse_budgets(path: Path) -> dict[str, Decimal]:
    try:
        lines = text_lines(path.read_bytes())
    except (OSError, UnicodeDecodeError) as e:
        raise cfgerr(f"cannot read budget file: {e}") from e
    out: dict[str, Decimal] = {}
    for no, line in enumerate(lines, 1):
        s = strip_st(line)
        if not s or s[0] in "#;":
            continue
        if "=" not in s:
            raise cfgerr(f"{path.name}:{no}: expected CATEGORY = AMOUNT")
        cat, amt = strip_st(s.split("=", 1)[0]), strip_st(s.split("=", 1)[1])
        if not NAME_RE.fullmatch(cat) or cat == "uncategorized":
            raise cfgerr(f"{path.name}:{no}: invalid category {cat!r}")
        if not re.fullmatch(r"[0-9]{1,16}(\.[0-9]{1,2})?", amt):
            raise cfgerr(f"{path.name}:{no}: invalid amount {amt!r}")
        if cat in out:
            raise cfgerr(f"{path.name}:{no}: category {cat} listed twice")
        out[cat] = Decimal(amt).quantize(Decimal("0.01"))
    return out


# ------------------------------------------------------------------ ledger

class Ledger:
    def __init__(self, d: Path):
        self.dir = d
        if not (d / "transactions.pqcf").is_file():
            raise Fail(6, "no ledger; run pqledger init")
        try:
            self.tx = pqcf_mini.read(d / "transactions.pqcf")[1]
            self.batches = pqcf_mini.read(d / "batches.pqcf")[1]
            self.ovr = {r[0]: r[1] for r in pqcf_mini.read(d / "overrides.pqcf")[1]}
        except (OSError, pqcf_mini.PqcfError) as e:
            raise Fail(7, f"cannot read ledger: {e}") from e

    def save(self, which: list[str]) -> None:
        if "tx" in which:
            pqcf_mini.write(self.dir / "transactions.pqcf", "transactions", TX_COLS, self.tx)
        if "batches" in which:
            pqcf_mini.write(self.dir / "batches.pqcf", "batches", BATCH_COLS, self.batches)
        if "ovr" in which:
            pqcf_mini.write(self.dir / "overrides.pqcf", "overrides", OVR_COLS,
                            [[k, v] for k, v in sorted(self.ovr.items())])


def categorize(led: Ledger, rules) -> dict[int, str]:
    out = {}
    for r in led.tx:
        if r[0] in led.ovr:
            out[r[0]] = led.ovr[r[0]]
            continue
        out[r[0]] = next((c for _, c, _, rx in rules if rx.fullmatch(r[4])), "uncategorized")
    return out


# ------------------------------------------------------------------ bank CSV import

def parse_csv_records(text: str, delim: str) -> list[tuple[int, list[str]]]:
    recs, i, n, line = [], 0, len(text), 1
    while i < n:
        start_line = line
        if text[i] == "\n" or text.startswith("\r\n", i):
            i += 2 if text[i] == "\r" else 1
            line += 1
            continue
        fields, f = [], []
        while True:
            if i < n and text[i] == '"' and not f:
                i += 1
                while True:
                    if i >= n:
                        raise Fail(4, f"{start_line}: unterminated quoted field")
                    c = text[i]
                    if c == '"':
                        if i + 1 < n and text[i + 1] == '"':
                            f.append('"')
                            i += 2
                            continue
                        i += 1
                        break
                    if c == "\n":
                        line += 1
                    f.append(c)
                    i += 1
                if i < n and text[i] not in (delim, "\n") and not text.startswith("\r\n", i):
                    raise Fail(4, f"{start_line}: text after closing quote")
            while i < n and text[i] != delim and text[i] != "\n" and not text.startswith("\r\n", i):
                f.append(text[i])
                i += 1
            fields.append("".join(f))
            f = []
            if i < n and text[i] == delim:
                i += 1
                continue
            if i < n:
                i += 2 if text[i] == "\r" else 1
                line += 1
            break
        recs.append((start_line, fields))
    return recs


def parse_bank_date(s: str, fmt: str) -> dt.date | None:
    s = strip_st(s)
    pats = {"YYYY-MM-DD": r"([0-9]{4})-([0-9]{2})-([0-9]{2})", "YYYYMMDD": r"([0-9]{4})([0-9]{2})([0-9]{2})",
            "MM/DD/YYYY": r"([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})", "DD/MM/YYYY": r"([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})",
            "DD.MM.YYYY": r"([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})"}
    m = re.fullmatch(pats[fmt], s)
    if not m:
        return None
    a, b, c = (int(x) for x in m.groups())
    y, mo, d = {"YYYY-MM-DD": (a, b, c), "YYYYMMDD": (a, b, c), "MM/DD/YYYY": (c, a, b),
                "DD/MM/YYYY": (c, b, a), "DD.MM.YYYY": (c, b, a)}[fmt]
    try:
        return dt.date(y, mo, d) if y >= 1 else None
    except ValueError:
        return None


def parse_amount(s: str, eff: dict[str, str]) -> Decimal | None:
    t = strip_st(s)
    neg = False
    if len(t) >= 2 and t[0] == "(" and t[-1] == ")":
        neg, t = True, t[1:-1]
    elif t.startswith("-"):
        neg, t = True, t[1:]
    elif t.startswith("+"):
        t = t[1:]
    cs = eff["currency_symbol"]
    if cs:
        if t.startswith(cs):
            t = t[len(cs):]
        elif t.endswith(cs):
            t = t[:-len(cs)]
    t = strip_st(t)
    ts = {"none": "", ",": ",", ".": ".", "space": " ", "'": "'"}[eff["thousands_separator"]]
    if ts:
        t = t.replace(ts, "")
    if eff["decimal_separator"] == ",":
        t = t.replace(",", ".")
    if not re.fullmatch(r"[0-9]{1,16}(\.[0-9]{1,2})?", t):
        return None
    v = Decimal(t).quantize(Decimal("0.01"))
    return -v if neg else v


def normalize_merchant(desc: str) -> str:
    m = re.sub(r"[ \t]+", " ", ascii_upper(desc)).strip(" ")
    if " " in m:
        head, last = m.rsplit(" ", 1)
        if re.fullmatch(r"#[0-9]+", last) or re.fullmatch(r"[0-9]{3,}", last):
            m = head
    return m


def read_bank_file(path: Path, eff: dict[str, str]) -> list[tuple[dt.date, str, str, Decimal]]:
    name = path.name
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise Fail(4, f"{name}: cannot read: {e}") from e
    if text.startswith("﻿"):
        text = text[1:]
    skip = int(eff["skip_lines"])
    cut, base = 0, 0
    for _ in range(skip):
        j = text.find("\n", cut)
        if j < 0:
            cut = len(text)
            break
        cut = j + 1
        base += 1
    delim = "\t" if eff["delimiter"] == "tab" else eff["delimiter"]
    try:
        recs = parse_csv_records(text[cut:], delim)
    except Fail as e:
        ln, msg = str(e).split(": ", 1)
        raise Fail(4, f"{name}:{int(ln) + base}: {msg}") from e
    recs = [(ln + base, f) for ln, f in recs]
    header = None
    if eff["header"] == "true":
        if not recs:
            raise Fail(4, f"{name}: no header")
        header = [ascii_lower(strip_st(h)) for h in recs[0][1]]
        recs_data = recs[1:]
        width = len(recs[0][1])
    else:
        recs_data = recs
        width = len(recs[0][1]) if recs else 0

    def col(ref: str) -> int:
        if ref.isdigit():
            k = int(ref) - 1
            if k >= width:
                raise Fail(4, f"{name}: column {ref} beyond the record")
            return k
        if header is None:
            raise Fail(4, f"{name}: column {ref!r} needs header = true")
        try:
            return header.index(ascii_lower(ref))
        except ValueError:
            raise Fail(4, f"{name}: no column {ref!r} in the header") from None

    dc, sc = col(eff["date_column"]), col(eff["description_column"])
    if eff["amount_mode"] == "signed":
        ac = col(eff["amount_column"])
    else:
        dbc, crc = col(eff["debit_column"]), col(eff["credit_column"])
    out = []
    for ln, f in recs_data:
        if len(f) != width:
            raise Fail(4, f"{name}:{ln}: expected {width} fields, found {len(f)}")
        d = parse_bank_date(f[dc], eff["date_format"])
        if d is None:
            raise Fail(4, f"{name}:{ln}: invalid date {f[dc]!r}")
        desc = strip_st(f[sc])
        if eff["amount_mode"] == "signed":
            a = parse_amount(f[ac], eff)
            if a is None:
                raise Fail(4, f"{name}:{ln}: invalid amount {f[ac]!r}")
        else:
            de, cr = strip_st(f[dbc]), strip_st(f[crc])
            if not de and not cr:
                raise Fail(4, f"{name}:{ln}: debit and credit both empty")
            dv = parse_amount(de, eff) if de else Decimal("0.00")
            cv = parse_amount(cr, eff) if cr else Decimal("0.00")
            if dv is None or cv is None:
                raise Fail(4, f"{name}:{ln}: invalid amount")
            a = cv - dv
        if eff["invert_sign"] == "true":
            a = -a
        if a == 0:
            a = Decimal("0.00")
        if abs(a) >= Decimal("1e16"):
            raise Fail(4, f"{name}:{ln}: amount out of range")
        out.append((d, desc, normalize_merchant(desc), a))
    return out


# ------------------------------------------------------------------ output

def fmt_value(v: Any, typ: str) -> str | None:
    if v is None:
        return None
    if typ.startswith("DECIMAL"):
        s = int(typ[:-1].split(",")[1])
        q = Decimal(v).quantize(Decimal(1).scaleb(-s))
        if q == 0:
            q = abs(q)
        return f"{q:f}"
    if typ == "FLOAT64":
        r = f"{v:.6f}"
        return "0.000000" if r == "-0.000000" else r
    if typ == "BOOLEAN":
        return "true" if v else "false"
    if typ == "DATE":
        return f"{v.year:04d}-{v.month:02d}-{v.day:02d}"
    return str(v)


def render(cols: list[tuple[str, str]], rows: list[list[Any]], fmt: str) -> str:
    texts = [[fmt_value(v, t) for v, (_, t) in zip(r, cols)] for r in rows]
    if fmt == "table":
        w = [max([len(n)] + [len(r[i] or "") for r in texts]) for i, (n, _) in enumerate(cols)]
        right = [is_numeric_type(t) or t.startswith("DECIMAL") for _, t in cols]

        def line(cells: list[str]) -> str:
            return "  ".join(c.rjust(w[i]) if right[i] else c.ljust(w[i]) for i, c in enumerate(cells)).rstrip(" ")
        out = [line([n for n, _ in cols]), line(["-" * x for x in w])]
        out += [line([c or "" for c in r]) for r in texts]
        out.append(f"({len(rows)} row{'' if len(rows) == 1 else 's'})")
        return "\n".join(out) + "\n"
    if fmt == "csv":
        def q(c: str | None) -> str:
            if c is None:
                return ""
            if c == "" or any(x in c for x in ',"\r\n') or c[0] == " " or c[-1] == " ":
                return '"' + c.replace('"', '""') + '"'
            return c
        return "".join(",".join(q(c) for c in r) + "\n" for r in [[n for n, _ in cols]] + texts)

    def js(s: str) -> str:
        m = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r"}
        return '"' + "".join(m.get(c, f"\\u{ord(c):04x}" if ord(c) < 0x20 else c) for c in s) + '"'

    def jv(c: str | None, t: str) -> str:
        if c is None:
            return "null"
        if t in ("INT64", "FLOAT64", "BOOLEAN"):
            return c
        return js(c)
    return "".join("{" + ",".join(f"{js(n)}:{jv(c, t)}" for c, (n, t) in zip(r, cols)) + "}\n" for r in texts)


# ------------------------------------------------------------------ commands

class Args:
    def __init__(self, argv: list[str], opts: dict[str, bool], npos: tuple[int, int]):
        self.pos: list[str] = []
        self.opt: dict[str, str | bool] = {}
        i = 0
        while i < len(argv):
            a = argv[i]
            if a.startswith("--"):
                if a not in opts:
                    raise usage(f"unknown option {a}")
                if a in self.opt:
                    raise usage(f"repeated option {a}")
                if opts[a]:
                    if i + 1 >= len(argv):
                        raise usage(f"{a} needs a value")
                    self.opt[a] = argv[i + 1]
                    i += 2
                    continue
                self.opt[a] = True
            else:
                self.pos.append(a)
            i += 1
        if not npos[0] <= len(self.pos) <= npos[1]:
            raise usage("wrong number of arguments")


FILTERS = {"--month": True, "--from": True, "--to": True, "--account": True}


def filt(a: Args):
    if "--month" in a.opt and ("--from" in a.opt or "--to" in a.opt):
        raise usage("--month cannot be combined with --from/--to")
    lo = hi = None
    if "--month" in a.opt:
        lo = hi = parse_month(a.opt["--month"])
    if "--from" in a.opt:
        lo = parse_month(a.opt["--from"])
    if "--to" in a.opt:
        hi = parse_month(a.opt["--to"])
    if lo and hi and lo > hi:
        raise usage("--from is later than --to")
    acc = a.opt.get("--account")
    if acc is not None and not NAME_RE.fullmatch(acc):
        raise usage(f"invalid account name {acc!r}")

    def ok(r: list[Any]) -> bool:
        ym = (r[2].year, r[2].month)
        return (lo is None or ym >= lo) and (hi is None or ym <= hi) and (acc is None or r[1] == acc)
    return ok


def spent_sum(rs) -> Decimal:
    return -sum((r[5] for r in rs), Decimal("0.00"))


def run(argv: list[str], out: list[str]) -> int:
    i, gopt = 0, {}
    while i < len(argv) and argv[i].startswith("--"):
        a = argv[i]
        if a == "--help":
            gopt[a] = True
            i += 1
            continue
        if a not in ("--config", "--format") or a in gopt:
            raise usage(f"unknown or repeated option {a}")
        if i + 1 >= len(argv):
            raise usage(f"{a} needs a value")
        gopt[a] = argv[i + 1]
        i += 2
    rest = argv[i:]
    if "--help" in gopt or (rest and rest[0] == "help"):
        out.append("usage: pqledger [--config PATH] [--format table|csv|json] COMMAND ...\n")
        return 0
    if not rest:
        raise usage("missing command")
    cmd, rest = rest[0], rest[1:]
    if cmd == "version":
        out.append("pqledger 1.0.0 (reference)\n")
        return 0
    if "--format" in gopt and gopt["--format"] not in ("table", "csv", "json"):
        raise usage("invalid --format")
    if cmd == "report":
        if not rest or rest[0] not in ("monthly", "categories", "merchants"):
            raise usage("report needs monthly, categories or merchants")
        cmd, rest = "report " + rest[0], rest[1:]
    known = {"init", "import", "report monthly", "report categories", "report merchants", "budget", "accounts",
             "list", "export", "set-category", "query"}
    if cmd not in known:
        raise usage(f"unknown command {cmd}")
    # Arguments are checked before the configuration is read.
    spec = {"init": ({}, (0, 0)), "import": ({"--account": True}, (1, 1)),
            "report monthly": (FILTERS, (0, 0)), "report categories": (FILTERS, (0, 0)),
            "report merchants": ({**FILTERS, "--top": True}, (0, 0)),
            "budget": ({"--month": True, "--account": True}, (0, 0)), "accounts": ({}, (0, 0)),
            "list": ({**FILTERS, "--category": True, "--uncategorized": False}, (0, 0)),
            "export": (FILTERS, (0, 0)), "set-category": ({"--clear": False}, (1, 2)), "query": ({}, (1, 1))}[cmd]
    a = Args(rest, *spec)
    cfg = parse_config(find_config(gopt.get("--config")))
    fmt = gopt.get("--format") or cfg["format"]
    if cmd == "init":
        d = cfg["data_dir"]
        if (d / "transactions.pqcf").exists():
            raise Fail(6, "ledger already exists")
        try:
            d.mkdir(parents=True, exist_ok=True)
            pqcf_mini.write(d / "transactions.pqcf", "transactions", TX_COLS, [])
            pqcf_mini.write(d / "batches.pqcf", "batches", BATCH_COLS, [])
            pqcf_mini.write(d / "overrides.pqcf", "overrides", OVR_COLS, [])
        except OSError as e:
            raise Fail(7, str(e)) from e
        out.append("initialized ledger\n")
        return 0
    if cmd == "import":
        acc = a.opt.get("--account")
        if acc is None:
            raise usage("--account is required")
        if not NAME_RE.fullmatch(acc):
            raise usage(f"invalid account name {acc!r}")
        rules = parse_rules(cfg["rules_file"])  # noqa: F841  (a broken rules file is still an error)
        led = Ledger(cfg["data_dir"])
        recs = read_bank_file(Path(a.pos[0]), effective_import(cfg, acc))
        have: dict[tuple, int] = {}
        for r in led.tx:
            k = (r[1], r[2], r[5], r[4])
            have[k] = have.get(k, 0) + 1
        total: dict[tuple, int] = {}
        for d, _, m, amt in recs:
            k = (acc, d, amt, m)
            total[k] = total.get(k, 0) + 1
        seen: dict[tuple, int] = {}
        next_id = max((r[0] for r in led.tx), default=0) + 1
        batch = max((b[0] for b in led.batches), default=0) + 1
        imported = dups = 0
        for d, desc, m, amt in recs:
            k = (acc, d, amt, m)
            seen[k] = seen.get(k, 0) + 1
            if seen[k] <= min(total[k], have.get(k, 0)):
                dups += 1
                continue
            led.tx.append([next_id, acc, d, desc, m, amt, batch])
            next_id += 1
            imported += 1
        led.batches.append([batch, acc, Path(a.pos[0]).name, imported, dups])
        led.save(["tx", "batches"])
        out.append(f"batch {batch}: imported {imported}, duplicates {dups}\n")
        return 0
    rules = parse_rules(cfg["rules_file"])
    budgets = None
    if cmd == "budget":
        if cfg["budget_file"] is None:
            raise cfgerr("no budget_file configured")
        budgets = parse_budgets(cfg["budget_file"])
        if "--month" not in a.opt:
            raise usage("budget needs --month")
    led = Ledger(cfg["data_dir"])
    cats = categorize(led, rules)
    D = "DECIMAL(18,2)"
    if cmd == "set-category":
        if not re.fullmatch(r"[0-9]+", a.pos[0]) or int(a.pos[0]) < 1:
            raise usage("invalid transaction id")
        clear = "--clear" in a.opt
        if clear == (len(a.pos) == 2):
            raise usage("give a category or --clear")
        tid = int(a.pos[0])
        if not clear and (not NAME_RE.fullmatch(a.pos[1]) or a.pos[1] == "uncategorized"):
            raise usage("invalid category")
        if tid not in {r[0] for r in led.tx}:
            raise Fail(6, f"no transaction {tid}")
        if clear:
            led.ovr.pop(tid, None)
        else:
            led.ovr[tid] = a.pos[1]
        led.save(["ovr"])
        out.append(f"transaction {tid}: category {'cleared' if clear else a.pos[1]}\n")
        return 0
    if cmd == "query":
        raise Fail(7, "query is not supported by the reference implementation")
    if cmd == "accounts":
        accs: dict[str, list] = {}
        for r in led.tx:
            accs.setdefault(r[1], []).append(r)
        rows = [[k, len(v), sum((r[5] for r in v), Decimal("0.00")), min(r[2] for r in v), max(r[2] for r in v)]
                for k, v in sorted(accs.items())]
        out.append(render([("account", "STRING"), ("transactions", "INT64"), ("balance", D), ("first", "DATE"),
                           ("last", "DATE")], rows, fmt))
        return 0
    if cmd == "budget":
        y, m = parse_month(a.opt["--month"])
        acc = a.opt.get("--account")
        if acc is not None and not NAME_RE.fullmatch(acc):
            raise usage("invalid account name")
        rows, over = [], False
        for c in sorted(budgets):
            sp = spent_sum([r for r in led.tx if r[5] < 0 and cats[r[0]] == c and (r[2].year, r[2].month) == (y, m)
                            and (acc is None or r[1] == acc)])
            st = "ok" if sp <= budgets[c] else "over"
            over |= st == "over"
            rows.append([c, budgets[c], sp, budgets[c] - sp, st])
        out.append(render([("category", "STRING"), ("budget", D), ("spent", D), ("remaining", D),
                           ("status", "STRING")], rows, fmt))
        return 3 if over else 0
    ok = filt(a)
    txs = [r for r in led.tx if ok(r)]
    if cmd == "report monthly":
        months: dict[str, list] = {}
        for r in txs:
            months.setdefault(f"{r[2].year:04d}-{r[2].month:02d}", []).append(r)
        rows = [[k, sum((r[5] for r in v if r[5] > 0), Decimal("0.00")), spent_sum([r for r in v if r[5] < 0]),
                 sum((r[5] for r in v), Decimal("0.00")), len(v)] for k, v in sorted(months.items())]
        out.append(render([("month", "STRING"), ("income", D), ("expenses", D), ("net", D),
                           ("transactions", "INT64")], rows, fmt))
        return 0
    if cmd == "report categories":
        g: dict[str, list] = {}
        for r in txs:
            if r[5] < 0:
                g.setdefault(cats[r[0]], []).append(r)
        tot = sum((spent_sum(v) for v in g.values()), Decimal("0.00"))
        rows = []
        for k, v in g.items():
            sp = spent_sum(v)
            num, den = int(sp * 100) * 1000, int(tot * 100)
            tenths = (2 * num + den) // (2 * den) if den else 0
            rows.append([k, sp, Decimal(tenths).scaleb(-1), len(v)])
        rows.sort(key=lambda r: (-r[1], r[0]))
        out.append(render([("category", "STRING"), ("spent", D), ("share", "DECIMAL(18,1)"),
                           ("transactions", "INT64")], rows, fmt))
        return 0
    if cmd == "report merchants":
        top = a.opt.get("--top", "10")
        if not re.fullmatch(r"[0-9]+", top) or int(top) < 1:
            raise usage("invalid --top")
        g = {}
        for r in txs:
            if r[5] < 0:
                g.setdefault(r[4], []).append(r)
        rows = sorted([[k, spent_sum(v), len(v)] for k, v in g.items()], key=lambda r: (-r[1], r[0]))[:int(top)]
        out.append(render([("merchant", "STRING"), ("spent", D), ("transactions", "INT64")], rows, fmt))
        return 0
    if cmd == "list":
        if "--category" in a.opt and "--uncategorized" in a.opt:
            raise usage("--category and --uncategorized exclude each other")
        want = "uncategorized" if "--uncategorized" in a.opt else a.opt.get("--category")
        if want is not None and want != "uncategorized" and not NAME_RE.fullmatch(want):
            raise usage("invalid category")
        rows = sorted([[r[0], r[2], r[1], r[3], r[5], cats[r[0]]] for r in txs
                       if want is None or cats[r[0]] == want], key=lambda x: (x[1], x[0]))
        out.append(render([("id", "INT64"), ("date", "DATE"), ("account", "STRING"), ("description", "STRING"),
                           ("amount", D), ("category", "STRING")], rows, fmt))
        return 0
    if cmd == "export":
        rows = [[r[0], r[1], r[2], r[3], r[4], r[5], cats[r[0]], r[6]] for r in sorted(txs, key=lambda x: x[0])]
        out.append(render([("id", "INT64"), ("account", "STRING"), ("date", "DATE"), ("description", "STRING"),
                           ("merchant", "STRING"), ("amount", D), ("category", "STRING"), ("batch", "INT64")],
                          rows, fmt))
        return 0
    raise usage(cmd)


def main() -> int:
    out: list[str] = []
    try:
        rc = run(sys.argv[1:], out)
    except Fail as e:
        sys.stderr.write(f"pqledger: error: {e}\n")
        return e.code
    sys.stdout.write("".join(out))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
