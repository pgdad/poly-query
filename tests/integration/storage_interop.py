#!/usr/bin/env python3
"""Cross-engine PQCF v1 interoperability matrix (Phase 3 / M5).

For every writer engine W (claiming storage.pqcf) and every encoding mode, W
loads the interop tables and saves them. Each file is validated by the
independent reference reader (tools/validation/pqcf.py) and its decoded content
is compared with the reference ingestion of the source data. Then every reader
engine R opens every file and its `SELECT *` result is compared with the same
reference content. The golden files written by the reference writer are
included as an extra "writer".

  storage_interop.py [--engines java,go,...] [--report results/correctness/interop.json]
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/conformance"))
sys.path.insert(0, str(ROOT / "tools/validation"))

import pqcf  # noqa: E402
import pqref  # noqa: E402
from engine import EngineError, SessionEngine, engine_info  # noqa: E402
from pqt import rows_match  # noqa: E402

FIX = ROOT / "tests/conformance/fixtures"
LANGS = ["java", "clojure", "rust", "python", "go", "common-lisp"]

TABLES = {
    "people": {"path": "fixtures/people.csv", "format": "csv"},
    "ledger": {"path": "fixtures/ledger.csv", "format": "csv",
               "schema": [{"name": "id", "type": "INT64"}, {"name": "account", "type": "STRING"},
                          {"name": "amount", "type": "DECIMAL(10,2)"}, {"name": "fee", "type": "DECIMAL(4,2)"}]},
    "strings": {"path": "fixtures/strings.csv", "format": "csv"},
    "dates": {"path": "fixtures/dates.csv", "format": "csv"},
    "tx": {"path": "fixtures/gen/transactions.csv", "format": "csv",
           "schema": json.loads((FIX / "gen/transactions.schema.json").read_text())},
    "nulls": {"path": "fixtures/gen/nulls_heavy.csv", "format": "csv",
              "schema": json.loads((FIX / "gen/nulls_heavy.schema.json").read_text())},
    "events": {"path": "fixtures/events.json", "format": "json"},
}
MODES = [("plain", 100000), ("dict", 333), ("rle", 1000), ("auto", 64)]


def reference_rows(t: dict) -> tuple[list[str], list[list]]:
    text = (FIX.parent / t["path"]).read_text(encoding="utf-8")
    if t["format"] == "csv":
        names, types, rows = pqref.load_csv(text, t.get("schema"))
    else:
        names, types, rows = pqref.load_json(text, t["format"], t.get("schema"))
    return types, [[pqref.serialize(v, ty) for v, ty in zip(r, types)] for r in rows]


def decode_file(path: Path) -> tuple[list[str], list[list]]:
    meta, rows = pqcf.read(path.read_bytes())
    types = [pqref.canonical_type(c["type"]) for c in meta["columns"]]
    return types, [[pqref.serialize(v, ty) for v, ty in zip(r, types)] for r in rows]


def discover(names: list[str] | None) -> dict[str, str]:
    out = {}
    for l in names or LANGS:
        launcher = ROOT / "implementations" / l / "bin/polyquery"
        if launcher.exists():
            info = engine_info(str(launcher))
            if "storage.pqcf" in info["capability_set"]:
                out[l] = str(launcher)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engines")
    ap.add_argument("--report")
    a = ap.parse_args()
    engines = discover(a.engines.split(",") if a.engines else None)
    work = Path(tempfile.mkdtemp(prefix="pqinterop-"))
    (work / "fixtures").symlink_to(FIX)
    (work / "out").mkdir()
    refs = {name: reference_rows(t) for name, t in TABLES.items()}
    files: list[dict] = []   # {writer, mode, table, path, valid, content_ok, error}

    # 1. writers
    for w, launcher in engines.items():
        try:
            eng = SessionEngine(launcher, work, timeout=120)
        except EngineError as e:
            files.append({"writer": w, "error": f"engine start: {e}"})
            continue
        try:
            for tname, t in TABLES.items():
                req = {"op": "load", "table": tname, "format": t["format"], "path": t["path"]}
                if "schema" in t:
                    req["schema"] = t["schema"]
                r = eng.request(req)
                if not r.get("ok"):
                    files.append({"writer": w, "table": tname, "error": f"load failed: {r.get('error')}"})
                    continue
                for mode, rg in MODES:
                    rel = f"out/{w}__{tname}__{mode}.pqcf"
                    r = eng.request({"op": "save", "table": tname, "path": rel,
                                     "options": {"encoding": mode, "row_group_size": rg}})
                    entry = {"writer": w, "table": tname, "mode": mode, "path": rel}
                    if not r.get("ok"):
                        entry["error"] = f"save failed: {r.get('error')}"
                    else:
                        try:
                            types, rows = decode_file(work / rel)
                            ok, msg = rows_match(refs[tname][1], rows, refs[tname][0], True)
                            entry["valid"] = True
                            entry["content_ok"] = ok and types == refs[tname][0]
                            if not entry["content_ok"]:
                                entry["error"] = f"content differs from source: {msg or types}"
                        except pqcf.Corrupt as e:
                            entry["valid"] = False
                            entry["error"] = f"reference reader rejects file: {e.code}: {e}"
                    files.append(entry)
        except EngineError as e:
            files.append({"writer": w, "error": f"engine failure: {e}"})
        finally:
            eng.close()

    # reference-writer golden files count as an extra writer
    gold = {"people": "people.pqcf"}
    for tname, g in gold.items():
        shutil.copy(FIX / "pqcf" / g, work / "out" / f"reference__{tname}__auto.pqcf")
        files.append({"writer": "reference", "table": tname, "mode": "auto",
                      "path": f"out/reference__{tname}__auto.pqcf", "valid": True, "content_ok": True})

    # 2. readers
    matrix: dict[str, dict[str, dict]] = {}
    readable = [f for f in files if f.get("valid")]
    for r_name, launcher in engines.items():
        try:
            eng = SessionEngine(launcher, work, timeout=120)
        except EngineError as e:
            matrix[r_name] = {"_error": {"error": str(e)}}
            continue
        try:
            for k, f in enumerate(readable):
                tab = f"t{k}"
                cell = matrix.setdefault(r_name, {}).setdefault(f["writer"], {"ok": 0, "fail": 0, "failures": []})
                r = eng.request({"op": "open", "table": tab, "path": f["path"]})
                if r.get("ok"):
                    r = eng.request({"op": "query", "sql": f'SELECT * FROM "{tab}"'})
                if not r.get("ok"):
                    cell["fail"] += 1
                    cell["failures"].append({"file": f["path"], "error": r.get("error")})
                    continue
                types, exp = refs[f["table"]]
                got_types = [c["type"] for c in r.get("columns", [])]
                ok, msg = rows_match(exp, r.get("rows", []), types, False)
                if ok and got_types == types:
                    cell["ok"] += 1
                else:
                    cell["fail"] += 1
                    cell["failures"].append({"file": f["path"], "error": msg or f"types {got_types}"})
                eng.request({"op": "drop", "table": tab})
        except EngineError as e:
            matrix.setdefault(r_name, {})["_error"] = {"error": str(e)}
        finally:
            eng.close()

    write_errors = [f for f in files if f.get("error")]
    read_fail = sum(c["fail"] for row in matrix.values() for c in row.values() if isinstance(c, dict) and "fail" in c)
    summary = {"engines": list(engines), "files_written": len(files), "write_errors": len(write_errors),
               "read_failures": read_fail, "passed": not write_errors and read_fail == 0 and bool(engines)}
    report = {"schema": "polyquery-interop/1", "summary": summary, "files": files, "matrix": matrix}
    print(f"interop engines={list(engines)} files={len(files)} write_errors={len(write_errors)} read_failures={read_fail}")
    for r_name, row in matrix.items():
        print(f"  reader {r_name:12} " + " ".join(f"{w}:{c.get('ok', 0)}/{c.get('ok', 0) + c.get('fail', 0)}"
                                                for w, c in row.items() if isinstance(c, dict) and "ok" in c))
    for f in write_errors[:20]:
        print(f"  WRITE {f.get('writer')} {f.get('table')} {f.get('mode')}: {f['error'][:200]}")
    if a.report:
        Path(a.report).parent.mkdir(parents=True, exist_ok=True)
        Path(a.report).write_text(json.dumps(report, indent=1) + "\n")
    shutil.rmtree(work, ignore_errors=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
