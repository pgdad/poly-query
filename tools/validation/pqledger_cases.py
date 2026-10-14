#!/usr/bin/env python3
"""Builds the pqledger test cases: tests/apps/pqledger/{cases,embed} (public) and
tests/apps/hidden/pqledger/{cases,embed} (withheld from agents).

Scenarios (inputs and commands) are defined here; the expected exit status, stdout and ledger
contents come from the reference implementation (pqledger_ref.py), which uses no engine.
`query` and embed-demo expectations are computed here directly from the scenario data.

  pqledger_cases.py            # (re)write all case files
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/validation"))
sys.path.insert(0, str(ROOT / "tests/apps/pqledger"))
import pqledger_ref as ref  # noqa: E402
import runner as trunner  # noqa: E402

REF = ROOT / "tools/validation/pqledger_ref.py"
PUBLIC = ROOT / "tests/apps/pqledger"
HIDDEN = ROOT / "tests/apps/hidden/pqledger"
D2 = "DECIMAL(18,2)"

CONF = """[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf
"""
CARD = """
[account card]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true
"""
GIRO = """
[account giro]
delimiter = ;
skip_lines = 2
date_column = Buchungstag
date_format = DD.MM.YYYY
description_column = Verwendungszweck
amount_mode = debit_credit
debit_column = Soll
credit_column = Haben
decimal_separator = ,
thousands_separator = .
"""
RULES = """# first match wins
groceries = WHOLE FOODS*, TRADER JOE*, SAFEWAY, REWE*, EDEKA*, LIDL*
coffee = SQ *BLUE BOTTLE*, STARBUCKS*, CAFé*
transport = SHELL*, CHEVRON*, UBER*, LYFT*, ARAL*, DB VERTRIEB*
housing = RENT*, MIETE*
income = PAYROLL*, GEHALT*
shopping = AMAZON*, HOME DEPOT, REI
utilities = PACIFIC GAS*, COMCAST*, STADTWERKE*, TELEKOM*
"""
BUDGETS = """groceries = 600
coffee = 30.00
transport = 200
shopping = 150.5
"""


def bank(style: str, frm: str, to: str, seed: int = 1, per_month: int = 12) -> str:
    gen = ROOT / "datasets/generators/bankgen.py"
    return subprocess.run([sys.executable, str(gen), "--style", style, "--from", frm, "--to", to, "--seed", str(seed),
                           "--per-month", str(per_month)], check=True, capture_output=True).stdout.decode("utf-8")


def run_ref(tmp: Path, args: list[str], env: dict, cwd: str = ".") -> tuple[int, str, str]:
    p = subprocess.run([sys.executable, str(REF), *args], cwd=tmp / cwd, env=env, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8"), p.stderr.decode("utf-8")


def ledger_rows(d: Path) -> dict:
    out = {}
    for t in trunner.TABLES:
        _, rows = trunner.pqcf_mini.read(d / f"{t}.pqcf")
        out[t] = [[trunner.jsonable(v) for v in r] for r in rows]
    return out


def ref_state(tmp: Path, conf: str = "pqledger.conf"):
    cfg = ref.parse_config(tmp / conf)
    led = ref.Ledger(cfg["data_dir"])
    cats = ref.categorize(led, ref.parse_rules(cfg["rules_file"]))
    budgets = ref.parse_budgets(cfg["budget_file"]) if cfg["budget_file"] else {}
    return led, cats, ref.parse_rules(cfg["rules_file"]), budgets


def build(sc: dict) -> dict:
    """Run the scenario on the reference; return the case with expectations filled in."""
    tmp = Path(tempfile.mkdtemp(prefix="pqlcase-"))
    try:
        trunner.write_files(tmp, sc)
        env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "LANG": "C.UTF-8", **(sc.get("env") or {})}
        steps = []
        for st in sc["steps"]:
            if "write" in st:
                trunner.write_files(tmp, {"files": st["write"]})
                steps.append(st)
            elif "ledger" in st:
                steps.append({"ledger": {"dir": st["ledger"], **ledger_rows(tmp / st["ledger"])}})
            elif "query" in st:
                led, cats, rules, budgets = ref_state(tmp)
                cols, rows = st["fn"](led, cats, rules, budgets)
                fmt = st.get("format", "table")
                args = (["--format", fmt] if "format" in st else []) + ["query", st["query"]]
                steps.append({"args": args, "exit": 0, "stdout": ref.render(cols, rows, fmt)})
            elif "query_error" in st:
                steps.append({"args": ["query", st["query_error"]], "exit": 5, "stderr_contains": [st["code"]]})
            else:
                rc, out, err = run_ref(tmp, st["args"], env, st.get("cwd", "."))
                if rc not in (0, 3) and not err.startswith("pqledger: error: "):
                    raise SystemExit(f"{sc['name']}: reference failed unexpectedly: {err}")
                s = {"args": st["args"], "exit": rc}
                if "cwd" in st:
                    s["cwd"] = st["cwd"]
                if rc in (0, 3):
                    s["stdout"] = out
                if "contains" in st:
                    s["stderr_contains"] = st["contains"]
                if "timeout" in st:
                    s["timeout"] = st["timeout"]
                if "expect_exit" in st and st["expect_exit"] != rc:
                    raise SystemExit(f"{sc['name']}: step {st['args']} exit {rc} != {st['expect_exit']}: {err}")
                steps.append(s)
        case = {k: sc[k] for k in ("name", "description", "files", "files_b64", "generate", "seed_ledger", "env")
                if sc.get(k)}
        case["steps"] = steps
        return case
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def R(*args, **kw) -> dict:
    return {"args": list(args), **kw}


def base_files(**extra) -> dict:
    files = {"pqledger.conf": CONF + CARD + GIRO, "rules.conf": RULES, "budgets.conf": BUDGETS}
    files.update(extra)
    return files


# ------------------------------------------------------------------ query expectations (computed from data)

def q_count(led, cats, rules, budgets):
    return [("n", "INT64")], [[len(led.tx)]]


def q_by_category(led, cats, rules, budgets):
    g: dict[str, list] = {}
    for r in led.tx:
        g.setdefault(cats[r[0]], []).append(r[5])
    return [("category", "STRING"), ("n", "INT64"), ("total", D2)], \
        [[k, len(v), sum(v, Decimal("0.00"))] for k, v in sorted(g.items())]


def q_rules(led, cats, rules, budgets):
    return [("rule_no", "INT64"), ("category", "STRING"), ("pattern", "STRING")], \
        [[n, c, p] for n, c, p, _ in rules if c == "coffee"]


def q_budgets(led, cats, rules, budgets):
    return [("category", "STRING"), ("amount", D2)], [[c, a] for c, a in sorted(budgets.items()) if a > 100]


def q_batches(led, cats, rules, budgets):
    return [("batch", "INT64"), ("file", "STRING"), ("imported", "INT64")], [[b[0], b[2], b[3]] for b in led.batches]


def q_override_join(led, cats, rules, budgets):
    rows = [[r[0], ov] for r in led.tx for k, ov in led.ovr.items() if k == r[0]]
    return [("id", "INT64"), ("category", "STRING")], sorted(rows)


def q_big_tx(led, cats, rules, budgets):
    rows = sorted([[r[0], r[4], r[5]] for r in led.tx if r[5] <= Decimal("-1000")], key=lambda x: x[0])
    return [("id", "INT64"), ("merchant", "STRING"), ("amount", D2)], rows


# ------------------------------------------------------------------ scenarios

def public_scenarios() -> list[dict]:
    chk = bank("us-checking", "2026-01", "2026-02", seed=1, per_month=10)
    chk2 = bank("us-checking", "2026-02", "2026-03", seed=1, per_month=10)  # overlaps February
    card = bank("us-card", "2026-01", "2026-02", seed=2, per_month=8)
    giro = bank("de-giro", "2026-01", "2026-02", seed=3, per_month=8)
    S = []
    S.append({"name": "init", "description": "init creates an empty ledger; a second init fails",
              "files": base_files(), "steps": [R("init"), {"ledger": "ledger"}, R("init", expect_exit=6),
                                                R("accounts"), R("--format", "json", "accounts")]})
    S.append({"name": "import-checking", "description": "signed amounts, re-import is all duplicates",
              "files": base_files(**{"chk.csv": chk}),
              "steps": [R("init"), R("import", "chk.csv", "--account", "checking"), {"ledger": "ledger"},
                        R("import", "chk.csv", "--account", "checking"), {"ledger": "ledger"}, R("accounts")]})
    S.append({"name": "import-overlap", "description": "overlapping statements import only the new rows",
              "files": base_files(**{"jan-feb.csv": chk, "feb-mar.csv": chk2}),
              "steps": [R("init"), R("import", "jan-feb.csv", "--account", "checking"),
                        R("import", "feb-mar.csv", "--account", "checking"), {"ledger": "ledger"},
                        R("report", "monthly")]})
    S.append({"name": "repeated-identical", "description": "identical rows within one file are real transactions",
              "files": base_files(**{
                  "a.csv": "Date,Description,Amount\n2026-03-02,Starbucks Store 12,-4.50\n"
                           "2026-03-02,Starbucks Store 12,-4.50\n2026-03-02,Starbucks Store 12,-4.50\n",
                  "b.csv": "Date,Description,Amount\n2026-03-02,STARBUCKS STORE 12,-4.50\n"
                           "2026-03-02,Starbucks  Store 12,-4.50\n2026-03-02,Starbucks Store 12,-4.50\n"
                           "2026-03-02,Starbucks Store 12,-4.50\n2026-03-03,Starbucks Store 12,-4.50\n"}),
              "steps": [R("init"), R("import", "a.csv", "--account", "checking"),
                        R("import", "b.csv", "--account", "checking"), R("import", "a.csv", "--account", "savings"),
                        {"ledger": "ledger"}, R("export")]})
    S.append({"name": "import-card", "description": "MM/DD/YYYY, currency symbol, thousands, parentheses, invert_sign",
              "files": base_files(**{"card.csv": card}),
              "steps": [R("init"), R("import", "card.csv", "--account", "card"), {"ledger": "ledger"},
                        R("report", "merchants", "--top", "5")]})
    S.append({"name": "import-giro", "description": "semicolons, preamble, debit/credit, comma decimals, CRLF",
              "files": base_files(**{"giro.csv": giro}),
              "steps": [R("init"), R("import", "giro.csv", "--account", "giro"), {"ledger": "ledger"},
                        R("list", "--month", "2026-01")]})
    S.append({"name": "import-errors", "description": "a bad record rejects the whole file",
              "files": base_files(**{
                  "good.csv": "Date,Description,Amount\n2026-01-05,Lunch,-12.00\n",
                  "bad-date.csv": "Date,Description,Amount\n2026-01-05,Lunch,-12.00\n2026-02-30,Dinner,-30.00\n",
                  "bad-amount.csv": "Date,Description,Amount\n2026-01-05,Lunch,-12.005\n",
                  "bad-fields.csv": "Date,Description,Amount\n2026-01-05,Lunch,-12.00\n\n"
                                    "\"2026-01-06\",\"Multi\nline\",-1.00\n2026-01-07,Extra,1.00,x\n",
                  "no-col.csv": "Day,Description,Amount\n2026-01-05,Lunch,-12.00\n"}),
              "steps": [R("init"), R("import", "good.csv", "--account", "checking"),
                        R("import", "bad-date.csv", "--account", "checking", contains=["bad-date.csv:3:"]),
                        R("import", "bad-amount.csv", "--account", "checking", contains=["bad-amount.csv:2:"]),
                        R("import", "bad-fields.csv", "--account", "checking", contains=["bad-fields.csv:6:"]),
                        R("import", "no-col.csv", "--account", "checking"),
                        R("import", "missing.csv", "--account", "checking"),
                        {"ledger": "ledger"}]})
    S.append({"name": "merchant-normalization", "description": "upper-casing, spaces, store-number tokens",
              "files": base_files(**{"m.csv": (
                  "Date,Description,Amount\n"
                  "2026-01-01,Whole Foods Market #10234,-1.00\n2026-01-01,  SQ *Blue  Bottle 4421 ,-2.00\n"
                  "2026-01-01,Rent 2026,-3.00\n2026-01-01,7-Eleven 12,-4.00\n2026-01-01,#123,-5.00\n"
                  "2026-01-01,\"Café\tMélange  #9\",-6.00\n2026-01-01,AMAZON.COM*X2 AMZN.COM/BILL,-7.00\n"
                  "2026-01-01,Shop 12 345,-8.00\n2026-01-01,\"\",-9.00\n2026-01-01,REI #,-10.00\n")}),
              "steps": [R("init"), R("import", "m.csv", "--account", "x"), R("export"),
                        R("--format", "csv", "export"), R("report", "categories")]})
    S.append({"name": "rules-and-overrides", "description": "first match wins, overrides, rules change applies to old rows",
              "files": base_files(**{"chk.csv": chk}),
              "steps": [R("init"), R("import", "chk.csv", "--account", "checking"), R("report", "categories"),
                        R("set-category", "2", "coffee"), R("set-category", "5", "shopping"), {"ledger": "ledger"},
                        R("list", "--category", "coffee"), R("set-category", "5", "--clear"),
                        R("set-category", "7", "--clear"),
                        {"write": {"rules.conf": "coffee = *\n"}}, R("report", "categories"),
                        {"write": {"rules.conf": ""}}, R("list", "--uncategorized", "--month", "2026-02")]})
    S.append({"name": "reports-filters", "description": "monthly, categories, merchants with filters",
              "files": base_files(**{"chk.csv": chk, "card.csv": card, "giro.csv": giro}),
              "steps": [R("init"), R("import", "chk.csv", "--account", "checking"),
                        R("import", "card.csv", "--account", "card"), R("import", "giro.csv", "--account", "giro"),
                        R("report", "monthly"), R("report", "monthly", "--account", "card"),
                        R("report", "monthly", "--from", "2026-02"), R("report", "monthly", "--to", "2026-01"),
                        R("report", "categories", "--month", "2026-02"), R("report", "categories", "--account", "giro"),
                        R("report", "merchants"), R("report", "merchants", "--top", "3", "--month", "2026-01"),
                        R("report", "monthly", "--from", "2027-01"), R("accounts")]})
    S.append({"name": "share-rounding", "description": "share is exact, rounded half away from zero",
              "files": base_files(**{"s.csv": (
                  "Date,Description,Amount\n2026-05-01,Netflix.com,-1.00\n2026-05-01,Spotify USA,-2.00\n"
                  "2026-05-01,Uber trip,-397.00\n2026-05-02,Lyft Ride,-0.01\n2026-05-02,Payroll Acme,100.00\n")}),
              "steps": [R("init"), R("import", "s.csv", "--account", "a"), R("report", "categories"),
                        R("--format", "csv", "report", "categories"),
                        {"write": {"s2.csv": "Date,Description,Amount\n2026-06-01,Uber X,-1.00\n"
                                             "2026-06-01,Shell 1,-1.00\n2026-06-01,C,-1.00\n"}},
                        R("import", "s2.csv", "--account", "a"), R("report", "categories", "--month", "2026-06")]})
    S.append({"name": "budget", "description": "budget status and exit 3",
              "files": base_files(**{"chk.csv": chk, "card.csv": card}),
              "steps": [R("init"), R("import", "chk.csv", "--account", "checking"),
                        R("import", "card.csv", "--account", "card"),
                        R("budget", "--month", "2026-01"), R("budget", "--month", "2026-02", "--account", "card"),
                        R("budget", "--month", "2025-12"), R("--format", "json", "budget", "--month", "2026-01")]})
    S.append({"name": "budget-missing", "description": "budget needs a budget_file",
              "files": {"pqledger.conf": "[ledger]\ndata_dir = ledger\n"},
              "steps": [R("init"), R("budget", "--month", "2026-01")]})
    S.append({"name": "output-formats", "description": "table, csv and json quoting and escaping",
              "files": {"pqledger.conf": "[ledger]\ndata_dir = ledger\n[output]\nformat = csv\n",
                        "x.csv": ('Date,Description,Amount\n2026-01-01,"Comma, Inc",-1.00\n'
                                  '2026-01-02,"Say ""hi""",-2.00\n2026-01-03,"Tab\there",3.00\n'
                                  '2026-01-04,"Line\nbreak",4.00\n2026-01-05,"",-5.00\n'
                                  '2026-01-06,Back\\slash,0.00\n2026-01-07,Ünïcödé ✓,-0.50\n')},
              "steps": [R("init"), R("import", "x.csv", "--account", "a"), R("export"),
                        R("--format", "json", "export"), R("--format", "table", "accounts")]})
    S.append({"name": "empty-results", "description": "zero rows in every format",
              "files": base_files(),
              "steps": [R("init"), R("report", "monthly"), R("--format", "csv", "report", "categories"),
                        R("--format", "json", "list"), R("budget", "--month", "2026-01")]})
    S.append({"name": "config-location", "description": "--config, PQLEDGER_CONFIG and ./pqledger.conf",
              "files": {"conf/main.conf": "[ledger]\ndata_dir = ../books\n",
                        "conf/env.conf": "[ledger]\ndata_dir = envbooks\n",
                        "pqledger.conf": "[ledger]\ndata_dir = cwdbooks\n",
                        "sub/t.csv": "Date,Description,Amount\n2026-01-01,X,1.00\n"},
              "steps": [R("--config", "conf/main.conf", "init"), {"ledger": "books"},
                        R("--config", "conf/main.conf", "import", "sub/t.csv", "--account", "a"),
                        R("init"), {"ledger": "cwdbooks"},
                        R("--config", "../conf/main.conf", "accounts", cwd="sub"),
                        R("--config", "nope.conf", "init")]})
    S.append({"name": "config-env", "description": "PQLEDGER_CONFIG is used when --config is absent",
              "env": {"PQLEDGER_CONFIG": "conf/env.conf"},
              "files": {"conf/env.conf": "[ledger]\ndata_dir = envbooks\n",
                        "pqledger.conf": "[ledger]\ndata_dir = cwdbooks\n"},
              "steps": [R("init"), {"ledger": "conf/envbooks"}, R("--config", "pqledger.conf", "init"),
                        {"ledger": "cwdbooks"}]})
    bad = {
        "unknown-key": "[ledger]\ndata_dir = l\ncolour = blue\n",
        "repeated-key": "[ledger]\ndata_dir = l\ndata_dir = m\n",
        "before-section": "data_dir = l\n[ledger]\ndata_dir = l\n",
        "no-data-dir": "[ledger]\nrules_file = r\n",
        "bad-format": "[ledger]\ndata_dir = l\n[output]\nformat = xml\n",
        "bad-header": "[ledger]\ndata_dir = l\n[import]\nheader = yes\n",
        "unknown-section": "[ledger]\ndata_dir = l\n[accounts]\n",
        "same-separators": "[ledger]\ndata_dir = l\n[account eu]\ndecimal_separator = ,\nthousands_separator = ,\n",
    }
    S.append({"name": "config-errors", "description": "invalid configuration files exit 2",
              "files": {f"{k}.conf": v for k, v in bad.items()} | {
                  "ok.conf": "; comment\n[ledger]\n  data_dir = \"l\"  \nrules_file = bad-rules.conf\n",
                  "ok2.conf": "[ledger]\ndata_dir = l\nbudget_file = bad-budget.conf\n",
                  "bad-rules.conf": "groceries = SAFE_WAY\n",
                  "bad-budget.conf": "groceries = 12.345\n"},
              "steps": [R("--config", f"{k}.conf", "init") for k in bad] + [
                  R("--config", "ok.conf", "init"), R("--config", "ok.conf", "report", "monthly"),
                  R("--config", "ok2.conf", "budget", "--month", "2026-01")]})
    S.append({"name": "usage-errors", "description": "command-line errors exit 1",
              "files": base_files(**{"t.csv": "Date,Description,Amount\n2026-01-01,X,1.00\n"}),
              "steps": [R("init"), R("import", "t.csv", "--account", "a"), R("frobnicate"), R("report"),
                        R("report", "weekly"),
                        R("report", "monthly", "--month", "2026-01", "--from", "2026-01"),
                        R("report", "monthly", "--month", "2026-13"), R("report", "monthly", "--from", "2026-03",
                                                                         "--to", "2026-02"),
                        R("report", "monthly", "--bogus"), R("import", "t.csv"),
                        R("import", "t.csv", "--account", "Bad Name"), R("set-category", "1", "Groceries"),
                        R("set-category", "1", "uncategorized"), R("report", "merchants", "--top", "0"),
                        R("--format", "xml", "accounts"), R("accounts", "extra"),
                        R("report", "monthly", "--month", "2026-01", "--month", "2026-02"), R("help"),
                        R("--help")]})
    S.append({"name": "set-category", "description": "overrides are stored in overrides.pqcf",
              "files": base_files(**{"t.csv": "Date,Description,Amount\n2026-01-01,Mystery,-10.00\n"
                                              "2026-01-02,Mystery,-20.00\n"}),
              "steps": [R("init"), R("import", "t.csv", "--account", "a"), R("set-category", "2", "gifts"),
                        R("set-category", "2", "books"), R("set-category", "9", "gifts"), {"ledger": "ledger"},
                        R("report", "categories"), R("set-category", "2", "--clear"), {"ledger": "ledger"}]})
    S.append({"name": "no-ledger", "description": "commands before init exit 6",
              "files": base_files(**{"t.csv": "Date,Description,Amount\n2026-01-01,X,1.00\n"}),
              "steps": [R("accounts"), R("report", "monthly"), R("import", "t.csv", "--account", "a")]})
    S.append({"name": "seeded-ledger", "description": "a ledger written elsewhere (DICT/RLE encodings) is read and extended",
              "files": base_files(**{"chk.csv": chk}),
              "seed_ledger": {"dir": "ledger", "encoding": "compact",
                              "transactions": [[7, "checking", "2026-01-01", "RENT - OAKWOOD APTS", "RENT - OAKWOOD APTS",
                                                "-1850.00", 3],
                                               [9, "old", "2025-12-24", "Gift shop", "GIFT SHOP", "-40.00", 3],
                                               [12, "old", "2025-12-31", "Interest", "INTEREST", "0.12", 4]],
                              "batches": [[3, "checking", "dec.csv", 2, 0], [4, "old", "int.csv", 1, 0]],
                              "overrides": [[9, "gifts"]]},
              "steps": [R("accounts"), R("import", "chk.csv", "--account", "checking"), {"ledger": "ledger"},
                        R("report", "categories"), R("export", "--to", "2026-01")]})
    S.append({"name": "query", "description": "SQL on the ledger tables",
              "files": base_files(**{"chk.csv": chk}),
              "steps": [R("init"), R("import", "chk.csv", "--account", "checking"), R("set-category", "3", "gifts"),
                        {"query": "SELECT COUNT(*) AS n FROM transactions", "fn": q_count},
                        {"query": "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger GROUP BY category "
                                  "ORDER BY category", "fn": q_by_category},
                        {"query": "SELECT rule_no, category, pattern FROM rules WHERE category = 'coffee' "
                                  "ORDER BY rule_no", "fn": q_rules, "format": "csv"},
                        {"query": "SELECT category, amount FROM budgets WHERE amount > 100 ORDER BY category",
                         "fn": q_budgets, "format": "json"},
                        {"query": "SELECT t.id, o.category FROM transactions t JOIN overrides o ON t.id = o.id "
                                  "ORDER BY t.id", "fn": q_override_join},
                        {"query_error": "SELEC 1", "code": "PARSE_ERROR"},
                        {"query_error": "SELECT * FROM nowhere", "code": "SEMANTIC_ERROR"}]})
    S.append({"name": "help-version", "description": "help and version exit 0 without a configuration",
              "files": {}, "steps": [R("version"), R("help")]})
    return S


