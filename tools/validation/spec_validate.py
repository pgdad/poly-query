#!/usr/bin/env python3
"""Consistency checks between the specification and the conformance suites.

* required spec documents exist and internal markdown links resolve;
* error-codes.json is valid; every error code used in tests is defined;
* every capability required by a test file is defined in spec/phases/README.md;
* every .pqt file parses; every fixture path referenced exists;
* Phase-1 files expect success only for `sql.basic` syntax (Phase-2 constructs
  may appear only in cases that expect an error);
* golden PQCF files validate and corrupt ones are rejected by the reference reader.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/conformance"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from pqt import PqtSyntaxError, parse_file  # noqa: E402

REQUIRED = [
    "spec/README.md", "spec/data-types/types.md", "spec/data-types/ingestion.md", "spec/sql/grammar.md",
    "spec/sql/semantics.md", "spec/sql/functions.md", "spec/protocol/protocol.md", "spec/errors/errors.md",
    "spec/errors/error-codes.json", "spec/storage/pqcf-v1.md", "spec/storage/indexes-and-planning.md",
    "spec/concurrency/concurrency.md", "spec/phases/README.md", "spec/acceptance/README.md",
    "native-kernels/include/pq_kernels.h",
]


def main() -> int:
    problems: list[str] = []
    for r in REQUIRED:
        if not (ROOT / r).exists():
            problems.append(f"missing spec document {r}")

    for md in (ROOT / "spec").rglob("*.md"):
        for link in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", md.read_text()):
            if link.startswith("http"):
                continue
            if not (md.parent / link).resolve().exists():
                problems.append(f"{md.relative_to(ROOT)}: broken link {link}")

    codes = set(json.loads((ROOT / "spec/errors/error-codes.json").read_text())["codes"])
    caps = set(re.findall(r"^\| `([a-z0-9_.]+)` \|", (ROOT / "spec/phases/README.md").read_text(), re.M))

    phase2_syntax = re.compile(r"\b(BETWEEN|LIKE|CASE|IN|GROUP|HAVING|DISTINCT|JOIN|EXISTS|WITH|UNION|EXPLAIN)\b|\|\||"
                               r"\b(?!(?:COUNT|SUM|MIN|MAX|AVG|CAST|PQ_SLEEP|NOT|AND|OR|DECIMAL|NUMERIC|VARCHAR|CHAR)\s*\()[A-Z_]+\s*\(", re.I)
    files = sorted((ROOT / "tests/conformance/cases").rglob("*.pqt")) + \
        sorted((ROOT / "tests/conformance/hidden/cases").rglob("*.pqt"))
    ncases = 0
    for p in files:
        try:
            f = parse_file(p)
        except PqtSyntaxError as e:
            problems.append(f"syntax: {e}")
            continue
        for c in f.requires:
            if c not in caps:
                problems.append(f"{p.relative_to(ROOT)}: unknown capability {c}")
        for st in f.steps:
            if st.is_case:
                ncases += 1
            code = st.expect_error
            for kind, arg in st.expectations:
                if kind == "error":
                    code = arg
            if f.phase == 1 and st.sql and not code:
                bare = re.sub(r"'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\"", "''", st.sql)
                if m := phase2_syntax.search(bare):
                    problems.append(f"{p.relative_to(ROOT)}:{st.line}: Phase-2 syntax {m.group(0)!r} in a Phase-1 case")
            if code and code not in codes:
                problems.append(f"{p.relative_to(ROOT)}:{st.line}: unknown error code {code}")
            path = (st.request or {}).get("path")
            if path and path.startswith("fixtures/") and ".." not in path and st.kind in ("load", "open", "corrupt") \
                    and not st.expect_error in ("NOT_FOUND",) and not (ROOT / "tests/conformance" / path).exists():
                problems.append(f"{p.relative_to(ROOT)}:{st.line}: missing fixture {path}")

    import pqcf
    gold = ROOT / "tests/conformance/fixtures/pqcf"
    for g in sorted(gold.glob("*.pqcf")):
        try:
            pqcf.read(g.read_bytes())
        except pqcf.Corrupt as e:
            problems.append(f"golden {g.name} invalid: {e}")
    for g in sorted((gold / "corrupt").glob("*.pqcf")):
        try:
            pqcf.read(g.read_bytes())
            problems.append(f"corrupt fixture {g.name} is valid")
        except pqcf.Corrupt:
            pass

    for pr in problems:
        print(pr)
    print(f"spec-validate: {len(files)} test files, {ncases} cases, {len(codes)} error codes, {len(caps)} capabilities, "
          f"{len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
