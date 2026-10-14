#!/usr/bin/env python3
"""Cross-implementation ledger interoperability for pqledger (spec/apps/pqledger.md §4).

A ledger written by any conforming implementation must be readable and writable by every
other. Expected outputs always come from the engine-free reference (pqledger_ref.py), run on
the same ledger files; no implementation's output is ever used as another's expectation.

Phases (each takes --app NAME=PATH ... and works in --dir; PATH may be a .py script):
  produce   NAME builds a ledger in DIR/ledgers/NAME (init, three imports, overrides); its
            stdout must match the reference's, and its PQCF files must decode (strict reader
            tools/validation/pqcf.py) to exactly the rows the reference writes.
  consume   NAME reads every ledger in DIR/ledgers (accounts, list, export, reports, budget),
            then writes to a copy (an overlapping import, set/clear overrides) left in
            DIR/written/PRODUCER__NAME; reads compare with the reference on the same files,
            the written PQCF rows with the reference applying the same writes.
  readback  NAME reads every DIR/written/NAME__* (its own ledger after another implementation
            wrote to it, possibly next to its own stale cache files).
Results go to DIR/results/<phase>-NAME.json; `summary --dir DIR` prints the matrix.
The phases run engine code: invoke them only inside the sandbox (sandboxed.sh, or a pqrunner
unit on the ARM host).
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/validation"))
import pqcf  # noqa: E402

REFERENCE = ROOT / "tools/validation/pqledger_ref.py"
BANKGEN = ROOT / "datasets/generators/bankgen.py"
TABLES = ("transactions", "batches", "overrides")
TIMEOUT = 300

CONFIG = """[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[account checking]

[account card]
{card}
[account giro]
{giro}"""
RULES = """groceries = WHOLE FOODS*, TRADER JOE'S*, SAFEWAY*, REWE*, EDEKA*, LIDL*
fuel = SHELL*, CHEVRON*, ARAL*
coffee = *COFFEE*, STARBUCKS*
housing = RENT*, MIETE*
income = PAYROLL*, GEHALT*
"""
BUDGETS = "groceries = 600\nfuel = 150.50\ncoffee = 40\nhousing = 1850\n"
INPUTS = {  # file: (style, from, to, seed, per_month)
    "checking.csv": ("us-checking", "2026-01", "2026-03", 7, 30),
    "card.csv": ("us-card", "2026-01", "2026-03", 8, 25),
    "giro.csv": ("de-giro", "2026-02", "2026-03", 9, 20),
    "checking-apr.csv": ("us-checking", "2026-03", "2026-04", 7, 30),  # March overlaps: duplicates
}
PRODUCE = [["init"], ["import", "inputs/checking.csv", "--account", "checking"],
           ["import", "inputs/card.csv", "--account", "card"], ["import", "inputs/giro.csv", "--account", "giro"],
           ["set-category", "3", "travel"], ["set-category", "40", "coffee"], ["set-category", "41", "travel"]]
READS = [["accounts"], ["--format", "csv", "list"], ["--format", "csv", "export"],
         ["report", "monthly"], ["--format", "json", "report", "categories"], ["report", "merchants", "--top", "7"],
         ["list", "--uncategorized", "--account", "card", "--from", "2026-02-01"], ["budget", "--month", "2026-03"]]
WRITES = [["import", "inputs/checking-apr.csv", "--account", "checking"], ["set-category", "41", "--clear"],
          ["set-category", "5", "groceries"], ["set-category", "40", "dining"]]


def cmd_for(path: str) -> list[str]:
    return [sys.executable, path] if path.endswith(".py") else [path]


def run(app: str, args: list[str], cwd: Path) -> dict:
    try:
        p = subprocess.run([*cmd_for(app), *args], cwd=cwd, capture_output=True, timeout=TIMEOUT)
        return {"exit": p.returncode, "stdout": p.stdout.decode("utf-8", "replace"),
                "stderr": p.stderr.decode("utf-8", "replace")[-400:]}
    except subprocess.TimeoutExpired:
        return {"exit": None, "stdout": "", "stderr": "timeout"}


def setup(case: Path, inputs: Path) -> None:
    case.mkdir(parents=True)
    cfg = {s: subprocess.run([sys.executable, str(BANKGEN), "--style", s, "--from", "2026-01", "--to", "2026-01",
                              "--print-config"],
                             capture_output=True, text=True, check=True).stdout for s in ("us-card", "de-giro")}
    (case / "pqledger.conf").write_text(CONFIG.format(card=cfg["us-card"], giro=cfg["de-giro"]))
    (case / "rules.conf").write_text(RULES)
    (case / "budgets.conf").write_text(BUDGETS)
    shutil.copytree(inputs, case / "inputs")


def make_inputs(d: Path) -> Path:
    inp = d / "inputs"
    if not inp.exists():
        inp.mkdir(parents=True)
        for f, (style, a, b, seed, n) in INPUTS.items():
            subprocess.run([sys.executable, str(BANKGEN), "--style", style, "--from", a, "--to", b, "--seed",
                            str(seed), "--per-month", str(n), "--out", str(inp / f)], check=True)
    return inp


def ledger_rows(ledger: Path) -> dict:
    out = {}
    for t in TABLES:
        try:
            meta, rows = pqcf.read((ledger / f"{t}.pqcf").read_bytes())
            out[t] = {"columns": [[c["name"], c["type"]] for c in meta["columns"]], "rows": [[str(v) for v in r] for r in rows]}
        except Exception as e:  # noqa: BLE001 - any decode failure is a finding
            out[t] = {"error": f"{type(e).__name__}: {e}"}
    return out


def diff_ledgers(got: dict, exp: dict) -> list[str]:
    fails = []
    for t in TABLES:
        g, e = got.get(t, {}), exp.get(t, {})
        if "error" in g:
            fails.append(f"{t}.pqcf unreadable: {g['error']}")
        elif g["columns"] != e["columns"]:
            fails.append(f"{t}.pqcf columns {g['columns']} != {e['columns']}")
        elif g["rows"] != e["rows"]:
            bad = next(i for i, (a, b) in enumerate(zip(g["rows"] + [None], e["rows"] + [None])) if a != b)
            fails.append(f"{t}.pqcf rows differ ({len(g['rows'])} vs {len(e['rows'])}), first at {bad}: "
                         f"{(g['rows'] + [None])[bad]} != {(e['rows'] + [None])[bad]}")
    return fails


def compare(step: list[str], got: dict, exp: dict) -> list[str]:
    fails = []
    if got["exit"] != exp["exit"]:
        fails.append(f"{' '.join(step)}: exit {got['exit']} != {exp['exit']} ({got['stderr'].strip()[:200]})")
    elif got["stdout"] != exp["stdout"]:
        g, e = got["stdout"].splitlines(), exp["stdout"].splitlines()
        i = next((i for i, (a, b) in enumerate(zip(g + [""], e + [""])) if a != b), 0)
        fails.append(f"{' '.join(step)}: stdout differs at line {i + 1}: {(g + [''])[i]!r} != {(e + [''])[i]!r}")
    return fails


def read_checks(app: str, case: Path, scratch: Path) -> list[str]:
    """The reference reads a pristine copy first (an implementation may add cache files)."""
    ref = scratch / "ref-read"
    shutil.rmtree(ref, ignore_errors=True)
    shutil.copytree(case, ref)
    fails = []
    for step in READS:
        fails += compare(step, run(app, step, case), run(str(REFERENCE), step, ref))
    return fails


def apps_arg(values: list[str]) -> dict[str, str]:
    return dict(v.split("=", 1) for v in values)


def produce(d: Path, apps: dict[str, str]) -> dict:
    inputs = make_inputs(d)
    ref = d / "ledgers" / "reference"
    if not (ref / "ledger" / "transactions.pqcf").exists():
        shutil.rmtree(ref, ignore_errors=True)
        setup(ref, inputs)
        for step in PRODUCE:
            run(str(REFERENCE), step, ref)
    exp = ledger_rows(ref / "ledger")
    res = {}
    for name, app in apps.items():
        case = d / "ledgers" / name
        shutil.rmtree(case, ignore_errors=True)
        setup(case, inputs)
        with tempfile.TemporaryDirectory() as t:
            refc = Path(t) / "ref"
            setup(refc, inputs)
            fails = []
            for step in PRODUCE:
                fails += compare(step, run(app, step, case), run(str(REFERENCE), step, refc))
        fails += diff_ledgers(ledger_rows(case / "ledger"), exp)
        res[name] = {"ok": not fails, "failures": fails}
        print(f"produce {name}: {'ok' if not fails else f'{len(fails)} failures'}", flush=True)
    return res


def consume(d: Path, apps: dict[str, str]) -> dict:
    res = {}
    producers = sorted(p.name for p in (d / "ledgers").iterdir() if p.is_dir())
    for name, app in apps.items():
        for prod in producers:
            src = d / "ledgers" / prod
            out = d / "written" / f"{prod}__{name}"
            shutil.rmtree(out, ignore_errors=True)
            with tempfile.TemporaryDirectory() as t:
                scratch = Path(t)
                shutil.copytree(src, out)
                fails = read_checks(app, out, scratch)
                refw = scratch / "ref-write"
                shutil.copytree(src, refw)
                for step in WRITES:
                    fails += compare(step, run(app, step, out), run(str(REFERENCE), step, refw))
                fails += diff_ledgers(ledger_rows(out / "ledger"), ledger_rows(refw / "ledger"))
            res[f"{prod}__{name}"] = {"producer": prod, "consumer": name, "ok": not fails, "failures": fails}
            print(f"consume {prod} -> {name}: {'ok' if not fails else f'{len(fails)} failures'}", flush=True)
    return res


def readback(d: Path, apps: dict[str, str]) -> dict:
    res = {}
    for name, app in apps.items():
        for w in sorted((d / "written").glob(f"{name}__*")):
            with tempfile.TemporaryDirectory() as t:
                case = Path(t) / "case"
                shutil.copytree(w, case)  # keep the written ledger for other readers
                fails = read_checks(app, case, Path(t))
            res[w.name] = {"producer": name, "writer": w.name.split("__", 1)[1], "ok": not fails, "failures": fails}
            print(f"readback {w.name}: {'ok' if not fails else f'{len(fails)} failures'}", flush=True)
    return res


def summary(d: Path) -> int:
    res: dict[str, dict] = {"produce": {}, "consume": {}, "readback": {}}
    for f in sorted((d / "results").glob("*.json")):
        res[f.name.split("-", 1)[0]].update(json.loads(f.read_text()))
    names = sorted(set(res["produce"]) | {r["consumer"] for r in res["consume"].values()})
    print("produce:", ", ".join(f"{n} {'ok' if r['ok'] else 'FAIL'}" for n, r in sorted(res["produce"].items())))
    producers = ["reference", *sorted(res["produce"])]
    w = max(len(n) for n in producers) + 2
    print("\nconsume (row = ledger producer, column = reader/writer; then readback by the producer):")
    print(" " * w + "".join(n[:10].rjust(12) for n in names))
    bad = 0
    for p in producers:
        cells = []
        for c in names:
            k = f"{p}__{c}"
            con, rb = res["consume"].get(k), res["readback"].get(k)
            s = "-" if con is None else ("ok" if con["ok"] else "FAIL")
            if p != "reference":
                s += "/" + ("-" if rb is None else ("ok" if rb["ok"] else "FAIL"))
            bad += (con is not None and not con["ok"]) + (rb is not None and not rb["ok"])
            cells.append(s.rjust(12))
        print(p.ljust(w) + "".join(cells))
    bad += sum(not r["ok"] for r in res["produce"].values())
    for ph in res:
        for k, r in res[ph].items():
            for f in r["failures"][:3]:
                print(f"  {ph} {k}: {f}")
    (d / "interop.json").write_text(json.dumps(res, indent=1) + "\n")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("phase", choices=["produce", "consume", "readback", "summary"])
    ap.add_argument("--dir", type=Path, required=True)
    ap.add_argument("--app", action="append", default=[], help="NAME=PATH (repeatable)")
    a = ap.parse_args()
    a.dir = a.dir.resolve()
    if a.phase == "summary":
        return summary(a.dir)
    apps = {n: str(Path(p).resolve()) for n, p in apps_arg(a.app).items()}
    res = {"produce": produce, "consume": consume, "readback": readback}[a.phase](a.dir, apps)
    (a.dir / "results").mkdir(parents=True, exist_ok=True)
    tag = "-".join(sorted(apps))
    (a.dir / "results" / f"{a.phase}-{tag}.json").write_text(json.dumps(res, indent=1) + "\n")
    return 0 if all(r["ok"] for r in res.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