def strip_stdout(case: dict, names: set[str]) -> dict:
    """help/version text is implementation-defined: keep only the exit status."""
    for s in case["steps"]:
        if s.get("args") and s["args"][-1] in names | {"--help"} and "stdout" in s:
            del s["stdout"]
    return case


def hidden_scenarios() -> list[dict]:
    chk = bank("us-checking", "2025-11", "2026-02", seed=11, per_month=14)
    chk_b = bank("us-checking", "2026-01", "2026-04", seed=11, per_month=14)
    card = bank("us-card", "2025-12", "2026-03", seed=12, per_month=10)
    giro = bank("de-giro", "2025-12", "2026-02", seed=13, per_month=10)
    S = []
    S.append({"name": "h-mixed-accounts", "description": "three formats, overlapping statements, every report",
              "files": base_files(**{"a.csv": chk, "b.csv": chk_b, "card.csv": card, "giro.csv": giro}),
              "steps": [R("init"), R("import", "a.csv", "--account", "checking"),
                        R("import", "card.csv", "--account", "card"), R("import", "b.csv", "--account", "checking"),
                        R("import", "giro.csv", "--account", "giro"), R("import", "card.csv", "--account", "card"),
                        {"ledger": "ledger"}, R("accounts"), R("report", "monthly"),
                        R("--format", "json", "report", "monthly", "--account", "checking"),
                        R("report", "categories", "--from", "2026-01", "--to", "2026-02"),
                        R("report", "merchants", "--top", "7", "--account", "card"),
                        R("budget", "--month", "2026-02"), R("--format", "csv", "list", "--month", "2026-03"),
                        R("export", "--account", "giro", "--month", "2025-12")]})
    S.append({"name": "h-formats", "description": "BOM, tab delimiter, YYYYMMDD, numeric columns without header",
              "files": {"pqledger.conf": (
                  "[ledger]\ndata_dir = data/ledger\n\n[import]\nheader = false\ndelimiter = tab\n"
                  "date_column = 2\ndate_format = YYYYMMDD\ndescription_column = 4\namount_column = 3\n"
                  "\n[account uk]\nheader = true\ndelimiter = ,\ndate_column = posted on\ndate_format = DD/MM/YYYY\n"
                  "description_column = DETAILS\namount_column = value\nthousands_separator = space\n"
                  "currency_symbol = \"£\"\n\n[account ch]\ndecimal_separator = .\nthousands_separator = '\n"
                  "currency_symbol = \" CHF\"\n")},
              "files_b64": {
                  "tab.tsv": __import__("base64").b64encode(
                      "﻿x\t20260301\t-12.34\tCorner Shop #77\n\r\ny\t20260302\t+1000\tSalary\n"
                      "z\t20260228\t-0.00\tZero\n".encode()).decode(),
                  "uk.csv": __import__("base64").b64encode(
                      "﻿Posted On,Details,Value\r\n1/3/2026,Tesco Stores 3301,-£1 234.50\r\n"
                      "15/03/2026,Refund,(-0)\r\n".encode()).decode(),
                  "uk2.csv": __import__("base64").b64encode(
                      "Posted On,Details,Value\r\n1/3/2026,Tesco Stores 3301,-£1 234.50\r\n"
                      "31/03/2026,  Pret  A Manger  ,£4.10\r\n".encode()).decode(),
                  "ch.tsv": __import__("base64").b64encode(
                      "a\t20260310\t-1'250.00 CHF\tMigros\nb\t20260311\t(80.05)\tCoop #1\n".encode()).decode()},
              "steps": [R("init"), R("import", "tab.tsv", "--account", "main"),
                        R("import", "uk.csv", "--account", "uk", contains=["uk.csv:3:"]),
                        R("import", "uk2.csv", "--account", "uk"), R("import", "ch.tsv", "--account", "ch"),
                        {"ledger": "data/ledger"}, R("--format", "json", "export")]})
    S.append({"name": "h-config-edge", "description": "quoted values, comments, account sections, CRLF config",
              "files": {"p.conf": ("﻿# books\r\n[ledger]\r\ndata_dir = \"my books\"\r\nrules_file=r.conf\r\n"
                                   "[account joint-1]\r\n  amount_mode = debit_credit\r\n  debit_column = 2\r\n"
                                   "  credit_column = 3\r\n description_column = 4\r\n date_column = 1\r\n"),
                        "r.conf": "; rules\nfood = *BURGER*, ?ACO BELL\nfood = PIZZA*\nfun = *\n",
                        "j.csv": ("Date,Out,In,What\n2026-02-01,12.00,,Burger King\n2026-02-01,,5.00,Pizza Hut\n"
                                  "2026-02-02,3.00,1.00,Taco Bell\n2026-02-03,,,Nothing\n")},
              "steps": [R("--config", "p.conf", "init"), R("--config", "p.conf", "import", "j.csv", "--account", "joint-1",
                                                           contains=["j.csv:5:"]),
                        {"write": {"j.csv": ("Date,Out,In,What\n2026-02-01,12.00,,Burger King\n2026-02-01,,5.00,"
                                             "Pizza Hut\n2026-02-02,3.00,1.00,Taco Bell\n2026-02-03,1,,Kino\n")}},
                        R("--config", "p.conf", "import", "j.csv", "--account", "joint-1"),
                        R("--config", "p.conf", "--format", "csv", "list"),
                        R("--config", "p.conf", "report", "categories")]})
    S.append({"name": "h-errors", "description": "more invalid input",
              "files": base_files(**{
                  "q.csv": 'Date,Description,Amount\n2026-01-01,"unterminated,-1.00\n',
                  "dc.csv": "Date,Description,Amount\n2026-01-01,X,12.\n",
                  "big.csv": "Date,Description,Amount\n2026-01-01,X,-12345678901234567.00\n",
                  "ok.csv": "Date,Description,Amount\n2026-01-01,X,9999999999999999.99\n"}),
              "steps": [R("init"), R("import", "q.csv", "--account", "a"),
                        R("import", "dc.csv", "--account", "a", contains=["dc.csv:2:"]),
                        R("import", "big.csv", "--account", "a", contains=["big.csv:2:"]),
                        R("import", "ok.csv", "--account", "a"), {"ledger": "ledger"},
                        R("set-category", "0", "x"), R("set-category", "abc", "x"),
                        R("set-category", "1", "x", "--clear"), R("budget"),
                        R("report", "merchants", "--top", "x")]})
    S.append({"name": "h-seeded-interop", "description": "seeded plain-encoded ledger, rules change, overrides kept",
              "files": base_files(**{"g.csv": giro}),
              "seed_ledger": {"dir": "ledger", "encoding": "plain",
                              "transactions": [[1, "giro", "2025-12-01", "Miete Hausverwaltung", "MIETE HAUSVERWALTUNG",
                                                "-1120.00", 1],
                                               [2, "giro", "2025-12-15", "Gehalt ACME GmbH", "GEHALT ACME GMBH",
                                                "3810.55", 1]],
                              "batches": [[1, "giro", "old.csv", 2, 0]], "overrides": [[2, "bonus"]]},
              "steps": [R("import", "g.csv", "--account", "giro"), {"ledger": "ledger"}, R("report", "monthly"),
                        R("list", "--category", "bonus"),
                        {"query": "SELECT id, merchant, amount FROM transactions WHERE amount <= -1000 ORDER BY id",
                         "fn": q_big_tx},
                        {"query": "SELECT batch, file, imported FROM batches ORDER BY batch", "fn": q_batches,
                         "format": "csv"}]})
    S.append({"name": "h-scale", "description": "about 100,000 transactions: import and reports in time",
              "files": base_files(),
              "generate": [{"path": "big.csv", "style": "us-checking", "from": "2018-01", "to": "2026-12",
                            "seed": 5, "per_month": 920}],
              "steps": [R("init"), R("import", "big.csv", "--account", "checking", timeout=120),
                        R("import", "big.csv", "--account", "checking", timeout=120),
                        R("report", "monthly", "--from", "2026-01", timeout=60),
                        R("report", "categories", timeout=60), R("report", "merchants", "--top", "3", timeout=60),
                        R("budget", "--month", "2024-02", timeout=60), R("accounts", timeout=60),
                        {"query": "SELECT COUNT(*) AS n FROM transactions", "fn": q_count}]})
    return S


