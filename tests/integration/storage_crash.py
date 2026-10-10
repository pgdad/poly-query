#!/usr/bin/env python3
"""PQCF crash-consistency suite (storage/pqcf-v1.md §5).

Repeatedly kills an engine with SIGKILL at random moments while it saves one of
two different versions of a large table over the same target path. After every
kill the target must be absent or a complete, valid file containing exactly one
of the two versions (checked with the independent reference reader). Finally
the engine itself must open the surviving file.

  storage_crash.py --engine implementations/go/bin/polyquery [--iterations 25] [--seed 7]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/conformance"))
sys.path.insert(0, str(ROOT / "tools/validation"))

import pqcf  # noqa: E402
from engine import SessionEngine  # noqa: E402


def make_csv(path: Path, rows: int, tag: str) -> None:
    with open(path, "w") as f:
        f.write("id,tag,v,s\n")
        for i in range(rows):
            f.write(f"{i},{tag},{(i * 7919) % 100003},{tag}-{i % 997}\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--iterations", type=int, default=25)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--report")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    launcher = str(Path(a.engine).resolve())
    data = Path(tempfile.mkdtemp(prefix="pqcrash-"))
    (data / "out").mkdir()
    sizes = {"A": 400_000, "B": 250_000}
    for tag, n in sizes.items():
        make_csv(data / f"{tag}.csv", n, tag)
    target = data / "out/t.pqcf"
    results = []
    violations = 0
    for it in range(a.iterations):
        tag = "A" if it % 2 == 0 else "B"
        eng = SessionEngine(launcher, data, timeout=300)
        r = eng.request({"op": "load", "table": "t", "format": "csv", "path": f"{tag}.csv"})
        if not r.get("ok"):
            print(f"load failed: {r}")
            eng.kill()
            return 2
        # Time a full save once per tag to choose kill points inside the save window.
        delay = rng.uniform(0.0, 0.25 if it < 2 else 0.6)
        assert eng.proc.stdin
        eng.proc.stdin.write((json.dumps({"op": "save", "table": "t", "path": "out/t.pqcf", "id": 1}) + "\n").encode())
        eng.proc.stdin.flush()
        time.sleep(delay)
        os.killpg(eng.proc.pid, signal.SIGKILL)
        eng.proc.wait()
        state = "absent"
        if target.exists():
            try:
                meta, _rows = pqcf.read(target.read_bytes())
                rc = meta["row_count"]
                state = "A" if rc == sizes["A"] else "B" if rc == sizes["B"] else f"unexpected_rows_{rc}"
            except pqcf.Corrupt as e:
                state = f"CORRUPT: {e}"
        ok = state in ("absent", "A", "B")
        violations += 0 if ok else 1
        results.append({"iteration": it, "writing": tag, "kill_after_s": round(delay, 3), "target_state": state, "ok": ok})
        print(f"  iter {it:2} writing {tag} kill@{delay:.3f}s -> {state}{'' if ok else '  <-- VIOLATION'}")
    engine_open = None
    if target.exists():
        eng = SessionEngine(launcher, data, timeout=300)
        r = eng.request({"op": "open", "table": "x", "path": "out/t.pqcf"})
        if r.get("ok"):
            r = eng.request({"op": "query", "sql": "SELECT COUNT(*) FROM x"})
        engine_open = r.get("ok")
        eng.close()
        if not engine_open:
            violations += 1
    leftovers = [p.name for p in (data / "out").iterdir() if p.name != "t.pqcf"]
    summary = {"iterations": a.iterations, "violations": violations, "engine_can_open_survivor": engine_open,
               "temp_files_left": len(leftovers), "states": sorted({r["target_state"] for r in results})}
    print("crash suite:", json.dumps(summary))
    if a.report:
        Path(a.report).write_text(json.dumps({"summary": summary, "iterations": results}, indent=1) + "\n")
    return 0 if violations == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
