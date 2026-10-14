#!/usr/bin/env python3
"""Assembly-engine policy check for a finished run (ADR-0016, languages.json stdlib_note).

Checks the agent's committed work directory and transcript: no C or other high-level source
files, no compiler-generated assembly markers (.LFB, .cfi_startproc, GCC ident), no C
compilation in any shell command, no high-level source file written anywhere, and reports
merge commits. Writes compliance.json into the run
directory and exits 1 on a violation.

  asm_engine_compliance.py <run-id>
"""
from __future__ import annotations

import gzip
import json
import re
import subprocess
import sys
from pathlib import Path

RUN_ROOT = Path("/srv/polyquery/runs")
HIGH_LEVEL = re.compile(r"\.(c|h|cc|cpp|cxx|hpp|rs|go|java|clj|lisp|zig|f90|d)$")
MARKERS = re.compile(r"\.LFB[0-9]|\.cfi_startproc|GCC: \(|^\s*\.ident\b", re.M)
# The embedding API's C header (spec/apps/embedding.md §2) is allowed if it only declares:
# no function bodies (a ')' followed by '{').
API_HEADER = "include/polyquery.h"
FUNC_BODY = re.compile(r"\)\s*\{")
C_COMPILE = re.compile(r"\b(gcc|cc|clang|tcc)\b[^\"]{0,120}\.c\b|-S\b[^\"]{0,40}\.c\b|\bcc1\b")


def git(ws: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=ws, check=True, capture_output=True, text=True).stdout


def tool_uses(transcript: Path):
    opener = gzip.open if transcript.suffix == ".gz" else open
    with opener(transcript, "rt") as fh:
        for line in fh:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            ev = ev.get("event") or ev
            msg = ev.get("message") if isinstance(ev, dict) else None
            for c in (msg or {}).get("content") or [] if isinstance(msg, dict) else []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    yield c.get("name") or "", c.get("input") or {}


def shell_commands(transcript: Path):
    # Only executed commands count as compilation; file content (e.g. a C usage example in
    # EMBEDDING.md) is checked through the paths written, not by text matching.
    for name, inp in tool_uses(transcript):
        if name == "Bash" and isinstance(inp, dict):
            yield str(inp.get("command", ""))


def written_paths(transcript: Path):
    for name, inp in tool_uses(transcript):
        if name in ("Write", "Edit", "MultiEdit", "NotebookEdit") and isinstance(inp, dict):
            yield str(inp.get("file_path") or inp.get("notebook_path") or "")


def main() -> int:
    run = sys.argv[1]
    rd = RUN_ROOT / run
    m = json.loads((rd / "manifest.json").read_text())
    ws, wd = rd / "workspace", m["work_dir"]
    files = git(ws, "ls-files", wd).split()
    asm = [f for f in files if f.endswith((".S", ".s", ".inc"))]
    base = m.get("chain_baseline_commit") or m["baseline_commit"]
    transcripts = [p for p in (rd / "transcript.jsonl", rd / "transcript.jsonl.gz") if p.exists()]
    out = {
        "run_id": run,
        "high_level_sources": [f for f in files if HIGH_LEVEL.search(f) and not (
            f == f"{wd}/{API_HEADER}" and not FUNC_BODY.search((ws / f).read_text(errors="replace")))],
        "compiler_markers": [f for f in asm if MARKERS.search((ws / f).read_text(errors="replace"))],
        "c_compile_tool_calls": [s[:200] for t in transcripts[:1] for s in shell_commands(t) if C_COMPILE.search(s)],
        "high_level_files_written": sorted({p for t in transcripts[:1] for p in written_paths(t)
                                            if HIGH_LEVEL.search(p) and not p.endswith(f"/{API_HEADER}")}),
        "merge_commits": int(git(ws, "rev-list", "--merges", "--count", f"{base}..HEAD").strip()),
        "asm_lines": sum(len((ws / f).read_text(errors="replace").splitlines()) for f in asm),
        "transcript_checked": bool(transcripts),
    }
    out["compliant"] = (not out["high_level_sources"] and not out["compiler_markers"]
                        and not out["c_compile_tool_calls"] and not out["high_level_files_written"]
                        and out["transcript_checked"])
    (rd / "compliance.json").write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps({k: v for k, v in out.items() if k != "run_id"}))
    return 0 if out["compliant"] else 1


if __name__ == "__main__":
    sys.exit(main())