EMBED_T = "id,name,amount,day\n1,ann,10.50,2026-01-01\n2,bob,-3.25,2026-01-02\n3,\"c, d\",0.75,2026-01-02\n"


def embed_cases(hidden: bool) -> list[dict]:
    if not hidden:
        return [
            {"name": "embed-select", "files": {"t.csv": EMBED_T},
             "args": ["t.csv", "SELECT id, name FROM t ORDER BY id"], "exit": 0,
             "stdout": 'id,name\n1,ann\n2,bob\n3,"c, d"\n'},
            {"name": "embed-aggregate", "files": {"t.csv": EMBED_T},
             "args": ["t.csv", "SELECT day, COUNT(*) AS n FROM t GROUP BY day ORDER BY day"], "exit": 0,
             "stdout": "day,n\n2026-01-01,1\n2026-01-02,2\n"},
            {"name": "embed-error", "files": {"t.csv": EMBED_T}, "args": ["t.csv", "SELECT nope FROM t"],
             "exit": 1, "stderr_contains": ["error: SEMANTIC_ERROR"]}]
    return [
        {"name": "h-embed-types", "files": {"t.csv": EMBED_T},
         "args": ["t.csv", "SELECT name, amount * 2 AS twice, amount > 0 AS pos, CAST(NULL AS STRING) AS z FROM t "
                           "WHERE id <> 2 ORDER BY name DESC"], "exit": 0,
         "stdout": 'name,twice,pos,z\n"c, d",1.500000,true,\nann,21.000000,true,\n'},
        {"name": "h-embed-float", "files": {"t.csv": EMBED_T},
         "args": ["t.csv", "SELECT AVG(amount) AS a, SUM(id) AS s FROM t"], "exit": 0, "stdout": "a,s\n2.666667,6\n"},
        {"name": "h-embed-missing", "files": {}, "args": ["none.csv", "SELECT 1"], "exit": 1,
         "stderr_contains": ["error: "]},
        {"name": "h-embed-parse", "files": {"t.csv": EMBED_T}, "args": ["t.csv", "SELECT FROM"], "exit": 1,
         "stderr_contains": ["error: PARSE_ERROR"]}]


def write_dir(d: Path, cases: list[dict], sub: str) -> None:
    out = d / sub
    if out.exists():
        for f in out.glob("*.json"):
            f.unlink()
    out.mkdir(parents=True, exist_ok=True)
    for c in cases:
        (out / f"{c['name']}.json").write_text(json.dumps(c, indent=1, ensure_ascii=False) + "\n")


def main() -> int:
    pub = [strip_stdout(build(s), {"help", "version"}) for s in public_scenarios()]
    hid = [build(s) for s in hidden_scenarios()]
    write_dir(PUBLIC, pub, "cases")
    write_dir(HIDDEN, hid, "cases")
    write_dir(PUBLIC, embed_cases(False), "embed")
    write_dir(HIDDEN, embed_cases(True), "embed")
    n = lambda cs: sum(len(c["steps"]) for c in cs)  # noqa: E731
    print(f"public: {len(pub)} cases, {n(pub)} steps; hidden: {len(hid)} cases, {n(hid)} steps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
