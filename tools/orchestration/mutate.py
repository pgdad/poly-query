#!/usr/bin/env python3
"""Controlled defect injection for debugging / regression-recovery experiments.

Applies one language-agnostic source mutation (relational operator, arithmetic
operator, boolean literal, off-by-one in an integer literal) to a copy of an
engine, rebuilds it and runs the conformance suite. A mutant is accepted when it
builds and makes between --min-fail and --max-fail cases fail (a "killed but
subtle" defect). The accepted patch and the list of failing cases are stored in
experiments/controlled/defects/<lang>/<id>/ for use as a `debug-mutant` task.
Mutants are chosen with a recorded seed so every language gets the same
*procedure* (not the same line, which cannot exist across languages).

  mutate.py --lang go --seed 1 [--candidates 40] [--phase 1 --phase 2]
"""
from __future__ import annotations

import argparse
import json
import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXT = {"java": [".java"], "clojure": [".clj"], "rust": [".rs"], "python": [".py"], "go": [".go"],
       "common-lisp": [".lisp"]}
COMMENT = {"java": "//", "clojure": ";", "rust": "//", "python": "#", "go": "//", "common-lisp": ";"}

# (name, regex, replacement) — applied to one occurrence in one code line.
OPS = [
    ("rel_lt_le", r"(?<![<>=!])<(?![<=])", "<="),
    ("rel_le_lt", r"<=", "<"),
    ("rel_gt_ge", r"(?<![<>=-])>(?![>=])", ">="),
    ("rel_ge_gt", r">=", ">"),
    ("eq_ne", r"==", "!="),
    ("arith_plus_minus", r"(?<=\s)\+(?=\s)", "-"),
    ("arith_minus_plus", r"(?<=\s)-(?=\s)", "+"),
    ("bool_true_false", r"\btrue\b", "false"),
    ("bool_false_true", r"\bfalse\b", "true"),
    ("int_off_by_one", r"(?<![\w.])1(?![\w.])", "2"),
    ("lisp_lt_le", r"\(<\s", "(<= "),
    ("lisp_gt_ge", r"\(>\s", "(>= "),
    ("lisp_nil_t", r"\bnil\b", "t"),
]


def candidates(lang: str, base: Path, rng: random.Random, n: int) -> list[tuple[Path, int, str, re.Match]]:
    files = [p for p in base.rglob("*") if p.suffix in EXT[lang] and p.is_file()
             and not any(x in p.parts for x in ("target", "build", "test", "tests"))
             and not re.search(r"test", p.name, re.I)]
    pool = []
    for f in files:
        for i, line in enumerate(f.read_text(errors="replace").splitlines()):
            s = line.strip()
            if not s or s.startswith(COMMENT[lang]) or s.startswith(("*", "/*", '"', "'")):
                continue
            for name, rx, rep in OPS:
                for m in re.finditer(rx, line):
                    pool.append((f, i, name, m, rep))
    rng.shuffle(pool)
    return pool[:n]


SANDBOX = ROOT / "tools/orchestration/sandbox.sh"


def run(cmd: list[str], cwd: Path, timeout: int = 1800) -> subprocess.CompletedProcess:
    """Engine code is AI-generated: build and test it only inside the sandbox (cwd = work tree)."""
    cfg, scr = cwd / ".sbx-config", cwd / ".sbx-scratch"
    cfg.mkdir(exist_ok=True)
    scr.mkdir(exist_ok=True)
    return subprocess.run([str(SANDBOX), str(cwd), str(cfg), str(scr), "--", *cmd], cwd=cwd, capture_output=True,
                          text=True, timeout=timeout)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--candidates", type=int, default=40)
    ap.add_argument("--phase", type=int, action="append")
    ap.add_argument("--min-fail", type=int, default=1)
    ap.add_argument("--max-fail", type=int, default=15)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    src = ROOT / "implementations" / a.lang
    base = Path("/srv/polyquery/mutants")
    base.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=f"pqmut-{a.lang}-", dir=base))
    shutil.copytree(ROOT / "tests", work / "tests")
    dst = work / "implementations" / a.lang
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("target", "build", ".cpcache", "__pycache__"))
    phase_args = sum((["--phase", str(p)] for p in (a.phase or [1])), [])
    for f, i, name, m, rep in candidates(a.lang, dst, rng, a.candidates):
        text = f.read_text(errors="replace")
        lines = text.splitlines(keepends=True)
        orig = lines[i]
        lines[i] = orig[:m.start()] + rep + orig[m.end():]
        f.write_text("".join(lines))
        rel = f.relative_to(work)
        b = run(["make", "-C", str(dst), "build"], work)
        if b.returncode == 0:
            r = run(["python3", "tests/conformance/runner.py", "--engine", str(dst / "bin/polyquery"),
                     *phase_args, "--report", str(work / "mut.json"), "-q"], work)
            rep_ = json.loads((work / "mut.json").read_text()) if (work / "mut.json").exists() else None
            failing = [f"{x['file']}:{c['line']}" for x in (rep_ or {}).get("files", []) for c in x["cases"]
                       if c["status"] in ("fail", "error")]
            print(f"  {rel}:{i + 1} {name}: {len(failing)} failing")
            if a.min_fail <= len(failing) <= a.max_fail:
                did = f"seed{a.seed}-{name}-{f.stem}-{i + 1}"
                out = ROOT / "experiments/controlled/defects" / a.lang / did
                out.mkdir(parents=True, exist_ok=True)
                diff = subprocess.run(["diff", "-u", "--label", f"a/{rel}", "--label", f"b/{rel}", "-",
                                       str(f)], input=text, capture_output=True, text=True).stdout
                (out / "mutation.patch").write_text(diff)
                (out / "defect.json").write_text(json.dumps({"language": a.lang, "seed": a.seed, "operator": name,
                                                             "file": str(rel), "line": i + 1, "failing_cases": failing},
                                                            indent=1) + "\n")
                (out / "DEFECT.md").write_text("# Injected defect\n\nThe following conformance cases fail:\n\n" +
                                               "\n".join(f"* `{x}`" for x in failing) + "\n")
                print(f"accepted mutant -> {out.relative_to(ROOT)}")
                shutil.rmtree(work, ignore_errors=True)
                return 0
        f.write_text(text)
    print("no suitable mutant found")
    shutil.rmtree(work, ignore_errors=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
